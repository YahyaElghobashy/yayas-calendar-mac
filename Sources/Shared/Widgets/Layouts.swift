import SwiftUI

// MARK: - Agenda

struct AgendaColumn: View {
    let lines: [AgendaLine]
    let now: Date
    let style: WidgetStyle
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .day(let day, let continued, let count, let first, let slim):
                    DayBanner(day: day, continued: continued, count: count, now: now, style: style,
                              compact: compact, slim: slim)
                        .padding(.top, first ? 0 : (slim ? style.slimGap : style.dayGap))
                case .meeting(let meeting):
                    WidgetMeetingRow(meeting: meeting, now: now, style: style, compact: compact)
                }
            }
        }
    }
}

/// One-line header for Large and Extra Large: weekday in the accent colour, date, pager.
struct CompactHeader: View {
    let now: Date
    let meetings: [WidgetMeeting]
    let page: Int
    let pages: Int
    let style: WidgetStyle
    var showSummary = false
    /// Agenda & Inbox Extra Large keeps ↻ in its inbox header (the widget's top-right corner) instead.
    var showRefresh = true
    /// The 12 pt mark at the left; off on XL Portrait, whose stacked Agenda & Inbox reuses this line.
    var showMark = true
    @Environment(\.widgetLinks) private var links
    @Environment(\.widgetTitle) private var title

    var body: some View {
        let p = style.palette
        HStack(alignment: .center, spacing: 6) {
            WidgetLink(destination: links.open(.calendar)) {
                HeaderMarked(style: style, show: showMark) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(DayName.format("EEEE", now)).font(style.font(15, .bold)).foregroundStyle(p.accent)
                        Text(DayName.format("d MMMM", now)).font(style.font(15, .bold)).foregroundStyle(p.text)
                        if let title { WidgetTitleTag(title: title, style: style) }
                        if showSummary {
                            Text(DaySummary.text(meetings, now: now, style: style))
                                .font(style.font(11)).foregroundStyle(p.text2).padding(.leading, 6)
                        }
                    }
                }
            }
            Spacer(minLength: 6)
            if showRefresh { RefreshButton(style: style) }
            if pages > 1 { WidgetPager(page: page, count: pages, style: style) }
        }
        .lineLimit(1)
        .frame(height: 26)
    }
}

struct AgendaWidget: View {
    let family: Family
    let meetings: [WidgetMeeting]
    let now: Date
    let style: WidgetStyle
    var page = 1
    /// Points the paged lists give up at the bottom (a footer strip is showing).
    var reserve: CGFloat = 0

    var body: some View {
        WidgetCard(family, style) {
            switch family {
            case .small: UpNextSmall(meetings: meetings, now: now, style: style)
            case .medium: medium
            case .large: paged(columns: 1, headerSummary: false)
            case .extraLarge: paged(columns: 2, headerSummary: true)
            case .extraLargePortrait: portrait
            }
        }
    }

    static let pad: CGFloat = 13
    private var pad: CGFloat { Self.pad }

    /// The pages this widget would show (for render manifests and tests).
    static func pages(family: Family, meetings: [WidgetMeeting], now: Date, style: WidgetStyle,
                      reserve: CGFloat = 0) -> [[[AgendaLine]]] {
        let h = family.size.height - reserve
        switch family {
        case .large: return AgendaPaginator(style: style, columnHeight: h - pad * 2 - 26 - 8, columns: 1).pages(meetings, from: now)
        case .extraLarge: return AgendaPaginator(style: style, columnHeight: h - pad * 2 - 26 - 8, columns: 2).pages(meetings, from: now)
        case .extraLargePortrait: return AgendaPaginator(style: style, columnHeight: h - pad * 2 - 50 - 10, columns: 1).pages(meetings, from: now)
        case .medium: return AgendaPaginator(style: style, columnHeight: h - pad * 2, columns: 1).pages(meetings, from: now)
        case .small: return []
        }
    }

