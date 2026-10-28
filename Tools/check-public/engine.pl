#!/usr/bin/perl
# Tools/check-public/engine.pl: the matcher behind Tools/check-public.sh and Tools/check-secrets.sh.
# Run it through those scripts. Tools/check-public.sh documents the modes, the rule files, the allow
# file and the output format. Byte semantics throughout: rule files and scanned files are compared
# as raw UTF-8 bytes, never decoded. Nothing here prints a pattern or a matched string.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Cwd qw(abs_path);
use File::Find ();
use IPC::Open2 qw(open2);
use POSIX ();
use Unicode::Normalize ();

my $HERE;
BEGIN { require Cwd; $HERE = Cwd::abs_path(__FILE__); $HERE =~ s{/[^/]+\z}{}; }

# Perl quotes the pattern in some regex warnings; never let one reach a log. Other warnings and
# errors name this file's absolute path, which holds the home folder: it is replaced first. The
# handlers are set at compile time, so compile-time warnings go through them too.
my $HOME_PREFIX;
BEGIN { $HOME_PREFIX = '/Use' . 'rs/' }
sub scrub_msg {
    my ($w) = @_;
    $w =~ s/\Q$HERE\E/<tools>/g;
    $w =~ s/\Q$ENV{HOME}\E/~/g if defined $ENV{HOME} && length $ENV{HOME} > 1;
    $w =~ s{\Q$HOME_PREFIX\E[^/\s]+}{$HOME_PREFIX<user>}g;
    return $w;
}
BEGIN {
    $SIG{__WARN__} = sub {
        my $w = shift;
        if ($ENV{YC_DEBUG}) { print STDERR scrub_msg($w); return }
        $w = "internal warning withheld (it may quote a rule)\n" if $w =~ /regex|HERE|\bm\//i;
        print STDERR "WARN: " . scrub_msg($w);
    };
    $SIG{__DIE__} = sub { die(ref $_[0] ? $_[0] : scrub_msg($_[0])) };
}
require "$HERE/images.pl";

# Private classes are opaque ids (P01..P99): what each one covers is written only in the deny list's own
# header. The list gives a class its properties with CLASS lines, names its companion files with USE lines
# and adds letter variants for the decoded forms with FOLD lines (see Tools/check-public.sh).
my (@PRIVATE_ORDER, %PRIVATE_CLASS, %CLASS_PROP, %USE, %FOLD, $FOLD_RE);
my %PROP_OK = map { $_ => 1 } qw(sub promo name term);
my %USE_OK = map { $_ => 1 } qw(identity allow probes);
my %FLAG_OK = map { $_ => 1 } qw(i w s short ctx path);
my $CTRL = qr/[\x00-\x08\x0A-\x1F\x7F]/;
my $LIT_MAX = 256;
my $NO_PREFILTER = $ENV{YC_NO_PREFILTER} ? 1 : 0;

