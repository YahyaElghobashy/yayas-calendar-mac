import Foundation

/// The running engine: DataServices wiring, loops per account, accounts changes, midnight, visible
/// surfaces, diagnostics.
enum EngineTests {
    static func run() async {
        await servicesLifecycle()
        await accountsComeAndGo()
        await diagnostics()
    }

    static func servicesLifecycle() async {
        var timing = SyncTiming()
        timing.interval = 3600
        timing.visibleInterval = 3600
        timing.tick = 0.05
        let h = Harness("engine-services", runLoops: true, timing: timing)
        let (orb, token) = h.account("y@orb.example", tag: "ORB", sort: 0)
        h.google.put(token: token, calendar: "y@orb.example",
                     G.timed("e1", "Planning", "2026-10-19T12:00:00+01:00", "2026-10-19T13:00:00+01:00",
                             video: ["https://meet.google.com/abc-defg-hij"]))
        expect(Services.calendar is EmptyStores, "empty stores before start")
        let engine = DataServices.start(environment: h.env)
        expect(DataServices.start(environment: h.env) === engine, "start is idempotent")
        expect(Services.calendar is LocalCalendarStore && Services.calendarActions is LocalCalendarStore, "calendar stores installed")
        expect(Services.widgetSettings is WidgetService && Services.widgetInteractions is WidgetService, "widget services installed")
        do { let ok = await eventually(3) { h.snapshot("agenda.all")?.meetings.count == 1 }; expect(ok, "first loop pass syncs and publishes") }
        let event = try? Services.calendar.events(from: TestCal.local(2026, 10, 19), to: TestCal.local(2026, 10, 20), accounts: nil).first
        expect(event?.title == "Planning" && event?.joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij",
               "Services.calendar serves synced events with the join link")
        expect(h.reloader.count("agenda.all") >= 1, "background reload sent for the first content")

        // "Sync now" goes through the loop and returns after a forced pass.
        h.google.put(token: token, calendar: "y@orb.example", G.timed("e2", "Added", "2026-10-19T15:00:00+01:00", "2026-10-19T16:00:00+01:00"))
        await Services.calendarActions.syncNow()
        expect(h.snapshot("agenda.all")?.meetings.map(\.title) == ["Planning", "Added"], "syncNow returns with fresh data")

        // A visible surface syncs accounts whose last pass is older than the visible interval (1 min live).
        let lists = { h.google.requests.filter { $0.url.query?.contains("singleEvents=true") ?? false }.count }
        h.clock.advance(3700)   // older than the (test) visible interval
        h.google.put(token: token, calendar: "y@orb.example", G.timed("e3", "Visible", "2026-10-19T17:00:00+01:00", "2026-10-19T18:00:00+01:00"))
        let before = lists()
        DataServices.surfaceVisible = true
        do { let ok = await eventually(3) { lists() > before }; expect(ok, "surface visible → stale account synced") }
        expect(engine.surfaceVisible, "engine knows the surface is visible")
        DataServices.surfaceVisible = false

        // Wake: every loop pokes.
        h.google.put(token: token, calendar: "y@orb.example", G.timed("e4", "Woke", "2026-10-19T19:00:00+01:00", "2026-10-19T20:00:00+01:00"))
        engine.wake()
        do { let ok = await eventually(3) { h.snapshot("agenda.all")?.meetings.contains { $0.title == "Woke" } == true }; expect(ok, "wake → sync") }

        // Midnight through the ticker: kind state cleared, forced re-list, republish.
        engine.widgets.selectDay(kind: "month", day: "2026-10-25")
        expect(h.snapshot("month")?.selectedDay == "2026-10-25", "day picked")
        let listsBefore = lists()
        h.clock.set(TestCal.local(2026, 10, 20, 0, 1))
        do { let ok = await eventually(3) { h.snapshot("month")?.selectedDay == nil }; expect(ok, "midnight tick clears the picked day") }
        do { let ok = await eventually(3) { lists() > listsBefore }; expect(ok, "midnight forces a window re-list") }
        do { let ok = await eventually(3) { h.snapshot("agenda.all")?.meetings.isEmpty == true }; expect(ok, "agenda moved to the new day") }

        await DataServices.stop()
        expect(Services.calendar is EmptyStores && DataServices.engine == nil, "stop puts the empty stores back")
        expect(!engine.isRunning && engine.loop(orb.id) == nil, "loops stopped")
    }

