import Foundation

/// The Day widget's layout engine (pure, no SwiftUI): which hours a family shows and where every
/// meeting sits in them, the way Google Calendar's day view does it.
///
/// 1. **Window.** L / XL / XLP fit the whole day's timed meetings (30 min of air either side, snapped to
///    half hours, at least `minHours`, clamped to the day), so every meeting is on screen whatever the
///    day holds. S and M show a fixed slice that starts just before `now`.
/// 2. **Columns.** Meetings are sorted by start, longer first on a tie. Overlapping meetings form a
///    cluster; each takes the first column whose last meeting has ended, then grows right into every
///    column it does not collide with. A meeting too short to read is laid out as if it lasted
///    `minVisualMinutes`, so its block never covers the next one (Google does the same).
/// 3. **Overflow.** Columns past `maxColumns` would be too thin to read: those meetings are hidden and
///    counted on a "+N" chip (a link to the Day Peek) beside their cluster.
///
/// Everything is measured in elapsed time from the window's start, so a DST day (23 or 25 hours) keeps
/// blocks proportional, and hour lines come from the calendar (wall-clock labels).
/// Cost: one sort plus a binary search per column probe, O(n log n) for the columns a day can hold.
enum DayLayout {
    /// What a family asks of the layout.
    struct Params: Equatable {
        /// Blocks shorter than this are laid out as if they lasted this long (minutes).
        var minVisualMinutes: Double = 15
        /// More side-by-side columns than this are too thin to read: the rest go on a "+N" chip.
        var maxColumns = 4
    }

    struct Block {
        let meeting: WidgetMeeting
        /// The meeting clipped to the day (a meeting from yesterday evening starts at 00:00).
        let start: Date
        let end: Date
        /// `end`, or `start + minVisualMinutes` when that is later (what the columns were packed with).
        let visualEnd: Date
        let cluster: Int
        let column: Int
        /// Columns it covers, `column ..< column + span`.
        let span: Int
        /// Columns its cluster shows (≤ `maxColumns`).
        let columns: Int
        /// Its cluster hides meetings: the view keeps a lane on the right for the "+N" chip.
        let overflowLane: Bool
    }

    /// "+N" beside a cluster: `count` hidden meetings, from `start` to `end`.
    struct Overflow {
        let cluster: Int
        let start: Date
        let end: Date
        let hidden: [WidgetMeeting]
        var count: Int { hidden.count }
    }

    struct Plan {
        let day: Date
        let dayEnd: Date
        /// All-day meetings, in the order they came.
        let allDay: [WidgetMeeting]
        /// Visible timed blocks, in layout order (start, then longer first).
        let blocks: [Block]
        let overflow: [Overflow]
        /// Timed meetings on the day (shown or not).
        let timedCount: Int

        static let empty = Plan(day: Date(timeIntervalSince1970: 0), dayEnd: Date(timeIntervalSince1970: 0),
                                allDay: [], blocks: [], overflow: [], timedCount: 0)
    }

    // MARK: - Columns

    /// The day's layout. `meetings` may hold other days (they are skipped) and arrive in any order.
    static func plan(_ meetings: [WidgetMeeting], day: Date, params: Params = Params(),
                     calendar cal: Calendar = WidgetCalendar.current) -> Plan {
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var allDay: [WidgetMeeting] = []
        var timed: [(m: WidgetMeeting, start: Date, end: Date, order: Int)] = []
        for (order, m) in meetings.enumerated() {
            if m.allDay {
                // All-day rows are midnight-to-midnight (end exclusive).
                if m.start < dayEnd && max(m.end, m.start.addingTimeInterval(1)) > dayStart { allDay.append(m) }
                continue
            }
            let s = max(m.start, dayStart), e = min(m.end, dayEnd)
            // A zero-length meeting still shows (as a short block); one that only touches midnight does not.
            guard s < dayEnd, e > s || (m.start == m.end && m.start >= dayStart) else { continue }
            timed.append((m, s, max(e, s), order))
        }
        timed.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            let da = a.end.timeIntervalSince(a.start), db = b.end.timeIntervalSince(b.start)
            if da != db { return da > db }
            return a.order < b.order
        }

        let minVisual = max(1, params.minVisualMinutes) * 60
        let maxColumns = max(1, params.maxColumns)
        var blocks: [Block] = []
        var overflow: [Overflow] = []
        blocks.reserveCapacity(timed.count)

