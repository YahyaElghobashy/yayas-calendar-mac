import Foundation

// Fakes for the data tests. Nothing here touches the real Keychain, network, WidgetKit or
// ~/Library/Application Support.

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&storage) }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let date: Locked<Date>
    init(_ start: Date) { date = Locked(start) }
    var now: Date { date.value }
    func set(_ value: Date) { date.value = value }
    func advance(_ seconds: TimeInterval) { date.mutate { $0 = $0.addingTimeInterval(seconds) } }
    var closure: @Sendable () -> Date { { [self] in self.now } }
}

enum TestCal {
    /// The fixed test calendar (the widget's `WidgetCalendar.fixed`): London, Monday first.
    static var lab: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.firstWeekday = 2
        return c
    }

    static func iso(_ text: String) -> Date {
        guard let date = GoogleEventMapper.parseDateTime(text) else { fatalError("bad date \(text)") }
        return date
    }

    static func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        lab.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// The fixed "now": Monday 19 October 2026, 9:48 AM, London.
    static var labNow: Date { local(2026, 10, 19, 9, 48) }
}

final class FakeTokens: AccessTokenSource, @unchecked Sendable {
    let token: String
    let error = Locked<Error?>(nil)
    let calls = Locked(0)
    let forced = Locked(0)
    let invalidations = Locked(0)

    init(token: String) { self.token = token }

    func accessToken(forceRefresh: Bool) async throws -> String {
        calls.value += 1
        if forceRefresh { forced.value += 1 }
        if let error = error.value { throw error }
        return token
    }

    func invalidateAccessToken() async { invalidations.value += 1 }
}

/// Stands in for AccountsModel: tokens per account; "reauth" writes the account's health like
/// AccountsModel.update would.
final class FakeSource: SyncAccountsSource, @unchecked Sendable {
    let db: AppDatabase
    let tokens = Locked<[UUID: FakeTokens]>([:])
    let reauthMarked = Locked<[UUID]>([])

    init(db: AppDatabase) { self.db = db }

    func tokenSource(for accountId: UUID) async -> AccessTokenSource? { tokens.value[accountId] }

    func markReauthNeeded(_ accountId: UUID) async {
        reauthMarked.mutate { $0.append(accountId) }
        _ = try? AccountRepo(db: db).setHealth(accountId, .reauthNeeded, detail: "Sign in again")
    }

    /// "Turn on the … API" reports (D-038), in order.
    let apiReports = Locked<[(id: UUID, api: String, available: Bool)]>([])

    func apiAvailability(_ accountId: UUID, api: String, available: Bool) async {
        apiReports.mutate { $0.append((accountId, api, available)) }
    }
}

final class FakeReloader: TimelineReloader, @unchecked Sendable {
    let reloads = Locked<[String]>([])
    func reloadTimelines(ofKind kind: String) { reloads.mutate { $0.append(kind) } }
    func count(_ kind: String) -> Int { reloads.value.filter { $0 == kind }.count }
    func reset() { reloads.value = [] }
}

final class FakeLinkKeys: LinkKeyStore, @unchecked Sendable {
    let stored = Locked<Data?>(nil)
    let locked = Locked(false)
    let saves = Locked(0)

    func load() throws -> Data? {
        if locked.value { throw KeychainError.locked(-25308) }
        return stored.value
    }

    func save(_ key: Data) throws {
        if locked.value { throw KeychainError.locked(-25308) }
        saves.value += 1
        stored.value = key
    }
}

/// Google event JSON builders.
enum G {
    static func timed(_ id: String, _ title: String, _ start: String, _ end: String, uid: String? = nil,
                      recurring: String? = nil, original: String? = nil, attendees: [[String: Any]]? = nil,
                      organizer: [String: Any]? = nil, location: String? = nil, description: String? = nil,
                      hangout: String? = nil, video: [String]? = nil, transparency: String? = nil,
                      status: String = "confirmed", type: String? = nil) -> [String: Any] {
        var e: [String: Any] = ["id": id, "status": status, "summary": title, "iCalUID": uid ?? "\(id)@google.example",
                                "start": ["dateTime": start], "end": ["dateTime": end],
                                "htmlLink": "https://www.google.com/calendar/event?eid=\(id)",
                                "updated": "2026-10-18T10:00:00.000Z"]
        if let recurring { e["recurringEventId"] = recurring }
        if let original { e["originalStartTime"] = ["dateTime": original] }
        if let attendees { e["attendees"] = attendees }
        if let organizer { e["organizer"] = organizer }
        if let location { e["location"] = location }
        if let description { e["description"] = description }
        if let hangout { e["hangoutLink"] = hangout }
        if let video {
            e["conferenceData"] = ["entryPoints": video.map { ["entryPointType": "video", "uri": $0] }
                + [["entryPointType": "phone", "uri": "tel:+1-555-0100"]]]
        }
        if let transparency { e["transparency"] = transparency }
        if let type { e["eventType"] = type }
        return e
    }

