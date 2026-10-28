#!/bin/zsh
# Rich mail gate (D-040 to D-044): the checks Tools/gate.sh p4 doesn't make. Standalone and headless.
#
#   Tools/gate-richmail.sh <render dir> <build log>
#
# <render dir>  the output of `./build.sh --test --render <dir>` (rm-*.png + render-manifest.json)
# <build log>   the full log of that same run (the tests, then the render run's RICHMAIL-BENCH lines)
# The built app is read from build/ (its widget extension for the isolation check), so run this right after the build.
#
#  1 renders      every rm-* render of the rich-mail render list; reader, Peek and window renders are web snapshots
#                 (a text fallback is a warning)
#  2 tests        the "▸ Rich mail: …" shell sections and the data suite "rich mail" ran, 0 failed anywhere
#  3 appex        `nm -a` on the widget extension shows no rich-mail symbol (outbox, MIME builder, attachment cache,
#                 HTML writer/reader, cid handler, attachment UI); its entitlements, build.sh, Sources/Shared and
#                 Sources/Widget are unchanged
#  4 scopes/hosts the OAuth scope lists and HTTP.allowedHosts equal the base; added https literals in Net, Providers and
#                 Auth stay on allowed hosts
#  5 ban list     no AppKit HTML import/export, no content JavaScript, no quarantine opt-out
#  6 bench        every RICHMAIL-BENCH line with a budget is within 2× of it, and the expected lines are there
#  7 cast only    rich-mail fixtures, renders code, tests, goldens and the rm-* manifest entries: addresses only on
#                 *.example (or the app's own Message-ID domain), URLs on *.example (or Gmail, or the W3C and Dublin
#                 Core XML namespaces, which name a vocabulary and are never fetched), names only from the
#                 rich-mail cast; the rm-* PNGs through OCR when YC_OCR names an OCR tool, and the OCR text and manifest
#                 strings through check-public's private deny list when it is around (rule ids only, never the text)
#  8 D-023        the approval overlay, card, key monitor and approval model are byte-identical to the base, and the
#                 old mail tests are unmodified
#  9 memory       MIMEBuilder.buildRich in its own process (/usr/bin/time -l): a message just under the 25,000,000-byte
#                 limit and one with a 25 MB attachment; peak extra memory over a baseline run (same process, same file,
#                 no build) ≤ 2 × 80 MB, time ≤ 2 × 1.5 s
#
# Environment: YC_RICHMAIL_BASE (default `main`): the ref checks 3, 4 and 8 compare with. After rich mail is merged into
# a branch with its own changes, pass that branch's commit before the merge. YC_RICHMAIL_OWN (optional, `A..B`): rich
# mail's own commits; when set, check 3's "build.sh, entitlements, Sources/Shared and Sources/Widget unchanged" reads
# that range instead of the base against the worktree, so the branch's later edits there (its own phases) don't count.
# The app is the build profile's (Profile.swift: the dev app when build/ has it, else the release app). YC_OCR (optional):
# an OCR tool that takes PNG paths and prints "file<TAB>text" per line; without it the OCR step is skipped.
# YC_CHECK_PUBLIC: check-public.sh (default: Tools/check-public.sh when this tree has it).
# Never opens, installs, registers or sends anything. Compiles one small benchmark under the global build lock. Writes
# only under .work/gate-richmail/.
set -euo pipefail
setopt extendedglob nullglob
YC_ROOT="${0:A:h:h}"; ROOT="$YC_ROOT"
source "$ROOT/Tools/lib/common.zsh"
zmodload zsh/datetime
trap yc_lock_release EXIT
trap 'yc_lock_release; exit 130' INT TERM

