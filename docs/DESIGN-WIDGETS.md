# Widget design direction (v2, 2026-10-19)

Goals: widgets that feel calm rather than technical, an account logo on every row (Personal stays
blank), clear separation between days, user-controlled size and fonts, friendly names and copy.

## Principles
1. **Calm over clever.** Proportional type (SF Pro / Rounded / New York), real words, "9:00 AM", no
   monospace, no internal codes. Numbers use tabular digits so times still line up.
2. **Days are chapters.** Every day opens with a soft banner: "Today · Monday 19 October" + count.
   Tomorrow and later days read "Tomorrow", "Wednesday 21". A column that continues a day says
   "Today, continued".
3. **One moment matters.** The current or next meeting is highlighted (soft accent fill), says
   "Now" or "in 12 min", and carries the only filled **Join** button. Later meetings show a small
   camera glyph when they have a link.
4. **Whose meeting is it?** A 16 pt logo badge per row (the account's logo, or a drawn badge with its
   tag). Personal is blank, by design. Logos are the identity; colour is never the only signal.
5. **Glanceable summary.** Header: weekday (accent) + date, "5 meetings · free after 4:30 PM",
   and a gentle pager "1 of 3" with round arrow buttons.

## Settings (Widget Studio, per widget)
Look: Light (Paper) · Dark (Ink) · Match Mac. Font: System · Rounded · Serif. Text size: Small ·
Standard · Large (Large shows fewer meetings per page; Standard keeps ≥10 on Large). Show: calendar
logos, end times, locations, declined meetings, all-day events. Clock: 12 h · 24 h.

## Gallery names + descriptions
| Widget | Description |
|---|---|
| Agenda | Your meetings from every calendar, day by day. Flip pages with the arrows. |
| Day | One day hour by hour, with overlapping meetings side by side. Flip days with the arrows. |
| Up Next | Your next meeting, a countdown and a Join button. |
| Inbox | Newest mail from all your inboxes. Tap to read, mark read or archive. |
| Agenda & Inbox | Meetings on one side, mail on the other. |
| Month | Tap a day on the calendar to see its meetings. |
| Daily Digest | Today's mail digest from Yaya's Mail Helper, one box per mailbox. Tap to read it. |
| Custom Widget A–F | Pick its calendars and look in Yaya's Calendar → Widgets. |