    static func allDay(_ id: String, _ title: String, _ start: String, _ end: String, uid: String? = nil,
                       transparency: String? = "transparent") -> [String: Any] {
        var e: [String: Any] = ["id": id, "status": "confirmed", "summary": title, "iCalUID": uid ?? "\(id)@google.example",
                                "start": ["date": start], "end": ["date": end]]
        if let transparency { e["transparency"] = transparency }
        return e
    }

    static func me(_ email: String, _ response: String = "needsAction") -> [String: Any] {
        ["email": email, "self": true, "responseStatus": response]
    }

    static func guest(_ email: String, _ response: String = "accepted", organizer: Bool = false) -> [String: Any] {
        var a: [String: Any] = ["email": email, "responseStatus": response, "displayName": "Guest"]
        if organizer { a["organizer"] = true }
        return a
    }

    static func organizer(_ email: String, isSelf: Bool = false) -> [String: Any] {
        var o: [String: Any] = ["email": email]
        if isSelf { o["self"] = true }
        return o
    }

    static func decode(_ json: [String: Any]) -> GEvent {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GEvent.self, from: data)
    }
}

/// An in-memory Google Calendar API v3, routed by bearer token (one token per account). Implements the
/// parts the app uses: calendarList, events.list (window with singleEvents/orderBy, or the syncToken
/// feed; never both), events.get, events.patch with If-Match. Every request also passes the app's real
/// `HTTP.validate` policy check.
final class FakeGoogle: HTTPTransport, @unchecked Sendable {
    final class CalendarData {
        var entry: [String: Any]
        var events: [String: [String: Any]] = [:]
        var version = 1
        var changes: [(version: Int, id: String)] = []
        /// Tokens older than this answer 410.
        var minValidToken = 0
        init(entry: [String: Any]) { self.entry = entry }
    }

    struct Injected {
        var match: String
        var method: HTTPMethod?
        var status: Int
        var body: String
        var headers: [String: String]
        var remaining: Int
    }

    private let lock = NSLock()
    private var data: [String: (order: [String], calendars: [String: CalendarData])] = [:]
    private var injected: [Injected] = []
    private var log: [HTTPRequest] = []
    private var etagCounter = 1000
    var calendar = TestCal.lab
    var calendarListPageSize = 250
    var feedPageSize: Int?
    var forced412 = 0
    /// Window lists include cancelled occurrences (as Google does for some exceptions).
    var listCancelled = false

    // MARK: Setup

    func addCalendar(token: String, id: String, summary: String, selected: Bool? = true, accessRole: String = "owner",
                     hidden: Bool? = nil, primary: Bool = false, color: String? = "#9fe1e7") {
        lock.lock(); defer { lock.unlock() }
        var entry: [String: Any] = ["id": id, "summary": summary, "accessRole": accessRole]
        if let selected { entry["selected"] = selected }
        if let hidden { entry["hidden"] = hidden }
        if primary { entry["primary"] = true }
        if let color { entry["backgroundColor"] = color }
        var account = data[token] ?? ([], [:])
        if account.calendars[id] == nil { account.order.append(id) }
        account.calendars[id] = CalendarData(entry: entry)
        data[token] = account
    }

    func removeCalendar(token: String, id: String) {
        lock.lock(); defer { lock.unlock() }
        data[token]?.calendars[id] = nil
        data[token]?.order.removeAll { $0 == id }
    }

    func put(token: String, calendar id: String, _ event: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard let cal = data[token]?.calendars[id], let eventId = event["id"] as? String else { fatalError("no calendar \(id)") }
        var e = event
        etagCounter += 1
        e["etag"] = "\"\(etagCounter)\""
        cal.events[eventId] = e
        cal.version += 1
        cal.changes.append((cal.version, eventId))
    }

