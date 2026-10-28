import SwiftUI

// "Day": one day as an hour grid, meetings as blocks side by side when they overlap (Google Calendar's
// day view, in the widget language: Paper / Ink, account logos, teal accent, calm words).
// The layout engine is DayLayout (pure); this file only draws what it decided. Kind `day` and Custom slots
// set to Day (D-022): ‹ › → `day?w&d`, ↻ → `sync?w`, "+N" and empty grid → `open/day`, a block →
// `open/event`, Join → `join`; the header date (and "Today" on another day) go back to today.

/// How one family draws the day.
struct DayMetrics {
    /// Hour-label gutter at the grid's left.
    let gutter: CGFloat
    /// The shortest block drawn (points); shorter meetings are laid out as if this tall.
    let minBlock: CGFloat
    let maxColumns: Int
    /// L / XL / XLP fit the day; S / M show a fixed slice from just before now.
    let sliceHours: Double?
    let minHours: Double
    /// Room above the first and below the last hour line, so their labels never clip.
    let inset: CGFloat = 6
    /// The "+N" lane beside an overflowing cluster.
    var lane: CGFloat = 24

    static func of(_ family: Family, _ style: WidgetStyle) -> DayMetrics {
        let g: CGFloat = style.use24Hour ? 30 : 32
        // S / M label hours compactly ("9", "10", "11"; am/pm only where it changes), so the gutter is slim.
        let slim: CGFloat = (style.use24Hour ? 26 : 22) * style.scale
        switch family {
        case .small: return DayMetrics(gutter: slim, minBlock: 15, maxColumns: 1, sliceHours: 2.5, minHours: 2.5, lane: 20)
        case .medium: return DayMetrics(gutter: slim + 2, minBlock: 15, maxColumns: 2, sliceHours: 3, minHours: 3)
        case .large: return DayMetrics(gutter: g, minBlock: 15, maxColumns: 3, sliceHours: nil, minHours: 6)
        case .extraLarge: return DayMetrics(gutter: g, minBlock: 16, maxColumns: 3, sliceHours: nil, minHours: 8)
        case .extraLargePortrait: return DayMetrics(gutter: g, minBlock: 16, maxColumns: 3, sliceHours: nil, minHours: 8)
        }
    }
}

/// Everything a Day render needs, decided once (DayLayout twice: a first pass for the window, then the
/// columns with the minimum block height that window implies). Views below only read it.
struct DayModel {
    let day: Date
    let now: Date
    let plan: DayLayout.Plan
    /// One window (S, M, L, XLP) or two (XL's earlier / later columns, same scale).
    let windows: [DayLayout.Window]
    let isToday: Bool
    /// The one meeting that matters now (DESIGN-WIDGETS principle 3): the meeting under way (the latest
    /// to start, shorter first), else the next one within 30 min. Only it gets the ring and Join.
    let focusId: Int?

    static func make(meetings: [WidgetMeeting], day: Date, now: Date, family: Family, style: WidgetStyle,
                     gridHeight: CGFloat) -> DayModel {
        let cal = WidgetCalendar.current
        let m = DayMetrics.of(family, style)
        let isToday = cal.isDate(day, inSameDayAs: now)
        // Pass 1: real lengths, to find the window.
        let first = DayLayout.plan(meetings, day: day, params: .init(minVisualMinutes: 15, maxColumns: m.maxColumns), calendar: cal)
        var windows: [DayLayout.Window]
        if let hours = m.sliceHours {
            // Another day (‹ ›): the slice opens at its first timed meeting (9 AM when there is none).
            let opening = (first.blocks.map(\.start) + first.overflow.map(\.start)).min()
            windows = [DayLayout.sliceWindow(now: isToday ? now : (opening ?? now), hours: hours, day: day, calendar: cal)]
        } else {
            windows = [DayLayout.fitWindow(first, minHours: m.minHours,
                                           emptyStart: isToday ? now.addingTimeInterval(-3600) : nil,
                                           keep: isToday ? now : nil, calendar: cal)]
        }
        // Pass 2: the minimum block height in minutes at this window's scale.
        let usable = max(1, gridHeight - m.inset * 2)
        let seconds = family == .extraLarge ? windows[0].seconds / 2 : windows[0].seconds
        let minutesPerPoint = seconds / 60 / Double(usable)
        let plan = DayLayout.plan(meetings, day: day,
                                  params: .init(minVisualMinutes: max(10, Double(m.minBlock) * minutesPerPoint), maxColumns: m.maxColumns),
                                  calendar: cal)
        if family == .extraLarge {
            let w = windows[0]
            let cut = DayLayout.splitPoint(w, plan: plan, calendar: cal)
            // Both halves at one scale: the shorter one takes more air (earlier morning / later evening).
            let length = max(cut.timeIntervalSince(w.start), w.end.timeIntervalSince(cut))
            let early = DayLayout.Window(start: max(plan.day, cut.addingTimeInterval(-length)), end: cut)
            let late = DayLayout.Window(start: cut, end: cut.addingTimeInterval(length))
            windows = [early, late]
        }
        return DayModel(day: day, now: now, plan: plan, windows: windows, isToday: isToday,
                        focusId: isToday ? focus(plan, now: now) : nil)
    }

