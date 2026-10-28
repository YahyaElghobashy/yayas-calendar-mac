import AppKit
import SwiftUI

/// Where a Peek panel goes (AppKit coordinates: origin bottom-left). Its top-left corner sits just right
/// of and below the pointer; it flips left or upwards when it would leave the screen, then is clamped
/// inside that screen's visible frame (menu bar and Dock excluded) with an 8 pt margin.
enum PeekPlacement {
    static let width: CGFloat = 420
    static let maxHeight: CGFloat = 560
    static let margin: CGFloat = 8
    static let offset: CGFloat = 10

    static func frame(size: CGSize, anchor: CGPoint, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width - margin * 2)
        let height = min(size.height, maxHeight, visible.height - margin * 2)
        var x = anchor.x + offset
        if x + width > visible.maxX - margin { x = anchor.x - offset - width }
        var y = anchor.y - offset - height
        if y < visible.minY + margin { y = anchor.y + offset }
        x = min(max(x, visible.minX + margin), visible.maxX - margin - width)
        y = min(max(y, visible.minY + margin), visible.maxY - margin - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Text the Peeks show, kept here so tests can check it.
enum PeekText {
    static func when(_ e: CalendarEvent, calendar: Calendar = WidgetCalendar.current) -> String {
        let day = DayName.format("EEEE d MMMM", e.start)
        if e.allDay {
            let last = e.end.addingTimeInterval(-1)
            if calendar.isDate(e.start, inSameDayAs: last) { return "\(day) · All day" }
            return "\(DayName.format("EEE d MMM", e.start)) – \(DayName.format("EEE d MMM", last)) · All day"
        }
        let style = WidgetStyle()
        let range = WidgetClock.range(WidgetMeeting(id: 0, account: WidgetAccount(id: "", short: "", name: "", logo: nil),
                                                    title: "", start: e.start, end: e.end, place: nil, hasLink: false), style)
        if !calendar.isDate(e.start, inSameDayAs: e.end.addingTimeInterval(-1)) {
            return "\(day) · \(range) (ends \(DayName.format("EEE d", e.end)))"
        }
        return "\(day) · \(range)"
    }

    static func responseWord(_ r: CalendarEvent.Response) -> String {
        switch r {
        case .accepted: return "Going"
        case .tentative: return "Maybe"
        case .declined: return "Not going"
        case .needsAction: return "Not answered yet"
        }
    }

    /// The first lines of the description: at most `lines` non-empty lines and 600 characters.
    static func notesPreview(_ notes: String?, lines: Int = 6) -> String? {
        guard let notes else { return nil }
        let kept = notes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !kept.isEmpty else { return nil }
        var text = kept.prefix(lines).joined(separator: "\n")
        if text.count > 600 { text = String(text.prefix(600)) + "…" }
        else if kept.count > lines { text += "\n…" }
        return text
    }
}

/// The Event Peek's brain: one event, the user's reply (optimistic), Join and "Open in Google Calendar".
@MainActor
final class EventPeekModel: ObservableObject {
    @Published private(set) var event: CalendarEvent
    @Published private(set) var response: CalendarEvent.Response
    /// The reply being sent (its button shows a spinner-free "Sending…" state).
    @Published private(set) var sending: CalendarEvent.Response?
    @Published var toast: String?

    let directory: AccountDirectory
    private let actions: CalendarActions
    private let open: (URL) -> Bool
    var onClose: () -> Void = {}
    /// Day Peek → Event Peek: "‹ Back to Tuesday".
    var onBack: (() -> Void)?
    var backTitle: String?

    static let guestLimit = 8

    init(event: CalendarEvent, directory: AccountDirectory, actions: CalendarActions = Services.calendarActions,
         open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.event = event
        self.response = event.myResponse
        self.directory = directory
        self.actions = actions
        self.open = open
    }

    var isOrganizer: Bool {
        event.organizer?.isSelf == true || event.attendees.contains { $0.isSelf && $0.isOrganizer }
    }

    /// Replies make sense for invitations: there are guests, I'm one of them, and I didn't organise it.
    var canReply: Bool { !isOrganizer && event.attendees.contains { $0.isSelf } }

    var guests: [CalendarEvent.Attendee] { event.attendees.filter { !$0.isSelf } }
    var guestsShown: [CalendarEvent.Attendee] { Array(guests.prefix(Self.guestLimit)) }
    var moreGuests: Int { max(0, guests.count - Self.guestLimit) }

    /// "Also on: FAM" for merged invites (the other accounts; the primary is already in the header).
    var alsoOn: String? {
        guard event.accountIds.count > 1 else { return nil }
        let label = directory.label(Array(event.accountIds.dropFirst()))
        return label.isEmpty ? nil : "Also on: \(label)"
    }

    var joinProvider: String? { JoinPolicy.providerName(event.joinURL) }
    var canJoin: Bool { JoinPolicy.isAllowed(event.joinURL) }

    func rsvp(_ choice: CalendarEvent.Response) async {
        guard choice != response, sending == nil, canReply else { return }
        let previous = response
        response = choice
        sending = choice
        toast = nil
        do {
            try await actions.rsvp(r: event.r, response: choice)
            event.myResponse = choice
            sending = nil
            Trace.app("peek-rsvp", ["result": "ok", "v": choice.rawValue])
        } catch {
            response = previous
            sending = nil
            show(toast: "I couldn\u{2019}t send your reply. Check your connection and try again.")
            Trace.app("peek-rsvp", ["result": "error", "v": choice.rawValue])
        }
    }

    /// Toasts clear themselves after 5 s (a tap clears them sooner).
    private func show(toast text: String) {
        toast = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }

    @discardableResult
    func join() -> Bool {
        guard canJoin, let url = event.joinURL else {
            show(toast: "That meeting link doesn\u{2019}t look right, so I didn\u{2019}t open it.")
            return false
        }
        let ok = open(url)
        Trace.app("peek-join", ["result": ok ? "opened" : "failed"])
        if ok { onClose() }
        return ok
    }

    @discardableResult
    func openInGoogle() -> Bool {
        guard let url = event.webURL, url.scheme?.lowercased() == "https" else { return false }
        let ok = open(url)
        if ok { onClose() }
        return ok
    }
}

/// The Day Peek: one day's meetings for one widget's accounts (Small Month tap).
@MainActor
final class DayPeekModel: ObservableObject {
    let kind: String
    let day: Date
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var failed = false
    let directory: AccountDirectory
    let now: Date

    init(kind: String, day: Date, directory: AccountDirectory, store: CalendarStore = Services.calendar,
         settings: WidgetSettingsStore = Services.widgetSettings, now: Date = Date()) {
        self.kind = kind
        self.day = day
        self.directory = directory
        self.now = now
        let cal = WidgetCalendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let accounts = settings.settings(kind: kind).accountIds.map(Set.init)
        do {
            events = try store.events(from: start, to: end, accounts: accounts)
        } catch {
            failed = true
        }
    }

    var title: String { DayName.title(day, now: now) == "Today" ? "Today" : DayName.format("EEEE", day) }
    var subtitle: String { DayName.format("d MMMM", day) }
    var countText: String {
        let n = events.filter { !$0.allDay }.count
        return n == 0 ? "Nothing booked" : (n == 1 ? "1 meeting" : "\(n) meetings")
    }

    func rows() -> [WidgetMeeting] {
        events.enumerated().map { $0.element.widgetMeeting(index: $0.offset + 1, directory: directory) }
    }
}
