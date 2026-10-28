import Foundation

/// When the widget redraws without asking the app (D-019): one entry now, then at every moment
/// until the next midnight (at most 24 hours) at which what *this widget* draws changes by itself.
///
/// WidgetKit lays out and archives every entry of a timeline before it shows the first one, so each
/// entry costs real time on every reload (D-019). Entries are planned per placed family, for the
/// meetings that widget actually shows (`KindView.shownMeetings`), followed through time:
///
/// - a shown meeting's start and end (it turns "Now", then leaves the list and the rows move up);
/// - the Join highlight and countdown before a shown meeting's start: 30, 20, 10, 5 and 1 minute ahead
///   (D-017; the highlight begins 30 minutes out);
/// - the Up Next card (Small, left of Medium): also 15 minutes after its start (the card moves on) and
///   every quarter hour in the two hours before it, so "In 1 h 15 min" stays current;
/// - "x of y left" (Agenda Medium, XL, XL Portrait) and the pager's "1 of 3" (Agenda Large and up,
///   Agenda & Inbox): the end of each meeting they count, shown or not;
/// - the next midnight (the picked day and month reset, "Today" moves on). The timeline ends there: the
///   new day comes with a fresh timeline (the reload is due at the last entry, and the data layer
///   republishes at midnight too), so an evening, or a day picked on the Month, costs a few entries;
/// - `pageResetAt` while this family shows a later page (back to page 1 after five minutes);
/// - the moment the snapshot turns stale ("Last synced …" appears);
/// - the moment ↻ turns back from ✓ (`WidgetHealthInfo.justSyncedWindow` after a sync; only when the
///   reload came that soon after it, e.g. after a refresh tap);
/// - the end of every "Archived · Undo" mail row (archivedAt + 30 s: the row leaves).
///
/// The Day widget (D-022) plans its own moments (`dayEntryDates`): it draws no countdowns, so only the
/// moments its drawing changes count (focus ring and Join, a block fading as it ends, the window, the
/// summary), plus now-line steps; another day than today draws the same until midnight.
///
/// Meetings the widget does not show add nothing (Month Small draws only the grid; a picked future day
/// changes only at midnight). The plan walks its own moments in order and asks again what is shown at
/// each one, so a meeting that scrolls into view when an earlier one ends gets its moments too.
///
/// At most `maxEntries`, the earliest kept; the provider asks for a fresh timeline at the last entry
/// (or six hours from now, whichever comes first), so nothing past the cap is lost.
///
/// After the reload moment, up to `maxSettleEntries` more (`settleDates`): if WidgetKit doesn't reload
/// on time, they stop the last entry's "Now" or countdown from staying up after its meeting.
enum TimelinePlan {
    static let maxEntries = 16
    static let horizon: TimeInterval = 24 * 3600
    static let maxWait: TimeInterval = 6 * 3600
    static let countdownMarks: [TimeInterval] = [30, 20, 10, 5, 1].map { $0 * 60 }
    /// The Up Next card's countdown above half an hour ("In 1 h 15 min"): every quarter hour, two hours out.
    static let cardMarks: [TimeInterval] = [45, 60, 75, 90, 105, 120].map { $0 * 60 }
    /// Entries past the reload moment (`settleDates`).
    static let maxSettleEntries = 3

    /// One placed widget's timeline (the widget's `getTimeline`): the planned entries, then the settle
    /// entries. The reload stays due at the last *planned* entry (or six hours from now), so when
    /// WidgetKit reloads on time the settle entries never draw.
    static func timeline(now: Date, model: SnapshotModel, spec: WidgetKindSpec, family: Family,
                         calendar: Calendar = WidgetCalendar.current) -> (entries: [Date], reload: Date) {
        let planned = entryDates(now: now, model: model, spec: spec, family: family, calendar: calendar)
        let settle = settleDates(after: planned.last ?? now, model: model, spec: spec, family: family)
        return (planned + settle, reloadDate(now: now, entries: planned))
    }

