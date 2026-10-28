import AppKit
import Foundation

/// widget/<kind>.json → the shared design models (SnapshotModel), states, style, and the committed JSON
/// fixtures (Tests/Fixtures) the data layer's writer must keep decoding.
enum SnapshotTests {
    static let cal = WidgetCalendar.fixed
    static let now = WidgetSample.fixedNow
    static let orb = FixtureAccounts.orb.uuidString
    static let cmt = FixtureAccounts.cmt.uuidString

    static func run() {
        mapping()
        mail()
        states()
        health()
        style()
        effective()
        committedJSON()
    }

    static func mapping() {
        T.section("snapshot → model: busy week through JSON")
        let built = SnapshotFixtures.busy(kind: "agenda.all")
        guard let snap = SnapshotFixtures.roundTrip(built) else { T.check(false, "busy fixture decodes"); return }
        T.equal(snap, built, "JSON round trip is lossless")
        T.check(SnapshotFixtures.json(built).count < WidgetSnapshot.maxBytes, "busy fixture under 192 KB")
        T.equal(snap.contentHash, built.contentHash, "content hash survives JSON")
        var later = built; later.generatedAt = later.generatedAt.addingTimeInterval(600)
        T.equal(later.contentHash, built.contentHash, "generatedAt is outside the content hash")

        var logoCalls: [String] = []
        let orbLogo = NSImage(size: NSSize(width: 4, height: 4))
        let model = SnapshotModel(snap, logo: { id in logoCalls.append(id); return id == orb ? orbLogo : nil })
        T.equal(model.accountList.map(\.short), ["ORB", "CMT", "FAM", "Personal"], "accounts in the user's order")
        T.equal(model.accounts[orb]?.color, Int(Cast.orb.color), "account colour carried")
        T.equal(model.accounts[orb]?.name, "Orbital Pickle Co.", "account name carried")
        T.check(model.accounts[orb]?.logo === orbLogo, "logo loaded for an account with hasLogo")
        T.check(model.accounts[cmt]?.logo == nil, "missing logo file = no badge")
        T.check(!logoCalls.contains(FixtureAccounts.home.uuidString), "hasLogo false never touches the disk")
        T.equal(logoCalls.count, 3, "each logo loaded once per snapshot")

        T.equal(model.meetings.count, snap.meetings.count, "every meeting mapped")
        var ok = true
        for (m, row) in zip(model.meetings, snap.meetings) {
            if m.r != row.r || m.k != row.k || m.title != row.title || m.start != row.start || m.end != row.end
                || m.allDay != row.allDay || m.hasLink != row.hasJoin || m.place != row.place || m.accountIds != row.accountIds
                || m.clashes != row.clashes { ok = false; T.check(false, "row \(row.r) mapped field by field") }
        }
        T.check(ok, "r, k, title, times, all-day, join, place, accounts and clashes carried for every row")
        T.equal(model.meetings.map(\.id), Array(1...model.meetings.count), "row positions 1…n")

        let merged = model.meetings.first { $0.r == "grp-jingle" }
        T.equal(merged?.accountsLabel, "ORB+CMT", "merged invite shows ORB+CMT")
        T.equal(merged?.account.short, "ORB", "merged invite: primary first")
        T.equal(merged?.also.map(\.short), ["CMT"], "merged invite: the other copy")
        T.equal(merged?.isMerged, true, "merged flag")
        T.equal(model.meetings.first { $0.title == "Family day out" }?.allDay, true, "all-day carried")
        T.equal(model.meetings.first { $0.title == "Album artwork walkthrough" }?.reply, .needsReply, "needsReply")
        T.equal(model.meetings.first { $0.title == "Design crit" }?.reply, .maybe, "maybe")
        T.equal(model.meetings.first { $0.title == "Gym" }?.reply, .accepted, "accepted")

        var odd = built
        odd.meetings[0].accountIds = ["not-a-known-account"]
        odd.meetings[1].accountIds = []
        let oddModel = SnapshotModel(odd, logo: { _ in nil })
        T.equal(oddModel.meetings[0].account.short, "", "unknown account: untagged row, no crash")
        T.equal(oddModel.meetings[1].account.id, "", "no account ids: untagged row")
        var backwards = built
        backwards.meetings[0].end = backwards.meetings[0].start.addingTimeInterval(-60)
        T.equal(SnapshotModel(backwards, logo: { _ in nil }).meetings[0].end, backwards.meetings[0].start, "end before start is clamped")
    }

