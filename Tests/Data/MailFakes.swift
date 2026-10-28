import Foundation

// Gmail fakes for the mail tests. Nothing here touches the network, the Keychain or real mail: an
// in-memory Gmail API v1 routed by bearer token, a calendar/Gmail transport splitter, and sleepers
// that either advance the test clock or wait for the test to let them go.

/// Sends calendar requests to FakeGoogle and Gmail requests to FakeGmail.
final class SplitTransport: HTTPTransport, @unchecked Sendable {
    let calendar: FakeGoogle
    let gmail: FakeGmail
    init(calendar: FakeGoogle, gmail: FakeGmail) {
        self.calendar = calendar
        self.gmail = gmail
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.host == "gmail.googleapis.com" { return try await gmail.send(request) }
        return try await calendar.send(request)
    }
}

/// `sleep` for the engine: by default advances the test clock and returns at once; `gate()` makes the
/// next sleeps wait until `release()`.
final class TestSleeper: @unchecked Sendable {
    let clock: TestClock
    let requests = Locked<[TimeInterval]>([])
    private let lock = NSLock()
    private var gated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(clock: TestClock) { self.clock = clock }

    func gate() { lock.lock(); gated = true; lock.unlock() }

    func release() {
        lock.lock()
        gated = false
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for w in pending { w.resume() }
    }

    var waiting: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    func sleep(_ seconds: TimeInterval) async {
        requests.mutate { $0.append(seconds) }
        lock.lock()
        if gated {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
                lock.unlock()
            }
            return
        }
        lock.unlock()
        clock.advance(seconds)
    }

    var closure: @Sendable (TimeInterval) async -> Void { { [self] in await self.sleep($0) } }
}

/// An in-memory Gmail API v1 (the calls the app makes): profile, threads.list (labelIds=INBOX, q
/// category:primary, paging), threads.get (metadata/full), history.list (404 below the oldest kept
/// history id), labels.get INBOX, threads.modify/trash/untrash, messages.modify, messages.send (raw
/// parsed back), messages.list (`rfc822msgid:` search in SENT), settings.sendAs. Every request also
/// passes the app's real `HTTP.validate`.
final class FakeGmail: HTTPTransport, @unchecked Sendable {
    struct Message {
        var id: String
        var threadId: String
        var labels: Set<String>
        var internalDate: Int64
        var headers: [(String, String)]
        var snippet: String
        /// format=full payload; nil = a text/plain body made from `snippet`.
        var payload: [String: Any]?
        var historyId: Int
    }

    final class Mailbox {
        var email: String
        var historyId = 5_000
        /// history.list with a start below this answers 404.
        var oldestHistory = 0
        var messages: [String: Message] = [:]
        var order: [String] = []
        var history: [(id: Int, kind: String, messageId: String, threadId: String, labels: [String])] = []
        var sendAsName: String? = "Avery Moonfield"
        var sent: [Data] = []
        var untrashRestoresInbox = true
        var trashedInbox: Set<String> = []
        init(email: String) { self.email = email }
    }

    struct Injected {
        var match: String
        var method: HTTPMethod?
        var status: Int
        var body: String
        var remaining: Int
        /// Throw URLError(.timedOut) instead of answering.
        var timeout: Bool
        /// Do the work first, then fail (a send that reached Gmail but whose answer was lost).
        var afterWork: Bool
    }

    private let lock = NSLock()
    private var boxes: [String: Mailbox] = [:]
    private var injected: [Injected] = []
    private var log: [HTTPRequest] = []
    private var nextId = 1
    private var inFlight = 0
    private(set) var maxInFlight = 0
    var getDelay: UInt64 = 0
    var modifyDelay: UInt64 = 0
    var historyPageSize = 1_000

    // MARK: Setup

    @discardableResult
    func addMailbox(token: String, email: String) -> Mailbox {
        lock.lock(); defer { lock.unlock() }
        let box = Mailbox(email: email)
        boxes[token] = box
        return box
    }

    func mailbox(_ token: String) -> Mailbox? { lock.lock(); defer { lock.unlock() }; return boxes[token] }

