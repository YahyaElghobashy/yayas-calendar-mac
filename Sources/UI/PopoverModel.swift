import Foundation

/// The menu-bar popover's brain: the next-meeting card, Agenda | Inbox, account chips, and the
/// "synced N min ago" line. Everything comes through `Services` (fakes in renders and tests); the store
/// is local SQLite, so `load()` is synchronous and cheap enough to run on open and once a minute.
@MainActor
final class PopoverModel: ObservableObject {
    enum Tab: String, CaseIterable { case agenda, inbox }
    enum Phase: Equatable { case loading, ready, noAccounts, failed }

    struct Day: Identifiable, Equatable {
        var id: Date { day }
        let day: Date
        let events: [CalendarEvent]
    }

    /// The card: one meeting plus what to say about it.
    struct Card: Equatable {
        let event: CalendarEvent
        let live: Bool
        /// Live or starting within 30 min: highlighted, with the loud Join.
        let soon: Bool
        let canJoin: Bool
        let joinTitle: String
        /// "Today · 10:00 – 10:45 AM", "Tomorrow · 9:30 – 9:45 AM", "Wednesday 21 · …".
        let when: String
        /// Headless stand-in for the live `Text(date, style: .relative)` countdown: "Starts in 12 min".
        let countdown: String
    }

    /// The agenda reaches a week ahead (today + 6): enough to scroll, light on the store.
    static let horizonDays = 7
    static let threadLimit = 50

    @Published private(set) var tab: Tab = .agenda
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var mailPhase: Phase = .loading
    @Published private(set) var days: [Day] = []
    @Published private(set) var threads: [MailThread] = []
    /// Accounts shown; empty = all of them.
    @Published private(set) var filter: Set<UUID> = []
    @Published private(set) var accounts: [DirectoryAccount] = []
    @Published private(set) var card: Card?
    @Published private(set) var now: Date
    @Published private(set) var syncedAt: Date?
    @Published private(set) var unread = 0
    @Published private(set) var syncing = false

    private let store: () -> CalendarStore
    private let actions: () -> CalendarActions
    private let mail: () -> MailStore
    private let directory: () -> AccountDirectory
    private let clock: () -> Date
    let mailEnabled: () -> Bool
    private let lastSync: () -> Date?
    private let clock24: () -> Bool

    init(store: @escaping () -> CalendarStore = { Services.calendar },
         actions: @escaping () -> CalendarActions = { Services.calendarActions },
         mail: @escaping () -> MailStore = { Services.mail },
         directory: @escaping () -> AccountDirectory = { AccountDirectory.current() },
         clock: @escaping () -> Date = { Date() },
         mailEnabled: @escaping () -> Bool = { true },
         syncedAt: @escaping () -> Date? = { WidgetSnapshot.read(kind: WidgetKinds.agenda.kind)?.health.syncedAt },
         use24Hour: @escaping () -> Bool = { Services.widgetSettings.settings(kind: WidgetKinds.agenda.kind).style.use24Hour }) {
        self.store = store
        self.actions = actions
        self.mail = mail
        self.directory = directory
        self.clock = clock
        self.mailEnabled = mailEnabled
        self.lastSync = syncedAt
        self.clock24 = use24Hour
        now = clock()
    }

    var showsInbox: Bool { mailEnabled() }
    var use24Hour: Bool { clock24() }
    var accountDirectory: AccountDirectory { AccountDirectory(accounts: accounts) }
    var eventCount: Int { days.reduce(0) { $0 + $1.events.count } }

    /// Chips list the accounts the current tab can show (calendar-on for Agenda, mail-on for Inbox).
    var chipAccounts: [DirectoryAccount] {
        tab == .inbox ? accounts.filter(\.mailEnabled) : accounts.filter(\.calendarEnabled)
    }

    func select(_ tab: Tab) {
        guard tab != .inbox || showsInbox else { return }
        self.tab = tab
    }

    func load() {
        now = clock()
        syncedAt = lastSync()
        accounts = directory().accounts
        if tab == .inbox, !showsInbox { tab = .agenda }
        filter = filter.filter { id in accounts.contains { $0.id == id } }
        loadAgenda()
        loadMail()
    }

