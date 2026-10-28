import Foundation

/// WidgetInteractions + WidgetSettingsStore: state → publish that kind → reload it now.
enum InteractionTests {
    static func run() {
        let (h, accounts) = PublishTests.seeded("interactions")
        let engine = h.engine
        let w = engine.widgets
        engine.start()
        // Spend the background budget so only interactions can reload.
        h.reloader.reset()

        w.page(kind: "agenda.all", family: "L", to: 2)
        var snap = h.snapshot("agenda.all")
        expect(snap?.pages == ["L": 2] && snap?.pageResetAt == h.clock.now.addingTimeInterval(300), "page stored, reset in 5 min")
        expect(h.reloader.count("agenda.all") == 1, "page flip reloads that kind at once")
        expect(h.reloader.reloads.value == ["agenda.all"], "…and only that kind")
        h.clock.advance(60)
        w.page(kind: "agenda.all", family: "XL", to: 3)
        snap = h.snapshot("agenda.all")
        expect(snap?.pages == ["L": 2, "XL": 3] && snap?.pageResetAt == h.clock.now.addingTimeInterval(300), "per-family pages; latest reset")
        h.clock.advance(301)
        engine.publisher.publish(kind: "agenda.all", reason: .background)
        expect(h.snapshot("agenda.all")?.pages.isEmpty == true && h.snapshot("agenda.all")?.pageResetAt == nil, "pages back to 1 after 5 min")
        w.page(kind: "agenda.all", family: "L", to: 1)
        expect(h.snapshot("agenda.all")?.pages.isEmpty == true, "page 1 is the default (not stored in the snapshot)")

        h.reloader.reset()
        w.page(kind: "agenda.all", family: "Huge", to: 2)
        w.page(kind: "nope", family: "L", to: 2)
        w.selectDay(kind: "month", day: "2027-05-01")
        w.selectDay(kind: "month", day: "garbage")
        w.setRange(kind: "agenda.all", days: 5)
        expect(h.reloader.reloads.value.isEmpty, "bad family/kind/day/range ignored")
        expect(((try? engine.widgets.repo.states(kind: "nope")) ?? [WidgetStateRow(kind: "x", family: "y")]).isEmpty,
               "nothing stored for an unknown kind")

        w.selectDay(kind: "month", day: "2026-10-20")
        let month = h.snapshot("month")
        expect(month?.selectedDay == "2026-10-20" && h.reloader.count("month") == 1, "day pick stored + reloaded")
        expect(month?.meetings.first?.title == "Review", "month meetings start at the picked day")
        w.showMonth(kind: "month", month: "2026-11")
        expect(h.snapshot("month")?.monthShown == "2026-11", "month shown")
        w.showMonth(kind: "month", month: "2027-06")
        expect(h.snapshot("month")?.monthShown == "2026-12", "month clamps to the window's last month")
        w.showMonth(kind: "month", month: "2026-01")
        expect(h.snapshot("month")?.monthShown == "2026-10", "month clamps to this month")
        expect(h.snapshot("month")?.selectedDay == "2026-10-20", "showing a month keeps the picked day")

        w.setRange(kind: "agenda.all", days: 2)
        expect(h.snapshot("agenda.all")?.rangeDays == 2 && h.snapshot("agenda.all")?.meetings.map(\.title) == ["Standup", "Review", "Clash"],
               "range 2 = today + tomorrow")

        // Midnight: picks, months and ranges set yesterday are forgotten.
        h.clock.set(TestCal.local(2026, 10, 20, 0, 1))
        engine.tick()
        let fresh = h.snapshot("month")
        expect(fresh?.selectedDay == nil && fresh?.monthShown == nil, "selectedDay/monthShown reset at midnight")
        expect(h.snapshot("agenda.all")?.rangeDays == 7, "range back to the Studio value")

        // Studio settings round trip.
        var settings = w.settings(kind: "custom.f")
        expect(settings.customContent == nil && settings.accountIds == nil && settings.rangeDays == 7, "defaults")
        settings.title = "CMT only"
        settings.customContent = .upNext
        settings.accountIds = [accounts[1].id]
        settings.rangeDays = 2
        settings.style = WidgetSnapshot.Style(look: .paper, typeface: "serif", textSize: "large", showLogos: false, use24Hour: true)
        h.reloader.reset()
        try? w.save(settings)
        let back = w.settings(kind: "custom.f")
        expect(back == settings, "settings round trip")
        let custom = h.snapshot("custom.f")
        expect(custom?.content == .upNext && custom?.title == "CMT only" && custom?.style.look == .paper && custom?.style.use24Hour == true,
               "saved settings published")
        expect(h.reloader.reloads.value == ["custom.f"], "save reloads that kind")
        var agendaSettings = w.settings(kind: "agenda.all")
        agendaSettings.title = "ignored"
        agendaSettings.customContent = .month
        agendaSettings.rangeDays = 9
        try? w.save(agendaSettings)
        let stored = w.settings(kind: "agenda.all")
        expect(stored.title == nil && stored.customContent == nil && stored.rangeDays == 7, "fixed kinds ignore custom fields; range coerced")
        var thrown = false
        do { try w.save(WidgetSettings(kind: "bogus")) } catch { thrown = true }
        expect(thrown, "unknown kind can't be saved")

        // Links.
        let row = h.snapshot("agenda.all")?.meetings.first
        expect(row.map { w.verify(r: $0.r, k: $0.k) } == true, "verify accepts a published row")
        expect(row.map { w.verify(r: $0.r, k: "AAAAAAAAAAAAAAAA") } == false, "verify rejects a forged key")
        let resolved = row.flatMap { try? engine.calendarStore.event(r: $0.r) }
        expect(resolved?.title == row?.title, "published r resolves through CalendarStore.event(r:)")
    }
}
