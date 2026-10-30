import AppKit
import CryptoKit
import Foundation

// UI-layer fixtures (D-014): fakes for every app seam the surfaces call, and `WidgetSnapshot`
// builders from the sample week. Renders and tests go through JSON exactly like the widget
// (encode with `WidgetSnapshot.encoder`, decode with `WidgetSnapshot.decoder`). Nothing here touches the
// Keychain, the network or Application Support.

// MARK: - Accounts

/// The cast's four accounts (`Cast`): Orbital Pickle Co. (work), The Quiet Comets (a band), Moonfield
/// Family and Personal.
enum FixtureAccounts {
    static let orb = Cast.orb.id
    static let cmt = Cast.cmt.id
    static let fam = Cast.fam.id
    static let home = Cast.home.id

    static let all: [(id: UUID, tag: String, name: String, email: String, color: UInt32, sample: String)] =
        Cast.accounts.map { ($0.id, $0.tag, $0.name, $0.email, $0.color, $0.key) }

    /// Sample-week account keys ("orb") → fixture UUIDs.
    static func id(forSample key: String) -> UUID { all.first { $0.sample == key }?.id ?? home }

    /// `hasLogo` is true for the three badged accounts (Personal has none, by design); whether a badge
    /// draws depends on the logo loader the caller passes to SnapshotModel (renders: `Cast.badge`).
    static var snapshotAccounts: [WidgetSnapshot.Account] {
        all.map { WidgetSnapshot.Account(id: $0.id.uuidString, tag: $0.tag, name: $0.name, color: Int($0.color),
                                          hasLogo: $0.id != home) }
    }

    static func directory(logo: (UUID) -> NSImage? = { _ in nil }) -> AccountDirectory {
        AccountDirectory(accounts: all.map {
            DirectoryAccount(id: $0.id, tag: $0.tag, name: $0.name, email: $0.email, color: $0.color, logo: logo($0.id))
        })
    }
}

/// CONTRACTS "Link keys" with a fixed, public fixture key (never the real one, which lives in the
/// Keychain): base64url, no padding, of the first 12 bytes of HMAC-SHA256(key, r).
#if YC_DEV_TOOLS
enum FixtureLinkKeys {
    static let key = SymmetricKey(data: Data("yayas-calendar fixture link key (public, tests only)".utf8))

    static func k(_ r: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(r.utf8), using: key)
        return Data(Array(mac).prefix(12)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func verify(r: String, k: String) -> Bool {
        let expected = Array(Self.k(r).utf8), given = Array(k.utf8)
        guard expected.count == given.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(expected, given) { diff |= a ^ b }
        return diff == 0
    }
}
#endif

/// The `k` a fixture row carries: the fixture key's MAC in developer builds; empty in release builds (D-035),
/// which carry no fixture key: Widget Studio previews there draw links that verify against nothing.
func fixtureLinkKey(_ r: String) -> String {
    #if YC_DEV_TOOLS
    FixtureLinkKeys.k(r)
    #else
    ""
    #endif
}

// MARK: - Meetings

/// One fixture meeting: everything the snapshot row and the CalendarEvent need, from one source.
struct FixtureMeeting {
    var r: String
    var accounts: [UUID]
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var place: String?
    var join: URL?
    var reply: CalendarEvent.Response = .accepted
    var clashes = false
    var notes: String?
    var attendees: [CalendarEvent.Attendee] = []

    var snapshotRow: WidgetSnapshot.Meeting {
        let reply: WidgetSnapshot.Meeting.Reply
        switch self.reply {
        case .tentative: reply = .maybe
        case .needsAction: reply = .needsReply
        default: reply = .accepted
        }
        return WidgetSnapshot.Meeting(r: r, k: fixtureLinkKey(r), accountIds: accounts.map(\.uuidString), title: title,
                                      start: start, end: end, allDay: allDay, place: place, hasJoin: join != nil,
                                      reply: reply, clashes: clashes)
    }

    var event: CalendarEvent {
        let me = CalendarEvent.Attendee(name: Cast.ownerName, email: Cast.home.email, response: reply,
                                        isSelf: true, isOrganizer: false)
        let organizer = attendees.first { $0.isOrganizer }
        return CalendarEvent(r: r, accountIds: accounts, calendarName: FixtureAccounts.all.first { $0.id == accounts.first }?.name ?? "Calendar",
                             title: title, start: start, end: end, allDay: allDay, location: place, joinURL: join,
                             webURL: URL(string: "https://calendar.google.com/calendar/event?eid=\(r)"),
                             notes: notes, organizer: organizer, attendees: attendees.isEmpty ? [] : [me] + attendees,
                             myResponse: reply, clashes: clashes)
    }
}

enum FixtureWeek {
    static let guests: [(String, String)] = [
        ("Milo Brightwater", "milo@quietcomets.example"), ("Juniper Vale", "juniper@orbitalpickle.example"),
        ("Rafa Thistle", "rafa@pebblepost.example"), ("Sasha Pebble", "sasha@moonfield-family.example"),
        ("Priya Starling", "priya@orbitalpickle.example"), ("Bea Lantern", "bea@quietcomets.example"),
        ("Ines Marlowe", "ines@moonfield-family.example"), ("Theo Quill", "theo@orbitalpickle.example"),
        ("Wren Copperpot", "wren@quietcomets.example"), ("Kofi Ember", "kofi@moonfield-family.example"),
        ("Nico Fernhollow", "nico@orbitalpickle.example"), ("Tess Marigold", "tess@quietcomets.example"),
    ]

    static func attendees(_ count: Int, seed: Int) -> [CalendarEvent.Attendee] {
        let responses: [CalendarEvent.Response] = [.accepted, .accepted, .tentative, .needsAction, .accepted, .declined]
        return (0..<count).map { i in
            let g = guests[(i + seed) % guests.count]
            return CalendarEvent.Attendee(name: g.0, email: g.1, response: responses[(i + seed) % responses.count],
                                          isSelf: false, isOrganizer: i == 0)
        }
    }

    /// Real meeting hosts (the Join allowlist and the provider names need them) with synthetic ids only.
    static func joinURL(for account: UUID, _ n: Int) -> URL {
        switch account {
        case FixtureAccounts.cmt: return URL(string: "https://zoom.us/j/\(n % 2 == 0 ? "1234567890" : "0000000000")")!
        case FixtureAccounts.fam: return URL(string: "https://teams.microsoft.com/l/meetup-join/fixture-\(n)")!
        default: return URL(string: "https://meet.google.com/abc-defg-hij")!
        }
    }

