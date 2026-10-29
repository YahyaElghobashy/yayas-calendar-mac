import Foundation

// The link to Yaya's Murmur (D-046), the add-on notetaker on the same Mac, free of AppKit so the test binary checks
// all of it: whether Murmur is installed (a handler of its URL scheme that carries its bundle id), its marks file
// (`share/murmur-marks.json` in its data folder: which events have a Live Helper, notes ready, "me only" or explicit
// consent), its three links and the badges the marks give a meeting. The calendar reads Murmur's file and never
// writes it; the live pieces (LaunchServices, the file, opening links) come in through `MurmurSession.Environment`.
// Murmur's side of the contract: its docs/CONTRACTS.md, "Calendar link".

// MARK: - Event ids

/// The one event-id rule both apps share: 1 to 128 of `A–Z a–z 0–9 _ -`. The calendar's row ids (`r`) are always
/// such ids ("e" or "g" and 22 base64url characters); anything else never goes into a link.
enum MurmurEventID {
    static let maxLength = 128

    static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maxLength else { return false }
        return id.utf8.allSatisfy { b in
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x5F || b == 0x2D
        }
    }
}

// MARK: - Presence

enum MurmurPresence {
    /// Murmur is installed when an app that handles its URL scheme carries its bundle id. Any app may claim the
    /// scheme; a look-alike or a fork under another id leaves every Murmur option hidden. `handlers` are the bundle
    /// ids of the scheme's handlers (nil for a bundle without one).
    static func isInstalled(handlers: [String?], expected: String = Profile.murmurBundleId) -> Bool {
        let want = expected.lowercased()
        return handlers.contains { id in
            guard let id, !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return id.lowercased() == want
        }
    }
}

// MARK: - Marks

/// How Murmur processes an event's call (`mode` in a mark, and the `mode` of a join link).
enum MurmurMode: String, CaseIterable, Equatable {
    case homelab
    case macbook

    /// The words in the Join menu and on the status line.
    var title: String {
        switch self {
        case .homelab: return "Home lab"
        case .macbook: return "MacBook"
        }
    }

    /// "Records on the home lab".
    var place: String {
        switch self {
        case .homelab: return "on the home lab"
        case .macbook: return "on this MacBook"
        }
    }
}

/// One event's mark: Murmur's own choices for a calendar event. Nil fields are absent or unreadable.
struct MurmurMark: Equatable {
    enum HelperKind: Equatable {
        case clientMeeting, interview, discussion
        /// A kind this calendar doesn't know yet (Murmur may add some): the Live Helper is on all the same.
        case other

        var title: String {
            switch self {
            case .clientMeeting: return "Client meeting"
            case .interview: return "Interview"
            case .discussion: return "Discussion"
            case .other: return "Live Helper"
            }
        }
    }
    enum Consent: String, Equatable { case notice, explicit }
    enum Status: String, Equatable { case notesReady, meOnly }

    var helper: HelperKind?
    var mode: MurmurMode?
    var consent: Consent?
    var status: Status?
    var updatedAt: Date?

    /// The badges this mark gives its meeting, in this order.
    var badges: [MurmurBadge] {
        var out: [MurmurBadge] = []
        if helper != nil { out.append(.liveHelper) }
        if status == .notesReady { out.append(.notesReady) }
        if status == .meOnly { out.append(.meOnly) }
        if consent == .explicit { out.append(.explicitConsent) }
        return out
    }
}

/// The badges on a meeting's row and in its Event Peek. Murmur's own colours, used for these badges only: lime for
/// what Murmur does (Live Helper, Notes ready), pink for privacy (Me only, Explicit consent).
enum MurmurBadge: String, CaseIterable, Identifiable, Equatable {
    case liveHelper, notesReady, meOnly, explicitConsent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveHelper: return "Live Helper"
        case .notesReady: return "Notes ready"
        case .meOnly: return "Me only"
        case .explicitConsent: return "Explicit consent"
        }
    }

    /// Lime `#C6F36B` or pink `#FF9EEA` (Murmur's design colours).
    var isLime: Bool { self == .liveHelper || self == .notesReady }
    static let lime: UInt32 = 0xC6F36B
    static let pink: UInt32 = 0xFF9EEA
    var hex: UInt32 { isLime ? Self.lime : Self.pink }

    var symbol: String {
        switch self {
        case .liveHelper: return "sparkles"
        case .notesReady: return "doc.text"
        case .meOnly: return "person.fill"
        case .explicitConsent: return "hand.raised.fill"
        }
    }
}