    static func mail() {
        T.section("snapshot → model: mail rows")
        var s = SnapshotFixtures.base(kind: "inbox.all", meetings: [], now: now, calendar: cal)
        s.content = .inbox
        s.mail = [
            .init(r: "th1", k: FixtureLinkKeys.k("th1"), accountId: cmt, sender: "Milo Brightwater", subject: "Re: QA",
                  at: now.addingTimeInterval(-300), unread: true, starred: true),
            .init(r: "th2", k: FixtureLinkKeys.k("th2"), accountId: orb, sender: "Orbital Pickle Co.", subject: "Agenda",
                  at: now.addingTimeInterval(-3600), unread: false, starred: false),
        ]
        s.unreadCount = 7
        let model = SnapshotModel(SnapshotFixtures.roundTrip(s)!, logo: { _ in nil })
        T.equal(model.mail.map(\.r), ["th1", "th2"], "mail rows keep r")
        T.equal(model.mail.map(\.starred), [true, false], "starred carried")
        T.equal(model.mail.map(\.unread), [true, false], "unread carried")
        T.equal(model.mail.first?.account.short, "CMT", "mail account tag")
        T.equal(model.data(at: now).unreadCount, 7, "unread count from labels.get, not the rows")
        let ctx = WidgetLinkContext(kind: "inbox.all", family: .large)
        T.equal(Route.parse(ctx.mail(model.mail[0]))?.name, "open/message", "mail rows open the Mail Peek")
        T.equal(model.mail.map(\.archivedAt), [nil, nil], "archivedAt absent = nil (version-1 files still decode)")
    }

    static func states() {
        T.section("snapshot → model: whole-card states")
        func state(_ name: String, _ kind: String = "agenda.all") -> WidgetCardState {
            SnapshotModel(SnapshotFixtures.named(name, kind: kind), logo: { _ in nil }).data(at: now).state
        }
        T.equal(state("busy"), .content, "busy → design")
        T.equal(state("empty"), .content, "empty week → design (its own empty text)")
        T.equal(state("noAccounts"), .noAccounts, "no accounts → card")
        T.equal(state("setup", "custom.e"), .setup, "custom slot not set up → setup card")
        T.equal(state("mailComingSoon", "inbox.all"), .mailComingSoon, "the mail-off fixture → coming-soon card")
        T.equal(state("busy", "inbox.all"), .content, "mail on: Inbox draws the live design")
        T.equal(state("busy", "combo.all"), .content, "mail on: Agenda & Inbox draws the live design")
        T.equal(state("mailArchived", "inbox.all"), .content, "an Archived · Undo row is still the design")
        T.equal(state("inboxZero", "inbox.all"), .content, "inbox zero is the design (its own note)")
        var setupNoAccounts = SnapshotFixtures.named("noAccounts", kind: "custom.e")
        setupNoAccounts.content = .setup
        T.equal(SnapshotModel(setupNoAccounts, logo: { _ in nil }).cardState, .setup, "setup wins over noAccounts")
        T.equal(WidgetData.card(.noSnapshot, now: now).state, .noSnapshot, "no file on the desktop → hello card")

        T.section("snapshot → model: custom slots + family fallbacks")
        let a = SnapshotModel(SnapshotFixtures.busy(kind: "custom.a"), logo: { _ in nil }).data(at: now)
        T.equal(a.title, "Work", "custom title")
        T.equal(a.content, .agenda, "custom.a draws an agenda")
        T.equal(Set(a.meetings.map(\.account.short)), ["ORB", "FAM"], "custom.a only carries its accounts")
        let b = SnapshotModel(SnapshotFixtures.busy(kind: "custom.b"), logo: { _ in nil }).data(at: now)
        T.equal(b.content, .month, "custom.b draws a month")
        let c = SnapshotModel(SnapshotFixtures.busy(kind: "custom.c"), logo: { _ in nil }).data(at: now)
        let cSpec = WidgetKinds.spec("custom.c")!
        T.equal(KindView.resolve(spec: cSpec, family: .small, data: c), .design(.upNext), "Up Next slot, Small")
        T.equal(KindView.resolve(spec: cSpec, family: .large, data: c), .design(.agenda), "Up Next slot, Large → agenda")
        var combo = c; combo.content = .combo
        T.equal(KindView.resolve(spec: cSpec, family: .medium, data: combo), .design(.agenda), "combo slot, Medium → agenda")
        T.equal(KindView.resolve(spec: cSpec, family: .large, data: combo), .design(.combo), "combo slot, Large")
        var inbox = c; inbox.content = .inbox
        T.equal(KindView.resolve(spec: cSpec, family: .small, data: inbox), .inboxSmall, "inbox slot, Small → count card")
        let sample = WidgetSample.week(now: now, logos: nil, calendar: cal)
        T.equal(KindView.resolve(spec: WidgetKinds.custom[0], family: .large, data: sample), .card(.setup),
                "sample data in a custom slot → setup card (gallery)")
        T.equal(KindView.resolve(spec: WidgetKinds.month, family: .small, data: sample), .design(.month), "sample month")
        let busyTitle = SnapshotModel(SnapshotFixtures.busy(kind: "agenda.all"), logo: { _ in nil }).data(at: now).title
        T.equal(busyTitle, nil, "named kinds have no title")
        var blank = SnapshotFixtures.busy(kind: "custom.a"); blank.title = "   "
        T.equal(SnapshotModel(blank, logo: { _ in nil }).data(at: now).title, nil, "blank title = none")
    }

