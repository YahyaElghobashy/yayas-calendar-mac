import Foundation

// Gmail API v1 wire types: only the fields the app asks for and reads.
// https://developers.google.com/workspace/gmail/api/reference/rest

struct GProfile: Decodable { var emailAddress: String?; var historyId: String? }

struct GThreadList: Decodable {
    struct Item: Decodable, Equatable { var id: String; var historyId: String? }
    var threads: [Item]?
    var nextPageToken: String?
}

struct GHeader: Decodable, Equatable { var name: String?; var value: String? }

struct GMessagePartBody: Decodable, Equatable {
    var size: Int?
    /// base64url of the part's content (Gmail removes the transfer encoding).
    var data: String?
    var attachmentId: String?
}

struct GMessagePart: Decodable, Equatable {
    var partId: String?
    var mimeType: String?
    var filename: String?
    var headers: [GHeader]?
    var body: GMessagePartBody?
    var parts: [GMessagePart]?
}

struct GMessage: Decodable, Equatable {
    var id: String
    var threadId: String?
    var labelIds: [String]?
    var snippet: String?
    var historyId: String?
    /// Epoch milliseconds as a string.
    var internalDate: String?
    var payload: GMessagePart?

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return payload?.headers?.first { $0.name?.lowercased() == lower }?.value
    }

    var date: Date? { internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
}

struct GThread: Decodable, Equatable {
    var id: String
    var historyId: String?
    var snippet: String?
    var messages: [GMessage]?
}

struct GHistoryList: Decodable {
    struct MessageRef: Decodable { var id: String?; var threadId: String?; var labelIds: [String]? }
    struct Change: Decodable { var message: MessageRef?; var labelIds: [String]? }
    struct Record: Decodable {
        var id: String?
        var messages: [MessageRef]?
        var messagesAdded: [Change]?
        var messagesDeleted: [Change]?
        var labelsAdded: [Change]?
        var labelsRemoved: [Change]?

        /// Every thread this record touches.
        var threadIds: [String] {
            var ids = (messages ?? []).compactMap(\.threadId)
            for list in [messagesAdded, messagesDeleted, labelsAdded, labelsRemoved] {
                ids += (list ?? []).compactMap { $0.message?.threadId }
            }
            return ids
        }
    }
    var history: [Record]?
    var nextPageToken: String?
    var historyId: String?
}

struct GLabel: Decodable { var id: String?; var threadsUnread: Int?; var threadsTotal: Int?; var messagesUnread: Int? }

struct GMessageList: Decodable {
    struct Ref: Decodable { var id: String; var threadId: String? }
    var messages: [Ref]?
    var nextPageToken: String?
}

struct GSendAsList: Decodable {
    struct Item: Decodable { var sendAsEmail: String?; var displayName: String?; var isPrimary: Bool?; var isDefault: Bool? }
    var sendAs: [Item]?
}

/// Quota units per call (Gmail's table, rounded up where it changed over time).
enum GmailCost {
    static let profile = 1
    static let labels = 1
    static let sendAs = 1
    static let history = 2
    static let list = 5
    static let modify = 5
    static let search = 5
    static let get = 20
    static let trash = 20
    static let send = 100
    /// `messages.attachments.get` (rich mail, D-043).
    static let attachment = 20
}

/// Per-account token bucket in Gmail quota units: refills at 4,500 per minute (Google allows 6,000 per
/// user per minute) but holds at most `burst` units. Google ALSO caps each user at 250 units per
/// second — measured live 2026-10-20: a bucket that started full at 4,500 fired ~225 metadata GETs at
/// once and every account got 429 "rate_limited". Callers wait when it's empty instead of collecting
/// 429s.
actor GmailQuota {
    static let unitsPerMinute = 4_500.0
    /// Under Gmail's 250 units/s per-user ceiling, with room for the reader's on-demand fetches.
    static let burstUnits = 200.0

    let capacity: Double
    let perSecond: Double
    private var available: Double
    private var updated: Date
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    private(set) var spent = 0
    private(set) var waits = 0
    private(set) var waited: TimeInterval = 0

    init(perMinute: Double = GmailQuota.unitsPerMinute, burst: Double = GmailQuota.burstUnits,
         now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        capacity = min(burst, perMinute)
        perSecond = perMinute / 60
        available = capacity
        self.now = now
        self.sleep = sleep
        updated = now()
    }

    func acquire(_ units: Int) async {
        let cost = min(Double(units), capacity)
        while true {
            refill()
            // A refill can land a hair under the cost (floating point); a tolerance and a minimum wait
            // keep that from spinning on waits too small to move a Date.
            if available + 0.001 >= cost {
                available = max(0, available - cost)
                spent += units
                return
            }
            if Task.isCancelled { return }
            let wait = max(0.01, (cost - available) / perSecond)
            waits += 1
            waited += wait
            await sleep(wait)
        }
    }

    var remaining: Double { refill(); return available }

    private func refill() {
        let t = now()
        let elapsed = max(0, t.timeIntervalSince(updated))
        available = min(capacity, available + elapsed * perSecond)
        updated = t
    }
}