    /// A message (and its thread). Returns the message id.
    @discardableResult
    func add(token: String, thread: String, id: String? = nil, from: String = "Sender <sender@example.com>",
             subject: String = "Hello", date: Date, labels: [String] = ["INBOX", "UNREAD", "CATEGORY_PERSONAL"],
             snippet: String = "Snippet text", messageIdHeader: String? = nil, extraHeaders: [(String, String)] = [],
             payload: [String: Any]? = nil) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let box = boxes[token] else { fatalError("no mailbox") }
        let msgId = id ?? "msg\(nextId)"
        nextId += 1
        box.historyId += 1
        var headers: [(String, String)] = [("From", from), ("To", box.email), ("Subject", subject),
                                           ("Date", MailDate.format(date)),
                                           ("Message-ID", messageIdHeader ?? "<\(msgId)@mail.example.com>")]
        headers += extraHeaders
        box.messages[msgId] = Message(id: msgId, threadId: thread, labels: Set(labels), internalDate: Int64(date.timeIntervalSince1970 * 1000),
                                    headers: headers, snippet: snippet, payload: payload, historyId: box.historyId)
        box.order.append(msgId)
        box.history.append((box.historyId, "messageAdded", msgId, thread, labels))
        return msgId
    }

    /// Label change made elsewhere (Gmail web, phone).
    func relabel(token: String, message: String, add: [String] = [], remove: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        guard let box = boxes[token], var m = box.messages[message] else { return }
        m.labels.formUnion(add)
        m.labels.subtract(remove)
        box.historyId += 1
        m.historyId = box.historyId
        box.messages[message] = m
        if !add.isEmpty { box.history.append((box.historyId, "labelAdded", message, m.threadId, add)) }
        if !remove.isEmpty { box.history.append((box.historyId, "labelRemoved", message, m.threadId, remove)) }
    }

    func deleteThread(token: String, thread: String) {
        lock.lock(); defer { lock.unlock() }
        guard let box = boxes[token] else { return }
        for (id, m) in box.messages where m.threadId == thread {
            box.messages[id] = nil
            box.historyId += 1
            box.history.append((box.historyId, "messageDeleted", id, thread, []))
        }
        box.order.removeAll { box.messages[$0] == nil }
    }

    func labels(token: String, thread: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var out = Set<String>()
        guard let box = boxes[token] else { return out }
        for m in box.messages.values where m.threadId == thread { out.formUnion(m.labels) }
        return out
    }

    func messageLabels(token: String, message: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return boxes[token]?.messages[message]?.labels ?? []
    }

    func sentCount(token: String) -> Int { lock.lock(); defer { lock.unlock() }; return boxes[token]?.sent.count ?? 0 }
    func sentRaw(token: String) -> [Data] { lock.lock(); defer { lock.unlock() }; return boxes[token]?.sent ?? [] }

    func inject(_ match: String, method: HTTPMethod? = nil, status: Int = 500, body: String = "{}", times: Int = 1,
                timeout: Bool = false, afterWork: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        injected.append(Injected(match: match, method: method, status: status, body: body, remaining: times,
                                 timeout: timeout, afterWork: afterWork))
    }

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return log }
    func clearLog() { lock.lock(); log.removeAll(); maxInFlight = 0; lock.unlock() }
    func count(_ substring: String, method: HTTPMethod? = nil) -> Int {
        requests.filter { $0.url.absoluteString.contains(substring) && (method == nil || $0.method == method) }.count
    }

    // MARK: Transport

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try HTTP.validate(request.url)
        let text = request.url.absoluteString
        lock.lock()
        log.append(request)
        var hit: Injected?
        if let index = injected.firstIndex(where: { $0.remaining > 0 && text.contains($0.match)
            && ($0.method == nil || $0.method == request.method) }) {
            injected[index].remaining -= 1
            hit = injected[index]
        }
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        lock.unlock()
        defer { lock.lock(); inFlight -= 1; lock.unlock() }

        let isGet = request.method == .get && text.contains("/threads/")
        if isGet && getDelay > 0 { try? await Task.sleep(nanoseconds: getDelay) }
        if !isGet && request.method == .post && modifyDelay > 0 { try? await Task.sleep(nanoseconds: modifyDelay) }

        if let hit, !hit.afterWork {
            if hit.timeout { throw URLError(.timedOut) }
            return HTTPResponse(status: hit.status, headers: [:], body: Data(hit.body.utf8))
        }
        let response = handle(request)
        if let hit {
            if hit.timeout { throw URLError(.timedOut) }
            return HTTPResponse(status: hit.status, headers: [:], body: Data(hit.body.utf8))
        }
        return response
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        guard let auth = request.headers["Authorization"], auth.hasPrefix("Bearer "), let box = boxes[String(auth.dropFirst(7))]
        else { return json(401, ["error": ["code": 401]]) }
        guard let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else { return json(400, [:]) }
        var query: [String: [String]] = [:]
        for item in parts.queryItems ?? [] { query[item.name, default: []].append(item.value ?? "") }
        let path = parts.percentEncodedPath.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        // gmail / v1 / users / me / …
        guard path.count >= 5, path[0] == "gmail", path[1] == "v1", path[2] == "users", path[3] == "me" else { return json(404, [:]) }
        let rest = Array(path.dropFirst(4))
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        switch (request.method, rest.count, rest.first ?? "") {
        case (.get, 1, "profile"):
            return json(200, ["emailAddress": box.email, "historyId": "\(box.historyId)"])
        case (.get, 1, "threads"):
            return listThreads(box, query)
        case (.get, 2, "threads"):
            return getThread(box, rest[1], query)
        case (.post, 3, "threads"):
            return threadAction(box, rest[1], rest[2], body)
        case (.post, 3, "messages") where rest[2] == "modify":
            guard var m = box.messages[rest[1]] else { return json(404, ["error": ["code": 404]]) }
            let add = body["addLabelIds"] as? [String] ?? []
            let remove = body["removeLabelIds"] as? [String] ?? []
            apply(box, &m, add: add, remove: remove)
            return json(200, ["id": m.id, "threadId": m.threadId, "labelIds": Array(m.labels)])
        case (.post, 2, "messages") where rest[1] == "send":
            return sendMessage(box, body)
        case (.get, 1, "messages"):
            let q = query["q"]?.first ?? ""
            guard q.hasPrefix("rfc822msgid:") else { return json(400, [:]) }
            let wanted = String(q.dropFirst("rfc822msgid:".count))
            let hits = box.messages.values.filter { m in
                m.labels.contains("SENT") && m.headers.contains { $0.0.lowercased() == "message-id"
                    && $0.1.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) == wanted }
            }
            return json(200, hits.isEmpty ? ["resultSizeEstimate": 0] : ["messages": hits.map { ["id": $0.id, "threadId": $0.threadId] }])
        case (.get, 1, "history"):
            return history(box, query)
        case (.get, 2, "labels") where rest[1] == "INBOX":
            let unread = Set(box.messages.values.filter { $0.labels.contains("INBOX") && $0.labels.contains("UNREAD") }.map(\.threadId))
            let total = Set(box.messages.values.filter { $0.labels.contains("INBOX") }.map(\.threadId))
            return json(200, ["id": "INBOX", "threadsUnread": unread.count, "threadsTotal": total.count])
        case (.get, 2, "settings") where rest[1] == "sendAs":
            var item: [String: Any] = ["sendAsEmail": box.email, "isPrimary": true, "isDefault": true]
            if let name = box.sendAsName { item["displayName"] = name }
            return json(200, ["sendAs": [item]])
        default:
            return json(404, ["error": ["code": 404]])
        }
    }

    private func threadIds(_ box: Mailbox) -> [String] {
        var seen = Set<String>()
        return box.order.compactMap { box.messages[$0]?.threadId }.filter { seen.insert($0).inserted }
    }

    private func messages(_ box: Mailbox, thread: String) -> [Message] {
        box.order.compactMap { box.messages[$0] }.filter { $0.threadId == thread }
    }

    private func listThreads(_ box: Mailbox, _ query: [String: [String]]) -> HTTPResponse {
        guard query["labelIds"] == ["INBOX"] else { return json(400, [:]) }
        let primaryOnly = query["q"]?.first == "category:primary"
        if let q = query["q"]?.first, !primaryOnly { return json(400, ["error": ["code": 400, "q": q]]) }
        var threads: [(String, Int64, Int)] = []
        for id in threadIds(box) {
            let ms = messages(box, thread: id)
            let inbox = ms.filter { $0.labels.contains("INBOX") }
            guard !inbox.isEmpty else { continue }
            if primaryOnly && !inbox.contains(where: { $0.labels.contains("CATEGORY_PERSONAL")
                || !$0.labels.contains { $0.hasPrefix("CATEGORY_") } }) { continue }
            threads.append((id, ms.map(\.internalDate).max() ?? 0, ms.map(\.historyId).max() ?? 0))
        }
        threads.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let size = Int(query["maxResults"]?.first ?? "100") ?? 100
        let offset = Int(query["pageToken"]?.first?.dropFirst() ?? "0") ?? 0
        let page = Array(threads.dropFirst(offset).prefix(size))
        var out: [String: Any] = ["threads": page.map { ["id": $0.0, "historyId": "\($0.2)"] }]
        if offset + page.count < threads.count { out["nextPageToken"] = "t\(offset + page.count)" }
        return json(200, out)
    }

    private func messageJSON(_ m: Message, format: String, headers wanted: [String]) -> [String: Any] {
        var out: [String: Any] = ["id": m.id, "threadId": m.threadId, "labelIds": Array(m.labels).sorted(),
                                  "snippet": m.snippet, "historyId": "\(m.historyId)", "internalDate": "\(m.internalDate)"]
        let lower = Set(wanted.map { $0.lowercased() })
        let headers = m.headers.filter { format != "metadata" || lower.isEmpty || lower.contains($0.0.lowercased()) }
            .map { ["name": $0.0, "value": $0.1] }
        if format == "full" {
            var payload = m.payload ?? ["mimeType": "text/plain",
                                        "headers": [["name": "Content-Type", "value": "text/plain; charset=UTF-8"]],
                                        "body": ["size": m.snippet.utf8.count, "data": Data(m.snippet.utf8).base64URLString]]
            var partHeaders = payload["headers"] as? [[String: String]] ?? []
            partHeaders = headers.map { ["name": $0["name"]!, "value": $0["value"]!] } + partHeaders
            payload["headers"] = partHeaders
            out["payload"] = payload
        } else {
            out["payload"] = ["headers": headers]
        }
        return out
    }

    private func getThread(_ box: Mailbox, _ id: String, _ query: [String: [String]]) -> HTTPResponse {
        let ms = messages(box, thread: id)
        guard !ms.isEmpty else { return json(404, ["error": ["code": 404]]) }
        let format = query["format"]?.first ?? "full"
        let wanted = query["metadataHeaders"] ?? []
        return json(200, ["id": id, "historyId": "\(ms.map(\.historyId).max() ?? 0)", "snippet": ms.last?.snippet ?? "",
                          "messages": ms.map { messageJSON($0, format: format, headers: wanted) }])
    }

    private func apply(_ box: Mailbox, _ m: inout Message, add: [String], remove: [String]) {
        let before = m.labels
        m.labels.formUnion(add)
        m.labels.subtract(remove)
        guard m.labels != before else { return }
        box.historyId += 1
        m.historyId = box.historyId
        box.messages[m.id] = m
        let added = Array(m.labels.subtracting(before))
        let removed = Array(before.subtracting(m.labels))
        if !added.isEmpty { box.history.append((box.historyId, "labelAdded", m.id, m.threadId, added)) }
        if !removed.isEmpty { box.history.append((box.historyId, "labelRemoved", m.id, m.threadId, removed)) }
    }

    private func threadAction(_ box: Mailbox, _ id: String, _ action: String, _ body: [String: Any]) -> HTTPResponse {
        let ms = messages(box, thread: id)
        guard !ms.isEmpty else { return json(404, ["error": ["code": 404]]) }
        for var m in ms {
            switch action {
            case "modify":
                apply(box, &m, add: body["addLabelIds"] as? [String] ?? [], remove: body["removeLabelIds"] as? [String] ?? [])
            case "trash":
                if m.labels.contains("INBOX") { box.trashedInbox.insert(m.id) }
                apply(box, &m, add: ["TRASH"], remove: ["INBOX"])
            case "untrash":
                let restore = box.untrashRestoresInbox && box.trashedInbox.contains(m.id)
                apply(box, &m, add: restore ? ["INBOX"] : [], remove: ["TRASH"])
                box.trashedInbox.remove(m.id)
            default:
                return json(404, [:])
            }
        }
        return json(200, ["id": id, "messages": messages(box, thread: id).map { ["id": $0.id, "labelIds": Array($0.labels).sorted()] }])
    }

    private func sendMessage(_ box: Mailbox, _ body: [String: Any]) -> HTTPResponse {
        guard let raw = (body["raw"] as? String).flatMap({ Data(base64URL: $0) }) else { return json(400, [:]) }
        box.sent.append(raw)
        let part = MIMEParser.parse(raw)
        let thread = body["threadId"] as? String ?? "sent\(nextId)"
        let id = "sent-msg\(nextId)"
        nextId += 1
        box.historyId += 1
        let headers = part.headers.map { ($0.name, $0.value) }
        box.messages[id] = Message(id: id, threadId: thread, labels: ["SENT"], internalDate: Int64(Date().timeIntervalSince1970 * 1000),
                                   headers: headers, snippet: "", payload: nil, historyId: box.historyId)
        box.order.append(id)
        box.history.append((box.historyId, "messageAdded", id, thread, ["SENT"]))
        return json(200, ["id": id, "threadId": thread, "labelIds": ["SENT"]])
    }

    private func history(_ box: Mailbox, _ query: [String: [String]]) -> HTTPResponse {
        guard let start = Int(query["startHistoryId"]?.first ?? "") else { return json(400, [:]) }
        if start < box.oldestHistory { return json(404, ["error": ["code": 404, "errors": [["reason": "notFound"]]]]) }
        let types = Set(query["historyTypes"] ?? [])
        let records = box.history.filter { $0.id > start && (types.isEmpty || types.contains($0.kind)) }
        let offset = Int(query["pageToken"]?.first?.dropFirst() ?? "0") ?? 0
        let page = Array(records.dropFirst(offset).prefix(historyPageSize))
        let items: [[String: Any]] = page.map { r in
            let message: [String: Any] = ["id": r.messageId, "threadId": r.threadId]
            var item: [String: Any] = ["id": "\(r.id)", "messages": [message]]
            switch r.kind {
            case "messageAdded": item["messagesAdded"] = [["message": message]]
            case "messageDeleted": item["messagesDeleted"] = [["message": message]]
            case "labelAdded": item["labelsAdded"] = [["message": message, "labelIds": r.labels]]
            default: item["labelsRemoved"] = [["message": message, "labelIds": r.labels]]
            }
            return item
        }
        var out: [String: Any] = ["historyId": "\(box.historyId)"]
        if !items.isEmpty { out["history"] = items }
        if offset + page.count < records.count { out["nextPageToken"] = "h\(offset + page.count)" }
        return json(200, out)
    }

    private func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(status: status, headers: ["content-type": "application/json"], body: body)
    }
}

