import Foundation

/// The Day kind wired (D-022): snapshot → design for every family, the routes its links build (‹ ›, ↻,
/// "+N" / empty grid, blocks, Join, back to today) round-trip through the router with valid link keys,
/// a custom slot set to Day, and the Day's own timeline planning (only the moments its drawing changes,
/// ≤16 + ≤3 settle, one entry until midnight on another day, now-line steps, coalescing).
enum DayWidgetTests {
    static let cal = WidgetCalendar.fixed
    static let now = WidgetSample.fixedNow
    static let day = WidgetKinds.day

    static func model(_ fixture: String, _ kind: String = "day", now: Date? = nil) -> SnapshotModel {
        SnapshotModel(SnapshotFixtures.named(fixture, kind: kind, now: now), logo: { _ in nil })
    }

    static func at(_ h: Int, _ m: Int) -> Date { TimelineTests.at(0, h, m) }

    static func run() {
        resolution()
        links()
        planning()
        nowLine()
        coalescing()
    }

    static func resolution() {
        T.section("day widget: snapshot → design")
        let busy = model("busy")
        T.equal(busy.snapshot.content, .day, "busy-day.json carries content .day")
        T.equal(busy.content, .day, "SnapshotModel maps it")
        T.check(busy.meetings.allSatisfy { cal.isDate($0.start, inSameDayAs: now) }, "only today's meetings in the fixture")
        for family in Family.allCases {
            T.equal(KindView.resolve(spec: day, family: family, data: busy.data(at: now)), .design(.day), "Day \(family.short) → Day design")
        }
        let custom = model("customDay", "custom.f")
        T.equal(custom.snapshot.title, "Work", "custom slot title")
        for family in Family.allCases {
            T.equal(KindView.resolve(spec: WidgetKinds.spec("custom.f")!, family: family, data: custom.data(at: now)), .design(.day),
                    "Custom F set to Day, \(family.short) → Day design")
        }
        T.equal(KindView.resolve(spec: day, family: .large, data: model("noAccounts").data(at: now)), .card(.noAccounts), "no accounts → card")
        var setup = SnapshotFixtures.named("busy", kind: "custom.f"); setup.content = .setup
        T.equal(KindView.resolve(spec: WidgetKinds.spec("custom.f")!, family: .large,
                                 data: SnapshotModel(setup, logo: { _ in nil }).data(at: now)), .card(.setup), "set-up slot → card")

        let picked = model("dayPicked")
        let wednesday = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!
        T.equal(picked.data(at: now).selectedDay, wednesday, "selectedDay from the snapshot")
        T.check(picked.meetings.allSatisfy { $0.start < cal.date(byAdding: .day, value: 1, to: wednesday)! && $0.end > wednesday },
                "dayPicked carries Wednesday's meetings only")
        T.check(picked.meetings.contains { $0.allDay }, "…its all-day offsite included")
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        T.equal(picked.data(at: midnight).selectedDay, midnight, "the pick resets to today at midnight")
        let wed = DayTimelineWidget.layout(family: .large, meetings: picked.meetings, day: wednesday, now: now, style: WidgetStyle()).model
        T.check(!wed.isToday && wed.focusId == nil, "another day: no focus ring, no Join")
        T.equal(wed.plan.allDay.count, 1, "the all-day row")

        let twenty = model("busyDay")
        T.equal(twenty.meetings.count, 20, "busyDay: 20 meetings")
        let rows = KindView.meetingRows(spec: day, family: .large, data: twenty.data(at: now), style: WidgetStyle())
        T.check((rows ?? 0) >= 17 && (rows ?? 0) <= 20, "Large draws the whole day (got \(rows ?? -1) blocks; the rest on +N)")
        let small = KindView.meetingRows(spec: day, family: .small, data: twenty.data(at: now), style: WidgetStyle()) ?? 0
        T.check(small >= 1 && small < 10, "Small draws its slice (got \(small))")
        let shown = KindView.shownMeetings(spec: day, family: .large, data: twenty.data(at: now), style: WidgetStyle())
        T.equal(shown.rows.map(\.title), ["The Comets weekly sync"], "drawn live at 9:48: the 10:00 meeting (focus ring + Join)")
        let later = DayTimelineWidget.drawing(family: .large, meetings: twenty.meetings, day: now, now: at(10, 20), style: WidgetStyle())
        let standUp = twenty.meetings.first { $0.title == "Team stand-up" }!.id
        T.check(later.past.contains(standUp), "10:20: the stand-up has faded")
        T.check(later.nowVisible, "10:20: the now line shows")
    }

