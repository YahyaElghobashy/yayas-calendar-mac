#!/bin/zsh
# Yaya's Calendar: builds the resident menu-bar app (LSUIElement) with its widget extension
# YayasCalendarWidget.appex, using swiftc + codesign from the Command Line Tools (no Xcode project).
#
#   ./build.sh                    release profile, signed with your local identity → build/Yaya's Calendar.app
#                                 (Config/signing.local.sh; Tools/setup-signing.sh creates one per Mac)
#   ./build.sh --install          … then install to $INSTALL_DIR (default /Applications) and relaunch
#   ./build.sh --dev              dev profile + developer tools, ad-hoc → build/Yaya's Calendar Dev.app: its own
#                                 bundle ids, yayacal-dev://, data folder and Keychain services, so it never
#                                 touches the real app's data, scheme, Keychain items or widgets. Needs no
#                                 Config. Gates and CI use this.
#   ./build.sh --release          release profile, no developer tools, dead-stripped and `strip -x`ed, signed
#                                 with the release identity from the login keychain (Config/release.sh);
#                                 its designated requirement must match docs/DR.txt. Tools/make-release.sh
#                                 then packages it (zip + SHA256SUMS, extended attributes stripped, UTC)
#   ./build.sh --adhoc            ad-hoc signature instead of an identity (with --release: gate checks only,
#                                 never shipped or installed)
#   ./build.sh --test             … then build and run the tests (Tests/run-tests.sh)
#   ./build.sh --selftest         … with developer tools; then run the built app with --selftest (headless)
#   ./build.sh --render <dir>     … with developer tools; then --render <dir> (headless PNGs)
#   ./build.sh --bench <dir>      … with developer tools; then --bench <dir> (headless widget timings)
#
# The identifiers come from Sources/Shared/Profile.swift (one table). CFBundleVersion is YYYYMMDD.N: the UTC
# date, then this Mac's build count for that UTC day (kept in ~/Library/Caches/YayasCalendar-build/), so it is
# new with every build (chronod caches widget renders by it) and never carries a time of day.
# YC_BUILD_NUMBER=YYYYMMDD.N sets it instead (a release).
# The expected designated requirement is derived from the identity used; docs/DR.txt holds only the release
# identity's and is checked whenever that identity signs. Never falls back to ad-hoc on its own (D-007):
# Keychain items follow the designated requirement.
# Every build ends by unregistering build copies from LaunchServices (this one, the main checkout's and every
# .work/wt-* worktree's): a stale worktree copy once claimed yayacal:// and delayed links 7 s. --install repeats
# that as its very last step, after the installed copy is registered and launched.
# The last line printed is a one-line summary (gates and installers read it with `tail -1`).
set -euo pipefail
cd "${0:A:h}"
YC_ROOT="$PWD"; ROOT="$PWD"
source "$ROOT/Tools/lib/common.zsh"
SECONDS=0