    /// The sample week (WidgetSample.week), as the data layer would carry it: stable ids, one
    /// merged invite (ORB+CMT), one all-day event, guests and notes on the bigger meetings.
    static func busy(now: Date, calendar: Calendar) -> [FixtureMeeting] {
        var out = from(WidgetSample.week(now: now, logos: nil, calendar: calendar).meetings, prefix: "ev")
        if let i = out.firstIndex(where: { $0.title == "Pickle × Comets jingle weekly" }) {
            out[i].accounts = [FixtureAccounts.orb, FixtureAccounts.cmt]
            out[i].r = "grp-jingle"
            out[i].notes = "Agenda\n1. Last week's numbers\n2. The jingle plan\n3. Open questions from the band\nDeck is in the shared folder."
            out[i].attendees = attendees(12, seed: 0)
        }
        if let i = out.firstIndex(where: { $0.title == "Album artwork walkthrough" }) {
            out[i].attendees = attendees(5, seed: 3)
            out[i].notes = "Walk through the October artwork proofs before they go to the printer."
        }
        if let i = out.firstIndex(where: { $0.title == "The Comets weekly sync" }) {
            out[i].attendees = attendees(4, seed: 5)
        }
        // An all-day event on Wednesday (sample day 21).
        let anchor = calendar.startOfDay(for: now)
        let wednesday = calendar.date(byAdding: .day, value: 2, to: anchor)!
        out.append(FixtureMeeting(r: "ev-allday-offsite", accounts: [FixtureAccounts.fam], title: "Family day out",
                                  start: wednesday, end: calendar.date(byAdding: .day, value: 1, to: wednesday)!,
                                  allDay: true, place: "The lake house"))
        return out.sorted { ($0.start, $0.r) < ($1.start, $1.r) }
    }

    /// The Day widget's busy day (`DaySample.twenty`, Monday 19 October 2026): stable ids `dy1`…`dy20`.
    static func busyDay(calendar: Calendar) -> [FixtureMeeting] {
        from(DaySample.twenty(logos: nil, calendar: calendar), prefix: "dy")
    }

    static func sparse(now: Date, calendar: Calendar) -> [FixtureMeeting] {
        from(WidgetSample.sparseWeek(now: now, logos: nil, calendar: calendar).meetings, prefix: "sp")
    }

    /// London leaves summer time early on Sunday 25 October 2026 (02:00 → 01:00): meetings on both
    /// sides of the repeated hour, one ending inside it. Day 0 is the day of `now` (the fixture's
    /// `dstNow` is that Sunday).
    static func dst(now: Date, calendar: Calendar) -> [FixtureMeeting] {
        let anchor = calendar.startOfDay(for: now)
        func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
            calendar.date(bySettingHour: h, minute: m, second: 0, of: calendar.date(byAdding: .day, value: day, to: anchor)!)!
        }
        let rows: [(UUID, String, Int, Int, Int, Int)] = [
            (FixtureAccounts.cmt, "Late call · West coast", 0, 0, 30, 60),
            (FixtureAccounts.fam, "Sunday brunch", 0, 10, 0, 60),
            (FixtureAccounts.cmt, "Soundcheck", 0, 13, 0, 30),
            (FixtureAccounts.orb, "Release checklist", 0, 16, 0, 60),
            (FixtureAccounts.home, "Movie night", 0, 20, 0, 120),
            (FixtureAccounts.orb, "Team stand-up", 1, 9, 30, 15),
            (FixtureAccounts.fam, "Holiday plan review", 1, 11, 0, 60),
            (FixtureAccounts.home, "Lunch with Rafa", 1, 14, 0, 90),
            (FixtureAccounts.cmt, "Gig recap", 2, 10, 0, 30),
        ]
        return rows.enumerated().map { i, row in
            let start = at(row.2, row.3, row.4)
            return FixtureMeeting(r: "dst\(i + 1)", accounts: [row.0], title: row.1, start: start,
                                  end: start.addingTimeInterval(TimeInterval(row.5 * 60)),
                                  join: row.0 == FixtureAccounts.home ? nil : joinURL(for: row.0, i))
        }
    }

    private static func from(_ meetings: [WidgetMeeting], prefix: String) -> [FixtureMeeting] {
        meetings.map { m in
            let account = FixtureAccounts.id(forSample: m.account.id)
            let reply: CalendarEvent.Response
            switch m.reply {
            case .accepted: reply = .accepted
            case .maybe: reply = .tentative
            case .needsReply: reply = .needsAction
            }
            return FixtureMeeting(r: "\(prefix)\(m.id)", accounts: [account], title: m.title, start: m.start, end: m.end,
                                  place: m.place, join: m.hasLink ? joinURL(for: account, m.id) : nil, reply: reply,
                                  clashes: m.clashes)
        }
    }
}

// MARK: - Snapshots

/// Snapshot builders for every state the surface draws. All pinned to the sample week's "now" (Monday 19
/// October 2026, 9:48 AM, London) unless a builder says otherwise.
enum SnapshotFixtures {
    /// Names used by renders, the gate and the committed JSON files (Tests/Fixtures/<name>.json).
    static let names = ["busy", "busyPage2", "sparse", "dst", "empty", "noAccounts", "stale", "reauth",
                        "mailComingSoon", "setup", "customTitle", "mailArchived", "inboxZero",
                        "busyDay", "dayPicked", "customDay"]