    private func paged(columns: Int, headerSummary: Bool) -> some View {
        let header: CGFloat = 26, gap: CGFloat = 8
        let height = family.size.height - pad * 2 - header - gap
        let all = Self.pages(family: family, meetings: meetings, now: now, style: style, reserve: reserve)
        let current = all.isEmpty ? [] : all[max(1, min(page, all.count)) - 1]
        return VStack(alignment: .leading, spacing: gap) {
            CompactHeader(now: now, meetings: meetings, page: page, pages: all.count, style: style, showSummary: headerSummary)
            HStack(alignment: .top, spacing: 18) {
                ForEach(0..<columns, id: \.self) { i in
                    if i < current.count {
                        AgendaColumn(lines: current[i], now: now, style: style)
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                    if i < columns - 1 {
                        Rectangle().fill(style.palette.rule).frame(width: 1, height: height)
                    }
                }
            }
        }
        .padding(pad)
    }

    private var portrait: some View {
        let headerHeight: CGFloat = 50, gap: CGFloat = 10
        let all = Self.pages(family: family, meetings: meetings, now: now, style: style, reserve: reserve)
        let current = all.isEmpty ? [] : all[max(1, min(page, all.count)) - 1]
        return VStack(alignment: .leading, spacing: gap) {
            HStack(alignment: .top) {
                DateHeader(now: now, meetings: meetings, style: style)
                Spacer()
                HStack(spacing: 6) {
                    RefreshButton(style: style)
                    if all.count > 1 { WidgetPager(page: page, count: all.count, style: style) }
                }
                .frame(height: 22)
            }
            .frame(height: headerHeight, alignment: .top)
            if let column = current.first { AgendaColumn(lines: column, now: now, style: style) }
        }
        .padding(pad)
    }

    /// Medium's list: today's banner and the next meeting live in the left panel, so they're dropped.
    static func mediumLines(meetings: [WidgetMeeting], now: Date, style: WidgetStyle) -> [AgendaLine] {
        let next = meetings.first { $0.end > now && !$0.allDay }
        let lines = (AgendaPaginator(style: style, columnHeight: Family.medium.size.height - pad * 2, columns: 1)
            .pages(meetings, from: now, maxColumns: 1).first?.first ?? []).filter {
            if case .day(let d, _, _, _, _) = $0 { return !WidgetCalendar.current.isDate(d, inSameDayAs: now) }
            if case .meeting(let m) = $0, let next, m.start == next.start, m.title == next.title { return false }
            return true
        }
        return Array(lines.prefix(5))
    }

    private var medium: some View {
        let next = meetings.first { $0.end > now && !$0.allDay }
        return HStack(alignment: .top, spacing: 14) {
            MediumDayPanel(meetings: meetings, next: next, now: now, style: style)
                .frame(width: 92, alignment: .leading)
                // ↻ beside the big date (the weekday above can run the panel's full width), a sibling link.
                .overlay(alignment: .topTrailing) {
                    RefreshButton(style: style).padding(.top, MediumDayPanel.refreshTop(style))
                }
            AgendaColumn(lines: Self.mediumLines(meetings: meetings, now: now, style: style), now: now, style: style, compact: true)
        }
        .padding(pad)
    }
}

/// Medium Agenda's left panel: weekday, big date, then the next meeting's Join or the day summary.
private struct MediumDayPanel: View {
    let meetings: [WidgetMeeting]
    let next: WidgetMeeting?
    let now: Date
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    /// Centres ↻ on the big date: the weekday line (10.5 pt) and the gap, then half the date's line
    /// (38 pt) less half the glyph.
    static func refreshTop(_ style: WidgetStyle) -> CGFloat {
        ((13 + 2 + 23) * style.scale - RefreshButton.side / 2).rounded()
    }

    var body: some View {
        let p = style.palette
        VStack(alignment: .leading, spacing: 2) {
            WidgetLink(destination: links.open(.calendar)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DayName.format("EEEE", now).uppercased())
                        .font(style.font(10.5, .bold)).tracking(0.6).foregroundStyle(p.accent)
                    Text(DayName.format("d", now)).font(style.font(38, .bold)).foregroundStyle(p.text)
                }
            }
            Spacer(minLength: 0)
            // The same 30-minute window as the rows' highlight and Join chip (the −30 min entry shows it).
            if let next, next.hasLink, next.start.timeIntervalSince(now) <= 30 * 60 {
                WidgetLink(destination: links.event(next)) {
                    Text(next.title).font(style.font(11, .semibold)).foregroundStyle(p.text).lineLimit(2)
                }
                WidgetLink(destination: links.join(next)) { JoinButton(style: style) }
                    .padding(.top, 3)
            } else {
                Text(DaySummary.text(meetings, now: now, style: style))
                    .font(style.font(10.5)).foregroundStyle(p.text2).lineLimit(3)
            }
        }
    }
}

