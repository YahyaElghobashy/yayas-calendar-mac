# The release identity (D-030). Sourced by build.sh --release and Tools/create-release-identity.sh.
# A self-signed code-signing certificate whose subject is this common name and nothing else, kept in the
# login keychain with codesign allowed to use its key without asking. docs/DR.txt holds its designated
# requirement, which every shipped build must match.
RELEASE_IDENTITY="Yayas Calendar Release"
RELEASE_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
