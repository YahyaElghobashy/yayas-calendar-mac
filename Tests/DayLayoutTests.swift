import Foundation

/// DayLayout (the Day widget's engine): columns, expansion, clipping to the day and window, "+N"
/// overflow, the windows each family shows, a DST day, the focus meeting, and its cost.
enum DayLayoutTests {
    static let cal = WidgetCalendar.fixed
    static let now = WidgetSample.fixedNow   // Monday 19 October 2026, 9:48 AM, London
    static let account = WidgetAccount(id: "t", short: "T", name: "Test", logo: nil)

    static func run() {
        columns()
        expansion()
        backToBack()
        clipping()
        overflow()
        windows()
        dstDay()
        focus()
        cost()
    }

    static func at(_ h: Int, _ m: Int = 0, day: Int = 0, from base: Date = now) -> Date {
        let d = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: base))!
        return cal.date(bySettingHour: h, minute: m, second: 0, of: d)!
    }

    static func meeting(_ id: Int, _ start: Date, minutes: Double, link: Bool = true) -> WidgetMeeting {
        WidgetMeeting(id: id, account: account, title: "M\(id)", start: start, end: start.addingTimeInterval(minutes * 60),
                      place: nil, hasLink: link)
    }

    static func block(_ plan: DayLayout.Plan, _ id: Int) -> DayLayout.Block? { plan.blocks.first { $0.meeting.id == id } }

    static func params(_ minVisual: Double = 15, _ maxColumns: Int = 4) -> DayLayout.Params {
        DayLayout.Params(minVisualMinutes: minVisual, maxColumns: maxColumns)
    }

    static func columns() {
        T.section("day layout: columns")
        // Same start: longest first gets column 0.
        let ms = [meeting(1, at(10), minutes: 30), meeting(2, at(10), minutes: 60), meeting(3, at(10), minutes: 45)]
        let plan = DayLayout.plan(ms, day: now, params: params(), calendar: cal)
        T.equal(plan.blocks.map(\.meeting.id), [2, 3, 1], "same start: longer first")
        T.equal(plan.blocks.map(\.column), [0, 1, 2], "same start: one column each")
        T.check(plan.blocks.allSatisfy { $0.columns == 3 && $0.span == 1 }, "3 columns, no room to grow")
        T.equal(Set(plan.blocks.map(\.cluster)).count, 1, "one cluster")
        // Two separate clusters keep their own column counts.
        let two = DayLayout.plan([meeting(1, at(9), minutes: 30), meeting(2, at(9), minutes: 30), meeting(3, at(14), minutes: 60)],
                                 day: now, params: params(), calendar: cal)
        T.equal(block(two, 3)?.columns, 1, "a later lone meeting is full width")
        T.equal(block(two, 1)?.columns, 2, "the morning pair shares two columns")
    }

    static func expansion() {
        T.section("day layout: expansion into free columns")
        // A 9–12 (col 0), B 9–10 (col 1), C 9–9:30 (col 2), D 10–11 (col 1, after B) grows into col 2.
        let ms = [meeting(1, at(9), minutes: 180), meeting(2, at(9), minutes: 60), meeting(3, at(9), minutes: 30),
                  meeting(4, at(10), minutes: 60)]
        let plan = DayLayout.plan(ms, day: now, params: params(), calendar: cal)
        T.equal(block(plan, 4)?.column, 1, "D reuses B's column")
        T.equal(block(plan, 4)?.span, 2, "D expands right over C's finished column")
        T.equal(block(plan, 2)?.span, 1, "B cannot grow (C overlaps it)")
        T.equal(block(plan, 1)?.span, 1, "A cannot grow")
        T.check(plan.blocks.allSatisfy { $0.columns == 3 }, "three columns in the cluster")
        // Nested: a short meeting inside a long one sits beside it, the long one keeps column 0.
        let nested = DayLayout.plan([meeting(1, at(11, 30), minutes: 60), meeting(2, at(11, 45), minutes: 30)],
                                    day: now, params: params(), calendar: cal)
        T.equal(nested.blocks.map(\.column), [0, 1], "nested: side by side")
    }

    static func backToBack() {
        T.section("day layout: back-to-back and the minimum block")
        let ms = [meeting(1, at(9), minutes: 15), meeting(2, at(9, 15), minutes: 15)]
        let tall = DayLayout.plan(ms, day: now, params: params(15), calendar: cal)
        T.equal(Set(tall.blocks.map(\.cluster)).count, 2, "back-to-back, readable length: two clusters, full width")
        T.check(tall.blocks.allSatisfy { $0.columns == 1 }, "back-to-back: one column each")
        // On a squeezed grid a 15-min meeting is drawn 30 min tall: the next one moves beside it.
        let short = DayLayout.plan(ms, day: now, params: params(30), calendar: cal)
        T.equal(short.blocks.map(\.column), [0, 1], "short blocks never cover the next one")
        T.check(short.blocks[0].visualEnd == at(9, 30), "visual end = start + minimum")
    }

    static func clipping() {
        T.section("day layout: clipping to the day and the window")
        var allDay = meeting(1, cal.startOfDay(for: now), minutes: 24 * 60)
        allDay.allDay = true
        let overnight = meeting(2, at(22, day: -1), minutes: 180)     // 22:00 yesterday → 01:00 today
        let tomorrow = meeting(3, at(9, day: 1), minutes: 30)
        let lateNight = meeting(4, at(23, 30), minutes: 90)           // runs past midnight
        let plan = DayLayout.plan([allDay, overnight, tomorrow, lateNight], day: now, params: params(), calendar: cal)
        T.equal(plan.allDay.map(\.id), [1], "all-day rows go to the chips")
        T.equal(plan.timedCount, 2, "tomorrow's meeting is not on today")
        T.check(block(plan, 2)?.start == cal.startOfDay(for: now), "overnight meeting starts at 00:00 today")
        T.check(block(plan, 4)?.end == plan.dayEnd, "late meeting ends at midnight")
        // A slice window draws only what it touches.
        let window = DayLayout.sliceWindow(now: now, hours: 3, day: now, calendar: cal)
        T.check(window.start == at(9, 30) && window.end == at(12, 30), "S/M slice 9:30–12:30 at 9:48 (got \(window))")
        let late = DayLayout.sliceWindow(now: at(23, 10), hours: 3, day: now, calendar: cal)
        T.check(late.end == plan.dayEnd && late.seconds == 3 * 3600, "a late slice stays inside the day")
        T.check(window.fraction(at(11)) > 0.49 && window.fraction(at(11)) < 0.51, "fraction is elapsed time")
    }

    static func overflow() {
        T.section("day layout: +N overflow")
        let ms = (1...5).map { meeting($0, at(10), minutes: 30) }
        let plan = DayLayout.plan(ms, day: now, params: params(15, 3), calendar: cal)
        T.equal(plan.blocks.count, 3, "three columns shown")
        T.equal(plan.overflow.count, 1, "one chip")
        T.equal(plan.overflow.first?.count, 2, "+2")
        T.check(plan.blocks.allSatisfy { $0.overflowLane && $0.columns == 3 }, "lane reserved, columns capped")
        T.equal(plan.timedCount, 5, "hidden meetings still count")
        // Hidden meetings far apart get their own chips.
        let spread = (1...3).map { meeting($0, at(9), minutes: 240) } + [meeting(4, at(9, 30), minutes: 30), meeting(5, at(12), minutes: 30)]
        let p2 = DayLayout.plan(spread, day: now, params: params(15, 3), calendar: cal)
        T.equal(p2.overflow.map(\.count), [1, 1], "two separate +1 chips")
        // Within the cap nothing is hidden.
        T.check(DayLayout.plan(Array(ms.prefix(3)), day: now, params: params(15, 3), calendar: cal).overflow.isEmpty, "3 of 3: no chip")
    }

    static func windows() {
        T.section("day layout: windows (fit, minimum, empty, keep now)")
        let busy = DayLayout.plan(DaySample.busy(logos: nil, calendar: cal), day: now, params: params(), calendar: cal)
        let w = DayLayout.fitWindow(busy, minHours: 6, calendar: cal)
        T.check(w.start == at(8) && w.end == at(20), "busy day 8:30–7:30 PM fits 8 AM–8 PM (got \(w))")
        let all = busy.blocks.allSatisfy { w.contains($0.start) && w.contains($0.end) }
        T.check(all, "every meeting inside the window")
        let light = DayLayout.plan(DaySample.light(logos: nil, calendar: cal), day: now, params: params(), calendar: cal)
        let lw = DayLayout.fitWindow(light, minHours: 8, calendar: cal)
        T.check(lw.seconds >= 8 * 3600 - 1, "light day grows to the minimum (got \(lw.seconds / 3600) h)")
        T.check(lw.contains(at(11)) && lw.contains(at(16)), "light day keeps both meetings")
        let kept = DayLayout.fitWindow(light, minHours: 6, keep: now, calendar: cal)
        T.check(kept.contains(now), "today: the window opens at now when it is shortly before the first meeting")
        let early = DayLayout.fitWindow(light, minHours: 6, keep: at(5), calendar: cal)
        T.check(!early.contains(at(5)), "…but not from 5 AM (more than 3 h before)")
        let empty = DayLayout.plan([], day: now, params: params(), calendar: cal)
        let ew = DayLayout.fitWindow(empty, minHours: 6, calendar: cal)
        T.check(ew.start == at(9) && ew.seconds == 6 * 3600, "empty day: 9 AM + minimum")
        let lateDay = DayLayout.plan([meeting(1, at(23, 30), minutes: 29)], day: now, params: params(), calendar: cal)
        let lateW = DayLayout.fitWindow(lateDay, minHours: 6, calendar: cal)
        T.check(lateW.end == lateDay.dayEnd && lateW.seconds >= 6 * 3600 - 1, "late meeting: clamped at midnight, grown earlier")
        // XL split: the whole hour near the middle cutting the fewest blocks.
        let cut = DayLayout.splitPoint(w, plan: busy, calendar: cal)
        T.check(cut == at(14) || cut == at(13), "busy day splits at 1 or 2 PM (got \(DayName.format("HH:mm", cut)))")
        T.check(!busy.blocks.contains { $0.start < cut && $0.end > cut }, "the split cuts no meeting")
    }

    static func dstDay() {
        T.section("day layout: DST day (London, Sunday 25 October 2026)")
        let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        let day = cal.startOfDay(for: base)
        let plan = DayLayout.plan([meeting(1, base, minutes: 60)], day: day, params: params(), calendar: cal)
        let hours = plan.dayEnd.timeIntervalSince(plan.day) / 3600
        T.note("25 October 2026 in London lasts \(hours) h")
        let whole = DayLayout.Window(start: plan.day, end: plan.dayEnd)
        let marks = DayLayout.hourMarks(whole, calendar: cal)
        T.equal(marks.count, Int(hours) + 1, "one hour line per elapsed hour (+ the closing one)")
        let elapsed = base.timeIntervalSince(plan.day) / 3600
        T.equal(elapsed, hours == 25 ? 13 : 12, "noon is 13 real hours in (the repeated hour comes first)")
        T.check(abs(whole.fraction(base) - elapsed / hours) < 1e-9, "noon sits at its elapsed position")
        T.check(zip(marks, marks.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 3600 }, "lines an hour apart")
        let labels = marks.map { DayName.format("HH", $0) }
        if hours == 25 { T.equal(labels.filter { $0 == "01" }.count, 2, "fall back: 1 AM twice") }
        T.equal(plan.blocks.count, 1, "the meeting is placed")
    }

    static func focus() {
        T.section("day layout: the focus meeting")
        let ms = DaySample.busy(logos: nil, calendar: cal)
        let id = { (title: String) in ms.first { $0.title == title }!.id }
        let plan = DayLayout.plan(ms, day: now, params: params(), calendar: cal)
        T.equal(DayModel.focus(plan, now: now), id("The Comets weekly sync"), "9:48: next within 30 min, longer of the 10:00 pair")
        T.equal(DayModel.focus(plan, now: at(10, 20)), id("Prep · Pickle × Comets"), "10:20: the latest meeting under way")
        T.equal(DayModel.focus(plan, now: at(12, 50)), id("Lunch with Rafa"), "12:50: lunch in 10 min (ring, no Join: no link)")
        T.equal(DayModel.focus(plan, now: at(20)), nil, "evening: nothing")
    }

    static func cost() {
        T.section("day layout: cost")
        // 120 meetings (the snapshot cap) in one day, heavily overlapping.
        var ms: [WidgetMeeting] = []
        var rng = SeededRandom(19)
        for i in 0..<120 { ms.append(meeting(i + 1, at(7 + rng.int(0...12), rng.int(0...3) * 15), minutes: Double(rng.int(1...8) * 15))) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var plan = DayLayout.Plan.empty
        for _ in 0..<100 { plan = DayLayout.plan(ms, day: now, params: params(20, 4), calendar: cal) }
        let ms100 = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / 100
        T.check(plan.blocks.count + plan.overflow.reduce(0) { $0 + $1.count } == 120, "every meeting placed or counted")
        T.check(ms100 < 5, "120 meetings lay out in < 5 ms (got \(String(format: "%.3f", ms100)) ms)")
        T.note(String(format: "DayLayout.plan, 120 meetings: %.3f ms; busy day: see bench", ms100))
    }
}
