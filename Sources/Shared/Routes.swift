import Foundation

/// Sidebar sections of the main window; also the `section` value of `yayacal://open/app`.
enum AppSection: String, CaseIterable, Identifiable {
    case inbox, calendar, widgets, accounts, settings
    var id: String { rawValue }
}

/// One row of the route table in docs/CONTRACTS.md. Quiet routes act in the background: if the link
/// brought the agent forward, it hides again within 250 ms so the user's app comes back.
struct RouteSpec: Equatable {
    let name: String
    let params: [String]
    let quiet: Bool
}

enum RouteTable {
    static let scheme = Profile.urlScheme

    /// Exactly the CONTRACTS table. Tests compare against it; add routes there first.
    static let all: [RouteSpec] = [
        RouteSpec(name: "ping", params: ["probe"], quiet: true),
        RouteSpec(name: "open/app", params: ["section"], quiet: false),
        RouteSpec(name: "page", params: ["w", "fam", "to"], quiet: true),
        RouteSpec(name: "day", params: ["w", "d"], quiet: true),
        RouteSpec(name: "month", params: ["w", "to"], quiet: true),
        RouteSpec(name: "range", params: ["w", "v"], quiet: true),
        RouteSpec(name: "sync", params: ["w"], quiet: true),
        RouteSpec(name: "join", params: ["r", "k"], quiet: true),
        RouteSpec(name: "rsvp", params: ["r", "k", "v"], quiet: true),
        RouteSpec(name: "mail/read", params: ["r", "k"], quiet: true),
        RouteSpec(name: "mail/archive", params: ["r", "k"], quiet: true),
        RouteSpec(name: "mail/undo", params: ["r", "k"], quiet: true),
        RouteSpec(name: "mail/star", params: ["r", "k"], quiet: true),
        RouteSpec(name: "open/event", params: ["r", "k"], quiet: false),
        RouteSpec(name: "open/message", params: ["r", "k"], quiet: false),
        RouteSpec(name: "open/day", params: ["w", "d"], quiet: false),
        RouteSpec(name: "reauth", params: ["a", "k"], quiet: false),
    ]

    private static let byName: [String: RouteSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    static func spec(_ name: String) -> RouteSpec? { byName[name] }
}

/// A parsed `yayacal://<route>?<query>` link. Only known parameters with safe values survive parsing,
/// so whatever reaches the trace or a handler is short, printable and free of PII and URLs.
struct Route: Equatable {
    /// Nil for a route this build does not know.
    let spec: RouteSpec?
    /// The route name, or a sanitized stand-in for an unknown one.
    let name: String
    let params: [String: String]

    var isKnown: Bool { spec != nil }
    /// Unknown routes do nothing, so they count as quiet: the agent hides again.
    var quiet: Bool { spec?.quiet ?? true }

    static func parse(_ url: URL) -> Route? {
        guard url.scheme?.lowercased() == RouteTable.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (components.host ?? "").lowercased()
        let path = components.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = [host, path].filter { !$0.isEmpty }.joined(separator: "/")

        guard let spec = RouteTable.spec(name) else {
            return Route(spec: nil, name: sanitizedName(name), params: [:])
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] where spec.params.contains(item.name) && params[item.name] == nil {
            if let value = item.value, isSafeValue(value) { params[item.name] = value }
        }
        return Route(spec: spec, name: spec.name, params: params)
    }

    /// Letters, digits, `.`, `_`, `-`; 1…64 characters. Covers kinds, families, dates, ids and
    /// base64url link keys; rejects anything that could carry an address, a URL or free text.
    static func isSafeValue(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { safeScalars.contains($0) }
    }

    /// Batches from one `open` event: hide afterwards only when every route in it is quiet.
    static func batchIsQuiet(_ routes: [Route]) -> Bool {
        !routes.isEmpty && routes.allSatisfy(\.quiet)
    }

    private static let safeScalars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    private static func sanitizedName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789/._-")
        guard !name.isEmpty, name.count <= 32, name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "?"
        }
        return name
    }
}

/// Builds the links widgets and the app hand to the system. The inverse of `Route.parse`.
enum YayaLink {
    static func ping(_ probe: String) -> URL { url("ping", [("probe", probe)]) }
    static func openApp(_ section: AppSection) -> URL { url("open/app", [("section", section.rawValue)]) }
    static func page(kind: String, family: String, to page: Int) -> URL {
        url("page", [("w", kind), ("fam", family), ("to", "\(page)")])
    }
    /// `day` is `YYYY-MM-DD`.
    static func day(kind: String, day: String) -> URL { url("day", [("w", kind), ("d", day)]) }
    static func openDay(kind: String, day: String) -> URL { url("open/day", [("w", kind), ("d", day)]) }
    /// `month` is `YYYY-MM`.
    static func month(kind: String, to month: String) -> URL { url("month", [("w", kind), ("to", month)]) }

    static func url(_ route: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents()
        components.scheme = RouteTable.scheme
        if let slash = route.firstIndex(of: "/") {
            components.host = String(route[..<slash])
            components.path = String(route[slash...])
        } else {
            components.host = route
        }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return components.url ?? URL(string: "\(RouteTable.scheme)://\(route)")!
    }
}