    static func links() {
        T.section("day widget: routes round-trip with link keys")
        let m = model("busy")
        let data = m.data(at: now)
        let ctx = WidgetLinkContext(kind: "day", family: .large, windowStart: data.windowStart, windowEnd: data.windowEnd)
        func decide(_ url: URL?) -> RouteAction? {
            url.flatMap(Route.parse).map { RouteDecider.decide($0, verify: FixtureLinkKeys.verify) }
        }
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!, tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        T.equal(decide(ctx.selectDay(yesterday)), .selectDay(kind: "day", day: "2026-10-18"), "‹ → day?w=day&d=<yesterday>")
        T.equal(decide(ctx.selectDay(tomorrow)), .selectDay(kind: "day", day: "2026-10-20"), "› → day?w=day&d=<tomorrow>")
        T.equal(ctx.selectDay(tomorrow).flatMap(Route.parse)?.quiet, true, "‹ › are quiet")
        func date(_ y: Int, _ mo: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: mo, day: d, hour: 12))! }
        T.check(ctx.selectDay(date(2026, 9, 28)) != nil && ctx.selectDay(date(2026, 9, 27)) == nil, "‹ stops at the window's first day")
        T.check(ctx.selectDay(date(2026, 12, 31)) != nil && ctx.selectDay(date(2027, 1, 1)) == nil, "› stops at the window's last day")
        T.equal(decide(ctx.today(now)), .selectDay(kind: "day", day: "2026-10-19"), "header / Today → day?w&d=<today>")
        T.equal(decide(ctx.openDay(now)), .openDay(kind: "day", day: "2026-10-19"), "+N / empty grid → open/day?w&d")
        T.equal(Route.parse(ctx.openDay(now))?.quiet, false, "open/day shows the Peek (not quiet)")
        T.equal(decide(ctx.refresh()), .sync(kind: "day"), "↻ → sync?w=day")
        let row = m.meetings.first { $0.hasLink }!
        T.equal(decide(ctx.event(row)), .openEvent(r: row.r!), "block → open/event?r&k (key verifies)")
        T.equal(decide(ctx.join(row)), .join(r: row.r!), "Join → join?r&k (key verifies)")
        var forged = row; forged.k = String(repeating: "A", count: 16)
        T.equal(decide(ctx.join(forged)), .ignore(route: "join", reason: "bad-key"), "a forged key is ignored")
        let custom = WidgetLinkContext(kind: "custom.f", family: .medium, windowStart: data.windowStart, windowEnd: data.windowEnd)
        T.equal(decide(custom.refresh()), .sync(kind: "custom.f"), "custom slot ↻ → sync?w=custom.f")
        T.equal(decide(custom.selectDay(tomorrow)), .selectDay(kind: "custom.f", day: "2026-10-20"),
                "custom slot ‹ › pick in place on Medium too")
        T.check(WidgetLinkContext(kind: "day", family: .small).selectDay(date(2030, 1, 1)) != nil, "no window (sample) → unbounded")
    }

    static func planning() {
        T.section("day widget: timeline (only where the drawing changes; ≤16 + ≤3)")
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let twenty = model("busyDay")
        var counts: [String] = []
        for family in Family.allCases {
            let full = TimelinePlan.timeline(now: now, model: twenty, spec: day, family: family, calendar: cal)
            let planned = TimelinePlan.entryDates(now: now, model: twenty, spec: day, family: family, calendar: cal)
            T.equal(planned.first, now, "\(family.short): first entry is now")
            T.check(zip(planned, planned.dropFirst()).allSatisfy { $0 < $1 }, "\(family.short): entries in order")
            T.check(planned.count <= TimelinePlan.maxEntries, "\(family.short): ≤16 planned (got \(planned.count))")
            T.check(full.entries.count - planned.count <= TimelinePlan.maxSettleEntries, "\(family.short): ≤3 settle entries")
            T.check(planned.allSatisfy { $0 <= midnight }, "\(family.short): ends by midnight")
            T.check(full.reload <= midnight && full.reload > now, "\(family.short): reload due by midnight")
            counts.append("\(family.short) \(planned.count)+\(full.entries.count - planned.count)")
        }
        T.note("busyDay at 9:48, entries planned+settle: \(counts.joined(separator: ", "))")

        // Another day: one entry until midnight (plus the moment the stale strip appears).
        let picked = model("dayPicked")
        for family in Family.allCases {
            let planned = TimelinePlan.entryDates(now: now, model: picked, spec: day, family: family, calendar: cal)
            let allowed = Set([now, midnight] + [TimelinePlan.staleAt(picked)].compactMap { $0 })
            T.check(planned.count <= 3 && Set(planned).isSubset(of: allowed),
                    "\(family.short) another day: now, the stale strip, midnight (got \(planned.count))")
            let full = TimelinePlan.timeline(now: now, model: picked, spec: day, family: family, calendar: cal)
            T.equal(full.entries.count, planned.count, "\(family.short) another day: no settle entries")
        }

        // Moments: focus at start − 30 (10:00 meeting → 9:30 is past; 10:30 → 10:00), starts, ends.
        let large = Set(TimelinePlan.entryDates(now: now, model: twenty, spec: day, family: .large, calendar: cal))
        T.check(large.contains(at(10, 0)), "L: 10:00 (starts, focus hand-over)")
        T.check(large.contains(at(10, 15)), "L: 10:15 (the 9:00 → 10:15 hand-overs continue)")
        // No countdown marks: a Day draws no "in 5 min".
        T.check(!large.contains(at(9, 55)) && !large.contains(at(9, 59)), "L: no −5 / −1 min countdown entries")
        // S / M windows slide at :10 / :40.
        let early = TimelinePlan.entryDates(now: at(6, 0), model: twenty, spec: day, family: .small, calendar: cal)
        T.check(early.contains(at(6, 10)) && early.contains(at(6, 40)), "S: the slice slides at :10 and :40")
        let medium = TimelinePlan.entryDates(now: at(6, 0), model: twenty, spec: day, family: .medium, calendar: cal)
        T.check(medium.contains(at(6, 10)), "M: the slice slides at :10")
        // An evening past the last meeting: L's window ends at 8 PM, the now line is off it, nothing moves.
        let evening = TimelinePlan.entryDates(now: at(21, 5), model: twenty, spec: day, family: .large, calendar: cal)
        T.equal(evening, [at(21, 5), midnight], "L 21:05 after the day: now, then midnight")
        // A quiet afternoon on a light day: the now line still steps every half hour while it shows.
        let light = TimelinePlan.entryDates(now: at(12, 5), model: model("sparse"), spec: day, family: .large, calendar: cal)
        T.check(light.contains(at(12, 30)) && light.contains(at(13, 0)), "L light day: half-hour now-line steps")

        // Planning cost stays small (it runs on every reload).
        let t0 = DispatchTime.now().uptimeNanoseconds
        for family in Family.allCases { _ = TimelinePlan.timeline(now: now, model: twenty, spec: day, family: family, calendar: cal) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 5
        T.note(String(format: "Day planning: %.1f ms per timeline (busyDay, 9:48)", ms))
        T.check(ms < 250, "planning under 250 ms per timeline (got \(ms))")
    }

    /// While the now line shows, the entry in force is never more than 30 min (+2 min coalescing) old.
    static func nowLine() {
        T.section("day widget: the now line never waits more than 30 min")
        var worst = 0.0
        for fixture in ["busyDay", "busy", "sparse", "empty"] {
            let m = model(fixture)
            for family in Family.allCases {
                for start in [now, at(13, 50), at(20, 20)] {
                    let planned = TimelinePlan.entryDates(now: start, model: m, spec: day, family: family, calendar: cal)
                    guard let last = planned.last else { continue }
                    var t = start
                    while t < last {
                        let d = DayTimelineWidget.drawing(family: family, meetings: m.meetings, day: start, now: t, style: WidgetStyle())
                        if d.nowVisible, let inForce = planned.last(where: { $0 <= t }) {
                            worst = max(worst, t.timeIntervalSince(inForce))
                        }
                        t = t.addingTimeInterval(60)
                    }
                }
            }
        }
        T.check(worst <= TimelinePlan.dayNowStep + TimelinePlan.dayCoalesce,
                "worst now-line age \(Int(worst / 60)) min (≤ 32)")
    }

    /// Changes closer than 2 min draw as one entry, at the later moment.
    static func coalescing() {
        T.section("day widget: moments closer than 2 min coalesce")
        var snap = SnapshotFixtures.named("busy", kind: "day")
        // 10:00–10:59 and 10:30–11:00 end a minute apart (both fade; XL's "x of y left" moves twice).
        let start = at(11, 0)
        let rows = [(at(10, 0), at(10, 59)), (at(10, 30), start), (at(13, 0), at(14, 0))]
        snap.meetings = rows.enumerated().map { i, r in
            FixtureMeeting(r: "co\(i)", accounts: [FixtureAccounts.orb], title: "C\(i)", start: r.0, end: r.1,
                           join: URL(string: "https://meet.google.com/x")).snapshotRow
        }
        let m = SnapshotModel(snap, logo: { _ in nil })
        for family in Family.allCases {
            let planned = TimelinePlan.entryDates(now: now, model: m, spec: day, family: family, calendar: cal)
            let gaps = zip(planned.dropFirst(), planned.dropFirst(2)).map { $1.timeIntervalSince($0) }
            T.check(gaps.allSatisfy { $0 >= TimelinePlan.dayCoalesce }, "\(family.short): no two entries within 2 min")
            T.check(planned.contains(start) && !planned.contains(start.addingTimeInterval(-60)),
                    "\(family.short): 10:59 and 11:00 ends → one entry at 11:00")
        }
    }
}