struct UpNextSmall: View {
    let meetings: [WidgetMeeting]
    let now: Date
    let style: WidgetStyle
    /// Up Next Medium keeps ↻ in its "After that" header (the widget's top-right corner) instead.
    var showRefresh = true
    /// Up Next Medium: Join with Fathom beside Join when the meeting offers it (D-045); Small keeps one Join.
    var showRecord = false
    @Environment(\.widgetLinks) private var links

    /// A started meeting stays on the card this long, then the next one takes over.
    static let grace: TimeInterval = 15 * 60

    static func next(_ meetings: [WidgetMeeting], now: Date) -> WidgetMeeting? {
        meetings.first { !$0.allDay && $0.end > now && $0.start >= now.addingTimeInterval(-grace) }
    }

    var body: some View {
        let p = style.palette
        let next = Self.next(meetings, now: now)
        return VStack(alignment: .leading, spacing: 4) {
            if let next {
                WidgetLink(destination: links.event(next)) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            AccountBadge(account: next.account, style: style, size: 18)
                            Text(next.start <= now ? "Now" : WidgetClock.until(next.start, from: now).capitalizedFirst)
                                .font(style.font(12, .semibold)).foregroundStyle(p.accent)
                        }
                        Text(next.title).font(style.font(15, .bold)).foregroundStyle(p.text).lineLimit(2)
                            .padding(.top, 2)
                        Text(WidgetClock.range(next, style)).font(style.font(11)).foregroundStyle(p.text2)
                    }
                }
                Spacer(minLength: 0)
                if next.hasLink {
                    HStack(spacing: 6) {
                        WidgetLink(destination: links.join(next)) { JoinButton(style: style, big: true) }
                        if showRecord && next.rec {
                            WidgetLink(destination: links.record(next)) { RecordButton(style: style, kind: next.recBy) }
                        }
                    }
                } else if let place = next.place {
                    Label(place, systemImage: "mappin.and.ellipse").font(style.font(11)).foregroundStyle(p.text2)
                }
            } else {
                Text("Nothing booked. Suspicious.").font(style.font(13, .semibold)).foregroundStyle(p.text2)
                    .padding(.trailing, showRefresh ? RefreshButton.side : 0)
            }
        }
        .padding(14)
        // Full width (children stay leading) so ↻ sits in the card's top-right corner, level with the
        // badge row and outside the meeting's link.
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if showRefresh { RefreshButton(style: style).padding(14) }
        }
    }
}

// MARK: - Up Next (kind `upnext`)

struct UpNextWidget: View {
    let family: Family
    let meetings: [WidgetMeeting]
    let now: Date
    let style: WidgetStyle

    var body: some View {
        WidgetCard(family, style) {
            if family == .small {
                UpNextSmall(meetings: meetings, now: now, style: style)
            } else {
                medium
            }
        }
    }

    /// Medium's right column: what follows the card, without today's banner (the card implies it).
    static func laterLines(meetings: [WidgetMeeting], now: Date, style: WidgetStyle) -> [AgendaLine] {
        let next = UpNextSmall.next(meetings, now: now)
        let rest = meetings.filter { m in m.end > now && !(next.map { $0.start == m.start && $0.title == m.title } ?? false) }
        // Today's banner is implied by the card on the left; later days keep theirs.
        let lines = (AgendaPaginator(style: style, columnHeight: 164 - 26 - 18, columns: 1)
            .pages(rest, from: now, maxColumns: 1).first?.first ?? []).filter {
                if case .day(let d, _, _, _, _) = $0 { return !WidgetCalendar.current.isDate(d, inSameDayAs: now) }
                return true
            }
        return Array(lines.prefix(5))
    }

    /// Built from the Small card: the Small card on the left, what follows on the right.
    private var medium: some View {
        let p = style.palette
        let lines = Self.laterLines(meetings: meetings, now: now, style: style)
        return HStack(alignment: .top, spacing: 0) {
            UpNextSmall(meetings: meetings, now: now, style: style, showRefresh: false, showRecord: true)
                .frame(width: 156, alignment: .leading)
            Rectangle().fill(p.rule).frame(width: 1).padding(.vertical, 13)
            VStack(alignment: .leading, spacing: 4) {
                Text("AFTER THAT").font(style.font(9.5, .bold)).tracking(0.7).foregroundStyle(p.text3)
                    .frame(height: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) { RefreshButton(style: style) }
                AgendaColumn(lines: lines, now: now, style: style, compact: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 13)
        }
    }
}

// MARK: - Inbox

/// One mail row. Snapshot rows are live: the unread dot marks the thread read (`mail/read`), the
/// row opens the Mail Peek (`open/message`), the archive glyph archives (`mail/archive`). Three sibling
/// Links, never nested. A row archived from a widget reads "Archived · Undo" (`mail/undo`) for 30 s.
struct WidgetMailRow: View {
    let mail: WidgetMail
    let now: Date
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    /// Width of the unread-dot slot (a tap target wider than the 6 pt dot) and of the archive glyph.
    static let dotSlot: CGFloat = 13
    static let archiveSlot: CGFloat = 20

