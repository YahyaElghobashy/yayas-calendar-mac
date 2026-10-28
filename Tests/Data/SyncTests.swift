import Foundation

/// CalendarSyncer end to end against the fake server (D-015).
enum SyncTests {
    static func run() async {
        await firstAndIncremental()
        await goneResets()
        await calendarsFollowGoogle()
        await recurringAndDST()
        await skipsBrokenCalendar()
        await emptyCalendarListKeepsData()
    }

    static func setup(_ name: String) -> (Harness, AccountRecord, String, CalendarSyncer, GoogleCalendarClient) {
        let h = Harness(name)
        let (account, token) = h.account("me@orb.example", tag: "ORB", sort: 0)
        let syncer = CalendarSyncer(db: h.db, now: h.clock.closure, calendar: { TestCal.lab })
        let client = GoogleCalendarClient(transport: h.google, tokens: h.source.tokens.value[account.id]!)
        return (h, account, token, syncer, client)
    }

    static func lists(_ google: FakeGoogle) -> Int {
        google.requests.filter { $0.url.query?.contains("singleEvents=true") ?? false }.count
    }

    static func firstAndIncremental() async {
        let (h, a, token, syncer, client) = setup("sync-flow")
        let cal = "me@orb.example"
        h.google.put(token: token, calendar: cal, G.timed("e1", "One", "2026-10-20T09:00:00+01:00", "2026-10-20T10:00:00+01:00"))
        h.google.put(token: token, calendar: cal, G.timed("e2", "Two", "2026-10-21T09:00:00+01:00", "2026-10-21T10:00:00+01:00"))
        h.google.put(token: token, calendar: cal, G.timed("old", "Old", "2026-08-01T09:00:00Z", "2026-08-01T10:00:00Z"))

        let first = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect(first?.calendars == 1 && first?.listed == 1 && first?.upserted == 2, "first pass: list, token, 2 events in window")
        expect(Set((try? EventRepo(db: h.db).eventIds(accountId: a.id, calendarId: cal)) ?? []) == ["e1", "e2"], "rows stored")
        let state = try? SyncStateRepo(db: h.db).get(accountId: a.id, calendarId: cal)
        expect(state?.syncToken != nil && state?.lastListAt == h.clock.now, "sync token + list time stored")
        let r1 = (try? EventRepo(db: h.db).get(accountId: a.id, calendarId: cal, eventId: "e1"))?.r

        h.google.clearLog()
        h.clock.advance(120)
        let quiet = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect(quiet?.listed == 0 && lists(h.google) == 0, "no change, 2 min later: feed only, no re-list")
        expect(!h.google.requests.contains { $0.url.path.hasSuffix("calendarList") }, "calendar list not re-read within 15 min")

        h.google.put(token: token, calendar: cal, G.timed("e1", "One (edited)", "2026-10-20T11:00:00+01:00", "2026-10-20T12:00:00+01:00"))
        h.google.clearLog()
        h.clock.advance(120)
        let changed = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect(changed?.feedChanges == 1 && changed?.listed == 1 && lists(h.google) == 1, "feed change → window re-list")
        let e1 = (try? EventRepo(db: h.db).get(accountId: a.id, calendarId: cal, eventId: "e1")) ?? nil
        expect(e1?.title == "One (edited)" && e1?.r == r1, "UPSERT updated the row and kept r")

        h.google.remove(token: token, calendar: cal, eventId: "e2")
        h.clock.advance(120)
        _ = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect((try? EventRepo(db: h.db).eventIds(accountId: a.id, calendarId: cal)) == ["e1"], "deleted on Google → vanished row deleted")

        h.google.clearLog()
        h.clock.advance(15 * 60)
        let periodic = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect(periodic?.listed == 1, "15 minutes → re-list without a feed change")
        expect(h.google.requests.contains { $0.url.path.hasSuffix("calendarList") }, "calendar list refreshed every 15 min")

        // Midnight: the next pass re-lists even though 15 min haven't passed.
        h.clock.set(TestCal.local(2026, 10, 19, 23, 59))
        _ = try? await syncer.sync(accountId: a.id, client: client, force: true)
        h.clock.set(TestCal.local(2026, 10, 20, 0, 1))
        h.google.clearLog()
        let midnight = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect(midnight?.listed == 1, "first pass after midnight re-lists")

        // Cancelled occurrences in a list are deleted.
        h.google.put(token: token, calendar: cal, G.timed("e1", "One", "2026-10-20T11:00:00+01:00", "2026-10-20T12:00:00+01:00", status: "cancelled"))
        h.google.listCancelled = true
        h.clock.advance(60)
        _ = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect(((try? EventRepo(db: h.db).eventIds(accountId: a.id, calendarId: cal)) ?? ["x"]).isEmpty, "cancelled → row deleted")
    }