    static var calendar: Calendar { WidgetCalendar.fixed }
    static var now: Date { WidgetSample.fixedNow }
    /// Sunday 25 October 2026, 9:48 AM, London: the day the clocks go back (a 25-hour day).
    static var dstNow: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 48))!
    }

    /// The fixture a name stands for, for one kind (as the data layer would publish it with mail off).
    /// Day content carries only the day it shows, as the publisher writes it (D-022).
    static func named(_ name: String, kind: String, now: Date? = nil, calendar: Calendar? = nil) -> WidgetSnapshot {
        let cal = calendar ?? self.calendar
        let s = unfiltered(name, kind: kind, now: now, calendar: cal)
        return s.content == .day ? dayOnly(s, calendar: cal) : s
    }

    /// Meetings overlapping the day a Day snapshot shows (`selectedDay`, else the snapshot's today).
    static func dayOnly(_ snapshot: WidgetSnapshot, calendar cal: Calendar) -> WidgetSnapshot {
        var s = snapshot
        let today = cal.startOfDay(for: s.generatedAt)
        let start = s.selectedDay.flatMap { day -> Date? in
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        } ?? today
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        s.meetings = s.meetings.filter { $0.start < end && max($0.end, $0.start.addingTimeInterval(1)) > start }
        s.busyDays = []
        return s
    }

    private static func unfiltered(_ name: String, kind: String, now: Date?, calendar cal: Calendar) -> WidgetSnapshot {
        #if YC_DEV_TOOLS
        // The Daily Digest's own states (D-053); any other fixture draws the busy digest on it.
        if kind == WidgetKinds.digest.kind { return digestFixture(name, now: now ?? self.now, calendar: cal) }
        #endif
        switch name {
        case "busyPage2":
            var s = busy(kind: kind, now: now ?? self.now, calendar: cal)
            s.pages = ["L": 2, "XL": 2, "XLP": 2, "M": 1]
            s.pageResetAt = (now ?? self.now).addingTimeInterval(4 * 60)
            return s
        case "sparse":
            return base(kind: kind, meetings: FixtureWeek.sparse(now: now ?? self.now, calendar: cal), now: now ?? self.now, calendar: cal)
        case "dst":
            let n = now ?? dstNow
            return base(kind: kind, meetings: FixtureWeek.dst(now: n, calendar: cal), now: n, calendar: cal)
        case "empty":
            return base(kind: kind, meetings: [], now: now ?? self.now, calendar: cal)
        case "noAccounts":
            var s = base(kind: kind, meetings: [], now: now ?? self.now, calendar: cal)
            s.accounts = []
            s.health = .init(state: .noAccounts, accountId: nil, k: nil, syncedAt: nil)
            return s
        case "stale":
            var s = busy(kind: kind, now: now ?? self.now, calendar: cal)
            s.health = .init(state: .stale, accountId: nil, k: nil, syncedAt: (now ?? self.now).addingTimeInterval(-(2 * 3600 + 600)))
            return s
        case "reauth":
            var s = busy(kind: kind, now: now ?? self.now, calendar: cal)
            let cmt = FixtureAccounts.cmt.uuidString
            s.health = .init(state: .reauth, accountId: cmt, k: fixtureLinkKey(cmt), syncedAt: (now ?? self.now).addingTimeInterval(-25 * 60))
            return s
        case "mailComingSoon":
            var s = base(kind: kind, meetings: [], now: now ?? self.now, calendar: cal)
            s.content = .mailComingSoon
            return s
        case "setup":
            var s = base(kind: kind, meetings: [], now: now ?? self.now, calendar: cal)
            s.content = .setup
            return s
        case "mailArchived":
            // A row archived from the widget 8 s before "now": it reads "Archived · Undo" until +30 s.
            var s = busy(kind: kind, now: now ?? self.now, calendar: cal)
            if let i = s.mail.firstIndex(where: { $0.r == "th-jingle" }) {
                s.mail[i].archivedAt = (now ?? self.now).addingTimeInterval(-8)
                if s.mail[i].unread { s.mail[i].unread = false; s.unreadCount = (s.unreadCount ?? 1) - 1 }
            }
            return s
        case "justSynced":
            // The reload right after a refresh tap: synced 5 s before "now", so ↻ reads ✓.
            var s = busy(kind: kind, now: now ?? self.now, calendar: cal)
            s.health.syncedAt = (now ?? self.now).addingTimeInterval(-5)
            return s
        case "longMonth":
            // September on the grid at the Large text size: Month Small/Medium shorten it to "SEP" beside ↻.
            var s = busy(kind: kind, now: now ?? self.now, calendar: cal)
            s.monthShown = "2026-09"
            s.style.textSize = WidgetStyle.TextSize.large.key
            return s
        case "inboxZero":
            var s = busy(kind: kind, now: now ?? self.now, calendar: cal)
            s.mail = []
            s.unreadCount = 0
            return s
        case "busyDay":
            // The Day widget's 20-meeting day (DaySample.twenty: 3-, 4- and 5-way overlaps) on Monday.
            return base(kind: kind, meetings: FixtureWeek.busyDay(calendar: cal), now: now ?? self.now, calendar: cal)
        case "dayPicked":
            // ‹ › moved the Day (or Month) to Wednesday: the all-day day out and four meetings.
            let n = now ?? self.now
            var s = kind == "month" ? busy(kind: kind, now: n, calendar: cal)
                : base(kind: kind, meetings: FixtureWeek.busy(now: n, calendar: cal), now: n, calendar: cal)
            s.selectedDay = DayName.posixDay(cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now ?? self.now))!, calendar: cal)
            return s
        case "customDay":
            // Custom F set to Day in Studio: "Work" (ORB + FAM).
            let keep: Set<UUID> = [FixtureAccounts.orb, FixtureAccounts.fam]
            let meetings = FixtureWeek.busy(now: now ?? self.now, calendar: cal).filter { keep.contains($0.accounts[0]) }
            var s = base(kind: kind, meetings: meetings, now: now ?? self.now, calendar: cal)
            s.content = .day
            s.title = "Work"
            s.accounts = FixtureAccounts.snapshotAccounts.filter { keep.contains(UUID(uuidString: $0.id)!) }
            return s
        case "customTitle":
            let keep: Set<UUID> = [FixtureAccounts.orb, FixtureAccounts.fam]
            let meetings = FixtureWeek.busy(now: now ?? self.now, calendar: cal).filter { keep.contains($0.accounts[0]) }
            var s = base(kind: kind, meetings: meetings, now: now ?? self.now, calendar: cal)
            s.content = .agenda
            s.title = "Work"
            s.accounts = FixtureAccounts.snapshotAccounts.filter { keep.contains(UUID(uuidString: $0.id)!) }
            return s
        default:
            return busy(kind: kind, now: now ?? self.now, calendar: cal)
        }
    }

    #if YC_DEV_TOOLS
    /// The Daily Digest (D-053), as the publisher writes it from the helper's fixture files: `busy` (and any other name)
    /// = Monday's digest, codes and security read; `digestAllRead`; `digestNone` (installed, no digest yet);
    /// `mailHelperOff` (the helper isn't on this Mac); `digestMany` (seven mailboxes, four the calendar doesn't know).
    static func digestFixture(_ name: String, now: Date, calendar cal: Calendar) -> WidgetSnapshot {
        var s = base(kind: WidgetKinds.digest.kind, meetings: [], now: now, calendar: cal)
        s.health = WidgetSnapshot.Health()
        s.busyDays = []
        switch name {
        case "mailHelperOff":
            s.content = .mailHelperOff
            s.accounts = []
            return s
        case "digestNone":
            s.accounts = []
            return s
        default:
            break
        }
        var digest = FixtureDigest.snapshot()
        switch name {
        case "digestAllRead":
            for i in digest.sections.indices { digest.sections[i].read = true }
        case "digestLargeText":
            s.style.textSize = WidgetStyle.TextSize.large.key
        case "digestAtlas":
            // Model Atlas's weekly box (D-054), this week's report not opened yet.
            s.atlas = FixtureAtlas.box(report: "2026-10-17", fresh: true, alerts: [])
        case "digestMany":
            let extra: [(String, String, String, Bool)] = [
                ("00000000-0000-4000-8000-0000000000B1", "avery@lanternhall.example", "Members get early booking for the winter season", true),
                ("00000000-0000-4000-8000-0000000000B2", "avery@moonbase-outfitters.example", "Your saved boots are back in stock", false),
                ("00000000-0000-4000-8000-0000000000B3", "avery@cometchords.example", "Rehearsal room moves to Studio 2", false),
                ("00000000-0000-4000-8000-0000000000B4", "avery@parcelwing.example", "Two parcels arrive on Wednesday", false),
            ]
            for (id, email, text, pick) in extra {
                digest.boxes.append(.init(account: id, label: email, counts: ["newsletters": 1],
                                          top: [.init(text: text, section: "newsletters", pick: pick ? true : nil)]))
            }
            if let i = digest.sections.firstIndex(where: { $0.key == "newsletters" }) { digest.sections[i].count += extra.count }
            digest.total += extra.count
        case "digestAtlasOld":
            // Seven mailboxes and a Model Atlas report nine days old, opened already, with an alert: it keeps its place
            // when mailboxes spill into "+N more", and dims.
            for (id, email, text) in [("00000000-0000-4000-8000-0000000000B1", "avery@lanternhall.example", "Members get early booking"),
                                      ("00000000-0000-4000-8000-0000000000B2", "avery@moonbase-outfitters.example", "Boots back in stock"),
                                      ("00000000-0000-4000-8000-0000000000B3", "avery@cometchords.example", "Rehearsal room moves"),
                                      ("00000000-0000-4000-8000-0000000000B4", "avery@parcelwing.example", "Two parcels on Wednesday")] {
                digest.boxes.append(.init(account: id, label: email, counts: ["newsletters": 1], top: [.init(text: text, section: "newsletters")]))
            }
            if let i = digest.sections.firstIndex(where: { $0.key == "newsletters" }) { digest.sections[i].count += 4 }
            digest.total += 4
            s.atlas = FixtureAtlas.box(report: "2026-10-10", fresh: false,
                                       alerts: ["Backups growing: the night copy of node-b holds 6.5 GB of models"])
        default:
            break
        }
        let ids = Set(digest.boxes.map(\.account))
        s.accounts = FixtureAccounts.snapshotAccounts.filter { ids.contains($0.id) }
        s.digest = digest
        return s
    }
    #endif

    #if YC_DEV_TOOLS
    /// Model Atlas's weekly box (D-054) for the Moonfield desk: invented models and machines only.
    enum FixtureAtlas {
        static let lines: [WidgetSnapshot.Atlas.Line] = [
            .init(text: "New: Pickle-7B reads handwriting well and runs on a 16 GB Mac.", kind: "new"),
            .init(text: "Try: a smaller speech model in Deck; it could free 2.1 GB.", kind: "try"),
            .init(text: "Fixed: model files are out of the nightly backups.", kind: "fixed"),
            .init(text: "Waiting on you: 1.2 GB of unused models on the Mac.", kind: "waiting on you"),
            .init(text: "Buy pick: a mini PC with 64 GB before the 32 GB laptop upgrade.", kind: "buy pick"),
        ]

        static func box(report: String, fresh: Bool, alerts: [String]) -> WidgetSnapshot.Atlas {
            WidgetSnapshot.Atlas(report: report, lines: lines, alerts: alerts, models: 24, fresh: fresh ? true : nil)
        }
    }
    #endif

    /// The busy week for a kind, as the data layer publishes it with mail on: Inbox and Agenda &
    /// Inbox carry the sample inbox (14 threads, 7 unread, 2 starred); Custom A–F are a mix of set-up
    /// slots (A "Work" agenda for ORB + FAM, B month, C up next, D "Band" agenda for CMT) and two not set up.
    /// `mailComingSoon` is the mail-off state.
    static func busy(kind: String, now: Date? = nil, calendar: Calendar? = nil) -> WidgetSnapshot {
        let cal = calendar ?? self.calendar
        let n = now ?? self.now
        #if YC_DEV_TOOLS
        if kind == WidgetKinds.digest.kind { return digestFixture("busy", now: n, calendar: cal) }
        #endif
        var s = base(kind: kind, meetings: FixtureWeek.busy(now: n, calendar: cal), now: n, calendar: cal)
        let wednesday = DayName.posixDay(cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: n))!, calendar: cal)
        switch kind {
        case "inbox.all":
            s.meetings = []
            s.mail = FixtureMail.snapshotRows(now: n, calendar: cal)
            s.unreadCount = FixtureMail.unread
        case "combo.all":
            s.mail = FixtureMail.snapshotRows(now: n, calendar: cal)
            s.unreadCount = FixtureMail.unread
        case "month":
            s.selectedDay = wednesday
        case "custom.a":
            let keep: Set<UUID> = [FixtureAccounts.orb, FixtureAccounts.fam]
            s.title = "Work"
            s.meetings = FixtureWeek.busy(now: n, calendar: cal).filter { keep.contains($0.accounts[0]) }.map(\.snapshotRow)
            s.accounts = FixtureAccounts.snapshotAccounts.filter { keep.contains(UUID(uuidString: $0.id)!) }
        case "custom.b":
            s.content = .month
            s.title = "Planning"
            s.selectedDay = wednesday
        case "custom.c":
            s.content = .upNext
        case "custom.d":
            let cmt = FixtureAccounts.cmt
            s.title = "Band"
            s.meetings = FixtureWeek.busy(now: n, calendar: cal).filter { $0.accounts.contains(cmt) }.map(\.snapshotRow)
            s.accounts = FixtureAccounts.snapshotAccounts.filter { $0.id == cmt.uuidString }
        case "custom.e", "custom.f":
            s.content = .setup
            s.meetings = []
        default:
            break
        }
        return s.content == .day ? dayOnly(s, calendar: cal) : s
    }

    static func base(kind: String, meetings: [FixtureMeeting], now: Date, calendar: Calendar) -> WidgetSnapshot {
        let content: WidgetSnapshot.Content
        switch WidgetKinds.spec(kind)?.content {
        case .upNext?: content = .upNext
        case .month?: content = .month
        case .inbox?: content = .inbox
        case .combo?: content = .combo
        case .day?: content = .day
        case .digest?: content = .digest
        default: content = .agenda
        }
        let rows = meetings.sorted { ($0.start, $0.r) < ($1.start, $1.r) }.prefix(WidgetSnapshot.maxMeetings).map(\.snapshotRow)
        let busy = Set(meetings.map { DayName.posixDay($0.start, calendar: calendar) }).sorted()
        let (start, end) = window(now: now, calendar: calendar)
        return WidgetSnapshot(kind: kind, generatedAt: now.addingTimeInterval(-60), content: content, title: nil,
                              style: WidgetSnapshot.Style(), accounts: FixtureAccounts.snapshotAccounts,
                              health: .init(state: .ok, accountId: nil, k: nil, syncedAt: now.addingTimeInterval(-3 * 60)),
                              meetings: Array(rows), mail: [], unreadCount: nil, pages: [:], pageResetAt: nil,
                              selectedDay: nil, monthShown: nil, busyDays: busy,
                              windowStart: DayName.posixDay(start, calendar: calendar),
                              windowEnd: DayName.posixDay(end, calendar: calendar), rangeDays: 7)
    }

    /// The sync window: start of this month's grid → end of the month containing +60 days.
    static func window(now: Date, calendar: Calendar) -> (Date, Date) {
        let monthStart = calendar.dateInterval(of: .month, for: now)!.start
        let lead = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -lead, to: monthStart)!
        let later = calendar.date(byAdding: .day, value: 60, to: now)!
        let lastMonth = calendar.dateInterval(of: .month, for: later)!
        return (gridStart, calendar.date(byAdding: .day, value: -1, to: lastMonth.end)!)
    }

    /// Every CalendarEvent of a fixture (Event Peek, Day Peek, the Calendar section).
    static func events(_ name: String = "busy", now: Date? = nil, calendar: Calendar? = nil) -> [CalendarEvent] {
        let cal = calendar ?? self.calendar
        switch name {
        case "sparse": return FixtureWeek.sparse(now: now ?? self.now, calendar: cal).map(\.event)
        case "dst": return FixtureWeek.dst(now: now ?? dstNow, calendar: cal).map(\.event)
        case "empty": return []
        default: return FixtureWeek.busy(now: now ?? self.now, calendar: cal).map(\.event)
        }
    }

    // MARK: JSON (the widget's own read path)

    static func json(_ snapshot: WidgetSnapshot) -> Data { (try? WidgetSnapshot.encoder.encode(snapshot)) ?? Data() }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        guard let s = try? WidgetSnapshot.decoder.decode(WidgetSnapshot.self, from: data), s.v <= WidgetSnapshot.version else { return nil }
        return s
    }

    /// Through JSON and back, as the widget would read it from `widget/<kind>.json`.
    static func roundTrip(_ snapshot: WidgetSnapshot) -> WidgetSnapshot? { decode(json(snapshot)) }
}