/// Gmail API v1 over `HTTPTransport` for one account (bearer token, one retry after a 401, quota
/// bucket before every request). Errors are `GoogleAPIError` (404 on history = start a full sync).
struct GmailClient: Sendable {
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    static let metadataHeaders = ["From", "Subject", "Date", "Message-ID"]
    static let historyTypes = ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"]

    let transport: HTTPTransport
    let tokens: AccessTokenSource
    let quota: GmailQuota

    // MARK: Reads

    func profile() async throws -> GProfile {
        try await getJSON("/profile", [("fields", "emailAddress,historyId")], cost: GmailCost.profile)
    }

    /// One page of INBOX threads, newest first. `q` narrows it (`category:primary`).
    func listThreads(q: String?, maxResults: Int, pageToken: String?) async throws -> GThreadList {
        var query = [("labelIds", "INBOX"), ("maxResults", "\(maxResults)"), ("fields", "threads(id,historyId),nextPageToken")]
        if let q { query.append(("q", q)) }
        if let pageToken { query.append(("pageToken", pageToken)) }
        return try await getJSON("/threads", query, cost: GmailCost.list)
    }

    func threadMetadata(_ id: String) async throws -> GThread {
        var query = [("format", "metadata")]
        for header in Self.metadataHeaders { query.append(("metadataHeaders", header)) }
        query.append(("fields", "id,historyId,snippet,messages(id,threadId,labelIds,snippet,historyId,internalDate,payload/headers)"))
        return try await getJSON("/threads/\(FormURLEncoding.escape(id))", query, cost: GmailCost.get)
    }

    /// Headers a reply needs from the thread's newest messages.
    func threadReplyHeaders(_ id: String) async throws -> GThread {
        var query = [("format", "metadata")]
        for header in ["Message-ID", "References", "In-Reply-To", "Subject"] { query.append(("metadataHeaders", header)) }
        query.append(("fields", "id,messages(id,labelIds,internalDate,payload/headers)"))
        return try await getJSON("/threads/\(FormURLEncoding.escape(id))", query, cost: GmailCost.get)
    }

    func threadFull(_ id: String) async throws -> GThread {
        try await getJSON("/threads/\(FormURLEncoding.escape(id))", [("format", "full")], cost: GmailCost.get, byteLimit: 40 << 20)
    }

    func history(startHistoryId: String, pageToken: String?) async throws -> GHistoryList {
        var query = [("startHistoryId", startHistoryId), ("maxResults", "500")]
        for type in Self.historyTypes { query.append(("historyTypes", type)) }
        if let pageToken { query.append(("pageToken", pageToken)) }
        return try await getJSON("/history", query, cost: GmailCost.history, byteLimit: 16 << 20)
    }

    func label(_ id: String) async throws -> GLabel {
        try await getJSON("/labels/\(FormURLEncoding.escape(id))", [], cost: GmailCost.labels)
    }

    /// Sent mail carrying this Message-ID (the no-double-send check before any retry).
    func searchSent(messageID: String) async throws -> [GMessageList.Ref] {
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let page: GMessageList = try await getJSON("/messages", [("labelIds", "SENT"), ("q", "rfc822msgid:\(bare)"),
                                                                 ("maxResults", "5")], cost: GmailCost.search)
        return page.messages ?? []
    }

    func sendAs() async throws -> [GSendAsList.Item] {
        let list: GSendAsList = try await getJSON("/settings/sendAs", [], cost: GmailCost.sendAs)
        return list.sendAs ?? []
    }