    static func goneResets() async {
        let (h, a, token, syncer, client) = setup("sync-410")
        let cal = "me@orb.example"
        h.google.put(token: token, calendar: cal, G.timed("k", "Keep", "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z"))
        _ = try? await syncer.sync(accountId: a.id, client: client, force: false)
        let before = try? SyncStateRepo(db: h.db).get(accountId: a.id, calendarId: cal)
        h.google.expireTokens(token: token, calendar: cal)
        h.clock.advance(120)
        h.google.clearLog()
        let report = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect(report?.resets == 1 && report?.listed == 1, "410 → token reset + full re-list")
        let after = try? SyncStateRepo(db: h.db).get(accountId: a.id, calendarId: cal)
        expect(after?.syncToken != nil && after?.syncToken != before?.syncToken, "new token stored")
        let statuses = h.google.requests.compactMap { r -> String? in
            r.url.query?.contains("syncToken") == true ? "feed-token" : (r.url.query?.contains("singleEvents") == true ? "list" : "feed-new")
        }
        expect(statuses == ["feed-token", "feed-new", "list"], "order: failed feed, fresh token, window list")
    }

    static func calendarsFollowGoogle() async {
        let (h, a, token, syncer, client) = setup("sync-calendars")
        h.google.addCalendar(token: token, id: googleCalendarID("en.uk#holiday", "group.v.calendar.google.com"), summary: "Holidays", selected: nil,
                             accessRole: "reader")
        h.google.addCalendar(token: token, id: googleCalendarID("team"), summary: "Team", selected: true, accessRole: "writer")
        h.google.addCalendar(token: token, id: "boss@client.example", summary: "Boss", selected: true, accessRole: "freeBusyReader")
        h.google.put(token: token, calendar: googleCalendarID("team"),
                     G.timed("t", "Team sync", "2026-10-22T10:00:00Z", "2026-10-22T11:00:00Z"))
        h.google.put(token: token, calendar: googleCalendarID("en.uk#holiday", "group.v.calendar.google.com"), G.allDay("h", "Holiday", "2026-10-12", "2026-10-13"))
        _ = try? await syncer.sync(accountId: a.id, client: client, force: false)
        let selected = (try? CalendarRepo(db: h.db).selected(accountId: a.id).map(\.calendarId)) ?? []
        expect(Set(selected) == ["me@orb.example", googleCalendarID("team")], "Google's selected set, minus free/busy-only")
        expect((try? CalendarRepo(db: h.db).all(accountId: a.id).count) == 4, "every calendar recorded")
        expect((try? EventRepo(db: h.db).count(accountId: a.id)) == 1, "holidays (unselected) not synced")

        // Deselected in Google → its events go; removed → its row goes.
        h.google.addCalendar(token: token, id: googleCalendarID("team"), summary: "Team", selected: false, accessRole: "writer")
        h.google.removeCalendar(token: token, id: "boss@client.example")
        _ = try? await syncer.sync(accountId: a.id, client: client, force: true)
        expect((try? EventRepo(db: h.db).count(accountId: a.id)) == 0, "deselected calendar's events removed")
        expect((try? CalendarRepo(db: h.db).all(accountId: a.id).map(\.calendarId).contains("boss@client.example")) == false,
               "calendar gone from the list → row removed")
    }

