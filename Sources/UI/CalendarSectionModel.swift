import Foundation

/// The Calendar section: one agenda from today to +60 days across the accounts the user filters to.
final class CalendarSectionModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, noAccounts, failed }

    struct Day: Identifiable, Equatable {
        var id: Date { day }
        let day: Date
        let events: [CalendarEvent]
    }

    static let horizonDays = 60

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var days: [Day] = []
    /// Accounts shown; empty = all of them.
    @Published private(set) var filter: Set<UUID> = []
    @Published private(set) var syncing = false
    @Published private(set) var now: Date
    @Published private(set) var accounts: [DirectoryAccount] = []

    private let store: () -> CalendarStore
    private let actions: () -> CalendarActions
    private let directory: () -> AccountDirectory
    private let clock: () -> Date

    init(store: @escaping () -> CalendarStore = { Services.calendar },
         actions: @escaping () -> CalendarActions = { Services.calendarActions },
         directory: @escaping () -> AccountDirectory = { AccountDirectory.current() },
         clock: @escaping () -> Date = { Date() }) {
        self.store = store
        self.actions = actions
        self.directory = directory
        self.clock = clock
        now = clock()
    }

    var eventCount: Int { days.reduce(0) { $0 + $1.events.count } }
    var accountDirectory: AccountDirectory { AccountDirectory(accounts: accounts) }

    func load() {
        now = clock()
        accounts = directory().accounts.filter(\.calendarEnabled)
        guard !accounts.isEmpty else {
            days = []
            phase = .noAccounts
            return
        }
        filter = filter.filter { id in accounts.contains { $0.id == id } }
        let cal = WidgetCalendar.current
        let today = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: Self.horizonDays + 1, to: today) ?? today.addingTimeInterval(61 * 86_400)
        do {
            let events = try store().events(from: today, to: end, accounts: filter.isEmpty ? nil : filter)
            let grouped = Dictionary(grouping: events) { cal.startOfDay(for: max($0.start, today)) }
            days = grouped.keys.sorted().map { day in
                Day(day: day, events: grouped[day]!.sorted { ($0.allDay ? 0 : 1, $0.start, $0.r) < ($1.allDay ? 0 : 1, $1.start, $1.r) })
            }
            phase = .ready
        } catch {
            days = []
            phase = .failed
        }
    }

    func toggle(_ id: UUID) {
        if filter.contains(id) { filter.remove(id) } else { filter.insert(id) }
        if filter.count == accounts.count { filter = [] }   // every chip on = "All"
        load()
    }

    func showAll() {
        filter = []
        load()
    }

    func isShown(_ id: UUID) -> Bool { filter.isEmpty || filter.contains(id) }

    @MainActor
    func syncNow() async {
        guard !syncing else { return }
        syncing = true
        await actions().syncNow()
        syncing = false
        load()
    }
}