    /// Deleted on Google: gone from lists, reported by the feed.
    func remove(token: String, calendar id: String, eventId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let cal = data[token]?.calendars[id] else { return }
        cal.events[eventId] = nil
        cal.version += 1
        cal.changes.append((cal.version, eventId))
    }

    /// Cancelled on Google but never reported by the change feed (a feed hiccup, a token consumed by
    /// another pass): gone from window lists only. Only a full re-list notices.
    func vanish(token: String, calendar id: String, eventId: String) {
        lock.lock(); defer { lock.unlock() }
        data[token]?.calendars[id]?.events[eventId] = nil
    }

    /// Every token handed out so far now answers 410.
    func expireTokens(token: String, calendar id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let cal = data[token]?.calendars[id] else { return }
        cal.minValidToken = cal.version + 1
        cal.version += 1
    }

    func event(token: String, calendar id: String, eventId: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return data[token]?.calendars[id]?.events[eventId]
    }

    func inject(_ match: String, method: HTTPMethod? = nil, status: Int, body: String = "{}",
                headers: [String: String] = [:], times: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        injected.append(Injected(match: match, method: method, status: status, body: body, headers: headers, remaining: times))
    }

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return log }
    func clearLog() { lock.lock(); log.removeAll(); lock.unlock() }
    /// Drops every injected answer still waiting.
    func clearInjected() { lock.lock(); injected.removeAll(); lock.unlock() }

    // MARK: Transport

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try HTTP.validate(request.url)
        lock.lock(); defer { lock.unlock() }
        log.append(request)
        let text = request.url.absoluteString
        if let index = injected.firstIndex(where: { $0.remaining > 0 && text.contains($0.match)
            && ($0.method == nil || $0.method == request.method) }) {
            injected[index].remaining -= 1
            let hit = injected[index]
            return HTTPResponse(status: hit.status, headers: hit.headers, body: Data(hit.body.utf8))
        }
        guard let auth = request.headers["Authorization"], auth.hasPrefix("Bearer "),
              let account = data[String(auth.dropFirst(7))] else { return json(401, ["error": ["code": 401]]) }
        guard let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else { return json(400, [:]) }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let segments = parts.percentEncodedPath.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        // calendar / v3 / …
        guard segments.count >= 3, segments[0] == "calendar", segments[1] == "v3" else { return json(404, [:]) }
        let rest = Array(segments.dropFirst(2))

        if rest == ["users", "me", "calendarList"], request.method == .get {
            let offset = Int(query["pageToken"]?.dropFirst() ?? "0") ?? 0
            let all = account.order.compactMap { account.calendars[$0]?.entry }
            let page = Array(all.dropFirst(offset).prefix(calendarListPageSize))
            var body: [String: Any] = ["items": page]
            if offset + page.count < all.count { body["nextPageToken"] = "c\(offset + page.count)" }
            return json(200, body)
        }
        guard rest.count >= 3, rest[0] == "calendars", rest[2] == "events", let cal = account.calendars[rest[1]] else {
            return json(404, ["error": ["code": 404, "errors": [["reason": "notFound"]]]])
        }
        if rest.count == 3, request.method == .get { return list(cal, query) }
        guard rest.count == 4 else { return json(404, [:]) }
        let eventId = rest[3]
        guard var event = cal.events[eventId] else { return json(404, ["error": ["code": 404]]) }
        switch request.method {
        case .get:
            return json(200, event)
        case .patch:
            if forced412 > 0 {
                forced412 -= 1
                etagCounter += 1
                event["etag"] = "\"\(etagCounter)\""
                cal.events[eventId] = event
                return json(412, ["error": ["code": 412, "message": "Precondition Failed"]])
            }
            guard request.headers["If-Match"] == event["etag"] as? String else {
                return json(412, ["error": ["code": 412, "message": "Precondition Failed"]])
            }
            guard let body = request.body, let patch = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return json(400, [:])
            }
            for (key, value) in patch { event[key] = value }
            etagCounter += 1
            event["etag"] = "\"\(etagCounter)\""
            cal.events[eventId] = event
            cal.version += 1
            cal.changes.append((cal.version, eventId))
            return json(200, event)
        default:
            return json(405, [:])
        }
    }

    private func list(_ cal: CalendarData, _ query: [String: String]) -> HTTPResponse {
        if let token = query["syncToken"] {
            // Google: syncToken can't be combined with timeMin/timeMax/orderBy.
            if query["timeMin"] != nil || query["timeMax"] != nil || query["orderBy"] != nil {
                return json(400, ["error": ["code": 400, "errors": [["reason": "invalid"]]]])
            }
            guard token.hasPrefix("s"), let n = Int(token.dropFirst()), n >= cal.minValidToken else {
                return json(410, ["error": ["code": 410, "errors": [["reason": "fullSyncRequired"]]]])
            }
            var seen = Set<String>()
            let ids = cal.changes.filter { $0.version > n }.map(\.id).filter { seen.insert($0).inserted }
            return feedPage(cal, ids: ids, query: query)
        }
        guard let min = query["timeMin"].flatMap(GoogleEventMapper.parseDateTime),
              let max = query["timeMax"].flatMap(GoogleEventMapper.parseDateTime) else {
            return feedPage(cal, ids: [], query: query)
        }
        guard query["singleEvents"] == "true", query["orderBy"] == "startTime" else { return json(400, [:]) }
        let items = cal.events.values.compactMap { e -> (Date, [String: Any])? in
            guard listCancelled || (e["status"] as? String) != "cancelled", let span = span(e) else { return nil }
            return span.start < max && Swift.max(span.end, span.start.addingTimeInterval(1)) > min ? (span.start, e) : nil
        }.sorted { a, b in a.0 != b.0 ? a.0 < b.0 : ((a.1["id"] as? String) ?? "") < ((b.1["id"] as? String) ?? "") }
            .map(\.1)
        let size = Int(query["maxResults"] ?? "250") ?? 250
        let offset = Int(query["pageToken"]?.dropFirst() ?? "0") ?? 0
        let page = Array(items.dropFirst(offset).prefix(size))
        var body: [String: Any] = ["items": page]
        if offset + page.count < items.count { body["nextPageToken"] = "p\(offset + page.count)" }
        return json(200, body)
    }

    private func feedPage(_ cal: CalendarData, ids: [String], query: [String: String]) -> HTTPResponse {
        let size = feedPageSize ?? 2500
        let offset = Int(query["pageToken"]?.dropFirst() ?? "0") ?? 0
        let total = Swift.max(ids.count, feedPageSize == nil ? 0 : size + 1)   // forced paging: always 2 pages
        let page = Array(ids.dropFirst(offset).prefix(size))
        var body: [String: Any] = [:]
        if query["fields"]?.contains("items") ?? false { body["items"] = page.map { ["id": $0] } }
        if offset + size < total {
            body["nextPageToken"] = "f\(offset + size)"
        } else {
            body["nextSyncToken"] = "s\(cal.version)"
        }
        return json(200, body)
    }

    private func span(_ e: [String: Any]) -> (start: Date, end: Date)? {
        func instant(_ value: Any?) -> Date? {
            guard let t = value as? [String: Any] else { return nil }
            if let d = t["date"] as? String { return DayKey.date(d, calendar) }
            if let d = t["dateTime"] as? String { return GoogleEventMapper.parseDateTime(d) }
            return nil
        }
        guard let start = instant(e["start"]) else { return nil }
        return (start, instant(e["end"]) ?? start)
    }

    private func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(status: status, headers: ["content-type": "application/json"], body: body)
    }
}