    var body: some View {
        if mail.archivedAt != nil { undoRow } else { liveRow }
    }

    private var liveRow: some View {
        let p = style.palette
        return HStack(spacing: 0) {
            readDot
            WidgetLink(destination: links.mail(mail)) {
                HStack(spacing: 7) {
                    AccountBadge(account: mail.account, style: style)
                    Text(mail.sender)
                        .font(style.font(12.5, mail.unread ? .semibold : .regular))
                        .foregroundStyle(mail.unread ? p.text : p.text2)
                        .lineLimit(1).frame(width: 98 * style.scale, alignment: .leading)
                    if mail.starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8.5 * style.scale, weight: .bold))
                            .foregroundStyle(p.warn)
                            .padding(.trailing, -3)
                            .accessibilityLabel(WidgetA11y.starred)
                    }
                    Text(mail.subject).font(style.font(12)).foregroundStyle(p.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(when).font(style.font(10.5)).foregroundStyle(p.text3).monospacedDigit()
                }
                .frame(height: style.meetingRow)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken.label)
                .accessibilityValue(spoken.value)
            }
            WidgetLink(destination: links.mailArchive(mail)) {
                Image(systemName: "archivebox")
                    .font(.system(size: 10 * style.scale, weight: .semibold))
                    .foregroundStyle(p.text3)
                    .frame(width: Self.archiveSlot * style.scale, height: style.meetingRow, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(WidgetA11y.archive(mail.subject))
        }
        .frame(height: style.meetingRow)
    }

    @ViewBuilder
    private var readDot: some View {
        let dot = Circle().fill(mail.unread ? style.palette.accent : .clear).frame(width: 6, height: 6)
            .frame(width: Self.dotSlot, height: style.meetingRow, alignment: .leading)
            .contentShape(Rectangle())
        if mail.unread {
            WidgetLink(destination: links.mailRead(mail)) { dot }
                .accessibilityLabel(WidgetA11y.markRead(mail.subject))
        } else {
            dot.accessibilityHidden(true)
        }
    }

    /// "Archived · Undo": the whole row is the undo link, on the soft accent fill the highlighted
    /// meeting uses, with the subject faded beside it so you know which one went.
    private var undoRow: some View {
        let p = style.palette
        return WidgetLink(destination: links.mailUndo(mail)) {
            // Same columns as a live row: the glyph sits where the logo was, the words where the sender was.
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.dotSlot)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 9.5 * style.scale, weight: .semibold))
                    .foregroundStyle(p.accent)
                    .frame(width: 16 * style.scale)
                (Text("Archived").foregroundStyle(p.text) + Text(" · ").foregroundStyle(p.text3)
                    + Text("Undo").foregroundStyle(p.accent).bold())
                    .font(style.font(12, .semibold))
                    .fixedSize()
                    .padding(.leading, 7)
                Text(mail.subject).font(style.font(11)).foregroundStyle(p.text3).lineLimit(1)
                    .padding(.leading, 10)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: style.meetingRow - 2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.accentSoft))
            .padding(.horizontal, -6)
            .frame(height: style.meetingRow)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetA11y.undoArchive(mail.subject))
        }
    }

    private var when: String {
        let (t, s) = WidgetClock.time(mail.at, style)
        return s.isEmpty ? t : "\(t) \(s.lowercased())"
    }

    /// What VoiceOver reads for the row's main link.
    private var spoken: (label: String, value: String) {
        WidgetA11y.mail(sender: mail.sender, subject: mail.subject, unread: mail.unread, starred: mail.starred, when: when)
    }
}

struct InboxWidget: View {
    let family: Family
    let mail: [WidgetMail]
    let now: Date
    let style: WidgetStyle
    var unreadCount: Int? = nil
    var page = 1

