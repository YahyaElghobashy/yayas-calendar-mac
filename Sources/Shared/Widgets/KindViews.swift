import SwiftUI

/// The one mapping from (kind, family, data) to a design, used by the widget extension, the app's
/// Widgets gallery and Studio, and the headless renders, so all of them always draw the same thing.
struct KindView: View {
    let spec: WidgetKindSpec
    let family: Family
    let data: WidgetData
    let style: WidgetStyle
    var page = 1
    @Environment(\.widgetTone) private var tone

    /// What a (kind, family, data) draws after the whole-card states and the family fallbacks.
    enum Resolved: Equatable {
        case design(WidgetContent)
        case card(WidgetCardState)
        /// A custom slot set to Inbox shown Small: just the count (the list needs Medium or larger).
        case inboxSmall
    }

    static func resolve(spec: WidgetKindSpec, family: Family, data: WidgetData) -> Resolved {
        if data.state != .content { return .card(data.state) }
        let content = data.content ?? spec.content
        switch (content, family) {
        case (.custom, _): return .card(.setup)
        // Up Next has only Small and Medium designs; bigger custom slots lead with the same meeting
        // on the agenda, highlighted with its Join chip.
        case (.upNext, .large), (.upNext, .extraLarge), (.upNext, .extraLargePortrait): return .design(.agenda)
        case (.combo, .small), (.combo, .medium): return .design(.agenda)
        case (.inbox, .small): return .inboxSmall
        default: return .design(content)
        }
    }

    var body: some View {
        var s = style
        if s.tone == .color { s.tone = tone }
        let footer = data.state == .content ? data.health.footer(at: data.now) : .none
        let links = WidgetLinkContext(kind: spec.kind, family: family, windowStart: data.windowStart, windowEnd: data.windowEnd)
        let compact = Self.compactFooter(family)
        return ZStack(alignment: compact ? .top : .bottom) {
            content(s, reserve: footer == .none || compact ? 0 : WidgetFooterView.reserve)
            if footer != .none {
                WidgetFooterView(footer: footer, style: s, compact: compact)
                    .padding(compact ? .top : .bottom, compact ? 1 : 3)
            }
        }
        .frame(width: family.size.width, height: family.size.height)
        .environment(\.widgetLinks, links)
        .environment(\.widgetTitle, data.title)
        .environment(\.widgetJustSynced, data.state == .content && data.health.justSynced(at: data.now))
    }

    @ViewBuilder
    private func content(_ style: WidgetStyle, reserve: CGFloat) -> some View {
        switch Self.resolve(spec: spec, family: family, data: data) {
        case .design(.agenda):
            AgendaWidget(family: family, meetings: data.agendaMeetings, now: data.now, style: style, page: page, reserve: reserve)
        case .design(.upNext):
            UpNextWidget(family: family, meetings: data.meetings, now: data.now, style: style)
        case .design(.month):
            MonthWidget(family: family, meetings: data.meetings, now: data.now, selected: data.selectedDay, style: style,
                        shown: data.monthShown, busyDays: data.busyDays)
        case .design(.inbox):
            InboxWidget(family: family, mail: data.mail, now: data.now, style: style, unreadCount: data.unreadCount, page: page)
        case .design(.combo):
            ComboWidget(family: family, meetings: data.agendaMeetings, mail: data.mail, now: data.now, style: style,
                        unreadCount: data.unreadCount, page: page)
        case .design(.day):
            DayTimelineWidget(family: family, meetings: data.meetings, now: data.now, style: style, day: data.selectedDay,
                              reserve: reserve)
        case .design(.digest):
            if let digest = data.digest {
                DigestWidget(family: family, digest: digest, now: data.now, style: style)
            } else {
                WidgetStateCard(state: .noDigest, family: family, style: style)
            }
        case .card(.setup), .design(.custom):
            if let letter = Self.letter(spec) {
                CustomSetupWidget(family: family, letter: letter, style: style)
            } else {
                WidgetStateCard(state: .setup, family: family, style: style)
            }
        case .card(let state):
            WidgetStateCard(state: state, family: family, style: style)
        case .inboxSmall:
            WidgetMessageCard(family: family, style: style, symbol: "tray.full", title: data.title ?? "Inbox",
                              line: data.unreadCount.map { $0 == 1 ? "1 unread" : "\($0) unread" } ?? "",
                              destination: YayaLink.openApp(.inbox))
        }
    }

    /// Small and Medium keep Join at the bottom: their strip sits in the top padding instead.
    static func compactFooter(_ family: Family) -> Bool { family == .small || family == .medium }

    static func letter(_ spec: WidgetKindSpec) -> String? {
        if case .custom(let letter) = spec.content { return letter }
        return nil
    }

