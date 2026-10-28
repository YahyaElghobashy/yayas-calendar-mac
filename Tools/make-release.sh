#!/bin/zsh
# Packages a release build for the repository's Releases page. It never builds, signs, commits, tags or
# uploads anything.
#
#   ./build.sh --release                        (YC_BUILD_NUMBER=YYYYMMDD.N ./build.sh --release sets the build)
#   Tools/make-release.sh [--adhoc] [<app>] [<out dir>]
#                                               default: "build/Yaya's Calendar.app" → dist/
#
#   --adhoc   accept an ad-hoc signed release-profile app (`./build.sh --release --adhoc`) to try the
#             packaging; the result says so and is never uploaded
#
# 1. The app: the release profile's bundle id, a YYYYMMDD.N build number, signed by the release identity
#    (Config/release.sh) with the hardened runtime, its designated requirement equal to docs/DR.txt, and
#    `codesign --verify --deep --strict`.
# 2. A staged copy (`ditto --norsrc --noextattr --noqtn`), then `xattr -cr` on it: no extended attribute
#    is left (com.apple.provenance, quarantine, Finder info, resource forks). Every file's date becomes
#    00:00 UTC on the build number's day, so the zip holds no time of day.
# 3. The zip: `TZ=UTC ditto -c -k --norsrc --noextattr --noqtn --keepParent` →
#    <out>/Yayas-Calendar-macOS-arm64.zip (the fixed name of D-024), with no AppleDouble (._*) or
#    __MACOSX entries.
# 4. <out>/SHA256SUMS with the bare file name, so `shasum -a 256 -c SHA256SUMS` works in the download folder.
# 5. The result checked: the zip unpacked into a scratch folder verifies (codesign and, unless --adhoc,
#    docs/DR.txt), the sums check, and Tools/check-public.sh --strict --bundle passes on the unpacked app.
#
# The public repository (D-025) starts at one commit. Make that commit and the release tag in UTC, dated
# the release day with no time of day, and check the release notes before they are posted:
#   export TZ=UTC GIT_AUTHOR_DATE="2026-11-01T00:00:00Z" GIT_COMMITTER_DATE="2026-11-01T00:00:00Z"
#   git commit -m "Yaya's Calendar 1.0.0"
#   git tag -a v1.0.0 -m "Yaya's Calendar 1.0.0"      # the tagger date comes from GIT_COMMITTER_DATE
#   Tools/check-public.sh --strict --text <release notes file>
set -euo pipefail
YC_ROOT="${0:A:h:h}"; ROOT="$YC_ROOT"
source "$ROOT/Tools/lib/common.zsh"

ADHOC=0; typeset -a args=()
for a in "$@"; do
  case "$a" in
    --adhoc) ADHOC=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*) yc_fail "unknown option: $a (see --help)" ;;
    *) args+=( "$a" ) ;;
  esac