    /// One attachment's bytes (`messages.attachments.get`, cost 20, the long-timeout session). Gmail sends them
    /// base64url in JSON; `expected` (the part's size from the message) bounds the response: about 4/3 for base64,
    /// plus room for the JSON, never more than 70 MB. The decoded count must equal Gmail's `size`.
    func attachment(messageId: String, id: String, expected: Int) async throws -> Data {
        let limit = expected > 0 ? min(70 << 20, Int(Double(expected) * 1.37) + (64 << 10)) : 70 << 20
        let response = try await send(.get, url("/messages/\(FormURLEncoding.escape(messageId))/attachments/\(FormURLEncoding.escape(id))",
                                                [("fields", "data,size")]),
                                      cost: GmailCost.attachment, byteLimit: limit, long: true)
        return try Self.decodeAttachment(response.body)
    }

    /// `{"size":…,"data":"<base64url>"}` → the bytes; the count must match `size`. The value is found in the response
    /// bytes and decoded from there in 64 KB slices, so a 50 MB attachment costs its response plus its bytes, not five
    /// copies (a JSON string, a byte array, a padded copy…). A value with JSON escapes (Gmail sends none) takes the
    /// general decoder.
    static func decodeAttachment(_ body: Data) throws -> Data {
        guard let fields = AttachmentJSON.scan(body) else { throw GoogleAPIError.undecodable }
        guard let range = fields.data else { throw GoogleAPIError.undecodable }
        let data: Data
        if fields.escaped {
            guard let part = try? JSONDecoder().decode(GMessagePartBody.self, from: body), let text = part.data,
                  let decoded = base64URL(text) else { throw GoogleAPIError.undecodable }
            data = decoded
        } else {
            guard let decoded = AttachmentJSON.base64URL(body, range) else { throw GoogleAPIError.undecodable }
            data = decoded
        }
        if let size = fields.size, size != data.count { throw GoogleAPIError.undecodable }
        return data
    }