    /// Meeting rows the widget shows (agenda pages, the Month day list), nil where it shows none.
    static func meetingRows(spec: WidgetKindSpec, family: Family, data: WidgetData, style: WidgetStyle, page: Int = 1) -> Int? {
        let reserve = data.state == .content && data.health.footer(at: data.now) != .none && !compactFooter(family)
            ? WidgetFooterView.reserve : 0
        switch resolve(spec: spec, family: family, data: data) {
        case .design(.agenda):
            let meetings = data.agendaMeetings
            guard family != .small else { return UpNextSmall.next(meetings, now: data.now) == nil ? 0 : 1 }
            if family == .medium { return AgendaWidget.mediumLines(meetings: meetings, now: data.now, style: style).filter(\.isMeeting).count }
            let pages = AgendaWidget.pages(family: family, meetings: meetings, now: data.now, style: style, reserve: reserve)
            guard !pages.isEmpty else { return 0 }
            return AgendaPaginator.meetingCount(pages[max(1, min(page, pages.count)) - 1])
        case .design(.month):
            guard let height = MonthWidget.listHeight(family) else { return nil }
            let lines = DayList.lines(day: data.selectedDay, now: data.now, meetings: data.meetings, style: style, height: height)
            return lines.filter(\.isMeeting).count
        case .design(.upNext):
            return UpNextSmall.next(data.meetings, now: data.now) == nil ? 0 : 1
        case .design(.day):
            // Blocks drawn (the slice on S / M, the whole day on L / XL / XLP; "+N" ones not counted).
            return DayTimelineWidget.drawnBlocks(dayModel(family: family, data: data, style: style, reserve: reserve)).count
        default:
            return nil
        }
    }

    /// The Day design's model for one entry, as `content` draws it.
    static func dayModel(family: Family, data: WidgetData, style: WidgetStyle, reserve: CGFloat) -> DayModel {
        DayTimelineWidget.layout(family: family, meetings: data.meetings, day: data.selectedDay, now: data.now,
                                 style: style, reserve: reserve).model
    }

    /// The meetings a (kind, family) draws at `data.now`: what TimelinePlan follows through time, so the
    /// timeline only plans moments that change this widget. Mirrors `content` above.
    static func shownMeetings(spec: WidgetKindSpec, family: Family, data: WidgetData, style: WidgetStyle,
                              page: Int = 1) -> ShownMeetings {
        var out = ShownMeetings()
        let now = data.now
        let reserve = data.state == .content && data.health.footer(at: now) != .none && !compactFooter(family)
            ? WidgetFooterView.reserve : 0
        func meetings(_ lines: [AgendaLine]) -> [WidgetMeeting] {
            lines.compactMap { line -> WidgetMeeting? in if case .meeting(let m) = line { return m } else { return nil } }
        }
        /// "x of y left": today's timed meetings still to finish.
        func summary(_ list: [WidgetMeeting]) -> [WidgetMeeting] {
            list.filter { !$0.allDay && $0.end > now && WidgetCalendar.current.isDate($0.start, inSameDayAs: now) }
        }
        /// The pager's "1 of 3" counts every upcoming meeting, shown or not.
        func upcoming(_ list: [WidgetMeeting]) -> [WidgetMeeting] { list.filter { $0.end > now } }
        switch resolve(spec: spec, family: family, data: data) {
        case .design(.agenda):
            let list = data.agendaMeetings
            switch family {
            case .small:
                out.card = UpNextSmall.next(list, now: now)
            case .medium:
                out.rows = meetings(AgendaWidget.mediumLines(meetings: list, now: now, style: style))
                if let next = list.first(where: { $0.end > now && !$0.allDay }) { out.rows.append(next) }
                out.ends = summary(list)
            case .large, .extraLarge, .extraLargePortrait:
                let pages = AgendaWidget.pages(family: family, meetings: list, now: now, style: style, reserve: reserve)
                if !pages.isEmpty { out.rows = pages[max(1, min(page, pages.count)) - 1].flatMap(meetings) }
                out.ends = upcoming(list)
            }
        case .design(.upNext):
            out.card = UpNextSmall.next(data.meetings, now: now)
            if family == .medium { out.rows = meetings(UpNextWidget.laterLines(meetings: data.meetings, now: now, style: style)) }
        case .design(.month):
            if let height = MonthWidget.listHeight(family) {
                out.rows = meetings(DayList.lines(day: data.selectedDay, now: now, meetings: data.meetings, style: style, height: height))
            }
        case .design(.combo):
            let pages = ComboWidget.agendaPages(data.agendaMeetings, now: now, style: style, height: ComboWidget.agendaHeight(family))
            if !pages.isEmpty { out.rows = meetings(pages[min(max(page, 1), pages.count) - 1]) }
            out.ends = upcoming(data.agendaMeetings)
        case .design(.day):
            // The one meeting drawn live (accent ring, Join): under way or starting within 30 min. The Day
            // plans its own moments (TimelinePlan.dayEntryDates); this feeds the settle entries.
            let model = dayModel(family: family, data: data, style: style, reserve: reserve)
            if let id = model.focusId, let m = data.meetings.first(where: { $0.id == id }) { out.rows = [m] }
        default:
            break
        }
        return out
    }

