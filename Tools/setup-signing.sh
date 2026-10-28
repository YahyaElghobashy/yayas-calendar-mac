#!/bin/zsh
# For people who build Yaya's Calendar from source: creates this Mac's own code-signing identity, once, so
# every ./build.sh on this Mac carries the same signature and macOS keeps the app's Keychain items (the
# Google sign-ins) across rebuilds instead of asking again. The identity is:
#   - calendar-only: its own name and keychain, so nothing else can sign as this app with it;
#   - the certificate's subject is the common name and nothing else (no email, organisation or place);
#   - the keychain's password is random, made here, and kept in your login keychain (never in a file).
#
#   Tools/setup-signing.sh             create it (does nothing when a working identity is already set up)
#   Tools/setup-signing.sh --replace   delete this script's keychain and password item, then create anew
#                                      (your next build's signature changes: macOS asks for Keychain access
#                                      once per item)
#
# Writes Config/signing.local.sh (gitignored, names only). Free and offline. It is not notarization: a copy
# you give someone else still shows Gatekeeper's prompt; builds you run yourself do not. Undo:
#   security delete-keychain ~/Library/Keychains/yayascalendar-signing.keychain-db
#   security delete-generic-password -s "Yayas Calendar signing keychain"
#   rm Config/signing.local.sh
set -euo pipefail
YC_ROOT="${0:A:h:h}"; ROOT="$YC_ROOT"
source "$ROOT/Tools/lib/common.zsh"

IDENTITY="Yayas Calendar Local Signing"
KC="$HOME/Library/Keychains/yayascalendar-signing.keychain-db"
PW_SERVICE="Yayas Calendar signing keychain"
CONF="$ROOT/Config/signing.local.sh"
REPLACE=0
case "${1:-}" in
  "") ;;
  --replace) REPLACE=1 ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  *) yc_fail "unknown option: $1 (see --help)" ;;
esac
yc_profile release
APP_ID="${YC_PROFILE[bundleId]}"

# The password is only ever handed to `security` and `openssl` on stdin.
password() { security find-generic-password -a "$USER" -s "$PW_SERVICE" -w 2>/dev/null; }
sec() { print -r -- "$1" | security -i >/dev/null 2>&1; }

can_sign() {
  local sha probe ok=1
  local pw; pw="$(password)" || return 1
  [[ -f "$KC" ]] || return 1
  yc_keychain_unlock "$KC" "$pw" || return 1
  pw=""
  sha="$(yc_identity_sha1 "$IDENTITY" "$KC")"; [[ -n "$sha" ]] || return 1
  probe="$(mktemp "${TMPDIR:-/tmp}/yc-probe.XXXXXX")"; cp /bin/echo "$probe"
  codesign --force --timestamp=none --sign "$sha" --keychain "$KC" --identifier "$APP_ID" "$probe" >/dev/null 2>&1 && ok=0
  rm -f "$probe"
  return $ok
}

write_conf() {
  umask 077
  cat > "$CONF" <<CONF
# Written by Tools/setup-signing.sh. Names only: the keychain's password stays in the login keychain.
SIGN_IDENTITY="$IDENTITY"
SIGN_KEYCHAIN="\$HOME/Library/Keychains/${KC:t}"
SIGN_KEYCHAIN_PASSWORD_SERVICE="$PW_SERVICE"
CONF
}

if (( ! REPLACE )) && can_sign; then
  [[ -f "$CONF" ]] || write_conf
  print -r -- "✓ \"$IDENTITY\" is ready (${KC:t}); ./build.sh uses it."
  exit 0
fi
if [[ -f "$KC" ]] && (( ! REPLACE )); then
  yc_fail "${KC:t} exists but cannot sign (its password item is missing or wrong). Run Tools/setup-signing.sh --replace to make a new one."
fi

print -r -- "▸ creating \"$IDENTITY\" in ${KC:t}…"
if (( REPLACE )); then
  security delete-keychain "$KC" >/dev/null 2>&1 || true
  security delete-generic-password -a "$USER" -s "$PW_SERVICE" >/dev/null 2>&1 || true
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/yc-signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# Random keychain password, kept in the login keychain (service "$PW_SERVICE"). `security` made the item,
# so `security` may read it back without a prompt; build.sh does that to unlock the signing keychain.
pw="$(openssl rand -hex 24)"
sec "add-generic-password -U -a \"$USER\" -s \"$PW_SERVICE\" -l \"$PW_SERVICE\" -w \"$pw\""
[[ "$(password)" == "$pw" ]] || yc_fail "could not store the keychain password in the login keychain"

# A self-signed code-signing certificate whose subject is the common name only.
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$IDENTITY" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
subject="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -subject -nameopt RFC2253 | sed -E 's/^subject= *//')"
[[ "$subject" == "CN=$IDENTITY" ]] || yc_fail "unexpected certificate subject: $subject"
# PBE-SHA1-3DES + sha1 MAC: what security(1) imports reliably (LibreSSL and OpenSSL 3 alike).
print -r -- "$pw" | /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY" \
  -out "$WORK/id.p12" -passout stdin -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  || yc_fail "openssl could not package the identity"

sec "create-keychain -p \"$pw\" \"$KC\""
[[ -f "$KC" ]] || yc_fail "could not create ${KC:t}"
security set-keychain-settings "$KC"   # no lock timeout; it still locks at logout
sec "unlock-keychain -p \"$pw\" \"$KC\""
sec "import \"$WORK/id.p12\" -k \"$KC\" -P \"$pw\" -T /usr/bin/codesign"
sec "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \"$pw\" \"$KC\""
pw=""
existing=( ${(f)"$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//')"} )
security list-keychains -d user -s "$KC" ${existing:#$KC}

can_sign || yc_fail "the identity was imported but codesign cannot use it (keychain search list?)"
write_conf
sha="$(yc_identity_sha1 "$IDENTITY" "$KC")"
print -r -- "✓ created \"$IDENTITY\" (certificate SHA-1 $sha) in ${KC:t}; wrote ${CONF#$ROOT/}."
print -r -- "  ./build.sh and ./build.sh --install now sign with it; the expected designated requirement is"
print -r -- "  derived from it on every build."
