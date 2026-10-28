import Foundation

/// Fetches a company logo for an account's email domain. This is deliberately a separate, tiny fetcher
/// and NOT part of the OAuth/API allowlist in `Sources/Net/HTTP.swift`: it may only talk to the
/// account's own website, which by definition is not on that list.
///
/// Rules (all enforced before and after every redirect):
/// - https only, default port, no userinfo;
/// - host must be exactly `<domain>` or `www.<domain>` (the account's email domain);
/// - at most 512 KB per response (streamed byte cap), 8 s per request, ephemeral session with no
///   cookies, cache or credential store;
/// - at most seven HTTP requests per fetch, redirects included, and three same-site redirects per address
///   (`RequestBudget`), so "seven at most" in Settings, on the success screen and in PRIVACY.md always holds;
/// - consumer domains (gmail.com, googlemail.com) are never fetched: personal accounts get no fetched logo.
///
/// Order: `https://<domain>/apple-touch-icon.png` → `<link rel="apple-touch-icon"|"icon">` (PNG or SVG)
/// from the home page → `https://<domain>/favicon.ico`. The first source at least 48 px wide (or any
/// vector) wins; otherwise the largest small one. The result is a 128×128 PNG (`LogoStore`).
struct LogoFetcher: Sendable {
    static let maxBytes = 512 * 1024
    static let timeout: TimeInterval = 8
    static let goodEnoughPixels = 48
    static let maxLinkCandidates = 4
    /// Every HTTP request of one fetch counts, redirects included.
    static let maxRequests = 7
    /// Same-site redirects followed for one address.
    static let maxRedirects = 3

    /// One fetch's requests, shared by `get` and the redirect guard (URLSession calls the guard on its own queue).
    final class RequestBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var used = 0
        private var redirects: [Int: Int] = [:]

        /// Requests made so far, redirects included.
        var count: Int { lock.lock(); defer { lock.unlock() }; return used }