    static func recurringAndDST() async {
        let (h, a, token, syncer, client) = setup("sync-recurring")
        let cal = "me@orb.example"
        for (id, start, end) in [("w_1", "2026-10-22T09:00:00+01:00", "2026-10-22T10:00:00+01:00"),
                                 ("w_2", "2026-10-29T09:00:00+00:00", "2026-10-29T10:00:00+00:00"),
                                 ("w_3", "2026-11-05T09:00:00+00:00", "2026-11-05T10:00:00+00:00")] {
            h.google.put(token: token, calendar: cal, G.timed(id, "Weekly", start, end, uid: "weekly@google.example", recurring: "w",
                                                              original: start))
        }
        h.google.put(token: token, calendar: cal, G.allDay("d25", "DST day", "2026-10-25", "2026-10-26"))
        h.google.put(token: token, calendar: cal, G.timed("late", "Repeated hour", "2026-10-25T01:30:00+00:00", "2026-10-25T02:15:00+00:00"))
        _ = try? await syncer.sync(accountId: a.id, client: client, force: false)
        let rows = (try? EventRepo(db: h.db).overlapping(from: TestCal.local(2026, 10, 1), to: TestCal.local(2026, 12, 1))) ?? []
        let weekly = rows.filter { $0.icalUID == "weekly@google.example" }
        expect(weekly.count == 3 && Set(weekly.map(\.r)).count == 3 && Set(weekly.map(\.groupId)).count == 3,
               "recurring instances: one row each, own r and group")
        let localHours = weekly.map { TestCal.lab.component(.hour, from: $0.start) }
        expect(localHours == [9, 9, 9], "9:00 local before and after the DST change")
        let d25 = rows.first { $0.eventId == "d25" }
        expect(d25.map { $0.end.timeIntervalSince($0.start) } == 25 * 3600, "all-day on the DST day spans 25 h")
        let late = rows.first { $0.eventId == "late" }
        expect(late?.start == TestCal.iso("2026-10-25T01:30:00Z"), "repeated-hour event stored at its UTC instant")
    }

    static func skipsBrokenCalendar() async {
        let (h, a, token, syncer, client) = setup("sync-broken")
        h.google.addCalendar(token: token, id: googleCalendarID("shared"), summary: "Shared", selected: true, accessRole: "reader")
        h.google.put(token: token, calendar: "me@orb.example", G.timed("ok", "OK", "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z"))
        h.google.inject(googleCalendarID("shared").replacingOccurrences(of: "@", with: "%40"), status: 403, body: #"{"error":{"errors":[{"reason":"forbidden"}]}}"#, times: 5)
        let report = try? await syncer.sync(accountId: a.id, client: client, force: false)
        expect(report?.skipped.count == 1 && report?.listed == 1, "a forbidden calendar is skipped, the others sync")
        h.google.inject("me%40orb.example", status: 503, body: "{}", times: 1)
        h.clock.advance(120)
        do {
            _ = try await syncer.sync(accountId: a.id, client: client, force: false)
            expect(false, "5xx should abort the pass")
        } catch {
            expect(SyncOutcome(error: error) == .serverError(retryAfter: nil), "5xx aborts the pass for backoff")
        }
    }
}

enum PerfTests {
    /// A heavy month (1,500 rows across 3 accounts): one interaction publish stays fast enough for a
    /// widget tap (measured: page flip p50 27 ms on the widget side).
    static func run() {
        let (h, accounts) = PublishTests.seeded("perf")
        let repo = EventRepo(db: h.db)
        try? h.db.transaction {
            for i in 0..<1_500 {
                let start = TestCal.local(2026, 10, 1, 8).addingTimeInterval(Double(i) * 3_600 * 1.4)
                try repo.upsert(Seed.row(accounts[i % 2].id, id: "p\(i)", title: "Meeting \(i)", start: start,
                                         end: start.addingTimeInterval(1_800), uid: i % 7 == 0 ? "shared\(i / 7)@x" : nil))
            }
        }
        let engine = h.engine
        let t0 = Date()
        engine.publisher.publishAll(reason: .background)
        let all = Date().timeIntervalSince(t0)
        let t1 = Date()
        engine.widgets.page(kind: "agenda.all", family: "L", to: 2)
        let one = Date().timeIntervalSince(t1)
        print(String(format: "    perf: publishAll %.0f ms, one interaction %.0f ms (1,500 rows)", all * 1000, one * 1000))
        expect(one < 0.25, "interaction publish under 250 ms on 1,500 rows")
        expect(h.snapshot("agenda.all")?.pages["L"] == 2, "perf fixture published")
    }
}

extension SyncTests {
    static func emptyCalendarListKeepsData() async {
        let (h, a, token, syncer, client) = setup("sync-empty-list")
        h.google.put(token: token, calendar: "me@orb.example", G.timed("k", "Keep", "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z"))
        _ = try? await syncer.sync(accountId: a.id, client: client, force: false)
        h.google.inject("calendarList", status: 200, body: #"{"items":[]}"#)
        do {
            _ = try await syncer.sync(accountId: a.id, client: client, force: true)
            expect(false, "empty calendar list should not succeed")
        } catch {
            expect((try? EventRepo(db: h.db).count(accountId: a.id)) == 1, "an empty calendar list never wipes the account")
        }
    }
}
