#!/bin/zsh
# Accounts tests (Store, Accounts, Logos, Provider Setup): a plain swiftc binary, no XCTest.
# No real Keychain, network, browser, pasteboard or ~/Library/Application Support: every seam is
# faked (Tests/Accounts/Fakes.swift) and all data lives under <worktree>/.work/tests-accounts/.
#   Tests/Accounts/run.sh
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h:h}"; YC_ROOT="$ROOT"
source "$ROOT/Tools/lib/common.zsh"
yc_toolchain                     # SDK honours YC_SDK
trap yc_lock_release EXIT
yc_lock_traps
OUT="$ROOT/.work/tests-accounts"
SCRATCH="$OUT/scratch"
mkdir -p "$OUT"
rm -rf "$SCRATCH"

# Global build lock shared with every other build on this Mac (one compile at a time).
yc_lock_acquire
echo "▸ compiling accounts tests…"
"$SWIFTC" -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" -suppress-warnings \
  -D YC_KEYCHAIN_ASSERT -D YC_DEV_TOOLS -module-name YayasCalendarAccountsTests \
  "$ROOT"/Sources/Shared/**/*.swift "$ROOT"/Sources/Auth/*.swift "$ROOT"/Sources/Net/*.swift \
  "$ROOT"/Sources/Store/*.swift "$ROOT"/Sources/Accounts/*.swift \
  "$ROOT/Sources/Contracts/Stores.swift" "$ROOT/Sources/App/RouteDecisions.swift" \
  "$HERE"/{TestMain,Fakes,StoreTests,CoreTests,LogoTests,ModelTests,KeychainLaunchTests,SetupTests}.swift \
  -framework AppKit -framework SwiftUI -framework Network -framework Security -framework CryptoKit \
  -framework UniformTypeIdentifiers -lsqlite3 \
  -o "$OUT/accounts-tests"
yc_lock_release

# The binary never waits on the network; 120 s is a hard stop if something hangs.
"$OUT/accounts-tests" "$SCRATCH" &
PID=$!
( sleep 120; kill -TERM $PID 2>/dev/null ) &
WATCH=$!
wait $PID
CODE=$?
kill $WATCH 2>/dev/null || true
exit $CODE
