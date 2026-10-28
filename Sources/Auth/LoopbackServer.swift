import Foundation
import Network

/// Catches one OAuth redirect on the loopback interface (RFC 8252 §7.3).
///
/// Bound with `requiredLocalEndpoint` to a loopback address and `acceptLocalOnly`, so nothing off this
/// Mac can connect and neither the application firewall nor the Local Network prompt is involved.
/// Single use: the listeners close after the first valid callback, on `cancel()`, or after `timeout`.
/// A request with a wrong or missing `state` is answered and ignored; the flow keeps waiting, so a stale
/// tab or a hostile page cannot end it.
final class LoopbackServer: @unchecked Sendable {
    enum Binding: Sendable, Equatable {
        /// Google: `http://127.0.0.1:<port>`.
        case ipv4
        /// Microsoft: `http://localhost:<port>`. Entra ignores the port for localhost redirects, and the
        /// browser may resolve localhost to either family, so this listens on 127.0.0.1 and ::1 at the
        /// same port.
        case localhost
    }

    enum Outcome: Equatable, Sendable {
        case code(String)
        case providerError(code: String, description: String?, subcode: String?)
    }

    enum Failure: Error, Equatable {
        case bindFailed(String)
        case timedOut
        case cancelled
        case alreadyStarted
        case notStarted
    }

    static let defaultTimeout: TimeInterval = 300
    static let maxRequestBytes = 8 * 1024
    static let maxConnections = 16
    static let connectionIdleTimeout: TimeInterval = 15
    private static let dualBindAttempts = 5

    let binding: Binding
    private let expectedState: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: Profile.scoped("loopback"))

    // Confined to `queue`.
    private var started = false
    private var port: UInt16 = 0
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var deadline: DispatchWorkItem?
    private var outcome: Result<Outcome, Error>?
    private var waiter: CheckedContinuation<Outcome, Error>?

    init(binding: Binding, expectedState: String, timeout: TimeInterval = LoopbackServer.defaultTimeout) {
        self.binding = binding
        self.expectedState = expectedState
        self.timeout = timeout
    }

    deinit {
        deadline?.cancel()
        listeners.forEach { $0.cancel() }
        connections.values.forEach { $0.cancel() }
    }

    /// Binds and returns the `redirect_uri` to put in the authorize request.
    func start() async throws -> URL {
        try queue.sync {
            guard !started else { throw Failure.alreadyStarted }
            started = true
        }
        let bound = try await bind()
        return try queue.sync {
            if outcome != nil {
                dropListeners()
                throw Failure.cancelled
            }
            port = bound
            let expiry = DispatchWorkItem { [weak self] in self?.finish(.failure(Failure.timedOut)) }
            deadline = expiry
            queue.asyncAfter(deadline: .now() + timeout, execute: expiry)
            return Self.redirectURI(for: binding, port: bound)
        }
    }

    /// Suspends until the browser delivers a callback with the right `state`, the deadline passes, or
    /// the task is cancelled.
    func waitForCallback() async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
                queue.async {
                    if let outcome = self.outcome { continuation.resume(with: outcome); return }
                    guard self.started, self.waiter == nil else {
                        continuation.resume(throwing: self.started ? Failure.alreadyStarted : Failure.notStarted)
                        return
                    }
                    self.waiter = continuation
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(Failure.cancelled)) }
    }

    static func redirectURI(for binding: Binding, port: UInt16) -> URL {
        switch binding {
        case .ipv4: return URL(string: "http://127.0.0.1:\(port)")!
        case .localhost: return URL(string: "http://localhost:\(port)")!
        }
    }

    /// `Host` header values a genuine redirect can carry. Anything else (DNS rebinding) is refused.
    static func allowedHostHeaders(port: UInt16) -> Set<String> {
        ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
    }

    // MARK: - Binding

    /// Returns the bound port. Every listener created here is owned by `listeners` from birth, so
    /// `finish` can always reach it.
    private func bind() async throws -> UInt16 {
        switch binding {
        case .ipv4:
            return try await listen(on: .ipv4(.loopback), port: .any)
        case .localhost:
            for _ in 0..<Self.dualBindAttempts {
                let port = try await listen(on: .ipv4(.loopback), port: .any)
                guard let samePort = NWEndpoint.Port(rawValue: port) else { continue }
                do {
                    _ = try await listen(on: .ipv6(.loopback), port: samePort)
                    return port
                } catch {
                    // Something else holds [::1]:port. Try a fresh port rather than leave ::1 to a stranger.
                    queue.sync { dropListeners() }
                }
            }
            // No usable IPv6 loopback: browsers fall back to 127.0.0.1 when ::1 refuses the connection.
            return try await listen(on: .ipv4(.loopback), port: .any)
        }
    }

    private func listen(on host: NWEndpoint.Host, port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.bindFailed(String(describing: error))
        }
        try queue.sync {
            guard outcome == nil else { throw Failure.cancelled }
            listeners.append(listener)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let listener else { return }
                guard !gate.used else {
                    if case .failed = state { self?.listenerStopped(listener) }
                    return
                }
                switch state {
                case .ready:
                    gate.used = true
                    if let bound = listener.port?.rawValue {
                        continuation.resume(returning: bound)
                    } else {
                        self?.drop(listener)
                        continuation.resume(throwing: Failure.bindFailed("listener has no port"))
                    }
                case .failed(let error), .waiting(let error):
                    gate.used = true
                    self?.drop(listener)
                    continuation.resume(throwing: Failure.bindFailed(String(describing: error)))
                case .cancelled:
                    gate.used = true
                    continuation.resume(throwing: Failure.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func drop(_ listener: NWListener) {
        listener.cancel()
        listeners.removeAll { $0 === listener }
    }

    private func dropListeners() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
    }

    /// A listener that dies after binding. The flow only fails once no listener is left.
    private func listenerStopped(_ listener: NWListener) {
        guard listeners.contains(where: { $0 === listener }) else { return }
        drop(listener)
        if listeners.isEmpty, port != 0 { finish(.failure(Failure.bindFailed("listener stopped"))) }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard outcome == nil, connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        // Browsers open speculative connections that never send a request.
        queue.asyncAfter(deadline: .now() + Self.connectionIdleTimeout) { [weak connection] in connection?.cancel() }
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffered
            if let content { buffer.append(content) }
            guard buffer.count <= Self.maxRequestBytes else {
                self.respond(connection, with: .tooLarge)
                return
            }
            switch LoopbackRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffered: buffer)
                }
            case .invalid:
                self.respond(connection, with: .badRequest)
            case .request(let request):
                self.handle(request, on: connection)
            }
        }
    }

    private func handle(_ request: LoopbackRequest, on connection: NWConnection) {
        guard outcome == nil else {
            respond(connection, with: .expired)
            return
        }
        let decision = LoopbackRoute.decide(request, expectedState: expectedState,
                                            allowedHosts: Self.allowedHostHeaders(port: port))
        switch decision {
        case .accept(let result):
            if case .code = result {
                respond(connection, with: .success)
            } else {
                respond(connection, with: .providerError)
            }
            finish(.success(result), keeping: connection)
        case .stateMismatch:
            respond(connection, with: .expired)
        case .notFound:
            respond(connection, with: .notFound)
        case .methodNotAllowed:
            respond(connection, with: .methodNotAllowed)
        case .badRequest:
            respond(connection, with: .badRequest)
        }
    }

    private func respond(_ connection: NWConnection, with page: LoopbackPage) {
        connection.send(content: page.httpResponse(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<Outcome, Error>, keeping survivor: NWConnection? = nil) {
        guard outcome == nil else { return }
        outcome = result
        deadline?.cancel()
        deadline = nil
        dropListeners()
        for connection in connections.values where connection !== survivor { connection.cancel() }
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        }
    }
}

