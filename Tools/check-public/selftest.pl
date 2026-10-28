#!/usr/bin/perl
# Tools/check-public/selftest.pl: run by `Tools/check-public.sh --self-test`.
#
# Plants every kind of hit at run time under .work/check-public-selftest/ (gitignored), runs the checker
# on it and asserts that each plant is reported under the right rule id and that clean controls pass.
# Generic plants are assembled here by string concatenation; deny-list plants come from the private
# probe file (one hit and one miss sample per rule) read at run time, or from a sample generated from
# the rule itself. No hit string is committed, and the output names case names and rule ids only.
# Without the private deny list the deny-list cases are skipped and reported as skipped.
# The folder is removed at the end unless YC_SELFTEST_KEEP=1.
use strict;
use warnings;
use Compress::Raw::Zlib ();
use Digest::SHA qw(sha256_hex);
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);

my $HOME_PREFIX;
BEGIN { $HOME_PREFIX = '/Use' . 'rs/' }
sub scrub_msg {    # no absolute tool path or home folder in a message
    my ($w) = @_;
    my $here = __FILE__;
    $here =~ s{/[^/]+\z}{};
    $w =~ s/\Q$here\E/<tools>/g if length $here > 1;
    $w =~ s/\Q$ENV{HOME}\E/~/g if defined $ENV{HOME} && length $ENV{HOME} > 1;
    $w =~ s{\Q$HOME_PREFIX\E[^/\s]+}{$HOME_PREFIX<user>}g;
    return $w;
}
BEGIN {    # set at compile time, so compile-time warnings go through it too
    $SIG{__WARN__} = sub {
        my $w = shift;
        $w = "internal warning withheld (it may quote a rule)\n" if $w =~ /regex|HERE|\bm\//i;
        print STDERR "WARN: " . scrub_msg($w);
    };
    $SIG{__DIE__} = sub { die(ref $_[0] ? $_[0] : scrub_msg($_[0])) };
}

my $CP     = $ENV{CP_SCRIPT} or die "run this through Tools/check-public.sh --self-test\n";
my $TOOLS  = $ENV{CP_TOOLS};
my $D      = $ENV{CP_SELFTEST_DIR};
my $DENY   = $ENV{CP_DENY} // '';
my $PROBES = $ENV{CP_PROBES} // '';
my $NONE   = "$D/does-not-exist";

umask 077;
remove_tree($D) if -e $D;
make_path($D) or die "cannot create the self-test folder\n";
$ENV{GIT_CEILING_DIRECTORIES} = $D;    # planted folders never see the surrounding checkout
$ENV{GIT_CONFIG_GLOBAL}       = '/dev/null';
$ENV{GIT_CONFIG_NOSYSTEM}     = '1';
wfile("$D/private-allow.txt", '');
my %ME = (name => 'Self Test', email => 'selftest@example.com');
my %STRANGER = (name => 'Someone Else', email => 'someone@example.org');

my ($PASS, $FAIL, $SKIP) = (0, 0, 0);
sub ok   { my ($c, $n) = @_; if ($c) { $PASS++; print "PASS $n\n" } else { $FAIL++; print "FAIL $n\n" } return $c }
sub skip { my ($n, $why) = @_; $SKIP++; print "SKIP $n ($why)\n" }