    var body: some View {
        WidgetCard(family, style) {
            InboxPanel(mail: mail, now: now, style: style, height: family.size.height - 26,
                       columns: Self.columns(family), showBanners: family != .medium, unreadCount: unreadCount, page: page,
                       showMark: family == .large || family == .extraLarge)
        }
    }

    static func columns(_ family: Family) -> Int { family == .extraLarge ? 2 : 1 }
    /// Height of the mail columns inside the panel (card padding, header, gap removed).
    static func listHeight(_ family: Family) -> CGFloat { family.size.height - 26 - 26 - 8 }
}

/// A day's worth of mail in one inbox column.
struct MailBlock {
    let day: Date
    let mail: [WidgetMail]
    let first: Bool
}

enum InboxLayout {
    /// Newest first; equal times keep their order (so pages never repeat or skip a row).
    static func newestFirst(_ a: WidgetMail, _ b: WidgetMail) -> Bool { a.at != b.at ? a.at > b.at : a.id < b.id }

    /// Newest first, day by day, filling `columns` columns of `height` points.
    static func columns(_ mail: [WidgetMail], style: WidgetStyle, height: CGFloat, columns: Int,
                        showBanners: Bool) -> [[MailBlock]] {
        let cal = WidgetCalendar.current
        let row = style.meetingRow
        let byDay = Dictionary(grouping: mail) { cal.startOfDay(for: $0.at) }
        var out: [[MailBlock]] = []
        var column: [MailBlock] = []
        var budget = height
        for day in byDay.keys.sorted(by: >) {
            var items = ArraySlice(byDay[day]!.sorted(by: newestFirst))
            while !items.isEmpty {
                let banner = showBanners ? style.dayBanner + (column.isEmpty ? 0 : style.dayGap) : 0
                if budget < banner + row {
                    if column.isEmpty { return out }          // a column too short for anything
                    out.append(column); column = []; budget = height
                    if out.count == columns { return out }
                    continue
                }
                budget -= banner
                let n = min(items.count, Int((budget + 0.01) / row))
                column.append(MailBlock(day: day, mail: Array(items.prefix(n)), first: column.isEmpty))
                budget -= CGFloat(n) * row
                items = items.dropFirst(n)
            }
        }
        if !column.isEmpty, out.count < columns { out.append(column) }
        return out
    }

    /// Every page of the inbox (the pager's ‹ 1 of 2 ›): each page fills its columns with the next
    /// newest rows. At most `maxPages` (a snapshot carries ≤ 96 rows).
    static func pages(_ mail: [WidgetMail], style: WidgetStyle, height: CGFloat, columns: Int,
                      showBanners: Bool, maxPages: Int = 24) -> [[[MailBlock]]] {
        var remaining = mail.sorted(by: newestFirst)
        var out: [[[MailBlock]]] = []
        while !remaining.isEmpty, out.count < maxPages {
            let page = Self.columns(remaining, style: style, height: height, columns: columns, showBanners: showBanners)
            let used = rowCount(page)
            guard used > 0 else { break }
            out.append(page)
            remaining.removeFirst(min(used, remaining.count))
        }
        return out
    }

    static func rowCount(_ page: [[MailBlock]]) -> Int { page.reduce(0) { $0 + $1.reduce(0) { $0 + $1.mail.count } } }
}

struct InboxPanel: View {
    let mail: [WidgetMail]
    let now: Date
    let style: WidgetStyle
    let height: CGFloat
    var columns = 1
    var showBanners = true
    var padding: CGFloat = 13
    var unreadCount: Int? = nil
    var page = 1
    /// Agenda & Inbox has one pager, for its agenda: its inbox shows the newest mail only.
    var showPager = true
    /// One ↻ per widget: Agenda & Inbox Large and XL Portrait keep it in the agenda header above.
    var showRefresh = true
    /// The 12 pt mark before the title: the Inbox widget's Large and Extra Large (Agenda & Inbox carries it
    /// in its agenda header).
    var showMark = false
    @Environment(\.widgetLinks) private var links
    @Environment(\.widgetTitle) private var title