    private func loadAgenda() {
        let calendarAccounts = accounts.filter(\.calendarEnabled)
        guard !calendarAccounts.isEmpty else {
            days = []
            card = nil
            phase = .noAccounts
            return
        }
        let cal = WidgetCalendar.current
        let today = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: Self.horizonDays, to: today) ?? today.addingTimeInterval(Double(Self.horizonDays) * 86_400)
        let shown = filter.isEmpty ? nil : filter
        do {
            // What's left: anything that hasn't ended (all-day events of today stay until midnight).
            let events = try store().events(from: now, to: end, accounts: shown).filter { $0.end > now }
            let grouped = Dictionary(grouping: events) { cal.startOfDay(for: max($0.start, today)) }
            days = grouped.keys.sorted().map { day in
                Day(day: day, events: grouped[day]!.sorted { ($0.allDay ? 0 : 1, $0.start, $0.r) < ($1.allDay ? 0 : 1, $1.start, $1.r) })
            }
            card = MeetingFocus.pick(events, now: now).map(makeCard)
            phase = .ready
        } catch {
            days = []
            card = nil
            phase = .failed
        }
    }

    private func loadMail() {
        guard showsInbox else {
            threads = []
            unread = 0
            mailPhase = .ready
            return
        }
        let mailAccounts = accounts.filter(\.mailEnabled)
        guard !mailAccounts.isEmpty else {
            threads = []
            unread = 0
            mailPhase = .noAccounts
            return
        }
        let ids = Set(mailAccounts.map(\.id))
        let shown = filter.isEmpty ? ids : filter.intersection(ids)
        do {
            threads = shown.isEmpty ? [] : try mail().threads(accounts: shown, limit: Self.threadLimit)
            unread = shown.isEmpty ? 0 : try mail().unreadCount(accounts: shown)
            mailPhase = .ready
        } catch {
            threads = []
            mailPhase = .failed
        }
    }

    func makeCard(_ e: CalendarEvent) -> Card {
        let live = MeetingFocus.isLive(e, now: now)
        let canJoin = JoinPolicy.isAllowed(e.joinURL)
        return Card(event: e, live: live, soon: MeetingFocus.isSoon(e, now: now), canJoin: canJoin,
                    joinTitle: JoinPolicy.providerName(e.joinURL).map { "Join \($0)" } ?? "Join meeting",
                    when: Self.when(e, now: now, use24Hour: use24Hour),
                    countdown: Self.countdown(e, now: now))
    }

    // MARK: Filter

    func toggle(_ id: UUID) {
        if filter.contains(id) { filter.remove(id) } else { filter.insert(id) }
        if !filter.isEmpty, chipAccounts.allSatisfy({ filter.contains($0.id) }) { filter = [] }   // every chip on = "All"
        load()
    }

    func showAll() {
        filter = []
        load()
    }

    func isOn(_ id: UUID) -> Bool { !filter.isEmpty && filter.contains(id) }

    // MARK: Footer

    /// "Synced 3 min ago" / "Not synced yet".
    var syncedText: String {
        if accounts.isEmpty { return "No accounts yet" }
        guard let syncedAt else { return "Not synced yet" }
        let ago = SyncText.ago(syncedAt, now: now)
        return ago == "just now" ? "Synced just now" : "Synced \(ago)"
    }

    func syncNow() async {
        guard !syncing else { return }
        syncing = true
        await actions().syncNow()
        syncing = false
        load()
    }

    // MARK: Text

    /// "Today · 10:00 – 10:45 AM"; all-day: "Today · All day".
    static func when(_ e: CalendarEvent, now: Date, use24Hour: Bool) -> String {
        let day = DayName.title(e.start < now ? now : e.start, now: now)
        let dayText = (day == "Today" || day == "Tomorrow") ? day : DayName.format("EEEE d", e.start)
        if e.allDay { return "\(dayText) · All day" }
        var style = WidgetStyle()
        style.use24Hour = use24Hour
        let row = WidgetMeeting(id: 0, account: WidgetAccount(id: "", short: "", name: "", logo: nil), title: "",
                                start: e.start, end: e.end, place: nil, hasLink: false)
        return "\(dayText) · \(WidgetClock.range(row, style))"
    }

    /// "Starts in 12 min" / "Ends in 40 min" / "Starts in 2 h 5 min" (rounded up like the widget).
    static func countdown(_ e: CalendarEvent, now: Date) -> String {
        if e.allDay { return "All day" }
        if MeetingFocus.isLive(e, now: now) {
            return "Ends " + WidgetClock.until(e.end, from: now)
        }
        let minutes = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes >= 24 * 60 {
            let day = DayName.title(e.start, now: now)
            return day == "Tomorrow" ? "Starts tomorrow" : "Starts \(day)"
        }
        return "Starts " + WidgetClock.until(e.start, from: now)
    }
}

/// Where the popover and the Peeks it opens go (AppKit coordinates, origin bottom-left).
enum PopoverPlacement {
    static let gap: CGFloat = 5
    static let margin: CGFloat = 8

    /// Centred under the status item, inside the screen's visible frame (menu bar and Dock excluded).
    /// No anchor (status item hidden): the top-right corner.
    static func frame(size: CGSize, anchor: CGRect?, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width - margin * 2)
        let height = min(size.height, visible.height - margin * 2)
        guard let anchor else {
            return CGRect(x: visible.maxX - margin - width, y: visible.maxY - margin - height, width: width, height: height)
        }
        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - margin - width)
        var y = min(anchor.minY, visible.maxY) - gap - height
        y = max(y, visible.minY + margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The anchor to hand `PeekPlacement` so a Peek sits left of the popover (right when the left has
    /// no room), its top a little above the row that was clicked.
    static func peekAnchor(popover: CGRect, pointer: CGPoint, visible: CGRect,
                           peekWidth: CGFloat = PeekPlacement.width) -> CGPoint {
        let offset = PeekPlacement.offset, m = PeekPlacement.margin
        let top = min(pointer.y + 30, popover.maxY) + offset
        let leftX = popover.minX - margin - peekWidth - offset
        if leftX + offset >= visible.minX + m { return CGPoint(x: leftX, y: top) }
        return CGPoint(x: popover.maxX + margin - offset, y: top)
    }
}