/// A Harness with Gmail: mail on, the split transport, a clock-driven sleeper, mail cache under the
/// test folder.
final class MailHarness {
    let h: Harness
    let gmail = FakeGmail()
    let sleeper: TestSleeper
    let safeSend = Locked(true)

    init(_ name: String, now: Date = TestCal.labNow, runLoops: Bool = false, timing: SyncTiming = SyncTiming()) {
        h = Harness(name, now: now, runLoops: runLoops, timing: timing)
        sleeper = TestSleeper(clock: h.clock)
        h.env.transport = SplitTransport(calendar: h.google, gmail: gmail)
        h.env.sleep = sleeper.closure
        let safe = safeSend
        h.env.labsSafeSend = { safe.value }
        h.labsMail.value = true
    }

    var engine: DataEngine { h.engine }
    var db: AppDatabase { h.db }
    var clock: TestClock { h.clock }

    /// A Google account with a mailbox (and its calendar on FakeGoogle).
    @discardableResult
    func account(_ email: String, tag: String, sort: Int, includeInAll: Bool = true) -> (AccountRecord, String) {
        let (record, token) = h.account(email, tag: tag, sort: sort, includeInAll: includeInAll)
        gmail.addMailbox(token: token, email: email)
        return (record, token)
    }

    /// `count` threads, one message each, newest = thread 0, one minute apart before now.
    func fill(_ token: String, threads count: Int, prefix: String = "t", labels: [String] = ["INBOX", "UNREAD", "CATEGORY_PERSONAL"],
              start: Date? = nil) {
        let newest = start ?? clock.now.addingTimeInterval(-60)
        for i in 0..<count {
            gmail.add(token: token, thread: "\(prefix)\(i)", from: "Sender \(i) <s\(i)@example.com>", subject: "Subject \(i)",
                      date: newest.addingTimeInterval(-Double(i) * 60), labels: labels, snippet: "Snippet \(i) &amp; more")
        }
    }

    func syncMail(_ id: UUID) async -> SyncOutcome { await engine.syncMail(id) }

    func r(_ account: UUID, _ thread: String) -> String { MailIds.threadR(accountId: account, threadId: thread) }

    func row(_ account: UUID, _ thread: String) -> MailThreadRecord? { try? MailRepo(db: db).thread(r: r(account, thread)) }
}

/// `expect` for conditions that contain `await` (an autoclosure can't suspend; this evaluates first).
func check(_ condition: Bool, _ name: String, file: String = #fileID, line: Int = #line) {
    DataTests.expect(condition, name, file: file, line: line)
}
