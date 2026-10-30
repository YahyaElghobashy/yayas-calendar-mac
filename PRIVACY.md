# Yaya’s Calendar: Privacy

Yaya’s Calendar is a free, open-source Mac app that shows your Google calendars and Gmail in widgets and
in its own window. It runs on your Mac and talks to Google. There is no Yaya’s Calendar server and no
account with the author. Nothing the app reads goes to the author, or to anyone you didn’t send it to.

This page covers version 1.0.0. Every statement here can be checked in the source; file names are given
where that helps.

## In short

- Your mail and calendars travel between Google and your Mac, and nowhere else.
- You sign in through a Google client you create in your own Google Cloud project. The author never
  sees it, your sign-ins or your data.
- Sign-ins live in your login Keychain. Everything else stays in your Library, in a folder only your
  user account can read.
- No analytics, tracking, ads, crash reporter or update check.
- Two things reach past Google, and both are yours to switch: company logos (on by default) and images
  in mail (blocked until you allow them).
- Settings → **Remove everything and quit** clears the app’s data off your Mac and asks Google to revoke
  its sign-ins.
- With Yaya’s Mail Helper installed, an account’s sign-in goes to it only when you approve handing it over,
  sealed so only your own server can open it ([below](#yayas-mail-helper)).

## Your own Google client

Yaya’s Calendar doesn’t ship a Google sign-in of its own. You create a Desktop OAuth client in your own
Google Cloud project ([docs/GOOGLE-SETUP.md](docs/GOOGLE-SETUP.md)) and drop its file into the app. The
app copies the client ID and secret into your Keychain and offers to move the downloaded file to the
Trash. The ID travels in Google’s sign-in address; the secret goes only to Google’s token endpoint.

What that means:

- The project is yours. Google’s consent screen shows the name you gave it, and Google counts sign-ins,
  quota and API use against your project.
- The author has no access to your project, your client or anything it can reach. There is no server
  where your data could collect.
- You can see and revoke the client’s access at https://myaccount.google.com/permissions. Deleting the
  client or the project in Google Cloud ends its access for every account at once.

**Google’s rules.** Because the client is yours, Google’s API Services User Data Policy, including its
Limited Use requirements, applies to it, with you as its owner. The app is built to keep within those
rules: it uses Google data only to show you your own mail and calendars and to do what you ask, gives
none of it to anyone you didn’t send it to, uses none of it for advertising, and lets no one else read it.
The one hand-off is the optional Deck file described below, which stays on your Mac.

## What the app asks Google for

Google asks for all of these on one consent screen (`Sources/Auth/OAuthProvider.swift`):

| Scope | Why |
|---|---|
| `openid`, `email` | Google tells the app which address you signed in with. |
| `https://www.googleapis.com/auth/gmail.modify` | Read your mail; mark it read or unread; star; archive; move to Trash and back; send. This scope can’t delete mail permanently, and the app asks for none that can. |
| `https://www.googleapis.com/auth/calendar.events` | Read your events and send your reply to an invitation. The scope would allow editing events; the app only changes your own reply. Google then tells the organizer, as Google Calendar does. |
| `https://www.googleapis.com/auth/calendar.calendarlist.readonly` | List your calendars with their names and colours. Read only. |

If you untick a box on the consent screen, the app doesn’t keep that sign-in: it hands it back to Google
(unless the same address is already connected and working) and tells you which permission is missing.

## Which hosts the app contacts

The app’s own connections go to five Google hosts and no others. The list is `HTTP.allowedHosts` in
[`Sources/Net/HTTP.swift`](Sources/Net/HTTP.swift); anything off it is refused before a connection
exists. Every request is HTTPS (TLS 1.2 or later) with no cookies, no cache and no redirects.

| Host | What for |
|---|---|
| `accounts.google.com` | Google’s sign-in and consent page. It opens in your browser; the app itself never connects to it. |
| `oauth2.googleapis.com` | Turning a sign-in into tokens, refreshing them, and revoking them when you remove an account or everything. |
| `gmail.googleapis.com` | The Gmail API: your inbox, messages, labels, attachments, your “From” name, and sending (large messages use Google’s upload path on the same host). |
| `www.googleapis.com` | The Google Calendar API: your calendars, events and replies. |
| `openidconnect.googleapis.com` | On the list, but 1.0 never calls it: your address arrives with the sign-in. |

While you sign in, the app listens on `127.0.0.1` for Google’s redirect (for five minutes at most). That
address is reachable only from your own Mac.

[`Tools/check-sealed.sh`](Tools/check-sealed.sh) fails the build when network code appears anywhere but
the network layer, the logo fetcher, the sign-in listener and a network-change monitor that sends nothing.

Everything else you click opens in your browser (or, for a meeting link, the meeting’s own app), not in
the app: the Google Cloud pages during setup, Google’s permissions page, Gmail or Google Calendar on the
web, join links, links in mail and this repository. Those visits follow that app’s own settings.

### The exception: company logos

When you add an account whose address is on its own domain (never `gmail.com` or `googlemail.com`), the
app looks for that organization’s icon on its website (`Sources/Accounts/LogoFetcher.swift`):

1. `https://<domain>/apple-touch-icon.png`;
2. if that isn’t good enough, the home page `https://<domain>/` and up to four icons it links to;
3. then `https://<domain>/favicon.ico`.

It stops at the first good icon, so this is usually one request and never more than seven, redirects
included. Only `<domain>` and `www.<domain>` are allowed, over HTTPS, with redirects elsewhere refused (and
at most three on the site for one address), no cookies, and at most 512 KB and 8 seconds per request. The site sees an ordinary request from your IP address with the
standard headers macOS adds, which name the app. Nothing about your account is in it. The screen that
confirms the new account names the domain it asked, and the icon is kept as a small PNG in the data folder.

- **Automatic:** when you add an account, or when the app restores one it finds in your Keychain.
  Settings → What leaves this Mac → **Fetch company logos** (on by default) turns this off.
- **When you ask:** **Fetch logo from website** in an account’s menu, or **Find its logo** in the
  welcome guide, asks the same way whenever you choose it, even with the switch off.

### Images in mail

Mail opens in a locked reader: JavaScript off, a web view that keeps no cookies or website data, and every
remote load blocked by both a content rule list and a Content-Security-Policy. Pictures sent inside the
message show. Pictures hosted elsewhere stay hidden until you choose:

- **Load images:** this message, this time.
- **Always for this sender:** that sender from now on. Settings → Mail lists them, and you can remove
  anyone there.
- **Images from people you’ve written to** (Settings → Mail, off by default): senders in conversations you
  replied in, and everyone you send to from the app, per account. Your own addresses never count. While
  it’s on, the app records those addresses in its database from mail it has already fetched; it needs no
  Contacts access and no extra Google permission. While it’s off, nothing is recorded, and turning it off
  deletes every address it recorded, in every account. Turned on again, it starts empty.

Only images load, over HTTP or HTTPS; scripts, fonts, frames and forms stay blocked. A loaded image comes
from wherever the sender keeps it, so the sender, or their mail service, can see your IP address and when
you opened the message.

## Where your data lives

**In your login Keychain** (three services):

- `com.yahyaelghobashy.yayascalendar.oauth`: each account’s Google refresh token, with its address and
  granted scopes;
- `com.yahyaelghobashy.yayascalendar.client`: your Google client ID and secret;
- `com.yahyaelghobashy.yayascalendar.linkkey`: a random key that signs the widgets’ links into the app.

macOS hands these over without asking only to an app with this app’s signature
([SECURITY.md](SECURITY.md)). Access tokens stay in memory and expire within about an hour.

**In the data folder,** `~/Library/Application Support/YayasCalendar/`:

| Path | What |
|---|---|
| `store.sqlite` | Your accounts, calendars, events in the sync window, the inbox list (senders, subjects, snippets), mail settings and signatures, the senders whose images you allowed, mail waiting to send, and the correspondents list when that setting is on |
| `mailcache/` | Message bodies the app has fetched, cleaned of scripts; the least recently read go past 100 MB |
| `attachments/` | Attachments and inline pictures fetched from Gmail, named by a hash, never by the sender’s filename; the least recently opened go past 300 MB (Settings → Mail shows the size, with Clear). Nothing over 50 MB is fetched: those files open in Gmail on the web |
| `Mail Downloads/` | The copy another app gets when you Open an attachment; deleted after 24 hours |
| `compose/` | Copies of files attached to a draft; deleted when the composer closes |
| `outbox/` | Large messages, or messages with files, waiting for Gmail; deleted once sent or cancelled, kept 7 days if sending failed |
| `widget/` | What the widgets draw (meeting titles and times, inbox senders and subjects, with Yaya’s Mail Helper the Daily Digest’s headlines and counts), account logos and the widget’s log |
| `share/` | The Deck file, only while that setting is on; `share/mailhelper/`, the requests for Yaya’s Mail Helper (each deleted by the helper, a leftover after an hour), only while it’s installed |
| `logs/` | The app’s log |

Folders are `0700` and files `0600`, so other user accounts on this Mac can’t read them. Apps you run
yourself can, as with anything in your home folder. The widget extension is sandboxed: it reads only the
`widget/` folder and has no network access.

**Logs** record events, counts, timings and error codes, never titles, subjects, names, addresses or
links. They stay small (512 KB for the app, 256 KB for the widget, one older copy each).

**Elsewhere:** the app’s preferences (`~/Library/Preferences/com.yahyaelghobashy.yayascalendar.plist`:
your settings, a copy of the allowed-sender list and, with Yaya’s Mail Helper, your VIP lists as it last took them and the Draft with AI choices), and folders macOS makes for the app by its bundle id
under `~/Library/Caches`, `~/Library/WebKit` (the reader’s compiled blocking rules),
`~/Library/HTTPStorages` and `~/Library/Saved Application State`.

**Files you save** go where you put them (Downloads by default). Each carries macOS’s quarantine mark for
an email attachment so Gatekeeper still checks it; the mark names this app only, never a sender, address
or link. Apps, scripts, installers, disk images, configuration profiles and web pages ask before they
open, every time.

**Mail you send** goes to Gmail and nowhere else. Files you attach go as they are. Pictures inside the
message or in a signature never go out with their metadata: when you send, the app checks each one for
location, camera, date, comment and text data, takes out what it finds and keeps the pixels, or, if it
can’t, sends a new PNG drawn from the pixels instead. A picture you paste or drop into the message is also redrawn as it goes in: photos as JPEG
at most 2560 pixels on the long side, pictures with transparency as PNG (over 5 MB, or with ⌥ held, it
becomes an attached file instead). The Message-ID of every message the app sends, and the Content-ID it
gives each picture inside, end in `@yayascalendar.local`, so anyone who reads a message’s headers can tell
it was sent from this app.

## Notifications

Notifications are local: the app schedules them with macOS, and no push service is involved.

- **Meeting heads-ups** (on by default): a minute before a meeting, its title, time, meeting service and
  account tags.
- **New mail** (off by default): the account, senders’ first names and the newest subject.
- **Sign-in needed:** when an account has to sign in again.

Quitting withdraws pending heads-ups, and Remove everything removes all of the app’s notifications.
Notification Center keeps delivered ones under your macOS settings.

Notifications are the one macOS permission the app asks for (plus your OK for the login item, if you turn
on Launch at login). It never asks for Contacts, Calendars, Location, the camera or the microphone.

## Sharing meetings with Deck

[Deck](https://github.com/YahyaElghobashy/deck-mac) is a separate meeting-recorder app for the Mac by the
same author. If it’s installed, it can read your upcoming meetings from Yaya’s Calendar to name its
recordings. Settings → What leaves this Mac → **Share upcoming meetings with Deck** controls this. Until
you choose, it’s on only when the Deck app itself is installed: the app that handles `deck:` links must
carry Deck’s own bundle identifier (checked against a stored SHA-256 digest of it). Any other app, whatever
its name, leaves it off. Once you choose, your choice stays.

While it’s on, the app keeps one file, `share/upcoming-meetings.json` in the data folder (`0600`):
meetings from 15 minutes ago to 48 hours ahead (no all-day events and none you declined, 300 at most),
each with its title, start and end, join link, organizer and attendees (names, addresses and replies),
your account tags and whether anyone is outside your own domains, plus your accounts’ email domains. After
each change, the app posts a system notification with no content, telling Deck to read the file again.
The file never leaves your Mac through the app. Turning the setting off deletes it at once
(`Sources/Notify/DeckExport.swift`, [docs/CONTRACTS.md](docs/CONTRACTS.md#deck-export)).

Yaya’s Murmur (below) reads the same file in the same way. While it’s installed, the switch is called **Share
upcoming meetings with Deck and Yaya’s Murmur**, and until you choose it’s on when either app is installed. It is
still one file and one switch.

## Join with Fathom

If [Fathom](https://fathom.video)'s Mac app is installed, meetings can offer **Join with Fathom** (each account card
in Accounts says which Fathom account its meetings record to, and can turn it off). To make sure a meeting records in
the right Fathom account, the app first checks which account Fathom is signed into. It reads two things Fathom keeps
on your Mac, and changes neither:

- `~/Library/Application Support/Fathom/bridge-config.json`, for the signed-in account's address and Fathom user ID;
- the names of Fathom's files in `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` (only names that
  start with `video.fathom.chrome_extension_bridge`), to see that the file above is current.

The address is compared with your links and shown to you; it never leaves your Mac and never goes into a log. When
the accounts match, the app opens Fathom's own `fathom://start-capture` link with the meeting's join link, so the
Fathom app records the meeting under Fathom's terms, and then opens the meeting. Nothing goes to Fathom from Yaya's
Calendar itself: there is no Fathom host on the app's list.

## Yaya’s Murmur

Yaya’s Murmur is a separate notetaker app for the Mac by the same author. Yaya’s Calendar shows its options only
when it’s installed: the app that handles its `yayamurmur:` links must carry Yaya’s Murmur’s own bundle identifier.
Then each account card in Accounts picks how that account’s meetings are recorded (Fathom, Yaya’s Murmur, Ask each
time or Off), and Join gets a menu with every way to join one meeting.

- **What Yaya’s Calendar opens.** Join with Yaya’s Murmur opens a `yayamurmur://join` link carrying only the
  meeting’s local id (the same opaque id as in the shared meetings file) and, if you picked one, Home lab or
  MacBook; then it opens the meeting. The Live Helper switch and Set up… open `yayamurmur://helper` for that id, and
  Open the notes opens `yayamurmur://open`. Yaya’s Murmur handles them on your Mac under its own settings.
- **What it reads.** `share/murmur-marks.json` in Yaya’s Murmur’s data folder (`~/Library/Application
  Support/YayasMurmur/`): for meeting ids, whether a Live Helper is set, whether notes are ready, “me only”, the
  consent level and where it records. The file holds no titles, names, addresses or links. Yaya’s Calendar opens it
  read-only, only if it’s a regular file of yours and at most 256 KB, and shows its contents as badges. It never
  writes Yaya’s Murmur’s files and never puts what it read into a log.
- **What leaves your Mac.** Nothing. Yaya’s Murmur is reached only through those links and the file; there is no
  Yaya’s Murmur host on the app’s list. When it’s not installed, nothing is read and nothing changes.

## Yaya’s Mail Helper

Yaya’s Mail Helper is a separate, private companion app by the same author that sorts mail on its owner’s own server.
Yaya’s Calendar shows its page (Mail helper, in the sidebar) and its Draft with AI button only when it’s installed:
the app that handles its `yayamail:` links must carry Yaya’s Mail Helper’s own bundle identifier. Yaya’s Calendar never
talks to that server; the helper does.

- **What Yaya’s Calendar reads.** Two files the helper keeps in its data folder (`~/Library/Application
  Support/YayasMailHelper/share/state.json` and `digest.json`) and its answers there (`results/`): how sorting is going
  per account, the labels it uses, its suggestions, the emails it was unsure about, what it did, the backlog plan and
  the daily digest (senders, subjects and short summaries of mail that left your inbox). They are opened read-only,
  only if they are regular files of yours and at most 4 MiB, shown as plain text, never written and never put into a
  log. The app deletes each answer once it has read it.
- **What Yaya’s Calendar writes.** Your choices on that page (pause, the AI setting, a Review decision, Undo, Apply, a
  VIP list, your style card, a draft request) as small command files in its own folder
  (`~/Library/Application Support/YayasCalendar/share/mailhelper/`, readable only by you), then a `yayamail://cmd?id=…`
  link that tells the helper to pick one up. The helper deletes each one it reads; anything left over goes after an hour.
- **Handing over a sign-in.** Only when you press **Hand over sign-in** and then approve a card that names the account
  and shows the server key’s fingerprint (check it matches the one the helper shows). Then, and only then, the app
  reads that account’s Google sign-in (its refresh token and your Google client) from your Keychain and seals it with
  that server key, so only your server can open it; the helper carries it but can’t read it. The token appears nowhere
  else: not on screen, not in a log, not in any other file. **Take back the sign-in** asks the server to forget it.
- **Once a day,** for each account you handed over, the addresses of the people in its meetings from the last 60 and
  next 30 days go to the helper (so mail from them stays in your inbox). Nothing goes for an account you didn’t hand over.
- **Draft with AI** sends the helper only which conversation you are answering (its account and Gmail thread id), the
  model and thinking level you picked and what you typed in “What should it say?”. The draft comes back as plain text
  into the composer; nothing is sent until you press Send, with the usual approval card.
- **The Daily Digest widget** draws the digest’s headlines, its counts per section and per mailbox and which sections
  you’ve read. The app copies just that (at most three short lines a mailbox) into the widget’s own file,
  `widget/digest.json`, as it does for the other widgets; the widget reads nothing else of the helper’s.
- **Model Atlas.** If your own Model Atlas report is on this Mac, the Daily Digest widget adds its weekly box. The
  app reads one small file of Model Atlas’s (`~/Library/Application Support/ModelAtlas/share/digest.json`, read-only,
  never logged), copies its few lines into the widget’s file, and on a tap opens that week’s report (a Markdown file in
  your Model Atlas folder) in your usual app. It remembers only which report you last opened.
- **What leaves your Mac from Yaya’s Calendar.** Nothing. There is no helper or server host on the app’s list. When the
  helper isn’t installed, nothing is read, written or changed.

## Diagnostics you can paste

    "/Applications/Yaya's Calendar.app/Contents/MacOS/YayasCalendar" --diagnose

prints one line of JSON and exits, without touching the network. It holds counts and states: per account
(shown as A1, A2, … plus a random ID made on your Mac) the health, calendar, event and mail counts, last
sync times and error codes; per widget the snapshot size, counts, health and a content hash; how many
sends are queued, the schema version, the sync window’s dates, the first weekday and your time zone as a
UTC offset. It holds no titles, subjects, names, addresses, account tags, tokens or time zone name, so
it’s safe to paste into a public issue. Read it before you paste it all the same.

Never attach files from the data folder: they hold your mail, meetings and addresses.

## Removing access, and removing everything

- **One account:** remove it in the app. It asks Google to revoke that sign-in, deletes its Keychain item,
  and drops its cached mail, events, attachments and logo. Your mail and calendars at Google are untouched.
- **At Google:** https://myaccount.google.com/permissions, from any browser, at any time.
- **Everything:** Settings → **Remove everything and quit** (it asks first), or `--purge` in Terminal.
  The app turns off its login item, removes its notifications and the Deck file, asks Google to revoke
  every sign-in (5 seconds at most), deletes its three Keychain services (10 seconds at most; anything
  left is named so you can delete it in Keychain Access), and removes the data folder, its preferences, the
  folders under Caches, WebKit, HTTPStorages and Saved Application State, and the handoff marker
  `--onboarding` leaves for an installer. `--purge --dry-run` lists all of it and removes nothing; it reads
  no Keychain item and uses no network.

Two things stay: the app itself (drag it to the Trash), and the widget extension’s own folder,
`~/Library/Containers/com.yahyaelghobashy.yayascalendar.widget`. macOS guards widget containers: an app
not signed by a registered Apple developer can set off an “access data from other apps” prompt by touching
one, so the app leaves it alone. The extension keeps no sign-ins, mail or calendars there. The last dialog
names the folder, and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#removing-the-app) shows how to
remove it.

## What the app doesn’t do

No analytics, tracking or advertising. No crash reporter, no update check, no third-party SDKs. New versions
are on this repository’s Releases page; the app never looks. If you share Mac analytics with Apple (System
Settings → Privacy & Security → Analytics & Improvements), a crash of this app may be among what macOS sends
Apple. That is Apple’s setting, and none of it reaches the author.

## Children

Yaya’s Calendar isn’t made for children. It collects nothing from anyone, children included. Google
accounts follow Google’s own age rules.

## Changes to this policy

This file lives in the repository, so every change to it is in its history. If a release changes what the
app sends or stores, this file changes in the same release and the release notes say so.

## Contact

Questions and bug reports: https://github.com/YahyaElghobashy/yayas-calendar-mac/issues.
Security problems: report them privately at
https://github.com/YahyaElghobashy/yayas-calendar-mac/security/advisories/new ([SECURITY.md](SECURITY.md)).
There is no email address.