(( $# == 2 )) || yc_fail "usage: Tools/gate-richmail.sh <render dir> <build log>"
RENDERS="${1:A}"; BUILDLOG="${2:A}"
[[ -d "$RENDERS" ]] || yc_fail "no render folder: $1"
[[ -f "$BUILDLOG" ]] || yc_fail "no build log: $2"
BASE="${YC_RICHMAIL_BASE:-main}"
git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || yc_fail "base ref not found: $BASE"
APP="$ROOT/build/Yaya's Calendar.app"; WIDGET_DIR="/Library/Application Support/YayasCalendar/widget/"
if (( $+functions[yc_profile] )) && [[ -f "$ROOT/Sources/Shared/Profile.swift" ]]; then
  # Profiles (D-034): gate p4 builds the dev app; its widget reads the dev data folder.
  for prof in dev release; do
    yc_profile "$prof"
    if [[ -d "$ROOT/build/${YC_PROFILE[displayName]}.app" ]]; then
      APP="$ROOT/build/${YC_PROFILE[displayName]}.app"; WIDGET_DIR="/${YC_PROFILE[dataRoot]}/widget/"; break
    fi
  done
fi
OWN="${YC_RICHMAIL_OWN:-}"
[[ -z "$OWN" ]] || git -C "$ROOT" rev-parse --verify --quiet "${OWN%%..*}^{commit}" >/dev/null || yc_fail "range not found: $OWN"
APPEX="$APP/Contents/PlugIns/YayasCalendarWidget.appex"
APPEX_BIN="$APPEX/Contents/MacOS/YayasCalendarWidget"
LOGS="$ROOT/.work/gate-richmail"; rm -rf "$LOGS"; mkdir -p "$LOGS"
MANIFEST="$RENDERS/render-manifest.json"

typeset -a RESULTS FAILED WARNINGS
pass() { RESULTS+=( "| $1 | ✅ pass | $2 |" ) }
fail() { RESULTS+=( "| $1 | ❌ FAIL | $2 |" ); FAILED+=( "$1" ) }
warn() { WARNINGS+=( "$1" ) }
started=$EPOCHREALTIME

# The rm-* objects of the render manifest, one per line.
typeset -a RM_OBJECTS
[[ -f "$MANIFEST" ]] && RM_OBJECTS=( "${(@f)$(tr -d '\n' < "$MANIFEST" | grep -oE '\{[^{}]*"file" *: *"rm-[^{}]*\}' || true)}" )
mfield() { print -r -- "$1" | sed -nE "s/.*\"$2\" *: *\"?([^\",}]*)\"?.*/\1/p" | head -1 | sed 's/ *$//' }

# ── 1. Renders: the rich-mail render list ────────────────────────────────────────────────────────
typeset -a expected
for n in reader-html-{light,dark} reader-html-narrow reader-remote-blocked reader-plain-{light,dark} \
         reader-quoted-collapsed-{light,dark} reader-quoted-expanded-{light,dark} reader-quoted-outlook reader-quoted-apple \
         reader-attachments-{light,dark} reader-inline-images-{light,dark} reader-hover-url reader-large-clipped \
         window-inbox-rich peek-mail-rich peek-mail-quoted peek-mail-attachments \
         composer-new-{light,dark} composer-formatted-{light,dark} composer-reply-{light,dark} composer-reply-quote-open \
         composer-reply-header-style composer-forward-{light,dark} composer-attachments-{light,dark} composer-inline-image \
         composer-over-limit-{light,dark} composer-large-warning composer-plain-mode composer-narrow composer-link-popover \
         composer-color-popover composer-approve-attachments settings-mail-writing settings-signature-rich \
         attachment-risky-confirm; do
  expected+=( "rm-$n" )
done
absent=(); for f in "${expected[@]}"; do [[ -f "$RENDERS/$f.png" ]] || absent+=( "$f" ); done
all_rm=( "$RENDERS"/rm-*.png(N:t:r) ); extra=( ${all_rm:|expected} )
web_snap=0; web_fallback=(); web_missing=()
for o in "${RM_OBJECTS[@]}"; do
  f="$(mfield "$o" file)"; f="${f%.png}"
  [[ "$f" == rm-reader-* || "$f" == rm-peek-* || "$f" == rm-window-* ]] || continue
  case "$(mfield "$o" web)" in
    snapshot) (( web_snap += 1 )) ;;
    text-fallback) web_fallback+=( "$f" ) ;;
    *) web_missing+=( "$f" ) ;;
  esac
