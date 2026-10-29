import Foundation

/// SnapshotPublisher: content per kind, ranges, caps, hash stability, atomic writes, health, pages.
enum PublishTests {
    static func run() {
        kindsAndContent()
        rangesAndCaps()
        hashStabilityAndAtomicWrite()
        sizeLimit()
        health()
        accountsAndLogos()
    }

    /// Three accounts with rows on Mon 19 → Fri 23 Oct (the sample week) stored directly.
    static func seeded(_ name: String) -> (Harness, [AccountRecord]) {
        let h = Harness(name)
        let orb = Seed.account(h.db, email: "y@orb.example", tag: "ORB", sort: 0, color: 0x3CCBB4)
        let cmt = Seed.account(h.db, email: "y@cmt.example", tag: "CMT", sort: 1, color: 0xD2A6C6)
        let me = Seed.account(h.db, email: consumerAddress("y"), tag: "Personal", sort: 2, includeInAll: false)
        let repo = EventRepo(db: h.db)
        for acct in [orb, cmt, me] {
            Seed.calendar(h.db, acct.id, "primary")
            SyncStatusRepo(db: h.db).recordSuccess(acct.id, at: h.clock.now)
        }
        try? repo.upsert(Seed.row(orb.id, id: "standup", title: "Standup", start: TestCal.local(2026, 10, 19, 10), end: TestCal.local(2026, 10, 19, 10, 15),
                                  join: "https://meet.google.com/abc-defg-hij", location: "https://meet.google.com/abc-defg-hij"))
        try? repo.upsert(Seed.row(cmt.id, id: "review", title: "Review", start: TestCal.local(2026, 10, 20, 14), end: TestCal.local(2026, 10, 20, 15),
                                  response: "needsAction", location: "Suite 404"))
        try? repo.upsert(Seed.row(orb.id, id: "clash", title: "Clash", start: TestCal.local(2026, 10, 20, 14, 30), end: TestCal.local(2026, 10, 20, 15, 30),
                                  response: "tentative"))
        try? repo.upsert(Seed.row(cmt.id, id: "declined", title: "Declined", start: TestCal.local(2026, 10, 21, 9), end: TestCal.local(2026, 10, 21, 10),
                                  response: "declined"))
        try? repo.upsert(Seed.row(orb.id, id: "trip", title: "Trip", start: TestCal.local(2026, 10, 28), end: TestCal.local(2026, 11, 1), allDay: true, busy: false))
        try? repo.upsert(Seed.row(me.id, id: "dinner", title: "Dinner", start: TestCal.local(2026, 10, 19, 20), end: TestCal.local(2026, 10, 19, 22)))
        return (h, [orb, cmt, me])
    }