    static func health() {
        T.section("snapshot → model: health strip (computed from the entry date)")
        let reauth = SnapshotModel(SnapshotFixtures.named("reauth", kind: "agenda.all"), logo: { _ in nil })
        guard case .reauth(let tag, let link) = reauth.health.footer(at: now) else {
            T.check(false, "reauth fixture → amber strip"); return
        }
        T.equal(tag, "CMT", "strip names the account")
        let route = link.flatMap(Route.parse)
        T.equal(route?.name, "reauth", "strip links to reauth")
        T.equal(route?.params["a"], cmt, "reauth a = account id")
        T.check(route.map { FixtureLinkKeys.verify(r: $0.params["a"] ?? "", k: $0.params["k"] ?? "") } ?? false, "reauth k verifies")
        var noKey = SnapshotFixtures.named("reauth", kind: "agenda.all"); noKey.health.k = nil
        if case .reauth(let t, let l) = SnapshotModel(noKey, logo: { _ in nil }).health.footer(at: now) {
            T.equal(t, "CMT", "no key: strip still names the account")
            T.check(l == nil, "no key: strip has no link")
        } else { T.check(false, "no key: still a reauth strip") }

        let stale = SnapshotModel(SnapshotFixtures.named("stale", kind: "agenda.all"), logo: { _ in nil })
        T.equal(stale.health.footer(at: now), .stale("Last synced 2 h ago"), "stale fixture → Last synced 2 h ago")
        T.equal(stale.health.footer(at: now.addingTimeInterval(3600)), .stale("Last synced 3 h ago"), "text moves with the entry date")
        let busy = SnapshotModel(SnapshotFixtures.busy(kind: "agenda.all"), logo: { _ in nil })
        T.equal(busy.health.footer(at: now), .none, "synced 3 min ago → no strip")
        T.equal(busy.health.footer(at: now.addingTimeInterval(26 * 60)), .none, "29 min after sync → still no strip")
        T.equal(busy.health.footer(at: now.addingTimeInterval(28 * 60)), .stale("Last synced 31 min ago"),
                "31 min after sync → Last synced 31 min ago, even though the file said ok")
        var never = SnapshotFixtures.busy(kind: "agenda.all")
        never.health = .init(state: .stale, accountId: nil, k: nil, syncedAt: nil)
        T.equal(SnapshotModel(never, logo: { _ in nil }).health.footer(at: now), .stale("Not synced yet"), "stale, never synced")

        T.section("sync text")
        let base = now
        for (seconds, text) in [(0, "just now"), (59, "just now"), (60, "1 min ago"), (59 * 60, "59 min ago"), (3600, "1 h ago"),
                                (23 * 3600, "23 h ago"), (24 * 3600, "yesterday"), (48 * 3600, "2 days ago"), (-30, "just now")] {
            T.equal(SyncText.ago(base.addingTimeInterval(TimeInterval(-seconds)), now: base), text, "\(seconds) s")
        }

        T.section("footer strip leaves the rows alone")
        let style = WidgetStyle()
        let busyData = busy.data(at: now)
        let staleData = stale.data(at: now)
        let agenda = WidgetKinds.agenda
        let busyRows = KindView.meetingRows(spec: agenda, family: .large, data: busyData, style: style) ?? 0
        let staleRows = KindView.meetingRows(spec: agenda, family: .large, data: staleData, style: style) ?? 0
        T.check(busyRows >= 10, "busy fixture: Large page 1 shows ≥10 meetings (got \(busyRows))")
        T.check(staleRows >= busyRows - 1, "with the strip Large gives up at most one row (\(busyRows) → \(staleRows))")
        T.note("busy fixture page 1 meeting rows: Large \(busyRows), with a footer strip \(staleRows)")
    }