done
(( ${#web_fallback} )) && warn "text fallback instead of a web snapshot: ${(j:, :)web_fallback}"
if (( ${#absent} == 0 && ${#RM_OBJECTS} >= ${#expected} && ${#web_missing} == 0 && web_snap >= 22 )); then
  pass "renders: rich-mail list" "${#expected} listed rm-* PNGs present (+${#extra}: ${(j:, :)extra:-none}); ${#RM_OBJECTS} manifest entries; $web_snap reader/Peek/window renders are web snapshots, ${#web_fallback} text fallbacks"
else
  fail "renders: rich-mail list" "missing ${(j:, :)absent[1,8]:-none} (${#absent}); manifest rm-* entries ${#RM_OBJECTS}; web snapshots $web_snap; no web field: ${(j:, :)web_missing[1,4]:-none}"
fi

# ── 2. Tests: the rich-mail sections ran and nothing failed ──────────────────────────────────────
shell_line="$(grep -E '^TESTS passed=' "$BUILDLOG" | tail -1 || true)"
data_line="$(grep -E '^DATA TESTS passed=' "$BUILDLOG" | tail -1 || true)"
acct_line="$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "$BUILDLOG" | tail -1 || true)"
rich_data="$(grep -E '^  rich mail +[0-9]+ passed, [0-9]+ failed' "$BUILDLOG" | tail -1 | sed -E 's/^ +//; s/ +/ /g' || true)"
rich_sections=( "${(@f)$(grep -E '^▸ Rich mail: ' "$BUILDLOG" | sed 's/^▸ //' | sort -u || true)}" ); rich_sections=( ${rich_sections:#} )
need_sections=( "Rich mail: seam" "Rich mail: cast (D-028)" "Rich mail: reader document" "Rich mail: context menu"
                "Rich mail: hovered link" "Rich mail: 2 MB clip" "Rich mail: attachment names" "Rich mail: risky types and Quick Look"
                "Rich mail: saved files, quarantine" "Rich mail: composer document operations" "Rich mail: composer paste normalization"
                "Rich mail: composer drafts" "Rich mail: Settings → Writing" "Rich mail: rich signatures" "Rich mail: Forward"
                "Rich mail: composer attaching" "Rich mail: size estimate" "Rich mail: the approval card with attachments (D-023)"
                "Rich mail: Forward key" )
missing_sections=()
for s in "${need_sections[@]}"; do grep -qF "▸ $s" "$BUILDLOG" || missing_sections+=( "$s" ); done
failed_any="$(grep -cE '✗|failed=[1-9]|[^0-9=][1-9][0-9]* failed' "$BUILDLOG" || true)"
if [[ "$shell_line" == *"failed=0"* && "$data_line" == *"failed=0"* && "$acct_line" == *" 0 failed" && "$rich_data" == *" 0 failed"* \
      && ${#missing_sections} == 0 && "$failed_any" == 0 ]]; then
  pass "tests: rich-mail sections" "${#rich_sections} \"▸ Rich mail: …\" shell sections · data \`$rich_data\` · \`${shell_line}\` · \`${data_line}\` · accounts \`$acct_line\`"
else
  fail "tests: rich-mail sections" "shell=\`${shell_line:-none}\` data=\`${data_line:-none}\` accounts=\`${acct_line:-none}\` rich=\`${rich_data:-none}\` missing: ${(j:, :)missing_sections:-none} · failure lines: $failed_any"
fi

# ── 3. Appex isolation ───────────────────────────────────────────────────────────────────────────
banned_symbols=( OutboxStore MIMEFileWriter RichOutgoingMail MIMEAttachment buildRich MailSize LocalAttachmentStore
                 MailAttachmentStore MailDraftAttachment MailQuoteRequest MailHTMLWriter MailHTMLReader MailCIDSchemeHandler
                 MailCID MailQuoteComposer MailQuote MailPlainText ComposeStaging ComposerAttachment AttachmentStrip
                 AttachmentTray AttachmentNames AttachmentFiles AttachmentSaveFolder AttachmentActions RichTextEditor
                 ComposerTextView RichSignature RichMailSettings RichTextSnapshot )
if [[ -x "$APPEX_BIN" ]]; then
  nm -a "$APPEX_BIN" > "$LOGS/appex-nm.txt" 2>/dev/null || true
  nsyms=$(wc -l < "$LOGS/appex-nm.txt" | tr -d ' ')
  hits=(); for s in "${banned_symbols[@]}"; do grep -qF "$s" "$LOGS/appex-nm.txt" && hits+=( "$s" ); done
  # Positive control: the widget's own snapshot reader must be found by the same search.
  control=0; grep -qF "WidgetSnapshot" "$LOGS/appex-nm.txt" && control=1
  [[ $control == 0 ]] && grep -qF "Snapshot" "$LOGS/appex-nm.txt" && control=1
  ents="$(codesign -d --entitlements - --xml "$APPEX" 2>/dev/null || true)"
  ents_ok=0
  [[ "$ents" == *app-sandbox* && "$ents" == *"$WIDGET_DIR"* && "$ents" != *network* ]] && ents_ok=1
  unchanged=0
  if [[ -n "$OWN" ]]; then
    git -C "$ROOT" diff --quiet "$OWN" -- Resources/Widget.entitlements Resources/Widget.dev.entitlements build.sh && unchanged=1
    new_shared=( "${(@f)$(git -C "$ROOT" diff --name-only "$OWN" -- Sources/Shared Sources/Widget || true)}" ); new_shared=( ${new_shared:#} )
  else
    git -C "$ROOT" diff --quiet "$BASE" -- Resources/Widget.entitlements build.sh && unchanged=1
    new_shared=( "${(@f)$(git -C "$ROOT" diff --name-only "$BASE" -- Sources/Shared Sources/Widget || true)}" ); new_shared=( ${new_shared:#} )
  fi
  if (( ${#hits} == 0 && nsyms > 100 && control == 1 && ents_ok == 1 && unchanged == 1 && ${#new_shared} == 0 )); then
    pass "appex isolation" "${APP:t}: nm -a: $nsyms symbols, none of ${#banned_symbols} rich-mail names (control: the widget's snapshot types found); entitlements app-sandbox + widget/ only, no network; Widget.entitlements, build.sh, Sources/Shared, Sources/Widget $([[ -n "$OWN" ]] && print "untouched by rich mail ($OWN)" || print "= $BASE")"
  else
    fail "appex isolation" "symbols found: ${(j:, :)hits:-none} · symbols=$nsyms control=$control · entitlements ok=$ents_ok · build.sh/entitlements unchanged=$unchanged · Shared/Widget changed: ${(j:, :)new_shared:-none}"
  fi
else
  fail "appex isolation" "no widget extension binary in build/ (run the build first)"
fi

# ── 4. Scopes and hosts ──────────────────────────────────────────────────────────────────────────
# block <open> <regex>: from the first line matching <regex> through the balanced closing bracket (stdin → stdout).
block() {
  /usr/bin/perl -e '
    my ($open, $re) = @ARGV; my $close = $open eq "{" ? "}" : "]";
    local $/; my @lines = split /\n/, scalar(<STDIN>), -1; my $i = 0;
    $i++ while $i < @lines && $lines[$i] !~ /$re/;
    exit 3 if $i >= @lines;
    my ($depth, $seen, @out) = (0, 0);
    for (; $i < @lines; $i++) {
      push @out, $lines[$i];
      for my $c (split //, $lines[$i]) { if ($c eq $open) { $depth++; $seen = 1 } elsif ($c eq $close) { $depth-- } }
      last if $seen && $depth <= 0;
    }
    print join("\n", @out), "\n";' "$1" "$2"
}
same_block() {  # same_block <file> <open> <regex>: the block is identical in the base and here
  local a b
  a="$(git -C "$ROOT" show "$BASE:$1" 2>/dev/null | block "$2" "$3")" || return 1
  b="$(block "$2" "$3" < "$ROOT/$1")" || return 1
  [[ -n "$a" && "$a" == "$b" ]]
}
scope_ok=1
same_block Sources/Auth/OAuthProvider.swift '{' 'var scopes: \[String\]' || scope_ok=0
same_block Sources/Auth/OAuthProvider.swift '{' 'var requiredGrantedScopes' || scope_ok=0
hosts_ok=1
same_block Sources/Net/HTTP.swift '[' 'static let allowedHosts' || hosts_ok=0
hosts=( "${(@f)$(block '[' 'static let allowedHosts' < "$ROOT/Sources/Net/HTTP.swift" | grep -oE '"[a-z0-9.-]+"' | tr -d '"' || true)}" )
added_https=( "${(@f)$(git -C "$ROOT" diff -U0 "$BASE" -- Sources/Net Sources/Providers Sources/Auth | grep -E '^\+[^+]' \
                 | grep -oE 'https://[A-Za-z0-9.-]+' | sed 's#https://##' | sort -u || true)}" ); added_https=( ${added_https:#} )
off_hosts=( ${added_https:|hosts} )
if (( scope_ok && hosts_ok && ${#off_hosts} == 0 )); then
  pass "scopes and hosts = $BASE" "OAuthProvider scopes + requiredGrantedScopes identical; HTTP.allowedHosts identical (${#hosts} hosts); added https literals in Net/Providers/Auth: ${(j:, :)added_https:-none}, all allowed"
else
  fail "scopes and hosts = $BASE" "scopes identical=$scope_ok hosts identical=$hosts_ok · off-list hosts: ${(j:, :)off_hosts:-none}"
fi

# ── 5. Ban list ──────────────────────────────────────────────────────────────────────────────────
ban='NSAttributedString\(html:|documentType: *\.html|DocumentType\.html|NSHTMLTextDocumentType|documentType: *\.webArchive|NSWebArchiveTextDocumentType|allowsContentJavaScript *= *true|LSFileQuarantineEnabled'
ban_hits="$(grep -rnE "$ban" "$ROOT/Sources" 2>/dev/null | sed "s#^$ROOT/##" | cut -d: -f1,2 || true)"
if [[ -z "$ban_hits" ]]; then
  pass "ban list" "0 hits in Sources for AppKit HTML/web-archive import or export, content JavaScript on, quarantine opt-out"
else
  fail "ban list" "${ban_hits//$'\n'/, }"
fi

# ── 6. RICHMAIL-BENCH within 2× budget ───────────────────────────────────────────────────────────
grep -E 'RICHMAIL-BENCH ' "$BUILDLOG" | sed -E 's/^.*RICHMAIL-BENCH //' > "$LOGS/bench.txt" || true
/usr/bin/perl -ne '
  chomp; my $l = $_;
  if ($l =~ /no budget/ || $l !~ /budget/) { print "INFO\t$l\n"; next }
  my @p; while ($l =~ /([0-9]+(?:\.[0-9]+)?)\s*(?:ms|s|MB)?\s*\(?budget[ =]([0-9]+(?:\.[0-9]+)?)/g) { push @p, [$1, $2] }
  if (!@p) { print "UNPARSED\t$l\n"; next }
  my $ok = 1; for (@p) { $ok = 0 if $_->[0] > 2 * $_->[1] }
  print(($ok ? "OK" : "OVER2X"), "\t$l\n");' "$LOGS/bench.txt" > "$LOGS/bench-judged.txt"
need_bench=( "sanitize+mark 200KB" "sanitize+mark 2MB" "MailPlainText.html 100KB" "attachment decode 25MB" "composer-keystroke"
             "writer-render" "toolbar-state" "buildRich 25MB to file" "forward-open" )
bench_missing=(); for b in "${need_bench[@]}"; do grep -qF -- "$b" "$LOGS/bench-judged.txt" || bench_missing+=( "$b" ); done
n_ok=$(grep -c '^OK' "$LOGS/bench-judged.txt" || true)
bad=( "${(@f)$(grep -E '^(OVER2X|UNPARSED)' "$LOGS/bench-judged.txt" | cut -f2 | cut -c1-60 || true)}" ); bad=( ${bad:#} )
if (( ${#bench_missing} == 0 && ${#bad} == 0 && n_ok >= ${#need_bench} )); then
  pass "RICHMAIL-BENCH ≤ 2× budget" "$n_ok budgeted lines within 2× (all ${#need_bench} expected present); $(grep -c '^INFO' "$LOGS/bench-judged.txt" || true) info lines"
else
  fail "RICHMAIL-BENCH ≤ 2× budget" "over or unparsed: ${(j:; :)bad:-none} · missing: ${(j:, :)bench_missing:-none}"
fi

# ── 7. Cast only ─────────────────────────────────────────────────────────────────────────────────
cast_files=( "$ROOT"/Sources/Contracts/Rich*.swift "$ROOT"/Sources/App/Rich*.swift "$ROOT"/Tests/Rich*.swift
             "$ROOT"/Tests/Data/Rich*.swift "$ROOT"/Tests/Data/Goldens/**/*(.) )
print -rl -- "${RM_OBJECTS[@]}" > "$LOGS/manifest-rm.txt"
cast_words='Avery Moonfield Juniper Vale Milo Brightwater Priya Starling Theo Quill Ines Marlowe Kofi Ember Mom Orbital Pickle Co. The Quiet Comets Family Personal'
ROOT="$ROOT" CAST_WORDS="$cast_words" /usr/bin/perl -CSD -e '
  my %ok = map { $_ => 1 } split / /, $ENV{CAST_WORDS};
  my %hosts = map { $_ => 1 } qw(gmail.googleapis.com www.googleapis.com mail.google.com www.w3.org purl.org);
  my $bad = 0;
  sub report { my ($kind, $file, $line) = @_; $file =~ s{^\Q$ENV{ROOT}\E/}{}; print "$kind\t$file:$line\n"; $bad++ }
  sub name_ok { my $n = shift; $n =~ s/<[^<>]*>//g; $n =~ s/\S+@\S+//g; $n =~ s/^\s+|\s+$//g; return 1 if $n eq "";
    my @w = grep { length } split /\s+/, $n; @w = @w[-2..-1] if @w > 2;
    for (@w) { (my $x = $_) =~ s/[,;:()"]//g; return 0 unless $ok{$x} } return 1 }
  for my $f (@ARGV) {
    open(my $fh, "<", $f) or next; local $/; my $s = <$fh>; close $fh;
    $s =~ s/=\r?\n//g if $f =~ /\.(eml|txt|html)$/;       # quoted-printable soft breaks in goldens
    my @lines = split /\n/, $s;
    for my $i (0..$#lines) { my $l = $lines[$i]; my $n = $i + 1;
      while ($l =~ /([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})/g) {
        my $d = lc $2; report("ADDRESS", $f, $n) unless $d =~ /(^|\.)example$/ || $d eq "yayascalendar.local" }
      while ($l =~ m{https?://(?:[^/\s"@]*@)?([A-Za-z0-9.-]+)}g) {
        my $h = lc $1; report("URL", $f, $n) unless $h =~ /(^|\.)example$/ || $hosts{$h} }
      while ($l =~ /(?:MailAddress|Person)\(name: *"([^"]*)"/g) { report("NAME", $f, $n) unless name_ok($1) }
      while ($l =~ /\b(?:from|sender): *"([^"]*)"/g) { report("NAME", $f, $n) unless name_ok($1) }
      while ($l =~ /([\p{L}][\p{L} .,\x27-]{0,40}?) <[^<>\s"]+@[^<>\s"]+>/g) { report("NAME", $f, $n) unless name_ok($1) }
    }
  }
  exit($bad ? 1 : 0);' "${cast_files[@]}" "$LOGS/manifest-rm.txt" > "$LOGS/cast.txt" 2>&1 && cast_rc=0 || cast_rc=$?
cast_detail="${#cast_files} files (fixtures, renders code, tests, goldens) + ${#RM_OBJECTS} manifest entries"
# OCR of the rm-* renders (optional: YC_OCR).
OCR="${YC_OCR:-}"
ocr_rc=0; ocr_note="OCR skipped (no tool)"
if [[ -x "$OCR" ]] && (( ${#all_rm} )); then
  pngs=( "$RENDERS"/rm-*.png(N) )
  if yc_timeout 300 "$OCR" "${pngs[@]}" > "$LOGS/ocr.txt" 2>/dev/null && [[ -s "$LOGS/ocr.txt" ]]; then
    /usr/bin/perl -CSD -ne '
      my ($file, $text) = split /\t/, $_, 2; next unless defined $text;
      while ($text =~ /([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)\.([A-Za-z0-9|]{2,})/g) {
        (my $tld = lc $3) =~ tr/1i|/lll/;
        print "OCR-ADDRESS\t$file\n" unless index("example", $tld) == 0;   # the TLD, or its start when cut off
      }' "$LOGS/ocr.txt" > "$LOGS/ocr-hits.txt" || true
    if [[ -s "$LOGS/ocr-hits.txt" ]]; then ocr_rc=1; fi
    # The deny-list pass below gets the words without the addresses: those were judged here, and OCR cuts some short
    # (".exa…"), which the generic address rule would flag.
    /usr/bin/perl -CSD -pe 's/\S*@\S*/[address]/g' "$LOGS/ocr.txt" > "$LOGS/ocr-words.txt"
    ocr_note="OCR $(wc -l < "$LOGS/ocr.txt" | tr -d ' ') text lines from ${#pngs} rm-* PNGs: $(wc -l < "$LOGS/ocr-hits.txt" | tr -d ' ') addresses off *.example"
  else
    ocr_note="OCR tool did not run headless (skipped)"; warn "$ocr_note"
  fi
fi
# The private deny list over the OCR text and the manifest strings (rule ids and file:line only).
CP="${YC_CHECK_PUBLIC:-$ROOT/Tools/check-public.sh}"
cp_rc=0; cp_note="deny list skipped (no check-public.sh)"
if [[ -x "$CP" ]]; then
  cp_inputs=( "$LOGS/manifest-rm.txt" ); [[ -s "$LOGS/ocr-words.txt" ]] && cp_inputs+=( "$LOGS/ocr-words.txt" )
  mode_note="--strict"
  ( cd "$ROOT" && "$CP" --strict --text "${cp_inputs[@]}" ) > "$LOGS/check-public.txt" 2>&1 || cp_rc=$?
  if (( cp_rc == 2 )); then
    mode_note="generic rules only (no private deny list)"; cp_rc=0
    ( cd "$ROOT" && "$CP" --text "${cp_inputs[@]}" ) > "$LOGS/check-public.txt" 2>&1 || cp_rc=$?
  fi
  cp_note="check-public --text $mode_note over ${#cp_inputs} files: $(grep -E '^SUMMARY' "$LOGS/check-public.txt" | tail -1 | sed -E 's/^SUMMARY //')"
fi
if (( cast_rc == 0 && ocr_rc == 0 && cp_rc == 0 )); then
  pass "cast only" "$cast_detail: addresses, URLs and names all cast · $ocr_note · $cp_note"
else
  hits_list="$(cut -f1,2 "$LOGS/cast.txt" "$LOGS/ocr-hits.txt"(N) | head -8 | tr '\t\n' ' ;')"
  cp_hits="$(grep -E '^[A-Z][A-Z0-9]*-[A-Z0-9-]+ ' "$LOGS/check-public.txt"(N) | head -8 | tr '\n' ';' || true)"
  fail "cast only" "$cast_detail · ${hits_list:-} · $ocr_note · $cp_note ${cp_hits:-}"
fi

# ── 8. D-023 untouched ───────────────────────────────────────────────────────────────────────────
# file | label | regex of the declaration line (each block runs to its balanced closing brace)
d023=( "Sources/UI/ComposerView.swift|SendApprovalOverlay|^struct SendApprovalOverlay\\b"
       "Sources/UI/ComposerView.swift|SendApprovalCard|^struct SendApprovalCard\\b"
       "Sources/UI/ComposerView.swift|approvalChanged|func approvalChanged\\("
       "Sources/UI/ComposerView.swift|installKeyMonitor|func installKeyMonitor\\("
       "Sources/UI/ComposerModel.swift|SendApproval|^struct SendApproval\\b"
       "Sources/UI/ComposerModel.swift|ApprovalKey|^enum ApprovalKey\\b"
       "Sources/UI/ComposerModel.swift|approvalHint|static func approvalHint\\("
       "Sources/UI/ComposerModel.swift|makeApproval|func makeApproval\\(" )
changed=()
for spec in "${d023[@]}"; do
  parts=( "${(@s:|:)spec}" )
  same_block "${parts[1]}" '{' "${parts[3]}" || changed+=( "${parts[2]}" )
done
old_tests=( Tests/MailTests.swift Tests/Data/MailActionTests.swift Tests/Data/MIMETests.swift Tests/Data/SanitizerTests.swift Tests/Data/MailFakes.swift )
tests_same=1; git -C "$ROOT" diff --quiet "$BASE" -- "${old_tests[@]}" || tests_same=0
if (( ${#changed} == 0 && tests_same )); then
  pass "D-023 untouched" "SendApprovalOverlay, SendApprovalCard, approvalChanged, installKeyMonitor, SendApproval, ApprovalKey, approvalHint, makeApproval byte-identical to $BASE; ${#old_tests} old mail test files unmodified"
else
  fail "D-023 untouched" "changed: ${(j:, :)changed:-none} · old mail tests unmodified=$tests_same"
fi

# ── 9. buildRich peak memory, in its own process ─────────────────────────────────────────────────
BENCH_SRC="$LOGS/bench-src"; mkdir -p "$BENCH_SRC"
cat > "$BENCH_SRC/main.swift" <<'SWIFT'
import Foundation
// richmail-membench <baseline|build> <scratch folder> <attachment bytes>: writes an incompressible attachment of that
// size, then (build) runs MIMEBuilder.buildRich to a file. /usr/bin/time -l around it gives the peak; the baseline run
// does everything but the build.
let args = CommandLine.arguments
let mode = args[1], dir = URL(fileURLWithPath: args[2], isDirectory: true), size = Int(args[3]) ?? 0
let fm = FileManager.default
try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
let source = dir.appendingPathComponent("attachment.bin"), out = dir.appendingPathComponent("message.eml")
var chunk = Data(count: 1 << 20)
chunk.withUnsafeMutableBytes { raw in
    guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
    var x: UInt32 = 2_463_534_242
    for i in 0..<(1 << 20) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = UInt8(truncatingIfNeeded: x) }
}
_ = fm.createFile(atPath: source.path, contents: nil)
let handle = try FileHandle(forWritingTo: source)
var left = size
while left > 0 { let n = min(left, chunk.count); try handle.write(contentsOf: chunk.prefix(n)); left -= n }
try handle.close()
func maxRSS() -> Int { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Int(u.ru_maxrss) }
let before = maxRSS()
var bytes = 0, seconds = 0.0
if mode == "build" {
    let mail = RichOutgoingMail(headers: OutgoingMail(from: MailAddress(name: "Avery Moonfield", email: "avery@orbitalpickle.example"),
                                                      to: [MailAddress(name: "Priya Starling", email: "priya@starling.example")],
                                                      subject: "Moodboard", body: "", messageID: MIMEBuilder.newMessageID(), date: Date()),
                                text: "The moodboard.", html: "<div>The moodboard.</div>",
                                files: [MIMEAttachment(filename: "Moodboard.zip", mimeType: "application/zip", contentId: nil, source: .file(source))])
    let t0 = Date()
    bytes = try MIMEBuilder.buildRich(mail, to: out)
    seconds = Date().timeIntervalSince(t0)
}
print("RICHMAIL-MEM mode=\(mode) attachment=\(size) message=\(bytes) seconds=\(String(format: "%.3f", seconds)) rss-before=\(before) rss-after=\(maxRSS())")
try? fm.removeItem(at: source)
try? fm.removeItem(at: out)
SWIFT
yc_toolchain
yc_lock_acquire
mem_rc=0
yc_timeout 300 "$SWIFTC" -O -swift-version 5 -target arm64-apple-macos26.0 -sdk "$SDK" -suppress-warnings -module-name RichMailMemBench \
  "$BENCH_SRC/main.swift" "$ROOT"/Sources/Mail/{MIMEBuilder,MIMERichBuilder,MIMEText,MailSize}.swift \
  -o "$LOGS/richmail-membench" > "$LOGS/membench-compile.log" 2>&1 || mem_rc=$?
yc_lock_release
typeset -A peak foot secs msg
if (( mem_rc == 0 )); then
  # 18,250,000 bytes of attachment ≈ a message just under 25,000,000 bytes; 26,214,400 = the 25 MB attachment of the budget.
  for size in 18250000 26214400; do
    for mode in baseline build; do
      rc=0
      { /usr/bin/time -l "$LOGS/richmail-membench" "$mode" "$LOGS/membench-scratch" "$size" > "$LOGS/mem-$mode-$size.out"; } \
        2> "$LOGS/mem-$mode-$size.time" || rc=$?
      (( rc == 0 )) || mem_rc=$rc
      peak[$mode-$size]="$(sed -nE 's/^ *([0-9]+) +maximum resident set size.*/\1/p' "$LOGS/mem-$mode-$size.time" | head -1)"
      foot[$mode-$size]="$(sed -nE 's/^ *([0-9]+) +peak memory footprint.*/\1/p' "$LOGS/mem-$mode-$size.time" | head -1)"
      secs[$mode-$size]="$(sed -nE 's/.* seconds=([0-9.]+).*/\1/p' "$LOGS/mem-$mode-$size.out")"
      msg[$mode-$size]="$(sed -nE 's/.* message=([0-9]+).*/\1/p' "$LOGS/mem-$mode-$size.out")"
    done
  done
  rm -rf "$LOGS/membench-scratch"
fi
mb() { printf '%.1f' $(( $1 / 1048576.0 )) }
if (( mem_rc == 0 )) && [[ -n "${peak[build-18250000]:-}" && -n "${peak[build-26214400]:-}" ]]; then
  mem_ok=1; detail=()
  for size in 18250000 26214400; do
    xr=$(( ${peak[build-$size]} - ${peak[baseline-$size]} )); xf=$(( ${foot[build-$size]:-0} - ${foot[baseline-$size]:-0} ))
    (( xr < 0 )) && xr=0; (( xf < 0 )) && xf=0
    (( xr > 160 * 1048576 || xf > 160 * 1048576 )) && mem_ok=0
    (( ${secs[build-$size]:-99} > 3.0 )) && mem_ok=0
    label="25 MB message"; (( size == 26214400 )) && label="25 MB attachment"
    detail+=( "$label (${msg[build-$size]} bytes): peak RSS $(mb ${peak[build-$size]}) MB vs baseline $(mb ${peak[baseline-$size]}) MB → +$(mb $xr) MB; footprint +$(mb $xf) MB; ${secs[build-$size]} s" )
    print -r -- "RICHMAIL-MEM $label message=${msg[build-$size]} peak-rss=$(mb ${peak[build-$size]})MB baseline=$(mb ${peak[baseline-$size]})MB extra-rss=$(mb $xr)MB extra-footprint=$(mb $xf)MB seconds=${secs[build-$size]}" >> "$LOGS/memory.txt"
  done
  if (( mem_ok )); then pass "buildRich memory (own process)" "${(j: · :)detail} (budget +80 MB and 1.5 s; gate 2×)"
  else fail "buildRich memory (own process)" "${(j: · :)detail}"; fi
else
  fail "buildRich memory (own process)" "the benchmark did not build or run (exit $mem_rc; .work/gate-richmail/membench-compile.log)"
fi

# ── Report ───────────────────────────────────────────────────────────────────────────────────────
total_secs=$(printf '%.0f' $(( EPOCHREALTIME - started )))
status_word="PASS"; (( ${#FAILED} )) && status_word="FAIL (${(j:, :)FAILED})"
commit="$(git -C "$ROOT" rev-parse --short HEAD)"; branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
{
  print -r -- "# Rich mail gate: $status_word"
  print -r -- ""
  print -r -- "Run $(date '+%Y-%m-%d %H:%M %Z') on \`$branch\` @ \`$commit\` by \`Tools/gate-richmail.sh\` (${total_secs}s), base \`$BASE\`."
  print -r -- "Renders: \`${RENDERS#$ROOT/}\` · build log: \`${BUILDLOG#$ROOT/}\` · details: \`.work/gate-richmail/\`."
  print -r -- ""
  print -r -- "| Check | Result | Evidence |"
  print -r -- "|---|---|---|"
  print -rl -- "${RESULTS[@]}"
  if (( ${#WARNINGS} )); then print -r -- ""; print -r -- "Warnings:"; for w in "${WARNINGS[@]}"; do print -r -- "- $w"; done; fi
  print -r -- ""
  print -r -- "RICHMAIL-BENCH (judged against 2× budget):"
  print -r -- ""
  print -r -- '```'
  cat "$LOGS/bench-judged.txt"
  [[ -f "$LOGS/memory.txt" ]] && cat "$LOGS/memory.txt"
  print -r -- '```'
} > "$LOGS/report.md"
cat "$LOGS/report.md"
print -r -- ""
print -r -- "GATE-RICHMAIL $status_word · ${#RESULTS} checks · ${total_secs}s"
(( ${#FAILED} == 0 ))
