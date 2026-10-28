import Foundation

/// The app's way to Google's sign-in and APIs: HTTPS to an allowlisted host with an allowlisted method, on an
/// ephemeral session with no cookies, no cache, no credential store, no redirects and TLS 1.2+.
/// Requests that fail the policy are refused before any task exists. The app's only other network paths are
/// the logo fetcher (an account's own website, `LogoFetcher`) and the loopback listener that catches the
/// sign-in redirect on this Mac (`LoopbackServer`).
final class HTTP: @unchecked Sendable {
    static let shared = HTTP()

    static let allowedHosts: Set<String> = [
        "accounts.google.com",
        "oauth2.googleapis.com",
        "gmail.googleapis.com",
        "www.googleapis.com",
        "openidconnect.googleapis.com",
    ]

    static let defaultByteLimit = 4 << 20
    static let requestTimeout: TimeInterval = 30
    /// `HTTPRequest.long` (attachment downloads, large sends): 60 s between bytes, 15 min in all.
    static let longRequestTimeout: TimeInterval = 60
    static let longResourceTimeout: TimeInterval = 900
    /// The slowest uplink a big send is given time for (bytes per second): 25 MB gets about 51 minutes. A dead connection
    /// still fails after `longRequestTimeout` without a byte moving.
    static let minimumUploadRate: Double = 8_192

    /// The whole-transfer limit for an upload of `bytes`: 15 min, or longer when the body needs it at `minimumUploadRate`.
    static func uploadResourceTimeout(bytes: Int) -> TimeInterval {
        max(longResourceTimeout, (Double(max(0, bytes)) / minimumUploadRate).rounded(.up))
    }

    private let session: URLSession
    private let longSession: URLSession

    init() {
        session = Self.makeSession(request: Self.requestTimeout, resource: Self.requestTimeout * 2)
        longSession = Self.makeSession(request: Self.longRequestTimeout, resource: Self.longResourceTimeout)
    }

    /// The one policy for both sessions: ephemeral, no cookies, cache or credential store, TLS 1.2+, no redirects.
    private static func makeSession(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = request
        config.timeoutIntervalForResource = resource
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// Throws `HTTPError` for anything off-policy; otherwise returns the response whatever its status. A `bodyFile` is
    /// streamed from disk (`upload(for:fromFile:)`), never read into memory; a `resourceTimeout` longer than the
    /// session's gets a one-off session with the same policy.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Self.validate(request.url)
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: request.long ? Self.longRequestTimeout : Self.requestTimeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        if request.bodyFile == nil { urlRequest.httpBody = request.body }

        var chosen = request.long ? longSession : session
        var oneOff = false
        let limit = request.long ? Self.longResourceTimeout : Self.requestTimeout * 2
        if let resource = request.resourceTimeout, resource > limit {
            chosen = Self.makeSession(request: request.long ? Self.longRequestTimeout : Self.requestTimeout, resource: resource)
            oneOff = true
        }
        defer { if oneOff { chosen.finishTasksAndInvalidate() } }

        if let file = request.bodyFile {
            let (data, response) = try await chosen.upload(for: urlRequest, fromFile: file)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
            guard data.count <= request.byteLimit else { throw HTTPError.responseTooLarge(limit: request.byteLimit) }
            return HTTPResponse(status: http.statusCode, headers: Self.headers(http), body: data)
        }

        let (bytes, response) = try await chosen.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        if http.expectedContentLength > Int64(request.byteLimit) {
            bytes.task.cancel()
            throw HTTPError.responseTooLarge(limit: request.byteLimit)
        }
        var body = Data()
        if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
        // Appended 64 KB at a time (a 35 MB attachment body byte by byte costs real CPU); the limit holds per chunk.
        let chunkSize = 64 << 10
        var chunk: [UInt8] = []
        chunk.reserveCapacity(chunkSize)
        for try await byte in bytes {
            chunk.append(byte)
            if body.count + chunk.count > request.byteLimit {
                bytes.task.cancel()
                throw HTTPError.responseTooLarge(limit: request.byteLimit)
            }
            if chunk.count == chunkSize {
                body.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        body.append(contentsOf: chunk)
        return HTTPResponse(status: http.statusCode, headers: Self.headers(http), body: body)
    }

    /// Response headers, names lowercased.
    private static func headers(_ http: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return headers
    }

    func get(_ url: URL, bearer: String? = nil, headers: [String: String] = [:],
             byteLimit: Int = HTTP.defaultByteLimit) async throws -> HTTPResponse {
        var all = headers
        if let bearer { all["Authorization"] = "Bearer \(bearer)" }
        return try await send(HTTPRequest(method: .get, url: url, headers: all, byteLimit: byteLimit))
    }

    /// `application/x-www-form-urlencoded` POST, as OAuth token endpoints expect.
    func postForm(_ url: URL, fields: [(String, String)], byteLimit: Int = 64 << 10) async throws -> HTTPResponse {
        try await send(HTTPRequest(method: .post, url: url,
                                   headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                   body: FormURLEncoding.encode(fields), byteLimit: byteLimit))
    }

    /// https only, allowlisted host, default port, no userinfo, no fragment.
    static func validate(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw HTTPError.invalidURL }
        guard parts.scheme?.lowercased() == "https" else { throw HTTPError.schemeNotAllowed }
        guard let host = parts.host?.lowercased(), allowedHosts.contains(host) else {
            throw HTTPError.hostNotAllowed(parts.host ?? "")
        }
        guard parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw HTTPError.invalidURL
        }
    }
}