    /// WidgetKit keeps drawing a timeline's last entry until it reloads, and it may reload late or not at
    /// all for a while (its daily budget; a measured run saw 33–89 % of requested reloads honoured; a sleeping Mac).
    /// A trimmed timeline often ends while a meeting is drawn as "Now" or counting down: at the cap, in
    /// the middle of a busy day; at midnight, inside an overnight call. For the meetings the last planned
    /// entry draws that way (rows, the Medium panel's Join, the Up Next card), entries at their start
    /// and at the moment they leave keep the drawing honest until the last of them is over, instead of
    /// a "Now" that stays up for hours. At most `maxSettleEntries`, past midnight too; when there are
    /// more moments, the earliest and the very last (so none of them is still drawn after it ends).
    static func settleDates(after last: Date, model: SnapshotModel, spec: WidgetKindSpec, family: Family) -> [Date] {
        let shown = KindView.shownMeetings(spec: spec, family: family, data: model.data(at: last),
                                           style: model.style(dark: false), page: model.page(family: family, at: last))
        /// "Now", or inside the 30-minute Join window with its countdown.
        func live(_ m: WidgetMeeting) -> Bool {
            !m.allDay && m.end > last && m.start.timeIntervalSince(last) <= countdownMarks[0]
        }
        var seconds = Set<Int64>()
        func add(_ date: Date) {
            if date > last { seconds.insert(Int64(date.timeIntervalSinceReferenceDate.rounded(.up))) }
        }
        for m in shown.rows where live(m) {
            add(m.start)
            add(m.end)
        }
        if let m = shown.card, live(m) {
            add(m.start)
            add(min(m.end, m.start.addingTimeInterval(UpNextSmall.grace + 1)))   // the card moves on…
            add(m.end)   // …and Up Next Medium may list it under "After that" until it ends
        }
        var moments = seconds.sorted()
        if moments.count > maxSettleEntries, let latest = moments.last {
            moments = Array(moments.prefix(maxSettleEntries - 1)) + [latest]
        }
        return moments.map { Date(timeIntervalSinceReferenceDate: TimeInterval($0)) }
    }

    /// Entry dates for one placed widget (the widget's `getTimeline`).
    static func entryDates(now: Date, model: SnapshotModel, spec: WidgetKindSpec, family: Family,
                           calendar: Calendar = WidgetCalendar.current) -> [Date] {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        let limit = min(now.addingTimeInterval(horizon), midnight ?? now.addingTimeInterval(horizon))
        var seconds = Set<Int64>()
        func second(_ date: Date) -> Int64 { Int64(date.timeIntervalSinceReferenceDate.rounded(.up)) }
        /// Moments after `after` (and after now), up to the next midnight.
        func add(_ date: Date?, after: Date) {
            guard let date, date > now, date > after, date <= limit else { return }
            seconds.insert(second(date))
        }

        // Moments that don't depend on which meetings show.
        add(midnight, after: now)
        if model.page(family: family, at: now) > 1 { add(model.snapshot.pageResetAt, after: now) }
        add(staleAt(model), after: now)
        add(justSyncedEnd(model, now: now), after: now)
        for end in model.undoEnds { add(end, after: now) }

        if case .design(.day) = KindView.resolve(spec: spec, family: family, data: model.data(at: now)) {
            return dayEntryDates(now: now, limit: limit, model: model, family: family, fixed: seconds, calendar: calendar)
        }

        // Meetings: what this widget shows, followed through time.
        let style = model.style(dark: false)
        var rows = Set<Int>(), cards = Set<Int>(), counted = Set<Int>()
        func visit(_ t: Date) {
            let shown = KindView.shownMeetings(spec: spec, family: family, data: model.data(at: t), style: style,
                                               page: model.page(family: family, at: t))
            for m in shown.rows where rows.insert(m.id).inserted {
                for date in boundaries(m) { add(date, after: t) }
            }
            if let m = shown.card, cards.insert(m.id).inserted {
                for date in boundaries(m) { add(date, after: t) }
                // The card keeps a meeting while `start >= now - grace`: it moves on one second later.
                add(m.start.addingTimeInterval(UpNextSmall.grace + 1), after: t)
                for mark in cardMarks { add(m.start.addingTimeInterval(-mark), after: t) }
            }
            for m in shown.ends where counted.insert(m.id).inserted { add(m.end, after: t) }
        }
        visit(now)
        // What shows only changes at a planned moment (a shown meeting ends or leaves the card, midnight,
        // a page reset, the stale strip), and a visit only adds later moments: visiting the planned
        // moments in order makes the first `maxEntries - 1` final.
        var cursor = second(now)
        var visited = 0
        while visited < maxEntries - 1, let next = seconds.lazy.filter({ $0 > cursor }).min() {
            visit(Date(timeIntervalSinceReferenceDate: TimeInterval(next)))
            cursor = next
            visited += 1
        }
        let later = seconds.sorted().prefix(maxEntries - 1).map { Date(timeIntervalSinceReferenceDate: TimeInterval($0)) }
        return [now] + later
    }

    // MARK: - Day (D-022)

    /// Two changes this close draw as one entry, at the later moment (the earlier one ≤ 2 min late).
    static let dayCoalesce: TimeInterval = 120
    /// While the now line shows, it never waits longer than this for a redraw.
    static let dayNowStep: TimeInterval = 30 * 60