    /// base64url over UTF-8 bytes (`Data(base64URL:)` walks Characters, which is far too slow for 35 MB of text).
    static func base64URL(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count + 3)
        for b in text.utf8 {
            switch b {
            case 0x2D: bytes.append(0x2B)                    // - → +
            case 0x5F: bytes.append(0x2F)                    // _ → /
            case 0x20, 0x09, 0x0A, 0x0D: continue
            default: bytes.append(b)
            }
        }
        let rem = bytes.count % 4
        if rem == 1 { return nil }
        if rem > 0 { bytes.append(contentsOf: repeatElement(0x3D, count: 4 - rem)) }
        return Data(base64Encoded: Data(bytes))
    }

    // MARK: Writes

    @discardableResult
    func modifyThread(_ id: String, add: [String] = [], remove: [String] = []) async throws -> GThread? {
        let body = try JSONSerialization.data(withJSONObject: ["addLabelIds": add, "removeLabelIds": remove])
        let response = try await send(.post, url("/threads/\(FormURLEncoding.escape(id))/modify", []), body: body, cost: GmailCost.modify)
        return try? JSONDecoder().decode(GThread.self, from: response.body)
    }

    func modifyMessage(_ id: String, add: [String] = [], remove: [String] = []) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["addLabelIds": add, "removeLabelIds": remove])
        _ = try await send(.post, url("/messages/\(FormURLEncoding.escape(id))/modify", []), body: body, cost: GmailCost.modify)
    }

    @discardableResult
    func trashThread(_ id: String) async throws -> GThread? {
        let response = try await send(.post, url("/threads/\(FormURLEncoding.escape(id))/trash", []), body: Data("{}".utf8),
                                      cost: GmailCost.trash)
        return try? JSONDecoder().decode(GThread.self, from: response.body)
    }

    @discardableResult
    func untrashThread(_ id: String) async throws -> GThread? {
        let response = try await send(.post, url("/threads/\(FormURLEncoding.escape(id))/untrash", []), body: Data("{}".utf8),
                                      cost: GmailCost.trash)
        return try? JSONDecoder().decode(GThread.self, from: response.body)
    }

    /// `messages.send` with `raw` = base64url of the RFC 5322 bytes; `threadId` files a reply in its thread.
    func send(raw: Data, threadId: String?) async throws -> GMessage {
        var object: [String: Any] = ["raw": raw.base64URLString]
        if let threadId { object["threadId"] = threadId }
        let body = try JSONSerialization.data(withJSONObject: object)
        let response = try await send(.post, url("/messages/send", []), body: body, cost: GmailCost.send)
        guard let message = try? JSONDecoder().decode(GMessage.self, from: response.body) else { throw GoogleAPIError.undecodable }
        return message
    }

    /// `messages.send` through the upload URI (rich mail, D-044): raw MIME over 1 MB goes as `uploadType=multipart`
    /// on the same host, a JSON part (`{"threadId":…}` or `{}`) then the message as `message/rfc822`, on the
    /// long-timeout session. (`uploadType=media` can't carry `threadId`, and replies need it to thread.) The body is
    /// written to `bodyFile` (0600; a temporary file when nil) in 1 MB slices and streamed from there, so a 25 MB send
    /// never sits in memory twice; the file is deleted when the request ends. The upload's time limit grows with its size
    /// (`HTTP.uploadResourceTimeout`).
    static let uploadSendURL = "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart"

    func sendUpload(raw: Data, threadId: String?, bodyFile: URL? = nil, boundary: String = "yc-up-" + UUID().uuidString) async throws -> GMessage {
        var object: [String: Any] = [:]
        if let threadId { object["threadId"] = threadId }
        let json = try JSONSerialization.data(withJSONObject: object)
        let file = bodyFile ?? FileManager.default.temporaryDirectory.appendingPathComponent("yc-upload-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.writeUploadBody(to: file, json: json, raw: raw, boundary: boundary)
        let response = try await send(.post, URL(string: Self.uploadSendURL)!, bodyFile: file, cost: GmailCost.send, long: true,
                                      resourceTimeout: HTTP.uploadResourceTimeout(bytes: raw.count),
                                      contentType: "multipart/related; boundary=\(boundary)")
        guard let message = try? JSONDecoder().decode(GMessage.self, from: response.body) else { throw GoogleAPIError.undecodable }
        return message
    }

    /// The upload's multipart/related body, written to `url` (created 0600, replacing anything there).
    static func writeUploadBody(to url: URL, json: Data, raw: Data, boundary: String) throws {
        let out = try MIMEFileWriter(url)
        defer { out.close() }
        try out.write("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        try out.write(json)
        try out.write("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n")
        var offset = 0
        while offset < raw.count {
            let end = min(raw.count, offset + (1 << 20))
            try autoreleasepool { try out.write(raw.subdata(in: offset..<end)) }
            offset = end
        }
        try out.write("\r\n--\(boundary)--\r\n")
        try out.flush()
    }

    // MARK: Plumbing

    func url(_ path: String, _ query: [(String, String)]) -> URL {
        var text = Self.base + path
        if !query.isEmpty {
            text += "?" + query.map { "\(FormURLEncoding.escape($0.0))=\(FormURLEncoding.escape($0.1))" }.joined(separator: "&")
        }
        return URL(string: text)!
    }

    private func getJSON<T: Decodable>(_ path: String, _ query: [(String, String)], cost: Int,
                                       byteLimit: Int = 8 << 20) async throws -> T {
        let response = try await send(.get, url(path, query), cost: cost, byteLimit: byteLimit)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw GoogleAPIError.undecodable
        }
    }

    private func send(_ method: HTTPMethod, _ url: URL, body: Data? = nil, bodyFile: URL? = nil, cost: Int,
                      byteLimit: Int = 8 << 20, long: Bool = false, resourceTimeout: TimeInterval? = nil,
                      contentType: String = "application/json") async throws -> HTTPResponse {
        var refreshed = false
        while true {
            await quota.acquire(cost)
            try Task.checkCancellation()
            let token = try await tokens.accessToken(forceRefresh: refreshed)
            var headers = ["Authorization": "Bearer \(token)"]
            if body != nil || bodyFile != nil { headers["Content-Type"] = contentType }
            let response: HTTPResponse
            do {
                response = try await transport.send(HTTPRequest(method: method, url: url, headers: headers, body: body,
                                                                byteLimit: byteLimit, long: long, bodyFile: bodyFile,
                                                                resourceTimeout: resourceTimeout))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GoogleCalendarClient.classify(transport: error)
            }
            if response.status == 401 && !refreshed {
                await tokens.invalidateAccessToken()
                refreshed = true
                continue
            }
            guard response.isSuccess else { throw GoogleAPIError(response: response) }
            return response
        }
    }
}

/// The two fields of `messages.attachments.get` read straight from the response bytes (rich mail attachments): the
/// top-level `"data"` string's byte range and `"size"`. Anything that isn't one JSON object is refused; nested values
/// and other fields are skipped.
enum AttachmentJSON {
    struct Fields {
        /// The bytes between the quotes of the top-level "data" string.
        var data: Range<Int>?
        var size: Int?
        /// The data string holds a backslash escape.
        var escaped = false
    }

