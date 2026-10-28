#!/bin/zsh
# Headless renders of the accounts screens (ImageRenderer only — never opens a window or the app).
#   Tests/Accounts/render.sh   → docs/renders/accounts/accounts-*.png (gitignored)
# The accounts are the sample cast with its badges, drawn in code; no logo file is read.
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h:h}"; YC_ROOT="$ROOT"
source "$ROOT/Tools/lib/common.zsh"
yc_toolchain
trap yc_lock_release EXIT
yc_lock_traps
OUT="$ROOT/.work/tests-accounts"
RENDERS="$ROOT/docs/renders/accounts"
mkdir -p "$OUT" "$RENDERS"

yc_lock_acquire

echo "▸ compiling accounts renderer…"
"$SWIFTC" -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" -suppress-warnings \
  -D YC_DEV_TOOLS -module-name YayasCalendarAccountsRender \
  "$ROOT"/Sources/Shared/**/*.swift "$ROOT"/Sources/Auth/*.swift "$ROOT"/Sources/Net/*.swift \
  "$ROOT"/Sources/Store/*.swift "$ROOT"/Sources/Accounts/*.swift \
  "$HERE"/{RenderMain,Fakes}.swift \
  -framework AppKit -framework SwiftUI -framework Network -framework Security -framework CryptoKit \
  -framework UniformTypeIdentifiers -lsqlite3 \
  -o "$OUT/accounts-render"
yc_lock_release

rm -rf "$OUT/render-scratch"
"$OUT/accounts-render" "$RENDERS" "$OUT/render-scratch" &
PID=$!
( sleep 120; kill -TERM $PID 2>/dev/null ) &
WATCH=$!
wait $PID
CODE=$?
kill $WATCH 2>/dev/null || true
exit $CODE
