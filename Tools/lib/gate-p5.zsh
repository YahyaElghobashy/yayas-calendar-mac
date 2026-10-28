# Gate p5 (stranger-ready build): sourced by Tools/gate.sh after the p4 checks, while build/ still holds the
# dev app ($APP).
# Uses gate.sh's pass / fail / pending, $ROOT, $APP, $BIN, $LOGS, $PHASE and the common.zsh helpers.
# Never runs a real --purge or --uninstall; the dry run is proven dry on the dev app before the release
# binary sees it, and the release run is sandboxed (no network, no writes under ~/Library, no Keychain,
# login-item or notification services).

typeset -g P5_REL_MODE="" P5_REL_APP="" P5_SYMBOLS="" P5_CLONE="" P5_DRY_FLAGS="" P5_DEV_UNINSTALLER=""
typeset -ga P5_DEV_HITS

p5_dev_names() { yc_profile dev; print -r -- "${YC_PROFILE[keychainOAuth]} ${YC_PROFILE[keychainClient]} ${YC_PROFILE[keychainLinkKey]} ${YC_PROFILE[dataRoot]}" }
p5_rel_names() { yc_profile release; print -r -- "${YC_PROFILE[keychainOAuth]} ${YC_PROFILE[keychainClient]} ${YC_PROFILE[keychainLinkKey]} ${YC_PROFILE[dataRoot]}" }

# ── a. Sealed: the source tree and the dev bundle ───────────────────────────────────────────────
rc=0; out="$(yc_timeout 180 "$ROOT/Tools/check-sealed.sh" "$APP" 2>&1)" || rc=$?
print -r -- "$out" > "$LOGS/sealed-dev.log"
if (( rc == 0 )); then pass "check-sealed (tree + dev app)" "${$(print -r -- "$out" | tail -1)#✓ }"
else fail "check-sealed (tree + dev app)" "see .work/gate-$PHASE/sealed-dev.log"; fi

# ── b. Dev profile: the table test ran in the passing test run; the dev app reaches no release name ──
prof="$(grep -E '^▸ Profile: ' "$LOGS/build.log" | tail -1 || true)"
if [[ "$prof" == *" 0 failed"* ]]; then pass "dev-profile identifier test" "${prof#▸ Profile: } (Tests/Profile)"
else fail "dev-profile identifier test" "${prof:-Tests/Profile did not run}"; fi

rc=0; out="$(yc_timeout 120 "$ROOT/Tools/check-profile.sh" "$APP" 2>&1)" || rc=$?
print -r -- "$out" > "$LOGS/check-profile.log"
if (( rc == 0 )); then
  pass "dev app: no release identifier" "${out#✓ check-profile: }"