    static func focus(_ plan: DayLayout.Plan, now: Date) -> Int? {
        let timed = plan.blocks.map(\.meeting) + plan.overflow.flatMap(\.hidden)
        let live = timed.filter { $0.start <= now && $0.end > now }
        if let current = live.min(by: { a, b in
            a.start != b.start ? a.start > b.start : a.end.timeIntervalSince(a.start) < b.end.timeIntervalSince(b.start)
        }) { return current.id }
        let soon = timed.filter { $0.start > now && $0.start.timeIntervalSince(now) <= 30 * 60 }
        return soon.min(by: { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.hasLink != b.hasLink { return a.hasLink }
            return a.end > b.end
        })?.id
    }

    /// Seconds every column of this family spans (XL halves share one scale, even when one is clamped).
    var columnSeconds: TimeInterval { windows.map(\.seconds).max() ?? 3600 }

    var meetingCount: Int { plan.timedCount + plan.allDay.count }

    /// The focus meeting when it has a Join link (S header, M panel).
    var joinMeeting: WidgetMeeting? {
        guard let focusId else { return nil }
        return (plan.blocks.map(\.meeting) + plan.overflow.flatMap(\.hidden)).first { $0.id == focusId && $0.hasLink }
    }
}

// MARK: - Widget

struct DayTimelineWidget: View {
    let family: Family
    let meetings: [WidgetMeeting]
    let now: Date
    let style: WidgetStyle
    /// The day shown (nil = today).
    var day: Date? = nil
    /// Points the "Last synced" / re-auth strip takes from the bottom of L / XL / XLP (KindView).
    var reserve: CGFloat = 0

    static let pad: CGFloat = 13

    private var shownDay: Date { WidgetCalendar.current.startOfDay(for: day ?? now) }

    var body: some View {
        WidgetCard(family, style) {
            switch family {
            case .small: small
            case .medium: medium
            case .large: large
            case .extraLarge: extraLarge
            case .extraLargePortrait: portrait
            }
        }
    }

    // Grid heights per family (fixed sizes: no GeometryReader).
    static func allDayHeight(_ model: DayModel) -> CGFloat { model.plan.allDay.isEmpty ? 0 : 20 + 6 }

    /// The grid's height before the all-day row: the family's size minus its padding and header.
    static func innerHeight(_ family: Family, reserve: CGFloat = 0) -> CGFloat {
        switch family {
        case .small: return family.size.height - 10 * 2 - 18 - 2
        case .medium: return family.size.height - 11 * 2
        case .large, .extraLarge: return family.size.height - pad * 2 - 26 - 6 - reserve
        case .extraLargePortrait: return family.size.height - pad * 2 - 50 - 8 - reserve
        }
    }

    /// What a family draws for one entry (the views below only read it): the layout at the grid height
    /// that family has, measured again without the all-day row's height when there is one. The timeline
    /// planner and the render manifest use the same call, so they see exactly what is drawn.
    static func layout(family: Family, meetings: [WidgetMeeting], day: Date, now: Date, style: WidgetStyle,
                       reserve: CGFloat = 0) -> (model: DayModel, grid: CGFloat) {
        let inner = innerHeight(family, reserve: reserve)
        let probe = DayModel.make(meetings: meetings, day: day, now: now, family: family, style: style, gridHeight: inner)
        let grid = inner - allDayHeight(probe)
        let m = probe.plan.allDay.isEmpty
            ? probe : DayModel.make(meetings: meetings, day: day, now: now, family: family, style: style, gridHeight: grid)
        return (m, grid)
    }

    private var resolved: (model: DayModel, grid: CGFloat) {
        Self.layout(family: family, meetings: meetings, day: shownDay, now: now, style: style, reserve: reserve)
    }

    private var large: some View {
        let gap: CGFloat = 6
        let (m, grid) = resolved
        let width = family.size.width - Self.pad * 2
        return VStack(alignment: .leading, spacing: gap) {
            DayHeaderLine(day: shownDay, now: now, model: m, style: style, summary: false)
            DayBody(model: m, family: family, style: style, width: width, gridHeight: grid)
        }
        .padding(Self.pad)
    }

    private var extraLarge: some View {
        let gap: CGFloat = 6
        let (m, grid) = resolved
        let width = family.size.width - Self.pad * 2
        return VStack(alignment: .leading, spacing: gap) {
            DayHeaderLine(day: shownDay, now: now, model: m, style: style, summary: true)
            DayBody(model: m, family: family, style: style, width: width, gridHeight: grid)
        }
        .padding(Self.pad)
    }

    private var portrait: some View {
        let header: CGFloat = 50, gap: CGFloat = 8
        let (m, grid) = resolved
        let width = family.size.width - Self.pad * 2
        return VStack(alignment: .leading, spacing: gap) {
            HStack(alignment: .top, spacing: 6) {
                DayDateHeader(day: shownDay, now: now, model: m, style: style)
                Spacer(minLength: 4)
                if !m.isToday { DayTodayChip(now: now, style: style).frame(height: 22) }
                DayControls(day: shownDay, style: style, size: 22)
            }
            .frame(height: header, alignment: .top)
            DayBody(model: m, family: family, style: style, width: width, gridHeight: grid)
        }
        .padding(Self.pad)
    }

    /// Medium: the day panel on the left (weekday, big date, summary, arrows), a 3-hour slice on the right.
    private var medium: some View {
        let panel: CGFloat = 84, spacing: CGFloat = 12, padV: CGFloat = 11
        let inner = family.size.height - padV * 2
        let (m, grid) = resolved
        let width = family.size.width - Self.pad * 2 - panel - spacing
        return HStack(alignment: .top, spacing: spacing) {
            DayMediumPanel(day: shownDay, now: now, model: m, style: style)
                .frame(width: panel, height: inner, alignment: .topLeading)
            DayBody(model: m, family: family, style: style, width: width, gridHeight: grid)
        }
        .padding(.horizontal, Self.pad).padding(.vertical, padV)
    }