        var i = 0
        var clusterIndex = 0
        while i < timed.count {
            // One cluster: everything until a meeting starts after every earlier one has (visually) ended.
            var j = i
            var clusterEnd = Date.distantPast
            // Column assignment: per column the visual ends in start order (sorted), for the greedy pick.
            var columnEnds: [Date] = []
            var placed: [(index: Int, column: Int, visualEnd: Date)] = []
            while j < timed.count {
                let t = timed[j]
                if j > i && t.start >= clusterEnd { break }
                let visualEnd = max(t.end, t.start.addingTimeInterval(minVisual))
                // First column whose last meeting has ended (columns stay few; this is a short scan).
                let column = columnEnds.firstIndex { $0 <= t.start } ?? columnEnds.count
                if column == columnEnds.count { columnEnds.append(visualEnd) } else { columnEnds[column] = visualEnd }
                placed.append((j, column, visualEnd))
                clusterEnd = max(clusterEnd, visualEnd)
                j += 1
            }
            let total = columnEnds.count
            let shown = min(total, maxColumns)
            let lane = total > maxColumns

            // Per column, the meetings in it (start order), to probe for collisions with binary search.
            var byColumn = [[(start: Date, end: Date)]](repeating: [], count: total)
            for p in placed { byColumn[p.column].append((timed[p.index].start, p.visualEnd)) }

            var hidden: [(start: Date, end: Date, m: WidgetMeeting)] = []
            for p in placed {
                let t = timed[p.index]
                guard p.column < shown else {
                    hidden.append((t.start, p.visualEnd, t.m))
                    continue
                }
                var span = 1
                var k = p.column + 1
                while k < shown, !collides(byColumn[k], t.start, p.visualEnd) { span += 1; k += 1 }
                blocks.append(Block(meeting: t.m, start: t.start, end: t.end, visualEnd: p.visualEnd, cluster: clusterIndex,
                                    column: p.column, span: span, columns: shown, overflowLane: lane))
            }
            // Hidden meetings: one chip per run of overlapping ones.
            var run: [(start: Date, end: Date, m: WidgetMeeting)] = []
            func flush() {
                guard let first = run.first else { return }
                overflow.append(Overflow(cluster: clusterIndex, start: first.start,
                                         end: run.map(\.end).max() ?? first.end, hidden: run.map(\.m)))
                run = []
            }
            for h in hidden.sorted(by: { $0.start < $1.start }) {
                if let end = run.map(\.end).max(), h.start >= end { flush() }
                run.append(h)
            }
            flush()
            clusterIndex += 1
            i = j
        }
        return Plan(day: dayStart, dayEnd: dayEnd, allDay: allDay, blocks: blocks, overflow: overflow, timedCount: timed.count)
    }

    /// Does any interval in `column` (sorted by start, non-overlapping) overlap `[start, end)`?
    static func collides(_ column: [(start: Date, end: Date)], _ start: Date, _ end: Date) -> Bool {
        // First interval that starts at or after `end` cannot overlap; only the one before it can.
        var lo = 0, hi = column.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if column[mid].start < end { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return false }
        return column[lo - 1].end > start
    }

    // MARK: - Window

    struct Window: Equatable {
        let start: Date
        let end: Date
        var seconds: TimeInterval { end.timeIntervalSince(start) }

        /// 0…1 down the window (elapsed time, so DST days stay proportional).
        func fraction(_ date: Date) -> Double {
            guard seconds > 0 else { return 0 }
            return date.timeIntervalSince(start) / seconds
        }

        func contains(_ date: Date) -> Bool { date >= start && date <= end }

        /// The window cut in two (XL's morning / afternoon columns) at `at`.
        func split(at: Date) -> (Window, Window) {
            let t = min(max(at, start), end)
            return (Window(start: start, end: t), Window(start: t, end: end))
        }
    }

    /// L / XL / XLP: every timed meeting of the day, `padMinutes` of air, snapped to half hours, at least
    /// `minHours` (grown evenly, whole half hours, earlier first), clamped to the day. A day without
    /// timed meetings shows `minHours` from `emptyStart` (default 9 AM; today: the hour before now).
    /// `keep` (today's now): when it falls up to 3 h before the first meeting, the window opens there
    /// too, so the now line shows where you stand against what is left.
    static func fitWindow(_ plan: Plan, minHours: Double, padMinutes: Double = 30, emptyStart: Date? = nil,
                          keep: Date? = nil, calendar cal: Calendar = WidgetCalendar.current) -> Window {
        let day = plan.day, dayEnd = plan.dayEnd
        let timed = plan.blocks.map { ($0.start, $0.visualEnd) } + plan.overflow.map { ($0.start, $0.end) }
        if timed.isEmpty {
            let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            let s = snap(emptyStart ?? nine, down: true, cal: cal, day: day)
            let length = min(minHours * 3600, dayEnd.timeIntervalSince(day))
            let start = max(day, min(s, dayEnd.addingTimeInterval(-length)))
            return Window(start: start, end: start.addingTimeInterval(length))
        }
        var first = timed.map(\.0).min()!
        let last = timed.map(\.1).max()!
        if let keep, keep >= day, keep < first, first.timeIntervalSince(keep) <= 3 * 3600 {
            first = keep.addingTimeInterval(-15 * 60)
        }
        var start = snap(first.addingTimeInterval(-padMinutes * 60), down: true, cal: cal, day: day)
        var end = snap(last.addingTimeInterval(padMinutes * 60), down: false, cal: cal, day: day)
        start = max(start, day); end = min(end, dayEnd)
        let need = minHours * 3600
        var grow = true
        while end.timeIntervalSince(start) < need - 1, grow {
            grow = false
            // Earlier first: a light day reads better with its morning showing.
            if start > day { start = max(day, start.addingTimeInterval(-1800)); grow = true }
            if end.timeIntervalSince(start) < need - 1, end < dayEnd { end = min(dayEnd, end.addingTimeInterval(1800)); grow = true }
        }
        return Window(start: start, end: end)
    }

    /// S / M: a fixed slice of `hours` from the half hour before `now` (at least 10 min of context
    /// above the now line), kept inside the day.
    static func sliceWindow(now: Date, hours: Double, day: Date, calendar cal: Calendar = WidgetCalendar.current) -> Window {
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let length = hours * 3600
        var start = snap(now.addingTimeInterval(-10 * 60), down: true, cal: cal, day: dayStart)
        if !cal.isDate(now, inSameDayAs: dayStart) {
            start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart) ?? dayStart
        }
        start = max(dayStart, min(start, dayEnd.addingTimeInterval(-length)))
        return Window(start: start, end: min(dayEnd, start.addingTimeInterval(length)))
    }

    /// `date` snapped down / up to a half hour on the wall clock (minutes 0 or 30).
    static func snap(_ date: Date, down: Bool, cal: Calendar, day: Date) -> Date {
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let minute = c.minute ?? 0
        let exact = minute % 30 == 0 && (c.second ?? 0) == 0 && (c.nanosecond ?? 0) == 0
        if exact { return date }
        let into = TimeInterval((minute % 30) * 60 + (c.second ?? 0)) + Double(c.nanosecond ?? 0) / 1e9
        return down ? date.addingTimeInterval(-into) : date.addingTimeInterval(1800 - into)
    }

    /// Wall-clock hours inside the window (the grid's lines and labels). On a DST day an hour can
    /// repeat or go missing; each line sits at its real elapsed position.
    static func hourMarks(_ window: Window, calendar cal: Calendar = WidgetCalendar.current) -> [Date] {
        var marks: [Date] = []
        // First whole hour at or after the start.
        var t = snapToHour(window.start, cal: cal)
        if t < window.start { t = t.addingTimeInterval(3600) }
        while t <= window.end, marks.count < 30 {
            marks.append(t)
            t = t.addingTimeInterval(3600)
        }
        return marks
    }

    private static func snapToHour(_ date: Date, cal: Calendar) -> Date {
        let c = cal.dateComponents([.minute, .second, .nanosecond], from: date)
        return date.addingTimeInterval(-TimeInterval((c.minute ?? 0) * 60 + (c.second ?? 0)) - Double(c.nanosecond ?? 0) / 1e9)
    }

    /// XL's split: the whole hour nearest the middle that cuts the fewest blocks (ties: nearer the middle).
    static func splitPoint(_ window: Window, plan: Plan, calendar cal: Calendar = WidgetCalendar.current) -> Date {
        let mid = window.start.addingTimeInterval(window.seconds / 2)
        let hours = hourMarks(window, calendar: cal).filter { $0 > window.start && $0 < window.end }
        guard !hours.isEmpty else { return mid }
        func cost(_ t: Date) -> (Int, Double) {
            let cuts = plan.blocks.filter { $0.start < t && $0.visualEnd > t }.count
            return (cuts, abs(t.timeIntervalSince(mid)))
        }
        // Stay within 90 min of the middle so both halves keep a similar scale.
        let near = hours.filter { abs($0.timeIntervalSince(mid)) <= 5400 }
        return (near.isEmpty ? hours : near).min { cost($0) < cost($1) }!
    }
}
