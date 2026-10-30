import Foundation

/// The widget tap path after the performance review: a tap republishes and reloads only the kind it touched; the
/// flush that follows leaves sync-time-only changes alone; taps read the store once per data change
/// (write generations), and what they publish is exactly what a fresh read would publish.
enum TapPathTests {
    static func run() {
        onlyTheTouchedKind()
        cachedEqualsFresh()
        undoWindowCloses()
        generations()
    }

    /// An "Archived · Undo" row in cached mail data ends with its 30 s window, as in a fresh read: time
    /// closes the window, no store write marks it.
    static func undoWindowCloses() {
        let (h, accounts) = PublishTests.seeded("tap-undo")
        h.labsMail.value = true
        let mail = MailRepo(db: h.db)
        let a = accounts[0]
        func thread(_ r: String, inbox: Bool, minutesAgo: Double) -> MailThreadRecord {
            MailThreadRecord(r: r, accountId: a.id, threadId: r, historyId: nil, subject: "Subject \(r)", senderName: "Sender",
                             senderEmail: "s@x.example", snippet: "", lastAt: h.clock.now.addingTimeInterval(-minutesAgo * 60),
                             unread: true, starred: false, inInbox: inbox, categoryPrimary: true, messageCount: 1,
                             lastMessageIdHeader: nil, labels: inbox ? ["INBOX"] : [], messageIds: ["m-\(r)"])
        }
        try? mail.upsert(thread("keep", inbox: true, minutesAgo: 5))
        try? mail.upsert(thread("gone", inbox: false, minutesAgo: 1))
        try? ActionRepo(db: h.db).insert(MailActionRecord(id: "arch", kind: .archive, r: "gone", accountId: a.id, payload: [:],
                                                          state: .done, createdAt: h.clock.now.addingTimeInterval(-10),
                                                          undoUntil: h.clock.now.addingTimeInterval(20)))
        let engine = h.engine
        engine.start()
        let w = engine.widgets
        w.page(kind: "inbox.all", family: "L", to: 1)
        expect(h.snapshot("inbox.all")?.mail.contains { $0.r == "gone" && $0.archivedAt != nil } == true,
               "a tap inside the undo window carries the archived row")
        h.clock.advance(25)   // the window closed; nothing was written since
        w.page(kind: "inbox.all", family: "L", to: 1)
        expect(h.snapshot("inbox.all")?.mail.contains { $0.r == "gone" } == false,
               "a tap after it drops the row, as a fresh read does")
        guard let cached = engine.publisher.context(.none), let fresh = engine.publisher.context(.all),
              var x = engine.publisher.snapshot(kind: "inbox.all", context: cached),
              let y = engine.publisher.snapshot(kind: "inbox.all", context: fresh) else {
            expect(false, "contexts")
            return
        }
        x.generatedAt = y.generatedAt
        expect(x == y, "cached mail data = a fresh read once the window closed")
    }

    static func onlyTheTouchedKind() {
        let (h, accounts) = PublishTests.seeded("tap-touched")
        let engine = h.engine
        let w = engine.widgets
        engine.start()
        engine.widgets.flushChanged()   // the first flush of a run reloads every kind once
        h.reloader.reset()

        // A sync pass for every account: syncedAt moves in every snapshot, nothing else.
        h.clock.advance(120)
        for a in accounts { SyncStatusRepo(db: h.db).recordSuccess(a.id, at: h.clock.now) }
        let changed = engine.publisher.publishAll(reason: .background)
        expect(changed.count == 12, "a sync pass rewrites every snapshot with a sync time (syncedAt; the Daily Digest has none)")
        expect(h.reloader.reloads.value.isEmpty, "…without a background reload (sync time only)")

        // The first tap after it: the router's action, then its flush.
        w.selectDay(kind: "month", day: "2026-10-21")
        expect(h.reloader.reloads.value == ["month"], "the tap reloads the tapped kind")
        let flushed = engine.governor.flushChanged()
        expect(flushed.isEmpty && h.reloader.reloads.value == ["month"],
               "…and the flush after it reloads nothing else (was: every kind)")
        w.page(kind: "agenda.all", family: "L", to: 2)
        expect(h.reloader.reloads.value == ["month", "agenda.all"], "a page tap: that kind only")

        // A real change waiting for its background budget still rides along with the next flush.
        h.reloader.reset()
        try? EventRepo(db: h.db).upsert(Seed.row(accounts[0].id, id: "late", title: "Late add", start: TestCal.local(2026, 10, 19, 17),
                                                 end: TestCal.local(2026, 10, 19, 17, 30)))
        engine.publisher.publishAll(reason: .background)
        let pending = h.reloader.reloads.value
        w.selectDay(kind: "month", day: "2026-10-22")
        let ride = engine.governor.flushChanged()
        expect(!ride.isEmpty && Set(ride + pending).isSuperset(of: ["agenda.all", "upnext"]),
               "a significant change held by the budget goes out on the next flush")
        expect(h.snapshot("agenda.all")?.meetings.contains { $0.title == "Late add" } == true, "with the new meeting")

        // 30 min of sync passes and no tap: one keep-alive refreshes the widget's sync time, at 24 min
        // (before the 30 min "Last synced …" strip), not every 15 min.
        h.reloader.reset()
        var at22 = -1
        for pass in 1...15 {
            h.clock.advance(120)
            for a in accounts { SyncStatusRepo(db: h.db).recordSuccess(a.id, at: h.clock.now) }
            engine.publisher.publishAll(reason: .background)
            engine.governor.tick()
            if pass == 11 { at22 = h.reloader.count("month") }
        }
        expect(at22 == 0, "22 min of sync passes: the widget's sync time is still fresh enough, no reload")
        expect(h.reloader.count("month") == 1,
               "30 min: exactly one keep-alive (\(h.reloader.count("month")) reloads), before the strip would show")
    }