    /// Small: "MON 19" + ↻, then the next three hours.
    private var small: some View {
        let header: CGFloat = 18, gap: CGFloat = 2, padH: CGFloat = 11, padV: CGFloat = 10
        let (m, grid) = resolved
        let width = family.size.width - padH * 2
        let p = style.palette
        return VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: 4) {
                DayDateLink(day: shownDay, now: now) {
                    HStack(spacing: 4) {
                        Text(DayName.format("EEE", shownDay).uppercased())
                            .font(style.font(10.5, .bold)).tracking(0.5).foregroundStyle(p.accent)
                        Text(DayName.format(m.joinMeeting == nil ? "d MMM" : "d", shownDay)).font(style.font(10.5, .bold)).foregroundStyle(p.text)
                    }
                }
                Spacer(minLength: 2)
                if let join = m.joinMeeting { DayJoinChip(meeting: join, style: style) }
                RefreshButton(style: style, round: 16)
            }
            .lineLimit(1)
            .frame(height: header)
            DayBody(model: m, family: family, style: style, width: width, gridHeight: grid)
        }
        .padding(.horizontal, padH).padding(.vertical, padV)
    }

    // MARK: Planning (TimelinePlan) and the manifest

    /// What one entry draws, minus the now line's exact height: the timeline plans an entry wherever this
    /// changes (the focus ring and its Join, a block fading as its meeting ends, the window, the summary
    /// text), plus now-line steps (TimelinePlan.dayEntryDates).
    struct Drawing: Equatable {
        var focus: Int?
        var windows: [DayLayout.Window]
        /// Drawn blocks already over (they fade).
        var past: [Int]
        var text: String
        var nowVisible: Bool
    }

    static func drawing(family: Family, meetings: [WidgetMeeting], day: Date, now: Date, style: WidgetStyle,
                        reserve: CGFloat = 0) -> Drawing {
        let m = layout(family: family, meetings: meetings, day: day, now: now, style: style, reserve: reserve).model
        let drawn = drawnBlocks(m)
        let text: String
        switch family {
        case .small, .large: text = ""
        case .medium: text = m.joinMeeting == nil ? DayCopy.mediumSummary(m, style: style) : ""
        case .extraLarge, .extraLargePortrait: text = DayCopy.summary(m, style: style)
        }
        return Drawing(focus: m.focusId, windows: m.windows,
                       past: m.isToday ? drawn.filter { $0.meeting.end <= now }.map(\.meeting.id) : [],
                       text: text, nowVisible: m.isToday && m.windows.contains { $0.contains(now) })
    }

    /// Blocks inside a window (what the grid draws; S / M slices leave the rest of the day out).
    static func drawnBlocks(_ model: DayModel) -> [DayLayout.Block] {
        model.plan.blocks.filter { b in
            model.windows.contains { b.start < $0.end && max(b.visualEnd, b.end) > $0.start }
        }
    }
}

/// The date in a header: opens the Calendar section on today; on another day it goes back to today
/// (`day?w&d=<today>`, quiet), like the "Today" chip.
private struct DayDateLink<Label: View>: View {
    let day: Date
    let now: Date
    @ViewBuilder let label: () -> Label
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let today = WidgetCalendar.current.isDate(day, inSameDayAs: now)
        WidgetLink(destination: today ? links.open(.calendar) : links.today(now), label: label)
    }
}

/// "Today" beside the arrows when another day is shown (L / XL / XLP): back to today.
private struct DayTodayChip: View {
    let now: Date
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        WidgetLink(destination: links.today(now)) {
            Text("Today")
                .font(style.font(10, .bold)).foregroundStyle(style.palette.accent)
                .lineLimit(1)
                .padding(.horizontal, 8).frame(height: 18 * style.scale)
                .background(Capsule().fill(style.palette.accentSoft))
                .fixedSize()
        }
        .accessibilityLabel("Back to today")
    }
}

// MARK: - Headers

/// L / XL: "Monday 19 October" (weekday in the accent), the count or the day summary, ↻, ‹ ›.
private struct DayHeaderLine: View {
    let day: Date
    let now: Date
    let model: DayModel
    let style: WidgetStyle
    let summary: Bool
    @Environment(\.widgetLinks) private var links
    @Environment(\.widgetTitle) private var title

    var body: some View {
        let p = style.palette
        HStack(alignment: .center, spacing: 6) {
            DayDateLink(day: day, now: now) {
                HStack(alignment: .center, spacing: 6) {
                    // The mark takes 18 pt, so today shortens like another day does ("Mon 19
                    // October"): shorter forms before any truncation, and the mark goes last.
                    ViewThatFits(in: .horizontal) {
                        self.markedTitle(model.isToday ? DayName.format("EEEE", day) : DayName.title(day, now: now), "d MMMM")
                        self.markedTitle(DayName.format("EEE", day), "d MMMM")
                        self.markedTitle(DayName.format("EEE", day), "d MMM")
                        self.dateTitle(DayName.format("EEE", day), "d MMM")
                    }
                    if let title { WidgetTitleTag(title: title, style: style) }
                    if summary {
                        Text(DayCopy.summary(model, style: style))
                            .font(style.font(11)).foregroundStyle(p.text2).padding(.leading, 6)
                    }
                }
            }
            Spacer(minLength: 6)
            if !model.isToday {
                // Another day: the way back to today takes the count's place (L) or sits by the arrows (XL).
                DayTodayChip(now: now, style: style).padding(.trailing, 2)
            } else if !summary, style.textSize != .large {
                Text(DayCopy.count(model)).font(style.font(10.5, .medium)).foregroundStyle(p.text3)
                    .padding(.trailing, 2)
            }
            DayControls(day: day, style: style, size: 22)
        }
        .lineLimit(1)
        .frame(height: 26)
    }
}

