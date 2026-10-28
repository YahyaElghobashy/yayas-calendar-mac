#!/bin/zsh
# Run once by the maintainer who publishes releases, in Terminal: creates the release identity that signs
# every published Yaya's Calendar build (Config/release.sh names it), and writes its designated requirement
# to docs/DR.txt.
#
#   Tools/create-release-identity.sh                 create it in the login keychain
#   Tools/create-release-identity.sh --p12 <file>    … and also write a password-protected backup (.p12) for
#                                                     your password manager (openssl asks for its passphrase)
#
# What it does:
#   1. A self-signed code-signing certificate (RSA 3072, SHA-256, ten years) whose subject is
#      CN=Yayas Calendar Release and nothing else: no email, O, OU, L, ST or C (openssl, not Certificate
#      Assistant, whose defaults can add those). The script checks the subject and issuer before going on.
#   2. Imports the key and certificate into the LOGIN keychain with /usr/bin/codesign on the key's access list.
#   3. Lets Apple's tools (codesign) use that one key without asking: `security set-key-partition-list`
#      limited to keys labelled "Yayas Calendar Release". macOS asks for your LOGIN KEYCHAIN PASSWORD here,
#      in this Terminal, ONCE. That is the only password this setup ever needs; builds never ask again.
#   4. Signs a scratch copy of /bin/echo as the app to prove codesign can use it without a prompt. Only if
#      that fails for want of trust does it add a code-signing trust setting for this one certificate in
#      your user domain (macOS then shows its own authorisation dialog). Normally it is not needed.
#   5. Writes the designated requirement to docs/DR.txt and prints it.
# It never deletes or replaces anything: if the identity exists it only prints its DR (and fills docs/DR.txt
# when that still holds the placeholder). The private key is never written outside a 0700 temporary folder
# that is removed on exit, except into the .p12 you ask for.
#
# Afterwards: commit docs/DR.txt and record where the identity lives (its name and "login keychain", nothing
# secret); check a release build with `./build.sh --release`, then
#   codesign -d --extract-certificates=/tmp/yc-cert "build/Yaya's Calendar.app" && openssl x509 -inform DER \
#     -in /tmp/yc-cert0 -noout -subject      # → subject=CN=Yayas Calendar Release
# Moving to another Mac: `security import <file>.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`,
# then run this script again (it finds the identity and only repeats step 3's partition list if you pass
# --authorize).
set -euo pipefail
YC_ROOT="${0:A:h:h}"; ROOT="$YC_ROOT"
source "$ROOT/Tools/lib/common.zsh"
source "$ROOT/Config/release.sh"

