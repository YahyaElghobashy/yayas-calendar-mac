# Contributing to Yaya’s Calendar

Thanks for looking. Bug fixes are welcome any time. For a new feature, open an issue first: direction is
the most common reason a change gets turned down, and that is far cheaper to settle before the code
exists. Small pull requests get reviewed fastest.

## Build and check

You need an Apple silicon Mac on macOS 26 or later and the Command Line Tools with the macOS 27 SDK
(`xcrun --show-sdk-version` says 27 or later). No Xcode.

```sh
./build.sh --dev --test                 # the dev app (ad-hoc, its own ids and data folder) and every test suite
Tools/check-sealed.sh                   # network code and hosts only where they are allowed
Tools/check-sealed.sh "build/Yaya's Calendar Dev.app"
Tools/check-secrets.sh                  # no secret shapes in the tree
Tools/check-public.sh --tree .          # no personal paths, real addresses, meeting links or time zones
```

**Signing.** `Tools/setup-signing.sh` makes this Mac’s own signing identity and writes
`Config/signing.local.sh` with the names in [`Config/signing.local.example.sh`](Config/signing.local.example.sh).
An older local file that calls them `<PREFIX>_IDENTITY`, `<PREFIX>_KC` and `<PREFIX>_KC_PASSWORD` still
builds; rename them to `SIGN_IDENTITY`, `SIGN_KEYCHAIN` and `SIGN_KEYCHAIN_PASSWORD`.

To sign in from a dev build without the setup guide, put your own Desktop OAuth client in
`Config/oauth.local.json`, shaped like [`Config/oauth.local.example.json`](Config/oauth.local.example.json).
Git ignores `Config/*.local.*`. A `--dev` build run from inside the checkout (or with `YAYACAL_DEV_OAUTH`
naming the file or a folder above it) offers **Import from developer file** in Provider Setup, which copies
the client into the dev profile’s Keychain item; the app never reads the file after that, and release
builds never look for it.

The tests are plain `swiftc` binaries (XCTest isn’t in the Command Line Tools), run by
`Tests/run-tests.sh` plus every `Tests/*/run.sh`. A change to a layout needs its renders looked at:
`./build.sh --render <folder>` writes every widget, state and window as PNGs from the sample data.

## Rules for changes

- **The network.** Every request goes through `Sources/Net/HTTP.swift` to a host in `HTTP.allowedHosts`.
  The only other network code is the logo fetcher, the loopback sign-in listener and a network-change
  monitor. A new host or a new network call is a reviewed edit of `Tools/check-sealed.sh` and a new entry
  in `docs/DECISIONS.md`, never a quiet addition.
- **The mail reader stays locked.** Content JavaScript off, remote content blocked unless the person
  allows it, every HTML body through the sanitizer.
- **Contracts.** Widget kinds, the snapshot format, `yayacal://` routes, link keys and the Keychain layout
  are in `docs/CONTRACTS.md`. Placed widgets and saved sign-ins depend on them, so they change only with a
  `docs/DECISIONS.md` entry. The identifiers live in one table, `Sources/Shared/Profile.swift`; never
  change the bundle ids (D-001).
- **Sample data is fictional.** Fixtures, tests, renders and screenshots use the Moonfield desk (D-028):
  Orbital Pickle Co., The Quiet Comets, Moonfield Family and Personal, with addresses on `.example`
  domains. Never your own mail, calendars, names or desktop.
- **Images.** Re-encode anything you commit with `Tools/make-icons.sh --strip <in> <out.png>` and check it
  with `Tools/check-public.sh --images <file>`.
- **Developer tools stay out of release builds.** Renders, benchmarks, the self-test and test doubles
  compile only with `-D YC_DEV_TOOLS` (D-035).
- **Words.** The app speaks as “I” and calls the person “you”. A joke belongs in an empty state or a
  welcome, never in an error, a sign-in step, sending or deleting. [brand/BRAND.md](brand/BRAND.md) has
  the name, the colours and the mark.
- **Decisions.** Anything that changes behaviour people rely on gets a line in `docs/DECISIONS.md`, with
  the next free D-number, saying what and why. Code comments cite those ids.

## Pull requests

- One change per pull request, with what you ran and what you couldn’t test (your Mac, your macOS
  version). The template asks for it.
- Write commit messages as plain sentences about the change.
- If an issue exists, reference it as `Refs #N`.

By contributing you agree that your work is released under the [MIT License](LICENSE) like the rest of
the project.