/// A test database with accounts.
enum Seed {
    static func database(_ name: String) -> (AppDatabase, URL) {
        let dir = DataTests.folder(name)
        let db = try! AppDatabase(url: dir.appendingPathComponent("store.sqlite"))
        return (db, dir)
    }

    @discardableResult
    static func account(_ db: AppDatabase, email: String, tag: String, sort: Int, color: UInt32 = 0x3CCBB4,
                        includeInAll: Bool = true, calendarOn: Bool = true, health: HealthState = .ok) -> AccountRecord {
        let record = AccountRecord(id: UUID(), provider: "google", email: email, displayName: tag, tag: tag, color: color,
                                   logoFile: nil, includeInAll: includeInAll, mailEnabled: true,
                                   calendarEnabled: calendarOn, sortOrder: sort, health: health, healthDetail: nil,
                                   createdAt: Date(timeIntervalSince1970: 1_000 + Double(sort)))
        try! AccountRepo(db: db).insert(record)
        return record
    }

    static func calendar(_ db: AppDatabase, _ account: UUID, _ id: String, selected: Bool = true, summary: String? = nil) {
        try! CalendarRepo(db: db).upsert(CalendarRecord(accountId: account, calendarId: id, summary: summary ?? id,
                                                        selected: selected, color: nil, accessRole: "owner"))
    }