extension DayHeaderLine {
    fileprivate func dateTitle(_ name: String, _ datePattern: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(name).font(style.font(15, .bold)).foregroundStyle(style.palette.accent)
            Text(DayName.format(datePattern, day)).font(style.font(15, .bold)).foregroundStyle(style.palette.text)
        }
        .fixedSize()
    }

    fileprivate func markedTitle(_ name: String, _ datePattern: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            HeaderMark(style: style)
            dateTitle(name, datePattern)
        }
    }
}

/// XL Portrait: weekday (accent, small caps) over the date, then the summary, as Agenda's header.
private struct DayDateHeader: View {
    let day: Date
    let now: Date
    let model: DayModel
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links
    @Environment(\.widgetTitle) private var title

    var body: some View {
        let p = style.palette
        DayDateLink(day: day, now: now) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(DayName.format("EEEE", day).uppercased())
                        .font(style.font(10.5, .bold)).tracking(0.6).foregroundStyle(p.accent)
                    if let title { WidgetTitleTag(title: title, style: style) }
                }
                Text(DayName.format("d MMMM", day)).font(style.font(19, .bold)).foregroundStyle(p.text)
                Text(DayCopy.summary(model, style: style)).font(style.font(10.5)).foregroundStyle(p.text2).lineLimit(1)
            }
        }
    }
}

/// Medium's left panel: weekday, big date, the summary, then ‹ › ↻ at the bottom.
private struct DayMediumPanel: View {
    let day: Date
    let now: Date
    let model: DayModel
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        VStack(alignment: .leading, spacing: 2) {
            DayDateLink(day: day, now: now) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(DayName.format("EEEE", day).uppercased())
                        .font(style.font(10.5, .bold)).tracking(0.6).foregroundStyle(p.accent).lineLimit(1)
                    Text(DayName.format("d", day)).font(style.font(36, .bold)).foregroundStyle(p.text)
                    if model.joinMeeting == nil {
                        Text(DayCopy.mediumSummary(model, style: style))
                            .font(style.font(10.5)).foregroundStyle(p.text2).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // The meeting under way or next within 30 min, with its Join (as Agenda's Medium panel).
            if let join = model.joinMeeting {
                WidgetLink(destination: links.event(join)) {
                    Text(join.title).font(style.font(11, .semibold)).foregroundStyle(p.text).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WidgetLink(destination: links.join(join)) { JoinButton(style: style) }
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            DayControls(day: day, style: style, size: 20)
        }
    }
}

/// Small's Join: the focus meeting's call, in the header where it is always readable.
private struct DayJoinChip: View {
    let meeting: WidgetMeeting
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        WidgetLink(destination: links.join(meeting)) {
            HStack(spacing: 3) {
                Image(systemName: "video.fill").font(.system(size: 8 * style.scale, weight: .semibold))
                Text("Join").font(style.font(9.5, .semibold))
            }
            .foregroundStyle(style.palette.onAccent)
            .padding(.horizontal, 7).frame(height: 16)
            .background(Capsule().fill(style.palette.accent))
            .fixedSize()
        }
    }
}

/// ↻ ‹ › as round buttons (the pager's look). ‹ › pick the previous / next day in place (`day?w&d`,
/// quiet); at the sync window's edges the arrow fades and links nowhere. ↻ is the shared refresh button
/// (`sync?w=<kind>`, ✓ for 30 s after a healthy sync, D-021).
struct DayControls: View {
    let day: Date
    let style: WidgetStyle
    var size: CGFloat = 22

    @Environment(\.widgetLinks) private var links

    var body: some View {
        let cal = WidgetCalendar.current
        HStack(spacing: 4) {
            RefreshButton(style: style, round: size)
            circle("chevron.left", cal.date(byAdding: .day, value: -1, to: day).flatMap(links.selectDay))
                .accessibilityLabel("Previous day")
            circle("chevron.right", cal.date(byAdding: .day, value: 1, to: day).flatMap(links.selectDay))
                .accessibilityLabel("Next day")
        }
    }

    @ViewBuilder
    private func circle(_ symbol: String, _ url: URL?) -> some View {
        let p = style.palette
        let glyph = Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .bold))
            .frame(width: size, height: size)
            .background(Circle().fill(p.band))
            .contentShape(Circle())
        if let url {
            WidgetLink(destination: url) { glyph.foregroundStyle(p.text) }
        } else {
            glyph.foregroundStyle(p.text.opacity(0.3))
        }
    }
}

enum DayCopy {
    static func count(_ model: DayModel) -> String {
        let n = model.meetingCount
        return n == 0 ? "No meetings" : (n == 1 ? "1 meeting" : "\(n) meetings")
    }