/// Queue-confined "resume exactly once" flag for a listener's state handler.
private final class ResumeGate: @unchecked Sendable {
    var used = false
}

// MARK: - Request parsing

/// The request head of one HTTP/1.x request, parsed strictly enough that nothing malformed reaches the
/// state check, and with no URL-parsing APIs that trap on bad input.
struct LoopbackRequest: Equatable, Sendable {
    enum Parse: Equatable, Sendable {
        case incomplete
        case invalid
        case request(LoopbackRequest)
    }

    let method: String
    let path: String
    let query: String?
    /// Lowercased names.
    let headers: [String: String]

    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let requestLine = lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return .invalid }
        let (method, target, version) = (parts[0], parts[1], parts[2])
        guard !method.isEmpty, method.utf8.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }),
              version == "HTTP/1.1" || version == "HTTP/1.0",
              target.hasPrefix("/"),
              target.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
        else { return .invalid }

        var resource = Substring(target)
        if let hash = resource.firstIndex(of: "#") { resource = resource[..<hash] }
        let path: String
        let query: String?
        if let mark = resource.firstIndex(of: "?") {
            path = String(resource[..<mark])
            query = String(resource[resource.index(after: mark)...])
        } else {
            path = String(resource)
            query = nil
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon]
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return .invalid }
            let key = name.lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if key == "host", headers[key] != nil { return .invalid }
            headers[key] = value
        }
        return .request(LoopbackRequest(method: method, path: path, query: query, headers: headers))
    }

    /// Percent-decoded parameters, or nil when the query is malformed or repeats a name (which would make
    /// it ambiguous which `state` or `code` counts).
    static func parameters(fromQuery query: String) -> [String: String]? {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let rawName: Substring
            let rawValue: Substring
            if let equals = pair.firstIndex(of: "=") {
                rawName = pair[..<equals]
                rawValue = pair[pair.index(after: equals)...]
            } else {
                rawName = pair
                rawValue = ""
            }
            guard let name = String(rawName).removingPercentEncoding,
                  let value = String(rawValue).removingPercentEncoding,
                  result[name] == nil
            else { return nil }
            result[name] = value
        }
        return result
    }
}

