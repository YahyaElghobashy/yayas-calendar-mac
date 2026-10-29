#!/bin/zsh
# Builds and runs the shell + surface test binary: plain swiftc, no XCTest (not in the Command Line
# Tools). Pure logic only: Sources/Shared, Contracts, the router's decisions and the surface models,
# against fakes and the committed JSON fixtures in Tests/Fixtures. Regenerate those (after reviewing a
# deliberate format change) with: Tests/.out/shell-tests --write-fixtures Tests/Fixtures
# Other suites can add a Tests/<Name>/run.sh; each one found is run after this binary.
# Last line: "TESTS passed=<n> failed=<n>" (build.sh puts it in its summary).
set -euo pipefail
YC_ROOT="${0:A:h:h}"
source "$YC_ROOT/Tools/lib/common.zsh"
yc_toolchain
trap yc_lock_release EXIT
yc_lock_traps

OUT="$YC_ROOT/Tests/.out"
mkdir -p "$OUT"
# The seam (Contracts: Stores + Fixtures), the router's decisions and the surface models; the mail models
# (Inbox section, reader policy, composer, Settings → Mail); the menu bar (status title,
# hotkey decision, popover model + placement, welcome guide flow, VoiceOver words).
SOURCES=( "$YC_ROOT"/Sources/Shared/**/*.swift(N) "$YC_ROOT/Sources/App/SuiteJSON.swift" "$YC_ROOT/Sources/App/RouteDecisions.swift"
          "$YC_ROOT"/Sources/Contracts/*.swift(N)
          "$YC_ROOT"/Sources/UI/RichMail/*.swift(N)   # rich mail's pure UI models (attachment names, saved files)
          "$YC_ROOT"/Sources/UI/{AccountDirectory,PeekModels,WidgetStudioModel,CalendarSectionModel}.swift
          "$YC_ROOT"/Sources/UI/{MailModels,ComposerModel,InboxSectionModel,SettingsMailModel}.swift
          "$YC_ROOT"/Sources/UI/{MenuBarModels,PopoverModel,OnboardingFlow,AccessibilityText,FathomModels}.swift
          "$YC_ROOT"/Sources/UI/{MurmurModels,RecorderModels}.swift   # Yaya's Murmur link and recording per account (D-046)
          "$YC_ROOT"/Sources/UI/{MailHelperModels,MailHelperSession}.swift   # Yaya's Mail Helper link (D-050)
          "$YC_ROOT"/Sources/UI/RichMail/*.swift(N) "$YC_ROOT"/Sources/Mail/{MailHTMLWriter,MailAttribution,MailSize}.swift
          "$YC_ROOT"/Tests/*.swift(N) )
SOURCES=( ${(u)SOURCES} )   # one copy of each file, however many globs name it

yc_lock_acquire
print -r -- "▸ compiling tests (${#SOURCES} files)…"
# -D YC_DEV_TOOLS: the fixture link key and the test doubles in Sources/Contracts/Fixtures.swift (D-035).
"$SWIFTC" -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" -suppress-warnings \
  -D YC_DEV_TOOLS -module-name ShellTests "${SOURCES[@]}" -framework SwiftUI -framework AppKit -framework UserNotifications -framework CryptoKit \
  -o "$OUT/shell-tests"
yc_lock_release

rc=0
export YC_FIXTURES="$YC_ROOT/Tests/Fixtures"
yc_timeout 120 "$OUT/shell-tests" | tee "$OUT/shell-tests.log" || rc=$?
summary="$(sed -n 's/^TESTS //p' "$OUT/shell-tests.log" | tail -1)"
passed="${${summary#passed=}%% *}"; failed="${summary##*failed=}"

# Each suite gets 600 s of its own time: while it waits for the build lock (another worktree compiling),
# yc_timeout stops counting (YC_LOCK_WAIT_FILE, Tools/lib/common.zsh).
for hook in "$YC_ROOT"/Tests/*/run.sh(N); do
  print -r -- "▸ ${hook#$YC_ROOT/}…"
  hrc=0; yc_timeout 600 "$hook" || hrc=$?
  if (( hrc == 124 )); then rc=1; print -r -- "✗ ${hook#$YC_ROOT/} ran out of its 600 s (lock waits not counted)"
  elif (( hrc )); then rc=1; print -r -- "✗ ${hook#$YC_ROOT/} failed (exit $hrc)"; fi
done

print -r -- "TESTS passed=${passed:-0} failed=${failed:-?}"
exit $rc