    /// Today: "3 of 8 meetings left · free after 7:30 PM"; another day: "8 meetings · 9 AM – 7:30 PM".
    static func summary(_ model: DayModel, style: WidgetStyle) -> String {
        let timed = model.plan.blocks.map(\.meeting) + model.plan.overflow.flatMap(\.hidden)
        guard let last = timed.map(\.end).max() else {
            return model.plan.allDay.isEmpty ? "No meetings. Enjoy it." : count(model)
        }
        let (t, s) = WidgetClock.time(min(last, model.plan.dayEnd), style)
        let free = t + (s.isEmpty ? "" : " " + s)
        if model.isToday {
            let left = timed.filter { $0.end > model.now }.count
            if left == 0 { return "All done for today" }
            return "\(left) of \(timed.count) meetings left · free after \(free)"
        }
        return "\(count(model)) · done by \(free)"
    }

    static func mediumSummary(_ model: DayModel, style: WidgetStyle) -> String {
        let timed = model.plan.blocks.map(\.meeting) + model.plan.overflow.flatMap(\.hidden)
        guard let last = timed.map(\.end).max() else { return "No meetings. Enjoy it." }
        let (t, s) = WidgetClock.time(min(last, model.plan.dayEnd), style)
        if model.isToday, !timed.contains(where: { $0.end > model.now }) { return "All done for today" }
        return "\(count(model))\nFree after\n\(t)\(s.isEmpty ? "" : " " + s)"
    }

    /// What an empty slice says (S / M): "Free until 2 PM" or "Nothing else today".
    static func freeUntil(_ model: DayModel, after: Date, style: WidgetStyle) -> String {
        let next = model.plan.blocks.map(\.meeting).filter { $0.start >= after }.map(\.start).min()
        guard let next else {
            return model.plan.timedCount == 0 ? "Free all day" : (model.isToday ? "Nothing else today" : "Nothing later")
        }
        let (t, s) = WidgetClock.time(next, style)
        return "Free until \(t)\(s.isEmpty ? "" : " " + s)"
    }
}

// MARK: - Body: all-day chips over the grid

private struct DayBody: View {
    let model: DayModel
    let family: Family
    let style: WidgetStyle
    let width: CGFloat
    let gridHeight: CGFloat

    var body: some View {
        let metrics = DayMetrics.of(family, style)
        VStack(alignment: .leading, spacing: 6) {
            if !model.plan.allDay.isEmpty {
                DayAllDayRow(meetings: model.plan.allDay, style: style, width: width - metrics.gutter,
                             compact: family == .small || family == .medium)
                    .padding(.leading, metrics.gutter)
                    .frame(height: 20)
            }
            if family == .extraLarge, model.windows.count == 2 {
                let half = (width - 19) / 2
                HStack(alignment: .top, spacing: 9) {
                    DayGrid(model: model, window: model.windows[0], metrics: metrics, style: style,
                            width: half, height: gridHeight, family: family)
                    Rectangle().fill(style.palette.rule).frame(width: 1, height: gridHeight)
                    DayGrid(model: model, window: model.windows[1], metrics: metrics, style: style,
                            width: half, height: gridHeight, family: family)
                }
            } else {
                DayGrid(model: model, window: model.windows[0], metrics: metrics, style: style,
                        width: width, height: gridHeight, family: family)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if model.plan.timedCount == 0, family != .small, family != .medium {
                DayEmptyNote(model: model, window: model.windows[0], family: family, style: style)
                    .frame(width: width - metrics.gutter, height: gridHeight)
                    .padding(.leading, metrics.gutter)
            }
        }
    }
}

private struct DayAllDayRow: View {
    let meetings: [WidgetMeeting]
    let style: WidgetStyle
    let width: CGFloat
    let compact: Bool
    @Environment(\.widgetLinks) private var links

