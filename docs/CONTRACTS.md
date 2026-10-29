# Contracts (change only with a DECISIONS entry)

## Identifiers
Bundle `com.yahyaelghobashy.yayascalendar` (executable `YayasCalendar`, app name "Yaya's Calendar"),
widget `com.yahyaelghobashy.yayascalendar.widget` (executable `YayasCalendarWidget`, appex
`PlugIns/YayasCalendarWidget.appex`), URL scheme `yayacal`, LSMinimumSystemVersion 26.0, arm64.
One table holds these names, the data folder and the Keychain services below, and the names of Yaya's Murmur (its
bundle id, URL scheme and data folder, D-046) and of Yaya's Mail Helper (the same three, D-050): `Sources/Shared/Profile.swift`.
`./build.sh --dev` builds a separate dev profile from the same table (`….dev` ids, "Yaya's Calendar Dev",
`yayacal-dev`, `YayasCalendarDev`, `….dev.*` services; Murmur's `….yayasmurmur.dev`, `yayamurmur-dev`,
`YayasMurmurDev`; the Mail helper's `….yayasmailhelper.dev`, `yayamail-dev`, `YayasMailHelperDev`), ad-hoc signed, that
never touches these names. Every
other build is signed with a stable identity, never ad-hoc (D-030); its expected designated requirement is
derived from that identity, and the release identity's is `docs/DR.txt`.

## Paths (`Sources/Shared/Paths.swift`)
`~/Library/Application Support/YayasCalendar/` (0700): `store.sqlite`, `widget/` (snapshots, `logos/`,
`trace.log`; the widget's only sandbox exception), `share/` (Deck export; `share/mailhelper/`, Yaya's Mail Helper's
command files, D-050), `logs/app.log`.

## Keychain (file-based login keychain, every query `kSecUseAuthenticationUIFail`)
`com.yahyaelghobashy.yayascalendar.oauth` (account = account UUID, refresh token JSON),
`com.yahyaelghobashy.yayascalendar.client` (account = `google` | `microsoft`, client config),
`com.yahyaelghobashy.yayascalendar.linkkey` (HMAC key for widget links). Never call
`SecKeychainSetUserInteractionAllowed`. Measured on macOS 27 (item written by build A, read by rebuilds B
and C signed with the same identity; hardened runtime makes no difference):

| Read options | Same build | After rebuild |
|---|---|---|
| `kSecUseAuthenticationUIFail` only | 0 | **0** |
| + `kSecMatchSearchList` [login keychain] | 0 | **0** |
| + `SecKeychainSetUserInteractionAllowed(false)` | 0 | **-25293** (`errSecAuthFailed`) |
| `SecKeychainSetUserInteractionAllowed(false)` only | 0 | **-25293** |

## Widget kinds (StaticConfiguration only; placed kinds are a public contract)
| Kind | Gallery name | Families |
|---|---|---|
| `agenda.all` | Agenda | S M L XL XLP |
| `day` | Day | S M L XL XLP (D-022) |
| `upnext` | Up Next | S M |
| `month` | Month | S M L XL XLP |
| `inbox.all` | Inbox | M L XL XLP |
| `combo.all` | Agenda & Inbox | L XL XLP |
| `custom.a` … `custom.f` | Custom Widget A … F | S M L XL XLP |
XLP = `.systemExtraLargePortrait`, behind `#available(macOS 27, *)`.

## Widget snapshot — `widget/<kind>.json` (frozen seam, D-014)
Type: `WidgetSnapshot` in `Sources/Shared/Snapshot.swift` (version 1). The data layer writes it, the
UI layer reads it. Content: agenda | upNext | month | inbox | combo | day | setup | mailComingSoon (`day`: D-022).
Carries style (look auto/paper/ink, typeface, text size, logos, 24 h), accounts (id, tag, name, colour,
hasLogo → `widget/logos/<id>.png`), health (ok/noAccounts/stale/reauth + syncedAt), meetings (r, k,
accountIds, title, start, end, allDay, place, hasJoin, reply, clashes, rec: optional, D-045; recBy: optional, D-046), mail (r, k, accountId, sender,
subject, at, unread, starred), unreadCount, pages per family + pageResetAt, selectedDay, monthShown,
busyDays, windowStart/End, rangeDays. Day reuses `selectedDay` (nil = today; ‹ › send `day?w&d`). **No time-relative text**; atomic write only when `contentHash`
(FNV-1a over sorted JSON, `generatedAt` excluded) changes; caps 120 meetings / 96 mail / 192 KB.

## Link keys
`k` = base64url (no padding) of the first 12 bytes of HMAC-SHA256(linkkey, r); linkkey = 32 random
bytes in Keychain service `….linkkey`. One key per row id, valid for every route on that row.
`WidgetInteractions.verify(r:k:)` checks it in constant time; failures are ignored and traced.

## App seam (`Sources/Contracts/Stores.swift`)
`CalendarStore`, `CalendarActions`, `MailStore`, `MailActions`, `WidgetSettingsStore`,
`WidgetInteractions`, `MailPreferencesStore`, reached only via `Services.*` (empty implementations until the data layer
installs real ones). Mail is on, with no labs gate (D-029); each account's mail toggle stays. `Labs.safeSend` (UserDefaults `mail.askBeforeSendingOutside`, default ON; Settings → Mail "Ask before sending to other people") makes every send to an address outside the user's connected accounts need the user's approval in the composer (D-023). `MailSettingsMigration` runs once at launch: an old `labs.safeSend` is copied to the new key and deleted (absent → nothing written, the switch reads ON), and the old `labs.mail` key is deleted; a second launch changes nothing.
Ownership: data layer = Sources/Store, Sources/Sync, Sources/Providers, Sources/Publish (+ migrations
v2 calendars/events, v3 widget settings/state, v4 mail threads/actions, v5 action queue, v6 rich mail — numbered now,
written by the data layer only). UI layer = Sources/Widget, Sources/Shared/Widgets, Sources/UI,
Sources/App, Sources/Contracts/Fixtures.swift. Shared/Snapshot.swift + Contracts/Stores.swift change only
with a DECISIONS entry. `MailThread.labels` (D-050): the thread's Gmail label ids, from the stored `labels_json`; `[]` by default.

## URL routes (`yayacal://`) — quiet routes hide the agent within 250 ms
| Route | Params | Quiet |
|---|---|---|
| `ping` | `probe` | yes |
| `open/app` | `section` (`inbox`, `mailhelper` while Yaya's Mail Helper is installed, `calendar`, `widgets`, `accounts`, `settings`) | no |
| `page` | `w` (kind), `fam`, `to` | yes |
| `day` | `w`, `d` (YYYY-MM-DD) | yes |
| `month` | `w`, `to` (YYYY-MM) | yes |
| `range` | `w`, `v` (1/2/7) | yes |
| `sync` | `w` (kind, optional; D-021) | yes |
| `join` | `r`, `k` | yes |
| `record` | `r`, `k` (Join with Fathom, D-045; the meeting's recorder while Yaya's Murmur is installed, D-046) | yes |
| `livehelper` | `r`, `k` (Join with Live Helper: Yaya's Murmur for a meeting marked Live Helper, D-048) | yes |
| `rsvp` | `r`, `k`, `v` | yes |
| `mail/read`, `mail/archive`, `mail/undo`, `mail/star` | `r`, `k` | yes |
| `open/event`, `open/message` | `r`, `k` | no |
| `open/day` | `w`, `d` (YYYY-MM-DD); Small Month → Day Peek | no |
| `reauth` | `a`, `k` | no |
`r` = stable local row id, `k` = HMAC-SHA256(linkkey, route|r|…) first 12 bytes base64url. No PII or
URLs in links. `sync` alone syncs every account; `sync?w=<kind>` is a widget's ↻ (D-021): a forced
full window re-list of that widget's calendar accounts plus an incremental mail pass for Inbox kinds,
then that kind republished and reloaded while the agent is active; repeats for the same kind within
5 s are ignored and traced; an unknown kind is ignored (`bad-kind`).

## Installer flags
For installers and scripts that set the app up or remove it.
`--permissions-json` → one stdout line `{"app":"yayascalendar","loginItem":bool,"notifications":"granted|denied|undetermined"}`,
`.prohibited` activation, no Keychain/network/UI, < 1 s, exit 0. `--login-item on|off` → SMAppService
then continue launching. `--onboarding` → onboarding sheet; "Let's go" writes the handoff marker
`yayascalendar.done` into the handoff folder named in `Sources/Shared/Profile.swift`, which an installer can
wait for (opened from Settings, the guide writes nothing). `--uninstall` → drop login item,
exit. `--uninstall --purge` (or `--purge`) → revoke Google tokens (5 s budget), delete this app's Keychain
items (10 s budget through the Keychain gate; leftovers reported), the data folder, preferences, WebKit /
cache / HTTP storage folders and the handoff marker, exit; the last line reports counts and what was left.
`--purge --dry-run` → print the paths and Keychain service names it would remove (never a value), exit.
Settings → "Remove everything and quit" runs the same removal (`Uninstaller.swift`). The widget's sandbox
container stays (docs/TROUBLESHOOTING.md).
Dev: `--selftest`, `--render <dir>`.

## Join with Fathom (D-045)
- **Preferences** (UserDefaults): `fathom.link.<account UUID>`: absent = the account's own address, `"off"`, or
  `"addr:<address>"` (lowercased); `fathom.hotkeyRecords` (Bool, default off): ⌃⌥J records with Fathom.
- **Read, never written or sent:** `~/Library/Application Support/Fathom/bridge-config.json` (`account.userId`,
  `account.email`; a regular file, at most 64 KB) and the file names in
  `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` that start with
  `video.fathom.chrome_extension_bridge` (`….<userId>.json` must exist). Both are Fathom's and undocumented: anything
  else reads as "can't tell", and the app asks before recording.
- **Opened:** `fathom://start-capture?url=<the meeting's allowlisted join link, percent-encoded>`, then the meeting
  itself 0.6 s later; `fathom://open-app` (Open Fathom). Fathom's Mac app is found by its bundle identifier
  `video.fathom.electron`.
- **Snapshot:** `Meeting.rec` (`true` or left out): one of the meeting's accounts records with Fathom and the meeting has a
  join link; Up Next Medium then shows Fathom beside Join (`record?r&k`). Version stays 1.
- **Notifications:** category `yc.meeting.fathom` (actions `yc.join`, `yc.join.fathom`, `yc.snooze`) for heads-ups of such
  meetings.

## Yaya's Murmur link (D-046)
Yaya's Murmur is a separate notetaker app on the same Mac. The two apps share no code, Keychain item or network:
each writes one file in its own data folder and pings after each write; each reads the other's file and treats a
missing or invalid one as "no data". Murmur's side: its own docs/CONTRACTS.md, "Calendar link".

| | Release profile | Dev profile |
|---|---|---|
| Installed when | a handler of `yayamurmur:` has bundle id `com.yahyaelghobashy.yayasmurmur` | `yayamurmur-dev:`, `….yayasmurmur.dev` |
| Marks (read only) | `~/Library/Application Support/YayasMurmur/share/murmur-marks.json` | `…/YayasMurmurDev/share/murmur-marks.json` |
| Marks ping (observed) | `com.yahyaelghobashy.yayasmurmur.marksChanged` | `….yayasmurmur.dev.marksChanged` |
| Links (opened) | `yayamurmur://join\|helper\|open?event=…` | `yayamurmur-dev://…` |

- **Without Murmur nothing changes:** every Murmur option is hidden and every surface is Join with Fathom's (D-045).
- **Presence** (`MurmurPresence`, `MurmurLive`): looked up at launch, then at most every 30 s while surfaces load and
  after each ping; another app claiming the scheme does not count. A change republishes the widgets.
- **Reading the marks** (`MurmurMarks.parse`, `MurmurLive.marks`): `open(O_NOFOLLOW)`, then `fstat` on that descriptor:
  a regular file owned by this user, at most **256 KB**, read through the same descriptor; re-parsed only when its
  device, inode, size or modification time changed, at launch, when a surface loads and on the ping (`.deliverImmediately`;
  pings within 0.3 s are read once). `v` must be the integer 1; a higher `v` is ignored ("newer"); anything else, or a
  file that isn't a JSON object with a `marks` object, is "unreadable" (no badges). Each mark is checked on its own: an id
  outside the event-id rule (1–128 of `A–Z a–z 0–9 _ -`) or a mark that isn't an object is skipped; a field of the wrong
  type or with an unknown value reads as absent (`liveHelperKind`: `clientMeeting`, `interview`, `discussion`, or another
  word of 1–32 letters = on; `mode`: `homelab`, `macbook`; `consentTier`: `notice`, `explicit`; `status`: `notesReady`,
  `meOnly`; `updatedAt`: ISO 8601); unknown keys are ignored; past 500 marks the newest 500 (by `updatedAt`) are kept.
  Never written, never logged (traces carry outcomes and counts only).
- **Links** (`MurmurLinks`, built with `URLComponents` from the profile's scheme; never from text): `join?event=<r>`
  with `&mode=homelab|macbook` when the Join menu names one (none: Murmur's own setting), `helper?event=<r>`,
  `open?event=<r>`. `r` is the calendar's row id (the export's `id`) and must pass the event-id rule; a link is at most
  512 bytes. Join with Yaya's Murmur opens the join link, then the meeting's allowlisted link 0.6 s later.
- **Preferences** (UserDefaults): `recorder.<account UUID>`: absent = automatic, `"fathom"`, `"murmur"`, `"ask"`, `"off"`.
  Automatic = Fathom when Fathom is installed and the account's Fathom link isn't off, else Yaya's Murmur. A meeting's
  recorder is its primary copy's account's. `fathom.hotkeyRecords` (D-045) makes ⌃⌥J join with that recorder.
- **Snapshot:** `Meeting.rec` (D-045) plus `Meeting.recBy`: `"murmur"` or `"ask"`, left out for Fathom; Up Next Medium
  draws Murmur's ringed planet or "…" in the widget's accent. Version stays 1.
- **Snapshot, Live Helper** (D-048): `Meeting.lh` (`true` or left out) when Murmur's mark for `r` has a Live Helper kind
  and the meeting has a join link; Up Next Medium then shows Join with Live Helper (`livehelper?r&k`) in place of the
  recorder button. The route re-reads the marks and opens Murmur's `join?event=<r>`, then the meeting 0.6 s later.
- **Popover, Live Helper** (D-049): only with Murmur installed and an allowlisted join link. A meeting Murmur marked Live
  Helper shows Join with Live Helper in place of the recorder's button and "✦ Join with Live Helper" in the ▾
  (`JoinMenu.Entry.liveHelper`); an unmarked timed meeting shows a compact "✦ Live Helper" beside the recorder's
  button and "Set up Live Helper…" last in the ▾ (`.liveHelperSetUp`), both opening `helper?event=<r>`. Join with Live
  Helper and the `livehelper` route both call `MurmurSession.joinLiveHelper(_:via:)`: marks re-read, `join?event=<r>`
  (no mode), then the meeting 0.6 s later; nil (not marked, or Murmur gone, nothing opened) leaves the caller its
  recorder's path. The card redraws when the session's `installed` or `marks` change (Murmur's ping). The Event
  Peek's ▾ takes no Live Helper item.
- **Notifications:** categories `yc.meeting.murmur` (actions `yc.join`, `yc.join.murmur`, `yc.snooze`) and
  `yc.meeting.ask` (`yc.join`, `yc.join.ask`, `yc.snooze`; Join and record… opens the Event Peek).
- **Meeting export:** Murmur reads the Deck export (below) unchanged; the switch starts on when Deck or Murmur is installed.

## Yaya's Mail Helper link (D-050)
Yaya's Mail Helper is a private companion app on the same Mac; it talks to the owner's own mail server, the calendar
never does. The calendar reads the helper's files, writes command files in its own data folder and opens one link;
the two share no code, Keychain item or network. The helper's side: its docs/CONTRACT.md, "Helper ⇄ Calendar"
(contract v1, plus v1.1's writer).

| | Release profile | Dev profile |
|---|---|---|
| Installed when | a handler of `yayamail:` has bundle id `com.yahyaelghobashy.yayasmailhelper` | `yayamail-dev:`, `….yayasmailhelper.dev` |
| Its files (read only) | `~/Library/Application Support/YayasMailHelper/share/state.json`, `digest.json`, `results/<id>.json` | `…/YayasMailHelperDev/share/…` |
| Ping (observed) | `com.yahyaelghobashy.yayasmailhelper.changed` | `….yayasmailhelper.dev.changed` |
| Commands (written) | `~/Library/Application Support/YayasCalendar/share/mailhelper/cmd-<uuid>.json` | `…/YayasCalendarDev/share/mailhelper/…` |
| Link (opened) | `yayamail://cmd?id=<uuid>` | `yayamail-dev://cmd?id=<uuid>` |

- **Without the helper nothing changes:** no Mail helper entry in the sidebar, the inbox's order and rows as before, no
  Draft with AI in the composer.
- **Reading** (`MailHelperParse`, `MailHelperLive`): `open(O_NOFOLLOW)`, then `fstat` on that descriptor (a regular file
  owned by this user, at most **4 MiB**), read through it; re-parsed only when its device, inode, size or modification time
  changed, on the ping (`.deliverImmediately`, pings within 0.3 s read once) and every 30 s while the section is open.
  `version` must be the integer 1; higher is "newer" and ignored; anything else is "unreadable". Every item is checked on
  its own and skipped when it fails: accounts and credential names `[A-Za-z0-9_-]{1,64}`, Gmail thread ids
  `[0-9a-f]{1,32}`, backlog runs `bf-` + 12 hex digits, a 32-byte seal key; text loses control and direction characters
  and is capped, and is drawn as plain text only. An answer (`{version:1,id,ok,error,data}`, its `id` the command's) is
  deleted once read.
- **`state.json` fields used:** `updated_at`; `lab.{paired,reachable,last_ok_at,error}`; `server.{seal_key,seal_fingerprint}`;
  `status.{accounts[],claude_credentials,root_label,errors}` (per account: `id` = the calendar's account UUID string,
  `email, kind, paused, state, detail, ai_policy, claude_credential, claude_ready, today, review_waiting, backfill{id,state},
  has_sign_in`); `labels{account: [{label_id,path,category,topic}]}`; `proposals`; `review`; `activity` (newest first,
  at most 150); `backfills{run: {state, scanned, applied, totals, labels[{label,category,topic,count,stays_in_inbox,
  senders[≤5],samples[≤3]}]}}`. `digest.json`: `digest.{id,day,total,read{section: bool},sections[{key,title,count,items}]}`,
  items `{account,thread_id,sender,subject,topic,headline,bullets,worth_opening}` or, for updates,
  `{service,subjects,threads[{account,thread_id}]}`.
- **Commands** (`MailHelperCommand`): `{ "version":1, "id":"<uuid, lowercase>", "kind", "args" }`, compact JSON with sorted
  keys, at most **64 KiB**, written 0600 to a temporary name with `O_EXCL | O_NOFOLLOW`, synced and renamed into a 0700
  folder that is never a link; then the link, opened without bringing the helper forward. Kinds sent: `refresh`,
  `handover {account, kind, envelope}`, `account {account, paused | ai_policy | claude_credential}`, `forget {account}`,
  `people {account, kind: vip | vip_domain | meeting, addresses}` (lowercased, checked, de-duplicated; meetings at most
  2,000), `undo {action_ids | batch | since}`, `proposal {id, decision}`, `review {account, thread_id, category, scope:
  sender | thread}`, `backfill_start {account}`, `backfill_override {run, sender, category}`, `backfill_apply | _stop |
  _undo {run}`, `digest_build`, `digest_read {id, section?}`, `needs_reply`, `voice_get | voice_put {account, card ≤ 3,000}`,
  `voice_build {account, use_claude}`, `draft {account, thread_id, model, effort, instruction? ≤ 1,000}`. The calendar waits
  120 s for an answer (a draft 330 s), looks on every ping and every 1.5 s, and deletes its own command files the helper
  never picked up after an hour.
- **Hand-over** (`handover`): only from the approval card (account, server-key fingerprint, Personal / Work), after
  checking `seal_fingerprint` is the fingerprint of `seal_key` (SHA-256 of the raw key, its first 12 bytes mapped to
  `ABCDEFGHJKMNPQRSTVWXYZ23456789` by `byte % 30`, groups of 4 joined by `-`). The envelope (CONTRACT §2): a fresh
  X25519 key agreed with `seal_key`, HKDF-SHA256 (empty salt, info `yaya-mail-helper seal v1`, 32 bytes),
  ChaCha20-Poly1305 with a fresh 12-byte nonce over `{refresh_token, client_id, client_secret, email}`, AAD
  `mh-seal-v1|gmail|<account UUID>`; `{v:1, purpose:"gmail", account, epk, nonce, ct}` (base64; `ct` = ciphertext + tag).
- **Inbox order and chips** (`MailHelperInbox`): from `labels[account]`, a thread whose `MailThread.labels` include the
  account's Priority label (`category == "priority"`) sorts first, both groups keeping their order, with a ⭐ chip; the
  Review label gives a "Review" chip. Only the Inbox section; the popover and widgets don't change.
- **Preferences** (UserDefaults): `mailhelper.vip.<UUID>`, `mailhelper.vipDomains.<UUID>` (the lists the helper last
  took), `mailhelper.draft.model.<UUID>`, `mailhelper.draft.effort.<UUID>`.
- **Meeting people:** once a day (checked hourly) and when the helper appears, per handed-over account with meetings.

## Accounts interface (shell ↔ accounts)
`AccountsModel.shared: ObservableObject` with `start()`; `AccountsScreen(model:)` view.

## Rich mail (D-040 to D-044)
- **Folders** under the data root, folders 0700 and files 0600, none inside `widget/`, so the widget extension can't
  read them; `--uninstall --purge` deletes them with the rest of the data root:
  `attachments/` (attachment cache, hashed names, least recently opened files go past 300 MB, nothing over 50 MB
  fetched); `outbox/` (`<action id>.eml`, the raw MIME of a queued send over 64 KB or with files or inline images,
  SHA-256 in the action payload, required: a file without it is unreadable; deleted when sent or cancelled, kept 7 days
  when failed, strays swept at launch and when an account is removed; `<action id>.upload` holds an upload's body
  while it is sent); `compose/` (`<composer id>/`, the composer's copies of attached files, made off the main thread,
  a symlink's target copied, never the link; deleted when the window closes, swept at launch); `Mail Downloads/`
  (copies handed to Open, removed after 24 h).
- **Delivery** (D-023 unchanged): the raw message's own To, Cc and Bcc must equal the recipients checked when Send was
  pressed, or the send fails as unreadable and nothing goes out.
- **Seam** (`Sources/Contracts/Stores.swift`, D-041): `MailAttachmentStore` via `Services.mailAttachments` (empty until
  the data layer installs it); `MailMessage.Attachment` `id` (Gmail part id), `mimeType`, `contentId`, `isInline`;
  `MailMessage.isPlainText`; `MailDraft.html`, `.attachments`, `.quote` (`MailQuoteRequest`); `MailDraftAttachment`
  (`filename`, `mimeType`, `file`, `bytes`, `contentId`, and `data: Data? = nil`: bytes in memory for drafts without a
  staging folder, read instead of `file` when set); `MailAccountPrefs.signatureRich`. All defaulted.
- **Size** (`MailSize`, D-044): limit 25,000,000 bytes of encoded MIME (equal is allowed); a note in the composer over
  10,000,000; the composer's estimate never under-counts (base64 is 78 bytes per 57); the data layer checks the exact
  size before queueing.
- **Gmail:** `messages.attachments.get` (20 units); raw MIME over 1 MB goes to `messages.send` through
  `https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart` on the long-request HTTP
  session (60 s between bytes; 15 min in all, longer for big bodies at 8 KB/s), the body streamed from a file. No new
  scope, no new host.
- **Store migration v6:** `mail_prefs.signature_rich` (RTFD, base64), `attachment_cache` (account, message and part
  id; file, bytes, MIME type, SHA-256, last opened) and `mail_correspondents` (account, address, last seen). Both tables
  are quiet: writes move no widget write generation.
- **Settings keys** (`MailLocalStore`): `mail.compose.fontFamily`, `mail.compose.fontSize`, `mail.compose.plainTextOnly`
  (default off), `mail.compose.quoteStyle` (`bar` | `header`), `mail.attachments.saveFolder` ("" = Downloads),
  `mail.images.fromCorrespondents` (default off). Correspondents are the senders of messages in threads the user
  replied in plus everyone the user sends to from this app, recorded per account from metadata already fetched (no
  Contacts access) and only while the setting is on; turning it off deletes them all, in every account (Settings → Mail calls `forgetCorrespondents()`; the engine also clears them at start while it is off). The user's own addresses never count. With the setting on, mail
  in that account from them loads remote images without asking.
- **Menus:** Format menu (lists, indent, quote block, link, clear formatting, Make Plain Text) with Attach Files…
  (⇧⌘A); Edit → Paste and Match Style (⌥⇧⌘V). The F key in the Inbox forwards.
- **Routes and the widget:** unchanged. No new `yayacal://` route, no snapshot change, no new file under
  `Sources/Shared` or `Sources/Widget`, and no attachment code in the widget extension.

## Mail
Rows are Gmail **threads**; `r` = deterministic hash of account + thread id. Actions via `threads.modify`
(read = remove UNREAD, archive = remove INBOX, star = add STARRED to the newest message, trash =
threads.trash). `mail/undo?r&k` reverses the last archive/trash of row r within 30 s. Sends carry our own
Message-ID; before any retry the sender searches Sent for `rfc822msgid:` (no double send). Remote images
are blocked unless the sender is on the allow list. Migrations: v4 threads/messages cache + mail state,
v5 action queue (data layer).
Asking before sending (D-023): `MailDraft.approvedOutside` (default `[]`, lowercased) lists the outside addresses
the user approved for that one send in the composer's approval card; only the card fills it, never remembered.
While `Labs.safeSend` is on, `MailActions.send` refuses any To/Cc/Bcc address that is neither one of the connected
accounts' addresses nor approved (case-insensitive; an approval clears only the address it names), with a friendly
`ServiceError`; the switch as read when Send was pressed and the approvals ride in the queued action (`payload["ask"]`
"1"/"0", `payload["approved"]`) so the delivery-time re-check, retries and recovery after a restart apply that same
rule (no `ask`: the switch now). Off: no card and no check. Recipient entries carrying CR or LF (checked per Unicode
scalar: "\r\n" is one Swift Character) are refused before any of this.

## Deck export
`share/upcoming-meetings.json` (v1, atomic 0600, written only on change) + DistributedNotification `com.yahyaelghobashy.yayascalendar.meetingsChanged` (no payload). Removed on uninstall.
For Deck, a meeting recorder on the same Mac, and Yaya's Murmur (D-046), which reads the same file under the same
contract: they name recordings, link them to the right event within ±15 minutes and tell internal from external
calls. Nothing leaves the machine. Settings: "Share upcoming meetings with Deck" ("… with Deck and Yaya's Murmur"
while Murmur is installed); with no stored choice it is on when Deck or Murmur is installed.

| | |
|---|---|
| File | `~/Library/Application Support/YayasCalendar/share/upcoming-meetings.json` (`Paths.share`) |
| Modes | `share/` 0700 (created by `DataFolders.ensure`), file 0600 |
| Write | temp file next to it (`O_CREAT|O_EXCL|O_NOFOLLOW`, 0600), `fsync`, `rename(2)`: readers see the old file or the new one |
| When | after every calendar pass, RSVP, account edit, every 5 min, on time-zone/clock/day change; **written only when the content changed** (`generatedAt` excluded from the comparison) |
| Ping | after each write, `DistributedNotificationCenter` posts `com.yahyaelghobashy.yayascalendar.meetingsChanged` with no object and no userInfo: re-read the file |
| Writer | `Sources/Notify/DeckExport.swift` (`DeckExportBuilder`, `DeckExporter`, `SecureFile`), driven by `NotifyCoordinator.refresh()` |
| Uninstall | `--uninstall` (with or without `--purge`) deletes the file, then posts the same ping |

A reader loads the file at launch and on every ping, and treats a missing or undecodable file as "no
calendar data". `generatedAt` is the time of the last *change*; if the app is not running the file can be
hours old, so a reader applies its own time filter.

```json
{
  "v": 1,
  "generatedAt": "2026-10-19T07:48:00Z",
  "myDomains": ["home.example", "orbitalpickle.example"],
  "meetings": [
    {
      "id": "gK3v…22 chars",
      "accounts": ["ORB", "FAM"],
      "provider": "google",
      "start": "2026-10-19T09:00:00Z",
      "end": "2026-10-19T09:30:00Z",
      "title": "Weekly sync",
      "joinURL": "https://meet.google.com/abc-defg-hij",
      "organizer": { "name": "Juniper", "email": "juniper@riverside.example" },
      "attendees": [
        { "name": null, "email": "avery@orbitalpickle.example", "response": "accepted" },
        { "name": "Juniper", "email": "juniper@riverside.example", "response": "needsAction" }
      ],
      "isExternal": true
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `v` | Schema version (1). Ignore files with a higher `v`. New optional keys may appear without a bump. |
| `generatedAt` | When this content was built, i.e. last changed (ISO 8601 UTC). |
| `myDomains` | Email domains of every connected account (lowercased, sorted, unique). |
| `meetings` | Sorted by `start`, then `id`. At most 300. |
| `id` | The stable local id `r` (merged invites across accounts share one). Opaque. |
| `accounts` | Tags of every connected account that has the meeting, primary copy first (no tag: the account's name). |
| `provider` | `"google"` (D-009). |
| `start`, `end` | ISO 8601 UTC instants. |
| `title` | As in Google Calendar (`(No title)` when empty). |
| `joinURL` | https link that passes the join rules (`JoinLinks.isAllowed`), or `null`. |
| `organizer` | `{name, email}` or `null`; `name` may be `null`. |
| `attendees` | `[{name, email, response}]` without rooms/resources; includes the user. `response` ∈ `accepted`, `tentative`, `declined`, `needsAction`. |
| `isExternal` | `true` when any attendee or the organizer (other than the user) is outside the user's domains. |

Keys are always present; missing values are `null`. Meetings: every timed, non-declined event of every
account with Calendar on that overlaps [now − 15 min, now + 48 h); merged invites and separate invites to
the same call (same start, same join link) appear once. "Declined" is the primary copy's response (D-017).
A person is internal when their address is one of the connected accounts' addresses, or their domain is
in `myDomains` and is not a public webmail domain (gmail.com, outlook.com, icloud.com, yahoo.com and the
like); Google calendar ids (rooms, group calendars) never make a meeting external. The trace logs only
counts, never titles, names, addresses or links.