/// The methods the app uses. Anything else cannot be expressed.
enum HTTPMethod: String, CaseIterable, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

struct HTTPRequest: Sendable {
    var method: HTTPMethod
    var url: URL
    var headers: [String: String] = [:]
    var body: Data? = nil
    var byteLimit: Int = HTTP.defaultByteLimit
    /// Large transfers (attachments, big sends): the long-timeout session, same policy.
    var long = false
    /// The body streamed from this file instead of `body` (big sends: the upload never sits in memory whole).
    var bodyFile: URL? = nil
    /// A whole-transfer limit longer than the session's (an upload sized for a slow uplink).
    var resourceTimeout: TimeInterval? = nil
}

struct HTTPResponse: Sendable {
    let status: Int
    /// Lowercased names.
    let headers: [String: String]
    let body: Data

    var isSuccess: Bool { (200..<300).contains(status) }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Seconds to wait before retrying, from `Retry-After` (delta-seconds or HTTP-date).
    func retryAfter(now: Date = Date()) -> TimeInterval? {
        header("retry-after").flatMap { RetryAfter.parse($0, now: now) }
    }

    func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw HTTPError.undecodable(status: status)
        }
    }

    func jsonObject() throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw HTTPError.undecodable(status: status)
        }
        return object
    }
}

enum HTTPError: Error, Equatable, Sendable {
    case invalidURL
    case schemeNotAllowed
    case hostNotAllowed(String)
    case notHTTP
    case responseTooLarge(limit: Int)
    case undecodable(status: Int)
}

/// RFC 7231 §7.1.3.
enum RetryAfter {
    static func parse(_ value: String, now: Date = Date()) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isASCIIDigit) {
            return TimeInterval(trimmed)
        }
        for format in httpDateFormats {
            if let date = format.date(from: trimmed) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    /// IMF-fixdate, then the two obsolete forms recipients must still accept.
    private static let httpDateFormats: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ].map { pattern in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = pattern
        return formatter
    }
}

/// `application/x-www-form-urlencoded` with everything outside the RFC 3986 unreserved set
/// percent-encoded, so `+`, `&`, `=` and `/` inside values survive intact.
enum FormURLEncoding {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func encode(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// A redirect could leave the allowlist; the 3xx itself is handed back instead.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