    static func style() {
        T.section("snapshot style → widget style")
        var s = WidgetSnapshot.Style()
        T.equal(WidgetStyle.from(s, dark: true).look, .ink, "auto + dark Mac → Dark")
        T.equal(WidgetStyle.from(s, dark: false).look, .paper, "auto + light Mac → Light")
        s.look = .paper
        T.equal(WidgetStyle.from(s, dark: true).look, .paper, "Light stays light on a dark Mac")
        s.look = .ink
        T.equal(WidgetStyle.from(s, dark: false).look, .ink, "Dark stays dark on a light Mac")
        s.typeface = "rounded"; s.textSize = "large"; s.showLogos = false; s.use24Hour = true
        let w = WidgetStyle.from(s, dark: false)
        T.equal(w.typeface, .rounded, "rounded")
        T.equal(w.textSize, .large, "large text")
        T.equal(w.showLogos, false, "logos off")
        T.equal(w.use24Hour, true, "24-hour clock")
        s.typeface = "comic"; s.textSize = "huge"
        T.equal(WidgetStyle.from(s, dark: false).typeface, .system, "unknown typeface → System")
        T.equal(WidgetStyle.from(s, dark: false).textSize, .standard, "unknown size → Standard")
        T.equal(WidgetStyle.Typeface.allCases.map(\.key), ["system", "rounded", "serif"], "typeface keys = Studio/snapshot spelling")
        T.equal(WidgetStyle.TextSize.allCases.map(\.key), ["small", "standard", "large"], "size keys")
        var mono = WidgetStyle(); mono.mono = true
        T.check(mono.palette.accent == mono.palette.text, "mono palette: accent = text colour")
        var ink = WidgetStyle(); ink.look = .ink; ink.mono = true
        T.check(ink.palette.accent == Palette.inkMono.accent, "mono dark palette")
        var window = WidgetStyle(); window.scaleOverride = 1.16; window.textSize = .small
        T.equal(window.scale, 1.16, "window scale overrides text size")
    }

    static func effective() {
        T.section("effective page / picked day / month / range (from the entry date)")
        var s = SnapshotFixtures.busy(kind: "agenda.all")
        s.pages = ["L": 3, "XL": 0]
        s.pageResetAt = now.addingTimeInterval(5 * 60)
        let m = SnapshotModel(s, logo: { _ in nil })
        T.equal(m.page(family: .large, at: now), 3, "page from the snapshot")
        T.equal(m.page(family: .large, at: now.addingTimeInterval(299)), 3, "just before pageResetAt")
        T.equal(m.page(family: .large, at: now.addingTimeInterval(300)), 1, "page 1 once pageResetAt passed")
        T.equal(m.page(family: .extraLarge, at: now), 1, "page 0 → 1")
        T.equal(m.page(family: .medium, at: now), 1, "missing family → 1")
        var noReset = s; noReset.pageResetAt = nil
        T.equal(SnapshotModel(noReset, logo: { _ in nil }).page(family: .large, at: now.addingTimeInterval(86_400)), 3, "no reset time → keep")

        var month = SnapshotFixtures.busy(kind: "month")
        let today = cal.startOfDay(for: now)
        let wednesday = cal.date(byAdding: .day, value: 2, to: today)!
        T.equal(SnapshotModel(month, logo: { _ in nil }).selectedDay(at: now), wednesday, "picked day from the snapshot")
        month.selectedDay = nil
        T.equal(SnapshotModel(month, logo: { _ in nil }).selectedDay(at: now), today, "nil picked day = today")
        month.selectedDay = "2026-02-30"
        T.equal(SnapshotModel(month, logo: { _ in nil }).selectedDay(at: now), today, "invalid day = today")
        month.selectedDay = "2026-10-21"
        month.monthShown = "2026-11"
        let mm = SnapshotModel(month, logo: { _ in nil })
        T.equal(DayName.linkMonth(mm.monthShown(at: now)), "2026-11", "month shown from the snapshot")
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!.addingTimeInterval(60)
        T.equal(mm.selectedDay(at: tomorrow), cal.startOfDay(for: tomorrow), "after midnight the picked day resets to today")
        T.equal(DayName.linkMonth(mm.monthShown(at: tomorrow)), "2026-10", "after midnight the month resets")
        T.equal(mm.pastMidnight(now.addingTimeInterval(3600)), false, "same day: no reset")
        month.monthShown = nil
        T.equal(DayName.linkMonth(SnapshotModel(month, logo: { _ in nil }).monthShown(at: now)), "2026-10", "nil month = the picked day's")

        let data = m.data(at: now)
        T.equal(data.windowStart.map(DayName.linkDay), "2026-09-28", "window starts on the month grid's first day (Monday)")
        T.equal(data.windowEnd.map(DayName.linkDay), "2026-12-31", "window ends with the month containing +60 days")
        T.equal(data.rangeDays, 7, "range from the snapshot")
        var odd = s; odd.rangeDays = 5
        T.equal(SnapshotModel(odd, logo: { _ in nil }).data(at: now).rangeDays, 7, "unknown range → week")
        var oneDay = data; oneDay.rangeDays = 1
        T.check(oneDay.agendaMeetings.allSatisfy { cal.isDate($0.start, inSameDayAs: now) }, "range Today keeps today only")
        var twoDays = data; twoDays.rangeDays = 2
        let latest = twoDays.agendaMeetings.map(\.start).max()!
        T.check(latest < cal.date(byAdding: .day, value: 2, to: today)!, "range 2 days stops before the day after tomorrow")
        var none = data; none.rangeDays = nil
        T.equal(none.agendaMeetings.count, data.meetings.count, "no range = everything")
        T.equal(Set(data.busyDays), Set(s.busyDays), "busy days carried for Month dots")

        T.section("link day parsing")
        T.check(DayName.parseDay("2026-10-21") == wednesday, "YYYY-MM-DD parses to the start of that day")
        for bad in ["2026-1-21", "2026-10-21x", "26-10-21", "2026-13-01", "2026-02-29", "", "2026/10/21", "２０２６-10-21"] {
            T.check(DayName.parseDay(bad) == nil, "rejects \(bad)")
        }
        T.check(DayName.parseDay("2028-02-29") != nil, "leap day parses")
        T.equal(DayName.parseMonth("2026-11").map(DayName.linkDay), "2026-11-01", "YYYY-MM parses to the 1st")
        T.check(DayName.parseMonth("2026-00") == nil, "month 00 rejected")
    }

