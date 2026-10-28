#!/bin/zsh
# Remove everything (D-037): the plan, --purge --dry-run and the removal engine, against temporary folders
# under <worktree>/.work/tests-uninstall and a fake keychain. Never the real Keychain, home, preferences,
# login item or notifications: every system call is a seam, and -D YC_KEYCHAIN_ASSERT traps a Keychain
# call on the main thread.
#   Tests/Uninstall/run.sh
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h:h}"
source "$ROOT/Tools/lib/common.zsh"
yc_toolchain
trap yc_lock_release EXIT
yc_lock_traps

OUT="$ROOT/.work/tests-uninstall"
SCRATCH="$OUT/scratch"
mkdir -p "$OUT"
rm -rf "$SCRATCH"

SOURCES=(
  "$ROOT"/Sources/Shared/**/*.swift(N)
  "$ROOT"/Sources/Auth/*.swift(N)
  "$ROOT"/Sources/Net/*.swift(N)
  "$ROOT/Sources/App/Uninstaller.swift"
  "$HERE"/*.swift(N)
)

yc_lock_acquire
print -r -- "▸ compiling uninstall tests (${#SOURCES} files)…"
rc=0
yc_timeout 900 "$SWIFTC" -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" -suppress-warnings \
  -D YC_KEYCHAIN_ASSERT -module-name YayasCalendarUninstallTests "${SOURCES[@]}" \
  -framework Foundation -framework AppKit -framework SwiftUI -framework Security -framework CryptoKit -framework Network \
  -o "$OUT/uninstall-tests" || rc=$?
yc_lock_release
(( rc == 0 )) || { print -r -- "✗ uninstall tests did not compile (exit $rc)"; exit $rc; }

rc=0
yc_timeout 120 "$OUT/uninstall-tests" "$SCRATCH" || rc=$?
(( rc == 0 )) || { print -r -- "✗ uninstall tests failed (exit $rc)"; exit $rc; }