    var body: some View {
        // As many chips as fit at ~110 pt (compact: one), the rest as "+N".
        let fit = compact ? 1 : max(1, Int(width / 118))
        let shown = Array(meetings.prefix(meetings.count > fit ? max(1, fit - 1) : fit))
        let rest = meetings.count - shown.count
        HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, m in
                let tint = DayTint.of(m.account, style)
                WidgetLink(destination: links.event(m)) {
                    HStack(spacing: 4) {
                        if style.showLogos, m.account.logo != nil {
                            AccountBadge(account: m.account, style: style, size: 12)
                        }
                        Text(m.title).font(style.font(10, .semibold)).foregroundStyle(style.palette.text).lineLimit(1)
                    }
                    .padding(.leading, 5).padding(.trailing, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.fill))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(tint.edge).frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            if rest > 0 {
                Text("+\(rest)").font(style.font(10, .bold)).foregroundStyle(style.palette.text2)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(style.palette.band)).fixedSize()
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - Grid

/// One column of hours: labels, lines, blocks, "+N" chips and the now line, all placed by arithmetic.
private struct DayGrid: View {
    let model: DayModel
    let window: DayLayout.Window
    let metrics: DayMetrics
    let style: WidgetStyle
    let width: CGFloat
    let height: CGFloat
    let family: Family
    @Environment(\.widgetLinks) private var links

    /// Points per second of this grid (XL halves share `columnSeconds`).
    private var scale: CGFloat {
        let usable = height - metrics.inset * 2
        return usable / CGFloat(max(60, model.columnSeconds))
    }

    private func y(_ date: Date) -> CGFloat { metrics.inset + CGFloat(date.timeIntervalSince(window.start)) * scale }

    var body: some View {
        let p = style.palette
        let marks = DayLayout.hourMarks(window)
        let perHour = scale * 3600
        let every = perHour < 15 ? 3 : (perHour < 22 ? 2 : 1)
        let nowY: CGFloat? = model.isToday && window.contains(model.now) ? y(model.now) : nil
        let blocks = model.plan.blocks.filter { $0.start < window.end && max($0.visualEnd, $0.end) > window.start }
        let left = metrics.gutter
        let area = width - left
        let hourYs = marks.map(y)
        let halfYs = perHour >= 40 ? marks.map { $0.addingTimeInterval(1800) }.filter { $0 < window.end }.map(y) : []
        ZStack(alignment: .topLeading) {
            // A tap on the grid outside a block opens the Day Peek (blocks and "+N" are links above it).
            WidgetLink(destination: links.openDay(model.day)) {
                Color.clear.frame(width: area, height: height).contentShape(Rectangle())
            }
            .offset(x: left)
            // Hour lines (and faint half hours when there is room) as two shapes, labels in the gutter.
            DayLines(ys: halfYs, x: left, width: area).fill(p.rule.opacity(0.45))
            DayLines(ys: hourYs, x: left - 4, width: area + 4).fill(p.rule)
            ForEach(Array(marks.enumerated()), id: \.offset) { i, mark in
                let yy = hourYs[i]
                let hour = WidgetCalendar.current.component(.hour, from: mark)
                if hour % every == 0 {
                    // Compact (S / M): am/pm only on the first label and where it flips at noon.
                    let compact = family == .small || family == .medium
                    let suffix = !compact || i == 0 || hour == 12
                    DayHourLabel(date: mark, style: style, suffix: suffix, compact: compact)
                        .fixedSize()
                        .frame(width: left - 6, height: 12, alignment: .trailing)
                        .offset(x: 0, y: yy - 6)
                }
            }
            if blocks.isEmpty, model.plan.overflow.isEmpty, family == .small || family == .medium {
                DayEmptyNote(model: model, window: window, family: family, style: style)
                    .frame(width: area, height: height)
                    .offset(x: left)
            }
            // The now line runs under the blocks (over them it reads as a strike-through on titles); the
            // dot in the gutter and the focus ring carry it across a meeting.
            if let nowY {
                Rectangle().fill(p.accent).frame(width: area + 3, height: 1.5).offset(x: left - 3, y: nowY - 0.75)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                block(b, left: left, area: area)
            }
            ForEach(Array(model.plan.overflow.enumerated()), id: \.offset) { _, o in
                if o.start >= window.start && o.start < window.end {
                    overflowChip(o, left: left, area: area)
                }
            }
            if let nowY {
                Circle().fill(p.accent).frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(p.backgroundTop, lineWidth: 1))
                    .offset(x: left - 6.5, y: nowY - 3.5)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    @ViewBuilder
    private func block(_ b: DayLayout.Block, left: CGFloat, area: CGFloat) -> some View {
        let clusterWidth = area - (b.overflowLane ? metrics.lane : 0)
        let column = clusterWidth / CGFloat(max(1, b.columns))
        let x = left + column * CGFloat(b.column)
        let w = column * CGFloat(b.span) - 2
        let top = y(b.start)
        let bottom = max(y(b.end), top + metrics.minBlock)
        let clipTop = max(top, 0), clipBottom = min(bottom, height)
        let h = clipBottom - clipTop - 1.5
        if h >= 6 {
            DayBlockView(meeting: b.meeting, now: model.now, isToday: model.isToday,
                         focus: model.focusId == b.meeting.id, style: style,
                         width: w, height: h, family: family,
                         cutTop: top < 0, cutBottom: bottom > height)
                .offset(x: x, y: clipTop)
        }
    }

    private func overflowChip(_ o: DayLayout.Overflow, left: CGFloat, area: CGFloat) -> some View {
        let p = style.palette
        let top = max(0, y(o.start))
        return WidgetLink(destination: links.openDay(model.day)) {
            Text("+\(o.count)")
                .font(style.font(9.5, .bold)).foregroundStyle(p.text)
                .frame(width: metrics.lane - 3, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.band))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(p.rule, lineWidth: 1))
        }
        .offset(x: left + area - metrics.lane + 2, y: top)
    }
}

/// 1 pt rules at `ys` (one shape for every line: one layer instead of one view per line).
private struct DayLines: Shape {
    let ys: [CGFloat]
    let x: CGFloat
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for y in ys { path.addRect(CGRect(x: x, y: y - 0.5, width: width, height: 1)) }
        return path
    }
}

/// "9 am" as one Text (number + small suffix), "09:00" / "09" in 24 h.
private struct DayHourLabel: View {
    let date: Date
    let style: WidgetStyle
    var suffix = true
    var compact = false

    var body: some View {
        let p = style.palette
        if style.use24Hour {
            Text(DayName.format(compact ? "HH" : "HH:mm", date)).font(style.font(9, .medium)).monospacedDigit()
                .foregroundStyle(p.text2)
        } else if suffix {
            Text(DayName.format("h", date)).font(style.font(9.5, .medium)).monospacedDigit().foregroundStyle(p.text2)
                + Text("\u{2009}" + DayName.format("a", date).lowercased()).font(style.font(7.5, .medium)).foregroundStyle(p.text3)
        } else {
            Text(DayName.format("h", date)).font(style.font(9.5, .medium)).monospacedDigit().foregroundStyle(p.text2)
        }
    }
}

/// A grid with nothing in it: the persona voice, centred (L / XL / XLP), or "Free until 2 PM" (S / M).
private struct DayEmptyNote: View {
    let model: DayModel
    let window: DayLayout.Window
    let family: Family
    let style: WidgetStyle

