import Foundation

/// A widget's ↻ (`sync?w=<kind>`, WidgetRefresh.swift): a forced full re-list of the widget's accounts,
/// so a cancelled meeting the change feed never reported still disappears; only that widget's accounts;
/// a loop sleeping off a backoff is left alone; the tapped kind reloads once at the end.
enum RefreshTests {
    static func run() async {
        await cancelledMeetingDisappears()
        await onlyTheWidgetsAccounts()
        await throughTheLoops()
        targets()
        governorReload()
    }

    static let planning = G.timed("e1", "Planning", "2026-10-19T12:00:00+01:00", "2026-10-19T13:00:00+01:00")
    static let standup = G.timed("e2", "Client standup", "2026-10-19T15:00:00+01:00", "2026-10-19T15:30:00+01:00")
    static let review = G.timed("e3", "Party planning", "2026-10-20T11:00:00+01:00", "2026-10-20T12:00:00+01:00")

    static func windowLists(_ h: Harness, token: String? = nil) -> Int {
        h.google.requests.filter { request in
            (request.url.query?.contains("singleEvents=true") ?? false)
                && (token.map { request.headers["Authorization"] == "Bearer \($0)" } ?? true)
        }.count
    }

    /// The live bug class: a meeting cancelled on Google stays in the widget until the next 15-minute
    /// re-list when the change feed says nothing. A refresh tap removes it at once.
    static func cancelledMeetingDisappears() async {
        let h = Harness("refresh-cancelled")
        let (orb, token) = h.account("y@orb.example", tag: "ORB", sort: 0)
        h.google.addCalendar(token: token, id: "team@orb.example", summary: "Team", selected: true)
        h.google.put(token: token, calendar: "y@orb.example", planning)
        h.google.put(token: token, calendar: "y@orb.example", standup)
        h.google.put(token: token, calendar: "team@orb.example", review)
        let engine = h.engine
        engine.start()
        _ = await engine.syncAccount(orb.id, force: false)
        expect(h.snapshot("agenda.all")?.meetings.map(\.title) == ["Planning", "Client standup", "Party planning"],
               "refresh: three meetings synced")

        // Cancelled on Google; the change feed never mentions it (a feed hiccup, a consumed token).
        h.google.vanish(token: token, calendar: "y@orb.example", eventId: "e2")
        h.clock.advance(60)
        _ = await engine.syncAccount(orb.id, force: false)
        expect(h.snapshot("agenda.all")?.meetings.contains { $0.title == "Client standup" } == true,
               "refresh: a feed-only pass keeps the cancelled meeting (the bug)")

        h.reloader.reset()
        let lists = windowLists(h)
        let report = await engine.refreshWidgets(["agenda.all"])
        engine.finishRefresh(["agenda.all"])
        expect(windowLists(h) - lists == 2, "refresh: every selected calendar's window listed in full (2)")
        expect(h.snapshot("agenda.all")?.meetings.map(\.title) == ["Planning", "Party planning"],
               "refresh: the cancelled meeting is gone from the widget")
        expect((try? EventRepo(db: h.db).count(accountId: orb.id)) == 2, "refresh: …and from the store")
        expect(report.calendarAccounts == 1 && report.mailAccounts == 0 && report.backingOff == 0 && report.ok,
               "refresh: report (1 calendar account, ok)")
        expect(report.traceResult == "ok cal=1 mail=0 backoff=0", "refresh: PII-free trace result")
        expect(h.reloader.count("agenda.all") == 1, "refresh: the tapped kind reloads exactly once")
        let synced = h.snapshot("agenda.all")?.health.syncedAt
        expect(synced == h.clock.now, "refresh: the widget's syncedAt is the refresh (✓ synced just now)")

        // Nothing changed since: the tap still reloads (the user asked), once.
        h.clock.advance(5)
        h.reloader.reset()
        _ = await engine.refreshWidgets(["agenda.all"])
        engine.finishRefresh(["agenda.all"])
        expect(h.reloader.count("agenda.all") == 1, "refresh: an unchanged widget still reloads once")

        // Offline: the pass fails, the widget keeps its data, the health strip follows the usual rules.
        h.google.inject("calendarList", status: 503, times: 1)
        let failed = await engine.refreshWidgets(["agenda.all"])
        engine.finishRefresh(["agenda.all"])
        expect(!failed.ok && failed.traceResult.hasPrefix("server_error"), "refresh: a failed pass is reported")
        expect(h.snapshot("agenda.all")?.meetings.count == 2, "refresh: a failed pass keeps the data")
        expect(SyncStatusRepo(db: h.db).lastError(orb.id) == "server_error", "refresh: the error is recorded as for any pass")
    }