extension DayName {
    /// `YYYY-MM-DD` in an explicit calendar's time zone (fixtures must not depend on the Mac's zone).
    static func posixDay(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

#if YC_DEV_TOOLS
// MARK: - Fakes

/// CalendarStore + CalendarActions over fixture events. Records RSVPs and syncs; can be told to fail.
final class FakeCalendarStore: CalendarStore, CalendarActions {
    var allEvents: [CalendarEvent]
    var rsvpError: Error?
    var loadError: Error?
    private(set) var rsvps: [(r: String, response: CalendarEvent.Response)] = []
    private(set) var syncs = 0

    init(events: [CalendarEvent] = SnapshotFixtures.events()) { allEvents = events }

    func events(from: Date, to: Date, accounts: Set<UUID>?) throws -> [CalendarEvent] {
        if let loadError { throw loadError }
        return allEvents.filter { $0.end > from && $0.start < to }
            .filter { e in accounts.map { set in e.accountIds.contains { set.contains($0) } } ?? true }
            .sorted { ($0.start, $0.r) < ($1.start, $1.r) }
    }

    func event(r: String) throws -> CalendarEvent? {
        if let loadError { throw loadError }
        return allEvents.first { $0.r == r }
    }

    func rsvp(r: String, response: CalendarEvent.Response) async throws {
        rsvps.append((r, response))
        if let rsvpError { throw rsvpError }
        if let i = allEvents.firstIndex(where: { $0.r == r }) { allEvents[i].myResponse = response }
    }

    func syncNow() async { syncs += 1 }
}

final class FakeWidgetSettingsStore: WidgetSettingsStore {
    var stored: [String: WidgetSettings] = [:]
    var saveError: Error?
    private(set) var saves: [WidgetSettings] = []

    func settings(kind: String) -> WidgetSettings { stored[kind] ?? WidgetSettings(kind: kind) }

    func save(_ settings: WidgetSettings) throws {
        if let saveError { throw saveError }
        saves.append(settings)
        stored[settings.kind] = settings
    }
}

/// Records every interaction; `verify` checks fixture link keys.
final class FakeWidgetInteractions: WidgetInteractions {
    private(set) var calls: [String] = []
    private(set) var flushes = 0

    func page(kind: String, family: String, to page: Int) { calls.append("page \(kind) \(family) \(page)") }
    func selectDay(kind: String, day: String) { calls.append("day \(kind) \(day)") }
    func showMonth(kind: String, month: String) { calls.append("month \(kind) \(month)") }
    func setRange(kind: String, days: Int) { calls.append("range \(kind) \(days)") }
    func flushChanged() { flushes += 1 }
    func verify(r: String, k: String) -> Bool { FixtureLinkKeys.verify(r: r, k: k) }
}

/// Points every seam at fixtures (renders; tests build their own).
enum FixtureServices {
    @discardableResult
    static func install(events: [CalendarEvent] = SnapshotFixtures.events(),
                        directory: AccountDirectory = FixtureAccounts.directory()) -> (FakeCalendarStore, FakeWidgetSettingsStore, FakeWidgetInteractions) {
        let calendar = FakeCalendarStore(events: events)
        let settings = FakeWidgetSettingsStore()
        let interactions = FakeWidgetInteractions()
        Services.calendar = calendar
        Services.calendarActions = calendar
        Services.widgetSettings = settings
        Services.widgetInteractions = interactions
        AccountDirectory.current = { directory }
        return (calendar, settings, interactions)
    }
}
#endif

// MARK: - Mail

/// One fixture thread: the inbox row, its messages, and the widget snapshot row, from one source.
struct FixtureThread {
    var thread: MailThread
    var messages: [MailMessage]

    var snapshotRow: WidgetSnapshot.Mail {
        WidgetSnapshot.Mail(r: thread.r, k: fixtureLinkKey(thread.r), accountId: thread.accountId.uuidString,
                            sender: thread.sender, subject: thread.subject, at: thread.at, unread: thread.unread,
                            starred: thread.starred)
    }
}

/// The sample inbox (WidgetSample.week's mail), as the data layer would carry it: Gmail
/// threads with stable ids, messages (plain text, HTML with remote images, a three-message thread),
/// attachments, two starred threads, seven unread. Addresses use `.example` domains only.
enum FixtureMail {
    static let unread = 7

    /// The user's own addresses (one per fixture account): with "Ask before sending to other people" on, any
    /// other address needs the approval card first (D-023).
    static var ownAddresses: [String] { FixtureAccounts.all.map(\.email) }

    static func threads(now: Date = SnapshotFixtures.now, calendar: Calendar = SnapshotFixtures.calendar) -> [FixtureThread] {
        let anchor = calendar.startOfDay(for: now)
        func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
            calendar.date(bySettingHour: h, minute: m, second: 0, of: calendar.date(byAdding: .day, value: day, to: anchor)!)!
        }
        let orb = FixtureAccounts.orb, cmt = FixtureAccounts.cmt, fam = FixtureAccounts.fam, me = FixtureAccounts.home
        func address(_ account: UUID) -> String { FixtureAccounts.all.first { $0.id == account }!.email }
        var out: [FixtureThread] = []

        func thread(_ r: String, _ account: UUID, _ sender: String, _ email: String, _ subject: String, _ snippet: String,
                    _ when: Date, unread: Bool, starred: Bool = false, messages: [MailMessage]) {
            out.append(FixtureThread(
                thread: MailThread(r: r, accountId: account, sender: sender, senderEmail: email, subject: subject,
                                   snippet: snippet, at: when, unread: unread, starred: starred, messageCount: messages.count),
                messages: messages))
        }
        func message(_ id: String, _ from: String, _ email: String, to: [String], cc: [String] = [], _ when: Date,
                     _ subject: String, text: String, html: String? = nil, remote: Bool = false,
                     attachments: [MailMessage.Attachment] = []) -> MailMessage {
            MailMessage(id: id, from: from, fromEmail: email, to: to, cc: cc, date: when, subject: subject, html: html,
                        text: text, hasRemoteImages: remote, attachments: attachments)
        }

        // Today.
        let miloLast = """
        Hi Avery,

        Thanks for the quick fixes. Two things left before Tuesday:

        1. The bridge on track 3 still clips on the loud take.
        2. The fade-out on the closer is on; it should be off.

        I put both on the checklist (attached). Shall we walk through it at 11?

        Milo
        """
        thread("th-milo", cmt, "Milo Brightwater", "milo@quietcomets.example", "Re: mix notes before Tuesday",
               "Thanks for the quick fixes. Two things left before Tuesday…", at(0, 9, 41), unread: true, starred: true,
               messages: [
                message("m-milo-1", "Milo Brightwater", "milo@quietcomets.example", to: [address(cmt)], at(-1, 15, 10),
                        "Mix notes before Tuesday",
                        text: "Hi Avery,\n\nI went through the rough mix this afternoon. Notes below; nothing scary.\n\nMilo"),
                message("m-milo-2", Cast.ownerName, address(cmt), to: ["milo@quietcomets.example"], at(-1, 17, 2),
                        "Re: Mix notes before Tuesday",
                        text: "Thanks Milo, fixed the vocal levels and the delay on the bridge. Have another listen when you can."),
                message("m-milo-3", "Milo Brightwater", "milo@quietcomets.example", to: [address(cmt)], cc: ["wren@quietcomets.example"],
                        at(0, 9, 41), "Re: Mix notes before Tuesday", text: miloLast,
                        html: """
                        <div style="font-family:-apple-system,Helvetica,sans-serif;font-size:14px;line-height:1.5">
                        <p>Hi Avery,</p><p>Thanks for the quick fixes. Two things left before Tuesday:</p>
                        <ol><li>The bridge on track 3 still clips on the loud take.</li>
                        <li>The fade-out on the closer is on; it should be off.</li></ol>
                        <p>I put both on the checklist (attached). Shall we walk through it at 11?</p>
                        <p><img src="https://images.quietcomets.example/signature/milo.png" width="120" height="32" alt="The Quiet Comets"></p>
                        <p>Milo · <a href="https://www.quietcomets.example">quietcomets.example</a></p></div>
                        """, remote: true, attachments: [.init(name: "Mix checklist.pdf", bytes: 186_420)]),
               ])
        thread("th-jingle", orb, "Orbital Pickle Co.", "team@orbitalpickle.example", "Agenda for today's weekly",
               "Here's the agenda for today at 2 PM: last week's numbers, the jingle plan…", at(0, 9, 12), unread: true,
               messages: [
                message("m-jingle", "Orbital Pickle Co.", "team@orbitalpickle.example", to: [address(orb)], at(0, 9, 12),
                        "Agenda for today's weekly",
                        text: "Hi all,\n\nHere's the agenda for today at 2 PM:\n1. Last week's numbers\n2. The jingle plan\n3. Open questions\n\nThe deck is attached.\n\nOrbital Pickle team",
                        html: """
                        <div style="font-family:Georgia,serif;font-size:15px;line-height:1.55">
                        <p><img src="https://cdn.orbitalpickle.example/mail/header.png" width="560" height="80" alt="Orbital Pickle Co."></p>
                        <p>Hi all,</p><p>Here's the agenda for today at 2 PM:</p>
                        <ol><li>Last week's numbers</li><li>The jingle plan</li><li>Open questions</li></ol>
                        <p>The deck is attached. <a href="https://orbitalpickle.example/weekly">Open the shared folder</a>.</p>
                        <p>Orbital Pickle team</p></div>
                        """, remote: true, attachments: [.init(name: "Jingle plan.pptx", bytes: 2_431_000)]),
               ])
        thread("th-photos", fam, "Photo Backup", "noreply@photobackup.example", "Your import finished: 2,318 photos",
               "Your photo import is complete. 2,318 photos were added or updated.", at(0, 8, 55), unread: false,
               messages: [
                message("m-photos", "Photo Backup", "noreply@photobackup.example", to: [address(fam)], at(0, 8, 55),
                        "Your import finished: 2,318 photos",
                        text: "Your photo import is complete.\n2,318 photos were added or updated, 4 were skipped.",
                        html: "<p><img src=\"https://static.photobackup.example/logo.png\" width=\"96\" alt=\"Photo Backup\"></p><p>Your photo import is complete.</p><p><b>2,318</b> photos were added or updated, 4 were skipped.</p>",
                        remote: true),
               ])
        thread("th-rafa", me, "Rafa", "rafa@pebblepost.example", "Still on for lunch? 🍕",
               "Café Nowhere at 1? I'll grab a table by the window.", at(0, 8, 30), unread: true,
               messages: [
                message("m-rafa", "Rafa", "rafa@pebblepost.example", to: [address(me)], at(0, 8, 30), "Still on for lunch? 🍕",
                        text: "Café Nowhere at 1? I'll grab a table by the window.\n\nR."),
               ])
        thread("th-juniper", orb, "Juniper Vale", "juniper@orbitalpickle.example", "Can we move our 1:1 to Wednesday?",
               "Something came up on Tuesday afternoon. Wednesday 3:30 works for me if it does for you.", at(0, 8, 2), unread: true,
               messages: [
                message("m-juniper", "Juniper Vale", "juniper@orbitalpickle.example", to: [address(orb)], at(0, 8, 2),
                        "Can we move our 1:1 to Wednesday?",
                        text: "Hi Avery,\n\nSomething came up on Tuesday afternoon. Wednesday 3:30 works for me if it does for you.\n\nJuniper"),
               ])
        thread("th-gig-report", cmt, "The Quiet Comets", "news@quietcomets.example", "October gig report is ready",
               "Your October gig report is ready to review.", at(0, 7, 15), unread: false,
               messages: [
                message("m-gig-report", "The Quiet Comets", "news@quietcomets.example", to: [address(cmt)], at(0, 7, 15),
                        "October gig report is ready", text: "Your October gig report is ready to review.",
                        html: "<h3>October gig report</h3><p>Your report is ready to review. Tickets sold: <b>38 of 40</b>.</p>"),
               ])
        // Yesterday.
        thread("th-sasha", fam, "Sasha", "sasha@moonfield-family.example", "Holiday plan, v3",
               "Tightened the timeline slide and added the packing list.", at(-1, 22, 10), unread: true,
               messages: [
                message("m-sasha", "Sasha", "sasha@moonfield-family.example", to: [address(fam)], at(-1, 22, 10), "Holiday plan, v3",
                        text: "Tightened the timeline slide and added the packing list. Shout if anything looks off.\n\nS",
                        attachments: [.init(name: "Holiday plan v3.key", bytes: 8_120_000)]),
               ])
        thread("th-phone", me, "Paper Cup Mobile", "bills@papercup.example", "Your bill is ready",
               "Your October bill is ready.", at(-1, 19, 0), unread: false,
               messages: [
                message("m-phone", "Paper Cup Mobile", "bills@papercup.example", to: [address(me)], at(-1, 19, 0), "Your bill is ready",
                        text: "Your October bill is ready.",
                        html: "<p><img src=\"https://img.papercup.example/brand.png\" alt=\"Paper Cup Mobile\"></p><p>Your October bill is ready.</p>",
                        remote: true),
               ])
        thread("th-wiki", orb, "Pickle Wiki", "digest@wiki.orbitalpickle.example", "Weekly digest: 14 updates",
               "14 updates across 3 spaces this week.", at(-1, 17, 45), unread: false,
               messages: [
                message("m-wiki", "Pickle Wiki", "digest@wiki.orbitalpickle.example", to: [address(orb)], at(-1, 17, 45), "Weekly digest: 14 updates",
                        text: "14 updates across 3 spaces this week.",
                        html: "<p>14 updates across <b>3 spaces</b> this week.</p>"),
               ])
        thread("th-lantern", cmt, "Lantern Hall", "bea@lanternhall.example", "Thanks for the call!",
               "Great to meet you both. Sending the booking form over by Thursday.", at(-1, 16, 20), unread: true, starred: true,
               messages: [
                message("m-lantern", "Bea Lantern", "bea@lanternhall.example", to: [address(cmt)], cc: ["milo@quietcomets.example"],
                        at(-1, 16, 20), "Thanks for the call!",
                        text: "Great to meet you both. Sending the booking form over by Thursday.\n\nBea\nLantern Hall"),
               ])
        thread("th-parcel", fam, "Snail Parcel", "tracking@snailparcel.example", "Your parcel is on its way",
               "Your parcel is on its way to the front door.", at(-1, 12, 5), unread: false,
               messages: [
                message("m-parcel", "Snail Parcel", "tracking@snailparcel.example", to: [address(fam)], at(-1, 12, 5), "Your parcel is on its way",
                        text: "Your parcel is on its way to the front door. It usually arrives in 2 business days."),
               ])
        thread("th-mom", me, "Mom", "mom@pebblepost.example", "Photos from Saturday 📸",
               "The good ones, finally. The blurry ones are a feature.", at(-1, 11, 30), unread: true,
               messages: [
                message("m-mom", "Mom", "mom@pebblepost.example", to: [address(me)], at(-1, 11, 30), "Photos from Saturday 📸",
                        text: "The good ones, finally. The blurry ones are a feature.",
                        attachments: [.init(name: "IMG_2041.jpg", bytes: 3_210_000), .init(name: "IMG_2044.jpg", bytes: 2_980_000)]),
               ])
        thread("th-gcal", orb, "Google Calendar", "calendar-notification@google.example", "Invitation: All hands, Mon 26 Oct",
               "You have been invited to All hands, Monday 26 October, 4 – 5 PM.", at(-1, 10, 0), unread: false,
               messages: [
                message("m-gcal", "Google Calendar", "calendar-notification@google.example", to: [address(orb)], at(-1, 10, 0),
                        "Invitation: All hands, Mon 26 Oct",
                        text: "You have been invited to All hands, Monday 26 October, 4 – 5 PM.",
                        attachments: [.init(name: "invite.ics", bytes: 2_140)]),
               ])
        // Two days ago.
        thread("th-gigboard", cmt, "Gig Board", "digest@gigboard.example", "Your band appeared in 41 searches",
               "See who's been looking this week.", at(-2, 9, 0), unread: false,
               messages: [
                message("m-gigboard", "Gig Board", "digest@gigboard.example", to: [address(cmt)], at(-2, 9, 0),
                        "Your band appeared in 41 searches", text: "See who's been looking this week."),
               ])
        return out
    }

    static func snapshotRows(now: Date = SnapshotFixtures.now, calendar: Calendar = SnapshotFixtures.calendar) -> [WidgetSnapshot.Mail] {
        threads(now: now, calendar: calendar).map(\.snapshotRow).sorted { $0.at > $1.at }
    }
}

#if YC_DEV_TOOLS
/// MailStore over fixture threads. `FakeMailActions` changes it the way the data layer would.
final class FakeMailStore: MailStore {
    var fixtures: [FixtureThread]
    /// Threads archived or trashed (out of the inbox, still undoable).
    private(set) var removed: [String: FixtureThread] = [:]
    var loadError: Error?
    var messagesError: Error?
    private(set) var messageReads: [String] = []