    /// The committed files are the format contract with the data layer: if the builders change, the
    /// files must be regenerated (`Tests/.out/shell-tests --write-fixtures Tests/Fixtures`) and reviewed.
    static func committedJSON() {
        T.section("committed JSON fixtures (Tests/Fixtures) decode with the widget's reader")
        guard let folder = ProcessInfo.processInfo.environment["YC_FIXTURES"] else {
            T.check(false, "YC_FIXTURES not set (run via Tests/run-tests.sh)"); return
        }
        for (name, kind) in fixtureFiles {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(kind).json")
            guard let data = try? Data(contentsOf: url) else { T.check(false, "missing \(url.lastPathComponent)"); continue }
            guard let decoded = SnapshotFixtures.decode(data) else { T.check(false, "\(url.lastPathComponent) decodes"); continue }
            T.equal(decoded, SnapshotFixtures.named(name, kind: kind), "\(url.lastPathComponent) = builder")
            T.check(data.count <= WidgetSnapshot.maxBytes, "\(url.lastPathComponent) ≤ 192 KB")
            T.check(decoded.meetings.count <= WidgetSnapshot.maxMeetings, "\(url.lastPathComponent) ≤ 120 meetings")
        }
        var future = SnapshotFixtures.busy(kind: "agenda.all"); future.v = WidgetSnapshot.version + 1
        T.check(SnapshotFixtures.decode(SnapshotFixtures.json(future)) == nil, "a newer file version is not read")
        T.check(SnapshotFixtures.decode(Data("{\"v\":1}".utf8)) == nil, "a truncated file is not read")
    }

    static var fixtureFiles: [(String, String)] {
        SnapshotFixtures.names.map { name -> (String, String) in
            switch name {
            case "mailComingSoon": return (name, "inbox.all")
            case "setup": return (name, "custom.e")
            case "customTitle": return (name, "custom.a")
            case "mailArchived", "inboxZero": return (name, "inbox.all")
            case "busyDay", "dayPicked": return (name, "day")
            case "customDay": return (name, "custom.f")
            default: return (name, "agenda.all")
            }
        } + [("busy", "month"), ("busy", "upnext"), ("busy", "custom.b"), ("busy", "inbox.all"), ("busy", "combo.all"),
             ("busy", "day")]
    }

    /// `shell-tests --write-fixtures <dir>`: (re)writes the committed JSON fixtures.
    static func write(to folder: String) -> Int32 {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        for (name, kind) in fixtureFiles {
            guard let data = try? encoder.encode(SnapshotFixtures.named(name, kind: kind)) else { return 1 }
            try? data.write(to: url.appendingPathComponent("\(name)-\(kind).json"))
        }
        print("wrote \(fixtureFiles.count) fixtures to \(folder)")
        return 0
    }
}