P12_OUT=""; AUTHORIZE_ONLY=0
while (( $# )); do
  case "$1" in
    --p12) (( $# >= 2 )) || yc_fail "--p12 needs a file"; P12_OUT="${2:a}"; shift ;;
    --authorize) AUTHORIZE_ONLY=1 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) yc_fail "unknown option: $1 (see --help)" ;;
  esac
  shift
done
[[ -t 0 && -t 1 ]] || yc_fail "run this in Terminal, at the keyboard: it may ask for your login keychain password once"
[[ -f "$RELEASE_KEYCHAIN" ]] || yc_fail "no login keychain at $RELEASE_KEYCHAIN"
[[ -z "$P12_OUT" || ! -e "$P12_OUT" ]] || yc_fail "$P12_OUT already exists; pick a new file name"
yc_profile release
APP_ID="${YC_PROFILE[bundleId]}"
DR_FILE="$ROOT/docs/DR.txt"

authorize() {
  print -r -- ""
  print -r -- "▸ letting codesign use the \"$RELEASE_IDENTITY\" key without asking."
  print -r -- "  macOS now asks for your LOGIN KEYCHAIN password (the one you log in with), once:"
  security set-key-partition-list -S apple-tool:,apple: -s -l "$RELEASE_IDENTITY" "$RELEASE_KEYCHAIN" >/dev/null \
    || yc_fail "the partition list was not set (wrong password?). Run: Tools/create-release-identity.sh --authorize"
}

# Signs a scratch copy of /bin/echo as the app; prints the designated requirement it gets.
probe_dr() {
  local sha="$1" probe; probe="$(mktemp "${TMPDIR:-/tmp}/yc-release-probe.XXXXXX")"
  cp /bin/echo "$probe"
  if ! codesign --force --timestamp=none --sign "$sha" --keychain "$RELEASE_KEYCHAIN" --identifier "$APP_ID" "$probe" >/dev/null 2>&1; then
    rm -f "$probe"; return 1
  fi
  codesign -d -r- "$probe" 2>&1 | sed -n 's/^designated => //p'
  rm -f "$probe"
}

write_dr() {
  local dr="$1" current; current="$(<"$DR_FILE" 2>/dev/null || true)"
  if [[ "$current" == "identifier "* && "$current" != "$dr" ]]; then
    yc_fail "docs/DR.txt already holds a different release DR; not overwriting it.
    file:     $current
    identity: $dr"
  fi
  print -r -- "$dr" > "$DR_FILE"
}

existing="$(yc_identity_sha1 "$RELEASE_IDENTITY" "$RELEASE_KEYCHAIN")"
if [[ -n "$existing" ]]; then
  print -r -- "▸ \"$RELEASE_IDENTITY\" is already in the login keychain (certificate SHA-1 $existing)."
  (( AUTHORIZE_ONLY )) && authorize
  dr="$(probe_dr "$existing")" || yc_fail "codesign cannot use it without asking. Run: Tools/create-release-identity.sh --authorize"
  write_dr "$dr"
  print -r -- "✓ designated requirement (docs/DR.txt):"
  print -r -- "  $dr"
  exit 0
fi
(( AUTHORIZE_ONLY )) && yc_fail "there is no \"$RELEASE_IDENTITY\" in the login keychain to authorize"

umask 077
WORK="$(mktemp -d "$HOME/Library/Caches/yc-release-identity.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

print -r -- "▸ 1/5 certificate: CN=$RELEASE_IDENTITY only…"
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$RELEASE_IDENTITY" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null || yc_fail "openssl could not make the certificate"
subject="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -subject -nameopt RFC2253 | sed -E 's/^subject= *//')"
issuer="$(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -issuer -nameopt RFC2253 | sed -E 's/^issuer= *//')"
[[ "$subject" == "CN=$RELEASE_IDENTITY" && "$issuer" == "CN=$RELEASE_IDENTITY" ]] \
  || yc_fail "the certificate is not CN-only: $subject / $issuer"
/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -text | grep -qiE 'email|Subject Alternative Name' \
  && yc_fail "the certificate carries an email or alternative name"

print -r -- "▸ 2/5 importing into the login keychain (codesign on the key's access list)…"
transfer="$(/usr/bin/openssl rand -hex 24)"
print -r -- "$transfer" | /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$RELEASE_IDENTITY" \
  -out "$WORK/import.p12" -passout stdin -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  || yc_fail "openssl could not package the identity"
# `security -i` reads the command on stdin: the transfer password never shows in a process list.
print -r -- "import \"$WORK/import.p12\" -k \"$RELEASE_KEYCHAIN\" -P \"$transfer\" -T /usr/bin/codesign" | security -i >/dev/null 2>&1 || true
transfer=""
sha="$(yc_identity_sha1 "$RELEASE_IDENTITY" "$RELEASE_KEYCHAIN")"
[[ -n "$sha" ]] || yc_fail "the import did not land in the login keychain (is it unlocked?)"

print -r -- "▸ 3/5 authorising codesign for this key…"
authorize

print -r -- "▸ 4/5 signing a scratch copy as $APP_ID…"
if ! dr="$(probe_dr "$sha")" || [[ -z "$dr" ]]; then
  print -r -- "  codesign could not use the identity; adding a code-signing trust setting for this certificate only"
  print -r -- "  (user domain; macOS shows its own authorisation dialog)…"
  security add-trusted-cert -r trustRoot -p codeSign -k "$RELEASE_KEYCHAIN" "$WORK/cert.pem" \
    || yc_fail "the trust setting was not added"
  dr="$(probe_dr "$sha")" || yc_fail "codesign still cannot use \"$RELEASE_IDENTITY\""
fi
[[ "$dr" == "identifier \"$APP_ID\" and "* ]] || yc_fail "unexpected designated requirement: $dr"

print -r -- "▸ 5/5 docs/DR.txt…"
write_dr "$dr"

if [[ -n "$P12_OUT" ]]; then
  print -r -- ""
  print -r -- "▸ backup: openssl asks for a passphrase for $P12_OUT (twice). Keep both in your password manager."
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$RELEASE_IDENTITY" \
    -out "$P12_OUT" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 || yc_fail "the backup was not written"
  chmod 600 "$P12_OUT"
fi

print -r -- ""
print -r -- "✓ \"$RELEASE_IDENTITY\" is in the login keychain (certificate SHA-1 $sha); codesign may use it without asking."
print -r -- "  designated requirement, written to docs/DR.txt:"
print -r -- "  $dr"
[[ -n "$P12_OUT" ]] && print -r -- "  backup: $P12_OUT (move it into your password manager, then delete it here)"
print -r -- "  next: commit docs/DR.txt · ./build.sh --release"
