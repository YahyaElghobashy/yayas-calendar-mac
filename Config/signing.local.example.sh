# Config/signing.local.sh (gitignored) tells plain ./build.sh and --install which identity signs the app.
# Tools/setup-signing.sh creates a per-Mac identity and writes that file for you; copy this one only to
# point at an identity you already have. The expected designated requirement is derived from it on every
# build. Names only: never put a password here.
SIGN_IDENTITY="Yayas Calendar Local Signing"
# The keychain that holds it (leave empty for one already on your keychain search list).
SIGN_KEYCHAIN="$HOME/Library/Keychains/yayascalendar-signing.keychain-db"
# The login-keychain item that holds that keychain's password (build.sh unlocks through `security -i`).
SIGN_KEYCHAIN_PASSWORD_SERVICE="Yayas Calendar signing keychain"