    /// A stored event row (bypassing Google) for merge/publish tests.
    static func row(_ account: UUID, calendar: String = "primary", id: String, title: String, start: Date, end: Date,
                    uid: String? = nil, allDay: Bool = false, busy: Bool = true, response: String = "accepted",
                    organizer: StoredPerson? = nil, attendees: [StoredPerson] = [], join: String? = nil,
                    location: String? = nil) -> EventRecord {
        let icalUID = uid ?? "\(id)@google.example"
        return EventRecord(r: EventIds.rowId(accountId: account, calendarId: calendar, eventId: id), accountId: account,
                           calendarId: calendar, eventId: id, instanceStart: start, icalUID: icalUID,
                           groupId: EventIds.groupId(icalUID: icalUID, instanceStart: start), title: title,
                           start: start, end: end, allDay: allDay, busy: busy, location: location, joinURL: join,
                           webURL: nil, notes: nil, organizerJSON: organizer.flatMap { StoredPerson.encode($0) },
                           attendeesJSON: attendees.isEmpty ? nil : StoredPerson.encode(attendees),
                           myResponse: response, etag: "\"1\"", status: "confirmed", updated: nil)
    }
}

/// An engine over fakes, loops off unless asked.
final class Harness {
    let dir: URL
    let db: AppDatabase
    let clock: TestClock
    let google = FakeGoogle()
    let source: FakeSource
    let reloader = FakeReloader()
    let keys = FakeLinkKeys()
    let labsMail = Locked(false)
    var env: DataEnvironment
    private var built: DataEngine?

    init(_ name: String, now: Date = TestCal.labNow, runLoops: Bool = false, timing: SyncTiming = SyncTiming()) {
        let (db, dir) = Seed.database(name)
        self.db = db
        self.dir = dir
        clock = TestClock(now)
        source = FakeSource(db: db)
        let labs = labsMail
        env = DataEnvironment(database: db, source: source, transport: google, linkKeys: keys, reloader: reloader,
                              widgetDirectory: dir.appendingPathComponent("widget", isDirectory: true),
                              logosDirectory: dir.appendingPathComponent("widget/logos", isDirectory: true))
        env.now = clock.closure
        env.calendar = { TestCal.lab }
        env.labsMail = { labs.value }
        env.random = { 0 }
        env.runLoops = runLoops
        env.timing = timing
    }

    var engine: DataEngine {
        if let built { return built }
        let e = DataEngine(environment: env)
        built = e
        return e
    }

    /// An account with its Google token and primary calendar on the fake server.
    @discardableResult
    func account(_ email: String, tag: String, sort: Int, includeInAll: Bool = true) -> (AccountRecord, String) {
        let record = Seed.account(db, email: email, tag: tag, sort: sort, includeInAll: includeInAll)
        let token = "access-\(record.id.uuidString)"
        source.tokens.mutate { $0[record.id] = FakeTokens(token: token) }
        google.addCalendar(token: token, id: email, summary: email, primary: true)
        return (record, token)
    }

    func snapshot(_ kind: String) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: engine.publisher.url(kind: kind)) else { return nil }
        return try? WidgetSnapshot.decoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// An address on a consumer mail domain (gmail.com, googlemail.com), built from its parts: personal-domain
/// detection needs the real consumer domains, and the public leak check flags literal addresses outside the
/// reserved test domains (RFC 2606). The local parts stay neutral.
func consumerAddress(_ local: String, _ domain: String = "gmail.com") -> String { "\(local)@\(domain)" }

/// A calendar id on one of Google's own calendar domains (shared groups, holidays and contacts, rooms),
/// built from its parts like `consumerAddress`: these are protocol values, not people.
func googleCalendarID(_ local: String, _ domain: String = "group.calendar.google.com") -> String { "\(local)@\(domain)" }