enum LoopbackDecision: Equatable, Sendable {
    case accept(LoopbackServer.Outcome)
    case stateMismatch
    case notFound
    case methodNotAllowed
    case badRequest
}

enum LoopbackRoute {
    static func decide(_ request: LoopbackRequest, expectedState: String, allowedHosts: Set<String>) -> LoopbackDecision {
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else { return .badRequest }
        guard request.method == "GET" else { return .methodNotAllowed }
        guard request.path == "/" else { return .notFound }
        guard let query = request.query, let parameters = LoopbackRequest.parameters(fromQuery: query) else {
            return .badRequest
        }
        guard let state = parameters["state"], constantTimeEquals(state, expectedState) else { return .stateMismatch }
        if let error = parameters["error"], !error.isEmpty {
            return .accept(.providerError(code: error, description: parameters["error_description"],
                                          subcode: parameters["error_subcode"]))
        }
        guard let code = parameters["code"], !code.isEmpty else { return .badRequest }
        return .accept(.code(code))
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

// MARK: - Pages

/// Fixed, self-contained pages: no request data is ever reflected, no scripts, no external resources.
enum LoopbackPage: Equatable, Sendable {
    case success
    case providerError
    case expired
    case notFound
    case methodNotAllowed
    case badRequest
    case tooLarge

    var status: (code: Int, reason: String) {
        switch self {
        case .success, .providerError: return (200, "OK")
        case .expired, .badRequest: return (400, "Bad Request")
        case .notFound: return (404, "Not Found")
        case .methodNotAllowed: return (405, "Method Not Allowed")
        case .tooLarge: return (431, "Request Header Fields Too Large")
        }
    }

    private var copy: (title: String, message: String, positive: Bool) {
        switch self {
        case .success:
            return ("Signed in", "You can close this tab &mdash; Yaya&rsquo;s Calendar has it.", true)
        case .providerError:
            return ("Sign-in didn&rsquo;t finish", "Head back to Yaya&rsquo;s Calendar &mdash; it has the details.", false)
        case .expired:
            return ("This sign-in link has expired", "Start again from Yaya&rsquo;s Calendar.", false)
        case .notFound, .methodNotAllowed, .badRequest, .tooLarge:
            return ("Nothing here", "This address only answers Yaya&rsquo;s Calendar sign-ins.", false)
        }
    }

    func httpResponse() -> Data {
        let body = Data(html.utf8)
        let head = [
            "HTTP/1.1 \(status.code) \(status.reason)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Pragma: no-cache",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data((head + "\r\n\r\n").utf8) + body
    }

    var html: String {
        let (title, message, positive) = copy
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="dark">
        <link rel="icon" href="data:,">
        <title>Yaya&rsquo;s Calendar</title>
        <style>
        html,body{height:100%;margin:0}
        body{display:flex;align-items:center;justify-content:center;background:#0E1A22;\
        background-image:radial-gradient(60rem 36rem at 50% -12%,rgba(60,203,180,.16),transparent 62%);\
        color:#E9F4F1;font:15px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;-webkit-font-smoothing:antialiased}
        main{margin:16px;max-width:420px;padding:32px 28px;border-radius:16px;text-align:center;\
        background:rgba(233,244,241,.055);border:1px solid rgba(233,244,241,.09)}
        .mark{position:relative;width:44px;height:44px;margin:0 auto 18px;border-radius:50%;background:#3CCBB4}
        .mark::after{content:"";position:absolute;left:16px;top:9px;width:9px;height:18px;\
        border:solid #0E1A22;border-width:0 3px 3px 0;transform:rotate(45deg)}
        .mark.warn{background:#E0A35C}
        .mark.warn::after{content:"!";left:0;top:0;width:100%;height:100%;border:0;transform:none;\
        font:700 24px/44px ui-rounded,system-ui,sans-serif;color:#0E1A22}
        h1{margin:0 0 6px;font:600 20px/1.3 ui-rounded,-apple-system,system-ui,sans-serif;letter-spacing:-.01em}
        p{margin:0;color:rgba(233,244,241,.72)}
        .brand{margin-top:22px;font-size:12px;letter-spacing:.04em;color:#3CCBB4}
        </style></head>
        <body><main>
        <div class="mark\(positive ? "" : " warn")"></div>
        <h1>\(title)</h1>
        <p>\(message)</p>
        <div class="brand">YAYA&rsquo;S CALENDAR</div>
        </main></body></html>
        """
    }
}