    static func accountsComeAndGo() async {
        var timing = SyncTiming()
        timing.interval = 3600
        timing.tick = 3600
        let h = Harness("engine-accounts", runLoops: true, timing: timing)
        let (orb, _) = h.account("y@orb.example", tag: "ORB", sort: 0)
        let engine = h.engine
        engine.start()
        expect(engine.loop(orb.id) != nil, "a loop per account")
        do { let ok = await eventually(3) { await engine.loop(orb.id)?.lastOutcome == .ok }; expect(ok, "first pass ran") }
        let (cmt, cmtToken) = h.account("y@cmt.example", tag: "CMT", sort: 1)
        h.google.put(token: cmtToken, calendar: "y@cmt.example", G.timed("m", "CMT meeting", "2026-10-20T10:00:00Z", "2026-10-20T11:00:00Z"))
        engine.accountsChanged()
        expect(engine.loop(cmt.id) != nil, "new account → new loop")
        do { let ok = await eventually(3) { h.snapshot("agenda.all")?.meetings.contains { $0.title == "CMT meeting" } == true }; expect(ok, "and it syncs") }
        _ = try? AccountRepo(db: h.db).delete(cmt.id)
        engine.accountsChanged()
        expect(engine.loop(cmt.id) == nil, "removed account → loop stopped")
        expect((try? EventRepo(db: h.db).count(accountId: cmt.id)) == 0, "its events went with it")
        expect(h.snapshot("agenda.all")?.accounts.map(\.tag) == ["ORB"] && h.snapshot("agenda.all")?.meetings.isEmpty == true,
               "snapshot republished without it")

        // A stuck account (reauth) is retried when its row changes (signed in again).
        _ = try? AccountRepo(db: h.db).setHealth(orb.id, .reauthNeeded, detail: nil)
        await engine.syncAll(force: true)
        do { let ok = await engine.loop(orb.id)?.lastOutcome == .waitingForUser; expect(ok, "reauth account waits") }
        _ = try? AccountRepo(db: h.db).setHealth(orb.id, .ok, detail: nil)
        engine.accountsChanged()
        do { let ok = await eventually(3) { await engine.loop(orb.id)?.lastOutcome == .ok }; expect(ok, "signed back in → retried at once") }
        await engine.stop()
    }

    static func diagnostics() async {
        let h = Harness("engine-diagnose")
        let (orb, token) = h.account("secret.person@orb.example", tag: "ORB", sort: 0)
        h.google.put(token: token, calendar: "secret.person@orb.example",
                     G.timed("d", "Top secret title", "2026-10-20T10:00:00Z", "2026-10-20T11:00:00Z"))
        let engine = h.engine
        engine.start()
        _ = await engine.syncAccount(orb.id, force: false)
        let line = await engine.diagnose()
        expect(!line.contains("\n"), "one line")
        let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        let accounts = json?["accounts"] as? [[String: Any]]
        expect(json?["schema"] as? Int == 6 && json?["kind"] as? String == "data-diagnose", "header fields")
        expect(accounts?.first?["events"] as? Int == 1 && accounts?.first?["calendars"] as? Int == 1
               && accounts?.first?["selected"] as? Int == 1 && accounts?.first?["feedTokens"] as? Int == 1, "per-account counts")
        expect(accounts?.first?["lastSync"] is String && accounts?.first?["lastError"] is NSNull, "last sync + error")
        let snapshots = json?["snapshots"] as? [String: Any]
        expect((snapshots?["agenda.all"] as? [String: Any])?["meetings"] as? Int == 1 && snapshots?.count == 12, "snapshot summary per kind")
        expect(!line.contains("secret.person") && !line.contains("Top secret") && !line.contains("access-"),
               "no emails, titles or tokens")
        expect((json?["window"] as? [String]) == ["2026-09-28", "2026-12-31"], "window in the report")
        let offline = Diagnostics.report(db: h.db, widgetDirectory: h.dir.appendingPathComponent("widget"), now: h.clock.now,
                                         calendar: TestCal.lab, loops: [:], running: false)
        expect(offline.contains("\"engine\":\"stopped\"") && offline.contains("\"events\":1"), "works without a running engine")
        await engine.stop()
    }
}