    var body: some View {
        let p = style.palette
        let slice = family == .small || family == .medium
        if slice {
            Text(DayCopy.freeUntil(model, after: window.end, style: style))
                .font(style.font(11, .semibold)).foregroundStyle(p.text2)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(p.backgroundTop.opacity(0.9)))
                .overlay(Capsule().strokeBorder(p.rule, lineWidth: 1))
        } else if model.plan.timedCount == 0 {
            VStack(spacing: 6) {
                BrandMark().fill(p.accent).frame(width: 18 * style.scale, height: 18 * style.scale)
                    .frame(width: 36, height: 36).background(Circle().fill(p.accentSoft))
                Text(model.plan.allDay.isEmpty ? (model.isToday ? "No meetings today" : "No meetings") : "No timed meetings")
                    .font(style.font(13, .bold)).foregroundStyle(p.text)
                Text("Enjoy it.").font(style.font(11)).foregroundStyle(p.text2)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.backgroundTop))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.rule, lineWidth: 1))
        }
    }
}

// MARK: - Block

/// Account colour for a block: Paper = a light tint with a deeper left edge; Ink = a deeper tint with the
/// colour itself on the edge. Opaque mixes (never translucent stacks), so blocks read the same anywhere.
struct DayTint {
    let fill: Color
    /// Meetings already over today: the same hue, half as strong, still opaque (no offscreen opacity).
    let pastFill: Color
    let edge: Color
    let hatch: Color

    static func of(_ account: WidgetAccount, _ style: WidgetStyle) -> DayTint {
        let p = style.palette
        if style.mono { return DayTint(fill: p.band, pastFill: p.band, edge: p.text3, hatch: p.text3.opacity(0.35)) }
        let base = UInt32(account.color ?? fallback(account.id))
        if style.look == .paper {
            return DayTint(fill: Color(hex: mix(0xFFFFFF, base, 0.26)), pastFill: Color(hex: mix(0xFCFAF7, base, 0.12)),
                           edge: Color(hex: mix(base, 0x1D1B20, 0.28)), hatch: Color(hex: mix(base, 0x1D1B20, 0.1), opacity: 0.32))
        }
        return DayTint(fill: Color(hex: mix(0x1B252C, base, 0.32)), pastFill: Color(hex: mix(0x13212A, base, 0.15)),
                       edge: Color(hex: base), hatch: Color(hex: base, opacity: 0.30))
    }

    /// `a` → `b` by `t` per channel (sRGB).
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }
        func one(_ shift: UInt32) -> UInt32 { UInt32((ch(a, shift) * (1 - t) + ch(b, shift) * t).rounded()) << shift }
        return one(16) | one(8) | one(0)
    }

    /// Sample rows without a colour get a stable swatch from their id (FNV-1a, not `hashValue`).
    static func fallback(_ id: String) -> Int {
        var h: UInt32 = 2166136261
        for byte in id.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
        return Int(AppTheme.accountSwatches[Int(h % UInt32(AppTheme.accountSwatches.count))])
    }
}

/// Diagonal stripes (tentative meetings).
private struct Hatch: Shape {
    var spacing: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += spacing
        }
        return path
    }
}

private struct DayBlockView: View {
    let meeting: WidgetMeeting
    let now: Date
    let isToday: Bool
    /// The one meeting that matters now: accent ring, and Join when it has a link.
    let focus: Bool
    let style: WidgetStyle
    let width: CGFloat
    let height: CGFloat
    let family: Family
    /// The block runs on above / below this grid (S / M slices, XL halves): square that edge.
    var cutTop = false
    var cutBottom = false
    @Environment(\.widgetLinks) private var links

    private var past: Bool { isToday && meeting.end <= now }
    /// S / M put Join in the header / panel; L / XL / XLP on the block.
    private var joinable: Bool { focus && meeting.hasLink && family != .small && family != .medium }