    static func scan(_ body: Data) -> Fields? {
        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Fields? in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            func space() { while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 } }
            /// At an opening quote: past the closing one. Returns the content range and whether it held an escape.
            func string() -> (Range<Int>, Bool)? {
                guard i < b.count, b[i] == 0x22 else { return nil }
                let start = i + 1
                var j = start
                var escaped = false
                while j < b.count, b[j] != 0x22 {
                    if b[j] == 0x5C { escaped = true; j += 2 } else { j += 1 }
                }
                guard j < b.count else { return nil }
                i = j + 1
                return (start..<j, escaped)
            }
            /// Skips one value of any kind.
            func value() -> Bool {
                guard i < b.count else { return false }
                switch b[i] {
                case 0x22: return string() != nil
                case 0x7B, 0x5B:
                    var depth = 0
                    while i < b.count {
                        switch b[i] {
                        case 0x22: guard string() != nil else { return false }; continue
                        case 0x7B, 0x5B: depth += 1
                        case 0x7D, 0x5D: depth -= 1
                        default: break
                        }
                        i += 1
                        if depth == 0 { return true }
                    }
                    return false
                default:
                    let start = i
                    while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
                    return i > start
                }
            }
            var fields = Fields()
            space()
            guard i < b.count, b[i] == 0x7B else { return nil }
            i += 1
            space()
            if i < b.count, b[i] == 0x7D { i += 1; space(); return i == b.count ? fields : nil }
            while true {
                space()
                guard let (keyRange, _) = string() else { return nil }
                let key = String(decoding: UnsafeBufferPointer(rebasing: b[keyRange]), as: UTF8.self)
                space()
                guard i < b.count, b[i] == 0x3A else { return nil }
                i += 1
                space()
                if key == "data" {
                    guard i < b.count, b[i] == 0x22, let (range, escaped) = string() else { return nil }
                    fields.data = range
                    fields.escaped = escaped
                } else if key == "size" {
                    let start = i
                    guard value() else { return nil }
                    fields.size = Int(String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self))
                } else {
                    guard value() else { return nil }
                }
                space()
                guard i < b.count else { return nil }
                if b[i] == 0x2C { i += 1; continue }
                guard b[i] == 0x7D else { return nil }
                i += 1
                space()
                return i == b.count ? fields : nil
            }
        }
    }

    /// base64url (padding optional, spaces ignored) in `range` of `body` → bytes, decoded 64 KB of text at a time into
    /// one buffer sized up front. Nil for anything that isn't base64url.
    static func base64URL(_ body: Data, _ range: Range<Int>) -> Data? {
        let chunk = 64 << 10   // a multiple of 4
        var out = Data()
        out.reserveCapacity(range.count / 4 * 3 + 3)
        var text = [UInt8](repeating: 0, count: chunk + 4)
        let ok: Bool = body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            return text.withUnsafeMutableBufferPointer { (t: inout UnsafeMutableBufferPointer<UInt8>) -> Bool in
                guard let base = t.baseAddress else { return false }
                var n = 0
                func decode() -> Bool {
                    guard n > 0 else { return true }
                    guard let bytes = Data(base64Encoded: Data(bytesNoCopy: base, count: n, deallocator: .none)) else { return false }
                    out.append(bytes)
                    n = 0
                    return true
                }
                var k = range.lowerBound
                while k < range.upperBound {
                    let c = table[Int(b[k])]
                    k += 1
                    if c == 0 { return false }
                    if c == 1 { continue }
                    base[n] = c
                    n += 1
                    // Padding only ends the value: a full slice ending in "=" waits for the end.
                    if n == chunk, c != 0x3D, !decode() { return false }
                    if n > chunk + 3 { return false }   // padding followed by more text
                }
                let rem = n % 4
                if rem == 1 { return false }
                if rem > 0 { for _ in 0..<(4 - rem) { base[n] = 0x3D; n += 1 } }
                return decode()
            }
        }
        return ok ? out : nil
    }

    /// base64url → base64 per byte: 0 = not allowed, 1 = skipped (a space), else the byte to decode.
    private static let table: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 256)
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { t[Int(c)] = c }
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { t[Int(c)] = c }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { t[Int(c)] = c }
        for c in [UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "=")] { t[Int(c)] = c }
        t[Int(UInt8(ascii: "-"))] = UInt8(ascii: "+")
        t[Int(UInt8(ascii: "_"))] = UInt8(ascii: "/")
        t[Int(UInt8(ascii: " "))] = 1
        return t
    }()
}
