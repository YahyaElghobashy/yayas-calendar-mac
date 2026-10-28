import Foundation

/// The Day kind (D-022) on the data layer: `widget/day.json` carries the day shown and only its meetings;
/// ‹ › (`selectDay`) picks a day inside the sync window, back to today at midnight; Custom slots set to
/// Day publish the same with their own accounts; caps hold.
enum DayPublishTests {
    static func run() {
        let (h, accounts) = PublishTests.seeded("day-publish")
        let engine = h.engine
        let w = engine.widgets
        engine.tick()   // the engine notes today, so the clock passing midnight below counts as a new day
        engine.publisher.publishAll(reason: .background)

        guard let today = h.snapshot("day") else { expect(false, "day snapshot"); return }
        expect(today.kind == "day" && today.content == .day, "day.json written with content .day")
        expect(today.meetings.map(\.title) == ["Standup"], "today only: other days, declined rows and excluded accounts out")
        expect(today.selectedDay == nil && today.monthShown == nil && today.busyDays.isEmpty, "today: no pick, no Month fields")
        expect(today.windowStart == "2026-09-28" && today.windowEnd == "2026-12-31", "window keys for the arrows")
        expect(today.meetings.allSatisfy { w.verify(r: $0.r, k: $0.k) }, "every row's k verifies")
        expect(today.accounts.map(\.tag) == ["ORB", "CMT"], "the kind's accounts (Include in All)")

        // ‹ ›: day?w=day&d → selectDay → that day's meetings, this kind reloaded alone.
        h.reloader.reset()
        w.selectDay(kind: "day", day: "2026-10-20")
        let tuesday = h.snapshot("day")
        expect(tuesday?.selectedDay == "2026-10-20" && tuesday?.meetings.map(\.title) == ["Review", "Clash"],
               "picked day: that day's meetings only")
        expect(h.reloader.reloads.value == ["day"], "the tap reloads only the Day kind")
        expect(h.snapshot("month")?.selectedDay == nil, "Month keeps its own pick")
        w.selectDay(kind: "day", day: "2026-10-29")
        let trip = h.snapshot("day")
        expect(trip?.meetings.map(\.title) == ["Trip"] && trip?.meetings.first?.allDay == true, "an all-day event covering the day")
        w.selectDay(kind: "day", day: "2026-10-21")
        expect(h.snapshot("day")?.meetings.isEmpty == true, "a day with only a declined meeting carries none")

        // The sync window clamps the arrows: outside it nothing is stored.
        h.reloader.reset()
        w.selectDay(kind: "day", day: "2027-01-01")
        w.selectDay(kind: "day", day: "2026-09-25")
        w.selectDay(kind: "day", day: "nonsense")
        expect(h.snapshot("day")?.selectedDay == "2026-10-21" && h.reloader.reloads.value.isEmpty, "days outside the window are ignored")
        w.selectDay(kind: "day", day: "2026-12-31")
        expect(h.snapshot("day")?.selectedDay == "2026-12-31", "the window's last day is reachable")
        w.selectDay(kind: "day", day: "2026-09-28")
        expect(h.snapshot("day")?.selectedDay == "2026-09-28", "the window's first day is reachable")

        // Back to today at midnight (the pick was made yesterday).
        w.selectDay(kind: "day", day: "2026-10-22")
        h.clock.set(TestCal.local(2026, 10, 20, 0, 1))
        engine.tick()
        let fresh = h.snapshot("day")
        expect(fresh?.selectedDay == nil && fresh?.meetings.map(\.title) == ["Review", "Clash"], "back to today at midnight")

        // Custom slot set to Day: its own accounts, its own pick.
        var settings = WidgetSettings(kind: "custom.d")
        settings.title = "CMT day"
        settings.customContent = .day
        settings.accountIds = [accounts[1].id]
        h.reloader.reset()
        try? w.save(settings)
        let custom = h.snapshot("custom.d")
        expect(custom?.content == .day && custom?.title == "CMT day" && custom?.accounts.map(\.tag) == ["CMT"],
               "custom slot set to Day: content + its accounts")
        expect(custom?.meetings.map(\.title) == ["Review"], "…only its accounts' meetings that day")
        expect(h.reloader.reloads.value == ["custom.d"], "save reloads that slot")
        expect(w.settings(kind: "custom.d").customContent == .day, "Day survives the settings row round trip")
        w.selectDay(kind: "custom.d", day: "2026-10-19")
        expect(h.snapshot("custom.d")?.selectedDay == "2026-10-19" && h.snapshot("day")?.selectedDay == nil,
               "a custom slot's pick is its own")
        let row = WidgetSettingsCodec.row(from: settings)
        expect(row.customContent == "day", "stored as \"day\"")

        // Cap: 150 meetings on one day → the first 120.
        let repo = EventRepo(db: h.db)
        for i in 0..<150 {
            let start = TestCal.local(2026, 10, 20, 8).addingTimeInterval(Double(i) * 60)
            try? repo.upsert(Seed.row(accounts[0].id, id: "dbulk\(i)", title: "Bulk \(i)", start: start, end: start.addingTimeInterval(1800)))
        }
        w.selectDay(kind: "day", day: "2026-10-20")
        let capped = h.snapshot("day")
        expect(capped?.meetings.count == 120 && capped?.meetings.first?.title == "Bulk 0", "Day capped at 120, earliest kept")
        let size = (try? Data(contentsOf: engine.publisher.url(kind: "day")))?.count ?? .max
        expect(size <= WidgetSnapshot.maxBytes, "day.json within 192 KB")
    }
}