    /// Pages the pager offers (agenda, inbox, the combo's agenda; for the manifest), 0 where there is none.
    static func pageCount(spec: WidgetKindSpec, family: Family, data: WidgetData, style: WidgetStyle) -> Int {
        switch resolve(spec: spec, family: family, data: data) {
        case .design(.agenda):
            guard [.large, .extraLarge, .extraLargePortrait].contains(family) else { return 0 }
            let reserve = data.health.footer(at: data.now) != .none ? WidgetFooterView.reserve : 0
            return AgendaWidget.pages(family: family, meetings: data.agendaMeetings, now: data.now, style: style, reserve: reserve).count
        case .design(.inbox):
            return inboxPages(family: family, data: data, style: style).count
        case .design(.combo):
            return ComboWidget.agendaPages(data.agendaMeetings, now: data.now, style: style, height: ComboWidget.agendaHeight(family)).count
        default:
            return 0
        }
    }

    static func inboxPages(family: Family, data: WidgetData, style: WidgetStyle) -> [[[MailBlock]]] {
        InboxLayout.pages(data.mail, style: style, height: InboxWidget.listHeight(family),
                          columns: InboxWidget.columns(family), showBanners: family != .medium)
    }

    /// Mailboxes the Daily Digest draws (D-053), nil where it draws none.
    static func digestBoxes(spec: WidgetKindSpec, family: Family, data: WidgetData, style: WidgetStyle) -> Int? {
        guard resolve(spec: spec, family: family, data: data) == .design(.digest), let digest = data.digest else { return nil }
        return DigestWidget.shownBoxes(family: family, digest: digest, style: style)
    }

    /// Mail rows shown by inbox kinds on the page shown.
    static func mailRows(spec: WidgetKindSpec, family: Family, data: WidgetData, style: WidgetStyle, page: Int = 1) -> Int? {
        guard resolve(spec: spec, family: family, data: data) == .design(.inbox) else { return nil }
        let pages = inboxPages(family: family, data: data, style: style)
        guard !pages.isEmpty else { return 0 }
        return InboxLayout.rowCount(pages[min(max(page, 1), pages.count) - 1])
    }
}

/// Whole-card states in the widgets' own voice (the shape of the Custom "not set up yet" card).
struct WidgetStateCard: View {
    let state: WidgetCardState
    let family: Family
    let style: WidgetStyle

    var body: some View {
        let small = family == .small
        switch state {
        case .noSnapshot:
            WidgetMessageCard(family: family, style: style, symbol: "calendar.badge.plus",
                              title: small ? "Almost there" : "Open Yaya's Calendar to connect your calendars",
                              line: small ? "Open Yaya's Calendar to connect your calendars."
                                          : "Your meetings show up here a moment later.",
                              button: small ? nil : "Open Yaya's Calendar",
                              destination: YayaLink.openApp(.accounts), mark: true)
        case .noAccounts:
            WidgetMessageCard(family: family, style: style, symbol: "person.crop.circle.badge.plus",
                              title: small ? "No calendars yet" : "No calendars connected yet",
                              line: small ? "Connect a Google account." : "Connect a Google account and your meetings land here.",
                              button: small ? nil : "Connect an account",
                              destination: YayaLink.openApp(.accounts), mark: true)
        case .mailComingSoon:
            WidgetMessageCard(family: family, style: style, symbol: "tray.full",
                              title: MailOffCopy.widgetTitle,
                              line: small ? MailOffCopy.widgetLineSmall : MailOffCopy.widgetLine,
                              destination: YayaLink.openApp(.accounts))
        case .mailHelperOff:
            WidgetMessageCard(family: family, style: style, symbol: "envelope.badge",
                              title: small ? DigestCopy.offTitleSmall : DigestCopy.offTitle,
                              line: small ? DigestCopy.offLineSmall : DigestCopy.offLine,
                              destination: YayaLink.openApp(.widgets))
        case .noDigest:
            WidgetMessageCard(family: family, style: style, symbol: "newspaper",
                              title: DigestCopy.noneTitle,
                              line: small ? DigestCopy.noneLineSmall : DigestCopy.noneLine,
                              button: small ? nil : DigestCopy.noneButton,
                              destination: YayaLink.openDigest())
        case .setup, .content:
            WidgetMessageCard(family: family, style: style, symbol: "square.grid.2x2",
                              title: "Not set up yet", line: "Pick its calendars and look in Yaya's Calendar.",
                              button: small ? nil : "Set it up", destination: YayaLink.openApp(.widgets), mark: true)
        }
    }
}

/// What `KindView.shownMeetings` finds on a widget at one moment.
struct ShownMeetings: Equatable {
    /// Meeting rows and the Medium panel's next meeting: start, end and the Join countdown change them.
    var rows: [WidgetMeeting] = []
    /// The Up Next card (Small, and the left of Medium): its countdown, "Now", and it leaves 15 min after
    /// the start.
    var card: WidgetMeeting? = nil
    /// Meetings whose end changes the drawing even when they are not on screen: "x of y left" (Agenda
    /// Medium, XL, XL Portrait) and the pager's page count (Agenda Large and up, Agenda & Inbox).
    var ends: [WidgetMeeting] = []

    static func == (a: ShownMeetings, b: ShownMeetings) -> Bool {
        a.rows.map(\.id) == b.rows.map(\.id) && a.card?.id == b.card?.id && a.ends.map(\.id) == b.ends.map(\.id)
    }
}
