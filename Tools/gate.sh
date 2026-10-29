#!/bin/zsh
# Gate: runs the checks of one gate level and writes the evidence to .work/gates/<level>.md (ignored, so a
# checkout never commits gate evidence; set YC_GATE_REPORTS to write the report somewhere else).
#
#   Tools/gate.sh p1 | p2 | p3 | p4 | p5
#   Tools/gate.sh --help
#
# Gate levels p1 to p5: each level runs every check of the levels below it and adds its own, in the order
# the app grew (p1 the build, p2 widgets from fixtures, p3 mail, p4 the menu bar, p5 a stranger-ready
# release build). A change is checked with p4; a release with p5.
#
# Every level builds with `./build.sh --dev`: the dev profile plus developer tools, ad-hoc signed, so a
# gate never needs a keychain password and never touches the real app's data, URL scheme, Keychain items or
# widgets. The designated requirement is checked against the one derived from that signature.
# p1 = one build with tests, self-test and renders (docs/renders/p1, gitignored), the secret scan of
# repo + bundle, signature + designated requirement, and `--permissions-json` timing (first run
# recorded, judged on 3 warm runs: each must finish in < 1 s). Every step runs under a timeout.
# p2 = the same, with renders from the JSON snapshot fixtures (every kind × family × light/dark, every
# state fixture, accented and vibrant variants composited as macOS draws a desktop not in focus, Peeks,
# Studio, Calendar section) and a render-manifest check: Large shows ≥10 meeting rows on the busy
# fixture's page 1, and no accented or vibrant render is a blank or solid panel (D-047). Ends by
# unregistering every build copy from LaunchServices (`--permissions-json` checks the build copy in).
# p3 = p2 plus mail: live inbox + combo widgets (incl. an "Archived · Undo" row and inbox zero), the
# Inbox section in every state, the reader with the remote-images bar, the composer (incl. the approval
# card and the footer hint, D-023), the Mail Peek, Settings → Mail and Studio with mail on; the manifest must show
# ≥10 mail rows on Inbox Large (busy, page 1). Renders stay local (docs/renders is gitignored).
# p4 = p3 plus the menu bar: the popover (agenda, live meeting, CMT chip, 24 h, inbox, inbox zero, clear
# week, no accounts, mail off) at 380 × 560, every status-title shape (icon, next, during, short,
# right-to-left, past 24 h, unread) with the glyph inside 20 × 15 pt, the welcome guide at each step,
# Settings → Menu bar, and the p4 test sections.
# p5 = p4 plus the stranger-ready build: Tools/check-sealed.sh on the tree and both bundles, the
# dev-profile identifier test (Tests/Profile in the test run, Tools/check-profile.sh on the dev app), the
# release build (`--release`; ad-hoc with "release identity" pending until the identity exists)
# with its symbol check (no developer-tool symbols or strings, local symbols near zero), the installer
# contract (docs/CONTRACTS.md, installer flags) on that release binary (`--permissions-json` valid JSON;
# `--purge --dry-run` once the uninstaller declares it, proven dry on the dev app first, both runs
# sandboxed), and a fresh `git clone` that builds with `--dev` and no Config. It never runs a real --purge
# or --uninstall.
# Headless only: never opens, installs or registers anything.
set -euo pipefail
YC_ROOT="${0:A:h:h}"; ROOT="$YC_ROOT"
source "$ROOT/Tools/lib/common.zsh"
zmodload zsh/datetime

