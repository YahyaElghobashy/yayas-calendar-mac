import Foundation

/// Finds a meeting's join link: conference video entry points first, then Google's hangoutLink, then
/// links in the location and the description. Only https links to known meeting hosts survive, so a
/// tap on Join never opens an arbitrary site.
enum JoinLinks {
    struct Host {
        let domain: String
        /// Also accept any subdomain (`*.zoom.us`).
        let subdomains: Bool
        /// Only the subdomains, not the bare domain (`*.webex.com`).
        let subdomainsOnly: Bool
        /// The path must start with one of these; empty = any path other than "/".
        let paths: [String]
    }

    static let hosts: [Host] = [
        Host(domain: "meet.google.com", subdomains: false, subdomainsOnly: false, paths: []),
        Host(domain: "zoom.us", subdomains: true, subdomainsOnly: false, paths: ["/j/", "/my/", "/w/", "/s/", "/wc/"]),
        Host(domain: "teams.microsoft.com", subdomains: false, subdomainsOnly: false,
             paths: ["/l/meetup-join/", "/meet/", "/l/meeting/"]),
        Host(domain: "teams.live.com", subdomains: false, subdomainsOnly: false, paths: ["/meet/"]),
        Host(domain: "webex.com", subdomains: true, subdomainsOnly: true, paths: []),
        Host(domain: "whereby.com", subdomains: false, subdomainsOnly: false, paths: []),
        Host(domain: "app.slack.com", subdomains: false, subdomainsOnly: false, paths: ["/huddle/"]),
        Host(domain: "meet.goto.com", subdomains: false, subdomainsOnly: false, paths: []),
        Host(domain: "chime.aws", subdomains: false, subdomainsOnly: false, paths: []),
        Host(domain: "meet.jit.si", subdomains: false, subdomainsOnly: false, paths: []),
    ]

    /// The first allowed link, in priority order.
    static func extract(videoEntryPoints: [String], hangoutLink: String?, location: String?,
                        description: String?) -> URL? {
        for candidate in videoEntryPoints {
            if let url = normalize(candidate) { return url }
        }
        if let hangoutLink, let url = normalize(hangoutLink) { return url }
        for text in [location, description].compactMap({ $0 }) {
            for candidate in urls(in: text) {
                if let url = normalize(candidate) { return url }
            }
        }
        return nil
    }

    /// Unwraps redirect wrappers (Google `/url?q=`, Outlook Safe Links), then checks the allowlist.
    static func normalize(_ raw: String, depth: Int = 0) -> URL? {
        let text = decodeEntities(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text.count <= 2048, let url = URL(string: text),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }
        if depth < 2, let inner = wrapped(parts, host: host) { return normalize(inner, depth: depth + 1) }
        return isAllowed(url) ? url : nil
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              host.unicodeScalars.allSatisfy({ $0.isASCII }), !host.contains("%")
        else { return false }
        let path = parts.path
        for rule in hosts {
            let exact = host == rule.domain
            let sub = rule.subdomains && host.hasSuffix("." + rule.domain)
            guard (exact && !rule.subdomainsOnly) || sub else { continue }
            if rule.paths.isEmpty { return path.count > 1 }
            return rule.paths.contains { path.lowercased().hasPrefix($0) }
        }
        return false
    }

    /// `https://` links in free text or HTML (hrefs included), trailing punctuation trimmed.
    static func urls(in text: String) -> [String] {
        var out: [String] = []
        let scalars = Array(text.unicodeScalars)
        let lower = text.lowercased().unicodeScalars.map { $0 }
        guard scalars.count == lower.count else { return fallbackURLs(in: text) }
        let marker = Array("https://".unicodeScalars)
        var i = 0
        while i + marker.count <= scalars.count {
            if Array(lower[i..<(i + marker.count)]) == marker {
                var j = i
                while j < scalars.count, !isTerminator(scalars[j]) { j += 1 }
                var candidate = String(String.UnicodeScalarView(scalars[i..<j]))
                while let last = candidate.last, ".,;:!?)]}'\u{201D}".contains(last) { candidate.removeLast() }
                if candidate.count > marker.count { out.append(candidate) }
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func isTerminator(_ s: Unicode.Scalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(s) { return true }
        return "\"'<>`\u{00A0}".unicodeScalars.contains(s)
    }

    /// Lowercasing changed the scalar count (rare letters): scan a case-sensitive copy instead.
    private static func fallbackURLs(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>`")))
            .filter { $0.lowercased().hasPrefix("https://") }
    }

    private static func wrapped(_ parts: URLComponents, host: String) -> String? {
        let items = parts.queryItems ?? []
        if (host == "www.google.com" || host == "google.com"), parts.path == "/url" {
            return items.first { $0.name == "q" || $0.name == "url" }?.value
        }
        if host.hasSuffix(".safelinks.protection.outlook.com") {
            return items.first { $0.name == "url" }?.value
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&#x26;", with: "&")
    }
}

/// Event descriptions arrive as HTML or plain text; notes are shown as plain text.
enum PlainText {
    static func fromHTML(_ input: String?) -> String? {
        guard let input else { return nil }
        let looksHTML = input.range(of: #"<(br|p|div|a|b|i|u|ul|ol|li|span|strong|em|html|font|h\d)[\s/>]"#,
                                    options: [.regularExpression, .caseInsensitive]) != nil
        var text = input
        if looksHTML {
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            text = text.replacingOccurrences(of: "\n", with: " ")
            text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: #"</?(p|div|h\d|tr)(\s[^>]*)?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: #"</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: #"<li[^>]*>"#, with: "\u{2022} ", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            text = decode(text)
            text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            if let semi = tail.prefix(12).firstIndex(of: ";") {
                let name = String(tail[tail.index(after: amp)..<semi])
                if let scalar = entity(name) {
                    out.unicodeScalars.append(scalar)
                    rest = tail[tail.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = tail.dropFirst()
        }
        return out + rest
    }

    private static func entity(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            if name.hasPrefix("#x") || name.hasPrefix("#X") { return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
            if name.hasPrefix("#") { return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init) }
            return nil
        }
    }
}