    /// Publishing from cached store data (taps) = publishing after reading everything again.
    static func cachedEqualsFresh() {
        let (h, accounts) = PublishTests.seeded("tap-cache")
        h.labsMail.value = true
        let mail = MailRepo(db: h.db)
        for (i, a) in accounts.enumerated() {
            for t in 0..<5 {
                try? mail.upsert(MailThreadRecord(r: "th-\(i)-\(t)", accountId: a.id, threadId: "t\(t)", historyId: nil,
                                                  subject: "Subject \(t)", senderName: "Sender \(t)", senderEmail: "s\(t)@x.example",
                                                  snippet: "", lastAt: h.clock.now.addingTimeInterval(-Double(t) * 600), unread: t % 2 == 0,
                                                  starred: false, inInbox: true, categoryPrimary: true, messageCount: 1,
                                                  lastMessageIdHeader: nil, labels: ["INBOX"], messageIds: ["m\(t)"]))
            }
        }
        let engine = h.engine
        engine.start()
        let w = engine.widgets
        try? w.save(WidgetSettings(kind: "custom.b", title: "Work", customContent: .month, accountIds: [accounts[1].id]))
        try? w.save(WidgetSettings(kind: "custom.c", customContent: .combo))
        w.selectDay(kind: "month", day: "2026-10-20")
        w.page(kind: "agenda.all", family: "XL", to: 2)
        w.showMonth(kind: "custom.b", month: "2026-11")
        // Data changes between taps, like a sync pass and a mail action would make them.
        try? EventRepo(db: h.db).upsert(Seed.row(accounts[1].id, id: "new", title: "New meeting", start: TestCal.local(2026, 10, 20, 9),
                                                 end: TestCal.local(2026, 10, 20, 9, 30)))
        try? mail.upsert(MailThreadRecord(r: "th-new", accountId: accounts[0].id, threadId: "tn", historyId: nil, subject: "Fresh",
                                          senderName: "New", senderEmail: "n@x.example", snippet: "", lastAt: h.clock.now,
                                          unread: true, starred: false, inInbox: true, categoryPrimary: true, messageCount: 1,
                                          lastMessageIdHeader: nil, labels: ["INBOX"], messageIds: ["mn"]))
        w.selectDay(kind: "month", day: "2026-10-21")
        expect(h.snapshot("month")?.meetings.contains { $0.title == "New meeting" } == false, "the month list starts at the picked day")
        w.setRange(kind: "agenda.all", days: 2)
        expect(h.snapshot("agenda.all")?.meetings.contains { $0.title == "New meeting" } == true, "a tap after an event write reads it")
        w.page(kind: "combo.all", family: "XL", to: 1)
        expect(h.snapshot("combo.all")?.mail.contains { $0.r == "th-new" } == true, "a tap after a mail write reads it")

        // Every kind: what the publisher builds from its cache = from a fresh read.
        guard let cached = engine.publisher.context(.none), let fresh = engine.publisher.context(.all) else {
            expect(false, "contexts")
            return
        }
        var same = true
        for spec in WidgetKinds.all {
            guard var a = engine.publisher.snapshot(kind: spec.kind, context: cached),
                  let b = engine.publisher.snapshot(kind: spec.kind, context: fresh) else { same = false; continue }
            a.generatedAt = b.generatedAt
            if a != b { same = false; print("    differs: \(spec.kind)") }
        }
        expect(same, "cached store data publishes the same 12 snapshots as a fresh read")
    }

    static func generations() {
        expect(AppDatabase.writtenTable("INSERT INTO events(r, title) VALUES (?, ?)") == "events", "insert table")
        expect(AppDatabase.writtenTable("\n            INSERT INTO widget_state (kind, family)\n VALUES (?, ?) ON CONFLICT DO UPDATE SET page = 2") == "widget_state",
               "multi-line upsert table")
        expect(AppDatabase.writtenTable("UPDATE mail_threads SET unread = 0") == "mail_threads", "update table")
        expect(AppDatabase.writtenTable("DELETE FROM sync_state WHERE x") == "sync_state", "delete table")
        expect(AppDatabase.writtenTable("INSERT OR REPLACE INTO settings VALUES (?)") == "settings", "insert or replace")
        expect(AppDatabase.writtenTable("SELECT 1") == nil, "reads are not writes")

        let (h, accounts) = PublishTests.seeded("tap-generations")
        let g0 = h.db.generations
        _ = try? WidgetRepo(db: h.db).setPage(kind: "agenda.all", family: "L", page: 2, at: h.clock.now)
        _ = try? WidgetRepo(db: h.db).setKindState(kind: "month", selectedDay: "2026-10-20", at: h.clock.now)
        expect(h.db.generations == g0, "widget state writes (taps) leave the generations alone")
        SyncStatusRepo(db: h.db).recordSuccess(accounts[0].id, at: h.clock.now)
        let g1 = h.db.generations
        expect(g1.calendar > g0.calendar && g1.mail == g0.mail, "a sync-state write moves the calendar generation")
        try? MailRepo(db: h.db).recordSuccess(accountId: accounts[0].id, at: h.clock.now)
        let g2 = h.db.generations
        expect(g2.mail > g1.mail && g2.calendar == g1.calendar, "a mail write moves the mail generation")
    }
}