    var body: some View {
        let p = style.palette
        let unread = unreadCount ?? mail.filter(\.unread).count
        // Without a pager (Agenda & Inbox) only the newest page shows: lay out just that one.
        let pages = InboxLayout.pages(mail, style: style, height: height - 26 - 8, columns: columns, showBanners: showBanners,
                                      maxPages: showPager ? 24 : 1)
        let shown = pages.isEmpty ? 1 : min(max(showPager ? page : 1, 1), pages.count)
        let layout = pages.isEmpty ? [] : pages[shown - 1]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                WidgetLink(destination: links.open(.inbox)) {
                    HeaderMarked(style: style, show: showMark) {
                        HStack(spacing: 6) {
                            Text(title ?? "Inbox").font(style.font(15, .bold)).foregroundStyle(p.text).lineLimit(1)
                            Text(unread == 0 ? "all read" : "\(unread) unread").font(style.font(11, .semibold)).foregroundStyle(p.accent)
                        }
                    }
                }
                Spacer()
                if showRefresh { RefreshButton(style: style) }
                if showPager, pages.count > 1 { WidgetPager(page: shown, count: pages.count, style: style) }
            }
            .frame(height: 26)
            if mail.isEmpty {
                InboxZeroNote(style: style, height: height - 26 - 8)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(0..<columns, id: \.self) { i in
                        if i < layout.count {
                            MailColumn(blocks: layout[i], now: now, style: style, showBanners: showBanners)
                        } else {
                            Spacer().frame(maxWidth: .infinity)
                        }
                        if i < columns - 1 {
                            Rectangle().fill(p.rule).frame(width: 1, height: height - 26 - 8)
                        }
                    }
                }
            }
        }
        .padding(padding)
    }
}

/// An empty inbox, in the persona voice (one tap opens the Inbox section).
private struct InboxZeroNote: View {
    let style: WidgetStyle
    let height: CGFloat
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        WidgetLink(destination: links.open(.inbox)) {
            VStack(spacing: 6) {
                BrandMark().fill(p.accent).frame(width: 20 * style.scale, height: 20 * style.scale)
                Text("Inbox zero").font(style.font(13, .bold)).foregroundStyle(p.text)
                if height > 60 {
                    Text("Nothing waiting. Go do something fun.").font(style.font(11)).foregroundStyle(p.text2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: max(0, height), alignment: .center)
            .contentShape(Rectangle())
        }
    }
}

private struct MailColumn: View {
    let blocks: [MailBlock]
    let now: Date
    let style: WidgetStyle
    let showBanners: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if showBanners {
                    MailDayBanner(day: block.day, count: block.mail.filter { $0.unread && $0.archivedAt == nil }.count,
                                  now: now, style: style)
                        .padding(.top, block.first ? 0 : style.dayGap)
                }
                ForEach(Array(block.mail.enumerated()), id: \.offset) { _, m in
                    WidgetMailRow(mail: m, now: now, style: style)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MailDayBanner: View {
    let day: Date
    let count: Int
    let now: Date
    let style: WidgetStyle

    var body: some View {
        let p = style.palette
        let cal = WidgetCalendar.current
        let title = cal.isDate(day, inSameDayAs: now) ? "Today"
            : (cal.isDate(day, inSameDayAs: cal.date(byAdding: .day, value: -1, to: now)!) ? "Yesterday" : DayName.format("EEEE", day))
        HStack {
            Text(title).font(style.font(11.5, .bold)).foregroundStyle(title == "Today" ? p.accent : p.text)
            Spacer()
            if count > 0 { Text("\(count) unread").font(style.font(10, .medium)).foregroundStyle(p.text3) }
        }
        .padding(.horizontal, 8)
        .frame(height: style.dayBanner)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.band))
    }
}

// MARK: - Agenda & Inbox

struct ComboWidget: View {
    var family: Family = .extraLarge
    let meetings: [WidgetMeeting]
    let mail: [WidgetMail]
    let now: Date
    let style: WidgetStyle
    var unreadCount: Int? = nil
    /// The agenda half's page (the combo's one pager); the inbox half shows the newest mail.
    var page = 1

    var body: some View {
        WidgetCard(family, style) {
            switch family {
            case .large: stacked(agendaHeight: 134, inboxBanners: false)
            case .extraLargePortrait: stacked(agendaHeight: 360, inboxBanners: true)
            default: sideBySide
            }
        }
    }

    /// Agenda pages for the combo's agenda column (`height` points, one column).
    static func agendaPages(_ meetings: [WidgetMeeting], now: Date, style: WidgetStyle, height: CGFloat) -> [[AgendaLine]] {
        AgendaPaginator(style: style, columnHeight: height, columns: 1).pages(meetings, from: now).map { $0.first ?? [] }
    }

