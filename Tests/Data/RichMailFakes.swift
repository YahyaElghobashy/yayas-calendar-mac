import Foundation

/// `SplitTransport` plus Gmail's `messages.attachments.get`, served from a table the test registers, and the
/// upload URI: `POST /upload/gmail/v1/users/me/messages/send?uploadType=multipart` is rewritten into the equivalent
/// JSON `/messages/send` for `FakeGmail` (so injections, timeouts, `sentRaw` and the Sent search apply unchanged) and
/// recorded (a body sent as a file is read from it). Unknown attachment ids answer 404, as Gmail does for a stale id.
/// Records requests and concurrency.
final class RichGmailTransport: HTTPTransport, @unchecked Sendable {
    struct Upload: Equatable {
        /// The JSON part: `{"threadId":…}` or `{}`.
        var metadata: [String: String]
        var rawBytes: Int
        var contentType: String
        var long: Bool
        /// The multipart body came as a file (`HTTPRequest.bodyFile`), not built in memory.
        var fromFile = false
        var resourceTimeout: TimeInterval?
        var bodyFile: URL?
    }

    let inner: HTTPTransport
    private let lock = NSLock()
    private var table: [String: Data] = [:]
    private var log: [(attachmentId: String, long: Bool)] = []
    private var uploadLog: [Upload] = []
    private var jsonSends = 0
    private var inFlight = 0
    private(set) var maxInFlight = 0
    var delay: UInt64 = 0

    init(inner: HTTPTransport) { self.inner = inner }

    func serve(_ messageId: String, _ attachmentId: String, _ data: Data) {
        lock.lock(); table["\(messageId)/\(attachmentId)"] = data; lock.unlock()
    }

    func requests(_ attachmentId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return log.filter { $0.attachmentId == attachmentId }.count
    }

    var attachmentCount: Int { lock.lock(); defer { lock.unlock() }; return log.count }
    var allLong: Bool { lock.lock(); defer { lock.unlock() }; return !log.isEmpty && log.allSatisfy(\.long) }
    var uploads: [Upload] { lock.lock(); defer { lock.unlock() }; return uploadLog }
    /// `messages.send` requests that came as JSON (not through the upload URI).
    var jsonSendCount: Int { lock.lock(); defer { lock.unlock() }; return jsonSends }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.url.path
        if request.method == .post, path == "/upload/gmail/v1/users/me/messages/send" {
            return try await upload(request)
        }
        if request.method == .post, path == "/gmail/v1/users/me/messages/send" {
            lock.lock(); jsonSends += 1; lock.unlock()
        }
        guard request.method == .get, path.hasPrefix("/gmail/v1/users/me/messages/"), path.contains("/attachments/") else {
            return try await inner.send(request)
        }
        try HTTP.validate(request.url)
        let parts = path.split(separator: "/").map(String.init)   // gmail v1 users me messages {mid} attachments {aid}
        guard parts.count == 8 else { return HTTPResponse(status: 404, headers: [:], body: Data("{}".utf8)) }
        let (mid, aid) = (parts[5], parts[7])
        lock.lock()
        log.append((aid, request.long))
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        let data = table["\(mid)/\(aid)"]
        let wait = delay
        lock.unlock()
        if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
        lock.lock(); inFlight -= 1; lock.unlock()
        guard request.headers["Authorization"]?.hasPrefix("Bearer ") == true else {
            return HTTPResponse(status: 401, headers: [:], body: Data("{}".utf8))
        }
        guard let data else {
            return HTTPResponse(status: 404, headers: ["content-type": "application/json"],
                                body: Data(#"{"error":{"code":404,"errors":[{"reason":"notFound"}]}}"#.utf8))
        }
        let body = try JSONSerialization.data(withJSONObject: ["size": data.count, "data": data.base64URLString])
        guard body.count <= request.byteLimit else { throw HTTPError.responseTooLarge(limit: request.byteLimit) }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: body)
    }

    /// multipart/related: a JSON part, then message/rfc822 → `{"raw":…, "threadId":…}` on the JSON endpoint.
    private func upload(_ request: HTTPRequest) async throws -> HTTPResponse {
        try HTTP.validate(request.url)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let contentType = request.headers["Content-Type"] ?? ""
        guard query.contains(where: { $0.name == "uploadType" && $0.value == "multipart" }),
              contentType.hasPrefix("multipart/related; boundary="),
              let body = request.body ?? request.bodyFile.flatMap({ try? Data(contentsOf: $0) }) else {
            return HTTPResponse(status: 400, headers: [:], body: Data("{}".utf8))
        }
        let boundary = String(contentType.dropFirst("multipart/related; boundary=".count))
        let parts = MIMEParser.multipart(body, boundary: boundary)
        guard parts.count == 2 else { return HTTPResponse(status: 400, headers: [:], body: Data("{}".utf8)) }
        func split(_ part: Data) -> (headers: String, content: Data) {
            let sep = Data("\r\n\r\n".utf8)
            guard let r = part.range(of: sep) else { return ("", part) }
            return (String(decoding: part[..<r.lowerBound], as: UTF8.self), part[r.upperBound...])
        }
        let (h1, json) = split(parts[0]), (h2, raw) = split(parts[1])
        guard h1.contains("application/json"), h2.contains("message/rfc822"),
              let meta = try? JSONSerialization.jsonObject(with: json) as? [String: String] else {
            return HTTPResponse(status: 400, headers: [:], body: Data("{}".utf8))
        }
        lock.lock()
        uploadLog.append(Upload(metadata: meta, rawBytes: raw.count, contentType: contentType, long: request.long,
                                fromFile: request.body == nil && request.bodyFile != nil, resourceTimeout: request.resourceTimeout,
                                bodyFile: request.bodyFile))
        lock.unlock()
        var object: [String: Any] = ["raw": Data(raw).base64URLString]
        if let thread = meta["threadId"] { object["threadId"] = thread }
        var rewritten = HTTPRequest(method: .post, url: URL(string: GmailClient.base + "/messages/send")!, headers: request.headers,
                                    body: try JSONSerialization.data(withJSONObject: object), byteLimit: request.byteLimit, long: request.long)
        rewritten.headers["Content-Type"] = "application/json"
        return try await inner.send(rewritten)
    }
}
