# Tools/check-public/images.pl: metadata parser for images and documents, loaded by engine.pl.
#
# mdls and `sips -g all` do not show ancillary PNG chunks, JPEG application segments or PDF info
# dictionaries, so this file reads the bytes itself. Pure perl, stock macOS modules only.
#
# Rule ids (class IMG):
#   IMG-01  PNG chunk outside the whitelist (IHDR PLTE tRNS IDAT IEND sRGB iCCP pHYs gAMA cHRM),
#           or bytes after IEND
#   IMG-02  colour profile (PNG iCCP, WebP ICCP) whose name or description is not a generic one
#   IMG-03  JPEG APP1 segment (EXIF or XMP)
#   IMG-04  JPEG APP11 segment (JUMBF, content credentials)
#   IMG-05  JPEG APP13 segment (IPTC, Photoshop resources)
#   IMG-06  JPEG COM comment segment, or bytes after EOI
#   IMG-07  PDF XMP packet or metadata stream
#   IMG-08  PDF Author set, or Creator/Producer/Title/Subject/Keywords naming a person or a machine,
#           or a Creator/Producer that is not a known generic tool
#   IMG-09  damaged file, or a binary kind this parser cannot read (review by eye)
#   IMG-10  GIF comment or application extension other than looping, WebP chunk outside the whitelist
#   IMG-11  ICNS element outside the icon whitelist (for example info or name)
package CPImages;

use strict;
use warnings;
use Compress::Raw::Zlib ();
use Encode ();

my %PNG_OK = map { $_ => 1 } qw(IHDR PLTE tRNS IDAT IEND sRGB iCCP pHYs gAMA cHRM);

# Generic colour profile descriptions (ICC 'desc' or 'mluc' text) and iCCP chunk names.
my %ICC_DESC_OK = map { $_ => 1 } (
    'sRGB IEC61966-2.1', 'sRGB', 'Display P3', 'Generic Gray Profile', 'Generic Gray Gamma 2.2 Profile',
);
my %ICCP_NAME_OK = map { lc($_) => 1 } (
    'ICC Profile', 'icc', 'sRGB IEC61966-2.1', 'sRGB', 'Display P3', 'Generic Gray Profile',
    'Generic Gray Gamma 2.2 Profile', 'kCGColorSpaceDisplayP3', 'kCGColorSpaceSRGB',
);

my %ICNS_OK = map { $_ => 1 } split /\s+/, q(
    TOC  icnV ic04 ic05 ic06 ic07 ic08 ic09 ic10 ic11 ic12 ic13 ic14 icp4 icp5 icp6
    is32 il32 ih32 it32 s8mk l8mk h8mk t8mk ICN# icm# ics# ich# icl4 icl8 ics4 ics8
    ich4 ich8 icm4 icm8 icsb icsB sb24 SB24
);
$ICNS_OK{'TOC '} = 1;

my %WEBP_OK = map { $_ => 1 } ('VP8 ', 'VP8L', 'VP8X', 'ALPH', 'ANIM', 'ANMF', 'ICCP');
my %GIF_APP_OK = map { $_ => 1 } ('NETSCAPE2.0', 'ANIMEXTS1.0');

# Creator and Producer values that name a tool and nothing else.
my @PDF_TOOL_OK = (
    qr/\AmacOS Version [0-9.]+ \(Build [0-9A-Za-z]+\) Quartz PDFContext\z/,
    qr/\AMac OS X [0-9.]+ Quartz PDFContext\z/,
    qr/\AQuartz PDFContext\z/,
    qr/\ASkia\/PDF m[0-9]+\z/,
    qr/\A(?:Chromium|Google Chrome|WebKit|Safari|Preview|Pages|Keynote|Numbers|TextEdit)\z/,
    qr/\ALibreOffice [0-9.]+\z/,
    qr/\AGPL Ghostscript [0-9.]+\z/,
    qr/\ApdfTeX-[0-9.-]+\z/,
    qr/\ALaTeX with hyperref(?: package)?\z/,
    qr/\ATypst [0-9.]+\z/,
);