/// Murmur's marks file, v1. Read with care: Murmur is another app, so every field is checked, a mark that fails is
/// skipped, and anything unexpected reads as "no marks" (never an error the person has to deal with).
enum MurmurMarks {
    /// The file Murmur writes in its data folder (`<murmurDataRoot>/share/`).
    static let fileName = "murmur-marks.json"
    static let shareFolder = "share"
    /// Murmur keeps at most 500 marks (about 200 bytes each): 256 KB is room to spare, and a bigger file is refused
    /// before it is read.
    static let fileLimit = 256 * 1024
    static let markLimit = 500
    /// Posted by Murmur (DistributedNotificationCenter, no object, no userInfo) after each write and on its uninstall.
    static var changedNotification: String { Profile.murmurBundleId + ".marksChanged" }

    enum State: Equatable {
        /// No file: Murmur isn't sharing anything (or was removed).
        case missing
        /// A file that fails the checks: shown as "no marks".
        case unreadable
        /// `v` above 1: a newer Murmur; ignored until this app understands it.
        case newer
        /// Event id → mark; `skipped` counts marks that failed their checks.
        case ready([String: MurmurMark], skipped: Int)

        var marks: [String: MurmurMark] {
            if case .ready(let m, _) = self { return m }
            return [:]
        }
    }

    static func parse(_ data: Data?) -> State {
        guard let data else { return .missing }
        guard data.count <= fileLimit,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        guard let v = integer(object["v"]) else { return .unreadable }
        if v > 1 { return .newer }
        guard v == 1, let raw = object["marks"] as? [String: Any] else { return .unreadable }
        var marks: [String: MurmurMark] = [:]
        var skipped = 0
        for (id, value) in raw {
            guard MurmurEventID.isValid(id), let fields = value as? [String: Any] else { skipped += 1; continue }
            marks[id] = mark(fields)
        }
        if marks.count > markLimit {
            // Murmur drops its oldest marks past 500; a file with more keeps the newest 500 here too.
            let keep = marks.sorted { a, b in
                let ta = a.value.updatedAt ?? .distantPast, tb = b.value.updatedAt ?? .distantPast
                return ta != tb ? ta > tb : a.key < b.key
            }.prefix(markLimit)
            skipped += marks.count - markLimit
            marks = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return .ready(marks, skipped: skipped)
    }

    /// One mark's fields. A field of the wrong type or with an unknown value reads as absent; unknown keys are ignored.
    static func mark(_ f: [String: Any]) -> MurmurMark {
        var m = MurmurMark()
        if let kind = f["liveHelperKind"] as? String {
            switch kind {
            case "clientMeeting": m.helper = .clientMeeting
            case "interview": m.helper = .interview
            case "discussion": m.helper = .discussion
            default:
                // A newer kind (letters only, short): the helper is on; anything else is not a kind.
                if (1...32).contains(kind.utf8.count), kind.utf8.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }) {
                    m.helper = .other
                }
            }
        }
        if let mode = f["mode"] as? String { m.mode = MurmurMode(rawValue: mode) }
        if let tier = f["consentTier"] as? String { m.consent = MurmurMark.Consent(rawValue: tier) }
        if let status = f["status"] as? String { m.status = MurmurMark.Status(rawValue: status) }
        if let at = f["updatedAt"] as? String { m.updatedAt = date(at) }
        return m
    }

    /// A JSON integer (not a boolean, not a fraction).
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        return plainDates.date(from: text) ?? fractionalDates.date(from: text)
    }

    // ISO8601DateFormatter is thread-safe; the file may be read off the main thread.
    nonisolated(unsafe) private static let plainDates = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalDates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Links

/// Murmur's links (its docs/CONTRACTS.md, "URL scheme"), built only from a valid event id and Murmur's own words:
/// `join?event=<id>[&mode=homelab|macbook]`, `helper?event=<id>`, `open?event=<id>`. Murmur parses them strictly
/// (exact scheme and host, no path, at most 512 bytes) and arms itself for that event.
enum MurmurLinks {
    static let maxBytes = 512

    static func join(event: String, mode: MurmurMode?, scheme: String = Profile.murmurScheme) -> URL? {
        var items = [URLQueryItem(name: "event", value: event)]
        if let mode { items.append(URLQueryItem(name: "mode", value: mode.rawValue)) }
        return build(scheme, "join", event, items)
    }

    static func helper(event: String, scheme: String = Profile.murmurScheme) -> URL? {
        build(scheme, "helper", event, [URLQueryItem(name: "event", value: event)])
    }

    static func open(event: String, scheme: String = Profile.murmurScheme) -> URL? {
        build(scheme, "open", event, [URLQueryItem(name: "event", value: event)])
    }

    private static func build(_ scheme: String, _ host: String, _ event: String, _ items: [URLQueryItem]) -> URL? {
        guard MurmurEventID.isValid(event) else { return nil }
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.queryItems = items
        guard let url = c.url, url.absoluteString.utf8.count <= maxBytes else { return nil }
        return url
    }
}

// MARK: - The session

/// What the app's surfaces need from Murmur: whether it's installed, the marks, and the three links. One shared
/// instance in the app (its live side is `MurmurLive`); renders and tests make their own with fakes.
@MainActor
final class MurmurSession: ObservableObject {
    static var shared = MurmurSession()

