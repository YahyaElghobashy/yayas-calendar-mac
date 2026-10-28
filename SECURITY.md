# Security

Yaya’s Calendar is a free app with one maintainer. There is no bug bounty and no promised response time,
but every report is read.

## Reporting

Please keep vulnerabilities out of public issues. Open a private report at
<https://github.com/YahyaElghobashy/yayas-calendar-mac/security/advisories/new> with the version from
**Settings → Version**, your macOS version and the steps to reproduce it.

Leave your own data out of the report: no tokens, client secrets, mail, or files from
`~/Library/Application Support/YayasCalendar/`. The redacted `--diagnose` line (see
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#reporting-a-useful-bug)) is fine.

## What matters most

- Anything that makes the app reach a host other than Google’s five (README, “Privacy, precisely”) or
  the account’s own domain for its logo, or send data anywhere else.
- Anything that lets an email run code: script in the mail reader, a remote resource loading without
  your say-so, a file opening without the question the app asks for risky types.
- Reading this app’s Keychain items from another program without a prompt, or the app reading anyone
  else’s.
- A `yayacal://` link that acts without a valid key (widget links are signed, see
  [docs/CONTRACTS.md](docs/CONTRACTS.md#link-keys)).
- Mail leaving for someone outside your own accounts without the “Send to …?” card while it’s switched on.

Problems in Google’s or Apple’s own services are best reported to them.

## How your sign-ins are kept

- **In your login Keychain:** each account’s Google refresh token
  (`com.yahyaelghobashy.yayascalendar.oauth`), your Google OAuth client, ID and secret
  (`….client`), and the 32-byte key that signs widget links (`….linkkey`). macOS gives these to an app
  without asking only when its signature satisfies the designated requirement they were saved with. A
  copy signed by anyone else gets a macOS prompt, not your tokens.
- **In memory only:** access tokens, which Google makes valid for about an hour.
- **Nowhere else.** The data folder (folders 0700, files 0600) holds cached mail and calendars, never a
  token or a secret, and the logs record events, counts, timings and error codes, never titles, names
  or addresses.
- **Revoking:** removing an account in the app revokes its token at Google. Settings → **Remove
  everything and quit** (or `--purge`) revokes every token and deletes the Keychain items, the data
  folder and the preferences. https://myaccount.google.com/permissions works from any browser.

## The release signature

Every release is signed with this app’s own self-signed identity, **Yayas Calendar Release**: a
code-signing certificate whose subject is that name and nothing else. It signs Yaya’s Calendar and
nothing else. It isn’t an Apple Developer ID, so the app isn’t notarized and Gatekeeper asks once per
downloaded version (Open Anyway).

The designated requirement, what macOS checks before it hands the app its Keychain items, is in
[`docs/DR.txt`](docs/DR.txt). It has this shape:

    identifier "com.yahyaelghobashy.yayascalendar" and certificate root = H"<SHA-1 of the release certificate>"

Every release carries the same one, which is why updates keep your sign-ins without a prompt.

### Verify a download

1. **The checksum.** Download `Yayas-Calendar-macOS-arm64.zip` and `SHA256SUMS` from the same release
   into one folder, then:

       shasum -a 256 -c SHA256SUMS

   It must say `Yayas-Calendar-macOS-arm64.zip: OK`. (Or run `shasum -a 256` on the zip and compare the
   hash by eye with `SHA256SUMS` and the release notes.)

2. **The signature.** Unzip it, then:

       codesign --verify --deep --strict --verbose=2 "Yaya's Calendar.app"
       codesign -dvv "Yaya's Calendar.app" 2>&1 | grep '^Authority='
       codesign -d -r- "Yaya's Calendar.app" 2>&1 | sed -n 's/^designated => //p'

   The first says the app and its widget extension are intact and signed. The second prints
   `Authority=Yayas Calendar Release`. The third prints the designated requirement, which must equal
   [`docs/DR.txt`](docs/DR.txt) at that release’s tag (for 1.0.0:
   <https://github.com/YahyaElghobashy/yayas-calendar-mac/blob/v1.0.0/docs/DR.txt>), character for
   character.

3. **What a mismatch means.** A copy with a different requirement wasn’t signed by this project’s release
   identity, whatever its name and icon say. Don’t give it your Google sign-ins, and please report where
   you found it.

`spctl --assess` reports such an app as rejected. That’s Gatekeeper saying it isn’t notarized, which is
expected here; the checks above are the ones that tell you it’s genuine.

## Builds you make yourself

`Tools/setup-signing.sh` creates a signing identity that belongs to your Mac alone (its own keychain,
whose random password stays in your login keychain), so your own builds keep their Keychain items across
rebuilds. Its requirement differs from the release’s, so switching between a downloaded copy and your own
build makes macOS ask once per Keychain item. `./build.sh --dev` builds a separate app with its own
identifiers and Keychain names, ad-hoc signed, that never touches the real app’s items.

## Known limits

- **A self-signed identity is only as safe as its private key.** Whoever holds a key can sign an app with
  the same requirement, and macOS would hand that app the Keychain items. The release key lives on the
  maintainer’s Mac and signs nothing but this app. Developer ID with notarization, which anchors the
  requirement to Apple, is the planned next step.
- **Your own signing identity can be used without asking.** `Tools/setup-signing.sh` lets `codesign` use
  your local key without a prompt, so a program already running as you could sign itself as Yaya’s
  Calendar and read the app’s Keychain items silently. Something running as you can already do a lot of
  damage, but this is one more thing it could do.
- **Other apps running as you can read your files.** That includes the data folder and the Deck export
  (`share/upcoming-meetings.json`, only while the Deck switch is on). macOS doesn’t keep your own
  programs out of your own home folder.