    static func kindsAndContent() {
        let (h, accounts) = seeded("publish-kinds")
        let engine = h.engine
        let changed = engine.publisher.publishAll(reason: .background)
        expect(changed.count == 12, "all 12 kinds written")
        let folder = h.dir.appendingPathComponent("widget")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        expect(files.filter { $0.hasSuffix(".json") }.count == 12 && !files.contains { $0.hasSuffix(".tmp") }, "12 files, no temp files left")
        let mode = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("agenda.all.json").path)[.posixPermissions] as? NSNumber)?.intValue
        expect(mode == 0o600, "snapshot files are 0600")
        let content = Dictionary(uniqueKeysWithValues: WidgetKinds.all.map { ($0.kind, h.snapshot($0.kind)?.content) })
        expect(content["agenda.all"] == .agenda && content["upnext"] == .upNext && content["month"] == .month
               && content["day"] == .day, "calendar kinds")
        expect(content["inbox.all"] == .mailComingSoon && content["combo.all"] == .mailComingSoon, "mail kinds: coming soon while mail is off")
        expect(WidgetKinds.custom.allSatisfy { content[$0.kind] == .setup }, "custom slots: setup until configured")
        expect(h.snapshot("custom.a")?.meetings.isEmpty == true, "setup carries no meetings")
        expect(h.snapshot("combo.all")?.meetings.isEmpty == false && h.snapshot("inbox.all")?.meetings.isEmpty == true,
               "combo keeps its agenda half; inbox has none")

        h.labsMail.value = true
        engine.widgets.trace = { _, _ in }
        try? engine.widgets.save(WidgetSettings(kind: "custom.b", title: "  Work  ", customContent: .month, accountIds: [accounts[1].id]))
        try? engine.widgets.save(WidgetSettings(kind: "custom.c", customContent: .inbox))
        engine.publisher.publishAll(reason: .background)
        expect(h.snapshot("inbox.all")?.content == .inbox && h.snapshot("combo.all")?.content == .combo, "mail on → inbox/combo")
        let b = h.snapshot("custom.b")
        expect(b?.content == .month && b?.title == "Work" && b?.accounts.map(\.tag) == ["CMT"], "configured custom slot")
        expect(h.snapshot("custom.c")?.content == .inbox, "custom inbox with mail on")
        h.labsMail.value = false
        engine.publisher.publishAll(reason: .background)
        expect(h.snapshot("custom.c")?.content == .mailComingSoon, "custom inbox with mail off → coming soon")
        expect(h.snapshot("agenda.all")?.title == nil, "fixed kinds carry no title")
    }

    static func rangesAndCaps() {
        let (h, accounts) = seeded("publish-ranges")
        let engine = h.engine
        engine.publisher.publishAll(reason: .background)
        guard let agenda = h.snapshot("agenda.all") else { expect(false, "agenda snapshot"); return }
        expect(agenda.meetings.map(\.title) == ["Standup", "Review", "Clash"], "7-day range from today; declined, all-day-later and excluded accounts out")
        expect(agenda.rangeDays == 7 && agenda.windowStart == "2026-09-28" && agenda.windowEnd == "2026-12-31", "range + window keys")
        let review = agenda.meetings.first { $0.title == "Review" }
        let clash = agenda.meetings.first { $0.title == "Clash" }
        expect(review?.reply == .needsReply && clash?.reply == .maybe, "replies: needsAction → needsReply, tentative → maybe")
        expect(review?.clashes == true && clash?.clashes == true && agenda.meetings.first?.clashes == false, "clash flags")
        expect(agenda.meetings.first?.hasJoin == true && agenda.meetings.first?.place == nil, "join flag; URL-only place dropped")
        expect(review?.place == "Suite 404", "real place kept")
        expect(review?.accountIds == [accounts[1].id.uuidString], "account ids as UUID strings")
        expect(agenda.busyDays.isEmpty && agenda.selectedDay == nil, "agenda carries no month fields")
        expect(agenda.meetings.allSatisfy { engine.widgets.verify(r: $0.r, k: $0.k) }, "every row's k verifies")
        let json = (try? String(contentsOf: engine.publisher.url(kind: "agenda.all"), encoding: .utf8)) ?? ""
        expect(!json.contains("https://") && !json.contains("@orb.example") && !json.contains("Declined"), "no URLs, emails or declined rows")

        engine.widgets.setRange(kind: "agenda.all", days: 1)
        expect(h.snapshot("agenda.all")?.meetings.map(\.title) == ["Standup"] && h.snapshot("agenda.all")?.rangeDays == 1, "range 1 = today")

        guard let month = h.snapshot("month") else { expect(false, "month snapshot"); return }
        expect(month.busyDays == ["2026-10-19", "2026-10-20", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31"],
               "busy days: meetings and every day of the trip; declined day not busy")
        expect(month.meetings.map(\.title) == ["Standup", "Review", "Clash", "Trip"], "month: today to the end of the window")
        let trip = month.meetings.last
        expect(trip?.allDay == true && trip?.start == TestCal.local(2026, 10, 28), "all-day row")

        // 300 meetings in range → 120.
        let repo = EventRepo(db: h.db)
        for i in 0..<300 {
            let start = TestCal.local(2026, 10, 22, 8).addingTimeInterval(Double(i) * 60)
            try? repo.upsert(Seed.row(accounts[0].id, id: "bulk\(i)", title: "Bulk \(i)", start: start, end: start.addingTimeInterval(30)))
        }
        // The rows land like a sync pass writes them (the store's write generation moved): the next
        // interaction publish reads them, cached store data or not.
        engine.widgets.setRange(kind: "agenda.all", days: 7)
        expect(h.snapshot("agenda.all")?.meetings.count == 120, "agenda capped at 120 meetings")
        expect(h.snapshot("agenda.all")?.meetings.first?.title == "Standup", "cap keeps the earliest")
    }

    static func hashStabilityAndAtomicWrite() {
        let (h, _) = seeded("publish-hash")
        let engine = h.engine
        engine.publisher.publishAll(reason: .background)
        let url = engine.publisher.url(kind: "agenda.all")
        let first = try? Data(contentsOf: url)
        let inode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue
        h.clock.advance(30)
        let rewritten = engine.publisher.publishAll(reason: .background)
        let second = try? Data(contentsOf: url)
        let inode2 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue
        expect(rewritten.isEmpty && first == second && inode == inode2, "nothing changed → nothing rewritten (generatedAt excluded)")

        guard let snap = h.snapshot("agenda.all") else { expect(false, "snapshot"); return }
        var later = snap
        later.generatedAt = snap.generatedAt.addingTimeInterval(999)
        expect(later.contentHash == snap.contentHash, "contentHash ignores generatedAt")
        var other = snap
        other.meetings[0].title = "Changed"
        expect(other.contentHash != snap.contentHash, "contentHash sees content")

        // A fresh publisher (next launch) recognises the files on disk.
        let reopened = SnapshotPublisher(db: h.db, links: engine.links, governor: ReloadGovernor(reloader: FakeReloader(), now: h.clock.closure),
                                         directory: h.dir.appendingPathComponent("widget"), logos: h.dir, timing: SyncTiming(),
                                         now: h.clock.closure, calendar: { TestCal.lab }, labsMail: { false })
        expect(reopened.publishAll(reason: .background).isEmpty, "next launch: unchanged files not rewritten")

        let firstAccount = (try? AccountRepo(db: h.db).all())?.first?.id ?? UUID()
        try? EventRepo(db: h.db).upsert(Seed.row(firstAccount, id: "new", title: "New one", start: TestCal.local(2026, 10, 21, 16),
                                                 end: TestCal.local(2026, 10, 21, 17)))
        let changed = engine.publisher.publishAll(reason: .background)
        expect(changed.contains("agenda.all") && changed.contains("month"), "a new meeting rewrites the affected kinds")
        expect(!changed.contains("custom.a") && !changed.contains("inbox.all"), "kinds without meetings unchanged")
        let inode3 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue
        expect(inode3 != inode, "atomic replace: a new file renamed over the old one")
        expect(h.snapshot("agenda.all")?.meetings.contains { $0.title == "New one" } == true, "new content readable")

        // Recording per account (D-046): the record button's recorder rides in `rec` and `recBy`; Fathom keeps D-045's form.
        let savedKind = SnapshotPublisher.recorderKind
        expect(savedKind([firstAccount], true) == (SnapshotPublisher.fathomOffered([firstAccount], true) ? "fathom" : nil),
               "the default recorder is D-045's Fathom button")
        SnapshotPublisher.recorderKind = { _, _ in "murmur" }
        _ = engine.publisher.publishAll(reason: .background)
        let murmurRows = h.snapshot("agenda.all")?.meetings ?? []
        expect(!murmurRows.isEmpty && murmurRows.allSatisfy { $0.rec == true && $0.recBy == "murmur" }, "Yaya's Murmur: rec + recBy murmur")
        SnapshotPublisher.recorderKind = { _, _ in "fathom" }
        _ = engine.publisher.publishAll(reason: .background)
        let fathomRows = h.snapshot("agenda.all")?.meetings ?? []
        expect(!fathomRows.isEmpty && fathomRows.allSatisfy { $0.rec == true && $0.recBy == nil }, "Fathom: rec alone, as D-045 wrote it")
        SnapshotPublisher.recorderKind = savedKind
        _ = engine.publisher.publishAll(reason: .background)
        expect((h.snapshot("agenda.all")?.meetings ?? []).allSatisfy { $0.recBy == nil }, "restored")

        // Only the sync time moved: the file is rewritten but no background reload is spent.
        h.reloader.reset()
        h.clock.advance(60)
        for a in (try? AccountRepo(db: h.db).all()) ?? [] { SyncStatusRepo(db: h.db).recordSuccess(a.id, at: h.clock.now) }
        let syncOnly = engine.publisher.publishAll(reason: .background)
        expect(syncOnly.contains("agenda.all") && h.reloader.reloads.value.isEmpty, "syncedAt-only change: written, no reload")
        engine.widgets.flushChanged()
        expect(h.reloader.count("agenda.all") == 1, "flushChanged reloads it")
    }

    static func sizeLimit() {
        let (h, _) = seeded("publish-size")
        let engine = h.engine
        let huge = String(repeating: "x", count: 2_000)
        let meetings = (0..<120).map { i in
            WidgetSnapshot.Meeting(r: "g\(i)", k: "k", accountIds: [], title: huge, start: TestCal.labNow, end: TestCal.labNow,
                                   allDay: false, place: huge, hasJoin: false, reply: .accepted, clashes: false)
        }
        let snap = WidgetSnapshot(kind: "agenda.all", generatedAt: TestCal.labNow, content: .agenda, title: nil, style: .init(),
                                  accounts: [], health: .init(), meetings: meetings, mail: [], unreadCount: nil, pages: [:],
                                  pageResetAt: nil, selectedDay: nil, monthShown: nil, busyDays: [], windowStart: "2026-09-28",
                                  windowEnd: "2026-12-31", rangeDays: 7)
        expect(((try? WidgetSnapshot.encoder.encode(snap))?.count ?? 0) > WidgetSnapshot.maxBytes, "fixture is over 192 KB")
        engine.publisher.write(snap, reason: .background)
        let size = (try? Data(contentsOf: engine.publisher.url(kind: "agenda.all")))?.count ?? 0
        let written = h.snapshot("agenda.all")
        expect(size > 0 && size <= WidgetSnapshot.maxBytes, "written file within 192 KB (\(size) bytes)")
        expect((written?.meetings.count ?? 0) > 0 && (written?.meetings.count ?? 0) < 120, "rows trimmed from the end")
        expect(written?.meetings.first?.r == "g0", "earliest rows kept")
        expect(SnapshotPublisher.clip(huge).count == 200, "titles clipped to 200 characters")
    }

    static func health() {
        let h = Harness("publish-health")
        let engine = h.engine
        engine.publisher.publishAll(reason: .background)
        expect(h.snapshot("agenda.all")?.health.state == .noAccounts, "no accounts → noAccounts")

        let a = Seed.account(h.db, email: "y@orb.example", tag: "ORB", sort: 0)
        let b = Seed.account(h.db, email: "y@cmt.example", tag: "CMT", sort: 1)
        engine.publisher.publishAll(reason: .background)
        expect(h.snapshot("agenda.all")?.health.state == .stale && h.snapshot("agenda.all")?.health.syncedAt == nil,
               "never synced → stale")
        SyncStatusRepo(db: h.db).recordSuccess(a.id, at: h.clock.now.addingTimeInterval(-60))
        SyncStatusRepo(db: h.db).recordSuccess(b.id, at: h.clock.now.addingTimeInterval(-120))
        engine.publisher.publishAll(reason: .background)
        let ok = h.snapshot("agenda.all")?.health
        expect(ok?.state == .ok && ok?.syncedAt == h.clock.now.addingTimeInterval(-120), "recent syncs → ok, syncedAt = oldest")
        h.clock.advance(14 * 60)
        engine.publisher.publishAll(reason: .background)
        expect(h.snapshot("agenda.all")?.health.state == .stale, "older than 15 min → stale")
        _ = try? AccountRepo(db: h.db).setHealth(b.id, .reauthNeeded, detail: nil)
        engine.publisher.publishAll(reason: .background)
        let reauth = h.snapshot("agenda.all")?.health
        expect(reauth?.state == .reauth && reauth?.accountId == b.id.uuidString, "reauth names the account")
        expect(reauth.map { engine.widgets.verify(r: $0.accountId ?? "", k: $0.k ?? "") } == true, "reauth link key verifies")
        try? engine.widgets.save(WidgetSettings(kind: "custom.d", customContent: .agenda, accountIds: []))
        expect(h.snapshot("custom.d")?.health.state == .noAccounts, "a widget with no accounts picked → noAccounts")
    }

    static func accountsAndLogos() {
        let (h, accounts) = seeded("publish-accounts")
        let logos = h.dir.appendingPathComponent("widget/logos")
        try? FileManager.default.createDirectory(at: logos, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logos.appendingPathComponent("\(accounts[0].id.uuidString).png").path, contents: Data([0x89]))
        let engine = h.engine
        engine.publisher.publishAll(reason: .background)
        let list = h.snapshot("agenda.all")?.accounts ?? []
        expect(list.map(\.tag) == ["ORB", "CMT"], "All = accounts marked Include in All, in the user's order")
        expect(list.first?.hasLogo == true && list.last?.hasLogo == false, "hasLogo = logos/<uuid>.png exists")
        expect(list.first?.color == 0x3CCBB4 && list.first?.name == "ORB" && list.first?.id == accounts[0].id.uuidString, "account fields")
        try? engine.widgets.save(WidgetSettings(kind: "custom.e", customContent: .agenda, accountIds: [accounts[2].id, accounts[0].id]))
        let custom = h.snapshot("custom.e")
        expect(custom?.accounts.map(\.tag) == ["ORB", "Personal"], "picked accounts, still in the user's order")
        expect(custom?.meetings.map(\.title).contains("Dinner") == true && custom?.meetings.map(\.title).contains("Review") == false,
               "picked accounts' meetings only")
        var off = accounts[1]
        off.calendarEnabled = false
        _ = try? AccountRepo(db: h.db).update(off)
        engine.publisher.publishAll(reason: .background)
        expect(h.snapshot("agenda.all")?.accounts.map(\.tag) == ["ORB"], "calendar off → left out of calendar kinds")
        expect(h.snapshot("agenda.all")?.meetings.contains { $0.title == "Review" } == false, "…and its meetings")
    }
}