PHASE="${1:-}"
if [[ "$PHASE" == (-h|--help) ]]; then awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0; fi
[[ "$PHASE" == p[1-5] ]] || yc_fail "usage: Tools/gate.sh p1|p2|p3|p4|p5 (gate levels; see --help)"
at_least() { (( ${PHASE#p} >= $1 )) }

yc_profile dev
APP="$ROOT/build/${YC_PROFILE[displayName]}.app"; BIN="$APP/Contents/MacOS/YayasCalendar"
WIDGET_FOLDER="/${YC_PROFILE[dataRoot]}/widget/"
RENDERS="$ROOT/docs/renders/$PHASE"
LOGS="$ROOT/.work/gate-$PHASE"; REPORT="${YC_GATE_REPORTS:-$ROOT/.work/gates}/$PHASE.md"
mkdir -p "$LOGS" "${REPORT:h}"
typeset -a RESULTS FAILED PENDING
pass() { RESULTS+=( "| $1 | ✅ pass | $2 |" ) }
fail() { RESULTS+=( "| $1 | ❌ FAIL | $2 |" ); FAILED+=( "$1" ) }
pending() { RESULTS+=( "| $1 | ⏳ pending | $2 |" ); PENDING+=( "$1" ) }
started=$EPOCHREALTIME

# ── 1. Build + tests + self-test + renders (one build) ───────────────────────────────────────────
print -r -- "▸ gate $PHASE: build --dev --test --selftest --render docs/renders/$PHASE"
t0=$EPOCHREALTIME; rc=0
yc_timeout 1800 "$ROOT/build.sh" --dev --test --selftest --render "docs/renders/$PHASE" > "$LOGS/build.log" 2>&1 || rc=$?
build_secs=$(printf '%.0f' $(( EPOCHREALTIME - t0 )))
summary="$(tail -1 "$LOGS/build.log")"
tests="$(grep -E '^TESTS ' "$LOGS/build.log" | tail -1 | sed 's/^TESTS //')"
selftest="$(grep -E '^\{"app":"yayascalendar","selftest"' "$LOGS/build.log" | tail -1 || true)"
rendered="$(grep -E '^RENDERED ' "$LOGS/build.log" | tail -1 || true)"
notes=( "${(@f)$(grep -E '^  · ' "$LOGS/build.log" | sed 's/^  · //' || true)}" )
if (( rc == 0 )); then pass "build + sign" "${build_secs}s · \`$summary\`"; else fail "build" "exit $rc after ${build_secs}s, see .work/gate-$PHASE/build.log"; fi
[[ "$tests" == *"failed=0"* ]] && pass "tests" "$tests" || fail "tests" "${tests:-no result}"
[[ "$selftest" == *'"selftest":"pass"'* ]] && pass "--selftest" "\`$selftest\`" || fail "--selftest" "\`${selftest:-no output}\`"
[[ "$rendered" == *"(0 failed)"* ]] && pass "--render" "${rendered%% →*} (0 failed)" || fail "--render" "${rendered:-no output}"

# A test section ran in this build: its "▸ <name>" line is in the log.
ran_section() { grep -q "^▸ $1" "$LOGS/build.log" }
# The contract tests ran: the installer flags (every level times --permissions-json below), every link
# route, and from p3 the Studio's mail switch.
contract_sections=( "installer flags: --permissions-json line" "installer flags: notification states"
                    "router: ping / open/app / every route handled / unknown" )
at_least 3 && contract_sections+=( "Studio: Inbox types gated by the mail switch" )
missing_sections=(); for sct in "${contract_sections[@]}"; do ran_section "$sct" || missing_sections+=( "$sct" ); done
(( ${#missing_sections} == 0 )) && pass "contract tests ran" "${#contract_sections} sections (installer flags, every link route$(at_least 3 && print ', the Studio mail switch')) in the passing run" \
  || fail "contract tests ran" "missing: ${(j:, :)missing_sections}"

# ── 1b. P2: the render manifest (JSON fixtures → widget read path) ───────────────────────────────
typeset -a MANIFEST_OBJECTS
if at_least 2; then
  manifest="$RENDERS/render-manifest.json"
  if [[ -f "$manifest" ]]; then
    MANIFEST_OBJECTS=( "${(@f)$(tr -d '\n' < "$manifest" | grep -oE '\{[^{}]*"file"[^{}]*\}' || true)}" )
  fi
  mfield() { print -r -- "$1" | sed -nE "s/.*\"$2\" *: *\"?([^\",}]*)\"?.*/\1/p" | head -1 | sed 's/ *$//' }
  large_rows=""
  for o in "${MANIFEST_OBJECTS[@]}"; do
    if [[ "$(mfield "$o" fixture)" == busy && "$(mfield "$o" kind)" == agenda.all && "$(mfield "$o" family)" == L \
          && "$(mfield "$o" look)" == light && "$(mfield "$o" mode)" == fullColor ]]; then
      large_rows="$(mfield "$o" meetingRows)"
    fi
  done
  if [[ -n "$large_rows" ]] && (( large_rows >= 10 )); then
    pass "manifest: Large ≥10 rows (busy, page 1)" "agenda.all L light busy → meetingRows=$large_rows"
  else
    fail "manifest: Large ≥10 rows (busy, page 1)" "meetingRows=${large_rows:-missing}"
  fi
  busy_n=${#${(M)MANIFEST_OBJECTS:#*\"widget-*}}; acc_n=${#${(M)MANIFEST_OBJECTS:#*\"accented-*}}
  vib_n=${#${(M)MANIFEST_OBJECTS:#*\"vibrant-*}}; glass_n=${#${(M)MANIFEST_OBJECTS:#*\"glass-*}}
  state_n=${#${(M)MANIFEST_OBJECTS:#*\"state-*}}
  fixtures_seen=( ${(u)${(f)"$(for o in ${(M)MANIFEST_OBJECTS:#*\"state-*}; do mfield "$o" fixture; done)"}} )
  need=( busyPage2 sparse dst empty noAccounts stale reauth mailComingSoon setup customTitle noSnapshot )
  at_least 3 && need+=( mailArchived inboxZero )
  at_least 4 && need+=( justSynced longMonth busyDay dayPicked customDay )
  missing=( ${need:|fixtures_seen} )
  if (( busy_n == 108 && acc_n == 108 && vib_n == 108 && glass_n >= 60 && ${#missing} == 0 )); then
    pass "manifest: coverage" "108 busy (12 kinds × families × light/dark) + 108 accented + 108 vibrant + $glass_n glass-state + $state_n state renders over ${#fixtures_seen} fixtures"
  else
    fail "manifest: coverage" "busy=$busy_n accented=$acc_n vibrant=$vib_n glass=$glass_n states=$state_n missing=${(j:,:)missing}"
  fi
  # D-047: on a desktop not in focus macOS keeps only opacity (accented) or brightness (vibrant). `ink` is
  # the share of the card it draws strongly: 1.0.0 came out as one white sheet (accented ≈ 1) or empty
  # glass (vibrant on Light ≈ 0). Every monochrome render must sit in between.
  glass_bad=(); glass_lo=1; glass_hi=0
  for o in ${(M)MANIFEST_OBJECTS:#*\"(accented|vibrant|glass)-*}; do
    ink="$(mfield "$o" ink)"
    if [[ -z "$ink" ]] || (( ink < 0.004 || ink > 0.40 )); then glass_bad+=( "$(mfield "$o" file)=${ink:-none}" ); continue; fi
    (( ink < glass_lo )) && glass_lo=$ink; (( ink > glass_hi )) && glass_hi=$ink
  done
  if (( acc_n + vib_n > 0 && ${#glass_bad} == 0 )); then
    pass "renders: readable on glass" "$(( acc_n + vib_n + glass_n )) accented / vibrant renders draw content: ink $(printf %.3f $glass_lo)–$(printf %.3f $glass_hi) of the card (blank < 0.004, solid > 0.40)"
  else
    fail "renders: readable on glass" "${#glass_bad} blank or solid: ${(j:, :)glass_bad[1,6]}"
  fi
  surfaces=( peek-event-merged peek-event-reply peek-day studio-custom-a studio-custom-setup window-calendar window-calendar-empty window-calendar-noaccounts window-widgets )
  absent=(); for f in "${surfaces[@]}"; do [[ -f "$RENDERS/$f.png" ]] || absent+=( "$f" ); done
  (( ${#absent} == 0 )) && pass "renders: Peek, Studio, Calendar" "${#surfaces} surface renders present" || fail "renders: Peek, Studio, Calendar" "missing ${(j:, :)absent}"
fi

# ── 1b'. Day widget (D-022): every family × light/dark (+ accented) and its states ──────────────
if at_least 4; then
  day_missing=()
  for fam in S M L XL XLP; do
    for look in light dark; do
      for f in "widget-day-$fam-$look" "accented-day-$fam-$look" "state-busyDay-day-$fam-$look" "state-dayPicked-day-$fam-$look" \
               "state-customDay-custom.f-$fam-$look" "state-justSynced-day-$fam-$look" "state-stale-day-$fam-$look" \
               "state-reauth-day-$fam-$look" "state-empty-day-$fam-$look" "state-dst-day-$fam-$look"; do
        [[ -f "$RENDERS/$f.png" ]] || day_missing+=( "$f" )
      done
    done
  done
  for f in state-noAccounts-day-S-light state-noAccounts-day-L-dark state-noSnapshot-day-M-light studio-day studio-custom-day; do
    [[ -f "$RENDERS/$f.png" ]] || day_missing+=( "$f" )
  done
  day_l=""
  for o in "${MANIFEST_OBJECTS[@]}"; do
    if [[ "$(mfield "$o" fixture)" == busyDay && "$(mfield "$o" kind)" == day && "$(mfield "$o" family)" == L \
          && "$(mfield "$o" look)" == light ]]; then
      day_l="$(mfield "$o" meetingRows)"
    fi
  done
  if (( ${#day_missing} == 0 )) && [[ -n "$day_l" ]] && (( day_l >= 17 )); then
    pass "renders: Day widget" "105 Day renders (busy, accented, busyDay, another day, Custom F, ✓, stale, re-auth, empty, DST × S M L XL XLP × light/dark; no accounts, no snapshot, Studio); Large draws $day_l of 20 blocks (the rest on +N)"
  else
    fail "renders: Day widget" "missing ${(j:, :)day_missing[1,6]} (${#day_missing}) · busyDay L blocks=${day_l:-missing}"
  fi
fi

# ── 1c. P3: mail in the manifest and every mail surface ──────────────────────────────────────────
if at_least 3; then
  inbox_rows=""
  for o in "${MANIFEST_OBJECTS[@]}"; do
    if [[ "$(mfield "$o" fixture)" == busy && "$(mfield "$o" kind)" == inbox.all && "$(mfield "$o" family)" == L \
          && "$(mfield "$o" look)" == light && "$(mfield "$o" mode)" == fullColor ]]; then
      inbox_rows="$(mfield "$o" mailRows)"
    fi
  done
  if [[ -n "$inbox_rows" ]] && (( inbox_rows >= 10 )); then
    pass "manifest: Inbox Large ≥10 mail rows (busy, page 1)" "inbox.all L light busy → mailRows=$inbox_rows"
  else
    fail "manifest: Inbox Large ≥10 mail rows (busy, page 1)" "mailRows=${inbox_rows:-missing}"
  fi
  live=0
  for o in "${MANIFEST_OBJECTS[@]}"; do
    k="$(mfield "$o" kind)"; st="$(mfield "$o" state)"
    [[ "$(mfield "$o" fixture)" == busy && ( "$k" == inbox.all || "$k" == combo.all ) && "$st" == content ]] && (( live += 1 ))
  done
  (( live >= 18 )) && pass "manifest: live mail widgets" "$live busy inbox + combo renders draw live rows (light/dark, full colour + accented + vibrant)" \
    || fail "manifest: live mail widgets" "only $live inbox/combo renders in the content state"
  mail_surfaces=( window-inbox window-inbox-images-loaded window-inbox-plain window-inbox-cmt window-inbox-starred window-inbox-toast
                  window-inbox-zero window-inbox-loading window-inbox-noaccounts window-inbox-failed window-inbox-labs-off
                  reader-remote-images reader-attachments composer-new composer-reply composer-hint composer-refused
                  composer-approve-single-dark composer-approve-single-light composer-approve-multi-dark composer-approve-multi-light composer-approve-multi-compact
                  composer-approve-single-long
                  composer-sending composer-safe-off peek-mail peek-mail-plain peek-mail-attachments peek-mail-archived
                  settings-mail settings-mail-ask-off window-settings studio-inbox studio-custom-inbox studio-combo-dark
                  state-mailArchived-inbox.all-L-light state-mailArchived-inbox.all-L-dark state-mailArchived-combo.all-XL-light
                  state-inboxZero-inbox.all-L-light widget-inbox.all-L-light widget-inbox.all-L-dark widget-combo.all-XL-light widget-combo.all-XL-dark )
  absent=(); for f in "${mail_surfaces[@]}"; do [[ -f "$RENDERS/$f.png" ]] || absent+=( "$f" ); done
  (( ${#absent} == 0 )) && pass "renders: mail surfaces" "${#mail_surfaces} mail renders present (Inbox states, reader, composer, Mail Peek, Settings, Studio, widgets)" \
    || fail "renders: mail surfaces" "missing ${(j:, :)absent}"
  peeks_fit=1
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" window)" == mailPeek && "$(mfield "$o" fits)" != true && "$(mfield "$o" fits)" != 1 ]] && peeks_fit=0
  done
  (( peeks_fit )) && pass "Mail Peek fits the panel" "every Mail Peek ≤ ${PEEK_MAX:-560} pt tall (no scroll, never jumps)" || fail "Mail Peek fits the panel" "a Mail Peek is taller than the panel"
  # The render sends mail and archives through fakes, which trace: those lines must land in the render's
  # own folder (an earlier bug: --render wrote the real logs/app.log).
  if [[ -f "$RENDERS/trace/app.log" ]] && grep -q " app mail-send " "$RENDERS/trace/app.log"; then
    pass "--render traces locally" "$(wc -l < "$RENDERS/trace/app.log" | tr -d ' ') render trace lines in docs/renders/$PHASE/trace/app.log, not logs/app.log"
  else
    fail "--render traces locally" "no render trace in docs/renders/$PHASE/trace/app.log"
  fi
fi

# ── 1d. P4: the menu bar (popover, status title, ⌃⌥J tests), the welcome guide ──────────────────
if at_least 4; then
  p4_surfaces=( popover-agenda popover-agenda-live popover-agenda-cmt popover-agenda-24h popover-inbox popover-inbox-zero
                popover-empty popover-noaccounts popover-labs-off
                status-icon status-next status-during status-short status-left status-rtl status-multiday status-unread status-titles
                sheet-onboarding onboarding-1-google onboarding-2-accounts onboarding-3-looks onboarding-4-widget
                onboarding-5-notifications onboarding-done settings-menubar settings-menubar-taken )
  absent=(); for f in "${p4_surfaces[@]}"; do [[ -f "$RENDERS/$f.png" ]] || absent+=( "$f" ); done
  (( ${#absent} == 0 )) && pass "renders: P4 surfaces" "${#p4_surfaces} renders present (popover ×9, status title ×9, welcome guide ×7, Settings → Menu bar ×2)" \
    || fail "renders: P4 surfaces" "missing ${(j:, :)absent}"
  # The popover is drawn at its real size (380 × 560 pt, 24 pt margin, @2x) in every state.
  bad_size=0; n_pop=0
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" window)" == popover ]] || continue
    (( n_pop += 1 ))
    [[ "$(mfield "$o" width)" == 380 && "$(mfield "$o" height)" == 560 && "$(mfield "$o" px)" == 856x1216 ]] || bad_size=1
  done
  (( n_pop >= 9 && bad_size == 0 )) && pass "popover 380 × 560" "$n_pop popover renders at 380 × 560 pt (856 × 1216 px with the margin)" \
    || fail "popover 380 × 560" "renders=$n_pop wrong-size=$bad_size"
  card=""; for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" window)" == popover && "$(mfield "$o" state)" == agenda-next-in-12-min ]] && card="$(mfield "$o" card)"
  done
  [[ "$card" == "The Comets weekly sync" ]] && pass "popover card" "9:48 on the busy fixture → \`$card\` (12 min, Join Zoom)" \
    || fail "popover card" "card=\`${card:-none}\`"
  # The status glyph stays inside 20 × 15 pt (macOS 27 closes the menu for bigger images).
  glyph=""; typeset -A status_titles
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" window)" == statusItem ]] || continue
    glyph="$(mfield "$o" glyph)"
    status_titles[$(mfield "$o" variant)]="$(mfield "$o" title)"
  done
  gw="${glyph%x*}"; gh="${glyph#*x}"
  if [[ "$glyph" == <->x<-> ]] && (( gw <= 20 && gh <= 15 )); then pass "status glyph ≤ 20 × 15 pt" "glyph $glyph pt"
  else fail "status glyph ≤ 20 × 15 pt" "glyph=${glyph:-missing}"; fi
  st_ok=1
  [[ "${status_titles[icon]:-}" == "" ]] || st_ok=0
  [[ "${status_titles[next]:-}" == "The Comets weekly… · 12m" ]] || st_ok=0
  [[ "${status_titles[during]:-}" == "The Comets weekly… · 35m left" ]] || st_ok=0
  [[ "${status_titles[short]:-}" == "Standup · 7m" ]] || st_ok=0
  [[ "${status_titles[left]:-}" == "Standup · 12m left" ]] || st_ok=0
  [[ "${status_titles[rtl]:-}" == $'\xe2\x81\xa8'*$'\xe2\x81\xa9'" · 7m" ]] || st_ok=0
  [[ "${status_titles[multiday]:-}" == "Offsite · 1d 8h left" ]] || st_ok=0
  [[ "${status_titles[unread]:-}" == <-> ]] || st_ok=0
  (( st_ok )) && pass "status titles" "\`${status_titles[next]}\` · \`${status_titles[during]}\` · \`${status_titles[short]}\` · \`${status_titles[left]}\` · right-to-left isolated · \`${status_titles[multiday]}\` · unread \`${status_titles[unread]}\`" \
    || fail "status titles" "next=${status_titles[next]:-?} during=${status_titles[during]:-?} short=${status_titles[short]:-?} multiday=${status_titles[multiday]:-?}"
  p4_sections=( "Status title: durations" "Status title: before, during, after" "Status title: truncation" "Status title: right-to-left"
                "⌃⌥J: join or open the popover" "Popover: agenda" "Popover: Inbox tab" "Popover placement" "Welcome guide" "VoiceOver words" )
  missing_sections=(); for sct in "${p4_sections[@]}"; do ran_section "$sct" || missing_sections+=( "$sct" ); done
  (( ${#missing_sections} == 0 )) && pass "P4 tests ran" "${#p4_sections} P4 sections (status title, ⌃⌥J, popover, placement, welcome guide, VoiceOver) in the passing run" \
    || fail "P4 tests ran" "missing: ${(j:, :)missing_sections}"
fi

# ── 2. Secrets (repo + bundle) ───────────────────────────────────────────────────────────────────
rc=0; out="$(yc_timeout 120 "$ROOT/Tools/check-secrets.sh" 2>&1)" || rc=$?
(( rc == 0 )) && pass "check-secrets (repo)" "${out#✓ check-secrets: }" || fail "check-secrets (repo)" "${out//$'\n'/ }"
if [[ -d "$APP" ]]; then
  rc=0; out="$(yc_timeout 120 "$ROOT/Tools/check-secrets.sh" "$APP" 2>&1)" || rc=$?
  (( rc == 0 )) && pass "check-secrets (bundle)" "${out#✓ check-secrets: }" || fail "check-secrets (bundle)" "${out//$'\n'/ }"
fi

# ── 3. Signature + designated requirement ────────────────────────────────────────────────────────
if [[ -d "$APP" ]]; then
  if codesign --verify --deep --strict "$APP" 2>/dev/null; then pass "codesign --verify --deep --strict" "app + appex"
  else fail "codesign --verify --deep --strict" "failed"; fi
  # The expected requirement is derived from the identity that signed this build (build.sh writes it).
  dr="$(codesign -d -r- "$APP" 2>&1 | sed -nE 's/^(# )?designated => //p')"
  expected_dr="$(<"$ROOT/.work/expected-dr.txt" 2>/dev/null || true)"
  if [[ -n "$dr" && "$dr" == "$expected_dr" ]] && codesign --verify -R="$expected_dr" "$APP" 2>/dev/null; then
    pass "designated requirement" "\`$dr\` = derived from the signing identity (dev build: ad-hoc cdhash)"
  else
    fail "designated requirement" "\`$dr\` ≠ derived \`${expected_dr:-missing}\`"
  fi
  auth="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  flags="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')"
  ents="$(codesign -d --entitlements - --xml "$APP/Contents/PlugIns/YayasCalendarWidget.appex" 2>/dev/null)"
  [[ "$ents" == *app-sandbox* && "$ents" == *"$WIDGET_FOLDER"* && "$ents" != *network* ]] \
    && pass "widget entitlements" "app-sandbox + \`~$WIDGET_FOLDER\` exception (the profile's), no network" || fail "widget entitlements" "unexpected"
fi

# ── 4. --permissions-json timing ─────────────────────────────────────────────────────────────────
typeset -a times
json_ok=1; line=""
for run in first warm1 warm2 warm3; do
  rc=0
  { /usr/bin/time -p /usr/bin/perl -e 'alarm shift @ARGV; exec { $ARGV[0] } @ARGV' 10 "$BIN" --permissions-json \
      > "$LOGS/perm-$run.out" ; } 2> "$LOGS/perm-$run.time" || rc=$?
  t="$(sed -n 's/^real *//p' "$LOGS/perm-$run.time" | tail -1)"
  times+=( "${run}=${t:-?}s" )
  line="$(head -1 "$LOGS/perm-$run.out")"
  [[ $rc -eq 0 && "$(wc -l < "$LOGS/perm-$run.out" | tr -d ' ')" == 1 \
     && "$line" =~ '^\{"app":"yayascalendar","loginItem":(true|false),"notifications":"(granted|denied|undetermined)"\}$' ]] || json_ok=0
  if [[ "$run" == warm* ]]; then
    [[ -n "$t" ]] && (( t < 1.0 )) || slow=1
  fi
done
(( json_ok )) && pass "--permissions-json output" "\`$line\` (one line, exit 0, every run)" || fail "--permissions-json output" "see .work/gate-$PHASE/perm-*.out"
(( ${slow:-0} )) && fail "--permissions-json < 1 s (warm)" "${(j:, :)times}" || pass "--permissions-json < 1 s (warm)" "${(j:, :)times} (/usr/bin/time -p real)"

# ── 4b. Unregister every build copy (the timing runs above checked this one in) ──────────────────
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
unregister_build_copies() {
  local common main c; local -i n=0; local -a copies; local -A seen
  common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"; main="${common:h}"
  [[ -n "$common" && -d "$main" ]] || main="$ROOT"
  copies=( "$APP" "$ROOT"/build/*.app(N) "$ROOT"/.work/wt-*/build/*.app(N) "$ROOT"/.work/fresh-clone/build/*.app(N)
           "$main"/build/*.app(N) "$main"/.work/wt-*/build/*.app(N) )
  for c in "${copies[@]}"; do
    [[ -d "$c" && -z "${seen[$c]:-}" ]] || continue; seen[$c]=1
    yc_timeout 30 "$LSREG" -u "$c" >/dev/null 2>&1 || true; (( n += 1 ))
  done
  print -r -- $n
}
if at_least 2 && ! at_least 5; then
  unreg="$(unregister_build_copies)"
  pass "lsregister -u build copies" "$unreg build copies unregistered (this worktree, main checkout, .work/wt-*)"
fi

# ── 4c. P5: stranger-ready build ─────────────────────────────────────────────────────────────────
if at_least 5; then
  source "$ROOT/Tools/lib/gate-p5.zsh"
  unreg="$(unregister_build_copies)"
  pass "lsregister -u build copies" "$unreg build copies unregistered (dev, release, fresh clone, main checkout, .work/wt-*)"
fi

total_secs=$(printf '%.0f' $(( EPOCHREALTIME - started )))

# ── 5. Report ────────────────────────────────────────────────────────────────────────────────────
pngs=( "$RENDERS"/*.png(N:t) )
widget_pngs=( ${(M)pngs:#widget-*} ); sparse_pngs=( ${(M)pngs:#sparse-*} ); window_pngs=( ${pngs:#(widget|sparse)-*} )
manifest_rows=""
if [[ -f "$RENDERS/render-manifest.json" ]]; then
  manifest_rows="$(tr -d '\n' < "$RENDERS/render-manifest.json" | grep -oE '\{[^{}]*"meetingRows"[^{}]*\}' \
    | sed -E 's/.*"family" *: *"([A-Z]+)".*"fixture" *: *"([a-z]+)".*"kind" *: *"([a-z.]+)".*"look" *: *"([a-z]+)".*"meetingRows" *: *([0-9]+).*/| \3 | \1 | \2 | \4 | \5 |/' \
    | grep -E '\| (light) \|' | sort -u || true)"
fi
status_word="PASS"; (( ${#PENDING} )) && status_word="PASS with pending (${(j:, :)PENDING})"
(( ${#FAILED} )) && status_word="FAIL (${(j:, :)FAILED})"
commit="$(git -C "$ROOT" rev-parse --short HEAD)"; branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
swift="$(yc_toolchain >/dev/null 2>&1; "$SWIFTC" --version 2>&1 | head -1 | sed 's/^.*\(Apple Swift version [0-9.]*\).*/\1/')"

if [[ "$PHASE" == "p1" ]]; then
{
  print -r -- "# Gate ${PHASE:u}: $status_word"
  print -r -- ""
  print -r -- "Run $(date '+%Y-%m-%d %H:%M %Z') on \`$branch\` @ \`$commit\` by \`Tools/gate.sh $PHASE\` (${total_secs}s total)."
  print -r -- "Toolchain: $swift, SDK $(xcrun --sdk macosx --show-sdk-version 2>/dev/null), target arm64-apple-macos26.0."
  print -r -- "Signed by: ${auth:-?} · code flags: ${flags:-?}. Logs: \`.work/gate-$PHASE/\` (local)."
  print -r -- ""
  print -r -- "| Check | Result | Evidence |"
  print -r -- "|---|---|---|"
  print -rl -- "${RESULTS[@]}"
  print -r -- ""
  print -r -- "## Paginator numbers (from the test run)"
  print -r -- ""
  for n in "${notes[@]}"; do [[ -n "$n" ]] && print -r -- "- $n"; done
  print -r -- ""
  print -r -- "## Renders (docs/renders/$PHASE, gitignored; regenerate with \`./build.sh --render docs/renders/$PHASE\`)"
  print -r -- ""
  print -r -- "Pinned to Monday 19 October 2026, 9:48 AM, Europe/London (the sample week's \"now\"). Renders draw only the sample"
  print -r -- "cast and its badges, drawn in code; no logo file is read. \`render-manifest.json\` has row counts per image."
  print -r -- ""
  print -r -- "Meeting rows on page 1 (light look; dark is identical):"
  print -r -- ""
  print -r -- "| Kind | Family | Fixture | Look | Meeting rows |"
  print -r -- "|---|---|---|---|---|"
  [[ -n "$manifest_rows" ]] && print -r -- "$manifest_rows"
  print -r -- ""
  print -r -- "**${#widget_pngs} widget PNGs** (12 kinds × their families × light/dark), \`widget-<kind>-<family>-<look>.png\`:"
  print -r -- ""
  print -r -- '```'
  print -rl -- "${widget_pngs[@]}" | column -c 120
  print -r -- '```'
  print -r -- ""
  print -r -- "**${#sparse_pngs} sparse-week PNGs** (D-013 slim day banners):"
  print -r -- ""
  print -r -- '```'
  print -rl -- "${sparse_pngs[@]}" | column -c 120
  print -r -- '```'
  print -r -- ""
  print -r -- "**${#window_pngs} window PNGs** (one per sidebar section, the gallery in dark, the full gallery, the onboarding sheet):"
  print -r -- ""
  print -r -- '```'
  print -rl -- "${window_pngs[@]}" | column -c 120
  print -r -- '```'
  print -r -- ""
  print -r -- "## Live checks left for a person (they need an install)"
  print -r -- ""
  print -r -- "- \`./build.sh --install\`, then the widget gallery lists 12 Yaya's Calendar kinds (XL Portrait on macOS 27)."
  print -r -- "- \`open -g 'yayacal://ping?probe=gate'\` → \`app recv ping probe=gate\` in \`~/Library/Application Support/YayasCalendar/logs/app.log\` in < 0.5 s."
  print -r -- "- A widget tap (row/Join → ping, pager → page) hides the agent again (\`hide-check hid=1\`), \`lsappinfo front\` unchanged."
  print -r -- "- Status item: icon draws, menu stays open (≤20×15 pt), Open / Settings… / Quit work; main window draws (\`.regular\` while open)."
  print -r -- "- \`--onboarding\` shows the sheet; \"Let's go\" writes the handoff marker (\`yayascalendar.done\` in the profile's handoff folder)."
  print -r -- "- Launch at login toggle registers from /Applications; \`--permissions-json\` then reports \`loginItem\":true\`."
  print -r -- "- No new files in ~/Library/Logs/DiagnosticReports."
  print -r -- "- The gate ran the build copy's binary (\`--permissions-json\` goes through NSApplication): \`lsregister -u\` the build copy before live tests."
} > "$REPORT"
elif [[ "$PHASE" == "p2" ]]; then
{
  print -r -- "# Gate ${PHASE:u}: $status_word"
  print -r -- ""
  print -r -- "Run $(date '+%Y-%m-%d %H:%M %Z') on \`$branch\` @ \`$commit\` by \`Tools/gate.sh $PHASE\` (${total_secs}s total)."
  print -r -- "Toolchain: $swift, SDK $(xcrun --sdk macosx --show-sdk-version 2>/dev/null), target arm64-apple-macos26.0."
  print -r -- "Signed by: ${auth:-?} · code flags: ${flags:-?}. Logs: \`.work/gate-$PHASE/\` (local)."
  print -r -- ""
  print -r -- "| Check | Result | Evidence |"
  print -r -- "|---|---|---|"
  print -rl -- "${RESULTS[@]}"
  print -r -- ""
  print -r -- "## Numbers from the test run"
  print -r -- ""
  for n in "${notes[@]}"; do [[ -n "$n" ]] && print -r -- "- $n"; done
  print -r -- ""
  print -r -- "## Renders (docs/renders/$PHASE, gitignored; regenerate with \`./build.sh --render docs/renders/$PHASE\`)"
  print -r -- ""
  print -r -- "Every widget image is drawn from a JSON snapshot fixture through the widget's own read path"
  print -r -- "(\`WidgetSnapshot\` encode → decode → \`SnapshotModel\`), pinned to Monday 19 October 2026, 9:48 AM, London"
  print -r -- "(the DST fixture: Sunday 25 October). The fixtures themselves are committed in \`Tests/Fixtures/\` and"
  print -r -- "copied to \`docs/renders/$PHASE/fixtures/\`. Logos: $(sed -nE 's/.*"logos" *: *"([^"]*)".*/\1/p' "$RENDERS/render-manifest.json" 2>/dev/null | head -1)."
  print -r -- ""
  print -r -- "Meeting rows on the page shown (light look, full colour):"
  print -r -- ""
  print -r -- "| Fixture | Kind | Family | Page | Meeting rows | Pages |"
  print -r -- "|---|---|---|---|---|---|"
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" look)" == light && "$(mfield "$o" mode)" == fullColor ]] || continue
    rows="$(mfield "$o" meetingRows)"; [[ -n "$rows" ]] || continue
    kind="$(mfield "$o" kind)"; [[ "$kind" == agenda.all || "$kind" == month || "$kind" == custom.a ]] || continue
    print -r -- "| $(mfield "$o" fixture) | $kind | $(mfield "$o" family) | $(mfield "$o" page) | $rows | $(mfield "$o" pages) |"
  done | sort -u
  print -r -- ""
  for group in "widget:Busy week, every kind × family × light/dark (Inbox and Agenda & Inbox included)" \
               "state:State fixtures (busyPage2, sparse, dst, empty, noAccounts, stale, reauth, mailComingSoon, setup, customTitle, noSnapshot)" \
               "accented:Accented (a desktop not in focus, macOS 26 and later): white by opacity over glass (D-047)" \
               "vibrant:Vibrant: brightness over glass (D-047)" \
               "glass:Whole-card and strip states, accented and vibrant" \
               "peek:Event Peek and Day Peek" \
               "studio:Widget Studio" \
               "window:Main window per section (Calendar: ready, empty, no accounts, loading, CMT filter)" \
               "gallery:Full Widgets page" "sheet:Onboarding"; do
    prefix="${group%%:*}"; title="${group#*:}"
    files=( ${(M)pngs:#${prefix}-*} )
    (( ${#files} )) || continue
    print -r -- "**${#files} PNGs: $title**"
    print -r -- ""
    print -r -- '```'
    print -rl -- "${files[@]}" | column -c 130
    print -r -- '```'
    print -r -- ""
  done
  print -r -- "## Live checks after an install"
  print -r -- ""
  print -r -- "Before: \`./build.sh --install\`, then confirm \`lsregister -dump | grep -c 'yayacal'\` lists only"
  print -r -- "/Applications (every build ends with \`lsregister -u\` on build copies; a stale copy once delayed links 7 s)."
  print -r -- ""
  print -r -- "1. **Widgets read snapshots.** Place Agenda (L), Month (M or L) and Up Next (S): each shows real meetings within a"
  print -r -- "   minute of a sync; \`widget/trace.log\` has \`render … state=ok entries=N\` with N ≤ 48. A Custom slot not set up"
  print -r -- "   says \"Not set up yet\"."
  print -r -- "2. **Time moves without the app.** The next meeting turns highlighted with a Join chip 30 min before, \"Now\" at"
  print -r -- "   its start, and leaves the list at its end, with no app activity (timeline entries). \"Last synced …\" appears"
  print -r -- "   if the app is quit for 30 min."
  print -r -- "3. **Pager / Month.** Tap › on Agenda L: page 2 within ~0.3 s; after 5 min untouched it shows page 1 again."
  print -r -- "   Month: tap a day → its meetings beside/below; arrows stop at the sync window; Small Month day → Day Peek."
  print -r -- "4. **Front app comes back.** With any other app in front, tap › 8 times: \`app.log\` shows"
  print -r -- "   \`front-restore … front-restored=1\` for every tap and \`lsappinfo front\` is unchanged afterwards."
  print -r -- "5. **Event Peek.** Tap a meeting row: the Peek opens at the pointer on that screen; desktop widgets regain colour"
  print -r -- "   right after (agent deactivated) while the Peek stays clickable; Esc (after one click in it) and a click outside"
  print -r -- "   close it. Join opens the call; \"Open in Google Calendar\" opens the event."
  print -r -- "6. **RSVP.** On a \`[YC-TEST]\` invite: Peek → Yes, then Maybe: Google shows the answer within a sync; with Wi-Fi"
  print -r -- "   off the button reverts and the toast says it couldn't send."
  print -r -- "7. **Join chip.** The Join chip on the highlighted row opens the meeting link directly (no Peek)."
  print -r -- "8. **Studio.** Widgets → Agenda → Dark + Rounded + Large → Save: the placed widget changes within a minute."
  print -r -- "   Custom A → name \"Work\", Agenda, ORB only → Save: the slot shows \"Work\" with ORB meetings."
  print -r -- "9. **Calendar section.** Lists today → +60 days; chips filter; a click opens the Event Peek; Sync now works."
  print -r -- "10. **Re-auth strip.** If an account needs sign-in, the amber strip names it and opens Accounts."
  print -r -- "11. No new files in ~/Library/Logs/DiagnosticReports."
} > "$REPORT"
elif [[ "$PHASE" == "p3" ]]; then
{
  print -r -- "# Gate ${PHASE:u}: $status_word"
  print -r -- ""
  print -r -- "Run $(date '+%Y-%m-%d %H:%M %Z') on \`$branch\` @ \`$commit\` by \`Tools/gate.sh $PHASE\` (${total_secs}s total)."
  print -r -- "Toolchain: $swift, SDK $(xcrun --sdk macosx --show-sdk-version 2>/dev/null), target arm64-apple-macos26.0."
  print -r -- "Signed by: ${auth:-?} · code flags: ${flags:-?}. Logs: \`.work/gate-$PHASE/\` (local)."
  print -r -- ""
  print -r -- "| Check | Result | Evidence |"
  print -r -- "|---|---|---|"
  print -rl -- "${RESULTS[@]}"
  print -r -- ""
  print -r -- "## Numbers from the test run"
  print -r -- ""
  for n in "${notes[@]}"; do [[ -n "$n" ]] && print -r -- "- $n"; done
  print -r -- ""
  print -r -- "## Renders (docs/renders/$PHASE, gitignored; regenerate with \`./build.sh --render docs/renders/$PHASE\`)"
  print -r -- ""
  print -r -- "Widgets are drawn from JSON snapshot fixtures through the widget's own read path (\`WidgetSnapshot\` encode →"
  print -r -- "decode → \`SnapshotModel\`), pinned to Monday 19 October 2026, 9:48 AM, London. Mail surfaces use the"
  print -r -- "sample inbox (14 threads, 7 unread, 2 starred; \`FixtureMail\`) behind fake stores (one Inbox and one Studio"
  print -r -- "slot with mail off, for comparison). HTML mail renders its text part headless (ImageRenderer cannot draw a"
  print -r -- "web view); the live reader draws the sanitized HTML in the locked WKWebView. Committed fixtures: \`Tests/Fixtures/\`."
  print -r -- "Logos: $(sed -nE 's/.*"logos" *: *"([^"]*)".*/\1/p' "$RENDERS/render-manifest.json" 2>/dev/null | head -1)."
  print -r -- ""
  print -r -- "Meeting rows on the page shown (light look, full colour):"
  print -r -- ""
  print -r -- "| Fixture | Kind | Family | Page | Meeting rows | Pages |"
  print -r -- "|---|---|---|---|---|---|"
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" look)" == light && "$(mfield "$o" mode)" == fullColor ]] || continue
    rows="$(mfield "$o" meetingRows)"; [[ -n "$rows" ]] || continue
    kind="$(mfield "$o" kind)"; [[ "$kind" == agenda.all || "$kind" == month ]] || continue
    [[ "$(mfield "$o" fixture)" == busy || "$(mfield "$o" fixture)" == sparse ]] || continue
    print -r -- "| $(mfield "$o" fixture) | $kind | $(mfield "$o" family) | $(mfield "$o" page) | $rows | $(mfield "$o" pages) |"
  done | sort -u
  print -r -- ""
  print -r -- "Mail rows on the page shown (light look, full colour):"
  print -r -- ""
  print -r -- "| Fixture | Kind | Family | Page | Mail rows | Pages |"
  print -r -- "|---|---|---|---|---|---|"
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" look)" == light && "$(mfield "$o" mode)" == fullColor ]] || continue
    rows="$(mfield "$o" mailRows)"; [[ -n "$rows" ]] || continue
    print -r -- "| $(mfield "$o" fixture) | $(mfield "$o" kind) | $(mfield "$o" family) | $(mfield "$o" page) | $rows | $(mfield "$o" pages) |"
  done | sort -u
  print -r -- ""
  for group in "widget:Busy week, every kind × family × light/dark (Inbox and Agenda & Inbox draw the live sample inbox)" \
               "state:State fixtures (busyPage2, sparse, dst, empty, noAccounts, stale, reauth, mailComingSoon, setup, customTitle, noSnapshot, mailArchived, inboxZero)" \
               "accented:Accented (white by opacity over glass, D-047), live mail rows included" \
               "vibrant:Vibrant (brightness over glass, D-047), live mail rows included" \
               "glass:Whole-card and strip states, accented and vibrant" \
               "window:Main window (Inbox: reader with the images bar, images loaded, plain text, CMT, Starred, Archived · Undo toast, inbox zero, loading, no accounts, failed, mail off; Calendar; Settings with Mail)" \
               "reader:The paper card alone (remote-images bar; plain text with attachments)" \
               "composer:Composer window (new, reply with quote + signature, the \"I'll check with you\" hint, the approval card for one and for seven people under a Light and a Dark Mac, at 560 × 480 with the list scrolling and with a two-line name, the send refusal, Sending… Undo, switch off)" \
               "peek:Event Peek, Day Peek and Mail Peek (thread with the images bar, plain text, attachments, Archived · Undo)" \
               "settings:Settings → Mail (Primary only, signatures, image senders, Ask before sending to other people on and off)" \
               "studio:Widget Studio (Inbox, Custom slot set to Inbox, Agenda & Inbox dark; a slot with mail off)" \
               "gallery:Full Widgets page" "sheet:Onboarding"; do
    prefix="${group%%:*}"; title="${group#*:}"
    files=( ${(M)pngs:#${prefix}-*} )
    (( ${#files} )) || continue
    print -r -- "**${#files} PNGs: $title**"
    print -r -- ""
    print -r -- '```'
    print -rl -- "${files[@]}" | column -c 130
    print -r -- '```'
    print -r -- ""
  done
  print -r -- "## Live checks after an install (~15 min)"
  print -r -- ""
  print -r -- "Before: \`./build.sh --install\` (its last step unregisters every build copy); confirm"
  print -r -- "\`lsregister -dump | grep -c 'yayacal'\` lists only /Applications. Mail is on (D-029); Ask before sending"
  print -r -- "stays on until step 9."
  print -r -- ""
  print -r -- "1. **Inbox section.** Inbox → Unified Inbox lists every account's threads newest first with the right unread counts in"
  print -r -- "   the sidebar (Unified, one entry per account, Starred). J/K move, Return opens, U/S/E/# act and every action"
  print -r -- "   shows an undo toast (Archived · Undo for 30 s); Undo puts the thread back in Gmail too."
  print -r -- "2. **Reader.** An HTML newsletter opens on the paper card with \"Remote images are hidden. Load images · Always for this"
  print -r -- "   sender\"; no request leaves before Load images (check with Little Snitch or \`nettop -p YayasCalendar\`). A link"
  print -r -- "   opens in the default browser, never inside the card. Plain-text mail reads as text; attachments list name + size."
  print -r -- "3. **Always for this sender.** Images load at once and next time; Settings → Mail lists the sender; Remove hides them again."
  print -r -- "4. **Composer.** New message: From defaults to the last account used. Reply on a"
  print -r -- "   \`[YC-TEST]\` thread: From = the account that received it, the quote and that account's signature are there."
  print -r -- "5. **Ask before sending.** Reply to someone outside your own addresses: Send opens the approval card; Esc keeps the draft, Return sends."
  print -r -- "   Esc on the card puts the cursor back exactly where it was (mid-word in To, and in the body). Holding ⌘↩ and"
  print -r -- "   letting go of ⌘ first doesn't approve it (a held ↩ is ignored); a double-click on Send doesn't either."
  print -r -- "   Reply all with 8+ people at the window's smallest size: the list scrolls to the last Bcc, Send stays visible."
  print -r -- "6. **Send + undo.** \`[YC-TEST]\` mail from one of your accounts to another: ⌘↵ shows \"Sending… · Undo\"; Undo keeps the draft"
  print -r -- "   and nothing arrives; send again and it arrives once (no double send) with your signature."
  print -r -- "7. **Widgets.** Place Inbox (L) and Agenda & Inbox (XL): \"Inbox · N unread\" matches Gmail; the dot marks read, a row"
  print -r -- "   opens the Mail Peek at the pointer (Reply opens the composer), the archive glyph turns the row into"
  print -r -- "   \"Archived · Undo\" for 30 s (Undo brings it back), then the row leaves on its own; the front app comes back."
  print -r -- "8. **Settings → Mail.** Primary inbox only on one account changes what the inbox lists after a sync; a signature edit"
  print -r -- "   shows up in the next reply."
  print -r -- "9. **Settings → Mail → Ask before sending to other people** off: mail to others goes straight out (5 s undo); back on, the card returns."
  print -r -- "10. No new files in ~/Library/Logs/DiagnosticReports; \`--render\` left \`logs/app.log\` untouched (its traces are in"
  print -r -- "    \`docs/renders/p3/trace/\`)."
} > "$REPORT"
else
{
  print -r -- "# Gate ${PHASE:u}: $status_word"
  print -r -- ""
  print -r -- "Run $(date '+%Y-%m-%d %H:%M %Z') on \`$branch\` @ \`$commit\` by \`Tools/gate.sh $PHASE\` (${total_secs}s total)."
  at_least 5 && p5_report_head
  print -r -- "Toolchain: $swift, SDK $(xcrun --sdk macosx --show-sdk-version 2>/dev/null), target arm64-apple-macos26.0."
  print -r -- "Signed by: ${auth:-?} · code flags: ${flags:-?}. Logs: \`.work/gate-$PHASE/\` (local)."
  print -r -- ""
  print -r -- "| Check | Result | Evidence |"
  print -r -- "|---|---|---|"
  print -rl -- "${RESULTS[@]}"
  print -r -- ""
  print -r -- "## Numbers from the test run"
  print -r -- ""
  for n in "${notes[@]}"; do [[ -n "$n" ]] && print -r -- "- $n"; done
  print -r -- ""
  print -r -- "## Renders (docs/renders/$PHASE, gitignored; regenerate with \`./build.sh --render docs/renders/$PHASE\`)"
  print -r -- ""
  print -r -- "Everything P3 drew (widgets from JSON fixtures, mail surfaces behind fakes), plus the P4 menu bar: the popover at"
  print -r -- "380 × 560 pt over fake stores (busy fixture, Monday 19 October 2026 9:48 AM London; one at 10:10 during the 10:00"
  print -r -- "meeting), the status item drawn as a strip of light and dark menu bar for every title shape, the welcome guide at each"
  print -r -- "step over a fake accounts store, and Settings → Menu bar. Text(date, style: .relative) countdowns render as their"
  print -r -- "words (\"Starts in 12 min\"): ImageRenderer would count from the real clock. Logos: $(sed -nE 's/.*"logos" *: *"([^"]*)".*/\1/p' "$RENDERS/render-manifest.json" 2>/dev/null | head -1)."
  print -r -- ""
  print -r -- "Status titles drawn (manifest \`statusItem\` entries):"
  print -r -- ""
  print -r -- "| Variant | Title |"
  print -r -- "|---|---|"
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" window)" == statusItem && "$(mfield "$o" variant)" != all ]] || continue
    t="$(mfield "$o" title)"
    print -r -- "| $(mfield "$o" variant) | \`${t:-(icon only)}\` |"
  done
  print -r -- ""
  print -r -- "Popover states (manifest \`popover\` entries):"
  print -r -- ""
  print -r -- "| State | Tab | Meetings listed | Conversations | Card |"
  print -r -- "|---|---|---|---|---|"
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" window)" == popover ]] || continue
    print -r -- "| $(mfield "$o" state) | $(mfield "$o" tab) | $(mfield "$o" rows) | $(mfield "$o" threads) | $(mfield "$o" card) |"
  done
  print -r -- ""
  for group in "popover:Menu-bar popover (agenda 9:48, live 10:10, CMT chip, 24 h, inbox, inbox zero, clear week, no accounts, mail off)" \
               "status:Status item: glyph + title on light and dark menu bars (icon, next, during, short, short during, right-to-left, past 24 h, unread; all together)" \
               "onboarding:Welcome guide, one step open at a time, then all set" "sheet:Welcome guide, fresh start" \
               "settings:Settings → Mail, Settings → Menu bar (⌃⌥J on; taken by another app)" \
               "widget:Busy week, every kind × family × light/dark" \
               "state:State fixtures (busyPage2, sparse, dst, empty, noAccounts, stale, reauth, mailComingSoon, setup, customTitle, noSnapshot, mailArchived, inboxZero, justSynced, longMonth; Day: busyDay, dayPicked, customDay)" \
               "accented:Accented (white by opacity over glass, D-047)" "vibrant:Vibrant (brightness over glass, D-047)" \
               "glass:Whole-card and strip states, accented and vibrant" \
               "window:Main window sections and states" "reader:The paper card alone" "composer:Composer window" \
               "peek:Event Peek, Day Peek and Mail Peek" "studio:Widget Studio" "gallery:Full Widgets page"; do
    prefix="${group%%:*}"; title="${group#*:}"
    files=( ${(M)pngs:#${prefix}-*} )
    (( ${#files} )) || continue
    print -r -- "**${#files} PNGs: $title**"
    print -r -- ""
    print -r -- '```'
    print -rl -- "${files[@]}" | column -c 130
    print -r -- '```'
    print -r -- ""
  done
  print -r -- "## Day widget (D-022)"
  print -r -- ""
  print -r -- "Kind \`day\` (12 kinds) and Custom slots set to Day, drawn from JSON fixtures through the widget's read path:"
  print -r -- "\`busy\` (Monday's 8 meetings at 9:48), \`busyDay\` (the 20-meeting day: 3-, 4- and 5-way overlaps), \`dayPicked\`"
  print -r -- "(‹ › moved to Wednesday: all-day offsite + 4 meetings, \"Today\" chip, no now line), \`customDay\` (Custom F \"Work\")"
  print -r -- "and the whole-card / strip states. Blocks drawn per family (manifest \`meetingRows\`, light):"
  print -r -- ""
  print -r -- "| Fixture | Kind | Family | Blocks drawn |"
  print -r -- "|---|---|---|---|"
  for o in "${MANIFEST_OBJECTS[@]}"; do
    [[ "$(mfield "$o" look)" == light && "$(mfield "$o" mode)" == fullColor ]] || continue
    kind="$(mfield "$o" kind)"; fx="$(mfield "$o" fixture)"
    [[ "$kind" == day || "$fx" == customDay ]] || continue
    [[ "$fx" == busy || "$fx" == busyDay || "$fx" == dayPicked || "$fx" == customDay ]] || continue
    print -r -- "| $fx | $kind | $(mfield "$o" family) | $(mfield "$o" meetingRows) |"
  done | sort -u
  print -r -- ""
  day_pngs=( ${(M)pngs:#*-day-*} ${(M)pngs:#*customDay*} ${(M)pngs:#studio-*day*} )
  print -r -- "**${#day_pngs} Day PNGs**"
  print -r -- ""
  print -r -- '```'
  print -rl -- "${day_pngs[@]}" | column -c 130
  print -r -- '```'
  print -r -- ""
  print -r -- "Day live checks (after install): place Day (S, M, L, XL, XL Portrait) and Custom F set to Day in Studio. ‹ ›"
  print -r -- "flip days quietly (app.log \`recv day w=day\`; one reload of that kind), and fade at the sync window's edges; the"
  print -r -- "header date or \"Today\" brings today back; ↻ syncs and draws ✓ for 30 s; \"+N\" and an empty slot open the Day"
  print -r -- "Peek; a block opens the Event Peek; Join opens the call. The widget trace shows \`entries=\` ≤ 16 + 3 on today and"
  print -r -- "≤ 3 on another day; the day returns to today after midnight."
  print -r -- ""
  print -r -- "## Live checks after an install (menu bar, ~10 min)"
  print -r -- ""
  print -r -- "Before: merge, \`./build.sh --install\`, confirm \`lsregister -dump | grep -c 'yayacal'\` lists only /Applications."
  print -r -- ""
  print -r -- "1. **Status item.** The calendar glyph draws at its old size. Within the hour before a meeting it reads"
  print -r -- "   \"Title · Nm\" and ticks on the minute (watch one change at :00); during it \"Title · Nm left\"; after the last"
  print -r -- "   meeting only the glyph. Control-click and right-click open the menu and it **stays open** with a title showing"
  print -r -- "   (macOS 27 closes menus for oversized status images; the glyph is still 20 × 15 pt, but the wider item is new)."
  print -r -- "2. **Menu.** Sync now (a \`menu action=sync\` line in app.log), Pause notifications for 1 hour (then the item reads"
  print -r -- "   \"Resume notifications (paused until …)\"; \`defaults read com.yahyaelghobashy.yayascalendar notifications.pausedUntil\`"
  print -r -- "   shows a date an hour ahead), Settings… opens Settings, Quit quits."
  print -r -- "3. **Popover.** Left click opens it under the icon **without** taking focus from the app in front (its title bar"
  print -r -- "   stays active; desktop widgets keep their colour). The card shows the next meeting with a ticking \"Starts in …\""
  print -r -- "   and Join (filled within 30 min). Join opens the call and closes the popover. Agenda rows open the Event Peek"
  print -r -- "   to the left of the popover; Inbox rows open the Mail Peek. Chips filter. Esc, a click"
  print -r -- "   elsewhere, cmd-tab or a Space change close it; clicking the icon again closes it (no flicker reopen)."
  print -r -- "   \"Open Yaya's Calendar\" opens the window; the footer's Made by link opens the profile."
  print -r -- "4. **surfaceVisible.** With the popover open, app.log shows the faster polling (\`surfaceVisible\`); closing it while"
  print -r -- "   the main window stays open keeps it on; closing both turns it off."
  print -r -- "5. **⌃⌥J.** In any app, with a Meet/Zoom/Teams meeting on now or within 30 min: the call opens (\`hotkey"
  print -r -- "   action=join result=opened\`). With nothing joinable: the popover opens. Other apps' ⌃⌥ shortcuts still work (it takes ⌃⌥J only and avoids common ⌃⌥ shortcuts)."
  print -r -- "   Settings → Menu bar → Join with ⌃⌥J off: the key does nothing. With VoiceOver on, Settings says it's resting."
  print -r -- "6. **Menu bar shows.** Icon only / Next meeting / Unread count switch the title at once."
  print -r -- "7. **Welcome guide.** \`open -a \"Yaya's Calendar\" --args --onboarding\` (or Settings → Welcome guide → Open):"
  print -r -- "   steps tick as you go (Google ready and accounts already done on this Mac); Add another runs the add-account"
  print -r -- "   sheet inside the guide; Check for me finds a placed widget; Allow notifications shows the macOS prompt once."
  print -r -- "   Close and reopen: it resumes on the step left open. \"Let's go\" under --onboarding writes the handoff"
  print -r -- "   marker (\`yayascalendar.done\` in the profile's handoff folder); from Settings it doesn't."
  print -r -- "8. **VoiceOver** (⌘F5, then off): the status item reads its countdown; popover rows read title, account, time,"
  print -r -- "   \"has a video link\"; chips and Studio pickers say selected; Peek close says Close."
  print -r -- "9. No new files in ~/Library/Logs/DiagnosticReports."
} > "$REPORT"
fi
at_least 5 && p5_report_tail >> "$REPORT"

print -r -- "▸ evidence: ${REPORT#$ROOT/}"
if (( ${#FAILED} )); then
  print -r -- "✗ gate $PHASE FAILED: ${(j:, :)FAILED} (${total_secs}s)"
  exit 1
fi
pending_note=""; (( ${#PENDING} )) && pending_note=" · PENDING: ${(j:; :)PENDING}"
print -r -- "✓ gate $PHASE passed: ${#RESULTS} checks, $tests, ${#pngs} renders, permissions ${(j:, :)times} (${total_secs}s)$pending_note"