    init(threads: [FixtureThread] = FixtureMail.threads()) { fixtures = threads }

    func threads(accounts: Set<UUID>?, limit: Int) throws -> [MailThread] {
        if let loadError { throw loadError }
        return Array(fixtures.map(\.thread)
            .filter { t in accounts.map { $0.contains(t.accountId) } ?? true }
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.r < $1.r }
            .prefix(limit))
    }

    func thread(r: String) throws -> MailThread? {
        if let loadError { throw loadError }
        return fixtures.first { $0.thread.r == r }?.thread
    }

    func messages(threadR: String) async throws -> [MailMessage] {
        messageReads.append(threadR)
        if let messagesError { throw messagesError }
        return (fixtures.first { $0.thread.r == threadR } ?? removed[threadR])?.messages ?? []
    }

    func unreadCount(accounts: Set<UUID>?) throws -> Int {
        try threads(accounts: accounts, limit: .max).filter(\.unread).count
    }

    // Changes made by FakeMailActions.
    func update(_ r: String, _ change: (inout MailThread) -> Void) {
        guard let i = fixtures.firstIndex(where: { $0.thread.r == r }) else { return }
        change(&fixtures[i].thread)
    }

    func remove(_ r: String) {
        guard let i = fixtures.firstIndex(where: { $0.thread.r == r }) else { return }
        removed[r] = fixtures.remove(at: i)
    }