done
(( ${#args} <= 2 )) || yc_fail "usage: Tools/make-release.sh [--adhoc] [<app>] [<out dir>]"

yc_profile release
APP="${args[1]:-$ROOT/build/${YC_PROFILE[displayName]}.app}"; APP="${APP:A}"
OUT="${args[2]:-$ROOT/dist}"; [[ "$OUT" == /* ]] || OUT="$PWD/$OUT"
ZIP="Yayas-Calendar-macOS-arm64.zip"
[[ -d "$APP" ]] || yc_fail "no app at $APP (build it with ./build.sh --release)"

# ── 1. The app ───────────────────────────────────────────────────────────────────────────────────
plist="$APP/Contents/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null || true)"
build="$(plutil -extract CFBundleVersion raw -o - "$plist" 2>/dev/null || true)"
[[ "$bundle_id" == "${YC_PROFILE[bundleId]}" ]] || yc_fail "not the release profile: bundle id ${bundle_id:-missing}"
[[ "$build" =~ '^[0-9]{8}\.[1-9][0-9]*$' ]] || yc_fail "build number ${build:-missing} is not YYYYMMDD.N"
codesign --verify --deep --strict "$APP" || yc_fail "codesign --verify --deep --strict failed"
sig="$(codesign -dvv "$APP" 2>&1)"
[[ "$sig" =~ 'flags=0x[0-9a-f]+\([^)]*runtime' ]] || yc_fail "the app lacks the hardened runtime"
if (( ADHOC )); then
  [[ "$sig" == *"Signature=adhoc"* ]] || yc_fail "--adhoc is for ad-hoc builds only"
  print -r -- "▸ AD-HOC: a packaging try, never uploaded"
else
  source "$ROOT/Config/release.sh"
  [[ "$sig" == *"Authority=$RELEASE_IDENTITY"* ]] || yc_fail "not signed by the release identity \"$RELEASE_IDENTITY\""
  expected="$(<"$ROOT/docs/DR.txt")"
  [[ "$expected" == "identifier "* ]] || yc_fail "docs/DR.txt holds no release designated requirement"
  dr="$(codesign -d -r- "$APP" 2>&1 | sed -nE 's/^(# )?designated => //p')"
  [[ "$dr" == "$expected" ]] || yc_fail "designated requirement differs from docs/DR.txt:
    app:      $dr
    expected: $expected"
fi
print -r -- "▸ app    : ${YC_PROFILE[displayName]} $version ($build), ${bundle_id}"

# ── 2. Staged copy: no extended attributes, dates at 00:00 UTC on the build's day ────────────────
STAGE="$ROOT/.work/release-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
STAGED="$STAGE/${APP:t}"
ditto --norsrc --noextattr --noqtn "$APP" "$STAGED"
xattr -cr "$STAGED"
left="$(xattr -lr "$STAGED" 2>/dev/null | cut -d: -f2 | sort -u | tr -d ' ' | tr '\n' ' ' || true)"
[[ -z "${left// /}" ]] || print -r -- "▸ note   : xattr could not clear ${left}on the staged copy; the zip leaves every extended attribute out"
day="${build%%.*}"
TZ=UTC find "$STAGED" -exec touch -h -t "${day}0000.00" {} +
codesign --verify --deep --strict "$STAGED" || yc_fail "the staged copy no longer verifies"

# ── 3. The zip ───────────────────────────────────────────────────────────────────────────────────
mkdir -p "$OUT"; rm -f "$OUT/$ZIP" "$OUT/SHA256SUMS"
( cd "$STAGE" && TZ=UTC ditto -c -k --norsrc --noextattr --noqtn --keepParent "${STAGED:t}" "$OUT/$ZIP" )
entries="$(zipinfo -1 "$OUT/$ZIP")"
[[ -z "$(print -r -- "$entries" | grep -E '(^|/)\._|^__MACOSX/' || true)" ]] || yc_fail "the zip carries AppleDouble or __MACOSX entries"
[[ "$(print -r -- "$entries" | head -1)" == "${STAGED:t}/"* ]] || yc_fail "the zip's top folder is not ${STAGED:t}"

# ── 4. SHA256SUMS, bare names ────────────────────────────────────────────────────────────────────
( cd "$OUT" && shasum -a 256 "$ZIP" > SHA256SUMS && shasum -a 256 -c SHA256SUMS >/dev/null ) || yc_fail "SHA256SUMS does not check"

# ── 5. The result: unpacked, it verifies and passes the bundle leak check ────────────────────────
CHECK="$STAGE/unpacked"; mkdir -p "$CHECK"
ditto -x -k "$OUT/$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/${STAGED:t}" || yc_fail "the unpacked app does not verify"
if (( ! ADHOC )); then
  [[ "$(codesign -d -r- "$CHECK/${STAGED:t}" 2>&1 | sed -nE 's/^(# )?designated => //p')" == "$(<"$ROOT/docs/DR.txt")" ]] \
    || yc_fail "the unpacked app's designated requirement differs from docs/DR.txt"
fi
"$ROOT/Tools/check-public.sh" --strict --bundle "$CHECK/${STAGED:t}" > "$STAGE/check-public-bundle.txt" 2>&1 \
  || yc_fail "check-public --strict --bundle failed on the unpacked app (see ${STAGE#$ROOT/}/check-public-bundle.txt)"
rm -rf "$CHECK"

print -r -- "▸ zip    : ${OUT}/$ZIP ($(stat -f %z "$OUT/$ZIP") bytes, $(print -r -- "$entries" | wc -l | tr -d ' ') entries)"
print -r -- "▸ sums   : ${OUT}/SHA256SUMS → $(cat "$OUT/SHA256SUMS")"
(( ADHOC )) && print -r -- "▸ AD-HOC: do not upload this zip"
print -r -- "Next, in UTC with the release day's date and no time of day: the public commit and tag (see --help)."
print -r -- "✓ $ZIP + SHA256SUMS for ${YC_PROFILE[displayName]} $version ($build)$( (( ADHOC )) && print ' · ad-hoc try')"
