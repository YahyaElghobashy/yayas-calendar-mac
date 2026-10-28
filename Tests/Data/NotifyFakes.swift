import Foundation

// Fakes for the notification + Deck export tests. Nothing here posts a real notification, touches
// UserDefaults or DistributedNotificationCenter.

/// Stands in for UNUserNotificationCenter: pending requests survive "restarts" (a new coordinator over
/// the same fake), notes without a trigger are delivered at once, `fire(until:)` plays the system clock.
final class FakeNoteCenter: NoteCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingById: [String: LocalNote] = [:]
    private(set) var delivered: [LocalNote] = []
    private(set) var added: [LocalNote] = []
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []
    private(set) var authorizations = 0
    var failAdds = false
    /// Permission as the system reports it (default: granted earlier, like a returning user).
    var state: NoteAuth = .authorized
    /// What the user answers when prompted.
    var answer = true
    /// The prompt sits unanswered (the call doesn't return for a minute).
    var promptIgnored = false
    /// The system doesn't answer the pending-requests read.
    var pendingUnavailable = false
    /// The status read takes this long (a snooze can arrive meanwhile).
    var statusDelay: TimeInterval = 0
    private(set) var statusReads = 0

    func authorizationStatus() async -> NoteAuth {
        let delay: TimeInterval = { lock.lock(); defer { lock.unlock() }; statusReads += 1; return statusDelay }()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// False: the prompt goes away without a decision (status stays undetermined).
    var answerDecides = true

    func authorize() async -> Bool {
        let ignored: Bool = { lock.lock(); defer { lock.unlock() }; authorizations += 1; return promptIgnored }()
        if ignored { try? await Task.sleep(nanoseconds: 60_000_000_000) }
        lock.lock(); defer { lock.unlock() }
        if answerDecides { state = answer ? .authorized : .denied }
        return answerDecides && answer
    }

    func pending() async -> [PendingNote]? {
        lock.lock(); defer { lock.unlock() }
        if pendingUnavailable { return nil }
        return pendingById.values.sorted { $0.id < $1.id }.map {
            PendingNote(id: $0.id, fingerprint: $0.fingerprint, fireAt: $0.fireAt)
        }
    }

    func add(_ note: LocalNote) async throws {
        lock.lock(); defer { lock.unlock() }
        if failAdds { throw ServiceError(description: "add failed") }
        added.append(note)
        if note.trigger == nil { delivered.append(note) } else { pendingById[note.id] = note }
    }

    func removePending(_ ids: [String]) async {
        lock.lock(); defer { lock.unlock() }
        for id in ids { pendingById[id] = nil }
        removedPending += ids
    }

    func removeDelivered(_ ids: [String]) async {
        lock.lock(); defer { lock.unlock() }
        delivered.removeAll { ids.contains($0.id) }
        removedDelivered += ids
    }

    /// The system fires every pending request due by `date`.
    func fire(until date: Date) {
        lock.lock(); defer { lock.unlock() }
        for (id, note) in pendingById where (note.fireAt ?? .distantPast) <= date {
            delivered.append(note)
            pendingById[id] = nil
        }
    }

    var pendingIds: [String] { lock.lock(); defer { lock.unlock() }; return pendingById.keys.sorted() }
    func pendingNote(_ id: String) -> LocalNote? { lock.lock(); defer { lock.unlock() }; return pendingById[id] }

    func clearLog() {
        lock.lock(); defer { lock.unlock() }
        added = []
        removedPending = []
        removedDelivered = []
    }
}

final class MemoryNotifyPrefs: NotifyPrefs, @unchecked Sendable {
    private let lock = NSLock()
    private var reauth: [UUID: Date] = [:]
    private var seen: [UUID: Date] = [:]
    private var _meetings = true
    private var _newMail = false
    private var _paused: Date?