    static func agendaHeight(_ family: Family) -> CGFloat {
        switch family {
        case .large: return 134
        case .extraLargePortrait: return 360
        default: return 344 - 26 - 26 - 8
        }
    }

    /// The Extra Large layout: agenda on the left, inbox on the right.
    private var sideBySide: some View {
        let pages = Self.agendaPages(meetings, now: now, style: style, height: Self.agendaHeight(.extraLarge))
        let shown = pages.isEmpty ? 1 : min(max(page, 1), pages.count)
        let lines = pages.isEmpty ? [] : pages[shown - 1]
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                CompactHeader(now: now, meetings: meetings, page: shown, pages: pages.count, style: style, showRefresh: false)
                AgendaColumn(lines: lines, now: now, style: style)
            }
            .padding(13)
            .frame(width: 352)
            Rectangle().fill(style.palette.rule).frame(width: 1).padding(.vertical, 13)
            InboxPanel(mail: mail, now: now, style: style, height: 344 - 26, unreadCount: unreadCount, showPager: false)
                .frame(width: 351)
        }
    }

    /// For Large and XL Portrait, from the Extra Large layout: agenda on top, inbox below.
    private func stacked(agendaHeight: CGFloat, inboxBanners: Bool) -> some View {
        let inner = family.size.height - 26
        let paginator = AgendaPaginator(style: style, columnHeight: agendaHeight, columns: 1)
        let pages = Self.agendaPages(meetings, now: now, style: style, height: agendaHeight)
        let shown = pages.isEmpty ? 1 : min(max(page, 1), pages.count)
        let lines = pages.isEmpty ? [] : pages[shown - 1]
        // The agenda takes what its rows need; the inbox gets the rest.
        let used = lines.reduce(CGFloat(0)) { $0 + paginator.height($1) }
        let inboxHeight = inner - 26 - 8 - used - 17
        return VStack(alignment: .leading, spacing: 8) {
            CompactHeader(now: now, meetings: meetings, page: shown, pages: pages.count, style: style,
                          showMark: family != .extraLargePortrait)
            AgendaColumn(lines: lines, now: now, style: style)
                .frame(height: used, alignment: .top)
            Rectangle().fill(style.palette.rule).frame(height: 1)
            InboxPanel(mail: mail, now: now, style: style, height: inboxHeight, showBanners: inboxBanners, padding: 0,
                       unreadCount: unreadCount, showPager: false, showRefresh: false)
        }
        .padding(13)
    }
}

// MARK: - Custom Widget A–F, not set up yet

/// The "slot unconfigured" state. One tap target opens Widgets.
struct CustomSetupWidget: View {
    let family: Family
    let letter: String
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        let small = family == .small
        WidgetCard(family, style) {
            ZStack(alignment: .topTrailing) {
                WidgetLink(destination: links.open(.widgets)) {
                    VStack(alignment: small ? .leading : .center, spacing: small ? 6 : 10) {
                        BrandMark().fill(p.accent)
                            .frame(width: (small ? 18 : 24) * style.scale, height: (small ? 18 : 24) * style.scale)
                            .frame(width: small ? 36 : 48, height: small ? 36 : 48)
                            .background(Circle().fill(p.accentSoft))
                        Text("Custom Widget \(letter)")
                            .font(style.font(small ? 13 : 16, .bold)).foregroundStyle(p.text)
                        Text(small ? "Not set up yet." : "Not set up yet. Pick its calendars and look in Yaya's Calendar.")
                            .font(style.font(small ? 11 : 12)).foregroundStyle(p.text2)
                            .multilineTextAlignment(small ? .leading : .center)
                            .fixedSize(horizontal: false, vertical: true)
                        if small { Spacer(minLength: 0) }
                        HStack(spacing: 4) {
                            Text("Set it up").font(style.font(11.5, .semibold))
                            Image(systemName: "arrow.right").font(.system(size: 9.5 * style.scale, weight: .bold))
                        }
                        .foregroundStyle(p.onAccent)
                        .padding(.horizontal, 12)
                        .frame(height: 26 * style.scale)
                        .background(Capsule().fill(p.accent))
                    }
                    .padding(small ? 14 : 24)
                    .frame(width: family.size.width, height: family.size.height,
                           alignment: small ? .topLeading : .center)
                    .contentShape(Rectangle())
                }
                RefreshButton(style: style).padding(WidgetMessageCard.refreshInset(family))
            }
        }
    }
}