# ---------------------------------------------------------------- options
my %O = (mode => '', targets => [], strict => 0, promo => 0, refs => 0, range => '',
         rules => '', allow => '', private_allow => '', deny => '', identity => '', repo => '');
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--mode')            { $O{mode} = shift(@ARGV) // '' }
    elsif ($a eq '--target')          { push @{ $O{targets} }, shift(@ARGV) // '' }
    elsif ($a eq '--rules')           { $O{rules} = shift(@ARGV) // '' }
    elsif ($a eq '--allow')           { $O{allow} = shift(@ARGV) // '' }
    elsif ($a eq '--private-allow')   { $O{private_allow} = shift(@ARGV) // '' }
    elsif ($a eq '--deny')            { $O{deny} = shift(@ARGV) // '' }
    elsif ($a eq '--identity')        { $O{identity} = shift(@ARGV) // '' }
    elsif ($a eq '--repo')            { $O{repo} = shift(@ARGV) // '' }
    elsif ($a eq '--range')           { $O{range} = shift(@ARGV) // '' }
    elsif ($a eq '--strict')          { $O{strict} = 1 }
    elsif ($a eq '--promo')           { $O{promo} = 1 }
    elsif ($a eq '--refs')            { $O{refs} = 1 }
    else                              { fatal("unknown engine argument") }
}
my %MODES = map { $_ => 1 } qw(tree staged bundle history images text secrets);
fatal("no mode") unless $MODES{ $O{mode} };

sub fatal { print STDERR "ERROR: $_[0]\n"; exit 2 }

# ---------------------------------------------------------------- rules
my (@CONTENT, @PATHRULES, @PRIVATE, %RULE_BY_ID, @GEN_ORDER, %GEN_SEEN, %MASKS, %PATH_MASKS, %ALLOW_SHA, @PRIV_IDX, @GENV_IDX, @DISP_RULES);
my $PRIVATE_LOADED = 0;

sub load_rules {
    my ($file, $origin) = @_;
    open my $fh, '<', $file or fatal("cannot read the $origin rules file");
    my ($ln, @skips, @new) = (0);
    while (my $line = <$fh>) {
        $ln++;
        next if $line =~ /\A\s*(?:#|\z)/;
        $line =~ s/\r?\n\z//;
        my @f = split /\t/, $line, -1;
        fatal("$origin rules line $ln: expected 4 tab-separated fields") unless @f == 4;
        if ($origin eq 'public' && $f[0] eq 'SKIP') { push @skips, [$ln, @f[1 .. 3]]; next }
        if ($origin eq 'private' && $f[0] =~ /\A(?:CLASS|USE|FOLD)\z/) { private_directive($ln, @f); next }
        my ($id, $class, $flags, $pat) = @f;
        if ($origin eq 'private') {
            fatal("private rules line $ln: the class must be P01..P99 and the id <class>-NN")
              unless $class =~ /\AP[0-9]{2}\z/ && $id =~ /\A\Q$class\E-[0-9]{2}\z/;
            $PRIVATE_CLASS{$class} = 1;
        } else {
            fatal("public rules line $ln: class must be GEN-<NAME> and the id <class>-NN")
              unless $class =~ /\AGEN-[A-Z]+\z/ && $id =~ /\A\Q$class\E-[0-9]{2}\z/;
            $pat =~ s/\{\+\}//g;
            push @GEN_ORDER, $class unless $GEN_SEEN{$class}++;
        }
        fatal("$origin rules line $ln: duplicate rule id") if $RULE_BY_ID{$id};
        my %fl;
        if ($flags ne '-') {
            for (split /,/, $flags) { fatal("$origin rules line $ln: unknown flag") unless $FLAG_OK{$_}; $fl{$_} = 1 }
        }
        fatal("$origin rules line $ln: empty pattern") unless length $pat;
        my $r = { id => $id, class => $class, flags => \%fl, origin => $origin, skips => [], slash => (index($pat, "/") >= 0 ? 1 : 0) };
        $RULE_BY_ID{$id} = $r;
        push @new, [$r, $pat];
    }
    close $fh;
    # compiled once the whole file is read: a CLASS line may follow the rules it describes
    for my $n (@new) {
        my ($r, $pat) = @$n;
        $r->{re} = compile_rule($r, $pat, 0);
        $r->{re_bundle} = compile_rule($r, $pat, 1);
        $r->{lits} = $NO_PREFILTER ? undef : lit_set($pat);
        printf STDERR "PREFILTER %s literals=%d\n", $r->{id}, $r->{lits} ? scalar @{ $r->{lits} } : 0 if $ENV{YC_DEBUG_PREFILTER};
        if ($r->{flags}{path}) { push @PATHRULES, $r } else { push @CONTENT, $r }
        push @PRIVATE, $r if $origin eq 'private';
    }
    if ($origin eq 'private') {
        @PRIVATE_ORDER = sort keys %PRIVATE_CLASS;
        $FOLD_RE = %FOLD ? do { my $alt = join '|', map { quotemeta } sort keys %FOLD; qr/($alt)/ } : undef;
    }
    for my $s (@skips) {
        my ($sl, $rid, $pathre, $matchre) = @$s;
        my $r = $RULE_BY_ID{$rid} or fatal("public rules line $sl: SKIP names an unknown rule");
        s/\{\+\}//g for $pathre, $matchre;
        my $pq = eval { qr/$pathre/ };
        my $mq = eval { qr/\A(?:$matchre)\z/ };
        fatal("public rules line $sl: SKIP regex does not compile") unless $pq && $mq;
        push @{ $r->{skips} }, [$pq, $mq];
    }
}

# The deny list's directives, four tab-separated fields like its rules:
#   CLASS <id> <props|-> -     properties of a private class: sub (substring rules in --bundle mode),
#                              promo (allowed by --text --promo), name and term (self-test shape hints)
#   USE <identity|allow|probes> <file> -     a companion file, relative to the deny list's folder
#   FOLD U+XXXX <U+YYYY|-> -   the decoded forms read the first character as the second (or drop it)
sub private_directive {
    my ($ln, $kind, $a, $b, $c) = @_;
    fatal("private rules line $ln: a $kind line ends in '-'") unless $c eq '-';
    if ($kind eq 'CLASS') {
        fatal("private rules line $ln: CLASS needs an id P01..P99") unless $a =~ /\AP[0-9]{2}\z/;
        $CLASS_PROP{$a} //= {};
        return if $b eq '-';
        for (split /,/, $b) { fatal("private rules line $ln: unknown class property") unless $PROP_OK{$_}; $CLASS_PROP{$a}{$_} = 1 }
    } elsif ($kind eq 'USE') {
        fatal("private rules line $ln: USE names identity, allow or probes, then a file") unless $USE_OK{$a} && length $b;
        $USE{$a} = $b;
    } else {
        my @cp = map { /\AU\+([0-9A-Fa-f]{4,6})\z/ ? hex $1 : -1 } ($a, $b eq '-' ? () : $b);
        fatal("private rules line $ln: FOLD takes U+XXXX (not ASCII) and U+XXXX or '-'")
          if grep({ $_ < 0 || $_ > 0x10FFFF || ($_ >= 0xD800 && $_ <= 0xDFFF) } @cp) || $cp[0] < 0x80;
        $FOLD{ chr $cp[0] } = @cp > 1 ? chr $cp[1] : '';
    }
}

# Bundle form of a rule whose class has the sub property: Swift mangling puts word characters on both
# sides of a name, so lookarounds that only test for a boundary character (a class such as [A-Za-z0-9],
# \w, ^ or $) are dropped and the rule becomes a substring rule. Short-tag rules keep their context:
# without it a three-letter tag matches inside ordinary words.
sub relax_boundaries {
    my ($p) = @_;
    my $n = length $p;
    my $out = '';
    my $skipclass = sub {
        my ($i) = @_;
        my $j = $i + 1;
        $j++ if substr($p, $j, 1) eq '^';
        $j++ if substr($p, $j, 1) eq ']';
        for (; $j < $n; $j++) { my $e = substr($p, $j, 1); if ($e eq '\\') { $j++; next } last if $e eq ']' }
        return $j;
    };
    for (my $i = 0; $i < $n; $i++) {
        my $c = substr($p, $i, 1);
        if ($c eq '\\') {
            my $nx = substr($p, $i + 1, 1);
            if ($nx eq 'b' || $nx eq 'B') { $out .= '(?:)'; $i++; next }
            $out .= substr($p, $i, 2); $i++; next;
        }
        if ($c eq '[') { my $j = $skipclass->($i); $out .= substr($p, $i, $j - $i + 1); $i = $j; next }
        if ($c eq '(' && substr($p, $i) =~ /\A\(\?(<[!=]|[!=])/) {
            my $hl = length("(?$1");
            my ($d, $j) = (1, $i + $hl);
            for (; $j < $n; $j++) {
                my $e = substr($p, $j, 1);
                if ($e eq '\\') { $j++; next }
                if ($e eq '[') { $j = $skipclass->($j); next }
                if ($e eq '(') { $d++ } elsif ($e eq ')') { $d--; last if $d == 0 }
            }
            my $body = substr($p, $i + $hl, $j - $i - $hl);
            my $boundary = 1;
            for my $alt (split /\|/, $body) {
                (my $t = $alt) =~ s/\A\(\?:(.*)\)\z/$1/;
                $boundary = 0 unless $t =~ /\A(?:\^|\$|\\[wWdDsS]|\[(?:\\.|[^\]\\])*\])\z/;
            }
            $out .= $boundary ? '(?:)' : substr($p, $i, $j - $i + 1);
            $i = $j;
            next;
        }
        $out .= $c;
    }
    return $out;
}

# ---------------------------------------------------------------- literal prefilter
# A rule's literal set: strings of which every match must contain at least one. Text is compared
# lower-cased (sound for case-sensitive rules too: lc only folds A-Z on these byte strings), so a
# rule whose literals are all absent is skipped with a C-speed index() instead of a regex pass.
# The pattern is parsed conservatively; any construct not understood means no prefilter for that
# rule, never a missed match. YC_NO_PREFILTER=1 turns it off (the self-test compares both).

sub lit_set {
    my ($p) = @_;
    my $i = 0;
    my $res = eval { lit_alt($p, \$i) };
    return undef unless $res && $i == length $p && $res->[0] && @{ $res->[0] };
    for (@{ $res->[0] }) { return undef if length $_ < 3 }
    my %u;
    return [ grep { !$u{$_}++ } map { lc } @{ $res->[0] } ];
}

sub lit_minlen { my ($s) = @_; my $m; for (@$s) { $m = length $_ if !defined $m || length $_ < $m } return $m // 0 }

sub lit_better {    # the more selective of two requirement sets (a set holding '' requires nothing)
    my ($a, $b) = @_;
    $a = undef if $a && (!@$a || grep { $_ eq '' } @$a);
    $b = undef if $b && (!@$b || grep { $_ eq '' } @$b);
    return $b unless $a;
    return $a unless $b;
    my ($ma, $mb) = (lit_minlen($a), lit_minlen($b));
    return $ma > $mb ? $a : $mb > $ma ? $b : (@$a <= @$b ? $a : $b);
}

sub lit_cross {
    my ($a, $b) = @_;
    return undef if @$a * @$b > $LIT_MAX;
    return [ map { my $x = $_; map { $x . $_ } @$b } @$a ];
}

sub lit_alt {
    my ($p, $ip) = @_;
    my @br = (lit_seq($p, $ip));
    while ($$ip < length $p && substr($p, $$ip, 1) eq '|') { $$ip++; push @br, lit_seq($p, $ip) }
    return $br[0] if @br == 1;
    my @set;
    my $exact = 1;
    for my $b (@br) { return [undef, 0] unless $b->[0]; push @set, @{ $b->[0] }; $exact &&= $b->[1] }
    return [undef, 0] if @set > $LIT_MAX;
    return [\@set, $exact];
}

sub lit_seq {
    my ($p, $ip) = @_;
    my ($cur, $best, $exact) = ([''], undef, 1);
    while ($$ip < length $p) {
        my $c = substr($p, $$ip, 1);
        last if $c eq '|' || $c eq ')';
        my $item = lit_quant($p, $ip, lit_atom($p, $ip));
        if ($item->[1] && $item->[0]) {
            my $x = lit_cross($cur, $item->[0]);
            if ($x) { $cur = $x; next }
            $best = lit_better($best, $cur);
            ($cur, $exact) = ($item->[0], 0);
            next;
        }
        $exact = 0;
        $best = lit_better(lit_better($best, $cur), $item->[0]);
        $cur = [''];
    }
    return [$cur, 1] if $exact;
    return [lit_better($best, $cur), 0];
}

sub lit_quant {
    my ($p, $ip, $item) = @_;
    my $c = substr($p, $$ip, 1);
    my ($min, $max);
    if    ($c eq '*') { ($min, $max) = (0, -1); $$ip++ }
    elsif ($c eq '+') { ($min, $max) = (1, -1); $$ip++ }
    elsif ($c eq '?') { ($min, $max) = (0, 1); $$ip++ }
    elsif ($c eq '{' && substr($p, $$ip) =~ /\A\{([0-9]+)(,([0-9]*))?\}/) {
        ($min, $max) = ($1, defined $2 ? (length $3 ? $3 : -1) : $1);
        $$ip += length $&;
    } else { return $item }
    $$ip++ if $$ip < length $p && substr($p, $$ip, 1) =~ /[?+]/;
    my ($set, $exact) = @$item;
    if ($min == 0) {
        return [['', @$set], 1] if $exact && $set && $max == 1 && @$set < $LIT_MAX;
        return [undef, 0];
    }
    if ($exact && $set && $max == $min) {
        my $x = [''];
        for (1 .. $min) { $x = lit_cross($x, $set) or return [$set, 0] }
        return [$x, 1];
    }
    return [$set, 0];
}

sub lit_escape_char {    # (char, length) for an escape that stands for one literal byte
    my ($p, $j) = @_;
    my $e = substr($p, $j + 1, 1);
    my %simple = (t => "\t", n => "\n", r => "\r", f => "\f", e => "\e", a => "\a");
    return ($simple{$e}, 2) if exists $simple{$e};
    if ($e eq 'x') {
        return (chr(hex $1), 2 + length $&) if substr($p, $j + 2) =~ /\A\{([0-9A-Fa-f]{1,2})\}/;
        return (chr(hex $1), 2 + length $1) if substr($p, $j + 2) =~ /\A([0-9A-Fa-f]{1,2})/;
        return (undef, 0);
    }
    return (chr(oct $1), 1 + length $1) if $e eq '0' && substr($p, $j + 1) =~ /\A(0[0-7]{0,2})/;
    return ($e, 2) if length $e && $e =~ /[^A-Za-z0-9]/;
    return (undef, 0);
}

sub lit_atom {
    my ($p, $ip) = @_;
    my $c = substr($p, $$ip, 1);
    my $rest = substr($p, $$ip);
    if ($c eq '(') {
        my $look = 0;
        if    ($rest =~ /\A\(\?(?:<[!=]|[!=])/)                    { $look = 1; $$ip += length $& }
        elsif ($rest =~ /\A\(\?#[^)]*\)/)                           { $$ip += length $&; return [[''], 1] }
        elsif ($rest =~ /\A\(\?\^?([a-wyzA-Z-]*):/)                 { $$ip += length $& }
        elsif ($rest =~ /\A\(\?\^?[a-wyzA-Z-]+\)/)                  { $$ip += length $&; return [[''], 1] }
        elsif ($rest =~ /\A\(\?(?:P?<[A-Za-z_][A-Za-z0-9_]*>|'[A-Za-z_][A-Za-z0-9_]*'|[>|])/) { $$ip += length $& }
        elsif ($rest =~ /\A\(\?/)                                   { die "unsupported group\n" }
        else                                                        { $$ip++ }
        my $inner = lit_alt($p, $ip);
        die "unbalanced\n" unless substr($p, $$ip, 1) eq ')';
        $$ip++;
        return $look ? [[''], 1] : $inner;
    }
    if ($c eq '[') {
        my $j = $$ip + 1;
        my ($neg, $complex, $first, @chars) = (0, 0, 1);
        if (substr($p, $j, 1) eq '^') { $neg = 1; $j++ }
        while ($j < length $p) {
            my $d = substr($p, $j, 1);
            last if $d eq ']' && !$first;
            $first = 0;
            if ($d eq '[' && substr($p, $j) =~ /\A\[:\^?[a-z]+:\]/) { $complex = 1; $j += length $&; next }
            my $ch;
            if ($d eq '\\') {
                my $e = substr($p, $j + 1, 1);
                if ($e =~ /[dwshvDWSHVNRpP]/) { die "property class\n" if $e =~ /[pP]/; $complex = 1; $j += 2; next }
                (my $cc, my $len) = lit_escape_char($p, $j);
                die "unsupported class escape\n" unless defined $cc;
                ($ch, $j) = ($cc, $j + $len);
            } else { ($ch, $j) = ($d, $j + 1) }
            if (substr($p, $j, 1) eq '-' && $j + 1 < length $p && substr($p, $j + 1, 1) ne ']') {
                my $e = substr($p, $j + 1, 1);
                my ($hi, $len) = ($e, 1);
                if ($e eq '\\') { ($hi, $len) = lit_escape_char($p, $j + 1); die "unsupported range\n" unless defined $hi }
                $j += 1 + $len;
                if (ord($hi) - ord($ch) > 8) { $complex = 1 } else { push @chars, map { chr } ord($ch) .. ord($hi) }
                next;
            }
            push @chars, $ch;
        }
        die "unterminated class\n" unless substr($p, $j, 1) eq ']';
        $$ip = $j + 1;
        return [undef, 0] if $neg || $complex || !@chars || @chars > 8;
        my %u;
        return [[ grep { !$u{ lc $_ }++ } @chars ], 1];
    }
    if ($c eq '\\') {
        my $e = substr($p, $$ip + 1, 1);
        if ($e =~ /[bBAzZG]/)         { $$ip += 2; return [[''], 1] }
        if ($e =~ /[dwshvDWSHVNRXC]/) { $$ip += 2; return [undef, 0] }
        if ($e eq 'Q') {
            my $end = index($p, '\\E', $$ip + 2);
            my $lit = $end < 0 ? substr($p, $$ip + 2) : substr($p, $$ip + 2, $end - $$ip - 2);
            $$ip = $end < 0 ? length $p : $end + 2;
            return [[$lit], 1];
        }
        my ($ch, $len) = lit_escape_char($p, $$ip);
        die "unsupported escape\n" unless defined $ch;
        $$ip += $len;
        return [[$ch], 1];
    }
    if ($c eq '.') { $$ip++; return [undef, 0] }
    if ($c eq '^' || $c eq '$') { $$ip++; return [[''], 1] }
    die "dangling quantifier\n" if $c =~ /[*+?]/;
    $$ip++;
    return [[$c], 1];
}

sub compile_rule {
    my ($r, $pat, $bundle) = @_;
    my $sub = $r->{origin} eq 'private' && $CLASS_PROP{ $r->{class} } && $CLASS_PROP{ $r->{class} }{sub};
    my $p = $pat;
    if ($bundle && $sub) { $p = relax_boundaries($p) unless $r->{flags}{short} }
    elsif ($r->{flags}{w}) { $p = "\\b(?:$p)\\b" }
    my $re = do { local $SIG{__WARN__} = sub { }; eval { $r->{flags}{i} ? qr/$p/i : qr/$p/ } };
    fatal("rule $r->{id} does not compile") unless defined $re;
    return $re;
}

# Allow file: "path : CLASS : sha256-of-whole-line" entries, "* : CLASS : re:<regex>" structural
# entries whose matches are blanked for that class before its rules run, and "path-re:<regex> : CLASS :
# re:<regex>" structural entries that blank only in the files whose path matches. The committed allow
# file and the private one share this format.
sub load_allow {
    my ($file, $what) = @_;
    return unless length $file && -e $file;
    open my $fh, '<', $file or fatal("cannot read the $what");
    my $ln = 0;
    while (my $line = <$fh>) {
        $ln++;
        next if $line =~ /\A\s*(?:#|\z)/;
        $line =~ s/\r?\n\z//;
        my ($path, $class, $val) = split /\s+:\s+/, $line, 3;
        fatal("$what line $ln: expected 'path : CLASS : value'") unless defined $val && length $path && length $class;
        if ($path eq '*') {
            fatal("$what line $ln: a '*' entry needs re:<regex>") unless $val =~ s/\Are://;
            my $re = do { local $SIG{__WARN__} = sub { }; eval { qr/$val/i } };
            fatal("$what line $ln: regex does not compile") unless $re;
            push @{ $MASKS{$class} }, $re;
        } elsif ($path =~ s/\Apath-re://) {
            fatal("$what line $ln: a 'path-re:' entry needs re:<regex>") unless $val =~ s/\Are://;
            my $pq = do { local $SIG{__WARN__} = sub { }; eval { qr/$path/ } };
            my $re = do { local $SIG{__WARN__} = sub { }; eval { qr/$val/i } };
            fatal("$what line $ln: regex does not compile") unless $pq && $re;
            push @{ $PATH_MASKS{$class} }, [$pq, $re];
        } else {
            fatal("$what line $ln: value must be a sha256 hex digest") unless $val =~ /\A[0-9a-f]{64}\z/;
            $ALLOW_SHA{"$path\0$class\0$val"} = 1;
        }
    }
    close $fh;
}

sub warn_mode {    # a private file readable by other users
    my ($file, $what) = @_;
    my $mode = (stat $file)[2] & 07777;
    print STDERR "WARN: the $what is readable by other users; chmod 600 it\n" if $mode & 077;
}

# A companion file of the deny list: the explicit path (from the environment), else the deny list's USE line.
sub companion {
    my ($key, $explicit) = @_;
    return $explicit if length $explicit;
    return '' unless $PRIVATE_LOADED && defined $USE{$key};
    return $USE{$key} if $USE{$key} =~ m{\A/};
    (my $dir = $O{deny}) =~ s{/[^/]*\z}{};
    $dir = '.' if $dir eq $O{deny};
    return "$dir/$USE{$key}";
}

fatal("public rules file missing") unless length $O{rules} && -r $O{rules};
load_rules($O{rules}, 'public');

if ($O{mode} eq 'secrets') { secrets_mode(); exit 0 }

if (length $O{deny} && -e $O{deny}) {
    load_rules($O{deny}, 'private');
    $PRIVATE_LOADED = 1;
    warn_mode($O{deny}, 'deny list');
} elsif ($O{strict}) {
    fatal("--strict needs the private deny list (set YC_DENYLIST or create .work/private/deny.txt)");
} else {
    print STDERR "WARN: private deny list not found; generic rules only\n";
}
load_allow($O{allow}, 'allow file');
my $PRIVATE_ALLOW = companion('allow', $O{private_allow});
if (length $PRIVATE_ALLOW && -e $PRIVATE_ALLOW) {
    load_allow($PRIVATE_ALLOW, 'private allow file');
    warn_mode($PRIVATE_ALLOW, 'private allow file');
} elsif ($O{strict}) {
    fatal("--strict needs the private allow file (set YC_PRIVATE_ALLOW or name it in a USE line of the deny list)");
} elsif ($PRIVATE_LOADED) {
    print STDERR "WARN: private allow file not found; its reviewed exceptions do not apply\n";
}
my $IDENTITY = companion('identity', $O{identity});
build_lit_index();
# rule indices that also run over the disguised forms (see scan_views); YC_NO_VIEWS=1 turns them off
@PRIV_IDX = $ENV{YC_NO_VIEWS} ? () : grep { $CONTENT[$_]{origin} eq "private" } 0 .. $#CONTENT;
# generic rules that also run over the decoded copy (escapes, entities, %XX), which needs no deny list
my %GEN_DECODED = map { $_ => 1 } qw(GEN-PATH GEN-MAIL GEN-TZ GEN-MEET);
@GENV_IDX = $ENV{YC_NO_VIEWS} ? () : grep { $GEN_DECODED{ $CONTENT[$_]{class} } } 0 .. $#CONTENT;
# rules whose matches are blanked in printed locations: every content rule, private and generic
@DISP_RULES = @CONTENT;

# ---------------------------------------------------------------- output
my (@HITS, %HIT_SEEN, @INFO, @EYE, %ALLOWED, %IGN, %IGN_FILES, $PROMO_ALLOWED, $SCANNED);
$PROMO_ALLOWED = 0;
$SCANNED = 0;

sub record {    # $raw: the unblanked location, so two paths that print alike are still two hits
    my ($id, $class, $loc, $short, $sink, $raw) = @_;
    $sink ||= 'fail';
    if ($sink eq 'ignored') { $IGN{$class}++; return }
    if ($O{promo} && $CLASS_PROP{$class} && $CLASS_PROP{$class}{promo}) { $PROMO_ALLOWED++; return }
    my $line = "$id $loc" . ($short ? ' REVIEW-BY-EYE' : '');
    return if $HIT_SEEN{ "$id\0" . (defined $raw ? $raw : $loc) }++;
    my $key = $loc =~ /\A(.*):([0-9]+)\z/s ? sprintf("%s\0%012d", $1, $2) : $loc;
    push @HITS, [$class, $line, $key, $id];
}

my %DISP;
sub disp {    # a location string with every rule match blanked, so paths never leak a name or address
    my ($s) = @_;
    return $DISP{$s} //= do {
        my $d = $s;
        for my $r (@DISP_RULES) { $d =~ s/$r->{re}/length($&) ? '***' : ''/ge }
        # a name that only the decoded, normalized form shows (escaped, %XX, zero-width characters,
        # combining marks) blanks its whole path component
        my @c = split m{/}, $d, -1;
        for my $c (@c) {
            next if $c eq q{***} || $c !~ /[^A-Za-z0-9._-]/;
            my $n = view_norm(view_decode($c));
            next if $n eq $c;
            $c = '***' if grep { $n =~ $_->{re} } @DISP_RULES;
        }
        $d = join '/', @c;
        $d =~ s/[\x00-\x1F\x7F]/?/g;
        $d;
    };
}

sub allowed {
    my ($key, $class, $line) = @_;
    return 0 unless %ALLOW_SHA;
    return $ALLOW_SHA{"$key\0$class\0" . sha256_hex($line)} ? 1 : 0;
}

# The structural masks of a class for one file: the '*' entries and the path-re: entries whose path matches.
sub masks_for {
    my ($class, $key) = @_;
    my $pm = $PATH_MASKS{$class};
    return $MASKS{$class} unless $pm && defined $key;
    my @own = map { $_->[1] } grep { $key =~ $_->[0] } @$pm;
    return $MASKS{$class} unless @own;
    return [ @{ $MASKS{$class} || [] }, @own ];
}

sub mask {
    my ($buf, $list) = @_;
    my $m = $buf;
    for my $re (@$list) { $m =~ s/$re/"\x1F" x length($&)/ge }
    return $m;
}

sub unskipped {    # true when at least one match of the rule in $t survives the rule's SKIP entries
    my ($r, $re, $t, $key) = @_;
    my @sk = grep { $key =~ $_->[0] } @{ $r->{skips} };
    return 1 unless @sk;
    while ($t =~ /$re/g) {
        my $m = $&;
        return 1 unless grep { $m =~ $_->[1] } @sk;
        pos($t) = $+[0] + 1 if $+[0] == $-[0];
    }
    return 0;
}

# ---------------------------------------------------------------- scanners
# $ctx: { key => allow/skip path, variant => 'text'|'bundle', on_hit => sub($rule, $lineno) }
# One pass finds every literal of every rule: a lookahead alternation, longest literal first, so the
# literal reported at a position is the longest one there. Any other literal matching at that position
# is a prefix of it, so each literal carries the rules of all its prefixes and no occurrence is lost.
my ($LIT_RE, %LIT_OWNERS);
sub build_lit_index {
    my %own;
    for my $i (0 .. $#CONTENT) { my $l = $CONTENT[$i]{lits} or next; $own{$_}{$i} = 1 for @$l }
    return unless %own;
    my @all = sort { length $b <=> length $a || $a cmp $b } keys %own;
    for my $L (@all) {
        my %o;
        for my $k (1 .. length $L) { my $h = $own{ substr($L, 0, $k) } or next; $o{$_} = 1 for keys %$h }
        $LIT_OWNERS{$L} = [ keys %o ];
    }
    my $alt = join "|", map { quotemeta } @all;
    $LIT_RE = qr/(?=($alt))/;
}

sub candidates {    # rule index -> { line index => 1 } for the lines where the rule's literals occur
    my ($lc) = @_;
    my %cand;
    return \%cand unless $LIT_RE;
    my ($ln, $last) = (0, 0);
    while ($lc =~ /$LIT_RE/g) {
        my $p = $-[0];
        $ln += (substr($lc, $last, $p - $last) =~ tr/\n//);
        $last = $p;
        $cand{$_}{$ln} = 1 for @{ $LIT_OWNERS{$1} };
    }
    return \%cand;
}

# Line-based scan. A rule with a literal set only tests the lines where one of its literals occurs;
# the email rule, which has none, tests every line.
# $ctx->{first_only}: stop a rule after its first reported line (bundle sections report once).
sub scan_lines {
    my ($buf, $ctx, $linenos) = @_;
    my $bundle = ($ctx->{variant} || "") eq "bundle";
    my (%masked, %split, $cand);
    for my $ri (0 .. $#CONTENT) {
        my $r = $CONTENT[$ri];
        my @cand;
        if ($r->{lits}) {
            $cand //= candidates(lc $buf);
            my $c = $cand->{$ri} or next;
            @cand = sort { $a <=> $b } keys %$c;
        }
        my $re = $bundle ? $r->{re_bundle} : $r->{re};
        my $mk = masks_for($r->{class}, $ctx->{key});
        my $src = $mk ? ($masked{ $r->{class} } //= mask($buf, $mk)) : $buf;
        next if !$r->{lits} && $src !~ $re;
        my $lines = $split{ $mk ? $r->{class} : "" } //= [ split /\n/, $src, -1 ];
        my $orig = $split{""} //= [ split /\n/, $buf, -1 ];
        for my $k ($r->{lits} ? @cand : 0 .. $#$lines) {
            my $t = $lines->[$k];
            next unless defined $t && $t =~ $re;
            next if @{ $r->{skips} } && !unskipped($r, $re, $t, $ctx->{key});
            if (allowed($ctx->{key}, $r->{class}, $orig->[$k])) { $ALLOWED{ $r->{class} }++; next }
            $ctx->{on_hit}->($r, $linenos ? $linenos->[$k] : $k + 1);
            last if $ctx->{first_only};
        }
    }
    return if $ctx->{no_views};
    my $dec;
    if (@GENV_IDX && $buf =~ /[\\%&=]/) {
        $dec = view_decode($buf);
        scan_gen_decoded($buf, $dec, $ctx, $linenos) if $dec ne $buf;
    }
    scan_views($buf, $ctx, $linenos, $dec) if @PRIV_IDX;
}

# The generic path, mail, zone and meeting rules over the decoded copy, line by line (view_decode keeps
# every line break): JSONEncoder's \/, %2F, %40, &#64; and the like. Only lines that decoding changed
# are tested; the allow digest is that of the original line.
sub scan_gen_decoded {
    my ($buf, $dec, $ctx, $linenos) = @_;
    my $bundle = ($ctx->{variant} || '') eq 'bundle';
    my @d = split /\n/, $dec, -1;
    my @o = split /\n/, $buf, -1;
    my @changed = grep { !defined $o[$_] || $d[$_] ne $o[$_] } 0 .. $#d;
    return unless @changed;
    my %masked;
    for my $ri (@GENV_IDX) {
        my $r = $CONTENT[$ri];
        my $re = $bundle ? $r->{re_bundle} : $r->{re};
        my $mk = masks_for($r->{class}, $ctx->{key});
        for my $k (@changed) {
            my $t = $d[$k];
            $t = $masked{"$r->{class}\0$k"} //= mask($t, $mk) if $mk;
            next unless $t =~ $re;
            next if @{ $r->{skips} } && !unskipped($r, $re, $t, $ctx->{key});
            if (allowed($ctx->{key}, $r->{class}, $o[$k] // '')) { $ALLOWED{ $r->{class} }++; next }
            $ctx->{on_hit}->($r, $linenos ? $linenos->[$k] : $k + 1);
            last if $ctx->{first_only};
        }
    }
}

# ---------------------------------------------------------------- disguised forms (private rules)
# The pass above matches one physical line at a time, as written. A name can also be written so that
# no line holds it: escaped (JSON \u, Swift \u{}, \x, HTML entities, %XX, quoted-printable =XX, RFC 2047
# encoded words), split by an unusual separator (NBSP and other spaces, Unicode dashes, %20, '+',
# '/', tab, double space), interleaved with invisible characters (zero-width characters, soft hyphen,
# bidi marks, combining marks of any script), cut into concatenated string literals, hard-wrapped
# onto the next line (Markdown, comments, commit bodies, quoted mail) or folded inside a word
# (quoted-printable soft breaks, RFC 5545/5322 folding, Swift line continuation).
# view_decode() and view_norm() rebuild the buffer in decoded, normalized form, one output line per
# input line, without leading comment or quote markers; view_norm() also reads every decimal digit as
# 0-9, folds compatibility forms (NFKC) and applies the deny list's FOLD lines. The private rules then
# run over these forms:
#   - every line joined to the next with one space (a wrap between words; a blank line stays a break),
#     as decoded, again with '+' before a letter read as a space (view_plus), and again with '/'
#     between words read as a space too (view_slash; not for rules whose pattern names '/', which
#     may exclude a path on purpose). A rule that needs a literal '/' or '+' still sees one in the
#     first reading. A match inside one line is reported at that line unless an allow entry covers
#     the original line; a match that crosses a break is reported at its first line;
#   - each pair of adjacent lines joined with nothing (a fold inside a word), and again without the
#     hyphen of a word hyphenated at the break (a letter, '-', a lower-case letter); a match that crosses
#     the join is reported at the first line of the pair, and a match inside one line that needs the
#     other line as context at that line. Short-tag rules skip this form: three letters plus context
#     taken from the next line would fire on ordinary code.
my %ENTITY = (
    nbsp => "\xC2\xA0", amp => '&', apos => "'", quot => '"', lt => '<', gt => '>', sol => '/', lowbar => '_',
    period => '.', hyphen => '-', dash => '-', commat => '@', num => '#', percnt => '%', plus => '+',
    rsquo => "\xE2\x80\x99", lsquo => "\xE2\x80\x98", rdquo => "\xE2\x80\x9D", ldquo => "\xE2\x80\x9C",
    ndash => "\xE2\x80\x93", mdash => "\xE2\x80\x94", shy => "\xC2\xAD", zwnj => "\xE2\x80\x8C",
    zwj => "\xE2\x80\x8D", ensp => ' ', emsp => ' ', thinsp => ' ', tab => ' ', newline => ' ',
);
my %QP_ASCII = map { $_ => 1 } (0x09, 0x20, 0x22, 0x27, 0x2C, 0x2D, 0x2E, 0x3D, 0x5F);
my $BREAK = "\n\0\n";    # a hard break: no rule pattern crosses a NUL between two newlines in practice

sub cp_utf8 {    # a code point as UTF-8 bytes; controls, surrogates and out-of-range points become a space
    my ($c) = @_;
    return ' ' if $c < 0x20 || $c == 0x7F || ($c >= 0xD800 && $c <= 0xDFFF) || $c > 0x10FFFF;
    return chr $c if $c < 0x80;
    return pack 'C2', 0xC0 | ($c >> 6), 0x80 | ($c & 0x3F) if $c < 0x800;
    return pack 'C3', 0xE0 | ($c >> 12), 0x80 | (($c >> 6) & 0x3F), 0x80 | ($c & 0x3F) if $c < 0x10000;
    return pack 'C4', 0xF0 | ($c >> 18), 0x80 | (($c >> 12) & 0x3F), 0x80 | (($c >> 6) & 0x3F), 0x80 | ($c & 0x3F);
}
sub hex_byte { my $c = hex $_[0]; return ($c < 0x20 || $c == 0x7F) ? ' ' : chr $c }

sub ew_decode {    # one RFC 2047 encoded word (Q or B); the charset is read as UTF-8 bytes
    my ($enc, $txt) = @_;
    my $b;
    if (lc $enc eq 'q') { ($b = $txt) =~ tr/_/ /; $b =~ s/=([0-9A-Fa-f]{2})/hex_byte($1)/ge }
    else { require MIME::Base64; $b = MIME::Base64::decode_base64($txt) }
    $b =~ s/[\x00-\x1F\x7F]/ /g;
    return $b;
}

sub qp_run {    # a run of quoted-printable =XX: decoded when it reads as text (UTF-8 bytes, space, quotes)
    my ($run) = @_;
    my @b = map { hex } $run =~ /=([0-9A-F]{2})/g;
    return $run if grep { $_ < 0x80 && !$QP_ASCII{$_} } @b;
    return join '', map { $_ == 0x09 ? ' ' : chr } @b;
}

sub view_decode {    # escapes and encodings; never adds or removes a newline
    my ($s) = @_;
    $s =~ s/\r(?=\n)//g;
    $s =~ s/\r/ /g;
    $s =~ s/(\?=)[ \t]+(?==\?)/$1/g;    # whitespace between adjacent encoded words is not text
    $s =~ s/=\?[A-Za-z0-9_.:*-]+\?([QqBb])\?([^?\s]*)\?=/ew_decode($1, $2)/ge;
    $s =~ s/((?:=[0-9A-F]{2})+)/qp_run($1)/ge;
    # string literals cut and concatenated, on one line or across a break: "ab" + "cd", 'ab' . 'cd'
    $s =~ s/(["'])[ \t]*(?:\+|\.)[ \t]*(\n)[ \t]*\1/$2/g;
    $s =~ s/(["'])[ \t]*(\n)[ \t]*(?:\+|\.)[ \t]*\1/$2/g;
    $s =~ s/(["'])[ \t]*(?:\+|\.)[ \t]*\1//g;
    $s =~ s/\\\(""\)|\$\{(?:""|'')\}//g;
    for (1 .. 2) {    # twice, for double encoding (&amp;#39;, %2520)
        # backslash escapes, also escaped again (JSON inside JSON writes \\u00e9 and \\n)
        $s =~ s/\\+[uU]([dD][89aAbB][0-9A-Fa-f]{2})\\+[uU]([dD][c-fC-F][0-9A-Fa-f]{2})/cp_utf8(0x10000 + ((hex($1) - 0xD800) << 10) + (hex($2) - 0xDC00))/ge;
        $s =~ s/\\+u\{([0-9A-Fa-f]{1,6})\}/cp_utf8(hex $1)/ge;
        $s =~ s/\\+U([0-9A-Fa-f]{8})/cp_utf8(hex $1)/ge;
        $s =~ s/\\+u([0-9A-Fa-f]{4})/cp_utf8(hex $1)/ge;
        $s =~ s/\\+x\{([0-9A-Fa-f]{1,6})\}/cp_utf8(hex $1)/ge;
        $s =~ s/\\+x([0-9A-Fa-f]{2})/hex_byte($1)/ge;
        # a written control escape (\n, \t, \r\n, \f, \b, \v, \0 in JSON, ICS, Swift and C strings) is
        # a break between words: one space, so the line count stays the same
        $s =~ s/\\+[nrtfbv0]/ /g;
        $s =~ s/\\+(['"\/,;:])/$1/g;
        $s =~ s/&amp;/&/gi;
        $s =~ s/&#0*([0-9]{1,7});?/cp_utf8($1)/ge;
        $s =~ s/&#[xX]0*([0-9A-Fa-f]{1,6});?/cp_utf8(hex $1)/ge;
        $s =~ s/&([A-Za-z]{2,8});/exists $ENTITY{lc $1} ? $ENTITY{lc $1} : "&$1;"/ge;
        $s =~ s/%([0-9A-Fa-f]{2})/hex_byte($1)/ge;
    }
    return $s;
}

my %DIGIT;
sub digit_of { require Unicode::UCD; my $v = Unicode::UCD::num($_[0]); return defined $v && $v =~ /\A[0-9]\z/ ? $v : $_[0] }

# One run of non-ASCII text in its folded form; a run that is not valid UTF-8 stays as it is. The same
# steps for every script: nothing here knows a language.
sub fold_run {
    my ($b) = @_;
    my $u = $b;
    return $b unless utf8::decode($u);
    # invisible format characters (zero-width characters, word joiner, BOM, soft hyphen, bidi marks) and
    # combining marks
    $u =~ s/[\p{Cf}\p{Mn}\p{Me}]//g;
    # curly quotes and apostrophe look-alikes (U+2018, U+2019, U+02BC, U+00B4, U+2032; U+201C, U+201D)
    # become straight quotes, before NFKC would split U+00B4; every rule that accepts a curly apostrophe
    # accepts the straight one
    $u =~ tr/\x{2018}\x{2019}\x{02BC}\x{00B4}\x{2032}\x{201C}\x{201D}/'''''""/;
    # compatibility forms (NFKC): fullwidth letters and digits, ligatures, presentation forms as PDF
    # copies produce them; then the marks they may bring back
    $u = Unicode::Normalize::NFKC($u);
    $u =~ s/[\p{Cf}\p{Mn}\p{Me}]//g;
    $u =~ s/[\p{Zs}\p{Zl}\p{Zp}]/ /g;                          # every Unicode space and separator
    $u =~ s/[\p{Pd}\x{2212}]/-/g;                              # dashes and the minus sign
    $u =~ s/(\p{Nd})/$DIGIT{$1} \/\/= digit_of($1)/ge;         # the decimal digits of every script as 0-9
    $u =~ s/$FOLD_RE/$FOLD{$1}/g if $FOLD_RE;                  # the deny list's FOLD lines
    utf8::encode($u);
    $u =~ s/[\x00-\x1F\x7F]/ /g;    # never a line break
    return $u;
}

sub view_norm {    # separators, invisible characters and line markers; never adds or removes a newline
    my ($s) = @_;
    $s =~ tr/\t/ /;
    $s =~ s/((?:[\xC2-\xDF][\x80-\xBF]|[\xE0-\xEF][\x80-\xBF]{2}|[\xF0-\xF4][\x80-\xBF]{3})+)/fold_run($1)/ge
      if $s =~ /[\x80-\xFF]/;
    $s =~ s/(?<=[A-Za-z\x80-\xFF])\*{1,3}(?=[A-Za-z\x80-\xFF])//g;    # emphasis inside a word
    $s =~ s/ {2,}/ /g;
    $s =~ s/ +$//mg;
    $s =~ s/(?:=|\\)$//mg;    # quoted-printable soft break, line continuation
    # leading space and comment or quote markers: // /* * # ; -- % > | and a list dash
    $s =~ s/^ *(?:(?:\/\/+!?|\/\*+|\*+\/?|#+|;+|--+|%+|>+|\|)(?= |$) *|- +)*//mg;
    return $s;
}

sub view_plus {    # '+' before a letter separates words (form encoding); before a digit it stays
    my ($s) = @_;
    $s =~ s/(?<=[A-Za-z0-9\x80-\xFF])\++(?=[A-Za-z\x80-\xFF])/ /g;
    $s =~ s/ {2,}/ /g;
    return $s;
}

sub view_slash {    # '/' between letters or digits separates words
    my ($s) = @_;
    $s =~ s/(?<=[A-Za-z0-9\x80-\xFF])\/+(?=[A-Za-z0-9\x80-\xFF])/ /g;
    $s =~ s/ {2,}/ /g;
    return $s;
}

sub space_join {    # (lines joined with one space, start offset of each line); a blank line is a hard break
    my ($L, $join) = @_;
    my ($j, @st) = ('');
    for my $k (0 .. $#$L) {
        $j .= ($join && length $L->[$k] && length $L->[$k - 1]) ? ' ' : $BREAK if $k;
        push @st, length $j;
        $j .= $L->[$k];
    }
    return ($j, \@st);
}

# The forms of a normalized buffer, with offsets. j1: lines joined with a space. j2: the same with
# '+' read as a space. j3: also '/' read as a space, for rules whose pattern has no '/' (one that
# names '/' may exclude a path on purpose). j0: each pair of adjacent lines joined with nothing.
sub view_forms {
    my ($t, $join) = @_;
    my @L = split /\n/, $t, -1;
    my %f = (L => \@L);
    @f{qw(j1 s1)} = space_join(\@L, $join);
    my $t2 = view_plus($t);
    my $t3 = view_slash($t2);
    @f{qw(j2 s2)} = $t2 eq $t ? ('', []) : space_join([ split /\n/, $t2, -1 ], $join);
    @f{qw(j3 s3)} = $t3 eq $t2 ? ('', []) : space_join([ split /\n/, $t3, -1 ], $join);
    my ($j0, @p0, @x0, @k0) = ('');
    if ($join) {
        for my $k (0 .. $#L - 1) {
            next unless length $L[$k] && length $L[$k + 1];
            # the pair as written, and for a word hyphenated at the break (a letter, '-', then a
            # lower-case letter on the next line) the pair without that hyphen
            my @first = ($L[$k]);
            push @first, substr($L[$k], 0, -1) if $L[$k] =~ /[A-Za-z\x80-\xFF]-\z/ && $L[$k + 1] =~ /\A[a-z]/;
            for my $a (@first) {
                $j0 .= $BREAK if length $j0;
                push @p0, length $j0;
                push @x0, length($j0) + length $a;
                push @k0, $k;
                $j0 .= $a . $L[$k + 1];
            }
        }
    }
    @f{qw(j0 p0 x0 k0)} = ($j0, \@p0, \@x0, \@k0);
    return \%f;
}

sub index_at {    # index of the last start offset at or before $o
    my ($st, $o) = @_;
    my ($lo, $hi) = (0, $#$st);
    while ($lo < $hi) { my $m = ($lo + $hi + 1) >> 1; if ($st->[$m] <= $o) { $lo = $m } else { $hi = $m - 1 } }
    return $lo;
}

sub unit_candidates {    # rule index -> { unit => 1 }: the lines (or pairs) of a form that hold a literal
    my ($j, $st) = @_;
    my %c;
    return \%c unless $LIT_RE && @$st;
    my $lc = lc $j;
    while ($lc =~ /$LIT_RE/g) {
        my $u = index_at($st, $-[0]);
        $c{$_}{$u} = 1 for @{ $LIT_OWNERS{$1} };
    }
    return \%c;
}

sub unit_windows {    # merged [first, last] unit ranges, $pad units on each side of every candidate
    my ($units, $pad, $max) = @_;
    my @w;
    for my $u (sort { $a <=> $b } @$units) {
        my ($a, $b) = ($u > $pad ? $u - $pad : 0, $u + $pad < $max ? $u + $pad : $max);
        if (@w && $a <= $w[-1][1] + 1) { $w[-1][1] = $b if $b > $w[-1][1] } else { push @w, [$a, $b] }
    }
    return @w;
}

# A rule with a literal set runs only on windows of its form around the units (lines, or pairs for
# j0) that hold one of its literals: two lines on each side for the joined forms, the pair itself for
# j0. A rule without one runs over the whole form.
sub scan_views {
    my ($buf, $ctx, $linenos, $base) = @_;
    my $bundle = ($ctx->{variant} || '') eq 'bundle';
    $base //= view_decode($buf);
    my ($orig, %v);    # %v: the forms per mask set (classes with structural allow entries differ)
    my $report = sub {
        my ($r, $k, $own) = @_;    # $own: a match inside one line, which an allow entry may cover
        if ($own) {
            $orig //= [ split /\n/, $buf, -1 ];
            return 0 if allowed($ctx->{key}, $r->{class}, $orig->[$k] // '');
        }
        $ctx->{on_hit}->($r, $linenos ? $linenos->[$k] : $k + 1);
        return 1;
    };
    for my $ri (@PRIV_IDX) {
        my $r = $CONTENT[$ri];
        my $mk = masks_for($r->{class}, $ctx->{key});
        my $view = $v{ $mk ? $r->{class} : '' } //= view_forms(view_norm($mk ? mask($base, $mk) : $base), !$bundle);
        my $re = $bundle ? $r->{re_bundle} : $r->{re};
        FORM: for my $form ('j1', 'j2', 'j3', 'j0') {
            my $j = $view->{$form};
            next unless length $j;
            next if $form eq 'j3' && $r->{slash};
            next if $form eq 'j0' && $r->{flags}{short};
            my $st = $view->{ $form eq 'j0' ? 'p0' : 's' . substr($form, 1) };
            next unless @$st;
            my @win = ([0, $#$st]);
            if ($r->{lits}) {
                my $c = ($view->{"c$form"} //= unit_candidates($j, $st))->{$ri} or next;
                @win = unit_windows([ keys %$c ], $form eq 'j0' ? 0 : 2, $#$st);
            }
            for my $w (@win) {
                my $off = $st->[ $w->[0] ];
                my $end = $w->[1] < $#$st ? $st->[ $w->[1] + 1 ] : length $j;
                my $sub = substr($j, $off, $end - $off);
                while ($sub =~ /$re/g) {
                    my ($s, $e) = ($-[0] + $off, $+[0] + $off);
                    if ($e == $s) { pos($sub) = $+[0] + 1; next }
                    my $done;
                    if ($form eq 'j0') {
                        # a match that crosses the join, or one that sits in one line but needs the
                        # other line as context (a lookaround), and so is not a match of that line alone
                        my $i = index_at($st, $s);
                        my ($x, $k) = ($view->{x0}[$i], $view->{k0}[$i]);
                        if ($s < $x && $e > $x) { $done = $report->($r, $k, 0) }
                        else {
                            my $line = $s < $x ? $k : $k + 1;
                            next if $view->{L}[$line] =~ $re;
                            $done = $report->($r, $line, 1);
                        }
                    } else {
                        my ($a, $b) = (index_at($st, $s), index_at($st, $e - 1));
                        $done = $report->($r, $a, $a == $b);
                    }
                    last FORM if $done && $ctx->{first_only};
                }
            }
        }
    }
}

# Raw bytes, bundle form of the rules: every printable run (split at control bytes, tab kept) is one
# line, so UTF-8 text and strings shorter than strings(1) shows are covered. The allow digest of a
# byte hit is that run. One report per rule.
sub scan_bytes {
    my ($buf, $ctx) = @_;
    (my $t = $buf) =~ s/$CTRL+/\n/g;
    scan_lines($t, { %$ctx, first_only => 1 });
}

sub textcheck {    # for image metadata values: any content rule at all
    my ($s) = @_;
    for my $r (@CONTENT) { return 1 if $s =~ $r->{re} }
    return 0;
}

sub is_binary { return index(substr($_[0], 0, 8000), "\0") >= 0 ? 1 : 0 }

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or return undef;
    local $/;
    my $b = <$fh>;
    close $fh;
    return defined $b ? $b : '';
}

# One file of a source tree (tree, staged, images, text, history blobs).
#   $rel: path for allow entries, SKIP and path rules; $loc: printed location prefix (already blanked)
sub scan_file {
    my ($rel, $loc, $bufref, %o) = @_;
    my $sink = $o{sink} || "fail";
    $SCANNED++ unless $o{no_count};
    unless ($o{no_name}) {    # the name itself, and the path rules
        scan_lines($rel, { key => $rel, on_hit => sub { record($_[0]{id}, $_[0]{class}, "$loc:0", $_[0]{flags}{short}, $sink, "$rel:0") } });
        for my $r (@PATHRULES) {
            next unless $rel =~ $r->{re};
            next if allowed($rel, $r->{class}, $rel);
            record($r->{id}, $r->{class}, "$loc:0", $r->{flags}{short}, $sink, "$rel:0");
        }
    }
    return if $o{name_only};
    my $bin = is_binary($$bufref);
    my $kind = CPImages::kind($$bufref);
    unless ($bin && CPImages::is_raster($kind)) {
        scan_lines($$bufref, { key => $rel, on_hit => sub {
            my ($r, $ln) = @_;
            record($r->{id}, $r->{class}, "$loc:$ln", $r->{flags}{short}, $sink, "$rel:$ln");
        }, }, $o{linenos});
    }
    if (($bin || $kind eq "pdf") && !$o{text_only}) {
        my $sha = sha256_hex($$bufref);
        my $rep = sub {
            my ($id, $where, $short) = @_;
            if (allowed($rel, "IMG", $sha)) { $ALLOWED{IMG}++; return }
            record($id, "IMG", $where, $short, $sink, $rel . substr($where, length $loc));
        };
        my $desc = CPImages::check($bufref, $loc, $rep, \&textcheck);
        push @EYE, "EYE $loc $desc";
    }
}

# ---------------------------------------------------------------- git helpers
sub git_out {    # list-form git call; returns stdout (raw) or undef on failure
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|');
    fatal("cannot fork") unless defined $pid;
    if (!$pid) { open STDERR, '>', '/dev/null'; exec 'git', @cmd; exit 127 }
    binmode $fh;
    local $/;
    my $out = <$fh>;
    close $fh;
    return $? == 0 ? (defined $out ? $out : '') : undef;
}

sub git_feed {    # list-form git call with stdin; returns stdout
    my ($in, @cmd) = @_;
    my $pid = open2(my $out, my $inp, 'git', @cmd);
    binmode $out;
    binmode $inp;
    # a child writes stdin while this process reads stdout, so large lists cannot deadlock
    my $w = fork();
    fatal("cannot fork") unless defined $w;
    if (!$w) { close $out; print $inp $in; close $inp; POSIX::_exit(0) }
    close $inp;
    local $/;
    my $res = <$out> // '';
    close $out;
    waitpid $w, 0;
    waitpid $pid, 0;
    return $res;
}

{
    my ($cpid, $cout, $cin);
    sub cat_open { my ($repo) = @_; $cpid = open2($cout, $cin, 'git', '-C', $repo, 'cat-file', '--batch'); binmode $cout; binmode $cin }
    sub cat_get {
        my ($name) = @_;
        print $cin "$name\n";
        $cin->flush;
        my $hdr = <$cout>;
        return undef if !defined $hdr || $hdr =~ / missing$/;
        my (undef, $type, $size) = split / /, $hdr;
        my ($data, $got) = ('', 0);
        while ($got < $size) { my $n = read($cout, $data, $size - $got, $got); last unless $n; $got += $n }
        read($cout, my $nl, 1);
        return $data;
    }
    sub cat_close { return unless $cpid; close $cin; close $cout; waitpid $cpid, 0; $cpid = undef }
}

sub export_ignored {    # hash of paths that carry export-ignore
    my ($repo, $paths, @extra) = @_;
    return {} unless @$paths;
    my $out = git_feed(join("\0", @$paths) . "\0", '-C', $repo, 'check-attr', @extra, '-z', '--stdin', 'export-ignore');
    my @f = split /\0/, $out, -1;
    my %ig;
    for (my $i = 0; $i + 2 < @f; $i += 3) { $ig{ $f[$i] } = 1 if $f[$i + 2] eq 'set' }
    return \%ig;
}

sub tar_names {    # member names of a tar stream (ustar + pax path records), as git archive writes it
    my ($tar) = @_;
    my ($p, %names, $pax_path) = (0);
    while ($p + 512 <= length $tar) {
        my $h = substr($tar, $p, 512);
        last if $h =~ /\A\0+\z/;
        my $name = unpack 'Z100', $h;
        my $size = oct(unpack('Z12', substr($h, 124, 12)) || 0);
        my $type = substr($h, 156, 1);
        my $prefix = substr($h, 257, 5) eq 'ustar' ? unpack('Z155', substr($h, 345, 155)) : '';
        $p += 512;
        my $data = substr($tar, $p, $size);
        $p += 512 * int(($size + 511) / 512);
        if ($type eq 'x') {
            while ($data =~ /\G([0-9]+) /gc) {
                my $len = $1;
                my $rec = substr($data, $-[0], $len);
                $pax_path = $1 if $rec =~ /\A[0-9]+ path=(.*)\n\z/s;
                pos($data) = $-[0] + $len;
            }
            next;
        }
        next if $type eq 'g';
        my $full = defined $pax_path ? $pax_path : (length $prefix ? "$prefix/$name" : $name);
        undef $pax_path;
        $names{$full} = 1 if $type eq '0' || $type eq "\0" || $type eq '2' || $type eq '7';
    }
    return \%names;
}

sub info { push @INFO, "INFO $_[0]" }

sub class_counts {
    my ($h) = @_;
    return join ' ', map { "$_=" . ($h->{$_} || 0) } grep { $h->{$_} } (@PRIVATE_ORDER, @GEN_ORDER, 'IMG');
}

# ---------------------------------------------------------------- tree / staged
sub scan_list {    # [[rel, getter]] with export-ignore set; hits in ignored files are info only
    my ($items, $ignored, $label) = @_;
    my %priv_files;
    for my $it (@$items) {
        my ($rel, $get) = @$it;
        my $buf = $get->();
        next unless defined $buf;
        my $ign = $ignored->{$rel} ? 1 : 0;
        my $before = scalar @HITS;
        my %ign_before = %IGN;
        scan_file($rel, disp($rel), \$buf, sink => ($ign ? 'ignored' : 'fail'));
        if ($ign) {
            $IGN_FILES{$rel} = 1 if grep { ($IGN{$_} || 0) != ($ign_before{$_} || 0) } keys %IGN;
        } else {
            for my $h (@HITS[$before .. $#HITS]) { $priv_files{$rel} = 1 if $PRIVATE_CLASS{ $h->[0] } }
        }
    }
    my $n_ign = scalar grep { $ignored->{ $_->[0] } } @$items;
    info("$label: " . scalar(@$items) . " files, $n_ign export-ignored");
    info("export-ignored files with hits (information only): " . scalar(keys %IGN_FILES) . " files, "
         . (class_counts(\%IGN) || 'none')) if $n_ign;
    info("archive files with deny-list hits that lack export-ignore: " . scalar(keys %priv_files)) if $PRIVATE_LOADED;
}

sub worktree_items {
    my ($dir) = @_;
    my $top = git_out('-C', $dir, 'rev-parse', '--show-toplevel');
    return undef unless defined $top;
    chomp $top;
    # an ignored folder inside a checkout (scratch space, an export) is scanned as plain files
    my $prefix = git_out('-C', $dir, 'rev-parse', '--show-prefix') // '';
    chomp $prefix;
    $prefix =~ s{/\z}{};
    return undef if length $prefix && defined git_out('-C', $top, 'check-ignore', '-q', '--', $prefix);
    my $ls = git_out('-C', $dir, 'ls-files', '-z', '--full-name', '--cached');
    fatal("git ls-files failed") unless defined $ls;
    my @paths = sort grep { length } split /\0/, $ls;
    my %u;
    @paths = grep { !$u{$_}++ } @paths;
    my $others = git_out('-C', $dir, 'ls-files', '-z', '--others', '--exclude-standard') // '';
    my $n_untracked = scalar grep { length } split /\0/, $others;
    info("untracked files not in the archive view (not scanned): $n_untracked") if $n_untracked;
    my @items;
    for my $p (@paths) {
        my $abs = "$top/$p";
        push @items, [$p, sub { -l $abs ? readlink($abs) : (-f $abs ? slurp($abs) : undef) }];
    }
    return (\@items, export_ignored($top, \@paths));
}

sub find_items {
    my ($dir) = @_;
    my @files;
    File::Find::find({ no_chdir => 1, wanted => sub { push @files, $File::Find::name if -f $_ || -l $_ } }, $dir);
    my @items;
    for my $f (sort @files) {
        (my $rel = $f) =~ s{\A\Q$dir\E/?}{};
        my $abs = $f;
        push @items, [$rel, sub { -l $abs ? readlink($abs) : slurp($abs) }];
    }
    return \@items;
}

sub ref_items {
    my ($repo, $ref) = @_;
    defined git_out('-C', $repo, 'rev-parse', '--verify', '--quiet', "$ref^{tree}")
      or fatal("not a directory and not a git ref in the current repository");
    my $ls = git_out('-C', $repo, 'ls-tree', '-r', '-z', '--full-tree', $ref) // fatal("git ls-tree failed");
    my (@items, @paths);
    cat_open($repo);
    for my $e (split /\0/, $ls) {
        next unless length $e;
        my ($meta, $path) = split /\t/, $e, 2;
        my ($mode, $type, $sha) = split / /, $meta;
        next unless $type eq 'blob';
        push @paths, $path;
        push @items, [$path, sub { cat_get($sha) }];
    }
    my $tar = git_out('-C', $repo, 'archive', '--format=tar', $ref) // fatal("git archive failed");
    my $names = tar_names($tar);
    my %ig = map { $_ => 1 } grep { !$names->{$_} } @paths;
    return (\@items, \%ig);
}

sub tree_mode {
    my $t = $O{targets}[0];
    if (-d $t) {
        my $abs = abs_path($t);
        my ($items, $ig) = worktree_items($abs);
        if ($items) { scan_list($items, $ig, 'tree (archive view of the checkout)') }
        else        { scan_list(find_items($abs), {}, 'tree (plain folder)') }
    } else {
        my ($items, $ig) = ref_items($O{repo}, $t);
        scan_list($items, $ig, 'tree (archive view of the ref)');
        cat_close();
    }
}

sub staged_mode {
    my $repo = $O{repo};
    my $ls = git_out('-C', $repo, 'ls-files', '-z', '-s') // fatal("not inside a git checkout");
    my (@items, @paths);
    cat_open($repo);
    for my $e (split /\0/, $ls) {
        next unless length $e;
        my ($meta, $path) = split /\t/, $e, 2;
        my ($mode, $sha, $stage) = split / /, $meta;
        next if $mode eq '160000';
        push @paths, $path;
        push @items, [$path, sub { cat_get($sha) }];
    }
    scan_list(\@items, export_ignored($repo, \@paths, '--cached'), 'staged (index)');
    cat_close();
}

# ---------------------------------------------------------------- text / images
sub text_mode {    # outgoing prose has no public file name, so only the content is checked
    for my $f (@{ $O{targets} }) {
        fatal("no such file for --text") unless -f $f;
        my $b = slurp($f);
        (my $base = $f) =~ s{.*/}{};
        scan_file($f, disp($base), \$b, text_only => 1, no_name => 1);
    }
    info("promo-class hits allowed by --promo: $PROMO_ALLOWED") if $O{promo};
}

sub images_mode {
    my @files;    # [name used for path rules and allow entries, source]
    if (@{ $O{targets} }) {
        for my $t (@{ $O{targets} }) {
            (my $base = $t) =~ s{/+\z}{};
            # a relative target keeps its spelling; an absolute one shows only its last component
            my $shown = $base =~ m{\A/} ? ($base =~ m{([^/]+)\z} ? $1 : $base) : $base;
            if (-d $t) {
                File::Find::find({ no_chdir => 1, wanted => sub {
                    return unless -f $_;
                    (my $sub = $File::Find::name) =~ s{\A\Q$base\E/}{};
                    push @files, ["$shown/$sub", $File::Find::name];
                } }, $base);
            } elsif (-f $t) { push @files, [$shown, $t] }
            else { fatal("no such path for --images") }
        }
    } else {
        my ($items) = worktree_items($O{repo});
        fatal("--images without paths needs to run inside a git checkout") unless $items;
        push @files, [$_->[0], $_->[1]] for @$items;
    }
    my $listed = 0;
    for my $f (sort { $a->[0] cmp $b->[0] } @files) {
        my ($rel, $src) = @$f;
        my $b = ref $src ? $src->() : slurp($src);
        next unless defined $b && (is_binary($b) || CPImages::kind($b) eq "pdf");
        $listed++;
        scan_file($rel, disp($rel), \$b);
    }
    info("non-text files listed for the eye check: $listed");
}

# ---------------------------------------------------------------- bundle
sub is_macho {
    my $m = substr($_[0], 0, 4);
    return 1 if $m eq "\xCF\xFA\xED\xFE" || $m eq "\xCE\xFA\xED\xFE" || $m eq "\xFE\xED\xFA\xCF" || $m eq "\xFE\xED\xFA\xCE";
    return 1 if ($m eq "\xCA\xFE\xBA\xBE" || $m eq "\xCA\xFE\xBA\xBF") && unpack('N', substr($_[0], 4, 4)) < 64;
    return 0;
}

sub macho_sections {    # [sectname, bytes] for the wanted sections of every slice
    my ($buf, $want) = @_;
    my @out;
    my $m = substr($buf, 0, 4);
    if ($m eq "\xCA\xFE\xBA\xBE" || $m eq "\xCA\xFE\xBA\xBF") {
        my $is64 = $m eq "\xCA\xFE\xBA\xBF";
        my $n = unpack 'N', substr($buf, 4, 4);
        for my $i (0 .. $n - 1) {
            my ($off, $size) = $is64 ? (unpack 'x8 Q> Q>', substr($buf, 8 + 32 * $i, 24))
                                     : (unpack 'x8 N N', substr($buf, 8 + 20 * $i, 16));
            next if !$size || $off + $size > length $buf;
            push @out, macho_sections(substr($buf, $off, $size), $want);
        }
        return @out;
    }
    my ($le, $is64);
    if    ($m eq "\xCF\xFA\xED\xFE") { ($le, $is64) = (1, 1) }
    elsif ($m eq "\xCE\xFA\xED\xFE") { ($le, $is64) = (1, 0) }
    elsif ($m eq "\xFE\xED\xFA\xCF") { ($le, $is64) = (0, 1) }
    elsif ($m eq "\xFE\xED\xFA\xCE") { ($le, $is64) = (0, 0) }
    else { return () }
    my ($L, $Q) = $le ? ('V', 'Q<') : ('N', 'Q>');
    my $ncmds = unpack $L, substr($buf, 16, 4);
    my $p = $is64 ? 32 : 28;
    for (1 .. $ncmds) {
        last if $p + 8 > length $buf;
        my ($cmd, $size) = unpack "$L$L", substr($buf, $p, 8);
        last if $size < 8;
        if (($is64 && $cmd == 0x19) || (!$is64 && $cmd == 0x1)) {
            my $nsects = unpack $L, substr($buf, $p + ($is64 ? 64 : 48), 4);
            my $s = $p + ($is64 ? 72 : 56);
            for (1 .. $nsects) {
                last if $s + ($is64 ? 80 : 68) > length $buf;
                my $sect = unpack 'Z16', substr($buf, $s, 16);
                my ($ssize, $soff) = $is64 ? (unpack($Q, substr($buf, $s + 40, 8)), unpack($L, substr($buf, $s + 48, 4)))
                                           : (unpack($L, substr($buf, $s + 36, 4)), unpack($L, substr($buf, $s + 40, 4)));
                push @out, [$sect, substr($buf, $soff, $ssize)] if $want->{$sect} && $soff && $soff + $ssize <= length $buf;
                $s += $is64 ? 80 : 68;
            }
        }
        $p += $size;
    }
    return @out;
}

sub cmd_out {    # list-form command, stdout only
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|');
    fatal("cannot fork") unless defined $pid;
    if (!$pid) { open STDERR, '>', '/dev/null'; exec @cmd; exit 127 }
    binmode $fh;
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : '';
}

sub cmd_out_in {    # cmd_out with a working folder
    my ($dir, @cmd) = @_;
    my $pid = open(my $fh, "-|");
    fatal("cannot fork") unless defined $pid;
    if (!$pid) { open STDERR, ">", "/dev/null"; chdir $dir or exit 126; exec @cmd; exit 127 }
    binmode $fh;
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : "";
}

# Swift mangling writes an identifier as its length and its text (13YayasCalendar10SampleDataV). This
# view puts spaces around each length-prefixed identifier, so context rules (short tags) see the
# identifier on its own: " YayasCalendar  SampleData V".
sub unmangle {
    my ($s) = @_;
    my ($o, $p) = ("", 0);
    while ($s =~ /(?<![0-9])([1-9][0-9]{0,3})(?=[A-Za-z_])/g) {
        my ($st, $n, $id0) = ($-[0], $1, $+[0]);
        next if $id0 + $n > length $s;
        my $id = substr($s, $id0, $n);
        next if $id =~ /[^A-Za-z0-9_]/;
        $o .= substr($s, $p, $st - $p) . " $id ";
        $p = $id0 + $n;
        pos($s) = $p;
    }
    return $o . substr($s, $p);
}

my $DEMANGLE;
sub bundle_mode {
    my @roots;
    for my $t (@{ $O{targets} }) {
        fatal("no such bundle folder") unless -d $t;
        push @roots, abs_path($t);
    }
    my @kept;
    for my $r (sort { length $a <=> length $b } @roots) {
        if (grep { index("$r/", "$_/") == 0 } @kept) { info("bundle nested in another bundle given, scanned once"); next }
        push @kept, $r;
    }
    $DEMANGLE = cmd_out('xcrun', '--find', 'swift-demangle');
    chomp $DEMANGLE;
    print STDERR "WARN: swift-demangle not found; symbol names are scanned mangled\n" unless length $DEMANGLE;
    my %want = map { $_ => 1 } qw(__swift5_reflstr __swift5_typeref);
    for my $root (@kept) {
        (my $base = $root) =~ s{.*/}{};
        my $prefix = @kept > 1 ? "$base/" : '';
        info("bundle " . disp($base));
        my @files;
        File::Find::find({ no_chdir => 1, wanted => sub { push @files, $File::Find::name if -f $_ || -l $_ } }, $root);
        for my $f (sort @files) {
            (my $rel = $f) =~ s{\A\Q$root\E/}{};
            my $key = "bundle:$prefix$rel";
            my $loc = "bundle:" . disp("$prefix$rel");
            $SCANNED++;
            # one report per rule and file, under the first section that sees it (strings, bytes,
            # unmangled, symbols, then the Swift sections), so "bytes" means invisible to strings(1)
            # The decoded forms run on names, plists and text resources only. Mach-O output and raw bytes
            # skip them: a binary keeps string literals as plain UTF-8, and there the forms made the
            # scan of the app about ten times slower.
            my %got;
            my $mk = sub { my ($sec) = @_; return { key => $key, variant => 'bundle', first_only => 1,
                no_views => ($sec =~ /\A(?:name|plist|text)\z/ ? 0 : 1), on_hit => sub {
                my ($r) = @_;
                return if $got{ $r->{id} }++;
                record($r->{id}, $r->{class}, "$loc:$sec", $r->{flags}{short}, undef, "$key:$sec");
            } } };
            scan_lines("$prefix$rel", $mk->('name'));
            for my $r (@PATHRULES) { record($r->{id}, $r->{class}, "$loc:name", $r->{flags}{short}, undef, "$key:name") if "$prefix$rel" =~ $r->{re} }
            next if -l $f;
            my $buf = slurp($f);
            next unless defined $buf;
            if (is_macho($buf)) {
                # strings and nm run from the file folder: nm prints the path it was given for a universal binary
                (my $dir = $f) =~ s{/[^/]+\z}{};
                (my $exe = $f) =~ s{.*/}{./};
                scan_lines(cmd_out_in($dir, 'strings', '-a', '-n', '4', $exe), $mk->('strings'));
                (my $runs = $buf) =~ s/$CTRL+/\n/g;
                scan_lines($runs, $mk->('bytes'));
                scan_lines(unmangle($runs), $mk->('unmangled'));
                my $nm = cmd_out_in($dir, 'nm', '-a', $exe);
                my $local = 0;
                for (split /\n/, $nm) { $local++ if /\A\s*[0-9A-Fa-f]*\s+([a-z-])\s/ }
                info("local symbols $local in $loc (near zero after a release strip)");
                my $sym = length $DEMANGLE ? cmd_out_in($dir, '/bin/sh', '-c', 'nm -a "$1" 2>/dev/null | "$2"', 'sh', $exe, $DEMANGLE) : $nm;
                scan_lines($sym, $mk->('symbols'));
                for my $s (macho_sections($buf, \%want)) {
                    (my $t = $s->[1]) =~ s/$CTRL+/\n/g;
                    (my $name = $s->[0]) =~ s/\A__swift5_//;
                    scan_lines($t, $mk->($name));
                }
            } elsif ($rel =~ /\.plist\z/ || $rel =~ m{(?:\A|/)CodeResources\z} || substr($buf, 0, 8) eq 'bplist00') {
                my $xml = substr($buf, 0, 8) eq 'bplist00' ? cmd_out('plutil', '-convert', 'xml1', '-o', '-', $f) : $buf;
                scan_lines($xml, $mk->('plist'));
            } elsif (is_binary($buf)) {
                my $kind = CPImages::kind($buf);
                if (CPImages::is_raster($kind) || $kind eq 'pdf') {
                    my $sha = sha256_hex($buf);
                    my $rep = sub {
                        my ($id, $where, $short) = @_;
                        if (allowed($key, 'IMG', $sha)) { $ALLOWED{IMG}++; return }
                        record($id, 'IMG', $where, $short, undef, $key . substr($where, length $loc));
                    };
                    push @EYE, "EYE $loc " . CPImages::check(\$buf, $loc, $rep, \&textcheck);
                }
                scan_bytes($buf, $mk->('bytes')) unless CPImages::is_raster($kind);
            } else {
                scan_lines($buf, $mk->('text'));
            }
        }
    }
    push @INFO, "CAVEAT Swift string literals of 15 bytes or fewer can be stored inside instructions and stay "
      . "invisible to strings and byte scans: the source scan (--tree) is the real control, this is a second net.";
}

# ---------------------------------------------------------------- history
sub unquote_path {
    my ($p) = @_;
    return $p unless $p =~ /\A"(.*)"\z/s;
    my $s = $1;
    my %esc = (n => "\n", t => "\t", a => "\a", b => "\b", f => "\f", r => "\r", v => "\013");
    $s =~ s{\\([0-7]{3}|.)}{length($1) == 3 ? chr(oct $1) : (exists $esc{$1} ? $esc{$1} : $1)}ge;
    return $s;
}

sub git_diff_path {    # "a/X b/X" or "\"a/X\" \"b/X\"" (renames are off, so both halves name one path)
    my ($rest) = @_;
    if ($rest =~ /\A"a\/.*" ("b\/.*")\z/s) { my $p = unquote_path($1); $p =~ s{\Ab/}{}; return $p }
    return undef if (length($rest) - 1) % 2;
    my $h = (length($rest) - 1) / 2;
    my ($x, $y) = (substr($rest, 0, $h), substr($rest, $h + 1));
    return ($x =~ s{\Aa/}{} && $y =~ s{\Ab/}{} && $x eq $y) ? $y : undef;
}

sub history_mode {
    my $gd = $O{targets}[0];
    fatal("no such git directory or checkout") unless -e $gd;
    my @g = (-f "$gd/HEAD" && -d "$gd/objects") ? ("--git-dir=$gd") : ('-C', $gd);
    defined git_out(@g, 'rev-parse', '--git-dir') or fatal("not a git repository");

    my %ident;
    if (length $IDENTITY && -r $IDENTITY) {
        open my $ih, '<', $IDENTITY or fatal("cannot read the identity allow file");
        while (my $l = <$ih>) { $l =~ s/\r?\n\z//; next unless length $l; $ident{$l} = 1 }
        close $ih;
        fatal("identity allow file: expected 'name<TAB>email' lines") unless %ident && !grep { !/\A[^\t]+\t[^\t]+\z/ } keys %ident;
    } elsif ($O{strict}) {
        fatal("--strict --history needs the identity allow file (set YC_ALLOW_IDENTITY or name it in a USE line of the deny list)");
    } else {
        print STDERR "WARN: identity allow file not found; author and committer are not checked\n";
    }

    if ($O{refs}) {
        my $refs = git_out(@g, 'for-each-ref', '--format=%(refname)') // fatal("git for-each-ref failed");
        my $n = 0;
        for my $ref (split /\n/, $refs) {
            $n++;
            next if $ref =~ m{\Arefs/(?:heads|tags|remotes)/};
            record('REF-01', 'REF', 'ref:' . disp($ref) . ':0', 0, undef, "ref:$ref");
        }
        info("refs checked: $n (refs/heads, refs/tags and remote-tracking refs pass)");
    }

    my @range = length $O{range} ? ($O{range}) : ('--all');
    my $fmt = '--format=%x01C %H%n%x01A %an%x09%ae%n%x01K %cn%x09%ce%n%x01M%n%B%n%x01E';
    my $pid = open(my $lh, '-|');
    fatal("cannot fork") unless defined $pid;
    if (!$pid) {
        open STDERR, '>', '/dev/null';
        exec 'git', @g, '-c', 'core.quotePath=false', 'log', @range, '--no-color', '--no-ext-diff', '--no-textconv',
          '-p', '-U0', '--cc', '--no-renames', $fmt;
        exit 127;
    }
    binmode $lh;
    my ($sha, $short, $file, $np, $newln, @msg, @added, @addln, @binaries);
    my $state = '';
    my $commits = 0;
    my $flush = sub {
        return unless @added;
        my $f = $file;
        my $loc = "history:$short/" . disp($f);
        scan_lines(join("\n", @added), { key => $f, on_hit => sub {
            my ($r, $ln) = @_;
            record($r->{id}, $r->{class}, "$loc:$ln", $r->{flags}{short}, undef, "history:$short/$f:$ln");
        } }, [@addln]);
        @added = ();
        @addln = ();
    };
    my $newfile = sub {
        my ($p) = @_;
        $flush->();
        $file = $p;
        $np = 1;
        $state = 'filehdr';
        scan_file($p, "history:$short/" . disp($p), \'', name_only => 1, no_count => 1) if defined $p && $p ne '/dev/null';
    };
    while (my $line = <$lh>) {
        $line =~ s/\n\z//;
        if ($line =~ /\A\x01C ([0-9a-f]{7,64})\z/) {
            $flush->();
            ($sha, $short, $state, $file) = ($1, substr($1, 0, 12), 'hdr', undef);
            $commits++;
            next;
        }
        if ($state eq 'hdr' && $line =~ /\A\x01([AK]) (.*)\z/s) {
            my ($who, $id) = ($1 eq 'A' ? 'author' : 'committer', $2);
            record($who eq 'author' ? 'IDENT-01' : 'IDENT-02', 'IDENT', "history:$short/$who:0") if %ident && !$ident{$id};
            next;
        }
        if ($state eq 'hdr' && $line eq "\x01M") { $state = 'msg'; @msg = (); next }
        if ($state eq 'msg') {
            if ($line eq "\x01E") {
                scan_lines(join("\n", @msg), { key => "history:$short/message", on_hit => sub {
                    my ($r, $ln) = @_;
                    record($r->{id}, $r->{class}, "history:$short/message:$ln", $r->{flags}{short});
                } });
                $state = 'diff';
                next;
            }
            push @msg, $line;
            next;
        }
        next unless ($state eq 'diff' || $state eq 'filehdr' || $state eq 'hunk');
        if ($line =~ /\Adiff --git (.*)\z/) { $newfile->(git_diff_path($1)); next }
        if ($line =~ /\Adiff --(?:cc|combined) (.*)\z/) { $newfile->(unquote_path($1)); next }
        if ($state eq 'filehdr') {
            if ($line =~ /\A\+\+\+ (.*)\z/) {
                my $p = unquote_path($1);
                $p =~ s{\Ab/}{};
                $file = $p unless $p eq '/dev/null';
                next;
            }
            if ($line =~ /\ABinary files .* and (.*) differ\z/) {
                my $p = unquote_path($1);
                $p =~ s{\Ab/}{};
                push @binaries, [$sha, $short, $p] unless $p eq '/dev/null';
                next;
            }
        }
        if ($line =~ /\A(@@+) -.*? \+([0-9]+)(?:,[0-9]+)? \1/) {
            $np = length($1) - 1;
            $newln = $2;
            $state = 'hunk';
            next;
        }
        if ($state eq 'hunk') {
            next if substr($line, 0, 1) eq '\\';
            my $pre = substr($line, 0, $np);
            next if $pre =~ /-/;
            if ($pre =~ /\+/) { push @added, substr($line, $np); push @addln, $newln }
            $newln++;
        }
    }
    close $lh;
    $flush->();
    fatal("git log failed") if $? != 0 && !$commits;

    if (@binaries) {
        my $repo_arg = $g[0] eq '-C' ? $g[1] : do { (my $x = $g[0]) =~ s/\A--git-dir=//; $x };
        cat_open($repo_arg);
        for my $b (@binaries) {
            my ($s, $sh, $p) = @$b;
            my $data = cat_get("$s:$p");
            next unless defined $data;
            scan_file($p, "history:$sh/" . disp($p), \$data);
        }
        cat_close();
    }

    if (!length $O{range}) {    # annotated tags: tagger and message
        my $tags = git_out(@g, 'for-each-ref', '--format=%(objecttype) %(objectname)', 'refs/tags') // '';
        for my $t (split /\n/, $tags) {
            my ($type, $obj) = split / /, $t;
            next unless $type eq 'tag';
            my $body = git_out(@g, 'cat-file', 'tag', $obj) // next;
            my ($hdr, $msg) = split /\n\n/, $body, 2;
            my $sh = substr($obj, 0, 12);
            if ($hdr =~ /^tagger (.*) <([^>]*)> [0-9]+ [-+][0-9]{4}$/m) {
                record('IDENT-03', 'IDENT', "history:tag-$sh/tagger:0") if %ident && !$ident{"$1\t$2"};
            }
            scan_lines($msg // '', { key => "history:tag-$sh/message", on_hit => sub {
                my ($r, $ln) = @_;
                record($r->{id}, $r->{class}, "history:tag-$sh/message:$ln", $r->{flags}{short});
            } });
        }
    }
    $SCANNED = $commits;
    info("history: $commits commits" . (length $O{range} ? " in the given range" : " on every ref")
         . ", " . scalar(@binaries) . " binary blobs parsed");
}

# ---------------------------------------------------------------- secrets (Tools/check-secrets.sh)
sub secrets_mode {
    my @sec = grep { $_->{class} eq 'GEN-SECRET' } @CONTENT;
    fatal("no GEN-SECRET rules in the public rules file") unless @sec;
    local $/ = "\0";
    while (my $f = <STDIN>) {
        chomp $f;
        next unless length $f && -f $f;
        my $b = slurp($f);
        next unless defined $b;
        for my $r (@sec) { if ($b =~ $r->{re}) { print "$f\n"; last } }
    }
}

# ---------------------------------------------------------------- main
if    ($O{mode} eq 'tree')    { tree_mode() }
elsif ($O{mode} eq 'staged')  { staged_mode() }
elsif ($O{mode} eq 'bundle')  { bundle_mode() }
elsif ($O{mode} eq 'history') { history_mode() }
elsif ($O{mode} eq 'images')  { images_mode() }
elsif ($O{mode} eq 'text')    { text_mode() }

info("lines allowed by the allow files: " . class_counts(\%ALLOWED)) if %ALLOWED;
print "$_\n" for @INFO;
print "$_\n" for @EYE;
my %count;
for my $h (sort { $a->[2] cmp $b->[2] || $a->[3] cmp $b->[3] } @HITS) {
    print "$h->[1]\n";
    $count{ $h->[0] }++;
}
my @classes = ((map { $PRIVATE_LOADED ? $_ : () } @PRIVATE_ORDER), @GEN_ORDER, 'IMG', 'IDENT', 'REF');
my $exit = @HITS ? 1 : 0;
print "SUMMARY mode=$O{mode} scanned=$SCANNED hits=" . scalar(@HITS) . ' '
  . join(' ', map { "$_=" . ($count{$_} || 0) } @classes)
  . ' private=' . ($PRIVATE_LOADED ? 'loaded' : 'missing') . " exit=$exit\n";
exit $exit;