    var body: some View {
        let p = style.palette
        let tint = DayTint.of(meeting.account, style)
        let r: CGFloat = 5
        let top: CGFloat = cutTop ? 1 : r, bottom: CGFloat = cutBottom ? 1 : r
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
        // The colour edge is its own shape (rounded on the left only), so the block needs no clip mask.
        let edge = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                          bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        let needsReply = meeting.reply == .needsReply
        let block = WidgetLink(destination: links.event(meeting)) {
            ZStack(alignment: .topLeading) {
                shape.fill(needsReply ? p.backgroundTop : (past ? tint.pastFill : tint.fill))
                if meeting.reply == .maybe {
                    Hatch().stroke(tint.hatch, lineWidth: 1.6).clipShape(shape)
                }
                if needsReply {
                    shape.strokeBorder(tint.edge, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                edge.fill(past ? tint.edge.opacity(0.45) : tint.edge).frame(width: 3, height: height)
                content
                if focus { shape.strokeBorder(p.accent, lineWidth: 1.5) }
            }
            .frame(width: width, height: height)
            .contentShape(shape)
        }
        // Only the focus block carries Join (a sibling link, never nested): the rest skip the wrapper.
        if joinable {
            ZStack(alignment: .topLeading) {
                block
                join
            }
            .frame(width: width, height: height, alignment: .topLeading)
        } else {
            block
        }
    }

    // Geometry of the content (points at this text size).
    private var tiny: Bool { height < 22 * style.scale }
    private var narrow: Bool { width < 96 }
    private var badgeSize: CGFloat { tiny || narrow ? 11 : (family == .extraLargePortrait || family == .extraLarge ? 13 : 12) }
    private var titleSize: CGFloat { narrow ? 10 : (family == .small || family == .medium ? 10.5 : 11) }
    private var lineHeight: CGFloat { titleSize * 1.2 * style.scale }
    /// Join sits bottom-right when the block is tall enough, so the title keeps the full width.
    private var joinAtBottom: Bool { height >= (narrow ? 29 : 34) * style.scale }
    private var joinWide: Bool { width >= 118 }
    private var topPad: CGFloat { 3 }

    @ViewBuilder
    private var content: some View {
        let p = style.palette
        let titleColor = past ? p.text3 : (meeting.reply == .maybe ? p.text2 : p.text)
        let timeColor = past ? p.text3 : p.text2
        let trailing: CGFloat = joinable && !joinAtBottom ? (joinWide ? 52 : 22) : 4
                if tiny {
            // One line: logo, title, start time (the time gives way first).
            HStack(spacing: 4) {
                if style.showLogos { AccountBadge(account: meeting.account, style: style, size: badgeSize).opacity(past ? 0.5 : 1) }
                (Text(meeting.title).font(style.font(titleSize - 0.5, .semibold)).foregroundStyle(titleColor)
                 + Text("  " + startText).font(style.font(9, .medium)).foregroundStyle(timeColor))
                    .lineLimit(1)
            }
            .padding(.leading, 6).padding(.trailing, trailing)
            .frame(width: width, height: height, alignment: .leading)
        } else {
            // The logo sits on the title's first line and the title wraps under it at full width (an
            // em-space indent the size of the badge), so even a narrow column keeps a readable title.
            let avail = height - topPad - 3 - (joinable && joinAtBottom ? 17 : 0)
            let timeLine = 12 * style.scale
            let showTime = !narrow && avail >= lineHeight + timeLine
            let rows = max(1, min(narrow ? 4 : 3, Int((avail - (showTime ? timeLine : 0)) / lineHeight)))
            let showPlace = !narrow && meeting.place != nil && rows <= 2
                && avail >= lineHeight * CGFloat(rows) + timeLine * 2
            if narrow {
                // Side-by-side columns: the logo sits on the title's first line and the title wraps under
                // it at full width (an em-space indent the size of the badge).
                ZStack(alignment: .topLeading) {
                    titleText(titleColor, withStart: false, indent: true).lineLimit(rows)
                    if style.showLogos {
                        AccountBadge(account: meeting.account, style: style, size: badgeSize).opacity(past ? 0.5 : 1)
                            .offset(y: max(0, (lineHeight - badgeSize * style.scale) / 2))
                    }
                }
                .padding(.leading, 6).padding(.trailing, trailing).padding(.top, topPad)
                .frame(width: width, height: height, alignment: .topLeading)
            } else {
                // Wide: a logo column, then title, time and place aligned in one text column.
                HStack(alignment: .top, spacing: 4) {
                    if style.showLogos {
                        AccountBadge(account: meeting.account, style: style, size: badgeSize).opacity(past ? 0.5 : 1)
                            .padding(.top, max(0, (lineHeight - badgeSize * style.scale) / 2))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        titleText(titleColor, withStart: !showTime, indent: false).lineLimit(rows)
                        if showTime {
                            Text(WidgetClock.range(meeting, style)).font(style.font(9.5, .medium)).monospacedDigit()
                                .foregroundStyle(timeColor).lineLimit(1)
                        }
                        if showPlace, let place = meeting.place {
                            Text(place).font(style.font(9.5)).foregroundStyle(p.text3).lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 6).padding(.trailing, trailing).padding(.top, topPad)
                .frame(width: width, height: height, alignment: .topLeading)
            }
        }
    }

    /// Badge-wide indent + title (+ the start time when no time line fits; it gives way first).
    private func titleText(_ color: Color, withStart: Bool, indent: Bool) -> Text {
        var text = Text(meeting.title).font(style.font(titleSize, .semibold)).foregroundStyle(color)
        if indent, style.showLogos {
            // Two em spaces at half the badge room: exactly that wide, never taller than the title line.
            let room = badgeSize * style.scale + 4
            text = Text("\u{2003}\u{2003}").font(.system(size: room / 2)) + text
        }
        if withStart {
            text = text + Text("  " + startText).font(style.font(9, .medium))
                .foregroundStyle(past ? style.palette.text3 : style.palette.text2)
        }
        return text
    }

    private var startText: String {
        let (t, s) = WidgetClock.time(meeting.start, style)
        return s.isEmpty ? t : "\(t) \(s.lowercased())"
    }

    /// Join is a sibling of the block's link (never nested): bottom-right on tall blocks, else top-right.
    private var join: some View {
        let p = style.palette
        let label = HStack(spacing: 3) {
            Image(systemName: "video.fill").font(.system(size: 8 * style.scale, weight: .semibold))
            if joinWide { Text("Join").font(style.font(9.5, .semibold)) }
        }
        .foregroundStyle(p.onAccent)
        .padding(.horizontal, joinWide ? 7 : 5).frame(height: 16)
        .background(Capsule().fill(p.accent))
        .fixedSize()
        let vertical: CGFloat = tiny ? max(0, (height - 16) / 2) : 3
        return WidgetLink(destination: links.join(meeting)) { label }
            .padding(joinAtBottom ? .bottom : .top, vertical).padding(.trailing, 3)
            .frame(width: width, height: height, alignment: joinAtBottom ? .bottomTrailing : .topTrailing)
    }
}
