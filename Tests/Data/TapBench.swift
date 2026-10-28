import Foundation

/// `data-tests <scratch> --bench <out.json>` (Tools/bench-widgets.sh, built with -O): the app side of a
/// widget tap, on a temp store under the worktree's `.work/` (never the real App Support, Keychain or
/// network). What LinkRouter does for one quiet link: the route's state write + publish of the tapped
/// kind (`WidgetInteractions.*`), then `flushChanged()` — timed, with the timeline reloads it asks for.
///
/// Store: 4 accounts, 2 calendars each, ~3k event rows over the sync window (merged invites, attendees,
/// notes), 96 inbox threads per account. Two runs: mail off and on.
enum TapBench {
    struct Sample { var ms: Double; var reloads: [String] }

    static func run(out: URL?) {
        var report: [String: Any] = [:]
        for mail in [false, true] {
            let name = mail ? "mailOn" : "mailOff"
            report[name] = scenario(mail: mail)
        }
        if let out, let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: out)
            print("BENCH tap → \(out.path)")
        }
    }

    static func scenario(mail: Bool) -> [String: Any] {
        let h = Harness("bench-\(mail ? "on" : "off")")
        h.labsMail.value = mail
        let rows = seed(h)
        let engine = h.engine
        let t0 = Date()
        engine.start()
        let startMs = Date().timeIntervalSince(t0) * 1000
        let w = engine.widgets
        let label = mail ? "mail on " : "mail off"

        // publishAll (every sync pass ends with one): syncedAt moves each time.
        let publishAll = (0..<5).map { _ -> Double in
            h.clock.advance(120)
            for id in accountIds(h) { SyncStatusRepo(db: h.db).recordSuccess(id, at: h.clock.now) }
            return clock { engine.publisher.publishAll(reason: .background) }
        }

        let today = h.env.calendar().startOfDay(for: h.clock.now)
        let days = (1...10).map { DayKey.string(h.env.calendar().date(byAdding: .day, value: $0, to: today)!, h.env.calendar()) }

        // Warm day taps: consecutive picks, nothing else changed in between.
        _ = tap(h) { w.selectDay(kind: "month", day: days[0]) }
        let warm = (0..<20).map { i in tap(h) { w.selectDay(kind: "month", day: days[(i + 1) % days.count]) } }

        // The first tap after a background sync (every 2 min per account in the app): syncedAt moved in
        // every snapshot, so the flush finds every kind changed since its last reload.
        let afterSync = (0..<10).map { i -> Sample in
            h.clock.advance(120)
            for id in accountIds(h) { SyncStatusRepo(db: h.db).recordSuccess(id, at: h.clock.now) }
            engine.publisher.publishAll(reason: .background)
            return tap(h) { w.selectDay(kind: "month", day: days[i % days.count]) }
        }

        let pages = (0..<20).map { i in tap(h) { w.page(kind: "agenda.all", family: "L", to: i % 2 == 0 ? 2 : 1) } }
        let months = (0..<10).map { i in tap(h) { w.showMonth(kind: "month", month: i % 2 == 0 ? "2026-11" : "2026-10") } }

        func summary(_ s: [Sample]) -> [String: Any] {
            let ms = s.map(\.ms).sorted()
            let reloads = s.map { Double($0.reloads.count) }
            return ["p50Ms": round3(pct(ms, 0.5)), "p90Ms": round3(pct(ms, 0.9)), "maxMs": round3(ms.last ?? 0),
                    "reloadsPerTap": round3(reloads.reduce(0, +) / Double(max(1, reloads.count))),
                    "kindsReloaded": Array(Set(s.flatMap(\.reloads))).sorted()]
        }
        let result: [String: Any] = [
            "eventRows": rows, "startMs": round3(startMs),
            "publishAllP50Ms": round3(pct(publishAll.sorted(), 0.5)),
            "dayTapWarm": summary(warm), "dayTapAfterSync": summary(afterSync),
            "pageTap": summary(pages), "monthTap": summary(months),
        ]
        func line(_ name: String, _ s: [Sample]) {
            let d = summary(s)
            print(String(format: "BENCH tap %@ %-15@ p50 %7.2f ms  p90 %7.2f ms  max %7.2f ms  reloads/tap %5.2f",
                         label as NSString, name as NSString, d["p50Ms"] as! Double, d["p90Ms"] as! Double,
                         d["maxMs"] as! Double, d["reloadsPerTap"] as! Double))
        }
        print(String(format: "BENCH tap %@ rows=%d  start %.1f ms  publishAll p50 %.1f ms", label as NSString, rows, startMs,
                     pct(publishAll.sorted(), 0.5)))
        line("day (warm)", warm)
        line("day after sync", afterSync)
        line("page", pages)
        line("month", months)
        return result
    }

    /// One quiet link as LinkRouter performs it: the route's action, then `flushChanged()`.
    static func tap(_ h: Harness, _ action: () -> Void) -> Sample {
        let before = h.reloader.reloads.value.count
        let ms = clock {
            action()
            h.engine.widgets.flushChanged()
        }
        return Sample(ms: ms, reloads: Array(h.reloader.reloads.value.dropFirst(before)))
    }

    static func accountIds(_ h: Harness) -> [UUID] { ((try? AccountRepo(db: h.db).all()) ?? []).map(\.id) }

    /// Four accounts; weekday meetings over the whole sync window; a fifth of them merged invites.
    @discardableResult
    static func seed(_ h: Harness) -> Int {
        let tags = [("ORB", 0x8FB4C4), ("CMT", 0xB8A99A), ("FAM", 0xC9A3E6), ("Personal", 0xE0A35C)]
        let accounts = tags.enumerated().map { i, t in
            Seed.account(h.db, email: "\(t.0.lowercased())@bench.example", tag: t.0, sort: i, color: UInt32(t.1))
        }
        for a in accounts {
            Seed.calendar(h.db, a.id, a.email)
            Seed.calendar(h.db, a.id, "team-\(a.tag)")
            SyncStatusRepo(db: h.db).recordSuccess(a.id, at: h.clock.now)
        }
        let cal = TestCal.lab
        let window = SyncWindow.current(now: h.clock.now, calendar: cal)
        let people = (0..<8).map { StoredPerson(email: "guest\($0)@bench.example", name: "Guest \($0)", response: "accepted",
                                                isSelf: false, isOrganizer: $0 == 0) }
        var rows = 0
        let repo = EventRepo(db: h.db)
        try? h.db.transaction {
            var day = cal.startOfDay(for: window.start)
            var n = 0
            while day < window.end {
                if !cal.isDateInWeekend(day) {
                    for (ai, a) in accounts.enumerated() {
                        for slot in 0..<9 {
                            let start = cal.date(bySettingHour: 8 + slot, minute: (ai * 15) % 60, second: 0, of: day)!
                            let calendarId = slot < 7 ? a.email : "team-\(a.tag)"
                            let shared = n % 5 == 0
                            let uid = shared ? "shared-\(n / 5)@bench" : nil
                            let me = StoredPerson(email: a.email, name: "Me", response: slot == 3 ? "needsAction" : "accepted",
                                                  isSelf: true, isOrganizer: false)
                            try repo.upsert(Seed.row(a.id, calendar: calendarId, id: "e\(n)", title: "Meeting \(n) with the team",
                                                     start: start, end: start.addingTimeInterval(45 * 60), uid: uid,
                                                     response: slot == 3 ? "needsAction" : "accepted", organizer: people[0],
                                                     attendees: [me] + people, join: slot % 2 == 0 ? "https://meet.google.com/abc-defg-hij" : nil,
                                                     location: slot % 3 == 0 ? "Suite 404" : nil))
                            rows += 1
                            if shared {
                                let other = accounts[(ai + 1) % accounts.count]
                                try repo.upsert(Seed.row(other.id, calendar: other.email, id: "e\(n)-copy", title: "Meeting \(n) with the team",
                                                         start: start, end: start.addingTimeInterval(45 * 60), uid: uid,
                                                         organizer: people[0], attendees: people))
                                rows += 1
                            }
                            n += 1
                        }
                    }
                }
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
        }
        let mail = MailRepo(db: h.db)
        for a in accounts {
            for i in 0..<WidgetSnapshot.maxMail {
                let t = MailThreadRecord(r: "th-\(a.tag)-\(i)", accountId: a.id, threadId: "t\(i)", historyId: nil,
                                         subject: "Subject line \(i) for the weekly numbers", senderName: "Sender \(i % 17)",
                                         senderEmail: "s\(i % 17)@bench.example", snippet: "Snippet \(i)",
                                         lastAt: h.clock.now.addingTimeInterval(-Double(i) * 1_800), unread: i % 3 == 0,
                                         starred: i % 11 == 0, inInbox: true, categoryPrimary: true, messageCount: 2,
                                         lastMessageIdHeader: nil, labels: ["INBOX"], messageIds: ["m\(i)a", "m\(i)b"])
                try? mail.upsert(t)
            }
            try? mail.recordSuccess(accountId: a.id, at: h.clock.now)
        }
        return rows
    }

    static func clock(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    static func pct(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