    /// The Day widget's entries: `now`, then every moment until midnight at which what it draws changes
    /// (`DayTimelineWidget.Drawing`: the focus ring and its Join, a block fading, the window, the summary),
    /// and a now-line step 30 min after the last entry whenever the line shows and nothing else redraws
    /// it sooner. Candidates: each timed meeting's start, end and start − 30 min (focus hand-over), the
    /// first meeting − 3 h (when L / XL / XLP stop opening at "now"), and every :00 / :10 / :15 / :30 /
    /// :40 / :45 (S / M windows slide at :10 / :40, the fitted window's "now" edge moves at :15 / :45,
    /// an empty day's at :00 / :30); a candidate is kept only when the drawing differs from the last
    /// entry's. Changes closer than `dayCoalesce` share one entry at the later moment; `fixed` (midnight,
    /// the stale strip, ✓'s end) always counts and keeps its own entry. Another day than today draws
    /// the same until midnight: `now` + `fixed`.
    static func dayEntryDates(now: Date, limit: Date, model: SnapshotModel, family: Family, fixed: Set<Int64>,
                              calendar cal: Calendar) -> [Date] {
        func date(_ s: Int64) -> Date { Date(timeIntervalSinceReferenceDate: TimeInterval(s)) }
        func second(_ d: Date) -> Int64 { Int64(d.timeIntervalSinceReferenceDate.rounded(.up)) }
        let day = model.selectedDay(at: now)
        guard cal.isDate(day, inSameDayAs: now) else {
            return [now] + fixed.sorted().prefix(maxEntries - 1).map(date)
        }
        let style = model.style(dark: false)
        func drawing(_ t: Date) -> DayTimelineWidget.Drawing {
            let data = model.data(at: t)
            let footer = data.state == .content ? data.health.footer(at: t) : .none
            let reserve = footer != .none && !KindView.compactFooter(family) ? WidgetFooterView.reserve : 0
            return DayTimelineWidget.drawing(family: family, meetings: data.meetings, day: data.selectedDay, now: t,
                                             style: style, reserve: reserve)
        }
        let start = second(now), end = second(limit)
        var candidates = Set<Int64>()
        func candidate(_ d: Date) {
            let s = second(d)
            guard s > start, s <= end else { return }
            candidates.insert(s)
        }
        let dayStart = cal.startOfDay(for: now)
        let timed = model.meetings.filter { !$0.allDay && $0.start < limit && $0.end > dayStart }
        for m in timed {
            candidate(m.start); candidate(m.end); candidate(m.start.addingTimeInterval(-30 * 60))
        }
        if let first = timed.map(\.start).min() { candidate(first.addingTimeInterval(-3 * 3600)) }
        var mark = dayStart
        while mark <= limit {
            for minute in [0, 10, 15, 30, 40, 45] {
                candidate(mark.addingTimeInterval(Double(minute * 60)))
            }
            mark = mark.addingTimeInterval(3600)
        }
        candidates.formUnion(fixed.filter { $0 > start && $0 <= end })

        var kept: [Int64] = []
        var last = drawing(now)
        var lastAt = start
        let step = Int64(dayNowStep)
        var full = false
        for s in candidates.sorted() {
            // Nothing changes between candidates but the now line: while it shows, redraw it every 30 min.
            while last.nowVisible, s - lastAt > step, !full {
                let t = lastAt + step
                if kept.count == maxEntries - 1 { full = true; break }
                kept.append(t)
                lastAt = t
            }
            if full { break }
            let d = drawing(date(s))
            guard d != last || fixed.contains(s) else { continue }
            // Fixed moments (the stale strip, ✓'s end, midnight) keep their own entry; Day moments merge.
            if let previous = kept.last, s - previous < Int64(dayCoalesce), !fixed.contains(s), !fixed.contains(previous) {
                kept[kept.count - 1] = s          // one entry for both, drawn at the later moment
            } else {
                if kept.count == maxEntries - 1 { break }
                kept.append(s)
            }
            last = d
            lastAt = s
        }
        return [now] + kept.map(date)
    }

    /// A meeting's own moments: start, end, and (timed meetings) the Join countdown marks.
    static func boundaries(_ m: WidgetMeeting) -> [Date] {
        var out = [m.start, m.end]
        if !m.allDay { out += countdownMarks.map { m.start.addingTimeInterval(-$0) } }
        return out
    }

    /// When "Last synced …" appears (nil when the data layer already marked the snapshot stale).
    static func staleAt(_ model: SnapshotModel) -> Date? {
        let health = model.health
        guard !health.markedStale, let synced = health.syncedAt else { return nil }
        return synced.addingTimeInterval(WidgetHealthInfo.staleAfter + 1)
    }

    /// When ↻ stops reading ✓ (nil unless the widget draws ✓ at `now`: its design, a healthy sync less
    /// than `justSyncedWindow` ago).
    static func justSyncedEnd(_ model: SnapshotModel, now: Date) -> Date? {
        guard model.cardState == .content, model.health.justSynced(at: now), let synced = model.health.syncedAt else {
            return nil
        }
        return synced.addingTimeInterval(WidgetHealthInfo.justSyncedWindow)
    }

    /// `.after(min(last entry, now + 6 h))`; never sooner than a minute from now.
    static func reloadDate(now: Date, entries: [Date]) -> Date {
        let last = entries.last ?? now
        let target = min(last, now.addingTimeInterval(maxWait))
        return target > now.addingTimeInterval(60) ? target : now.addingTimeInterval(15 * 60)
    }
}