    func restore(_ r: String) {
        guard let t = removed.removeValue(forKey: r) else { return }
        fixtures.append(t)
    }
}

/// MailActions over a FakeMailStore. Records every call; can be told to fail; sends can be refused the
/// way the data layer's SAFE_SEND does.
final class FakeMailActions: MailActions {
    let store: FakeMailStore
    var error: Error?
    var sendError: Error?
    private(set) var calls: [String] = []
    private(set) var sent: [MailDraft] = []
    private(set) var cancelled: [UndoToken] = []
    private var undoable: [String: String] = [:]   // token id → r

    init(store: FakeMailStore) { self.store = store }

    func markRead(r: String, _ read: Bool) async throws {
        calls.append("read \(r) \(read)")
        if let error { throw error }
        store.update(r) { $0.unread = !read }
    }

    func star(r: String, _ starred: Bool) async throws {
        calls.append("star \(r) \(starred)")
        if let error { throw error }
        store.update(r) { $0.starred = starred }
    }

    func archive(r: String) async throws -> UndoToken {
        calls.append("archive \(r)")
        if let error { throw error }
        store.remove(r)
        let token = UndoToken(id: "archive-\(r)-\(calls.count)")
        undoable[token.id] = r
        return token
    }

    func trash(r: String) async throws -> UndoToken {
        calls.append("trash \(r)")
        if let error { throw error }
        store.remove(r)
        let token = UndoToken(id: "trash-\(r)-\(calls.count)")
        undoable[token.id] = r
        return token
    }