    var meetingsOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _meetings }
        set { lock.lock(); _meetings = newValue; lock.unlock() }
    }

    var newMailOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _newMail }
        set { lock.lock(); _newMail = newValue; lock.unlock() }
    }

    var pausedUntil: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }

    func reauthSentAt(_ account: UUID) -> Date? { lock.lock(); defer { lock.unlock() }; return reauth[account] }
    func setReauthSent(_ account: UUID, at date: Date) { lock.lock(); reauth[account] = date; lock.unlock() }
    func clearReauthSent(_ account: UUID) { lock.lock(); reauth[account] = nil; lock.unlock() }
    func reauthStamped() -> [UUID] { lock.lock(); defer { lock.unlock() }; return Array(reauth.keys) }
    func mailSeen(_ account: UUID) -> Date? { lock.lock(); defer { lock.unlock() }; return seen[account] }
    func setMailSeen(_ account: UUID, _ date: Date) { lock.lock(); seen[account] = date; lock.unlock() }
}

final class FakeDeckPoster: DeckChangePoster, @unchecked Sendable {
    let posts = Locked(0)
    func post() { posts.value += 1 }
}

/// A data source the test controls (not ready, failing reads, fixed rows).
final class StubNotifyData: NotifyDataSource, @unchecked Sendable {
    let ready = Locked(true)
    let failing = Locked(false)
    let rows = Locked<[CalendarEvent]>([])
    let people = Locked<[AccountRecord]>([])

    var isReady: Bool { ready.value }

    func events(from: Date, to: Date) throws -> [CalendarEvent] {
        if failing.value { throw ServiceError(description: "read failed") }
        return rows.value.filter { $0.start < to && max($0.end, $0.start.addingTimeInterval(1)) > from }
    }

    func event(r: String) throws -> CalendarEvent? {
        if failing.value { throw ServiceError(description: "read failed") }
        return rows.value.first { $0.r == r }
    }

    func accounts() throws -> [AccountRecord] {
        if failing.value { throw ServiceError(description: "read failed") }
        return people.value
    }

    func inbox(account: UUID, limit: Int) throws -> [MailThread] { [] }
}

/// Builders for `CalendarEvent`s and accounts used by the pure planner tests.
enum N {
    static let posix = Locale(identifier: "en_US_POSIX")

    static func person(_ email: String, _ response: CalendarEvent.Response = .accepted, me: Bool = false,
                       organizer: Bool = false, name: String? = nil) -> CalendarEvent.Attendee {
        CalendarEvent.Attendee(name: name, email: email, response: response, isSelf: me, isOrganizer: organizer)
    }

    static func event(_ r: String, _ title: String = "Sync", start: Date, minutes: Double = 30, join: String? = nil,
                      people: [CalendarEvent.Attendee] = [], organizer: CalendarEvent.Attendee? = nil,
                      response: CalendarEvent.Response = .accepted, allDay: Bool = false,
                      accounts: [UUID] = []) -> CalendarEvent {
        CalendarEvent(r: r, accountIds: accounts, calendarName: "", title: title, start: start,
                      end: start.addingTimeInterval(minutes * 60), allDay: allDay, location: nil,
                      joinURL: join.flatMap(URL.init(string:)), webURL: nil, notes: nil, organizer: organizer,
                      attendees: people, myResponse: response, clashes: false)
    }

    static func account(_ email: String, tag: String, sort: Int = 0, health: HealthState = .ok) -> AccountRecord {
        AccountRecord(id: UUID(), provider: "google", email: email, displayName: tag, tag: tag, color: 0x3CCBB4, logoFile: nil,
                      sortOrder: sort, health: health, createdAt: Date(timeIntervalSince1970: 1_000 + Double(sort)))
    }

    static func context(now: Date = TestCal.labNow, meetingsOn: Bool = true, pausedUntil: Date? = nil,
                        tags: [UUID: String] = [:], calendar: Calendar = TestCal.lab) -> HeadsUp.Context {
        HeadsUp.Context(now: now, calendar: calendar, locale: posix, meetingsOn: meetingsOn, pausedUntil: pausedUntil, tags: tags)
    }

    static func thread(_ account: UUID, _ id: String, sender: String, email: String? = nil, subject: String = "Hello",
                       at: Date, unread: Bool = true) -> MailThreadRecord {
        MailThreadRecord(r: MailIds.threadR(accountId: account, threadId: id), accountId: account, threadId: id, historyId: "1",
                         subject: subject, senderName: sender, senderEmail: email ?? "\(id)@example.com", snippet: "",
                         lastAt: at, unread: unread, starred: false, inInbox: true, categoryPrimary: true, messageCount: 1,
                         lastMessageIdHeader: nil, labels: ["INBOX"], messageIds: ["m-\(id)"])
    }
}