    /// Only the tapped widget's accounts sync: "Include in All" for the built-in kinds, the Studio pick for
    /// a custom slot.
    static func onlyTheWidgetsAccounts() async {
        let h = Harness("refresh-accounts")
        let (_, orbToken) = h.account("y@orb.example", tag: "ORB", sort: 0)
        let (cmt, cmtToken) = h.account("y@cmt.example", tag: "CMT", sort: 1, includeInAll: false)
        h.google.put(token: orbToken, calendar: "y@orb.example", planning)
        h.google.put(token: cmtToken, calendar: "y@cmt.example", standup)
        let engine = h.engine
        engine.start()
        var settings = engine.widgets.settings(kind: "custom.b")
        settings.customContent = .agenda
        settings.accountIds = [cmt.id]
        try? engine.widgets.save(settings)

        h.google.clearLog()
        let all = await engine.refreshWidgets(["agenda.all"])
        expect(all.calendarAccounts == 1 && windowLists(h, token: orbToken) == 1 && windowLists(h, token: cmtToken) == 0,
               "refresh: agenda.all syncs only the Include-in-All account")
        h.google.clearLog()
        let custom = await engine.refreshWidgets(["custom.b"])
        expect(custom.calendarAccounts == 1 && windowLists(h, token: cmtToken) == 1 && windowLists(h, token: orbToken) == 0,
               "refresh: a custom slot syncs only its picked account")
        engine.finishRefresh(["custom.b"])
        expect(h.snapshot("custom.b")?.meetings.map(\.title) == ["Client standup"], "refresh: the custom slot shows it")

        h.google.clearLog()
        let both = await engine.refreshWidgets(["agenda.all", "custom.b", "month"])
        expect(both.calendarAccounts == 2 && windowLists(h) == 2, "refresh: one batch syncs each account once")

        h.google.clearLog()
        let setup = await engine.refreshWidgets(["custom.f"])
        expect(setup.calendarAccounts == 0 && h.google.requests.isEmpty, "refresh: a slot not set up syncs nothing")
        h.reloader.reset()
        engine.finishRefresh(["custom.f"])
        expect(h.reloader.count("custom.f") == 1, "refresh: …but still republishes and reloads it")
        let unknown = await engine.refreshWidgets(["nope"])
        expect(unknown.kinds.isEmpty && unknown.calendarAccounts == 0, "refresh: unknown kinds are dropped")
    }