    func undo(_ token: UndoToken) async throws {
        calls.append("undo \(token.id)")
        if let error { throw error }
        if let r = undoable.removeValue(forKey: token.id) { store.restore(r) }
    }

    func send(_ draft: MailDraft) async throws -> UndoToken {
        calls.append("send")
        if let sendError { throw sendError }
        sent.append(draft)
        return UndoToken(id: "send-\(sent.count)")
    }

    func cancelSend(_ token: UndoToken) async throws {
        calls.append("cancel \(token.id)")
        cancelled.append(token)
    }
}

/// MailPreferencesStore in memory (Primary-only, signatures, the image allow list, the correspondents clear).
final class FakeMailPreferences: MailPreferencesStore, MailImageAllowListing, MailCorrespondentForgetting {
    var stored: [UUID: MailAccountPrefs] = [:]
    var allowed: Set<String> = []
    var saveError: Error?
    private(set) var saves: [(UUID, MailAccountPrefs)] = []
    /// "Images from people you've written to": the recorded addresses, and what each clear saw.
    var correspondents: Set<String> = []
    var forgetError: Error?
    var onForget: (() -> Void)?
    private(set) var forgets = 0

    init(signatures: Bool = true) {
        guard signatures else { return }
        stored[FixtureAccounts.orb] = MailAccountPrefs(primaryOnly: false, signature: "Avery Moonfield\nOrbital Pickle Co.")
        stored[FixtureAccounts.cmt] = MailAccountPrefs(primaryOnly: false, signature: "Avery\nThe Quiet Comets")
        stored[FixtureAccounts.home] = MailAccountPrefs(primaryOnly: true, signature: "")
    }

