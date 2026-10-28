#!/bin/zsh
# The identifier table (Sources/Shared/Profile.swift, D-034): compiled as the release profile and as the dev
# profile (-D YC_PROFILE_DEV), each run against its rules (release values pinned; no release identifier
# reachable from the dev table), and each printed table compared with build.sh's reading of the same file
# (Tools/lib/common.zsh, yc_profile). Pure logic: no Keychain, files or network.
#   Tests/Profile/run.sh
set -euo pipefail
HERE="${0:A:h}"
YC_ROOT="${HERE:h:h}"
source "$YC_ROOT/Tools/lib/common.zsh"
yc_toolchain
trap yc_lock_release EXIT
yc_lock_traps

OUT="$YC_ROOT/Tests/.out"
mkdir -p "$OUT"
SRC=( "$YC_ROOT/Sources/Shared/Profile.swift" "$HERE/ProfileMain.swift" )

yc_lock_acquire
print -r -- "▸ compiling the profile table (release, dev)…"
for p in release dev; do
  flags=(); [[ "$p" == dev ]] && flags=( -D YC_PROFILE_DEV )
  "$SWIFTC" -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 -sdk "$SDK" \
    -suppress-warnings "${flags[@]}" -module-name ProfileTests "${SRC[@]}" -o "$OUT/profile-$p"
done
yc_lock_release

typeset -i passed=0 failed=0
rc=0
for p in release dev; do
  out="$("$OUT/profile-$p")" || rc=1
  print -r -- "$out" | grep -v '^TESTS ' || true
  summary="$(print -r -- "$out" | sed -n 's/^TESTS //p' | tail -1)"
  passed=$(( passed + ${${summary#passed=}%% *} )); failed=$(( failed + ${summary##*failed=} ))
  # build.sh reads the same file with yc_profile: both readings must agree, key for key.
  swift_table="$("$OUT/profile-$p" --print | sort)"
  yc_profile "$p"
  shell_table="$(for k v in "${(@kv)YC_PROFILE}"; do print -r -- "$k=$v"; done | sort)"
  if [[ "$swift_table" == "$shell_table" ]]; then
    passed=$(( passed + 1 ))
  else
    failed=$(( failed + 1 )); rc=1
    print -r -- "  ✗ build.sh reads a different $p table than Swift compiles:"
    diff <(print -r -- "$swift_table") <(print -r -- "$shell_table") | sed 's/^/    /' || true
  fi
done
print -r -- "▸ Profile: $passed passed, $failed failed (release + dev tables, build.sh's reading)"
(( failed == 0 )) || rc=1
exit $rc