    struct Environment {
        var installed: () -> Bool = { false }
        /// The marks as last read (the live side re-reads the file when it changed).
        var marks: () -> MurmurMarks.State = { .missing }
        var open: (URL) -> Bool = { _ in false }
        /// Runs the work after the delay (the meeting opens just after Murmur's join link).
        var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { _, work in work() }
    }

    enum Outcome: Equatable {
        /// Murmur's join link and the meeting opened.
        case started
        /// The meeting opened, but Murmur's link did not.
        case joinedOnly
        /// No allowlisted join link, or no valid event id.
        case blocked
        /// Murmur isn't on this Mac.
        case notInstalled
    }

    /// Murmur's link goes first, so it is armed when the call starts.
    static let meetingDelay: TimeInterval = 0.6

    @Published private(set) var installed = false
    @Published private(set) var marks: MurmurMarks.State = .missing
    var env: Environment

    init(env: Environment = Environment()) {
        self.env = env
    }

    /// Reads Murmur's state again (surfaces call it when they load; the live side calls it after a ping).
    func refresh() {
        installed = env.installed()
        let next = installed ? env.marks() : .missing
        if next != marks { marks = next }
    }

    func mark(_ r: String) -> MurmurMark? {
        guard installed else { return nil }
        return marks.marks[r]
    }

    /// The meeting's badges (none while Murmur isn't installed).
    func badges(_ r: String) -> [MurmurBadge] { mark(r)?.badges ?? [] }

    /// Join with Yaya's Murmur: its join link for this event, then the meeting. `mode` nil leaves it to Murmur (its
    /// Settings, or this event's own mark).
    @discardableResult
    func join(_ event: CalendarEvent, mode: MurmurMode?, via: String) -> Outcome {
        refresh()
        guard installed else { trace("join", via, "not-installed"); return .notInstalled }
        guard let meeting = event.joinURL, JoinPolicy.isAllowed(meeting),
              let link = MurmurLinks.join(event: event.r, mode: mode) else {
            trace("join", via, "blocked")
            return .blocked
        }
        let armed = env.open(link)
        env.after(Self.meetingDelay) { [env] in _ = env.open(meeting) }
        trace("join", via, armed ? "started" : "link-failed")
        return armed ? .started : .joinedOnly
    }

    /// Join with Live Helper (D-048 on Up Next, D-049 on the popover card): for a meeting Murmur marked Live Helper, its
    /// join link with no mode (Live Helper records on the MacBook whatever the mark's mode; Murmur's BND-21 brings the
    /// marked chat to the call the link armed), then the meeting, whatever the account's recorder. The marks are read
    /// again first. nil: not marked (any more) or Murmur isn't here, and nothing opened; the caller takes its
    /// recorder's path.
    func joinLiveHelper(_ event: CalendarEvent, via: String) -> Outcome? {
        refresh()
        guard mark(event.r)?.helper != nil else {
            trace("livehelper", via, installed ? "unmarked" : "not-installed")
            return nil
        }
        return join(event, mode: nil, via: via)
    }

    /// "Live Helper for this meeting" and "Set up…": Murmur's helper setup for the event (Murmur owns the choice and
    /// writes the mark; the Peek redraws on its ping).
    @discardableResult
    func openHelper(_ event: CalendarEvent, via: String) -> Bool {
        open(MurmurLinks.helper(event: event.r), "helper", via)
    }

    /// "Open notes": the event's meeting in Murmur's library.
    @discardableResult
    func openNotes(_ event: CalendarEvent, via: String) -> Bool {
        open(MurmurLinks.open(event: event.r), "open", via)
    }

    private func open(_ link: URL?, _ what: String, _ via: String) -> Bool {
        refresh()
        guard installed, let link else { trace(what, via, installed ? "blocked" : "not-installed"); return false }
        let ok = env.open(link)
        trace(what, via, ok ? "opened" : "failed")
        return ok
    }

    /// Outcomes only: never an event id, a title or a link.
    private func trace(_ action: String, _ via: String, _ result: String) {
        Trace.app("murmur", ["action": action, "via": via, "result": result])
    }

    /// Settings → Yaya's Murmur: what its marks file says.
    var statusLine: String {
        guard installed else { return "Yaya\u{2019}s Murmur isn\u{2019}t on this Mac." }
        switch marks {
        case .missing: return "Installed. It hasn\u{2019}t marked any meetings yet."
        case .unreadable: return "Installed, but I can\u{2019}t read its marks file, so I show no badges."
        case .newer: return "Installed, with a newer marks format than I understand. Update Yaya\u{2019}s Calendar to see its badges."
        case .ready(let m, _):
            return m.isEmpty ? "Installed. It hasn\u{2019}t marked any meetings yet."
                : "Installed. \(m.count) meeting\(m.count == 1 ? "" : "s") marked (Live Helper, notes, consent)."
        }
    }
}