    /// With loops running: a refresh is a forced pass through the account's loop (never a second pass
    /// alongside it), and a loop sleeping off a 429 backoff is left alone.
    static func throughTheLoops() async {
        var timing = SyncTiming()
        timing.interval = 3600
        timing.visibleInterval = 3600
        timing.tick = 3600
        let h = Harness("refresh-loops", runLoops: true, timing: timing)
        let (orb, token) = h.account("y@orb.example", tag: "ORB", sort: 0)
        h.google.put(token: token, calendar: "y@orb.example", planning)
        h.google.put(token: token, calendar: "y@orb.example", standup)
        let engine = h.engine
        engine.start()
        do { let ok = await eventually(3) { await engine.loop(orb.id)?.lastOutcome == .ok }; expect(ok, "refresh: first loop pass") }
        let runs = await engine.loop(orb.id)?.runs ?? 0
        h.google.vanish(token: token, calendar: "y@orb.example", eventId: "e2")
        let report = await engine.refreshWidgets(["month"])
        expect(report.ok && report.backingOff == 0, "refresh: loop pass ok")
        let after = await engine.loop(orb.id)?.runs ?? 0
        expect(after == runs + 1, "refresh: exactly one forced pass through the loop")
        expect(h.snapshot("month")?.meetings.map(\.title) == ["Planning"], "refresh: cancelled meeting gone via the loop")

        // Google says 429: the loop backs off; a refresh doesn't cut that short.
        h.google.inject("calendarList", status: 429, headers: ["Retry-After": "600"], times: 1)
        await engine.syncAll(force: true)
        do {
            let ok = await engine.loop(orb.id)?.lastOutcome.map { if case .rateLimited = $0 { return true } else { return false } } ?? false
            expect(ok, "refresh: loop rate-limited")
        }
        let before = h.google.requests.count
        let held = await engine.refreshWidgets(["month"])
        expect(held.backingOff == 1 && held.outcomes.isEmpty, "refresh: backing-off account left alone")
        expect(h.google.requests.count == before, "refresh: no request during a backoff")
        await engine.stop()
    }

    /// Which accounts each kind's ↻ syncs.
    static func targets() {
        let h = Harness("refresh-targets")
        let (orb, _) = h.account("y@orb.example", tag: "ORB", sort: 0)
        let (cmt, _) = h.account("y@cmt.example", tag: "CMT", sort: 1)
        _ = try? AccountRepo(db: h.db).update({ var a = cmt; a.calendarEnabled = false; return a }())
        let engine = h.engine
        func t(_ kind: String) -> (calendar: Set<UUID>, mail: Set<UUID>) { engine.refreshTargets(kind: kind) }
        expect(t("agenda.all").calendar == [orb.id] && t("agenda.all").mail.isEmpty, "targets: Agenda = calendar accounts")
        expect(t("month").calendar == [orb.id] && t("upnext").calendar == [orb.id], "targets: Month, Up Next")
        expect(t("inbox.all").calendar.isEmpty && t("inbox.all").mail.isEmpty, "targets: Inbox with mail off → nothing")
        h.labsMail.value = true
        expect(t("inbox.all").calendar.isEmpty && t("inbox.all").mail == [orb.id, cmt.id], "targets: Inbox = mail accounts")
        expect(t("combo.all").calendar == [orb.id] && t("combo.all").mail == [orb.id, cmt.id], "targets: Agenda & Inbox = both")
        expect(t("custom.a").calendar.isEmpty && t("custom.a").mail.isEmpty, "targets: slot not set up → nothing")
    }

    static func governorReload() {
        let clock = TestClock(TestCal.labNow)
        let reloader = FakeReloader()
        let gov = ReloadGovernor(reloader: reloader, budget: 15 * 60, now: clock.closure)
        let start = clock.now
        expect(gov.reload("month", unlessSince: start), "refresh reload: none since the start → reload")
        expect(!gov.reload("month", unlessSince: start), "refresh reload: one already went out → not twice")
        clock.advance(10)
        gov.changed("agenda.all", content: 1, significant: 1, interaction: true)
        expect(!gov.reload("agenda.all", unlessSince: start), "refresh reload: a changed snapshot already reloaded it")
        expect(gov.reload("agenda.all", unlessSince: clock.now.addingTimeInterval(1)), "refresh reload: a later refresh reloads")
        expect(reloader.count("month") == 1 && reloader.count("agenda.all") == 2, "refresh reload: counts")
        expect(gov.state("month")?.lastReload == start && gov.state("month")?.everReloaded == true, "refresh reload: recorded")
        expect(gov.reload("custom.c", unlessSince: nil), "refresh reload: an unseen kind reloads")
    }
}