        /// Room for one more request: taken, true; the budget spent, false.
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard used < LogoFetcher.maxRequests else { return false }
            used += 1
            return true
        }

        /// A redirect of task `task` to `url`: followed (and counted) only to an allowed host, at most `maxRedirects`
        /// times for that task, while the budget has room.
        func redirect(task: Int, to url: URL?, domain: String) -> Bool {
            guard let url, LogoFetcher.isAllowed(url, domain: domain) else { return false }
            lock.lock(); defer { lock.unlock() }
            let followed = redirects[task, default: 0]
            guard followed < LogoFetcher.maxRedirects, used < LogoFetcher.maxRequests else { return false }
            redirects[task] = followed + 1
            used += 1
            return true
        }
    }

    func fetch(domain rawDomain: String) async -> Data? {
        guard let domain = Self.validDomain(rawDomain), !AccountNaming.personalDomains.contains(domain) else {
            return nil
        }
        let budget = RequestBudget()
        let session = Self.makeSession(domain: domain, budget: budget)
        defer { session.invalidateAndCancel() }

        var fallback: (png: Data, pixels: Int)?
        func consider(_ data: Data) -> Data? {
            guard let result = LogoStore.normalizedPNG(from: data) else { return nil }
            if result.sourcePixels >= Self.goodEnoughPixels { return result.png }
            if fallback == nil || result.sourcePixels > fallback!.pixels { fallback = (result.png, result.sourcePixels) }
            return nil
        }

        for url in Self.primaryCandidates(domain: domain) {
            if let body = await get(url, session: session, domain: domain, budget: budget), let png = consider(body.data) { return png }
        }
        if let page = Self.homePage(domain: domain),
           let body = await get(page, session: session, domain: domain, budget: budget, allowTruncation: true) {
            let html = String(decoding: body.data, as: UTF8.self)
            for url in Self.iconLinks(inHTML: html, base: body.finalURL, domain: domain).prefix(Self.maxLinkCandidates) {
                if let icon = await get(url, session: session, domain: domain, budget: budget), let png = consider(icon.data) { return png }
            }
        }
        for url in Self.fallbackCandidates(domain: domain) {
            if let body = await get(url, session: session, domain: domain, budget: budget), let png = consider(body.data) { return png }
        }
        return fallback?.png
    }

    // MARK: - Policy (pure, unit-tested)

    /// A lowercase DNS name with at least two labels; nil for anything else (IPs, junk, single labels).
    static func validDomain(_ raw: String) -> String? {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard !domain.isEmpty, domain.count <= 253, domain.allSatisfy(allowed.contains) else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              let last = labels.last, !last.allSatisfy(\.isNumber)
        else { return nil }
        return domain
    }

    static func allowedHosts(domain: String) -> Set<String> { [domain, "www.\(domain)"] }

    static func isAllowed(_ url: URL, domain: String) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), allowedHosts(domain: domain).contains(host),
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil
        else { return false }
        return true
    }

    static func primaryCandidates(domain: String) -> [URL] {
        [URL(string: "https://\(domain)/apple-touch-icon.png")].compactMap { $0 }
    }

    static func homePage(domain: String) -> URL? { URL(string: "https://\(domain)/") }

    static func fallbackCandidates(domain: String) -> [URL] {
        [URL(string: "https://\(domain)/favicon.ico")].compactMap { $0 }
    }

    /// The full ordered list before any HTML is known (for tests and docs).
    static func staticCandidates(domain: String) -> [URL] {
        primaryCandidates(domain: domain) + [homePage(domain: domain)].compactMap { $0 } + fallbackCandidates(domain: domain)
    }

    /// `<link rel="apple-touch-icon" | "icon" …>` hrefs that are PNG or SVG, resolved against `base` and
    /// filtered to the allowed hosts. Apple touch icons first, then SVG, then PNG by declared size.
    static func iconLinks(inHTML html: String, base: URL, domain: String) -> [URL] {
        guard let tagPattern = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
              let attrPattern = try? NSRegularExpression(
                pattern: "([a-zA-Z_:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))", options: [])
        else { return [] }
        let text = html as NSString
        var found: [(url: URL, rank: Int, size: Int)] = []
        for tag in tagPattern.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let tagText = text.substring(with: tag.range)
            let tagNS = tagText as NSString
            var attributes: [String: String] = [:]
            for attr in attrPattern.matches(in: tagText, range: NSRange(location: 0, length: tagNS.length)) {
                let name = tagNS.substring(with: attr.range(at: 1)).lowercased()
                let value = (2...4).compactMap { i -> String? in
                    let r = attr.range(at: i)
                    return r.location == NSNotFound ? nil : tagNS.substring(with: r)
                }.first ?? ""
                if attributes[name] == nil { attributes[name] = value }
            }
            let rel = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let isTouch = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
            guard isTouch || rel.contains("icon"), !rel.contains("mask-icon"),
                  let rawHref = attributes["href"], !rawHref.isEmpty else { continue }
            let href = decodeEntities(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.lowercased().hasPrefix("data:"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  isAllowed(url, domain: domain) else { continue }
            let type = (attributes["type"] ?? "").lowercased()
            let ext = url.pathExtension.lowercased()
            let isSVG = type.contains("svg") || ext == "svg"
            let isPNG = type.contains("png") || ext == "png"
            guard isSVG || isPNG else { continue }
            let size = (attributes["sizes"] ?? "").lowercased()
                .split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.max() ?? 0
            found.append((url, isTouch ? 0 : (isSVG ? 1 : 2), size))
        }
        var seen = Set<String>()
        return found
            .enumerated()
            .sorted { ($0.element.rank, -$0.element.size, $0.offset) < ($1.element.rank, -$1.element.size, $1.offset) }
            .map(\.element.url)
            .filter { seen.insert($0.absoluteString).inserted }
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/")
    }

    // MARK: - Network

    private struct Body {
        let data: Data
        let finalURL: URL
    }

    private func get(_ url: URL, session: URLSession, domain: String, budget: RequestBudget, allowTruncation: Bool = false) async -> Body? {
        guard Self.isAllowed(url, domain: domain), budget.take() else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpShouldHandleCookies = false
        request.setValue(allowTruncation ? "text/html" : "image/png,image/svg+xml,image/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let finalURL = http.url, Self.isAllowed(finalURL, domain: domain) else {
                bytes.task.cancel()
                return nil
            }
            if !allowTruncation, http.expectedContentLength > Int64(Self.maxBytes) {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= Self.maxBytes {
                    bytes.task.cancel()
                    return allowTruncation ? Body(data: data, finalURL: finalURL) : nil
                }
            }
            return Body(data: data, finalURL: finalURL)
        } catch {
            return nil
        }
    }

    private static func makeSession(domain: String, budget: RequestBudget) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: RedirectGuard(domain: domain, budget: budget), delegateQueue: nil)
    }

    /// Follows a redirect only when its target passes the same host rules and the budget allows it; otherwise the 3xx
    /// itself comes back, and `get` treats it as no logo.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let domain: String
        let budget: RequestBudget
        init(domain: String, budget: RequestBudget) { self.domain = domain; self.budget = budget }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(budget.redirect(task: task.taskIdentifier, to: request.url, domain: domain) ? request : nil)
        }
    }
}
