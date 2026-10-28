import SwiftUI

/// "Month": a mini calendar; tapping a day (a Link) shows that day's meetings. Today is a filled accent
/// circle, the picked day an accent ring, and days with meetings get a dot. The week starts on the
/// Mac's first weekday (Monday in the UK, Sunday in the US).
struct MonthGrid: View {
    let month: Date          // any date inside the month shown
    let selected: Date
    let now: Date
    let meetings: [WidgetMeeting]
    let style: WidgetStyle
    var cell: CGSize = CGSize(width: 22, height: 19)
    var showTitle = true
    var spacing: CGFloat = 3
    /// Snapshot days with meetings (`YYYY-MM-DD`): dots even for days whose meetings aren't carried.
    var busyDays: Set<String> = []
    /// The 12 pt mark before the month's name: Large and Extra Large.
    var showMark = false
    @Environment(\.widgetLinks) private var links
    @Environment(\.widgetTitle) private var title

    private var cal: Calendar { WidgetCalendar.current }

    var body: some View {
        let p = style.palette
        let days = gridDays
        let symbols = weekdaySymbols
        // Days that have a meeting, once per render (each cell used to scan every meeting).
        let meetingDays = Set(meetings.map { cal.startOfDay(for: $0.start) })
        VStack(alignment: .leading, spacing: spacing) {
            if showTitle {
                HStack(spacing: 4) {
                    if cell.width * 7 > 200 {
                        HeaderMarked(style: style, show: showMark, spacing: 4) {
                            HStack(spacing: 4) {
                                monthName("MMMM")
                                if let title { WidgetTitleTag(title: title, style: style) }
                            }
                        }
                        Spacer(minLength: 2)
                    } else {
                        // Small and Medium: 140 pt hold the name, ↻ and both arrows. A long month
                        // ("SEPTEMBER", or a larger text size) shortens to "SEP" instead of truncating.
                        ViewThatFits(in: .horizontal) {
                            monthName("MMMM")
                            monthName("MMM")
                        }
                        .frame(width: cell.width * 7 - Self.narrowControls, alignment: .leading)
                    }
                    RefreshButton(style: style)
                    arrow("chevron.left", months: -1)
                    arrow("chevron.right", months: 1)
                }
                .frame(width: cell.width * 7, height: 18)
            }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[i]).font(style.font(9.5, .semibold)).foregroundStyle(p.text3)
                        .frame(width: cell.width)
                }
            }
            ForEach(0..<days.count / 7, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let day = days[row * 7 + col]
                        WidgetLink(destination: links.day(day)) { dayCell(day, meetingDays: meetingDays) }
                    }
                }
            }
        }
    }

    /// ↻ and the two arrows (18 pt each) with the title row's three 4 pt gaps.
    static let narrowControls: CGFloat = 3 * RefreshButton.side + 3 * 4

    private func monthName(_ pattern: String) -> some View {
        Text(DayName.format(pattern, month).uppercased())
            .font(style.font(11, .bold)).tracking(0.8).foregroundStyle(style.palette.text)
            .lineLimit(1)
    }

    /// `month?w&to`; an arrow pointing outside the sync window is drawn faded and links nowhere.
    @ViewBuilder
    private func arrow(_ symbol: String, months: Int) -> some View {
        let p = style.palette
        let target = cal.date(byAdding: .month, value: months, to: month) ?? month
        let circle = Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            .frame(width: 18, height: 18).background(Circle().fill(p.band))
            .contentShape(Circle())
        if let url = links.month(target) {
            WidgetLink(destination: url) { circle.foregroundStyle(p.text3) }
                .accessibilityLabel(WidgetA11y.month(forward: months > 0, to: target))
        } else {
            circle.foregroundStyle(p.text3.opacity(0.35))
                .accessibilityHidden(true)
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortWeekdaySymbols   // Sunday first
        return (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
    }

    private var gridDays: [Date] {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let first = cal.date(byAdding: .day, value: -lead, to: start)!
        let count = cal.range(of: .day, in: .month, for: start)!.count
        let rows = Int(ceil(Double(lead + count) / 7.0))
        return (0..<(rows * 7)).map { cal.date(byAdding: .day, value: $0, to: first)! }
    }

    /// `meetingDays`: start of every day with a meeting carried (same test as `isDate(inSameDayAs:)`).
    private func dayCell(_ day: Date, meetingDays: Set<Date>) -> some View {
        let p = style.palette
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = cal.isDate(day, inSameDayAs: now)
        let isPicked = cal.isDate(day, inSameDayAs: selected)
        let busy = inMonth && (meetingDays.contains(cal.startOfDay(for: day)) || busyDays.contains(DayName.linkDay(day)))
        let side = min(cell.width, cell.height) - 1
        return ZStack {
            if isToday {
                Circle().fill(p.accent).frame(width: side, height: side)
            } else if isPicked {
                Circle().strokeBorder(p.accent, lineWidth: 1.5).frame(width: side, height: side)
            }
            Text("\(cal.component(.day, from: day))")
                .font(style.font(10.5, isToday || isPicked ? .bold : .medium)).monospacedDigit()
                .foregroundStyle(isToday ? p.onAccent : (inMonth ? p.text : p.text3))
            if busy && !isToday {
                Circle().fill(p.accent.opacity(0.75)).frame(width: 3.5, height: 3.5)
                    .offset(y: side / 2 - 1)
            }
        }
        .frame(width: cell.width, height: cell.height)
        .contentShape(Rectangle())
    }
}

/// The picked day's meetings, under a banner. Falls through to the following days when there is room.
struct DayList: View {
    let day: Date
    let now: Date
    let meetings: [WidgetMeeting]
    let style: WidgetStyle
    let height: CGFloat
    var compact = false

    static func lines(day: Date, now: Date, meetings: [WidgetMeeting], style: WidgetStyle, height: CGFloat) -> [AgendaLine] {
        let cal = WidgetCalendar.current
        let fromDay = meetings.filter { $0.start >= cal.startOfDay(for: day) }
        return AgendaPaginator(style: style, columnHeight: height, columns: 1)
            .pages(fromDay, from: cal.isDate(day, inSameDayAs: now) ? now : cal.startOfDay(for: day), maxColumns: 1)
            .first?.first ?? []
    }

    var body: some View {
        let lines = Self.lines(day: day, now: now, meetings: meetings, style: style, height: height)
        if lines.isEmpty {
            Text("Nothing booked that day.").font(style.font(12)).foregroundStyle(style.palette.text2)
        } else {
            AgendaColumn(lines: lines, now: now, style: style, compact: compact)
        }
    }
}

struct MonthWidget: View {
    let family: Family
    let meetings: [WidgetMeeting]
    let now: Date
    let selected: Date
    let style: WidgetStyle
    /// Month on the grid (any date inside it); nil = this month.
    var shown: Date? = nil
    var busyDays: Set<String> = []

    /// Point budget of the picked-day list per family (manifests and tests use the same numbers).
    static func listHeight(_ family: Family) -> CGFloat? {
        switch family {
        case .small: return nil
        case .medium: return 164 - 22
        case .large: return 344 - 26 - 160
        case .extraLarge: return 344 - 26
        case .extraLargePortrait: return 704 - 26 - 246
        }
    }

    private func grid(_ cell: CGSize, spacing: CGFloat = 3) -> MonthGrid {
        MonthGrid(month: shown ?? now, selected: selected, now: now, meetings: meetings, style: style,
                  cell: cell, spacing: spacing, busyDays: busyDays, showMark: family == .large || family == .extraLarge)
    }

    var body: some View {
        WidgetCard(family, style) {
            switch family {
            case .small:
                grid(CGSize(width: 20, height: 16.5), spacing: 1)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            case .medium:
                HStack(alignment: .top, spacing: 14) {
                    grid(CGSize(width: 20, height: 16.5), spacing: 1)
                    DayList(day: selected, now: now, meetings: meetings, style: style, height: Self.listHeight(.medium)!, compact: true)
                }
                .padding(.horizontal, 13).padding(.vertical, 11)
            case .large:
                VStack(alignment: .leading, spacing: 10) {
                    grid(CGSize(width: 45, height: 19))
                    DayList(day: selected, now: now, meetings: meetings, style: style, height: Self.listHeight(.large)!)
                }
                .padding(13)
            case .extraLarge:
                HStack(alignment: .top, spacing: 18) {
                    grid(CGSize(width: 40, height: 40))
                    Rectangle().fill(style.palette.rule).frame(width: 1)
                    DayList(day: selected, now: now, meetings: meetings, style: style, height: Self.listHeight(.extraLarge)!)
                }
                .padding(13)
            case .extraLargePortrait:
                VStack(alignment: .leading, spacing: 12) {
                    grid(CGSize(width: 45, height: 30))
                    DayList(day: selected, now: now, meetings: meetings, style: style, height: Self.listHeight(.extraLargePortrait)!)
                }
                .padding(13)
            }
        }
    }
}