# Machine names: host names, Mac models, "<name>'s Mac", absolute home folders.
my $HOME_PREFIX = '/Use' . 'rs/';
my $MACHINE_RE = qr/\.local\b|MacBook|\biMac\b|Mac ?mini|Mac Studio|Mac Pro|['\x{2019}]s (?:Mac|MacBook|iMac|Computer|PC|Laptop)\b|\Q$HOME_PREFIX\E/i;

sub kind {
    my ($b) = @_;
    # the first 16 bytes, padded, so a file shorter than a magic number is never read past its end
    my $h = substr($b, 0, 16) . ("\x01" x 16);    # \x01 completes no magic number
    my $m4 = substr($h, 0, 4);
    return 'png'  if substr($h, 0, 8) eq "\x89PNG\r\n\x1a\n";
    return 'jpeg' if substr($h, 0, 3) eq "\xFF\xD8\xFF";
    return 'icns' if $m4 eq 'icns';
    return 'gif'  if substr($h, 0, 6) =~ /\AGIF8[79]a\z/;
    return 'webp' if $m4 eq 'RIFF' && substr($h, 8, 4) eq 'WEBP';
    return 'pdf'  if $b =~ /\A(?:\xEF\xBB\xBF)?[\t\r\n ]*%PDF-/;
    return 'tiff' if $m4 eq "II*\0" || $m4 eq "MM\0*";
    return 'heif' if substr($h, 4, 4) eq 'ftyp' && substr($h, 8, 4) =~ /\A(?:heic|heix|hevc|mif1|msf1|avif)\z/;
    return 'macho' if $m4 eq "\xCF\xFA\xED\xFE" || $m4 eq "\xCE\xFA\xED\xFE" || $m4 eq "\xCA\xFE\xBA\xBE";
    return 'other';
}

# Raster kinds whose pixel data is compressed; text rules are not run over their bytes.
sub is_raster { my ($k) = @_; return $k =~ /\A(?:png|jpeg|icns|gif|webp)\z/ ? 1 : 0 }

# check(\$bytes, $loc, $rep, $textcheck) -> "kind details" for the eye-check line.
#   $rep->($rule_id, "$loc:$offset", $review_by_eye)
#   $textcheck->($string) is true when a deny-list or generic rule matches the string.
sub check {
    my ($bref, $loc, $rep, $textcheck) = @_;
    my $k = kind($$bref);
    return 'png ' . png($$bref, $loc, $rep, $textcheck)   if $k eq 'png';
    return 'jpeg ' . jpeg($$bref, $loc, $rep)             if $k eq 'jpeg';
    return 'icns ' . icns($$bref, $loc, $rep, $textcheck) if $k eq 'icns';
    return 'pdf ' . pdf($$bref, $loc, $rep, $textcheck)   if $k eq 'pdf';
    return 'gif ' . gif($$bref, $loc, $rep)               if $k eq 'gif';
    return 'webp ' . webp($$bref, $loc, $rep, $textcheck) if $k eq 'webp';
    $rep->('IMG-09', "$loc:0", 1);
    return "$k unsupported";
}

sub inflate {
    my ($data) = @_;
    my ($inf, $st) = Compress::Raw::Zlib::Inflate->new(-ConsumeInput => 1, -LimitOutput => 0);
    return undef unless $inf;
    my $out = '';
    my $s = $inf->inflate($data, $out);
    return ($s == Compress::Raw::Zlib::Z_OK() || $s == Compress::Raw::Zlib::Z_STREAM_END()) ? $out : undef;
}

sub png {
    my ($b, $loc, $rep, $textcheck) = @_;
    my $n = length $b;
    my ($p, $end, $w, $h) = (8, 0, 0, 0);
    my (@seen, %seen);
    while ($p + 8 <= $n) {
        my ($len, $type) = unpack 'N a4', substr($b, $p, 8);
        if ($type !~ /\A[A-Za-z]{4}\z/ || $p + 12 + $len > $n) { $rep->('IMG-09', "$loc:$p", 1); return 'damaged' }
        push @seen, $type unless $seen{$type}++;
        ($w, $h) = unpack 'NN', substr($b, $p + 8, 8) if $type eq 'IHDR' && $len >= 8;
        if (!$PNG_OK{$type})   { $rep->('IMG-01', "$loc:$p") }
        elsif ($type eq 'iCCP') { iccp(substr($b, $p + 8, $len), "$loc:$p", $rep, $textcheck) }
        $p += 12 + $len;
        if ($type eq 'IEND') { $end = 1; last }
    }
    if (!$end)     { $rep->('IMG-09', "$loc:$p", 1) }
    elsif ($p < $n) { $rep->('IMG-01', "$loc:$p") }
    return "${w}x${h} chunks=" . join(',', @seen);
}

sub iccp {
    my ($d, $where, $rep, $textcheck) = @_;
    my $z = index($d, "\0");
    if ($z < 1 || $z > 79 || length($d) < $z + 3) { $rep->('IMG-02', $where); return }
    my $name = substr($d, 0, $z);
    my $prof = ord(substr($d, $z + 1, 1)) == 0 ? inflate(substr($d, $z + 2)) : undef;
    my @desc = defined $prof ? icc_desc($prof) : ();
    my $ok = $ICCP_NAME_OK{ lc $name } && @desc && !grep { !$ICC_DESC_OK{$_} } @desc;
    $ok = 0 if $ok && $textcheck && grep { $textcheck->($_) } ($name, @desc);
    $rep->('IMG-02', $where) unless $ok;
}

# Every text of the ICC 'desc' tag ('desc' type: one ASCII string; 'mluc' type: one per locale).
sub icc_desc {
    my ($p) = @_;
    my $n = length $p;
    return () if $n < 132;
    my $count = unpack 'N', substr($p, 128, 4);
    for my $i (0 .. $count - 1) {
        my $e = 132 + 12 * $i;
        last if $e + 12 > $n;
        my ($sig, $o, $sz) = unpack 'a4 N N', substr($p, $e, 12);
        next unless $sig eq 'desc';
        return () if $o + 16 > $n;
        my $type = substr($p, $o, 4);
        if ($type eq 'desc') {
            my $len = unpack 'N', substr($p, $o + 8, 4);
            my $s = substr($p, $o + 12, $len);
            $s =~ s/\0.*\z//s;
            return ($s);
        }
        if ($type eq 'mluc') {
            my ($nrec, $rsz) = unpack 'N N', substr($p, $o + 8, 8);
            my @out;
            for my $k (0 .. $nrec - 1) {
                my $r = $o + 16 + $k * ($rsz || 12);
                last if $r + 12 > $n;
                my ($len, $so) = unpack 'N N', substr($p, $r + 4, 8);
                last if $o + $so + $len > $n;
                my $u = eval { Encode::decode('UTF-16BE', substr($p, $o + $so, $len)) };
                return () unless defined $u;
                $u =~ s/\0+\z//;
                push @out, Encode::encode('UTF-8', $u);
            }
            return @out;
        }
        return ();
    }
    return ();
}

sub jpeg {
    my ($b, $loc, $rep) = @_;
    my $n = length $b;
    my $p = 2;
    my (@seen, %seen);
    my $eoi = 0;
    while ($p < $n) {
        if (ord(substr($b, $p, 1)) != 0xFF) { $rep->('IMG-09', "$loc:$p", 1); return 'damaged' }
        my $at = $p;
        $p++ while $p < $n && ord(substr($b, $p, 1)) == 0xFF;
        last if $p >= $n;
        my $m = ord(substr($b, $p, 1));
        $p++;
        my $name = sprintf 'FF%02X', $m;
        push @seen, $name unless $seen{$name}++;
        if ($m == 0xD9) { $eoi = 1; last }
        next if ($m >= 0xD0 && $m <= 0xD7) || $m == 0x01;
        if ($p + 2 > $n) { $rep->('IMG-09', "$loc:$at", 1); return 'damaged' }
        my $len = unpack 'n', substr($b, $p, 2);
        if ($len < 2 || $p + $len > $n) { $rep->('IMG-09', "$loc:$at", 1); return 'damaged' }
        $rep->('IMG-03', "$loc:$at") if $m == 0xE1;
        $rep->('IMG-04', "$loc:$at") if $m == 0xEB;
        $rep->('IMG-05', "$loc:$at") if $m == 0xED;
        $rep->('IMG-06', "$loc:$at") if $m == 0xFE;
        $p += $len;
        if ($m == 0xDA) {    # entropy-coded data runs to the next marker that is not stuffing or RSTn
            while (1) {
                my $f = index($b, "\xFF", $p);
                if ($f < 0 || $f + 1 >= $n) { $p = $n; last }
                my $x = ord(substr($b, $f + 1, 1));
                if ($x == 0x00 || ($x >= 0xD0 && $x <= 0xD7) || $x == 0xFF) { $p = $f + 1; next }
                $p = $f;
                last;
            }
        }
    }
    if (!$eoi)      { $rep->('IMG-09', "$loc:$p", 1) }
    elsif ($p < $n) { $rep->('IMG-06', "$loc:$p") }
    return 'segments=' . join(',', @seen);
}

sub icns {
    my ($b, $loc, $rep, $textcheck) = @_;
    my $n = length $b;
    my $p = 8;
    my @types;
    while ($p + 8 <= $n) {
        my ($t, $len) = unpack 'a4 N', substr($b, $p, 8);
        if ($len < 8 || $p + $len > $n) { $rep->('IMG-09', "$loc:$p", 1); last }
        (my $tn = $t) =~ s/[^\x21-\x7E]/?/g;
        push @types, $tn;
        my $d = substr($b, $p + 8, $len - 8);
        if (!$ICNS_OK{$t}) { $rep->('IMG-11', "$loc:$p") }
        elsif (substr($d, 0, 8) eq "\x89PNG\r\n\x1a\n") { png($d, "$loc#$tn", $rep, $textcheck) }
        $p += $len;
    }
    return 'elements=' . join(',', @types);
}

sub pdf_string {    # value at $pos: (literal) or <hex>; returns decoded bytes (UTF-8 when it had a BOM)
    my ($s, $pos) = @_;
    my $c = substr($s, $pos, 1);
    my $v = '';
    if ($c eq '(') {
        my ($d, $i) = (1, $pos + 1);
        while ($i < length $s && $d > 0) {
            my $ch = substr($s, $i, 1);
            if ($ch eq '\\') {
                my $nx = substr($s, $i + 1, 1);
                if ($nx =~ /[0-7]/) { my ($oct) = substr($s, $i + 1, 3) =~ /\A([0-7]{1,3})/; $v .= chr(oct $oct); $i += 1 + length $oct; next }
                my %e = (n => "\n", r => "\r", t => "\t", b => "\b", f => "\f");
                $v .= exists $e{$nx} ? $e{$nx} : $nx;
                $i += 2;
                next;
            }
            $d++ if $ch eq '(';
            $d-- if $ch eq ')';
            $v .= $ch if $d > 0;
            $i++;
        }
    } elsif ($c eq '<') {
        my $e = index($s, '>', $pos);
        return '' if $e < 0;
        (my $hex = substr($s, $pos + 1, $e - $pos - 1)) =~ s/[^0-9A-Fa-f]//g;
        $hex .= '0' if length($hex) % 2;
        $v = pack 'H*', $hex;
    }
    if (substr($v, 0, 2) eq "\xFE\xFF") {
        my $u = eval { Encode::decode('UTF-16BE', substr($v, 2)) };
        $v = defined $u ? Encode::encode('UTF-8', $u) : '';
    }
    return $v;
}

sub pdf {
    my ($b, $loc, $rep, $textcheck) = @_;
    my @bufs = ([$b, 0]);
    my $streams = 0;
    while ($b =~ /stream\r?\n/g) {
        my ($ds, $s) = ($-[0], $+[0]);
        my $e = index($b, 'endstream', $s);
        last if $e < 0;
        my $open = rindex($b, '<<', $ds);
        my $dict = $open >= 0 && $ds - $open < 4096 ? substr($b, $open, $ds - $open) : '';
        $streams++;
        $rep->('IMG-07', "$loc:$ds") if $dict =~ m{/Type\s*/Metadata\b|/Subtype\s*/XML\b};
        if ($dict =~ m{/FlateDecode\b} && $e - $s < 50_000_000) {
            my $u = inflate(substr($b, $s, $e - $s));
            push @bufs, [$u, $ds] if defined $u;
        }
        pos($b) = $e;
    }
    my $fields = 0;
    for my $pair (@bufs) {
        my ($x, $base) = @$pair;
        for my $mark ('<?xpacket', '<x:xmpmeta', 'adobe:ns:meta') {
            my $at = index($x, $mark);
            if ($at >= 0) { $rep->('IMG-07', "$loc:" . ($base || $at)); last }
        }
        $rep->('IMG-07', "$loc:" . ($base || $-[0])) if $x =~ m{/Metadata\s+[0-9]+\s+[0-9]+\s+R\b};
        while ($x =~ m{/(Author|Creator|Producer|Title|Subject|Keywords)\s*(?=[(<])(?!<<)}g) {
            my ($key, $at) = ($1, $-[0]);
            my $v = pdf_string($x, $+[0]);
            $v =~ s/\A\s+|\s+\z//g;
            next unless length $v;
            $fields++;
            my $where = "$loc:" . ($base || $at);
            if ($key eq 'Author') { $rep->('IMG-08', $where); next }
            if (($textcheck && $textcheck->($v)) || $v =~ $MACHINE_RE) { $rep->('IMG-08', $where); next }
            next unless $key eq 'Creator' || $key eq 'Producer';
            $rep->('IMG-08', $where, 1) unless grep { $v =~ $_ } @PDF_TOOL_OK;
        }
    }
    return "streams=$streams info-fields=$fields";
}

sub gif {
    my ($b, $loc, $rep) = @_;
    my $n = length $b;
    if ($n < 13) { $rep->('IMG-09', "$loc:0", 1); return 'damaged' }
    my ($w, $h, $f) = unpack 'v v C', substr($b, 6, 5);
    my $p = 13;
    $p += 3 * (2**(($f & 7) + 1)) if $f & 0x80;
    my $trailer = 0;
    my $skip = sub { my ($q) = @_; while ($q < $n) { my $bs = ord(substr($b, $q, 1)); $q += 1 + $bs; last if $bs == 0 } return $q };
    while ($p < $n) {
        my $c = ord(substr($b, $p, 1));
        if ($c == 0x3B) { $p++; $trailer = 1; last }
        if ($c == 0x21) {
            my $label = ord(substr($b, $p + 1, 1));
            if ($label == 0xFE) { $rep->('IMG-10', "$loc:$p") }
            if ($label == 0xFF) {
                my $bs = ord(substr($b, $p + 2, 1));
                $rep->('IMG-10', "$loc:$p") unless $GIF_APP_OK{ substr($b, $p + 3, $bs) };
            }
            $p = $skip->($p + 2);
            next;
        }
        if ($c == 0x2C) {
            my $lf = ord(substr($b, $p + 9, 1));
            my $q = $p + 10;
            $q += 3 * (2**(($lf & 7) + 1)) if $lf & 0x80;
            $p = $skip->($q + 1);
            next;
        }
        $rep->('IMG-09', "$loc:$p", 1);
        return 'damaged';
    }
    if (!$trailer)  { $rep->('IMG-09', "$loc:$p", 1) }
    elsif ($p < $n) { $rep->('IMG-10', "$loc:$p") }
    return "${w}x${h}";
}

sub webp {
    my ($b, $loc, $rep, $textcheck) = @_;
    my $n = length $b;
    my $p = 12;
    my (@seen, %seen);
    while ($p + 8 <= $n) {
        my ($t, $len) = unpack 'a4 V', substr($b, $p, 8);
        (my $tn = $t) =~ s/[^\x20-\x7E]/?/g;
        push @seen, $tn unless $seen{$tn}++;
        if (!$WEBP_OK{$t}) { $rep->('IMG-10', "$loc:$p") }
        elsif ($t eq 'ICCP') {
            my @desc = icc_desc(substr($b, $p + 8, $len));
            my $ok = @desc && !grep { !$ICC_DESC_OK{$_} } @desc;
            $ok = 0 if $ok && $textcheck && grep { $textcheck->($_) } @desc;
            $rep->('IMG-02', "$loc:$p") unless $ok;
        }
        $p += 8 + $len + ($len & 1);
    }
    return 'chunks=' . join(',', @seen);
}

1;