else
  # Self-closing pending: the only hits are the Keychain service names Sources/App/Uninstaller.swift still
  # spells out until it reads them from Profile.Uninstall. Once the file reads the table, any hit fails.
  P5_DEV_HITS=( ${(f)"$(cut -f3 "$ROOT/.work/check-profile/hits.tsv" 2>/dev/null)"} )
  uninstaller="$ROOT/Sources/App/Uninstaller.swift"
  base="$(yc_profile release; print -r -- "${YC_PROFILE[bundleId]}")"
  literals=( ${(f)"$(grep -oE "\"${base//./\\.}[^\"]*\"" "$uninstaller" 2>/dev/null | tr -d '"')"} )
  outside=( ${P5_DEV_HITS:|literals} )
  if (( ${#P5_DEV_HITS} )) && (( ${#outside} == 0 )) && ! grep -q 'Profile\.' "$uninstaller"; then
    P5_DEV_UNINSTALLER="${(j:, :)P5_DEV_HITS}"
    pending "dev app: Uninstaller names" "only Sources/App/Uninstaller.swift's ${#P5_DEV_HITS} release Keychain service names reach the dev app; its switch to \`Profile.Uninstall\` closes this (any other hit fails)"
  else
    fail "dev app: no release identifier" "see .work/gate-$PHASE/check-profile.log"
  fi
fi

# ── c. The dry run, declared by the uninstaller's flag list and proven dry on the dev app first ─────
# The launch-flag list is the doc comment of the file that handles them (Sources/App, docs/CONTRACTS.md).
declared="$(grep -hE '^[[:space:]]*///[[:space:]]+(--uninstall[[:space:]]+)?--purge[[:space:]]+--dry-run' "$ROOT"/Sources/App/*.swift 2>/dev/null | head -1 || true)"
typeset -a dry_flags=()
for w in ${=${declared#*///}}; do [[ "$w" == --* ]] && dry_flags+=( "$w" ) || break; done
# Unquoted on purpose: inside double quotes zsh joins the array before the :# filter, so nothing is removed.
typeset -a other_flags=( ${dry_flags:#(--uninstall|--purge|--dry-run)} )
dev_dry_ok=0
if [[ -z "$declared" ]] || ! grep -q '"--dry-run"' "$ROOT"/Sources/App/*.swift; then
  pending "--purge --dry-run" "not declared in the launch-flag list yet: not run"
elif (( ${#other_flags} )) || (( ${dry_flags[(I)--dry-run]} == 0 )); then
  fail "--purge --dry-run" "declared flags \`${dry_flags[*]}\` are not a dry run"
else
  P5_DRY_FLAGS="${dry_flags[*]}"
  dev_root="$(yc_profile dev; print -r -- "$HOME/${YC_PROFILE[dataRoot]}")"
  mkdir -p "$dev_root"; canary="$dev_root/.gate-dry-run-canary"; print -r -- "p5" > "$canary"
  rc=0; out="$(yc_timeout 20 sandbox-exec -p '(version 1)(allow default)(deny network*)' "$BIN" "${dry_flags[@]}" 2>&1)" || rc=$?
  print -r -- "$out" > "$LOGS/dry-run-dev.log"
  missing=(); for n in ${=$(p5_dev_names)}; do [[ "$out" == *"$n"* ]] || missing+=( "$n" ); done
  if (( rc == 0 )) && [[ -f "$canary" ]] && (( ${#missing} == 0 )); then
    dev_dry_ok=1; pass "--purge --dry-run (dev app)" "\`${dry_flags[*]}\` exit 0, lists the dev Keychain services and data folder, removed nothing (canary kept)"
  else
    fail "--purge --dry-run (dev app)" "exit $rc, canary $([[ -f "$canary" ]] && print kept || print GONE), missing ${(j:, :)missing}; release run skipped"
  fi
  rm -f "$canary"
fi

# ── d. The release build: release identity when it exists, else ad-hoc (pending until it exists) ──
rel_sha="$(source "$ROOT/Config/release.sh"; yc_identity_sha1 "$RELEASE_IDENTITY" "$RELEASE_KEYCHAIN")" || rel_sha=""
if [[ -n "$rel_sha" && "$(<"$ROOT/docs/DR.txt")" == "identifier "* ]]; then
  P5_REL_MODE="release identity"; rel_flags=( --release )
else
  P5_REL_MODE="ad-hoc"; rel_flags=( --release --adhoc )
  pending "release identity" "release identity pending (Tools/create-release-identity.sh not run yet): the release config was built ad-hoc for the symbol and contract checks"
fi
t0=$EPOCHREALTIME; rc=0
yc_timeout 1800 "$ROOT/build.sh" "${rel_flags[@]}" > "$LOGS/release-build.log" 2>&1 || rc=$?
secs=$(printf '%.0f' $(( EPOCHREALTIME - t0 )))
P5_REL_APP="$ROOT/build/$(yc_profile release; print -r -- "${YC_PROFILE[displayName]}").app"
REL_BIN="$P5_REL_APP/Contents/MacOS/YayasCalendar"
REL_WIDGET="$P5_REL_APP/Contents/PlugIns/YayasCalendarWidget.appex/Contents/MacOS/YayasCalendarWidget"
if (( rc == 0 )) && [[ -x "$REL_BIN" ]]; then
  pass "release build (\`${rel_flags[*]}\`)" "${secs}s · \`$(tail -1 "$LOGS/release-build.log")\`"
else
  fail "release build (\`${rel_flags[*]}\`)" "exit $rc, see .work/gate-$PHASE/release-build.log"
fi

if [[ -x "$REL_BIN" && -x "$REL_WIDGET" ]]; then
  # No developer tool in the release binaries, as symbols or strings; local symbols near zero.
  dev_marks='HeadlessRender|HeadlessBench|SelfTest|DevClientFile|FakeCalendarStore|FakeMailStore|FakeMailActions|FakeMailPreferences|FakeWidget|FixtureServices|fixture link key|YAYACAL_DEV_OAUTH'
  # Rich mail's renders and fixtures (fenced the same way after its merge).
  dev_marks+='|RichMailRenders|RichMailReaderRenders|RichMailAttachmentRenders|RichComposerRenders|RichSendRenders|RichMailCast|RichMailBodies|RichMailThreads|RichComposerFixtures|FakeMailAttachments|RICHMAIL-BENCH'
  typeset -a found=() counts=()
  local_ok=1
  for bin in "$REL_BIN" "$REL_WIDGET"; do
    marks="$( { nm -a "$bin" 2>/dev/null; strings -a "$bin"; } | grep -oE "$dev_marks" | sort -u | tr '\n' ' ' || true)"
    [[ -z "${marks// /}" ]] || found+=( "${bin:t}: $marks" )
    c="$(yc_symbol_counts "$bin")"; counts+=( "${bin:t} $c" )
    (( ${c%% *} <= 50 )) || local_ok=0
  done
  P5_SYMBOLS="$(cat "$ROOT/.work/release-symbols.txt" 2>/dev/null || true)"
  if (( ${#found} == 0 )); then pass "release: no developer tools" "no HeadlessRender, HeadlessBench, SelfTest, DevClientFile, rich-mail renders or fixtures, fakes or fixture link key (nm -a + strings)"
  else fail "release: no developer tools" "${(j:; :)found}"; fi
  if (( local_ok )); then pass "release: local symbols near zero" "${(j:; :)counts} (dead_strip + strip -x; before: ${(j:; :)${(f)P5_SYMBOLS}})"
  else fail "release: local symbols near zero" "${(j:; :)counts}"; fi

  rc=0; out="$(yc_timeout 180 "$ROOT/Tools/check-sealed.sh" "$P5_REL_APP" 2>&1)" || rc=$?
  print -r -- "$out" > "$LOGS/sealed-release.log"
  (( rc == 0 )) && pass "check-sealed (release app)" "bundle: two Mach-O files, reviewed URLs only, widget links no network framework" \
    || fail "check-sealed (release app)" "see .work/gate-$PHASE/sealed-release.log"

  # The installer contract on the release binary: --permissions-json is one valid JSON line, headless.
  rc=0; out="$(yc_timeout 10 "$REL_BIN" --permissions-json 2>/dev/null)" || rc=$?
  print -r -- "$out" > "$LOGS/perm-release.out"
  if (( rc == 0 )) && [[ "$(print -r -- "$out" | wc -l | tr -d ' ')" == 1 ]] \
     && print -r -- "$out" | /usr/bin/python3 -I -c 'import json,sys; o=json.loads(sys.stdin.read()); assert o["app"]=="yayascalendar" and isinstance(o["loginItem"], bool) and o["notifications"] in ("granted","denied","undetermined")' 2>/dev/null; then
    pass "installer contract: --permissions-json (release)" "\`$out\` (valid JSON, one line, exit 0)"
  else
    fail "installer contract: --permissions-json (release)" "exit $rc: \`${out:-no output}\`"
  fi

  if (( dev_dry_ok )); then
    sb="(version 1)(allow default)(deny network*)(deny file-write* (subpath \"$HOME/Library\") (subpath \"$HOME/Applications\"))"
    sb+='(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc")'
    sb+=' (global-name-regex #"^com\.apple\.backgroundtaskmanagement") (global-name-regex #"^com\.apple\.usernotifications") (global-name-regex #"^com\.apple\.usernoted"))'
    rc=0; out="$(yc_timeout 20 sandbox-exec -p "$sb" "$REL_BIN" ${=P5_DRY_FLAGS} 2>&1)" || rc=$?
    print -r -- "$out" > "$LOGS/dry-run-release.log"
    missing=(); for n in ${=$(p5_rel_names)}; do [[ "$out" == *"$n"* ]] || missing+=( "$n" ); done
    if (( rc == 0 )) && (( ${#missing} == 0 )); then
      pass "installer contract: $P5_DRY_FLAGS (release, sandboxed)" "lists the three Keychain services and the data folder; names only"
    else
      fail "installer contract: $P5_DRY_FLAGS (release, sandboxed)" "exit $rc, missing ${(j:, :)missing}"
    fi
  fi
fi

# ── e. A fresh clone builds with --dev and no Config ─────────────────────────────────────────────
CLONE="$ROOT/.work/fresh-clone"
rm -rf "$CLONE"
head_commit="$(git -C "$ROOT" rev-parse --short HEAD)"
dirty="$(git -C "$ROOT" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
rc=0
git clone --quiet --no-local --no-hardlinks --branch "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" "$ROOT" "$CLONE" > "$LOGS/fresh-clone.log" 2>&1 || rc=$?
# A clone has only tracked files: no Config/*.local.* (the *.local.example.* templates are tracked).
local_cfg=( "$CLONE"/Config/*.local.*(N) )
local_cfg=( ${local_cfg:#*.local.example.*} )
if (( rc == 0 )) && (( ${#local_cfg} == 0 )); then
  t0=$EPOCHREALTIME
  yc_timeout 1800 "$CLONE/build.sh" --dev >> "$LOGS/fresh-clone.log" 2>&1 || rc=$?
  secs=$(printf '%.0f' $(( EPOCHREALTIME - t0 )))
fi
P5_CLONE="$(tail -1 "$LOGS/fresh-clone.log")"
if (( rc == 0 )) && (( ${#local_cfg} == 0 )) && [[ "$P5_CLONE" == "✓ "* ]]; then
  pass "fresh clone builds with --dev" "\`git clone\` of \`$head_commit\`, no Config/*.local.*, ${secs}s · \`$P5_CLONE\`$( (( dirty )) && print " (the worktree had $dirty uncommitted file(s): the clone builds the commit)")"
else
  fail "fresh clone builds with --dev" "exit $rc, local config ${#local_cfg}, see .work/gate-$PHASE/fresh-clone.log"
fi
unregister_build_copies >/dev/null
rm -rf "$CLONE"

# ── Report sections ──────────────────────────────────────────────────────────────────────────────
p5_report_head() {
  print -r -- "Builds: the p1-p4 checks ran on \`./build.sh --dev\` (dev profile + developer tools, ad-hoc); the release"
  print -r -- "checks on \`./build.sh ${rel_flags[*]}\` (${P5_REL_MODE}). Never a real --purge or --uninstall."
}
p5_report_tail() {
  print -r -- ""
  print -r -- "## P5: stranger-ready build"
  print -r -- ""
  print -r -- "- Release build: \`./build.sh ${rel_flags[*]}\` ($P5_REL_MODE). Symbols before and after the release strip:"
  for l in ${(f)P5_SYMBOLS}; do print -r -- "  - $l"; done
  print -r -- "- Dev profile: \`Tools/check-profile.sh\` over the dev app's strings, plists, entitlements and signing"
  print -r -- "  identifiers; release names from the one table. ${P5_DEV_UNINSTALLER:+Pending: $P5_DEV_UNINSTALLER from Sources/App/Uninstaller.swift.}"
  print -r -- "- Dry run: ${P5_DRY_FLAGS:-not declared yet}."
  print -r -- "- Fresh clone: \`$P5_CLONE\`."
  print -r -- "- Pending: ${(j:; :)PENDING:-none}."
}