DEV=0; RELEASE=0; ADHOC=0; TEST=0; SELFTEST=0; INSTALL=0; RENDER_DIR=""; BENCH_DIR=""
while (( $# )); do
  case "$1" in
    --dev) DEV=1 ;;
    --release) RELEASE=1 ;;
    --adhoc) ADHOC=1 ;;
    --test) TEST=1 ;;
    --selftest) SELFTEST=1 ;;
    --install) INSTALL=1 ;;
    --render|--bench)
      (( $# >= 2 )) || yc_fail "$1 needs a directory"
      dir="$2"; [[ "$dir" == /* ]] || dir="$ROOT/$dir"
      if [[ "$1" == --render ]]; then RENDER_DIR="$dir"; else BENCH_DIR="$dir"; fi
      shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) yc_fail "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ── 0. Configuration: profile, developer tools, signing ───────────────────────────────────────────
DEV_TOOLS=$DEV
if (( SELFTEST )) || [[ -n "$RENDER_DIR" || -n "$BENCH_DIR" ]]; then DEV_TOOLS=1; fi
(( DEV && RELEASE )) && yc_fail "--dev and --release are different builds; pick one"
(( RELEASE && DEV_TOOLS )) && yc_fail "--release never carries developer tools (--selftest, --render, --bench need --dev)"
if (( INSTALL )); then
  (( DEV || DEV_TOOLS )) && yc_fail "--install never installs a dev build or one with developer tools"
  (( ADHOC )) && yc_fail "--install never installs an ad-hoc build (Keychain items follow the signature, D-007)"
fi
PROFILE=release; (( DEV )) && PROFILE=dev
yc_profile "$PROFILE"
if (( DEV || ADHOC )); then SIGN_MODE=adhoc
elif (( RELEASE )); then SIGN_MODE=release
else SIGN_MODE=local; fi

APP_NAME="${YC_PROFILE[displayName]}"
APP_ID="${YC_PROFILE[bundleId]}"; WIDGET_ID="${YC_PROFILE[widgetBundleId]}"; URL_SCHEME="${YC_PROFILE[urlScheme]}"
WIDGET_ENTITLEMENTS="$ROOT/${YC_PROFILE[widgetEntitlements]}"
WIDGET_FOLDER="/${YC_PROFILE[dataRoot]}/widget/"
APP_EXEC="YayasCalendar"; WIDGET_EXEC="YayasCalendarWidget"
MIN_OS="26.0"; TARGET="arm64-apple-macos$MIN_OS"
VERSION="$(plutil -extract version raw -o - "$ROOT/version.json")"
# YYYYMMDD.N in UTC, new every build: chronod caches renders by it. The counter file is shared by every
# checkout on this Mac and locked while it is read and written.
yc_build_number() {
  local day; day="$(date -u +%Y%m%d)"
  local dir="$HOME/Library/Caches/YayasCalendar-build"; mkdir -p "$dir"
  /usr/bin/perl -e '
    use strict; use warnings; use Fcntl qw(:flock O_RDWR O_CREAT);
    my ($file, $day) = @ARGV;
    sysopen(my $fh, $file, O_RDWR | O_CREAT, 0600) or die "build number: $file: $!\n";
    flock($fh, LOCK_EX) or die "build number: lock: $!\n";
    my $line = <$fh> // "";
    my ($d, $n) = $line =~ /\A(\d{8}) (\d+)\s*\z/ ? ($1, $2) : ("", 0);
    $n = $d eq $day ? $n + 1 : 1;
    seek($fh, 0, 0); truncate($fh, 0); print {$fh} "$day $n\n"; close $fh or die "build number: $!\n";
    print "$day.$n\n";
  ' "$dir/build-number" "$day"
}
if [[ -n "${YC_BUILD_NUMBER:-}" ]]; then
  [[ "$YC_BUILD_NUMBER" =~ '^[0-9]{8}\.[1-9][0-9]*$' ]] || yc_fail "YC_BUILD_NUMBER must look like YYYYMMDD.N (got: $YC_BUILD_NUMBER)"
  BUILD_NUM="$YC_BUILD_NUMBER"
else
  BUILD_NUM="$(yc_build_number)" || yc_fail "could not count this build (~/Library/Caches/YayasCalendar-build/build-number)"
fi
BUILD="$ROOT/build"; WORK="$ROOT/.work"
APP="$BUILD/$APP_NAME.app"; APPEX="$APP/Contents/PlugIns/$WIDGET_EXEC.appex"

yc_toolchain
trap yc_lock_release EXIT
yc_lock_traps
print -r -- "▸ swiftc : $("$SWIFTC" --version 2>&1 | head -1)"
print -r -- "▸ target : $TARGET (SDK $SDK_VER) · $APP_NAME $VERSION ($BUILD_NUM)"
print -r -- "▸ profile: $PROFILE ($APP_ID, $URL_SCHEME://)$( (( DEV_TOOLS )) && print ' + developer tools')$( (( RELEASE )) && print ' · release strip')"
if (( DEV )); then
  print -r -- "▸ ┌──────────────────────────────────────────────────────────────────────────────────────────┐"
  print -r -- "▸ │ DEV BUILD: ad-hoc signed, developer tools inside. \"$APP_NAME\" is a separate app: its own   "
  print -r -- "▸ │ bundle ids, $URL_SCHEME://, ~/${YC_PROFILE[dataRoot]} and Keychain services.            "
  print -r -- "▸ │ Not for daily use, never installed: macOS treats every rebuild as a new app.              "
  print -r -- "▸ └──────────────────────────────────────────────────────────────────────────────────────────┘"
elif (( ADHOC )); then
  print -r -- "▸ AD-HOC SIGNATURE: for checks only. Never install or ship this build: Keychain items would"
  print -r -- "▸ follow a signature that changes with every rebuild."
fi

# ── 1. Secrets in the repo ────────────────────────────────────────────────────────────────────────
"$ROOT/Tools/check-secrets.sh"

# ── 2. Compile (under the global lock) ───────────────────────────────────────────────────────────
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$WORK"

APP_SRC=( "$ROOT"/Sources/**/*.swift(N) )
APP_SRC=( ${APP_SRC:#*/Sources/Widget/*} )                     # everything but the extension
WIDGET_SRC=( "$ROOT"/Sources/Shared/**/*.swift(N) "$ROOT"/Sources/Widget/*.swift(N) )
COMMON=( -O -swift-version 5 -parse-as-library -target "$TARGET" -sdk "$SDK" -suppress-warnings )
(( DEV )) && COMMON+=( -D YC_PROFILE_DEV )
(( DEV_TOOLS )) && COMMON+=( -D YC_DEV_TOOLS )
LINK=()
(( RELEASE )) && LINK+=( -Xlinker -dead_strip )

yc_lock_acquire
print -r -- "▸ compiling app (${#APP_SRC} files)…"
"$SWIFTC" "${COMMON[@]}" -module-name "$APP_EXEC" "${APP_SRC[@]}" \
  -framework SwiftUI -framework AppKit -framework WidgetKit -framework ServiceManagement \
  -framework UserNotifications -framework Security -framework Network -framework CryptoKit \
  -framework WebKit -framework Carbon -framework Combine "${LINK[@]}" \
  -o "$APP/Contents/MacOS/$APP_EXEC"

# The extension must enter at _NSExtensionMain: a Swift main traps in the ExtensionKit bootstrap.
print -r -- "▸ compiling widget extension (${#WIDGET_SRC} files)…"
"$SWIFTC" "${COMMON[@]}" -D WIDGET_EXTENSION -application-extension -module-name "$WIDGET_EXEC" \
  "${WIDGET_SRC[@]}" -framework SwiftUI -framework WidgetKit \
  -Xlinker -e -Xlinker _NSExtensionMain "${LINK[@]}" \
  -o "$APPEX/Contents/MacOS/$WIDGET_EXEC"
yc_lock_release

# ── 3. No App Intents anywhere (no Team ID: linkd rejects them; D-004) ───────────────────────────
for bin in "$APP/Contents/MacOS/$APP_EXEC" "$APPEX/Contents/MacOS/$WIDGET_EXEC"; do
  defined="$(nm -U "$bin" 2>/dev/null || true)"
  [[ "$defined" != *10AppIntents* && "$defined" != *IntentVMa* ]] || yc_fail "${bin:t} defines App Intents types"
done
[[ ! -e "$APPEX/Contents/Resources/Metadata.appintents" ]] || yc_fail "Metadata.appintents must not exist"

# ── 3b. Release strip: local symbols out before signing. Reflection metadata stays: SwiftUI
#        reads field names at run time, so -disable-reflection-metadata is never passed. ─────────────
if (( RELEASE )); then
  : > "$WORK/release-symbols.txt"
  for bin in "$APP/Contents/MacOS/$APP_EXEC" "$APPEX/Contents/MacOS/$WIDGET_EXEC"; do
    before="$(yc_symbol_counts "$bin")"
    strip -x "$bin"
    after="$(yc_symbol_counts "$bin")"
    print -r -- "▸ strip  : ${bin:t}: $before → $after"
    print -r -- "${bin:t}: before $before; after $after (dead_strip + strip -x)" >> "$WORK/release-symbols.txt"
  done
fi

# ── 4. Info.plists ───────────────────────────────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$APP_EXEC</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$APP_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUM</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>DTPlatformName</key><string>macosx</string>
	<key>DTPlatformVersion</key><string>$SDK_VER</string>
	<key>DTSDKName</key><string>macosx$SDK_VER</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHumanReadableCopyright</key><string>© 2026 Yahya Elghobashy · MIT License</string>
	<key>NSMicrophoneUsageDescription</key><string>Only for Draft with AI's voice note: you say what the reply should say, and Yaya's Mail Helper writes it out on this Mac.</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>$APP_ID</string>
			<key>CFBundleURLSchemes</key><array><string>$URL_SCHEME</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$WIDGET_EXEC</string>
	<key>CFBundleIdentifier</key><string>$WIDGET_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$WIDGET_EXEC</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>XPC!</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUM</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>DTPlatformName</key><string>macosx</string>
	<key>DTPlatformVersion</key><string>$SDK_VER</string>
	<key>DTSDKName</key><string>macosx$SDK_VER</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
	<key>NSHumanReadableCopyright</key><string>© 2026 Yahya Elghobashy · MIT License</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist" || yc_fail "Info.plist lint failed"
print -n "APPL????" > "$APP/Contents/PkgInfo"

# ── 4b. Resources: the app icon, the menu bar glyph (Tools/make-icons.sh draws them), the licences ──
for f in Resources/Generated/AppIcon.icns Resources/Generated/MenuBarIcon.png Resources/Generated/MenuBarIcon@2x.png \
         LICENSE THIRD_PARTY_NOTICES.md; do
  [[ -f "$ROOT/$f" ]] || yc_fail "missing $f"
  cp "$ROOT/$f" "$APP/Contents/Resources/"
done

# ── 5. Sign. The expected designated requirement is derived from the identity used. ───────────────
print -r -- "▸ signing ($SIGN_MODE)…"
[[ -f "$WIDGET_ENTITLEMENTS" ]] || yc_fail "missing ${WIDGET_ENTITLEMENTS#$ROOT/}"
[[ "$(<"$WIDGET_ENTITLEMENTS")" == *"<string>$WIDGET_FOLDER</string>"* ]] \
  || yc_fail "${WIDGET_ENTITLEMENTS#$ROOT/} must grant exactly the profile's widget folder ($WIDGET_FOLDER)"
RELEASE_DR_FILE="$ROOT/docs/DR.txt"
release_dr() { local dr; dr="$(<"$RELEASE_DR_FILE")"; [[ "$dr" == "identifier "* ]] && print -r -- "$dr"; }
IDENTITY_LABEL=""; SIGN_SHA1=""; KEYCHAIN=""
case "$SIGN_MODE" in
  adhoc)
    SIGN=( codesign --force --timestamp=none --sign - ) ;;
  release)
    source "$ROOT/Config/release.sh"
    IDENTITY_LABEL="$RELEASE_IDENTITY"; KEYCHAIN="$RELEASE_KEYCHAIN"
    [[ -f "$KEYCHAIN" ]] || yc_fail "the login keychain is not at $KEYCHAIN"
    SIGN_SHA1="$(yc_identity_sha1 "$IDENTITY_LABEL" "$KEYCHAIN")"
    [[ -n "$SIGN_SHA1" ]] || yc_fail "the release identity \"$IDENTITY_LABEL\" is not in the login keychain.
    It is created once, in Terminal: Tools/create-release-identity.sh.
    For checks without it: ./build.sh --release --adhoc (never shipped)."
    [[ -n "$(release_dr)" ]] || yc_fail "docs/DR.txt holds no release DR yet (Tools/create-release-identity.sh writes it)" ;;
  local)
    SIGNING_CONF="$ROOT/Config/signing.local.sh"
    [[ -f "$SIGNING_CONF" ]] || yc_fail "no signing identity configured ($SIGNING_CONF is missing).
    Build from source: Tools/setup-signing.sh creates a per-Mac identity once, then ./build.sh.
    A quick look without one: ./build.sh --dev (a separate dev app, ad-hoc signed)."
    source "$SIGNING_CONF"
    # SIGN_* (Tools/setup-signing.sh). A local file older than that names the same three values
    # <PREFIX>_IDENTITY, <PREFIX>_KC and <PREFIX>_KC_PASSWORD; it still works (CONTRIBUTING.md, "Signing").
    old_prefix=""
    if [[ -z "${SIGN_IDENTITY:-}" ]]; then
      old_prefix="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9]*)_IDENTITY=.*/\2/p' "$SIGNING_CONF" | sort -u)"
      [[ "$old_prefix" =~ '^[A-Z][A-Z0-9]*$' && "$old_prefix" != SIGN ]] || old_prefix=""
    fi
    if [[ -n "$old_prefix" ]]; then
      old_id="${old_prefix}_IDENTITY"; old_kc="${old_prefix}_KC"; old_pw="${old_prefix}_KC_PASSWORD"
      IDENTITY_LABEL="${(P)old_id:-}"; KEYCHAIN="${(P)old_kc:-}"; SIGN_KEYCHAIN_PASSWORD="${(P)old_pw:-}"
      unset "$old_pw"
      print -r -- "▸ signing: ${SIGNING_CONF#$ROOT/} uses older variable names; rename them to SIGN_* (CONTRIBUTING.md)"
    else
      IDENTITY_LABEL="${SIGN_IDENTITY:-}"; KEYCHAIN="${SIGN_KEYCHAIN:-}"
    fi
    [[ -n "$IDENTITY_LABEL" ]] || yc_fail "$SIGNING_CONF must set SIGN_IDENTITY"
    kc_pw=""
    if [[ -n "${SIGN_KEYCHAIN_PASSWORD_SERVICE:-}" ]]; then
      # Tools/setup-signing.sh keeps the signing keychain's random password in the login keychain.
      kc_pw="$(security find-generic-password -a "$USER" -s "$SIGN_KEYCHAIN_PASSWORD_SERVICE" -w 2>/dev/null)" \
        || yc_fail "the signing keychain's password is not in the login keychain ($SIGN_KEYCHAIN_PASSWORD_SERVICE); run Tools/setup-signing.sh again"
    else
      kc_pw="${SIGN_KEYCHAIN_PASSWORD:-}"
    fi
    unset SIGN_KEYCHAIN_PASSWORD
    if [[ -n "$KEYCHAIN" ]]; then
      [[ -f "$KEYCHAIN" ]] || yc_fail "signing keychain not found: $KEYCHAIN"
      [[ -z "$kc_pw" ]] || yc_keychain_unlock "$KEYCHAIN" "$kc_pw" || yc_fail "could not unlock ${KEYCHAIN:t}"
    fi
    kc_pw=""
    SIGN_SHA1="$(yc_identity_sha1 "$IDENTITY_LABEL" "$KEYCHAIN")"
    [[ -n "$SIGN_SHA1" ]] || yc_fail "\"$IDENTITY_LABEL\" is not in ${KEYCHAIN:-the keychain search list}" ;;
esac
if [[ "$SIGN_MODE" != adhoc ]]; then
  SIGN=( codesign --force --timestamp=none --sign "$SIGN_SHA1" )
  [[ -n "$KEYCHAIN" ]] && SIGN+=( --keychain "$KEYCHAIN" )
  # find-certificate lists certificates codesign may still reject: prove the identity on a scratch copy,
  # which also yields the designated requirement this identity gives the app.
  PROBE="$WORK/sign-probe"; rm -f "$PROBE"; cp /bin/echo "$PROBE"
  "${SIGN[@]}" --identifier "$APP_ID" "$PROBE" >/dev/null 2>&1 \
    || yc_fail "codesign cannot use \"$IDENTITY_LABEL\" (refusing to fall back to ad-hoc)"
  EXPECTED_DR="$(codesign -d -r- "$PROBE" 2>&1 | sed -n 's/^designated => //p')"
  rm -f "$PROBE"
  [[ "$EXPECTED_DR" == "identifier \"$APP_ID\" and "* ]] || yc_fail "unexpected designated requirement from the probe: $EXPECTED_DR"
  if [[ "$SIGN_MODE" == release || -n "$(release_dr)" && "$EXPECTED_DR" == "$(release_dr)" ]]; then
    [[ "$EXPECTED_DR" == "$(release_dr)" ]] || yc_fail "the release identity's DR differs from docs/DR.txt:
    derived:  $EXPECTED_DR
    expected: $(release_dr)"
    DR_SOURCE="docs/DR.txt (release identity)"
  else
    DR_SOURCE="derived from \"$IDENTITY_LABEL\""
  fi
fi

xattr -cr "$APP"
"${SIGN[@]}" --options runtime --identifier "$WIDGET_ID" --entitlements "$WIDGET_ENTITLEMENTS" "$APPEX"
APP_ENTITLEMENTS="$ROOT/Resources/App.entitlements"
[[ -f "$APP_ENTITLEMENTS" ]] || yc_fail "missing Resources/App.entitlements"
"${SIGN[@]}" --options runtime --identifier "$APP_ID" --entitlements "$APP_ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP" || yc_fail "codesign --verify --deep --strict failed"

if [[ "$SIGN_MODE" == adhoc ]]; then
  cdhash="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
  EXPECTED_DR="cdhash H\"$cdhash\""; DR_SOURCE="ad-hoc (cdhash)"; AUTHORITY="adhoc"
  for bundle in "$APPEX" "$APP"; do
    [[ "$(codesign -dvv "$bundle" 2>&1)" == *"Signature=adhoc"* ]] || yc_fail "${bundle:t} is not ad-hoc signed"
  done
else
  AUTHORITY="$IDENTITY_LABEL"
  for bundle in "$APPEX" "$APP"; do
    [[ "$(codesign -dvv "$bundle" 2>&1)" == *"Authority=$IDENTITY_LABEL"* ]] || yc_fail "${bundle:t} is not signed by \"$IDENTITY_LABEL\""
  done
fi
for bundle in "$APPEX" "$APP"; do
  [[ "$(codesign -dvv "$bundle" 2>&1)" =~ 'flags=0x[0-9a-f]+\([^)]*runtime' ]] || yc_fail "${bundle:t} lacks the hardened runtime"
done
entitlements="$(codesign -d --entitlements - --xml "$APPEX" 2>/dev/null)"
[[ "$entitlements" == *"$WIDGET_FOLDER"* && "$entitlements" == *app-sandbox* ]] \
  || yc_fail "widget entitlements missing the sandbox or the widget-folder exception ($WIDGET_FOLDER)"
[[ "$entitlements" != *network* ]] || yc_fail "the widget must not have a network entitlement"
app_entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
[[ "$app_entitlements" == *device.audio-input* && "$app_entitlements" != *network* && "$app_entitlements" != *camera* ]] \
  || yc_fail "the app's entitlements must be the microphone (voice note) and nothing else"
DR="$(codesign -d -r- "$APP" 2>&1 | sed -nE 's/^(# )?designated => //p')"
[[ "$DR" == "$EXPECTED_DR" ]] || yc_fail "designated requirement mismatch:
    built:    $DR
    expected: $EXPECTED_DR ($DR_SOURCE)"
print -r -- "$DR" > "$WORK/expected-dr.txt"
print -r -- "▸ DR     : matches, $DR_SOURCE"

# ── 6. Secrets in the bundle ─────────────────────────────────────────────────────────────────────
"$ROOT/Tools/check-secrets.sh" "$APP"

flavour="$PROFILE"; if (( DEV_TOOLS )); then flavour+="+devtools"; fi; if (( RELEASE )); then flavour+=" stripped"; fi
SUMMARY=( "✓ $APP_NAME $VERSION ($BUILD_NUM) $flavour, signed \"$AUTHORITY\", DR ok" )

# ── 7. Tests, self-test, renders, bench ──────────────────────────────────────────────────────────
if (( TEST )); then
  print -r -- "▸ tests…"
  "$ROOT/Tests/run-tests.sh" | tee "$WORK/tests.log"
  SUMMARY+=( "$(sed -n 's/^TESTS //p' "$WORK/tests.log" | tail -1)" )
fi
if (( SELFTEST )); then
  print -r -- "▸ self-test (headless)…"
  rc=0; out="$(yc_timeout 60 "$APP/Contents/MacOS/$APP_EXEC" --selftest)" || rc=$?
  print -r -- "$out"
  (( rc == 0 )) || yc_fail "self-test failed (exit $rc)"
  SUMMARY+=( "selftest pass" )
fi
if [[ -n "$RENDER_DIR" ]]; then
  print -r -- "▸ rendering to ${RENDER_DIR#$ROOT/} (headless)…"
  rm -rf "$RENDER_DIR"; mkdir -p "$RENDER_DIR"
  # Renders draw only the sample cast and its badges (drawn in code); they never read a logo file.
  rc=0; yc_timeout 300 "$APP/Contents/MacOS/$APP_EXEC" --render "$RENDER_DIR" | tee "$WORK/render.log" || rc=$?
  (( rc == 0 )) || yc_fail "render failed (exit $rc)"
  SUMMARY+=( "$(ls "$RENDER_DIR"/*.png | wc -l | tr -d ' ') renders" )
fi
if [[ -n "$BENCH_DIR" ]]; then
  print -r -- "▸ bench to ${BENCH_DIR#$ROOT/} (headless)…"
  rm -rf "$BENCH_DIR"; mkdir -p "$BENCH_DIR"
  rc=0; YC_FIXTURES="$ROOT/Tests/Fixtures" yc_timeout 900 "$APP/Contents/MacOS/$APP_EXEC" --bench "$BENCH_DIR" \
    | tee "$WORK/bench.log" || rc=$?
  (( rc == 0 )) || yc_fail "bench failed (exit $rc)"
  SUMMARY+=( "bench done" )
fi

# ── 8. No build copy may own the URL scheme or the widget gallery ────────────────────────────────
# `--permissions-json` and a cold `open` check the bundle in with LaunchServices; only the installed copy
# should stay registered. Unregister this copy, the main checkout's and every worktree's build copy.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
yc_unregister_build_copies() {
  local common main
  common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  main="${common:h}"; [[ -n "$common" && -d "$main" ]] || main="$ROOT"
  local -a copies=( "$APP" "$ROOT"/build/*.app(N) "$ROOT"/.work/wt-*/build/*.app(N)
                    "$main"/build/*.app(N) "$main"/.work/wt-*/build/*.app(N) )
  local -A seen; local -i n=0
  for copy in "${copies[@]}"; do
    [[ -d "$copy" && -z "${seen[$copy]:-}" ]] || continue
    seen[$copy]=1
    yc_timeout 30 "$LSREG" -u "$copy" >/dev/null 2>&1 || true
    (( n += 1 ))
  done
  print -r -- "▸ lsregister -u: $n build cop$( (( n == 1 )) && print y || print ies) unregistered"
}
yc_unregister_build_copies

# ── 9. Install (announced first: it quits the running app) ───────────────────────────────────────
if (( INSTALL )); then
  INSTALL_DIR="${INSTALL_DIR:-/Applications}"
  [[ "$INSTALL_DIR" == /* ]] || yc_fail "INSTALL_DIR must be an absolute path"
  mkdir -p "$INSTALL_DIR"
  DEST="$INSTALL_DIR/$APP_NAME.app"
  REPORTS="$HOME/Library/Logs/DiagnosticReports"
  reports_before=$(ls "$REPORTS" 2>/dev/null | wc -l | tr -d ' ')
  print -r -- "▸ installing to $DEST…"
  if [[ -d "$DEST" ]]; then
    old="$(plutil -extract CFBundleVersion raw -o - "$DEST/Contents/Info.plist" 2>/dev/null || echo unknown)"
    mkdir -p "$WORK/rollback/$old"; rm -rf "$WORK/rollback/$old/$APP_NAME.app"
    ditto "$DEST" "$WORK/rollback/$old/$APP_NAME.app"
    keep=( "$WORK"/rollback/*(/Om) ); (( ${#keep} > 3 )) && rm -rf "${keep[@]:3}"
  fi
  pkill -x "$APP_EXEC" >/dev/null 2>&1 || true            # SIGTERM: the app terminates cleanly
  for _ in {1..25}; do pgrep -x "$APP_EXEC" >/dev/null || break; sleep 0.2; done
  # chronod keeps talking to whichever widget process is alive: kill it and drop stale registrations.
  pkill -f "$WIDGET_EXEC.appex/Contents/MacOS/$WIDGET_EXEC" >/dev/null 2>&1 || true
  pluginkit -r "$APPEX" >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  "$LSREG" -f "$DEST" >/dev/null 2>&1 || true
  pluginkit -a "$DEST/Contents/PlugIns/$WIDGET_EXEC.appex" >/dev/null 2>&1 || true
  open -g "$DEST"
  # Last install step (after --install the build copy once still claimed yayacal://). Registering
  # the installed copy and launching it can re-register the build copy it was copied from, so unregister
  # every build copy (this one, the main checkout's, every .work/wt-*) only AFTER the install is in.
  sleep 1
  yc_unregister_build_copies
  reports_after=$(ls "$REPORTS" 2>/dev/null | wc -l | tr -d ' ')
  print -r -- "▸ installed; DiagnosticReports $reports_before → $reports_after"
  SUMMARY+=( "installed" )
fi

print -r -- "${(j: · :)SUMMARY} · ${SECONDS}s"
