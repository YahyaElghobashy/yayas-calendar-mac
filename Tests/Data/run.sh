#!/bin/zsh
# Data tests (Store, Sync, Providers/Google, Publish, Mail, Notify): a plain swiftc binary, no XCTest.
# No real Keychain, network, Google APIs, WidgetKit or ~/Library/Application Support: the transport,
# token sources, link-key store, timeline reloader, notification center and Deck ping are fakes
# (Tests/Data/Fakes.swift, NotifyFakes.swift) and all data lives under <worktree>/.work/tests-data/.
#
# Step 2 type-checks the whole app target (everything build.sh compiles into the app, without
# -D YC_DATA_TESTS) so the WidgetKit reloader and the AccountsModel adapter are proven to compile too.
#   Tests/Data/run.sh            build + run + app type-check
#   Tests/Data/run.sh --no-app   skip the app type-check
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h:h}"
source "$ROOT/Tools/lib/common.zsh"
yc_toolchain
trap yc_lock_release EXIT
yc_lock_traps

OUT="$ROOT/.work/tests-data"
SCRATCH="$OUT/scratch"
mkdir -p "$OUT"
rm -rf "$SCRATCH"

SOURCES=(
  "$ROOT"/Sources/Shared/**/*.swift(N)
  "$ROOT"/Sources/Contracts/Stores.swift   # the frozen seam only (Fixtures.swift needs UI types)
  "$ROOT"/Sources/Store/*.swift(N)
  "$ROOT"/Sources/Auth/*.swift(N)
  "$ROOT"/Sources/Net/*.swift(N)
  "$ROOT"/Sources/Sync/*.swift(N)
  "$ROOT"/Sources/Providers/**/*.swift(N)
  "$ROOT"/Sources/Publish/*.swift(N)
  "$ROOT"/Sources/Mail/*.swift(N)
  "$ROOT"/Sources/Notify/*.swift(N)       # app-only parts (UserNotifications, SwiftUI) sit behind !YC_DATA_TESTS
  "$HERE"/*.swift(N)
)

# Every failure path releases the build lock itself: zsh skips the EXIT trap when ERR_EXIT fires on a
# failing *function* (yc_timeout), which would leave the shared lock behind for every other build.
yc_lock_acquire
print -r -- "▸ compiling data tests (${#SOURCES} files)…"
rc=0
yc_timeout 900 "$SWIFTC" -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" -suppress-warnings \
  -D YC_DATA_TESTS -D YC_KEYCHAIN_ASSERT -D YC_DEV_TOOLS -module-name YayasCalendarDataTests "${SOURCES[@]}" \
  -framework Foundation -framework AppKit -framework SwiftUI -framework Security -framework CryptoKit -framework Network \
  -lsqlite3 -o "$OUT/data-tests" || rc=$?
yc_lock_release
(( rc == 0 )) || { print -r -- "✗ data tests did not compile (exit $rc)"; exit $rc; }

rc=0
yc_timeout 300 "$OUT/data-tests" "$SCRATCH" || rc=$?
(( rc == 0 )) || { print -r -- "✗ data tests failed (exit $rc)"; exit $rc; }

if [[ "${1:-}" != "--no-app" ]]; then
  APP_SRC=( "$ROOT"/Sources/**/*.swift(N) )
  APP_SRC=( ${APP_SRC:#*/Sources/Widget/*} )
  yc_lock_acquire
  print -r -- "▸ type-checking the app target with the data layer (${#APP_SRC} files)…"
  rc=0
  # The release configuration (no -D YC_DEV_TOOLS, release profile): what plain ./build.sh compiles.
  yc_timeout 900 "$SWIFTC" -typecheck -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" \
    -suppress-warnings -module-name YayasCalendar "${APP_SRC[@]}" || rc=$?
  yc_lock_release
  (( rc == 0 )) || { print -r -- "✗ app type-check failed (exit $rc)"; exit 1; }
  print -r -- "✓ app target type-checks"
fi
