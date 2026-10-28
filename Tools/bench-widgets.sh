#!/bin/zsh
# Widget performance benchmark. Headless: never opens, installs or registers anything, and
# never reads the real App Support, Keychain or network.
#
#   Tools/bench-widgets.sh <out-dir> [--no-build]
#
# 1. Widget side: ./build.sh --dev (skipped with --no-build), then the built app runs `--bench <out>/widget`:
#    decode + SnapshotModel + TimelinePlan + every entry laid out and drawn with ImageRenderer, for the
#    committed fixtures (Tests/Fixtures) and a heavy 120-meeting month (with the sample cast's badges,
#    drawn in code: the bench never reads a logo file of its own).
#    Then `day20`: the Day widget design vs the Agenda over one 20-meeting day (L, XL, XLP), same moments.
# 2. App side: the data layer + Tests/Data built with -O into .work/perf/bin/data-bench, then
#    `data-bench <scratch> --bench <out>/tap.json`: a widget tap's state write + publish + flushChanged
#    on a temp store under .work/perf/scratch (~3k events, 4 accounts), with the reloads it asks for.
# Last line: "BENCH done <out-dir>".
set -euo pipefail
YC_ROOT="${0:A:h:h}"; ROOT="$YC_ROOT"
source "$ROOT/Tools/lib/common.zsh"
yc_toolchain
trap yc_lock_release EXIT
yc_lock_traps

(( $# >= 1 )) || yc_fail "usage: Tools/bench-widgets.sh <out-dir> [--no-build]"
OUT="$1"; [[ "$OUT" == /* ]] || OUT="$ROOT/$OUT"
BUILD=1; [[ "${2:-}" == "--no-build" ]] && BUILD=0
yc_profile dev   # the bench needs developer tools: the dev build
APP_BIN="$ROOT/build/${YC_PROFILE[displayName]}.app/Contents/MacOS/YayasCalendar"
mkdir -p "$OUT"

if (( BUILD )); then
  print -r -- "▸ build…"
  yc_timeout 1800 "$ROOT/build.sh" --dev > "$OUT/build.log" 2>&1 || yc_fail "build failed (see $OUT/build.log)"
fi
[[ -x "$APP_BIN" ]] || yc_fail "no built app at $APP_BIN (run ./build.sh --dev)"

print -r -- "▸ widget bench…"
export YC_FIXTURES="$ROOT/Tests/Fixtures"
rm -rf "$OUT/widget"
yc_timeout 900 "$APP_BIN" --bench "$OUT/widget" | tee "$OUT/widget.txt"

print -r -- "▸ tap bench (compiling with -O)…"
BIN="$ROOT/.work/perf/bin"; SCRATCH="$ROOT/.work/perf/scratch"
mkdir -p "$BIN"; rm -rf "$SCRATCH"
SOURCES=(
  "$ROOT"/Sources/Shared/**/*.swift(N) "$ROOT"/Sources/Contracts/Stores.swift "$ROOT"/Sources/Store/*.swift(N)
  "$ROOT"/Sources/Auth/*.swift(N) "$ROOT"/Sources/Net/*.swift(N) "$ROOT"/Sources/Sync/*.swift(N)
  "$ROOT"/Sources/Providers/**/*.swift(N) "$ROOT"/Sources/Publish/*.swift(N) "$ROOT"/Sources/Mail/*.swift(N)
  "$ROOT"/Sources/Notify/*.swift(N)
  "$ROOT"/Tests/Data/*.swift(N)
)
yc_lock_acquire
rc=0
yc_timeout 900 "$SWIFTC" -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" -suppress-warnings \
  -D YC_DATA_TESTS -D YC_KEYCHAIN_ASSERT -D YC_DEV_TOOLS -module-name YayasCalendarDataTests "${SOURCES[@]}" \
  -framework Foundation -framework AppKit -framework SwiftUI -framework Security -framework CryptoKit -framework Network \
  -lsqlite3 -o "$BIN/data-bench" || rc=$?
yc_lock_release
(( rc == 0 )) || yc_fail "tap bench did not compile (exit $rc)"
yc_timeout 600 "$BIN/data-bench" "$SCRATCH" --bench "$OUT/tap.json" | tee "$OUT/tap.txt"
rm -rf "$SCRATCH"
print -r -- "BENCH done $OUT"
