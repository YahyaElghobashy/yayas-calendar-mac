# Changelog

All notable changes to Yaya’s Calendar. Versions follow the app’s `CFBundleShortVersionString`
(`version.json`); build numbers are `YYYYMMDD.N`, the UTC date and a counter.

## Unreleased

- **Live Helper in the menu-bar popover.** With Yaya’s Murmur on your Mac, the next-meeting card shows ✦ Join with
  Live Helper for a meeting Yaya’s Murmur marked Live Helper, in place of the recorder’s button: the call opens with
  Yaya’s Murmur listening and that meeting’s chat beside it. The ▾ beside Join offers it too, and still every recorder.
  A meeting without one gets a small ✦ Live Helper button that sets it up in Yaya’s Murmur. The card follows as soon
  as Yaya’s Murmur changes a mark. Without Yaya’s Murmur, nothing changes (D-049).
- **Mail helper.** With Yaya’s Mail Helper, a private companion that sorts mail on its owner’s own server, a Mail
  helper page appears in the sidebar: each account’s sorting (pause, AI setting, VIPs, your writing style), the inbox
  clean-up plan with Apply and Undo all, emails to review, Needs reply, suggestions and every change with Undo, plus a
  daily Digest where reading a section to its end marks its mail read. Priority mail sorts first in the inbox with a ⭐,
  and replies get Draft with AI. Handing over an account’s sign-in takes an approval card and is sealed for your own
  server. Yaya’s Calendar talks to nothing new: it reads the helper’s files and leaves it small command files
  (PRIVACY.md, D-050). Without the helper, nothing changes.
- **Join with Live Helper on the widget.** When Yaya’s Murmur has a meeting marked Live Helper, Up Next (Medium)
  swaps its round recorder button for a ✦ Join with Live Helper button: it opens the call with Yaya’s Murmur recording
  and that meeting’s Live Helper chat attached, whichever recorder the account normally uses (D-048).
- **Widgets on a dimmed desktop.** With another app in front, macOS draws widgets in its accented or vibrant style;
  they now use a glass palette there instead of blank frosted panels (D-047).
- **Join with Fathom.** With Fathom’s Mac app installed, the popover, the Event Peek, Up Next (Medium) and the
  heads-up offer Join with Fathom next to Join. Each account card in Accounts says which Fathom account that
  account’s meetings record to (its own address by default, another address, or off). Before recording, the app
  checks which account Fathom is signed into. When it’s another one, nothing records: the app asks you to switch
  Fathom and records by itself once you do. Settings → Fathom can make ⌃⌥J record too. The checks read two small
  files Fathom keeps on your Mac and send nothing anywhere (PRIVACY.md, D-045).
- **Yaya’s Murmur.** With Yaya’s Murmur, the bot-free notetaker, on your Mac, each account card says how that
  account’s meetings are recorded: Fathom, Yaya’s Murmur, Ask each time or Off (accounts linked to Fathom keep Fathom;
  the rest start on Yaya’s Murmur). Join gets a ▾ with Join with Fathom, Join with Yaya’s Murmur ▸ Home lab /
  MacBook, and Just join; Up Next, the heads-up and ⌃⌥J (when its switch is on) follow the account’s choice. The
  Event Peek has a Live Helper switch, and meetings show Yaya’s Murmur’s badges (Live Helper, Notes ready, Me only,
  Explicit consent). The meeting-sharing switch becomes “Share upcoming meetings with Deck and Yaya’s Murmur”. The app
  reads one small file Yaya’s Murmur keeps on your Mac and sends nothing anywhere. Without Yaya’s Murmur, nothing
  changes (PRIVACY.md, D-046).

## 1.0.0 · 2026-10-28

The first release: Gmail and Google Calendar from every Google account you connect, in one menu-bar app
with desktop widgets.

- **Twelve widgets.** Agenda, Day, Up Next, Month, Inbox, Agenda & Inbox and Custom A to F, from Small to
  Extra Large, plus Extra Large Portrait on macOS 27. Each picks Light or Dark, a font, a text size and
  its calendars in the app’s Widgets page.
- **Day.** One day as an hour grid, overlapping meetings side by side, a teal line for now, arrows to
  flip days.
- **Month.** Tap a day to see its meetings beside or under the grid.
- **Up Next and Join.** A countdown and a Join button; **⌃⌥J** joins the next meeting from anywhere; a
  heads-up notification a minute before, with Join on it.
- **↻ on every widget.** Re-reads that widget’s calendars on the spot and shows ✓ when it’s done.
- **One inbox.** A unified inbox in the app and on the desktop: read, mark read, star, archive and trash,
  with Undo for 30 seconds from the widget and keyboard shortcuts in the app.
- **Rich mail.** HTML mail on a white sheet as its sender designed it, JavaScript off and remote images
  blocked until you allow them; quoted history folded away; the real destination of a link on hover.
- **A formatting composer.** Fonts, sizes, bold, italic, underline, strikethrough, colour, lists,
  indents, quotes and links; rich signatures per account; Make Plain Text; Paste and Match Style; 5
  seconds to undo a send.
- **Attachments.** Quick Look, Open, Save, Save All and drag to Finder; files up to Gmail’s 25 MB per
  message; risky file types ask before they open, every time, and every saved file carries macOS’s
  quarantine mark.
- **Forward**, with the original’s files attached again.
- **Ask before sending to other people.** A card lists everyone outside your own accounts before the
  message leaves, Cc and Bcc marked. On by default; Settings → Mail switches it off.
- **The menu bar.** A countdown title and a popover with today’s agenda and your inbox.
- **Your own Google sign-in, guided.** A six-step guide with links to the right Google Cloud pages,
  **Check my setup**, and plain fixes for the errors a fresh project produces.
- **What leaves this Mac,** in Settings: the two things that reach past Google, company logos (with
  their switch) and images in mail (blocked until you allow them), and the Deck export, which stays on this
  Mac.
- **Remove everything and quit.** Revokes the Google sign-ins and deletes the Keychain items, the data
  folder and the preferences (`--purge`; `--purge --dry-run` lists it first).
- **Google only on the network.** Five Google hosts and nothing else (plus each account’s own domain for
  its logo, fetched by itself unless you switch that off); `Tools/check-sealed.sh` holds the build to it.
- **Builds without Xcode.** `./build.sh --dev` for a quick look, `Tools/setup-signing.sh` and
  `./build.sh --install` for your own signed build.