# ---------------------------------------------------------------- private rules and probes
# The deny list's classes are opaque ids; the self-test reads what it needs from their properties
# (CLASS lines): sub, promo, and the shape hints name and term. FOLD lines give the letter variants.
my $HAVE_PRIV = length $DENY && -f $DENY && -r $DENY;
my (@PR, %PR, %HITP, %MISSP, @GLOBAL_MISS, %PROP, %FOLDS);
sub prop { my ($r, $p) = @_; return $PROP{ $r->{class} } && $PROP{ $r->{class} }{$p} ? 1 : 0 }
if ($HAVE_PRIV) {
    open my $fh, '<', $DENY or die "cannot read the deny list\n";
    while (my $l = <$fh>) {
        next if $l =~ /\A\s*(?:#|\z)/;
        $l =~ s/\r?\n\z//;
        my ($id, $class, $flags, $pat) = split /\t/, $l, 4;
        if ($id eq 'CLASS') { $PROP{$class}{$_} = 1 for grep { $_ ne '-' } split /,/, $flags; next }
        if ($id eq 'USE') { $PROBES = ($flags =~ m{\A/} ? $flags : do { (my $d = $DENY) =~ s{/[^/]*\z}{}; "$d/$flags" }) if $class eq 'probes' && !length $PROBES; next }
        if ($id eq 'FOLD') {
            my ($f, $t) = map { /\AU\+([0-9A-Fa-f]+)\z/ ? chr hex $1 : '' } $class, $flags;
            $FOLDS{$f} = $t if length $f;
            next;
        }
        my %fl = map { $_ => 1 } split /,/, $flags;
        $pat = "\\b(?:$pat)\\b" if $fl{w};
        my $re = do { local $SIG{__WARN__} = sub { }; eval { $fl{i} ? qr/$pat/i : qr/$pat/ } };
        next unless $re;
        my $r = { id => $id, class => $class, flags => \%fl, re => $re, pat => $pat };
        push @PR, $r;
        $PR{$id} = $r;
    }
    close $fh;
    if (length $PROBES && -f $PROBES && open my $ph, '<', $PROBES) {
        while (my $l = <$ph>) {
            next if $l =~ /\A\s*(?:#|\z)/;
            $l =~ s/\r?\n\z//;
            my ($id, $exp, $text) = split /\t/, $l, 3;
            next unless defined $text && length $text;
            if ($id eq '*') { push @GLOBAL_MISS, $text; next }
            if ($exp eq 'hit') { push @{ $HITP{$id} }, $text } else { push @{ $MISSP{$id} }, $text }
        }
        close $ph;
    }
    for my $r (@PR) {    # a rule without a hit probe gets a generated sample, if one matches
        next if $HITP{ $r->{id} } && grep { $_ =~ $r->{re} } @{ $HITP{ $r->{id} } };
        my $s = gen_sample($r->{pat});
        $HITP{ $r->{id} } = [$s] if defined $s && $s =~ $r->{re};
        $HITP{ $r->{id} } = [" $s "] if defined $s && $s !~ $r->{re} && " $s " =~ $r->{re};
    }
}
sub fires_private { my ($t) = @_; return grep { $t =~ $_->{re} } @PR }

# ---------------------------------------------------------------- helpers
sub wfile {
    my ($path, $data) = @_;
    (my $dir = $path) =~ s{/[^/]+\z}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "cannot write a planted file\n";
    print $fh $data;
    close $fh;
}

sub run_cmd {    # (\@cmd, %o) -> (exit, output)
    my ($cmd, %o) = @_;
    my $pid = open(my $fh, '-|');
    die "cannot fork\n" unless defined $pid;
    if (!$pid) {
        for my $k (keys %{ $o{env} || {} }) {
            if (defined $o{env}{$k}) { $ENV{$k} = $o{env}{$k} } else { delete $ENV{$k} }
        }
        chdir $o{cwd} or exit 126 if $o{cwd};
        open STDERR, '>&', \*STDOUT;
        exec @$cmd;
        exit 127;
    }
    local $/;
    my $out = <$fh> // '';
    close $fh;
    return ($? >> 8, $out);
}

sub run_cp {    # (\@args, priv => 0|1, env => {}, cwd => dir) -> (exit, [[rule, location]], output)
    my ($args, %o) = @_;
    # the private allow file is the self-test's own (empty unless a case writes one), so cases never
    # depend on the maintainer's reviewed exceptions
    my %env = (YC_DENYLIST => ($o{priv} && $HAVE_PRIV ? $DENY : $NONE), YC_ALLOW_IDENTITY => "$D/identity.txt",
               YC_PRIVATE_ALLOW => "$D/private-allow.txt", YC_DENYLIST_PROBES => undef,
               YC_PUBLIC_RULES => undef, YC_PUBLIC_ALLOW => undef, YC_NO_PREFILTER => undef, %{ $o{env} || {} });
    my ($rc, $out) = run_cmd(['/bin/bash', $CP, @$args], env => \%env, cwd => $o{cwd});
    my @hits;
    for (split /\n/, $out) { push @hits, [$1, $2] if /\A((?:[A-Z][A-Z0-9]*-)+[0-9]{2}) (.*?)(?: REVIEW-BY-EYE)?\z/ }
    return ($rc, \@hits, $out);
}

sub has { my ($h, $rule, $loc) = @_; return scalar grep { $_->[0] eq $rule && (!defined $loc || $_->[1] =~ $loc) } @$h }

sub git {
    my ($dir, @a) = @_;
    my ($rc) = run_cmd(['git', '-C', $dir, @a]);
    die "git step failed in the self-test\n" if $rc;
}

sub commit {
    my ($dir, $msg, $who) = @_;
    $who ||= \%ME;
    local $ENV{GIT_AUTHOR_NAME} = $who->{name};
    local $ENV{GIT_AUTHOR_EMAIL} = $who->{email};
    local $ENV{GIT_COMMITTER_NAME} = $who->{name};
    local $ENV{GIT_COMMITTER_EMAIL} = $who->{email};
    local $ENV{GIT_AUTHOR_DATE} = '2026-01-01T00:00:00Z';
    local $ENV{GIT_COMMITTER_DATE} = '2026-01-01T00:00:00Z';
    git($dir, 'add', '-A');
    git($dir, 'commit', '-q', '--no-verify', '-m', $msg);
}

sub new_repo { my ($dir) = @_; make_path($dir); git($dir, 'init', '-q', '-b', 'main'); }

sub wrap_middle {    # a hard wrap at the middle space between two letters, each line prefixed with $pre
    my ($s, $pre) = @_;
    my @pos;
    while ($s =~ /(?<=[A-Za-z\x80-\xFF]) (?=[A-Za-z\x80-\xFF])/g) { push @pos, $-[0] }
    return undef unless @pos;
    my $p = $pos[ int($#pos / 2) ];
    return $pre . substr($s, 0, $p) . "\n" . $pre . substr($s, $p + 1);
}

sub wrapped_probe {    # [rule, wrapped text] for a probe that no line of its wrapped form matches alone
    my ($class) = @_;
    for my $id (sort keys %HITP) {
        my $r = $PR{$id} or next;
        next if $r->{flags}{short} || (defined $class && $r->{class} ne $class);
        for my $t (@{ $HITP{$id} }) {
            my $w = wrap_middle($t, q{}) // next;
            next if grep { $_ =~ $r->{re} } split /\n/, $w;
            return [$id, $w];
        }
    }
    return undef;
}

# ---------------------------------------------------------------- binary builders
sub zlib {
    my ($d) = @_;
    my ($z) = Compress::Raw::Zlib::Deflate->new(-AppendOutput => 1);
    my $o = '';
    $z->deflate($d, $o);
    $z->flush($o);
    return $o;
}
sub chunk { my ($t, $d) = @_; return pack('N', length $d) . $t . $d . pack('N', Compress::Raw::Zlib::crc32($t . $d)) }
sub png {
    my (@extra) = @_;
    return "\x89PNG\r\n\x1a\n" . chunk('IHDR', pack('NNCCCCC', 1, 1, 8, 0, 0, 0, 0)) . join('', @extra)
      . chunk('IDAT', zlib("\0\0")) . chunk('IEND', '');
}
sub icc {    # minimal ICC profile with one 'desc' tag
    my ($desc) = @_;
    my $tag = 'desc' . ("\0" x 4) . pack('N', length($desc) + 1) . $desc . "\0" . ("\0" x 79);
    my $off = 128 + 4 + 12;
    return pack('N', $off + length $tag) . ("\0" x 124) . pack('N', 1) . 'desc' . pack('NN', $off, length $tag) . $tag;
}
sub iccp { my ($desc) = @_; return chunk('iCCP', "ICC Profile\0\0" . zlib(icc($desc))) }
sub icns { my ($png) = @_; return 'icns' . pack('N', 16 + length $png) . 'ic10' . pack('N', 8 + length $png) . $png }
sub seg { my ($m, $d) = @_; return "\xFF" . chr($m) . pack('n', length($d) + 2) . $d }
sub jpeg {
    my (@extra) = @_;
    return "\xFF\xD8" . seg(0xE0, "JFIF\0\x01\x01\0\0\x01\0\x01\0\0") . join('', @extra)
      . seg(0xC0, pack('CnnC', 8, 1, 1, 1) . pack('CCC', 1, 0x11, 0))
      . seg(0xDA, pack('C', 1) . pack('CC', 1, 0) . pack('CCC', 0, 63, 0)) . "\x12\x34\xFF\x00\x56" . "\xFF\xD9";
}
sub pdf {
    my ($info, $extra) = @_;
    return "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n"
      . ($extra // '') . "3 0 obj\n<< $info >>\nendobj\ntrailer\n<< /Root 1 0 R /Info 3 0 R >>\n%%EOF\n";
}
sub xmp_obj {
    my $packet = '<?xpa' . 'cket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmp' . 'meta xmlns:x="adobe:ns:meta/"/>';
    return "4 0 obj\n<< /Type /Metadata /Subtype /XML /Length " . length($packet) . " >>\nstream\n$packet\nendstream\nendobj\n";
}

# Plants are assembled from parts with join, not with the . operator: the decoded forms read
# concatenated string literals as one string, so "a" . "b" would plant a hit in this file.
sub j { return join q{}, @_ }
# ---------------------------------------------------------------- generic samples (assembled here)
my @GEN = (
    ['GEN-PATH-01',   j('open ', '/Use', 'rs/', 'jdoe', '/Library/notes.txt')],
    ['GEN-MAIL-01',   j('write to ', 'jane.doe', '@', 'orbitrail', '.io today')],
    ['GEN-TZ-01',     j('TimeZone(identifier: "', 'Asia', '/', 'Kolkata', '")')],
    ['GEN-MEET-01',   j('https://', 'us02web.', 'zoom', '.us/j/', '8475930261')],
    ['GEN-MEET-02',   j('https://', 'zoom', '.us/my/', 'jdoe.room')],
    ['GEN-MEET-03',   j('https://', 'meet', '.google.com/', 'kqz-rtyp-wvx')],
    ['GEN-MEET-04',   j('https://', 'teams', '.microsoft.com/meet/', '2849173650123')],
    ['GEN-MEET-05',   j('https://', 'teams', '.microsoft.com/l/meetup-join/19%3a', 'meeting_', 'NzQ1YTk2ZGUtOWQ')],
    ['GEN-MEET-06',   j('https://', 'meet', '.goto.com/', '584736291')],
    ['GEN-MEET-07',   j('https://', 'chime', '.aws/', '5839201746')],
    ['GEN-MEET-08',   j('https://', 'orbitrail', '.webex.com/meet/', 'jdoe')],
    ['GEN-MEET-09',   j('https://', 'orbitrail', '.webex.com/orbitrail/', 'j.php?MTID=', 'm8a7b6c5d4e3f2a1b')],
    ['GEN-SECRET-01', 'GOC' . 'SPX-' . ('k' x 28)],
    ['GEN-SECRET-02', '123456789012' . '-' . ('a1' x 16) . '.apps.' . 'googleusercontent' . '.com'],
    ['GEN-SECRET-03', 'ya' . '29.' . ('A0_' x 10)],
    ['GEN-SECRET-04', '1/' . '/0' . ('gX' x 15)],
    ['GEN-SECRET-05', 'A' . 'Iza' . ('Sy0_' x 9)],
    ['GEN-SECRET-06', '-----BEGIN ' . 'RSA ' . 'PRIV' . 'ATE KEY-----'],
    ['GEN-SECRET-07', 'gh' . 'p_' . ('Ab1' x 12)],
    ['GEN-SECRET-08', 'github' . '_pat_' . ('11AB' x 6)],
    ['GEN-SECRET-09', 'xo' . 'xb-' . '1234567890-' . 'abcdefABCDEF'],
    ['GEN-SECRET-10', 'xa' . 'pp-' . '1-' . 'A0B1C2D3E4F5'],
);
my %GEN = map { $_->[0] => $_->[1] } @GEN;
my @CLEAN = (
    'mail ' . 'someone' . '@' . 'example' . '.com, ' . 'x' . '@' . 'mail.example' . ', y' . '@' . 'host.test',
    'icon' . '@' . '2x' . '.png',
    'TimeZone(identifier: "' . 'Europe' . '/' . 'London' . '"), "' . 'America' . '/' . 'New_York' . '", UTC',
    'https://' . 'zoom' . '.us/j/' . '1234567890' . ' https://' . 'meet' . '.google.com/' . 'abc-defg-hij',
    'path ' . '/Use' . 'rs/' . 'Shared' . '/x and ~/Library',
    'hello world',
);

# ================================================================ 1. generic rules on a plain folder
{
    my $dir = "$D/plain";
    wfile("$dir/gen.txt", join("\n", map { $_->[1] } @GEN) . "\n");
    wfile("$dir/clean.txt", join("\n", @CLEAN) . "\n");
    wfile("$dir/brand/logo.png", png());
    my $zone = j('let zone = "', 'Asia', '/', 'Tokyo', '"', "\n");
    wfile("$dir/Tests/RenderCacheTests.swift", $zone);
    wfile("$dir/Tests/Other.swift", $zone);
    my ($rc, $h) = run_cp(['--tree', $dir]);
    ok($rc == 1, 'tree: a plain folder with generic plants exits 1');
    my @miss = grep { !has($h, $GEN[$_][0], qr/\Agen\.txt:@{[ $_ + 1 ]}\z/) } 0 .. $#GEN;
    ok(!@miss, 'generic rules: all ' . scalar(@GEN) . ' fire on their plants') or print "  not fired: $GEN[$_][0]\n" for @miss;
    ok(!grep({ $_->[1] =~ /\Aclean\.txt:/ } @$h), 'generic rules: reserved domains, allowed zones and synthetic meeting ids pass');
    ok(has($h, 'GEN-BRAND-01', qr/\Abrand\/logo\.png:0\z/), 'GEN-BRAND-01 fires on an image under brand/ outside the allowlist');
    ok(!has($h, 'GEN-TZ-01', qr/\ATests\/RenderCacheTests\.swift:/), 'SKIP: the named edge-case test file may use its zones');
    ok(has($h, 'GEN-TZ-01', qr/\ATests\/Other\.swift:1\z/), 'SKIP: the same zone fails in any other file');

    # Rich mail (D-043, D-044): .local is reserved (the app's own Message-ID and Content-ID host), a sentence's
    # full stop may follow a reserved address, a reserved label before a real TLD still fires, and one golden's
    # quoted-printable cut of a cast Content-ID passes in that file only.
    my $mdir = "$D/mail-reserved";
    wfile("$mdir/ids.txt", join("\n",
        j('Message-ID: <', 'a1b2c3', '@', 'yayascalendar', '.local', '>'),
        j('Write to ', 'juniper', '@', 'orb', '.example', '.'),
        j('Write to ', 'juniper', '@', 'orb', '.example', '.io'),
        j('Write to ', 'juniper', '@', 'host', '.localdomain', '.io'),
        j('Write to ', 'juniper', '@', 'orb', '.local', '.io')) . "\n");
    my $cut = j('Content-ID: <', 'logo.png', '@', 'orb', '.exam', "=\n", 'ple>');
    wfile("$mdir/Tests/Data/Goldens/mime/06-reply-quote.eml", "$cut\n");
    wfile("$mdir/Tests/Data/Goldens/mime/01-plain.eml", "$cut\n");
    my ($mrc, $mh) = run_cp(['--tree', $mdir]);
    ok(!has($mh, 'GEN-MAIL-01', qr/\Aids\.txt:[12]\z/), 'GEN-MAIL-01: .local and an address before a full stop pass');
    ok(has($mh, 'GEN-MAIL-01', qr/\Aids\.txt:3\z/) && has($mh, 'GEN-MAIL-01', qr/\Aids\.txt:4\z/)
       && has($mh, 'GEN-MAIL-01', qr/\Aids\.txt:5\z/), 'GEN-MAIL-01: a reserved label before a real TLD, or a longer label, still fires');
    ok(!has($mh, 'GEN-MAIL-01', qr/06-reply-quote\.eml:/), 'SKIP: the golden may hold its quoted-printable cut');
    ok(has($mh, 'GEN-MAIL-01', qr/01-plain\.eml:1\z/), 'SKIP: the same cut fails in any other file');

    # A path-re: structural entry blanks only in the files its path regex names, and only what its regex covers.
    my $b64 = j('QUJD', '/Use', 'rs/', 'jdoe', '/') . ('A' x 60);
    my $text = j('open ', '/Use', 'rs/', 'jdoe', '/notes.txt');
    wfile("$D/allow5/mime/a.eml", "$b64\n$text\n");
    wfile("$D/allow5/other/a.eml", "$b64\n");
    wfile("$D/allow5-file.txt", 'path-re:\Amime/[^/]+\.eml\z : GEN-PATH : re:(?m)^[A-Za-z0-9+/]{76}(?=\r?$)' . "\n");
    my ($arc, $ah) = run_cp(['--tree', "$D/allow5"], env => { YC_PUBLIC_ALLOW => "$D/allow5-file.txt" });
    ok(!has($ah, 'GEN-PATH-01', qr/\Amime\/a\.eml:1\z/), 'allow: a path-re: entry blanks its pattern in the files it names');
    ok(has($ah, 'GEN-PATH-01', qr/\Amime\/a\.eml:2\z/), 'allow: a path-re: entry leaves the other lines of those files checked');
    ok(has($ah, 'GEN-PATH-01', qr/\Aother\/a\.eml:1\z/), 'allow: a path-re: entry does nothing in other files');
    wfile("$D/allow5-bad.txt", 'path-re:\Amime/ : GEN-PATH : (?m)^x' . "\n");
    my ($brc) = run_cp(['--tree', "$D/allow5"], env => { YC_PUBLIC_ALLOW => "$D/allow5-bad.txt" });
    ok($brc == 2, 'allow: a path-re: entry without re: is a configuration error (exit 2)');

    my ($rc2, $h2) = run_cp(['--tree', "$D/plain-clean"]) if wfile("$D/plain-clean/a.txt", "hello world\n") || 1;
    ok($rc2 == 0 && !@$h2, 'tree: a clean plain folder passes (generic rules)');
    if ($HAVE_PRIV) {
        my ($rc3, $h3) = run_cp(['--tree', "$D/plain-clean"], priv => 1);
        ok($rc3 == 0 && !@$h3, 'tree: a clean plain folder passes (with the deny list)');
    }

    # the same rules over the decoded copy: JSONEncoder's \/, %2F, %40 and &#64;, a Windows or
    # lower-case home folder, ~name/; API paths, a numeric id and ~/ stay clean
    my $U = j('Us', 'ers');
    my @ENC = (
        ['GEN-PATH-01', j('{"path":"\\/', $U, '\\/', 'jdoe', '\\/Library\\/x.json"}')],
        ['GEN-PATH-01', j('C:\\', $U, '\\', 'jdoe', '\\Desktop')],
        ['GEN-PATH-01', j('cp x /', lc $U, '/', 'jdoe', '/notes/')],
        ['GEN-PATH-02', j('cp x ~', 'jdoe', '/notes/')],
        ['GEN-TZ-01',   j('{"tz":"', 'Asia', '\\/', 'Kolkata', '"}')],
        ['GEN-TZ-01',   j('https://calendar.example/embed?src=x&ctz=', 'Asia', '%2F', 'Kolkata')],
        ['GEN-MAIL-01', j('mailto:', 'jane.doe', '%40', 'orbitrail', '.io')],
        ['GEN-MAIL-01', j('jane.doe', '&#64;', 'orbitrail', '.io')],
        ['GEN-MEET-01', j('https://', 'zoom', '.us%2Fj%2F', '8475930261')],
    );
    my @ENC_OK = (
        j('GET https://api.github.com/', lc $U, '/', 'octocat'),
        j('let p = "/gmail/v1/', lc $U, '/', 'me', '/messages"'),
        j('let p = "/', lc $U, '/', '123', '/"'),
        'cp x ~/Library/',
    );
    wfile("$D/plain-enc/enc.txt", join("\n", map { $_->[1] } @ENC) . "\n");
    wfile("$D/plain-enc/ok.txt", join("\n", @ENC_OK) . "\n");
    my ($rce, $he) = run_cp(['--tree', "$D/plain-enc"]);
    my @em = grep { !has($he, $ENC[$_][0], qr/\Aenc\.txt:@{[ $_ + 1 ]}\z/) } 0 .. $#ENC;
    ok(!@em, 'generic rules: ' . scalar(@ENC) . ' escaped, encoded and Windows forms fire') or print "  not fired: line " . join(' ', map { $_ + 1 } @em) . "\n";
    ok(!grep({ $_->[1] =~ /\Aok\.txt:/ } @$he), 'generic rules: API user paths, a numeric id and ~/ pass');
}

# ================================================================ 1b. deny-list mechanics on a synthetic list
# A made-up list with made-up words (no private data), so the format runs everywhere, CI included:
# opaque classes and their properties, USE companions, FOLD lines, the private allow file, --promo,
# substring classes in --bundle mode, and the script-neutral folding of the decoded forms.
{
    require Encode;
    my $e = sub { Encode::encode('UTF-8', $_[0]) };
    my $T = "\t";
    my $sd = "$D/synth";
    my @head = (join($T, 'CLASS', 'P90', 'sub,promo', '-'), join($T, 'CLASS', 'P91', '-', '-'),
                join($T, 'USE', 'allow', 'allow.txt', '-'), join($T, 'USE', 'identity', 'identity.txt', '-'));
    my @fold = (join($T, 'FOLD', 'U+00F8', 'U+006F', '-'), join($T, 'FOLD', 'U+00B7', '-', '-'));
    my @rules = (join($T, 'P90-01', 'P90', 'i,w', 'zorblax'), join($T, 'P91-01', 'P91', 'w', 'quillon 4711'),
                 join($T, 'P91-02', 'P91', 'w', 'vexmoor'), join($T, 'P91-03', 'P91', 'w', 'kestrel-9'));
    wfile("$sd/deny.txt", join("\n", '# synthetic', @head, @fold, @rules) . "\n");
    wfile("$sd/nofold.txt", join("\n", @head, @rules) . "\n");
    my %S = (YC_DENYLIST => "$sd/deny.txt", YC_PRIVATE_ALLOW => undef, YC_ALLOW_IDENTITY => undef);

    # the decoded forms fold every script the same way, plus the list's FOLD lines
    my @forms = (
        ['P90-01', 'plain',                     'zorblax'],
        ['P90-01', 'a combining mark',          $e->("z\x{0301}orblax")],
        ['P90-01', 'a bidi override inside',    $e->("zor\x{202E}blax")],
        ['P90-01', 'fullwidth letters',         $e->("\x{FF5A}\x{FF4F}\x{FF52}\x{FF42}\x{FF4C}\x{FF41}\x{FF58}")],
        ['P91-01', 'Devanagari digits',         $e->("quillon \x{096A}\x{096D}\x{0967}\x{0967}")],
        ['P91-01', 'Thai digits',               $e->("quillon \x{0E54}\x{0E57}\x{0E51}\x{0E51}")],
        ['P91-01', 'N\'Ko digits',              $e->("quillon \x{07C4}\x{07C7}\x{07C1}\x{07C1}")],
        ['P91-01', 'an ogham space mark',       $e->("quillon\x{1680}4711")],
        ['P91-03', 'a two-em dash',             $e->("kestrel\x{2E3A}9")],
        ['P90-01', 'a FOLD variant',            $e->("z\x{00F8}rblax")],
        ['P90-01', 'a FOLD drop',               $e->("zorb\x{00B7}lax")],
    );
    wfile("$D/synth-forms/forms.txt", join("\n\n", map { $_->[2] } @forms) . "\n");
    my ($rc, $h) = run_cp(['--tree', "$D/synth-forms"], env => \%S);
    my @miss = grep { !has($h, $forms[$_][0], qr/\Aforms\.txt:@{[ 2 * $_ + 1 ]}\z/) } 0 .. $#forms;
    ok(!@miss, 'synthetic list: ' . scalar(@forms) . ' script-neutral and FOLD forms fire') or print "  not fired: " . join(', ', map { $forms[$_][1] } @miss) . "\n";
    my ($rc2, $h2) = run_cp(['--tree', "$D/synth-forms"], env => { %S, YC_NO_PREFILTER => 1 });
    ok(join("\n", sort map { "@$_" } @$h) eq join("\n", sort map { "@$_" } @$h2), 'synthetic list: the literal prefilter changes no result');
    ($rc, $h) = run_cp(['--tree', "$D/synth-forms"], env => { %S, YC_DENYLIST => "$sd/nofold.txt" });
    ok(!has($h, 'P90-01', qr/\Aforms\.txt:(?:19|21)\z/) && has($h, 'P90-01', qr/\Aforms\.txt:1\z/), 'synthetic list: without its FOLD lines the variants pass');

    # USE allow: the private allow file beside the list; --strict needs it
    my $credit = 'zorblax credit';
    wfile("$sd/allow.txt", "credit.txt : P90 : " . sha256_hex($credit) . "\n");
    wfile("$D/synth-allow/credit.txt", "$credit\nzorblax other\n");
    my $out;
    ($rc, $h, $out) = run_cp(['--strict', '--tree', "$D/synth-allow"], env => \%S);
    ok($rc == 1 && !has($h, 'P90-01', qr/\Acredit\.txt:1\z/) && has($h, 'P90-01', qr/\Acredit\.txt:2\z/),
       'synthetic list: the USE allow file allows exactly its line');
    ok($out =~ /^INFO lines allowed by the allow files: P90=1/m, 'synthetic list: lines it allows are counted');
    ($rc) = run_cp(['--strict', '--tree', "$D/synth-allow"], env => { %S, YC_PRIVATE_ALLOW => $NONE });
    ok($rc == 2, 'strict: a missing private allow file is exit 2');
    ($rc, $h) = run_cp(['--tree', "$D/synth-allow"], env => { %S, YC_PRIVATE_ALLOW => "$D/private-allow.txt" });
    ok(has($h, 'P90-01', qr/\Acredit\.txt:1\z/), 'synthetic list: YC_PRIVATE_ALLOW replaces the USE allow file');

    # USE identity: --strict --history finds the identity allow beside the list
    wfile("$sd/identity.txt", "$ME{name}\t$ME{email}\n");
    my $hist = "$D/synth-hist";
    new_repo($hist);
    wfile("$hist/a.txt", "hello\n");
    commit($hist, 'Add a');
    ($rc, $h) = run_cp(['--history', $hist, '--strict'], env => \%S);
    ok($rc == 0 && !@$h, 'synthetic list: --strict --history finds the USE identity allow');

    # promo: --text --promo lets a promo class pass, never another
    wfile("$D/synth-text/copy.txt", "zorblax\n\nvexmoor\n");
    ($rc, $h) = run_cp(['--text', "$D/synth-text/copy.txt"], env => \%S);
    ok($rc == 1 && has($h, 'P90-01') && has($h, 'P91-02'), 'synthetic list: --text fails on both classes');
    ($rc, $h) = run_cp(['--text', "$D/synth-text/copy.txt", '--promo'], env => \%S);
    ok($rc == 1 && !has($h, 'P90-01') && has($h, 'P91-02'), 'synthetic list: --promo passes only the promo class');

    # sub: a name glued inside a Swift identifier fires only for a substring class
    my $mo = -f '/usr/bin/true' ? do { local $/; open my $f, '<:raw', '/usr/bin/true' or die; <$f> } : '';
    wfile("$D/Synth.app/Contents/MacOS/Synth", $mo . "\0\$s13YayasCalendar14zorblaxAccountV\0\$s13YayasCalendar14vexmoorAccountV\0");
    ($rc, $h) = run_cp(['--bundle', "$D/Synth.app"], env => \%S);
    ok(has($h, 'P90-01', qr/\Abundle:Contents\/MacOS\/Synth:/) && !has($h, 'P91-02'),
       'synthetic list: a sub class matches inside an identifier, another class does not');

    # malformed lists are configuration errors
    my %bad = ('a CLASS id that is not opaque' => join($T, 'CLASS', 'X9', '-', '-'),
               'an unknown class property'     => join($T, 'CLASS', 'P90', 'loud', '-'),
               'a rule outside P01..P99'       => join($T, 'ID-X-01', 'ID-X', '-', 'zorblax'),
               'a FOLD of an ASCII letter'     => join($T, 'FOLD', 'U+0041', '-', '-'),
               'a USE of an unknown kind'      => join($T, 'USE', 'notes', 'n.txt', '-'));
    for my $k (sort keys %bad) {
        wfile("$sd/bad.txt", "$bad{$k}\n");
        ($rc) = run_cp(['--tree', "$D/plain-clean"], env => { %S, YC_DENYLIST => "$sd/bad.txt" });
        ok($rc == 2, "synthetic list: $k is exit 2");
    }
}

# ================================================================ 2. images
{
    my %img = (
        'clean.png'        => [png(), []],
        'text.png'         => [png(chunk('tEXt', "Comment\0" . 'plain words')), ['IMG-01']],
        'cabx.png'         => [png(chunk('caBX', 'jumb' . ("\0" x 8))), ['IMG-01']],
        'iccp-generic.png' => [png(iccp('sRGB IEC61966-2.1')), []],
        'iccp-custom.png'  => [png(iccp('Studio Calibration 7')), ['IMG-02']],
        'clean.icns'       => [icns(png()), []],
        'text.icns'        => [icns(png(chunk('tEXt', "Comment\0" . 'plain words'))), ['IMG-01']],
        'clean.jpg'        => [jpeg(), []],
        'app1.jpg'         => [jpeg(seg(0xE1, "Exif\0\0" . "MM\0*")), ['IMG-03']],
        'app11.jpg'        => [jpeg(seg(0xEB, "JP\0\0" . 'jumb')), ['IMG-04']],
        'app13.jpg'        => [jpeg(seg(0xED, "Photoshop 3.0\0")), ['IMG-05']],
        'clean.pdf'        => [pdf('/Producer (Skia/PDF m120)'), []],
        'author.pdf'       => [pdf('/Author (Jane Doe) /Producer (Skia/PDF m120)'), ['IMG-08']],
        'xmp.pdf'          => [pdf('/Producer (Skia/PDF m120)', xmp_obj()), ['IMG-07']],
        'tool.pdf'         => [pdf('/Producer (Mystery Writer 3)'), ['IMG-08']],
    );
    wfile("$D/img/$_", $img{$_}[0]) for keys %img;
    my ($rc, $h, $out) = run_cp(['--images', 'img'], cwd => $D);
    for my $name (sort keys %img) {
        my @want = @{ $img{$name}[1] };
        my @got = grep { $_->[1] =~ /\Aimg\/\Q$name\E[#:]/ } @$h;
        if (@want) { ok(@got && !grep({ my $w = $_; !grep { $_->[0] eq $w } @got } @want), "images: $name fires " . join(',', @want)) }
        else       { ok(!@got, "images: $name passes") }
    }
    ok(scalar(() = $out =~ /^EYE img\//mg) == scalar(keys %img), 'images: every non-text file is listed for the eye check');
    ok(has($h, 'IMG-01', qr/\Aimg\/text\.icns#ic10:/), 'images: a PNG inside an .icns gets the PNG check');
}

# ================================================================ 3. tree and staged on a repository
{
    my $repo = "$D/repo";
    new_repo($repo);
    wfile("$repo/README.md", "hello\n");
    wfile("$repo/.gitattributes", "private/** export-ignore\n");
    my $priv_line = '';
    my $priv_rule;
    if ($HAVE_PRIV) {
        ($priv_rule) = grep { $PR{$_} && prop($PR{$_}, 'name') && !$PR{$_}{flags}{short} } sort keys %HITP;
        $priv_line = $HITP{$priv_rule}[0] . "\n" if $priv_rule;
    }
    wfile("$repo/private/notes.md", $GEN{'GEN-PATH-01'} . "\n" . $priv_line);
    commit($repo, 'Initial');
    my ($rc, $h, $out) = run_cp(['--tree', $repo], priv => 1);
    ok($rc == 0, 'tree: hits inside an export-ignored file do not fail');
    ok($out =~ /^INFO export-ignored files with hits \(information only\): 1 files/m, 'tree: they are counted as information');
    ($rc) = run_cp(['--tree', 'HEAD'], priv => 1, cwd => $repo);
    ok($rc == 0, 'tree REF: the archive view of HEAD passes');

    wfile("$repo/.gitattributes", "");
    commit($repo, 'Drop the export rule');
    ($rc, $h) = run_cp(['--tree', $repo], priv => 1);
    ok($rc == 1 && has($h, 'GEN-PATH-01', qr/\Aprivate\/notes\.md:1\z/), 'tree: a private doc that lost export-ignore fails');
    if ($priv_rule) { ok(has($h, $priv_rule, qr/\Aprivate\/notes\.md:2\z/), 'tree: its deny-list hit is reported too') }
    ($rc, $h) = run_cp(['--tree', 'HEAD'], priv => 1, cwd => $repo);
    ok($rc == 1 && has($h, 'GEN-PATH-01', qr/\Aprivate\/notes\.md:1\z/), 'tree REF: the same doc fails in the archive view of HEAD');

    wfile("$repo/staged.txt", $GEN{'GEN-MAIL-01'} . "\n");
    git($repo, 'add', 'staged.txt');
    ($rc, $h) = run_cp(['--staged'], cwd => $repo);
    ok($rc == 1 && has($h, 'GEN-MAIL-01', qr/\Astaged\.txt:1\z/), 'staged: a staged plant fails');
    if (my $wp = $HAVE_PRIV ? wrapped_probe() : undef) {
        wfile("$repo/wrapped.md", "Notes\n$wp->[1]\n");
        git($repo, q{add}, q{wrapped.md});
        ($rc, $h) = run_cp([q{--staged}], priv => 1, cwd => $repo);
        ok($rc == 1 && has($h, $wp->[0], qr/\Awrapped\.md:2\z/), q{staged: a name hard-wrapped over two lines fails});
    } else { skip(q{staged: wrapped plant}, $HAVE_PRIV ? q{no multi-word probe} : q{no private deny list}) }

    my $clean = "$D/cleanrepo";
    new_repo($clean);
    wfile("$clean/README.md", "hello world\n");
    wfile("$clean/.gitattributes", "notes/** export-ignore\n");
    wfile("$clean/notes/n.md", $GEN{'GEN-PATH-01'} . "\n");
    wfile("$clean/icon.png", png());
    commit($clean, 'Initial');
    ($rc, $h) = run_cp(['--tree', $clean], priv => 1);
    ok($rc == 0 && !@$h, 'tree: a clean repository passes');
    ($rc, $h) = run_cp(['--staged'], priv => 1, cwd => $clean);
    ok($rc == 0 && !@$h, 'staged: a clean index passes');
}

# ================================================================ 4. history
{
    wfile("$D/identity.txt", "$ME{name}\t$ME{email}\n$ME{name}\t$ME{email}\n");
    my $hist = "$D/hist";
    new_repo($hist);
    wfile("$hist/a.txt", "hello\n");
    commit($hist, 'Add a');
    my ($rc, $h) = run_cp(['--history', $hist, '--refs']);
    ok($rc == 0 && !@$h, 'history: commits by the allowed identity pass');
    git($hist, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
    ($rc, $h) = run_cp(['--history', $hist, '--refs']);
    ok($rc == 0 && !@$h, 'history --refs: a remote-tracking ref passes');

    wfile("$hist/b.txt", $GEN{'GEN-SECRET-01'} . "\n");
    wfile("$hist/meta.png", png(chunk('tEXt', "Comment\0" . 'plain words')));
    commit($hist, "Add b\n\nwrite to " . $GEN{'GEN-MAIL-01'}, \%STRANGER);
    ($rc, $h) = run_cp(['--history', $hist]);
    ok($rc == 1, 'history: a commit by a foreign identity fails');
    ok(has($h, 'IDENT-01', qr{\Ahistory:[0-9a-f]{12}/author:0\z}) && has($h, 'IDENT-02', qr{/committer:0\z}), 'history: author and committer are both reported');
    ok(has($h, 'GEN-SECRET-01', qr{\Ahistory:[0-9a-f]{12}/b\.txt:1\z}), 'history: an added line is scanned');
    ok(has($h, 'GEN-MAIL-01', qr{\Ahistory:[0-9a-f]{12}/message:3\z}), 'history: the commit message is scanned');
    ok(has($h, 'IMG-01', qr{\Ahistory:[0-9a-f]{12}/meta\.png:}), 'history: an added image is parsed');
    ok(!grep({ $_->[0] eq 'GEN-MAIL-01' && $_->[1] =~ /author|committer/ } @$h), 'history: identity fields are not seen by the email rule');
    ($rc, $h) = run_cp(['--history', $hist, '--range', 'HEAD..HEAD']);
    ok($rc == 0, 'history --range: an empty range passes');
    ($rc, $h) = run_cp(['--history', $hist, '--range', 'HEAD~1..HEAD']);
    ok($rc == 1 && has($h, 'IDENT-01'), 'history --range: the range is scanned');
    ($rc, $h) = run_cp(['--history', $hist, '--range', 'HEAD~1..HEAD~1']);
    ok($rc == 0, 'history --range: commits outside the range are not scanned');

    git($hist, 'update-ref', 'refs/original/refs/heads/main', 'HEAD~1');
    ($rc, $h) = run_cp(['--history', $hist, '--refs', '--range', 'HEAD..HEAD']);
    ok($rc == 1 && has($h, 'REF-01', qr{\Aref:refs/original/refs/heads/main:0\z}), 'history --refs: a ref outside heads, tags and remotes fails');
    ok(!has($h, 'REF-01', qr{remotes}), 'history --refs: the remote-tracking ref still passes');

    ($rc) = run_cp(['--history', $hist, '--strict', '--range', 'HEAD..HEAD']);
    ok($rc == 2, 'history --strict: a missing deny list is a configuration error (exit 2)');
    if ($HAVE_PRIV) {
        ($rc) = run_cp(['--history', $hist, '--strict', '--range', 'HEAD..HEAD'], priv => 1, env => { YC_ALLOW_IDENTITY => $NONE });
        ok($rc == 2, 'history --strict: a missing identity allow is a configuration error (exit 2)');
        my ($term_cls) = grep { $PR{$_} && prop($PR{$_}, 'term') && $HITP{$_} } sort keys %HITP;
        my ($name_cls) = grep { $PR{$_} && prop($PR{$_}, 'name') && !$PR{$_}{flags}{short} && $HITP{$_} } sort keys %HITP;
        if ($term_cls && $name_cls) {
            wfile("$hist/c.txt", $HITP{$name_cls}[0] . "\n");
            commit($hist, "Add c\n\n" . $HITP{$term_cls}[0]);
            ($rc, $h) = run_cp(['--history', $hist, '--range', 'HEAD~1..HEAD'], priv => 1);
            ok(has($h, $term_cls, qr{/message:3\z}), 'history: a term-class plant in a commit message fires');
            ok(has($h, $name_cls, qr{/c\.txt:1\z}), 'history: a name-class plant in an added line fires');
            if (my $wp = wrapped_probe()) {
                wfile("$hist/d.md", "Notes\n$wp->[1]\n");
                commit($hist, "Add d\n\n$wp->[1]");
                ($rc, $h) = run_cp([q{--history}, $hist, q{--range}, q{HEAD~1..HEAD}], priv => 1);
                ok(has($h, $wp->[0], qr{/message:3\z}), q{history: a name hard-wrapped in a commit body fires});
                ok(has($h, $wp->[0], qr{/d\.md:2\z}), q{history: a name hard-wrapped over two added lines fires});
            } else { skip(q{history: wrapped plants}, q{no multi-word probe}) }
        } else { skip('history: deny-list plants', 'no probe for the classes') }
    } else { skip('history: deny-list plants', 'no private deny list') }
}

# ================================================================ 5. text
{
    wfile("$D/text/clean.txt", "A calendar for the menu bar.\n");
    wfile("$D/text/gen.txt", $GEN{'GEN-MAIL-01'} . "\n");
    my ($rc, $h) = run_cp(['--text', "$D/text/clean.txt"]);
    ok($rc == 0 && !@$h, 'text: clean prose passes');
    ($rc, $h) = run_cp(['--text', "$D/text/gen.txt"]);
    ok($rc == 1 && has($h, 'GEN-MAIL-01', qr/\Agen\.txt:1\z/), 'text: a generic plant fails');
    ($rc) = run_cp(['--promo', '--tree', "$D/text"]);
    ok($rc == 2, 'usage: --promo outside --text is exit 2');
    if ($HAVE_PRIV) {
        my $promo;
        for my $id (sort grep { $PR{$_} && prop($PR{$_}, 'promo') } keys %HITP) {
            for my $t (@{ $HITP{$id} }) {
                my @f = fires_private($t);
                next if grep { !prop($_, 'promo') } @f;
                next if grep { $t =~ /\Q$_\E/ } values %GEN;
                $promo = [$id, $t];
                last;
            }
            last if $promo;
        }
        if ($promo) {
            wfile("$D/text/promo.txt", "$promo->[1]\n");
            ($rc, $h) = run_cp(['--text', "$D/text/promo.txt"], priv => 1);
            ok($rc == 1 && has($h, $promo->[0], qr/\Apromo\.txt:1\z/), 'text: a promo-class plant fails');
            ($rc, $h) = run_cp(['--text', "$D/text/promo.txt", '--promo'], priv => 1);
            ok($rc == 0 && !@$h, 'text --promo: the promo-class plant passes');
        } else { skip('text: promo-class plant', 'no promo-class probe free of other classes') }
    } else { skip('text: promo-class plant', 'no private deny list') }
}

# ================================================================ 6. bundle
my $MACHO = -f '/usr/bin/true' ? do { local $/; open my $f, '<:raw', '/usr/bin/true' or die; <$f> } : undef;
{
    my $plist = sub {
        my ($id, $extra) = @_;
        return qq{<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n}
          . qq{<key>CFBundleIdentifier</key><string>$id</string>\n} . ($extra // '') . "</dict>\n</plist>\n";
    };
    wfile("$D/Clean.app/Contents/Info.plist", $plist->('org.example.selftest'));
    wfile("$D/Clean.app/Contents/MacOS/Clean", $MACHO // "\0clean\0");
    wfile("$D/Clean.app/Contents/Resources/icon.png", png());
    my ($rc, $h, $out) = run_cp(['--bundle', "$D/Clean.app"], priv => 1);
    ok($rc == 0 && !@$h, 'bundle: a clean bundle passes');
    if ($MACHO) { ok($out =~ /^INFO local symbols [0-9]+ in bundle:Contents\/MacOS\/Clean /m, 'bundle: the local symbol count is printed') }
    else { skip('bundle: local symbol count', 'no system Mach-O to copy') }
    ok($out =~ /^CAVEAT Swift string literals of 15 bytes or fewer/m, 'bundle: the short-literal caveat is printed');

    wfile("$D/Dirty.app/Contents/Info.plist", $plist->('org.example.selftest', '<key>Contact</key><string>' . $GEN{'GEN-MAIL-01'} . "</string>\n"));
    wfile("$D/Dirty.app/Contents/MacOS/Dirty", ($MACHO // '') . "\0" . $GEN{'GEN-SECRET-01'} . "\0");
    wfile("$D/Dirty.app/Contents/Resources/meta.png", png(chunk('tEXt', "Comment\0" . 'plain words')));
    wfile("$D/Dirty.app/Contents/Resources/blob.bin", "\0\x01" . $GEN{'GEN-SECRET-06'} . "\0");
    ($rc, $h) = run_cp(['--bundle', "$D/Dirty.app"]);
    ok($rc == 1, 'bundle: a bundle with plants exits 1');
    ok(has($h, 'GEN-MAIL-01', qr/\Abundle:Contents\/Info\.plist:plist\z/), 'bundle: a plist value is scanned');
    ok(has($h, 'GEN-SECRET-01', qr/\Abundle:Contents\/MacOS\/Dirty:bytes\z/), 'bundle: Mach-O bytes are scanned');
    ok(has($h, 'IMG-01', qr/\Abundle:Contents\/Resources\/meta\.png:/), 'bundle: images get the image check');
    ok(has($h, 'GEN-SECRET-06', qr/\Abundle:Contents\/Resources\/blob\.bin:bytes\z/), 'bundle: other resources are scanned as bytes');

    if ($HAVE_PRIV) {
        # Mangled-symbol plants: a name between word characters, as Swift mangling writes it.
        my (@long, @short);
        for my $r (grep { prop($_, 'sub') && $HITP{ $_->{id} } } @PR) {
            for my $t (@{ $HITP{ $r->{id} } }) {
                next unless $t =~ $r->{re};
                (my $w = $&) =~ s/[^A-Za-z0-9]//g;
                next unless length $w >= 3;
                if ($r->{flags}{short}) {
                    next unless $& =~ /\A[A-Za-z0-9]+\z/ && " $w " =~ $r->{re};    # identifier shapes only
                    push @short, [$r->{id}, '$s13YayasCalendar' . length($w) . $w . 'V'];
                } else {
                    next unless " $w " =~ $r->{re};
                    push @long, [$r->{id}, '$s13YayasCalendar' . length($w) . $w . 'AccountVMn'];
                }
                last;
            }
        }
        my %seen;
        @short = grep { !$seen{ $_->[0] }++ } @short;
        my @all = (@long, @short);
        if (@all) {
            wfile("$D/Mangled.app/Contents/MacOS/Mangled", ($MACHO // '') . join('', map { "\0" . $_->[1] . "\0" } @all));
            wfile("$D/mangled-text/symbols.txt", join("\n", map { $_->[1] } @all) . "\n");
            my ($brc, $bh) = run_cp(['--bundle', "$D/Mangled.app"], priv => 1);
            my @nl = grep { !has($bh, $_->[0], qr/\Abundle:Contents\/MacOS\/Mangled:(?:bytes|unmangled)\z/) } @long;
            ok(@long && !@nl, 'bundle: mangled-symbol plants of ' . scalar(@long) . ' substring-class rules fire as substrings')
              or print "  not fired: " . join(' ', map { $_->[0] } @nl) . "\n";
            if (@short) {
                my @ns = grep { !has($bh, $_->[0], qr/\Abundle:Contents\/MacOS\/Mangled:(?:bytes|unmangled)\z/) } @short;
                ok(!@ns, 'bundle: mangled-symbol plants of ' . scalar(@short) . ' short-tag rules fire')
                  or print "  not fired: " . join(' ', map { $_->[0] } @ns) . "\n";
            } else { skip('bundle: mangled short tags', 'no identifier-shaped short-tag probe') }
            my ($trc, $th) = run_cp(['--tree', "$D/mangled-text"], priv => 1);
            my $in_text = grep { my $id = $_->[0]; has($th, $id) } @long;
            print "INFO mangled plants caught by text-mode rules: $in_text of " . scalar(@long) . " (bundle mode: substring)\n";
        } else { skip('bundle: mangled-symbol plants', 'no single-word substring-class probe') }
    } else { skip('bundle: mangled-symbol plants', 'no private deny list') }
}

# ================================================================ 7. deny-list plants, one per rule, every class and tag shape
if ($HAVE_PRIV) {
    my (@lines, @owner);
    for my $id (sort keys %HITP) { for my $t (@{ $HITP{$id} }) { push @lines, $t; push @owner, $id } }
    # one sample per paragraph: a blank line keeps the joined forms from reading two samples as one
    wfile("$D/priv/hits.txt", join("\n\n", @lines) . "\n");
    my (@mlines, @mowner);
    for my $id (sort keys %MISSP) { for my $t (@{ $MISSP{$id} }) { push @mlines, $t; push @mowner, $id } }
    for my $t (@GLOBAL_MISS) { push @mlines, $t; push @mowner, '*' }
    wfile("$D/priv/misses.txt", join("\n\n", @mlines) . "\n") if @mlines;
    my ($rc, $h, $out) = run_cp(['--tree', "$D/priv"], priv => 1);
    my %fired;
    for my $x (@$h) { $fired{"$x->[0]\0$1"} = 1 if $x->[1] =~ /\Ahits\.txt:([0-9]+)\z/ }
    my (%per, %ok, @bad);
    for my $i (0 .. $#lines) {
        my $id = $owner[$i];
        my $hit = $fired{ "$id\0" . (2 * $i + 1) } ? 1 : 0;
        $ok{$id} //= 1;
        $ok{$id} = 0 unless $hit;
    }
    for my $r (@PR) {
        my $c = $r->{class};
        $per{$c}{rules}++;
        if (!$HITP{ $r->{id} }) { $per{$c}{nosample}++; next }
        if ($ok{ $r->{id} }) { $per{$c}{ok}++ } else { push @bad, $r->{id} }
    }
    for my $c (sort keys %per) {
        my $p = $per{$c};
        ok(($p->{ok} || 0) + ($p->{nosample} || 0) == $p->{rules},
           "deny list $c: " . ($p->{ok} || 0) . " of $p->{rules} rules fire on every one of their plants"
           . ($p->{nosample} ? " ($p->{nosample} without a sample)" : ''));
    }
    print "  not fired: @bad\n" if @bad;
    my @short = grep { $_->{flags}{short} } @PR;
    my $nshort = 0;
    $nshort += scalar @{ $HITP{ $_->{id} } || [] } for @short;
    ok(!grep({ !$ok{ $_->{id} } } grep { $HITP{ $_->{id} } } @short),
       "deny list short tags: $nshort plants over " . scalar(@short) . ' rules (quoted, stem, camelCase, embedded and upper-case shapes) fire');
    my %matched;
    for my $i (0 .. $#lines) { my $r = $PR{ $owner[$i] }; $matched{$&} = 1 if $r && $lines[$i] =~ $r->{re} && length($&) >= 4 }
    my $leaks = grep { index($out, $_) >= 0 } keys %matched;
    ok(!$leaks, 'deny list: the output holds none of the ' . scalar(keys %matched) . ' matched strings (4 bytes or more)');
    if (@mlines) {
        my %mf;
        for my $x (@$h) { $mf{$1}{ $x->[0] } = 1 if $x->[1] =~ /\Amisses\.txt:([0-9]+)\z/ }
        my @wrong;
        for my $i (0 .. $#mlines) {
            my $id = $mowner[$i];
            my $f = $mf{ 2 * $i + 1 } || {};
            if ($id eq '*') { push @wrong, "look-alike line " . (2 * $i + 1) if grep { $PR{$_} } keys %$f }
            elsif ($f->{$id}) { push @wrong, $id }
        }
        ok(!@wrong, 'deny list: ' . scalar(@mlines) . ' look-alike and miss samples pass') or print "  fired: @wrong\n";
    }
    my ($rc2, $h2) = run_cp(['--tree', "$D/priv"], priv => 1, env => { YC_NO_PREFILTER => 1 });
    my $a = join "\n", sort map { "$_->[0] $_->[1]" } @$h;
    my $b = join "\n", sort map { "$_->[0] $_->[1]" } @$h2;
    ok($a eq $b && $rc == $rc2, 'prefilter: the literal prefilter changes no result on the plants');
} else { skip('deny-list plants', 'no private deny list') }

# ================================================================ 7b. deny-list plants in disguise
# Every hit probe is planted again escaped, encoded, split by other separators, folded inside a word
# and hard-wrapped (all built here from the probe at run time); each form must still fire the probe's
# rule. The look-alike samples get the transforms that add no new characters and must still pass.
if ($HAVE_PRIV) {
    require Encode;
    require Unicode::Normalize;
    my $u  = sub { Encode::decode('UTF-8', $_[0]) };
    my $b8 = sub { Encode::encode('UTF-8', $_[0]) };
    my $split_word = sub {    # split the longest letter run (4 or more) in the middle with $ins
        my ($s, $ins) = @_;
        my $t = $u->($s);
        my ($bs, $bl) = (-1, 0);
        while ($t =~ /(\p{L}{4,})/g) { ($bs, $bl) = ($-[1], length $1) if length $1 > $bl }
        return undef if $bs < 0;
        my $m = $bs + int($bl / 2);
        return $b8->(substr($t, 0, $m)) . $ins . $b8->(substr($t, $m));
    };
    my $spaces = sub {    # every space between two letters becomes $x
        my ($s, $x) = @_;
        my $t = $u->($s);
        return undef unless $t =~ s/(?<=\p{L}) (?=\p{L})/\x{E000}/g;
        my $o = $b8->($t);
        $o =~ s/\xEE\x80\x80/$x/g;
        return $o;
    };
    my $wrap = \&wrap_middle;
    my $apos = sub { my ($s, $x) = @_; return ($s =~ s/'|\xE2\x80\x99/$x/g) ? $s : undef };
    my $non_ascii = sub { my ($s, $f) = @_; return $s =~ /[\x80-\xFF]/ ? $f->($s) : undef };
    my $esc = sub { my ($s, $fmt) = @_; (my $t = $u->($s)) =~ s/([^\x00-\x7F])/sprintf($fmt, ord $1)/ge; return $t };
    # kind => [mode, transform, safe for look-alikes, control]; mode 1: split inside a word (short-tag
    # rules are exempt by design), mode 2: a dash, asserted where an ASCII hyphen in the same place
    # fires, mode 3: a slash, which rules that name '/' read literally (they are exempt). A control,
    # when given, is the same carrier in plain form: the kind is asserted only where it fires.
    # Transforms get the probe and its rule.
    # a non-ASCII letter -> the first character (by code point) whose compatibility form (NFKC) is that
    # letter alone: presentation forms, fullwidth and other compatibility letters of any script
    my %COMPAT;
    for my $cp (0xA0 .. 0xFFFF) {
        next if $cp >= 0xD800 && $cp <= 0xDFFF;
        my $c = chr $cp;
        next if $c =~ /[\p{Cf}\p{Mn}\p{Me}]/;
        my $n = Unicode::Normalize::NFKC($c);
        $COMPAT{$n} //= $c if length $n == 1 && $n ne $c && ord($n) > 0x7F && $n =~ /\A\p{L}\z/;
    }
    # the deny list's FOLD lines, backwards: each target letter written as its first variant, and the
    # first dropped character set between two letters
    my %VARIANT;
    for my $f (sort keys %FOLDS) { $VARIANT{ $FOLDS{$f} } //= $f if length $FOLDS{$f} }
    my ($DROP) = sort grep { !length $FOLDS{$_} } keys %FOLDS;
    my $digits = sub { my ($s, $base) = @_; return ($s =~ s/([0-9])/$b8->(chr($base + $1))/ge) ? $s : undef };
    my $spaced = sub { "x $_[0] y" };
    my %K = (
        wrap_md       => [0, sub { $wrap->($_[0], '') }, 1],
        wrap_comment  => [0, sub { $wrap->($_[0], '// ') }, 1],
        wrap_quote    => [0, sub { $wrap->($_[0], '> ') }, 1],
        sep_nbsp      => [0, sub { $spaces->($_[0], "\xC2\xA0") }, 1],
        sep_pct20     => [0, sub { $spaces->($_[0], '%20') }],
        sep_plus      => [0, sub { $spaces->($_[0], '+') }],
        sep_entnbsp   => [0, sub { $spaces->($_[0], '&nbsp;') }],
        sep_2space    => [0, sub { $spaces->($_[0], '  ') }, 1],
        sep_tab       => [0, sub { $spaces->($_[0], "\t") }, 1],
        sep_slash     => [3, sub { $spaces->($_[0], '/') }],
        sep_endash    => [2, sub { $spaces->($_[0], "\xE2\x80\x93") }],
        sep_nbhyphen  => [2, sub { $spaces->($_[0], "\xE2\x80\x91") }],
        qp_softbreak  => [1, sub { $split_word->($_[0], "=\n") }, 1],
        ics_fold      => [1, sub { $split_word->($_[0], "\r\n ") }, 1],
        concat_inword => [1, sub { $split_word->($_[0], '" + "') }],
        concat_in_nl  => [1, sub { $split_word->($_[0], "\" +\n    \"") }],
        zwsp_inword   => [1, sub { $split_word->($_[0], "\xE2\x80\x8B") }, 1],
        shy_inword    => [1, sub { $split_word->($_[0], "\xC2\xAD") }, 1],
        json_u_all    => [0, sub { join '', map { sprintf '\\u%04X', ord } split //, $u->($_[0]) }, 1],
        html_dec_all  => [0, sub { join '', map { '&#' . ord($_) . ';' } split //, $u->($_[0]) }, 1],
        url_all       => [0, sub { join '', map { sprintf '%%%02X', ord } split //, $_[0] }, 1],
        json_u        => [0, sub { $non_ascii->($_[0], sub { $esc->($_[0], '\\u%04x') }) }],
        swift_u       => [0, sub { $non_ascii->($_[0], sub { $esc->($_[0], '\\u{%X}') }) }],
        html_nonascii => [0, sub { $non_ascii->($_[0], sub { $esc->($_[0], '&#%d;') }) }],
        q_word        => [0, sub { $non_ascii->($_[0], sub { (my $q = $_[0]) =~ s/([^A-Za-z0-9 ])/sprintf('=%02X', ord $1)/ge; $q =~ tr/ /_/; "=?UTF-8?Q?$q?=" }) }],
        qp_body       => [0, sub { $non_ascii->($_[0], sub { (my $q = $_[0]) =~ s/([\x80-\xFF])/sprintf('=%02X', ord $1)/ge; $q }) }],
        # a combining mark after every letter, and a bidi mark inside the longest word
        marks_after   => [0, sub { my $t = $u->($_[0]); $t =~ s/(\p{L})/$1\x{0301}/g ? $b8->($t) : undef }, 1],
        bidi_inword   => [1, sub { $split_word->($_[0], "\xE2\x80\x8F") }, 1],
        # the deny list's own letter variants (FOLD lines), written back into the text
        fold_variant  => [0, sub { return undef unless %VARIANT; my $t = $u->($_[0]); my $n = 0;
                                   $n += ($t =~ s/(\Q$_\E)/$VARIANT{$1}/g) for sort keys %VARIANT; $n ? $b8->($t) : undef }, 1],
        fold_drop     => [0, sub { return undef unless defined $DROP; my $t = $u->($_[0]);
                                   $t =~ s/(\p{L})(?=\p{L})/$1$DROP/ ? $b8->($t) : undef }, 1],
        apos_ent39    => [0, sub { $apos->($_[0], '&#39;') }],
        apos_entapos  => [0, sub { $apos->($_[0], '&apos;') }],
        apos_rsquo    => [0, sub { $apos->($_[0], '&rsquo;') }],
        apos_8217     => [0, sub { $apos->($_[0], '&#8217;') }],
        apos_json     => [0, sub { $apos->($_[0], '\\u2019') }],
        apos_pct      => [0, sub { $apos->($_[0], '%27') }],
        # a written control escape right before and right after the probe: JSON (also inside JSON), an
        # ICS DESCRIPTION, a Swift literal
        esc_json_n    => [0, sub { '{"d": "x\\n' . $_[0] . '\\ny"}' }, 1, $spaced],
        esc_json_t    => [0, sub { '{"d": "x\\t' . $_[0] . '\\ty"}' }, 1, $spaced],
        esc_json_crlf => [0, sub { '{"d": "x\\r\\n' . $_[0] . '\\r\\ny"}' }, 1, $spaced],
        esc_json_dbl  => [0, sub { '{"raw": "{\\"d\\":\\"x\\\\n' . $_[0] . '\\\\ny\\"}"}' }, 1, $spaced],
        esc_ics       => [0, sub { 'DESCRIPTION:x\\n' . $_[0] . '\\ny' }, 1, $spaced],
        esc_swift     => [0, sub { 'let s = "x\\t' . $_[0] . '\\r\\n"' }, 1, $spaced],
        # digits written in other scripts' decimal digits, and as fullwidth digits
        digits_0660   => [0, sub { $digits->($_[0], 0x660) }, 1],
        digits_07c0   => [0, sub { $digits->($_[0], 0x7C0) }, 1],
        digits_0966   => [0, sub { $digits->($_[0], 0x966) }, 1],
        digits_0e50   => [0, sub { $digits->($_[0], 0xE50) }, 1],
        digits_ff10   => [0, sub { $digits->($_[0], 0xFF10) }, 1],
        # non-ASCII letters as their compatibility characters (presentation forms as PDF copies produce
        # them), escaped twice; Latin letters and digits as fullwidth forms
        compat_forms  => [0, sub { my $t = $u->($_[0]); ($t =~ s/([^\x00-\x7F])/exists $COMPAT{$1} ? $COMPAT{$1} : $1/ge && $t ne $u->($_[0])) ? $b8->($t) : undef }, 1],
        json_dblu     => [0, sub { $non_ascii->($_[0], sub { $esc->($_[0], '\\\\u%04x') }) }],
        fullwidth     => [0, sub { my $t = $u->($_[0]); ($t =~ s/([A-Za-z0-9])/chr(ord($1) + 0xFEE0)/ge) ? $b8->($t) : undef }, 1],
        # a word of six or more letters in the match hyphenated at its middle over a line break
        hyph_wrap     => [1, sub {
            my ($t, $r) = @_;
            return undef unless $r && $t =~ $r->{re};
            my ($ms, $m) = ($-[0], $&);
            my ($bs, $bl) = (-1, 0);
            while ($m =~ /([A-Za-z]{6,})/g) { ($bs, $bl) = ($-[1], length $1) if length $1 > $bl }
            return undef if $bs < 0;
            my $cut = $ms + $bs + int($bl / 2);
            return undef unless substr($t, $cut, 1) =~ /[a-z]/;
            my $v = substr($t, 0, $cut) . "-\n" . substr($t, $cut);
            return (grep { $_ =~ $r->{re} } split /\n/, $v) ? undef : $v;
        }],
    );
    my (%plan, %mplan);    # kind -> [[rule, first line, last line]]
    for my $kind (sort keys %K) {
        my ($mode, $f, $safe) = @{ $K{$kind} };
        my ($body, $ln, $mbody, $mln) = ('', 1, '', 1);
        for my $id (sort keys %HITP) {
            my $r = $PR{$id} or next;
            next if $mode == 1 && $r->{flags}{short};
            next if $mode == 3 && index($r->{pat}, '/') >= 0;
            for my $t (@{ $HITP{$id} }) {
                next unless $t =~ $r->{re};
                my $v = $f->($t, $r);
                next unless defined $v && $v ne $t;
                if ($mode == 2) { my $h = $spaces->($t, '-'); next unless defined $h && $h =~ $r->{re} }
                if (my $cf = $K{$kind}[3]) { my $h = $cf->($t); next unless defined $h && $h =~ $r->{re} }
                my $n = ($v =~ tr/\n//);
                push @{ $plan{$kind} }, [$id, $ln, $ln + $n];
                $body .= "$v\n\n";
                $ln += $n + 2;
            }
        }
        if ($safe) {
            for my $s ((map { my $id = $_; map { [$id, $_] } @{ $MISSP{$id} } } sort keys %MISSP), (map { ['*', $_] } @GLOBAL_MISS)) {
                # a fold inside a word leaves a word break on the physical line itself, so the
                # short-tag look-alikes are exempt from those forms, as their rules are above
                next if $mode == 1 && $PR{ $s->[0] } && $PR{ $s->[0] }{flags}{short};
                my $v = $f->($s->[1], $PR{ $s->[0] });
                next unless defined $v && $v ne $s->[1];
                my $n = ($v =~ tr/\n//);
                push @{ $mplan{$kind} }, [$s->[0], $mln, $mln + $n];
                $mbody .= "$v\n\n";
                $mln += $n + 2;
            }
        }
        wfile("$D/disguise/$kind.txt", $body) if length $body;
        wfile("$D/disguise/miss-$kind.txt", $mbody) if length $mbody;
    }
    my ($rc, $h) = run_cp(['--tree', "$D/disguise"], priv => 1);
    my %at;
    for my $x (@$h) { $at{"$1\0$2"}{ $x->[0] } = 1 if $x->[1] =~ /\A(.+?\.txt):([0-9]+)\z/ }
    my $fired = sub { my ($file, $id, $a, $b) = @_; for my $l ($a .. $b) { return 1 if $at{"$file\0$l"}{$id} } return 0 };
    my ($nk, $np) = (0, 0);
    for my $kind (sort keys %plan) {
        my @bad = grep { !$fired->("$kind.txt", @$_) } @{ $plan{$kind} };
        $nk++;
        $np += @{ $plan{$kind} };
        ok(!@bad, "disguise $kind: " . (@{ $plan{$kind} } - @bad) . ' of ' . scalar(@{ $plan{$kind} }) . ' plants fire their rule')
          or print "  not fired: " . join(' ', map { $_->[0] } @bad) . "\n";
    }
    print "INFO disguised plants: $np over $nk forms\n";
    my (@mbad, $mn);
    for my $kind (sort keys %mplan) {
        for my $m (@{ $mplan{$kind} }) {
            $mn++;
            my ($id, $a, $b) = @$m;
            my @hit = map { keys %{ $at{"miss-$kind.txt\0$_"} || {} } } $a .. $b;
            my $m1 = $K{$kind}[0] == 1;
            push @mbad, "$kind:$id" if $id eq "*" ? grep({ $PR{$_} && !($m1 && $PR{$_}{flags}{short}) } @hit) : grep({ $_ eq $id } @hit);
        }
    }
    ok(!@mbad, 'disguise: ' . ($mn || 0) . ' look-alike samples in the same forms pass') or print "  fired: @mbad\n";
    my ($rc2, $h2) = run_cp(['--tree', "$D/disguise"], priv => 1, env => { YC_NO_PREFILTER => 1 });
    ok(join("\n", sort map { "$_->[0] $_->[1]" } @$h) eq join("\n", sort map { "$_->[0] $_->[1]" } @$h2),
       'prefilter: the literal prefilter changes no result on the disguised plants');

    # an allowed line stays allowed in the decoded forms; the same text wrapped over two lines does not
    my ($aid) = grep { my $id = $_; $PR{$id} && !$PR{$id}{flags}{short}
                       && grep({ /[A-Za-z] [A-Za-z]/ && $_ =~ $PR{$id}{re} } @{ $HITP{$id} }) } sort keys %HITP;
    if ($aid) {
        my ($t) = grep { /[A-Za-z] [A-Za-z]/ && $_ =~ $PR{$aid}{re} } @{ $HITP{$aid} };
        my $w = $wrap->($t, '');
        wfile("$D/allow4/credit.txt", "$t\n\n$w\n");
        wfile("$D/allow4-file.txt", "credit.txt : $PR{$aid}{class} : " . sha256_hex($t) . "\n");
        my ($rc4, $h4) = run_cp(['--tree', "$D/allow4"], priv => 1, env => { YC_PUBLIC_ALLOW => "$D/allow4-file.txt" });
        ok(!has($h4, $aid, qr/\Acredit\.txt:1\z/), 'allow: a digest entry still allows its line in the decoded forms');
        ok(has($h4, $aid, qr/\Acredit\.txt:[34]\z/), 'allow: the same text wrapped over two lines still fails');
    } else { skip('allow: wrapped credit line', 'no multi-word probe') }
} else { skip('deny-list plants in disguise', 'no private deny list') }

# ================================================================ 7c. names, tags and terms as identifiers
# Built here from the probes at run time, by the shape hints of each class (CLASS lines). Multi-word
# probes of the name classes joined, camelCase, PascalCase, dotted, underscored and as the local part of
# first.last@ and firstlast@ addresses; probes of the term classes as camelCase and PascalCase
# identifiers, JSON keys, enum cases and glued to a prefix or suffix; the short tags in code, config and
# file-name shapes (the prose shapes only for a tag that is not a dictionary word). Each plant must get
# a deny-list hit on its own lines. Failures name the rule or the tag's number, never the text.
if ($HAVE_PRIV) {
    my $ucf = sub { ucfirst lc $_[0] };
    my (%group, $body, $ln);
    ($body, $ln) = ('', 1);
    my $add = sub {
        my ($g, $label, $text) = @_;
        my $n = ($text =~ tr/\n//);
        push @{ $group{$g} }, [$label, $ln, $ln + $n];
        $body .= "$text\n\n";
        $ln += $n + 2;
    };
    my %seen;
    for my $id (sort keys %HITP) {
        my $r = $PR{$id} or next;
        next if $r->{flags}{short};
        for my $t (@{ $HITP{$id} }) {
            next unless $t =~ $r->{re};
            my @tk = grep { length } split /[ \t._-]+/, $&;
            next if $seen{ $r->{class} . "\0" . lc join ' ', @tk }++;
            my @l = map { lc } @tk;
            if (prop($r, 'name')) {
                next unless @tk >= 2 && @tk <= 4 && !grep { !/\A[A-Za-z]{2,}\z/ } @tk;
                my $camel = $l[0] . join '', map { $ucf->($_) } @l[1 .. $#l];
                $add->('names', "$id joined", 'Value: ' . join('', @l) . '.');
                $add->('names', "$id camelCase", "let ${camel}Email = 1");
                $add->('names', "$id PascalCase", 'struct ' . join('', map { $ucf->($_) } @l) . 'Profile {}');
                $add->('names', "$id dotted", 'user: ' . join('.', @l));
                $add->('names', "$id underscored", 'user: ' . join('_', @l));
                $add->('names', "$id first.last\@", 'mail: ' . join('.', @l) . '@example.com');
                $add->('names', "$id firstlast\@", 'mail: ' . join('', @l) . '@example.com');
            } elsif (prop($r, 'term')) {
                if (@tk >= 2 && !grep { !/\A[A-Za-z]+\z/ } @tk) {
                    my $camel = $l[0] . join '', map { $ucf->($_) } @l[1 .. $#l];
                    $add->('terms', "$id camelCase", "let ${camel}Value = 1");
                    $add->('terms', "$id PascalCase", 'struct ' . join('', map { $ucf->($_) } @l) . 'Profile {}');
                    $add->('terms', "$id JSON key", qq{{"$camel": 1}});
                    $add->('terms', "$id enum case", "    case $camel");
                } elsif (@tk == 1 && $tk[0] =~ /\A[A-Za-z][A-Za-z0-9]*\z/) {
                    $add->('terms', "$id glued after a prefix", 'let my' . $ucf->($tk[0]) . ' = 1');
                    $add->('terms', "$id glued before a suffix", 'let ' . $l[0] . 'Value = 1');
                }
            }
        }
    }
    # the short tags, as the short-tag probes show them
    my %tag;
    for my $r (grep { $_->{flags}{short} } @PR) {
        for my $t (@{ $HITP{ $r->{id} } || [] }) { $tag{ lc $& } = 1 if $t =~ $r->{re} && $& =~ /\A[A-Za-z]{3}\z/ }
    }
    my %dict;
    if (open my $wd, '<', '/usr/share/dict/words') { while (my $w = <$wd>) { chomp $w; $dict{ lc $w } = 1 } close $wd }
    my ($k, $nprose, @names) = (0, 0);
    for my $l (sort keys %tag) {
        $k++;
        my ($T, $U) = (ucfirst $l, uc $l);
        my %shape = (
            'enum case list' => "enum Kind { case first, $l, other }",
            'identifier end' => "var colorFor$T = 1",
            'identifier end, upper case' => "var isMode$U = 1",
            'snake_case tail' => "var account_$l = 1",
            'YAML key' => "$l:\n  color: blue",
            'CLI option' => "tool run --profile $l --verbose",
            'query value' => "https://x.invalid/?mode=$l&v=2",
            'folder' => "assets/$l/icon.png",
            'kebab compound' => "slug: data-$l-cache",
            'possessive' => "Open ${T}'s calendar.",
            'handle' => "\@$l on x",
            'host name' => "https://$l.invalid/docs",
            'file extension' => "Fixtures/$l.json",
        );
        if (%dict && !$dict{$l}) {
            $nprose++;
            %shape = (%shape, 'lower-case prose' => "set it to $l first", 'title-case prose' => "The $T option runs hourly.",
                      'before a dash' => "the $l-side folder");
        }
        $add->('tags', "tag$k $_", $shape{$_}) for sort keys %shape;
        push @names, ["tag$k file <tag>.json", "n$k-a/$l.json"], ["tag$k file x-<tag>-notes.md", "n$k-b/x-$l-notes.md"];
    }
    wfile("$D/ident/plants.txt", $body);
    wfile("$D/ident/$_->[1]", "x\n") for @names;
    my ($rc, $h) = run_cp(['--tree', "$D/ident"], priv => 1);
    my %at;
    for my $x (@$h) { $at{$1}{$x->[0]} = 1 if $PR{ $x->[0] } && $x->[1] =~ /\Aplants\.txt:([0-9]+)\z/ }
    for my $g (qw(names terms tags)) {
        my @p = @{ $group{$g} || [] };
        unless (@p) { skip("identifiers: $g", 'no probe of that shape'); next }
        my @bad = grep { my $p = $_; !grep { $at{$_} } $p->[1] .. $p->[2] } @p;
        my %what = (names => 'multi-word name-class plants (joined, camelCase, PascalCase, dotted, underscored, two address forms)',
                    terms => 'term-class plants (camelCase, PascalCase, JSON key, enum case, glued)',
                    tags => "short-tag plants over " . scalar(keys %tag) . " tags ($nprose with the prose shapes)");
        ok(!@bad, "identifiers: " . (@p - @bad) . ' of ' . scalar(@p) . " $what{$g} fire") or print "  not fired: " . join(', ', map { $_->[0] } @bad) . "\n";
    }
    if (@names) {
        my @bad = grep { my $dir = (split m{/}, $_->[1])[0]; !grep { $PR{ $_->[0] } && $_->[1] =~ /\A\Q$dir\E\/[^\/]*:0\z/ } @$h } @names;
        ok(!@bad, 'identifiers: ' . (@names - @bad) . ' of ' . scalar(@names) . ' short-tag file names fire') or print "  not fired: " . join(', ', map { $_->[0] } @bad) . "\n";
    }
} else { skip('identifiers: deny-list plants', 'no private deny list') }

# ================================================================ 8. allow file
{
    my @masks;
    if (open my $af, '<', "$TOOLS/public-allow.txt") {
        while (my $l = <$af>) { push @masks, [$1, $2] if $l =~ /\A\*\s+:\s+(\S+)\s+:\s+re:(.*?)\s*\z/ }
        close $af;
    }
    if ($HAVE_PRIV && @masks) {
        my (@ns, @other, $n_ok);
        for my $m (@masks) {
            my $s = gen_sample($m->[1]);
            next unless defined $s;
            my $mre = eval { qr/$m->[1]/i } or next;
            my ($line) = grep { $_ =~ $mre && grep { $_->{class} eq $m->[0] } fires_private($_) }
              ('id = "' . $s . 'calendar"', 'url = "https://' . $s . '"');
            next unless defined $line;
            push @ns, $line;
            # the same name in other places the pattern must not cover: other hosts, a subdomain,
            # prose, and the dots of a namespace read as any character
            my ($name) = $s =~ m{/([^/]+)\z} ? ($1) : $s =~ /\A[^.]+\.([^.]+)\.\z/ ? ($1) : ();
            next unless defined $name && length $name;
            push @other, grep { grep({ $_->{class} eq $m->[0] } fires_private($_)) }
              ("Follow me: https://x.com/$name/", "https://www.instagram.com/$name/", "https://twitter.com/$name",
               "https://gist.github.com/$name/", "https://gitlab.com/$name/project", "the telecom $name handle",
               "id = \"com/$name/calendar\"");
        }
        if (@other) {
            wfile("$D/allow-other/urls.txt", join("\n", @other) . "\n");
            my ($rc, $h) = run_cp(['--tree', "$D/allow-other"], priv => 1);
            my @nf = grep { my $l = $_ + 1; !grep { $_->[1] eq "urls.txt:$l" } @$h } 0 .. $#other;
            ok(!@nf, 'allow: the structural patterns do not cover the same name in ' . scalar(@other) . ' other URLs and words')
              or print "  passed wrongly: lines " . join(' ', map { $_ + 1 } @nf) . "\n";
        }
        if (@ns) {
            wfile("$D/allow/ns.txt", join("\n", @ns) . "\n");
            wfile("$D/empty-allow.txt", "");
            my ($rc, $h) = run_cp(['--tree', "$D/allow"], priv => 1);
            ok($rc == 0 && !@$h, 'allow: the ' . scalar(@ns) . ' structural patterns let their lines pass');
            ($rc, $h) = run_cp(['--tree', "$D/allow"], priv => 1, env => { YC_PUBLIC_ALLOW => "$D/empty-allow.txt" });
            ok($rc == 1, 'allow: the same lines fail without the allow file');
            my ($me) = grep { $PR{$_} && $PR{$_}{class} eq $masks[0][0] && $HITP{$_} } sort keys %HITP;
            if ($me) {
                wfile("$D/allow2/ns.txt", $ns[0] . ' ' . $HITP{$me}[0] . "\n");
                ($rc, $h) = run_cp(['--tree', "$D/allow2"], priv => 1);
                ok($rc == 1, 'allow: a structural pattern does not hide another name on the same line');
            }
        } else { skip('allow: structural patterns', 'no deny-list rule matches them') }
    } else { skip('allow: structural patterns', $HAVE_PRIV ? 'no structural entries' : 'no private deny list') }

    my $line = $GEN{'GEN-PATH-01'};
    wfile("$D/allow3/credit.txt", "$line\n$line and more\n");
    wfile("$D/custom-allow.txt", "credit.txt : GEN-PATH : " . sha256_hex($line) . "\n");
    my ($rc, $h, $out) = run_cp(['--tree', "$D/allow3"], env => { YC_PUBLIC_ALLOW => "$D/custom-allow.txt" });
    ok(!has($h, 'GEN-PATH-01', qr/\Acredit\.txt:1\z/) && has($h, 'GEN-PATH-01', qr/\Acredit\.txt:2\z/),
       'allow: a digest entry allows exactly its line, a changed line still fails');
    ok($out =~ /^INFO lines allowed by the allow files: GEN-PATH=1/m, 'allow: allowed lines are counted');
    wfile("$D/bad-allow.txt", "credit.txt : GEN-PATH\n");
    ($rc) = run_cp(['--tree', "$D/allow3"], env => { YC_PUBLIC_ALLOW => "$D/bad-allow.txt" });
    ok($rc == 2, 'allow: a malformed allow file is a configuration error (exit 2)');
}

# ================================================================ 9. configuration and usage
{
    my ($rc) = run_cp(['--strict', '--tree', "$D/plain-clean"]);
    ok($rc == 2, 'strict: a missing deny list is exit 2');
    ($rc) = run_cp(['--tree']);
    ok($rc == 2, 'usage: --tree without a target is exit 2');
    ($rc) = run_cp(['--tree', "$D/plain-clean", '--staged']);
    ok($rc == 2, 'usage: two modes are exit 2');
    wfile("$D/bad-rules.txt", "GEN-X-01\tGEN-X\t-\n");
    ($rc) = run_cp(['--tree', "$D/plain-clean"], env => { YC_PUBLIC_RULES => "$D/bad-rules.txt" });
    ok($rc == 2, 'config: a malformed rules file is exit 2');
}

# ================================================================ 10. Tools/check-secrets.sh outside a git checkout
{
    my $z = "$D/zip";
    make_path("$z/Tools/check-public");
    copy("$TOOLS/check-secrets.sh", "$z/Tools/check-secrets.sh");
    copy("$TOOLS/public-rules.txt", "$z/Tools/public-rules.txt");
    copy("$TOOLS/check-public/$_", "$z/Tools/check-public/$_") for qw(engine.pl images.pl);
    wfile("$z/Sources/a.txt", $GEN{'GEN-SECRET-03'} . "\n");
    my ($rc, $out) = run_cmd(['/bin/zsh', "$z/Tools/check-secrets.sh"]);
    ok($rc == 1 && $out =~ m{Sources/a\.txt}, 'check-secrets: a source folder without git is scanned with find');
    unlink "$z/Sources/a.txt";
    wfile("$z/Config/oauth.local.json", $GEN{'GEN-SECRET-01'} . "\n");
    wfile("$z/build/out.txt", $GEN{'GEN-SECRET-01'} . "\n");
    ($rc, $out) = run_cmd(['/bin/zsh', "$z/Tools/check-secrets.sh"]);
    ok($rc == 0, 'check-secrets: local config and build output stay out of the source scan');
    wfile("$z/Sources/b.txt", $GEN{'GEN-SECRET-10'} . "\n");
    ($rc, $out) = run_cmd(['/bin/zsh', "$z/Tools/check-secrets.sh"]);
    ok($rc == 1, 'check-secrets: the added shapes are checked');
    ($rc, $out) = run_cmd(['/bin/zsh', "$z/Tools/check-secrets.sh", "$D/Dirty.app"]);
    ok($rc == 1 && $out =~ /Dirty/, 'check-secrets: a bundle path is scanned');
}

# ================================================================ 11. nothing personal in the output
# Names that only the decoded, normalized form shows (a zero-width space inside, combining marks, %XX) and an
# address used as a file name are reported with the whole path component blanked; files shorter than a
# magic number raise no warning, and no message carries the home folder.
{
    require Encode;
    my $dir = "$D/names";
    my $mail = j('jane.doe', '@', 'orbitrail', '.io');
    wfile("$dir/$mail.md", "x\n");
    wfile("$dir/empty.bin", '');
    wfile("$dir/two.bin", "\0\x01");
    my @needles = ($mail, $HOME_PREFIX);
    push @needles, $ENV{HOME} if length($ENV{HOME} // '') > 1;
    my ($first, $nonascii, $nplant) = (undef, undef, 0);
    if ($HAVE_PRIV) {
        for my $r (grep { prop($_, 'name') && !$_->{flags}{short} } @PR) {
            for my $t (@{ $HITP{ $r->{id} } || [] }) {
                next unless $t =~ $r->{re};
                my $m = $&;
                $first //= $m if $m =~ /\A[A-Za-z]{4,}\z/;
                $nonascii //= $m if $m =~ /\A[\xC2-\xF4][\x80-\xBF]/ && Encode::decode('UTF-8', $m) =~ /\A\p{L}{2,}\z/;
            }
        }
        if (defined $first) {
            my $h = int(length($first) / 2);
            my $zw = substr($first, 0, $h) . "\xE2\x80\x8B" . substr($first, $h);
            my $pct = join '', map { sprintf '%%%02X', ord } split //, $first;
            wfile("$dir/doc-$zw-notes.md", "x\n");
            wfile("$dir/doc-$pct-notes.md", "x\n");
            push @needles, $first, $zw, $pct;
            $nplant += 2;
        }
        if (defined $nonascii) {
            my $a = Encode::decode('UTF-8', $nonascii);
            my $marked = Encode::encode('UTF-8', substr($a, 0, 1) . "\x{0301}" . substr($a, 1));
            wfile("$dir/doc-$marked-notes.md", "x\n");
            push @needles, $nonascii, $marked;
            $nplant++;
        }
    }
    my ($rc, $h, $out) = run_cp(['--tree', $dir], priv => 1);
    my $found = grep { index($out, $_) >= 0 } @needles;
    ok(!$found, 'output: none of ' . scalar(@needles) . ' names, addresses and home-folder strings is printed');
    ok(!grep({ /\AWARN/ && !/deny list not found/ } split /\n/, $out), 'output: files shorter than a magic number raise no warning');
    ok(has($h, 'GEN-MAIL-01', qr/\A\*\*\*(?:\.md)?:0\z/), 'output: an address used as a file name is reported, blanked');
    if ($nplant) {
        my $n = grep { $PR{ $_->[0] } && $_->[1] =~ /\A\*\*\*:0\z/ } @$h;
        ok($n >= $nplant, "output: $nplant disguised names in file names are reported with the component blanked");
    } else { skip('output: disguised names in file names', $HAVE_PRIV ? 'no single-word name probe' : 'no private deny list') }
}

# ---------------------------------------------------------------- sample generator
# Best effort: the first branch of every alternation, minimum repeats, '.' as '.', lookarounds skipped.
# Used only when the probe file has no hit sample for a rule, and for the structural allow patterns;
# each sample is checked against its rule before use.
sub gen_sample { my ($p) = @_; my $i = 0; my $s = eval { gen_alt($p, \$i) }; return (defined $s && $i == length $p) ? $s : undef }
sub gen_alt {
    my ($p, $ip) = @_;
    my $first = gen_seq($p, $ip);
    while ($$ip < length $p && substr($p, $$ip, 1) eq '|') { $$ip++; gen_seq($p, $ip) }
    return $first;
}
sub gen_seq {
    my ($p, $ip) = @_;
    my $out = '';
    while ($$ip < length $p) {
        my $c = substr($p, $$ip, 1);
        last if $c eq '|' || $c eq ')';
        my $a = gen_atom($p, $ip);
        $out .= $a x gen_quant($p, $ip);
    }
    return $out;
}
sub gen_quant {
    my ($p, $ip) = @_;
    my $c = substr($p, $$ip, 1);
    my $min = 1;
    if    ($c eq '*' || $c eq '?') { $min = 0; $$ip++ }
    elsif ($c eq '+') { $$ip++ }
    elsif ($c eq '{' && substr($p, $$ip) =~ /\A\{([0-9]+)(?:,[0-9]*)?\}/) { $min = $1; $$ip += length $& }
    else { return 1 }
    $$ip++ if $$ip < length $p && substr($p, $$ip, 1) =~ /[?+]/;
    return $min;
}
sub gen_atom {
    my ($p, $ip) = @_;
    my $c = substr($p, $$ip, 1);
    my $rest = substr($p, $$ip);
    if ($c eq '(') {
        my $look = 0;
        if    ($rest =~ /\A\(\?(?:<[!=]|[!=])/)                { $look = 1; $$ip += length $& }
        elsif ($rest =~ /\A\(\?\^?[a-wyzA-Z-]*:/)               { $$ip += length $& }
        elsif ($rest =~ /\A\(\?\^?[a-wyzA-Z-]+\)/)              { $$ip += length $&; return '' }
        elsif ($rest =~ /\A\(\?(?:P?<[A-Za-z_][A-Za-z0-9_]*>|[>|])/) { $$ip += length $& }
        elsif ($rest =~ /\A\(\?/)                               { die "unsupported\n" }
        else                                                    { $$ip++ }
        my $s = gen_alt($p, $ip);
        die "unbalanced\n" unless substr($p, $$ip, 1) eq ')';
        $$ip++;
        return $look ? '' : $s;
    }
    if ($c eq '[') {
        my $j = $$ip + 1;
        my $neg = substr($p, $j, 1) eq '^' ? do { $j++; 1 } : 0;
        my ($first, %in, @order) = (1);
        while ($j < length $p) {
            my $d = substr($p, $j, 1);
            last if $d eq ']' && !$first;
            $first = 0;
            my $ch;
            if ($d eq '\\') {
                my $e = substr($p, $j + 1, 1);
                $j += 2;
                if    ($e eq 'd') { $in{$_} = 1, push @order, $_ for 0 .. 9; next }
                elsif ($e eq 'w') { $in{$_} = 1, push @order, $_ for 'a' .. 'z', 'A' .. 'Z', 0 .. 9, '_'; next }
                elsif ($e eq 's') { $in{' '} = 1; push @order, ' '; next }
                $ch = $e;
            } else { $ch = $d; $j++ }
            if (substr($p, $j, 1) eq '-' && substr($p, $j + 1, 1) ne ']') {
                my $hi = substr($p, $j + 1, 1);
                $j += 2;
                $in{ chr $_ } = 1, push @order, chr $_ for ord($ch) .. ord($hi);
                next;
            }
            $in{$ch} = 1;
            push @order, $ch;
        }
        $$ip = $j + 1;
        if ($neg) { for ('a', '1', ' ', '-', '.', 'x') { return $_ unless $in{$_} } die "no char\n" }
        return $order[0];
    }
    if ($c eq '\\') {
        my $e = substr($p, $$ip + 1, 1);
        $$ip += 2;
        return ''  if $e =~ /[bBAzZG]/;
        return '1' if $e eq 'd';
        return 'a' if $e =~ /[wSD]/;
        return ' ' if $e =~ /[sh]/;
        return '-' if $e eq 'W';
        return "\t" if $e eq 't';
        if ($e eq 'x' && substr($p, $$ip) =~ /\A\{?([0-9A-Fa-f]{1,2})\}?/) { $$ip += length $&; return chr hex $1 }
        return $e if $e =~ /[^A-Za-z0-9]/;
        die "unsupported escape\n";
    }
    if ($c eq '.') { $$ip++; return '.' }
    if ($c eq '^' || $c eq '$') { $$ip++; return '' }
    $$ip++;
    return $c;
}

# ---------------------------------------------------------------- done
remove_tree($D) unless $ENV{YC_SELFTEST_KEEP};
print "SELF-TEST: $PASS passed, $FAIL failed, $SKIP skipped"
  . ($HAVE_PRIV ? '' : ' (no private deny list: deny-list cases skipped, generic rules only)') . "\n";
exit($FAIL ? 1 : 0);
