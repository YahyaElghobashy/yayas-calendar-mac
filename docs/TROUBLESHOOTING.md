# Troubleshooting

The usual fixes, roughly in the order people meet them. Still stuck? [Reporting a useful
bug](#reporting-a-useful-bug) is at the end.

## Installing and opening

**“Apple could not verify Yaya’s Calendar is free of malware.”** Expected: the app is signed with its own
certificate, not an Apple Developer ID, so it isn’t notarized. Open **System Settings → Privacy &
Security**, scroll down to the message about Yaya’s Calendar, click **Open Anyway**, then **Open**. Each
newly downloaded version asks once. (Control-click → Open no longer skips this on current macOS.) To make
sure the download is the real one, see “Check the download” in the [README](../README.md#check-the-download).

**Move it to Applications first.** Opened straight from Downloads, macOS runs the app from a temporary,
read-only copy (App Translocation). Widgets, the `yayacal://` links and the login item can then point at
a copy that disappears. Quit it, drag **Yaya’s Calendar** into **Applications**, and open it from there.
The welcome guide’s **Keep me running** step offers to move it for you.

**The widgets aren’t in the gallery.** Open the app once from Applications, then right-click the desktop
→ **Edit Widgets** and search **Yaya**. If they still don’t show, quit the app, open it again, and give
macOS a minute to register the widget extension.

## Widgets

**The widgets look grey.** That’s macOS’s **Automatic** widget style: it drains the colour from desktop
widgets whenever an app window is in front. **System Settings → Desktop & Dock → Widgets → Widget
style → Full colour** keeps them in colour. (Even in Full colour, macOS lowers the contrast a little
while a window is active.) Nothing in the widgets depends on colour alone: every row also has its
account’s logo or tag.

**Blank widgets, or the old version, after an update.** macOS’s widget host (`chronod`) can keep the
previous version of the extension running. Quit Yaya’s Calendar, then in Terminal:

    killall chronod

macOS restarts it at once, and the widgets redraw from the new version. Open the app again so they have
fresh data.

**A cancelled meeting is still there.** Tap **↻** on the widget: that widget re-reads its calendars now
instead of at the next 15-minute sync, and shows ✓ when it’s done.

**“Last synced …” on a widget.** The app hasn’t been able to sync for a while: it was quit, the Mac was
asleep or offline, or an account needs you. Open the app; the Accounts page says which account, if any.
The app has to be running for widgets to update, so let it start at login (Settings → Launch at login).

**Tapping a widget does nothing.** Widget taps are `yayacal://` links handled by the running app. Check
that it’s running (its icon is in the menu bar) and that only one copy is installed: an old copy left in
Downloads or another folder can claim the links. Delete the stray copy, then open the one in
Applications.

## Google sign-in

The step-by-step setup, and a table of the errors a fresh Google project produces, is in
[GOOGLE-SETUP.md](GOOGLE-SETUP.md). The short versions:

**“Turn on the Gmail API” (or the Google Calendar API) on an account.** That API is switched off in your
Google Cloud project. Click **Turn it on** on the account card (or open
https://console.cloud.google.com/apis/library, pick your project, find the API and click **Enable**), then
**Sync now**. **Accounts → Sign-in setup → Check my setup** tests both APIs with one of your accounts.

**“Google didn’t let me in” when you add an account.** Usually your Google app is still in *Testing* and
the account isn’t one of its test users. Open **Audience** (https://console.developers.google.com/auth/audience)
and click **Publish app**, or add the account under **Test users**. A work account may also need its
Workspace admin to allow your client ID; the app shows the steps and a **Copy client ID** button.

**Signed out about a week after you connected.** Google ends sign-ins from apps in *Testing* 7 days after
you approved them. Publish the app (Audience → **Publish app**), then sign in again once.

**“Google signed this account out. Sign in again to reconnect.”** Google ended that sign-in: you changed
the account’s password, revoked the app at https://myaccount.google.com/permissions, the app was in
*Testing* (above), or the account sat unused for a long time. Click **Sign in again** on the account card;
the account keeps its colour, logo and widgets.

**“Blocked by your admin.”** Your Google Workspace admin only lets in apps they trust. The account card
shows what to send them: **Copy client ID** (or **Copy message** for the whole note). They open
admin.google.com → Security → Access and data control → API controls → Manage Third-Party App Access →
Add app → OAuth App Name Or Client ID, paste the ID, select Yaya’s Calendar and set it to **Trusted**.
Then try again. The client ID isn’t a secret; the client secret stays in your Keychain.

**“This file has no client secret.”** Google shows a client’s secret only once, in the dialog right after
**Create**. Open **Clients** (https://console.developers.google.com/auth/clients), open your client, add a
new secret and download the JSON again, or make a new Desktop client.

**“Your Google client is gone.”** Google deletes OAuth clients that go unused for 6 months. Make a new
Desktop client (Clients → **Create client** → **Desktop app** → **Create** → **Download JSON**) and drop it
on **Accounts → Sign-in setup**, then sign in to each account again.

## Keychain

**“Waiting for Keychain access” or a macOS dialog asking to use your Keychain.** macOS lets the app read
its saved sign-ins without asking only while the app’s signature matches the one that saved them. After a
switch between a downloaded copy and one you built yourself (or the first launch of a copy signed
differently), macOS asks once per item: your Google client, each account and the widget-link key. Click
**Always Allow** each time. The app never waits on the dialog: it shows “Waiting for Keychain access” and
carries on once you answer.

**“Your Keychain is locked.”** The Mac is locked or just woke up. The app retries on its own after you
unlock.

## Mail

**Pictures in an email don’t show.** Remote images are blocked until you ask, because loading them tells
the sender you opened the message. Load them for that message, or allow that sender. Settings → Mail also
has “Images from people you’ve written to”, off by default.

**An attachment asks before it opens.** Apps, installers, scripts, disk images, configuration profiles
and web pages ask every time, on purpose: a mailed program shouldn’t run without you noticing. Files over
50 MB aren’t downloaded by the app; they open in Gmail on the web.

**Send was refused: too big.** Gmail’s limit is 25 MB for the whole encoded message, which is about a
third more than the files themselves. The composer warns over 10 MB and stops at 25 MB. Share big files
as a link instead.

## Removing the app

**One folder stays after “Remove everything and quit”.** Settings → **Remove everything and quit** (and
`--purge`) deletes the sign-ins, Keychain items, data folder, preferences and caches, but leaves the
widget’s own folder:

    ~/Library/Containers/com.yahyaelghobashy.yayascalendar.widget

macOS guards every widget’s container: an app that isn’t signed by a registered developer can trigger a
“wants to access data from other apps” prompt when it touches one, so the app doesn’t. It holds only what
the widget extension keeps for itself (no sign-ins, mail or calendars). To remove it: take the Yaya’s
Calendar widgets off your desktop, quit the app, then drag that folder to the Trash in Finder
(**Go → Go to Folder…**, paste the path). The final dialog has a **Show in Finder** button for it.

**See what would be removed first.** In Terminal:

    "/Applications/Yaya's Calendar.app/Contents/MacOS/YayasCalendar" --purge --dry-run

prints every path and Keychain service name it would remove and removes nothing.

**“Some Keychain items are still there.”** macOS asked about an item, or answering took longer than 10
seconds. Open **Keychain Access**, search for `yayascalendar` and delete what it finds.

## Reporting a useful bug

Open an issue at https://github.com/YahyaElghobashy/yayas-calendar-mac/issues/new/choose with:

- the version from **Settings → Version** (for example “Yaya’s Calendar 1.0.0 (build …)”);
- your macOS version, and whether you downloaded the app, built it yourself or installed it another way;
- what you did, what you expected and what happened instead;
- the diagnostics line. In Terminal:

      "/Applications/Yaya's Calendar.app/Contents/MacOS/YayasCalendar" --diagnose

  It prints one line of counts, sync health and error codes, without touching the network. Each account
  appears as A1, A2, … plus a random ID made on your Mac, and the time zone as a UTC offset. It holds no
  titles, subjects, names, addresses, account tags or tokens, so it’s safe to paste into a public issue.
  Read it before you paste it all the same.

Never attach files from `~/Library/Application Support/YayasCalendar/`: `widget/*.json`, `store.sqlite`,
`mailcache/` and `attachments/` hold your meetings, mail and addresses. The logs hold none of that (they
record events, counts, timings and error codes, never titles, subjects, names, addresses or links); the
diagnostics line covers what a report needs. Crop screenshots to what the bug needs. Security problems
go to a private report instead ([SECURITY.md](../SECURITY.md)).
