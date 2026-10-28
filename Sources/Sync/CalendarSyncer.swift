import Foundation

/// One account's calendar sync pass (D-015).
///
/// 1. The calendar list, at most every 15 minutes (or when forced): Google's own "selected" set.
/// 2. Per selected calendar, the change feed (`syncToken`, ids only). No token yet → fetch one; 410 →
///    reset and fetch a new one. Either way, or when the feed reports any change, the window is due.
/// 3. The window is also due every 15 minutes, after midnight, on first sync and when forced. It is
///    listed in full (`singleEvents`, `orderBy=startTime`, all pages) and replaces that calendar's rows
///    in one transaction: upsert on (account, calendar, event id), delete what the list no longer has.
///    The new feed token is stored in the same transaction, so a failed list never skips a change.
final class CalendarSyncer: @unchecked Sendable {
    struct Report: Equatable, Sendable {
        var calendars = 0
        var listed = 0
        var feedChanges = 0
        var resets = 0
        var upserted = 0
        var deleted = 0
        /// Calendars skipped this pass (gone, forbidden): calendar index → short code.
        var skipped: [String] = []
    }

    let db: AppDatabase
    let now: @Sendable () -> Date
    let calendar: @Sendable () -> Calendar
    var relistInterval: TimeInterval = 15 * 60
    var calendarListInterval: TimeInterval = 15 * 60

    private let lock = NSLock()
    private var lastCalendarList: [UUID: Date] = [:]

    init(db: AppDatabase, now: @escaping @Sendable () -> Date, calendar: @escaping @Sendable () -> Calendar) {
        self.db = db
        self.now = now
        self.calendar = calendar
    }

    func sync(accountId: UUID, client: GoogleCalendarClient, force: Bool) async throws -> Report {
        var report = Report()
        let calendars = CalendarRepo(db: db)
        let known = try calendars.all(accountId: accountId)
        if force || calendarListDue(accountId) || known.isEmpty {
            let list = try await client.calendarList()
            // Every account has at least its primary calendar: an empty list is a hiccup, not a reason
            // to drop every calendar and event.
            guard !list.isEmpty else { throw GoogleAPIError.undecodable }
            let records = list.filter { !($0.deleted ?? false) }.map {
                CalendarRecord(accountId: accountId, calendarId: $0.id, summary: $0.displayName,
                               selected: $0.includedByDefault, color: $0.color, accessRole: $0.accessRole ?? "reader")
            }
            try calendars.replace(accountId: accountId, with: records)
            setCalendarListed(accountId, now())
        }
        let window = SyncWindow.current(now: now(), calendar: calendar())
        for (index, cal) in try calendars.selected(accountId: accountId).enumerated() {
            report.calendars += 1
            do {
                let one = try await syncCalendar(accountId: accountId, calendarId: cal.calendarId, client: client,
                                                 window: window, force: force)
                report.listed += one.listed ? 1 : 0
                report.feedChanges += one.changes
                report.resets += one.reset ? 1 : 0
                report.upserted += one.upserted
                report.deleted += one.deleted
            } catch let error as GoogleAPIError {
                switch error {
                case .forbidden where error.isServiceDisabled:
                    // The Calendar API is off in the user's project: every calendar would fail the same
                    // way, so the pass fails and the account says so (never a silent skip).
                    throw error
                case .notFound, .forbidden, .badRequest:
                    // One calendar went away or lost access: skip it and re-read the list next pass.
                    report.skipped.append("\(index):\(error.code)")
                    setCalendarListed(accountId, nil)
                default:
                    throw error
                }
            }
        }
        return report
    }

    struct CalendarReport: Equatable, Sendable {
        var listed = false
        var changes = 0
        var reset = false
        var upserted = 0
        var deleted = 0
    }

    func syncCalendar(accountId: UUID, calendarId: String, client: GoogleCalendarClient, window: SyncWindow,
                      force: Bool) async throws -> CalendarReport {
        let states = SyncStateRepo(db: db)
        let state = try states.get(accountId: accountId, calendarId: calendarId)
        var report = CalendarReport()
        var due = force || listDue(state.lastListAt)

        let feed: ChangeFeed
        do {
            feed = try await client.changeFeed(calendarId: calendarId, syncToken: state.syncToken)
        } catch GoogleAPIError.gone {
            report.reset = true
            try states.setToken(nil, accountId: accountId, calendarId: calendarId)
            feed = try await client.changeFeed(calendarId: calendarId, syncToken: nil)
        }
        report.changes = feed.changedIds.count
        if feed.initial || !feed.changedIds.isEmpty { due = true }

        guard due else {
            if feed.nextSyncToken != state.syncToken {
                try states.setToken(feed.nextSyncToken, accountId: accountId, calendarId: calendarId)
            }
            return report
        }

        let items = try await client.listWindow(calendarId: calendarId, timeMin: window.start, timeMax: window.end)
        let cal = calendar()
        var records: [EventRecord] = []
        var cancelled = Set<String>()
        for item in items {
            switch GoogleEventMapper.map(item, accountId: accountId, calendarId: calendarId, calendar: cal) {
            case .event(let record): records.append(record)
            case .cancelled(let id): cancelled.insert(id)
            case .skipped: break
            }
        }
        let listedAt = now()
        let result = try EventRepo(db: db).replaceCalendar(accountId: accountId, calendarId: calendarId,
                                                           with: records, cancelled: cancelled) {
            try states.setToken(feed.nextSyncToken, accountId: accountId, calendarId: calendarId)
            try states.setListed(listedAt, accountId: accountId, calendarId: calendarId)
        }
        report.listed = true
        report.upserted = result.upserted
        report.deleted = result.deleted
        return report
    }

    /// The window is re-listed every `relistInterval`, and on the first pass after midnight.
    func listDue(_ last: Date?) -> Bool {
        guard let last else { return true }
        let current = now()
        if current.timeIntervalSince(last) >= relistInterval { return true }
        return last < calendar().startOfDay(for: current)
    }

    func forgetCalendarList(_ accountId: UUID) { setCalendarListed(accountId, nil) }

    private func calendarListDue(_ accountId: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastCalendarList[accountId] else { return true }
        return now().timeIntervalSince(last) >= calendarListInterval
    }

    private func setCalendarListed(_ accountId: UUID, _ date: Date?) {
        lock.lock(); lastCalendarList[accountId] = date; lock.unlock()
    }
}