## Month widget (added 2026-10-19)
Mini month (week starts on the Mac's first weekday — Monday in the UK). Today = filled accent circle,
picked day = accent ring, days with meetings = small dot. Every day cell is a Link
`yayacal://day?w=<kind>&d=YYYY-MM-DD`; month arrows are Links `yayacal://month?w=<kind>&to=YYYY-MM`.
The picked day's meetings show beside (Medium, XL) or below (Large, XL Portrait) the grid and run on
into the following days when there is room. Small = grid only; tapping a day opens a Peek of that day.
Selection returns to today at midnight.

## Refresh glyph (added 2026-10-20, D-021)
Meetings get cancelled: every widget, every family and whole-card state carries a quiet ↻ (10 pt
glyph, text3, 18 pt tap target) linking `yayacal://sync?w=<kind>`. It sits in the header just left of
the pager or Month arrows (Agenda L/XL, Agenda & Inbox, Inbox, Month, Agenda XL Portrait), beside the
big date (Agenda Medium), level with the badge row in the top-right corner (Up Next / Agenda Small),
in the "After that" header (Up Next Medium), or in the top-right corner of a whole-card state. One per
widget (Agenda & Inbox XL keeps it in its inbox header). Month Small/Medium shorten a long month name
("SEP") rather than truncate it. A widget can't animate while the app syncs; the reload that follows
draws ✓ in the accent colour for 30 s after a healthy sync ("synced just now"), then ↻ again.

## Day widget (added 2026-10-20, D-022)
One day as an hour grid, meetings as blocks side by side when they overlap (Google Calendar's day view)
in this file's language. Engine `Sources/Shared/Widgets/DayLayout.swift` (pure, tested in
Tests/DayLayoutTests.swift), views `DayTimeline.swift`, fixtures `DaySampleData.swift`.

- **Window.** L / XL / XLP fit every timed meeting of the day (30 min of air, half-hour snaps, at least
  6 h on L and 8 h on XL / XLP, clamped to the day; today also opens at "now" when the first meeting
  is ≤3 h away). S shows 2.5 h and M 3 h from the half hour before now.
- **Layout.** Overlapping meetings form a cluster; columns are greedy by start, longer first, and a
  block grows right into columns it does not collide with. Short meetings are laid out as tall as the
  minimum block (15–16 pt), so they never cover the next one. Columns past the cap (L / XL / XLP 3,
  M 2, S 1) go on a "+N" chip (→ Day Peek).
- **Blocks.** Account tint (Paper: light tint + deeper left edge; Ink: deeper tint + the colour on the
  edge), logo badge top-left (personal keeps the empty slot), title 1–3 lines by height, time range
  and place when they fit. Narrow columns flow the title around the logo. Short blocks are one line.
  Tentative = hatched, needs-reply = dashed outline on paper, past (today) = faded. Declined never
  arrive (D-017).
- **One moment matters.** The meeting under way (latest started) or the next within 30 min gets the
  accent ring; its Join is on the block (L / XL / XLP), in the header (S) or in the day panel (M).
- **Now.** Accent line under the blocks, dot in the hour gutter.
- **Header.** L / XL: "Monday 19 October" (weekday in the accent), count or day summary, ↻, ‹ ›.
  XLP: Agenda's two-line date header. M: day panel (weekday, big date, summary or Join, ↻ ‹ ›).
  S: "MON 19 Oct", Join, ↻. XL splits the day into two columns at the whole hour near the middle
  that cuts the fewest meetings, both at one scale.

**Wiring.** Kind `day` (gallery order Agenda, Day, Up Next, …; all five families) and Custom
slot type Day (Studio chip "Day"; the kind list shows `calendar.day.timeline.left`). The snapshot is
`widget/day.json` with `Content.day` and only the day shown (`selectedDay`, nil = today; picked days stay
inside the sync window and go back to today at midnight, like Month). Taps: ‹ › → `day?w=<kind>&d=<prev/next>`
(quiet; an arrow at the window's edge fades and links nowhere); ↻ → `sync?w=<kind>` through the shared
`RefreshButton` in its round Day form (✓ for 30 s after a healthy sync); "+N" and any empty part of the
grid → `open/day?w&d` (Day Peek); a block → `open/event?r&k`; Join → `join?r&k`. On another day the header
date links back to today, and L / XL / XLP show a small "Today" chip by the arrows (L: in place of the
count; the date shortens to "Wed 21 October" / "Wed 21 Oct" before it would truncate). Another day's S / M
slice opens at its first timed meeting (9 AM when it has none) and says "Nothing later" past its last.
The "Last synced" / re-auth strip takes 7 pt from L / XL / XLP's grid (as Agenda's pages do). Timelines:
`TimelinePlan.dayEntryDates` (only where the drawing changes; D-019). The headless renders match the
design's reference drawings within run-to-run antialiasing noise (max 2/255).

## Daily Digest widget (added 2026-10-30, D-053)
Yaya's Mail Helper's morning digest at a glance, in this file's language, one box per mailbox (any number;
what doesn't fit folds into "+N more mailboxes"). Views `Sources/Shared/Widgets/Digest.swift`.

- **Badge.** "12 unread" on the accent (the items of every section not read yet), "✓ All read" on the soft
  accent once every section is read. Small and Medium draw the number large (rounded, heavy), the word beside it.
- **Mailboxes.** The account's logo, or its initial on the account's colour (Personal and mailboxes without a
  logo still get a face); its name; its first line; its own count (accent pill, ✓ when read, "–" on a quiet
  day). Small shows up to four marks with an accent dot on the ones with unread mail.
- **Summary of the summary.** Large and up open with a band card (accent edge) of the top two or three lines
  across mailboxes: ✦ for "worth opening", picks and unread sections first, one mailbox at a time; then the
  sections as chips ("Social 5", read ones outlined with ✓) on Large and Portrait, or as a list with "✓ Read"
  on Extra Large.
- **Header.** Large and up: the mark, "Daily Digest", "Today · Monday 19 October" (the day in the accent),
  the badge, ↻. Small: "DIGEST", the day. Medium: "DAILY DIGEST", the day, the date; "MAILBOXES" and ↻
  over the rows.
- **States.** Unread, all read (lines and chips dim), no digest yet, Yaya's Mail Helper not on this Mac: the
  last two as whole cards in the widgets' own voice (`DigestCopy`).

- **Model Atlas** (D-054). With its weekly report on the Mac, one more box after the mailboxes: a chip glyph on the
  soft accent, "Model Atlas · Week of 31 Oct", alerts first with ⚠, then its lines; "New" until opened once; dimmed
  after eight days. Never counted as mail; it keeps its place when mailboxes spill into "+N more".

**Wiring.** Kind `digest` (after Agenda & Inbox; all five families), `widget/digest.json` with
`Content.digest` and the `digest` value (or `Content.mailHelperOff`). Taps: header → the Digest tab
(`open/app?section=mailhelper&tab=digest`); badge → its first unread section (`&part=<key>`); a chip, a
section row or a summary line → that section; a mailbox → its first unread section; ↻ → `sync?w=digest`
(re-reads the helper's files). Timelines: one entry, then midnight ("Today" becomes "Yesterday").

## Desktop not in focus (added 2026-10-28, D-047)
With another app in front, macOS draws desktop widgets in a monochrome mode on its own glass and removes
their background: **accented** (macOS 26 and later) paints every pixel white and keeps only its opacity;
**vibrant** desaturates and keeps only its brightness. The widgets switch to a glass palette in both, for
every look: no sheet of their own, white text with the hierarchy in opacity (accented) or grey level
(vibrant), banners, blocks and chips as faint white fills, Join and the other filled accents as a soft
glass capsule with a white label, logos desaturated (their brightness becomes opacity) without the Dark
look's paper plate. The weekday, "Now", Join, today and the now line are accentable, for a system that
tints the accent group. The renders composite both modes as macOS does (`accented-*`, `vibrant-*`,
`glass-*`), and the gate fails a render that comes out blank or solid.