    func prefs(account: UUID) -> MailAccountPrefs { stored[account] ?? MailAccountPrefs(primaryOnly: false, signature: "") }

    func save(account: UUID, _ prefs: MailAccountPrefs) throws {
        if let saveError { throw saveError }
        saves.append((account, prefs))
        stored[account] = prefs
    }

    func allowsImages(from sender: String) -> Bool { allowed.contains(sender.lowercased()) }

    func setAllowsImages(from sender: String, _ allowed: Bool) throws {
        if let saveError { throw saveError }
        if allowed { self.allowed.insert(sender.lowercased()) } else { self.allowed.remove(sender.lowercased()) }
    }

    func allowedImageSenders() -> [String] { allowed.sorted() }

    func forgetCorrespondents() throws {
        onForget?()
        if let forgetError { throw forgetError }
        forgets += 1
        correspondents.removeAll()
    }
}

extension FixtureServices {
    /// Points the mail seams at fixtures (renders; tests build their own).
    @discardableResult
    static func installMail(threads: [FixtureThread] = FixtureMail.threads()) -> (FakeMailStore, FakeMailActions, FakeMailPreferences) {
        let store = FakeMailStore(threads: threads)
        let actions = FakeMailActions(store: store)
        let prefs = FakeMailPreferences()
        Services.mail = store
        Services.mailActions = actions
        Services.mailPreferences = prefs
        return (store, actions, prefs)
    }
}
#endif
