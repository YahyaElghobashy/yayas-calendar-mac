import Foundation

// The router's decisions, free of AppKit so the test binary checks every one of them: what a parsed
// link asks for (after validating every parameter and every link key), whether to hide afterwards, and
// whether to hand the front back to the app the user was in (an early build restored it only 3 of 8 times).

/// What one `yayacal://` link asks the agent to do.
enum RouteAction: Equatable {
    case ping(String)
    case openApp(AppSection?)
    /// `open/app?section=mailhelper&tab=digest[&part=<section>]` (D-053): the Mail helper's Digest tab, at that section.
    case openDigest(part: String?)
    /// `open/atlas` (D-054): Model Atlas's weekly report in the person's Markdown app.
    case openAtlas
    case reauth(account: String)
    case page(kind: String, family: String, to: Int)
    case selectDay(kind: String, day: String)
    case showMonth(kind: String, month: String)
    case setRange(kind: String, days: Int)
    /// `sync`: every account (nil), or `sync?w=<kind>`: a widget's ↻ (that widget's accounts, a full
    /// re-list, then that widget reloads).
    case sync(kind: String?)
    case join(r: String)
    /// Join with Fathom (D-045): records at once, or the Event Peek waits for Fathom to switch accounts.
    case record(r: String)
    /// Join with Live Helper (D-048): Yaya's Murmur joins a meeting it marked Live Helper, whatever the account's recorder.
    case liveHelper(r: String)
    case rsvp(r: String, response: CalendarEvent.Response)
    case openEvent(r: String)
    case openDay(kind: String, day: String)
    /// Mail rows (thread `r`): mark read, archive, undo the last archive/trash, star toggle, Mail Peek.
    case mailRead(r: String)
    case mailArchive(r: String)
    case mailUndo(r: String)
    case mailStar(r: String)
    case openMessage(r: String)
    /// A route in the table that the decider has no case for (none today): traced, ignored.
    case unhandled(route: String)
    /// Missing or invalid parameter, unknown kind, failed link key: traced, ignored.
    case ignore(route: String, reason: String)

    /// The trace name ("join", "ignore"…).
    var name: String {
        switch self {
        case .ping: return "ping"
        case .openApp, .openDigest: return "open/app"
        case .openAtlas: return "open/atlas"
        case .reauth: return "reauth"
        case .page: return "page"
        case .selectDay: return "day"
        case .showMonth: return "month"
        case .setRange: return "range"
        case .sync: return "sync"
        case .join: return "join"
        case .record: return "record"
        case .liveHelper: return "livehelper"
        case .rsvp: return "rsvp"
        case .openEvent: return "open/event"
        case .openDay: return "open/day"
        case .mailRead: return "mail/read"
        case .mailArchive: return "mail/archive"
        case .mailUndo: return "mail/undo"
        case .mailStar: return "mail/star"
        case .openMessage: return "open/message"
        case .unhandled: return "unhandled"
        case .ignore: return "ignore"
        }
    }
}

enum RouteDecider {
    static let families: Set<String> = ["S", "M", "L", "XL", "XLP"]
    static let ranges: Set<Int> = [1, 2, 7]
    static let maxPage = 99

    /// `verify(r, k)` is `Services.widgetInteractions.verify` (constant-time HMAC check, data layer).
    /// `mailEnabled` off (tests only; mail is always on in the app, D-029): mail links are ignored.
    static func decide(_ route: Route, mailEnabled: Bool = true, verify: (String, String) -> Bool) -> RouteAction {
        guard let spec = route.spec else { return .ignore(route: route.name, reason: "unknown-route") }
        let p = route.params
        func ignore(_ reason: String) -> RouteAction { .ignore(route: spec.name, reason: reason) }

        /// The kind must be one of the 12 (WidgetKinds.all) and support the family when one is given.
        func kind(family: String? = nil) -> WidgetKindSpec? {
            guard let w = p["w"], let spec = WidgetKinds.spec(w) else { return nil }
            if let family, !spec.families.contains(where: { $0.short == family }) { return nil }
            return spec
        }

        /// Row-keyed routes: both present and the key verifies.
        enum KeyCheck { case ok(String), missing, bad }
        func keyed(_ idName: String = "r") -> KeyCheck {
            guard let r = p[idName], let k = p["k"] else { return .missing }
            return verify(r, k) ? .ok(r) : .bad
        }

        switch spec.name {
        case "ping":
            return .ping(p["probe"] ?? "-")
        case "open/atlas":
            return .openAtlas
        case "open/app":
            let section = p["section"].flatMap(AppSection.init(rawValue:))
            if section == .mailHelper, p["tab"] == "digest" { return .openDigest(part: p["part"]) }
            return .openApp(section)
        case "reauth":
            switch keyed("a") {
            case .ok(let a): return .reauth(account: a)
            case .missing: return ignore("missing-param")
            case .bad: return ignore("bad-key")
            }
        case "page":
            guard let fam = p["fam"], families.contains(fam) else { return ignore("bad-family") }
            guard let spec = kind(family: fam) else { return ignore("bad-kind") }
            guard let to = p["to"].flatMap(Int.init), (1...maxPage).contains(to) else { return ignore("bad-page") }
            return .page(kind: spec.kind, family: fam, to: to)
        case "day", "open/day":
            guard let spec = kind() else { return ignore("bad-kind") }
            guard let d = p["d"], DayName.parseDay(d) != nil else { return ignore("bad-day") }
            return route.name == "day" ? .selectDay(kind: spec.kind, day: d) : .openDay(kind: spec.kind, day: d)
        case "month":
            guard let spec = kind() else { return ignore("bad-kind") }
            guard let to = p["to"], DayName.parseMonth(to) != nil else { return ignore("bad-month") }
            return .showMonth(kind: spec.kind, month: to)
        case "range":
            guard let spec = kind() else { return ignore("bad-kind") }
            guard let v = p["v"].flatMap(Int.init), ranges.contains(v) else { return ignore("bad-range") }
            return .setRange(kind: spec.kind, days: v)
        case "sync":
            guard p["w"] != nil else { return .sync(kind: nil) }
            guard let spec = kind() else { return ignore("bad-kind") }
            return .sync(kind: spec.kind)
        case "join", "record", "livehelper", "open/event":
            switch keyed() {
            case .ok(let r):
                switch route.name {
                case "join": return .join(r: r)
                case "record": return .record(r: r)
                case "livehelper": return .liveHelper(r: r)
                default: return .openEvent(r: r)
                }
            case .missing: return ignore("missing-param")
            case .bad: return ignore("bad-key")
            }
        case "rsvp":
            guard let response = p["v"].flatMap(rsvpResponse) else { return ignore("bad-reply") }
            switch keyed() {
            case .ok(let r): return .rsvp(r: r, response: response)
            case .missing: return ignore("missing-param")
            case .bad: return ignore("bad-key")
            }
        case "mail/read", "mail/archive", "mail/undo", "mail/star", "open/message":
            guard mailEnabled else { return ignore("mail-off") }
            switch keyed() {
            case .ok(let r):
                switch spec.name {
                case "mail/read": return .mailRead(r: r)
                case "mail/archive": return .mailArchive(r: r)
                case "mail/undo": return .mailUndo(r: r)
                case "mail/star": return .mailStar(r: r)
                default: return .openMessage(r: r)
                }
            case .missing: return ignore("missing-param")
            case .bad: return ignore("bad-key")
            }
        default:
            return .unhandled(route: spec.name)
        }
    }

    /// `v` of `rsvp`: yes | maybe | no (the Google words work too).
    static func rsvpResponse(_ v: String) -> CalendarEvent.Response? {
        switch v.lowercased() {
        case "yes", "accepted", "accept": return .accepted
        case "maybe", "tentative": return .tentative
        case "no", "declined", "decline": return .declined
        default: return nil
        }
    }
}

/// A widget's ↻ (`sync?w=<kind>`) runs at most once per kind every `window` seconds: a double tap (or a
/// second click while the first refresh is still syncing) is ignored and traced, so it can't sync twice.
struct RefreshDebounce {
    static let window: TimeInterval = 5
    private(set) var last: [String: Date] = [:]

    /// True when this refresh should run (and remembers it); false for a repeat inside the window.
    mutating func admit(_ kind: String, at now: Date) -> Bool {
        if let previous = last[kind], now >= previous, now.timeIntervalSince(previous) < Self.window { return false }
        last[kind] = now
        return true
    }
}

/// How long a refresh may hold the hand-back (the agent stays active, so the tapped widget's reload is
/// asked while it is: free and unthrottled). A slower sync hands back anyway and reloads when it ends.
enum RefreshPolicy {
    static let handBackCap: TimeInterval = 5
}

/// Join links open only for https on the allowlist (Meet, Zoom, Teams, Webex, Whereby, Slack, GoTo,
/// Chime, Jitsi), checked again here even though the data layer filtered them already.
enum JoinPolicy {
    static let hosts = [
        "meet.google.com", "zoom.us", "zoomgov.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "whereby.com", "slack.com", "gotomeeting.com", "goto.com", "gotomeet.me", "chime.aws", "meet.jit.si",
    ]

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty
        else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// "Google Meet", "Zoom"… for the Peek's big Join button.
    static func providerName(_ url: URL?) -> String? {
        guard isAllowed(url), let host = url?.host?.lowercased() else { return nil }
        let names: [(String, String)] = [
            ("meet.google.com", "Google Meet"), ("zoom.us", "Zoom"), ("zoomgov.com", "Zoom"),
            ("teams.microsoft.com", "Teams"), ("teams.live.com", "Teams"), ("webex.com", "Webex"),
            ("whereby.com", "Whereby"), ("slack.com", "Slack"), ("gotomeeting.com", "GoTo"), ("goto.com", "GoTo"),
            ("gotomeet.me", "GoTo"), ("chime.aws", "Chime"), ("meet.jit.si", "Jitsi"),
        ]
        return names.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
    }
}

/// The router's `flushChanged()` after a batch of links (D-019): each batch pushes it back and it
/// runs `delay` after the last one, so other kinds' renders don't compete with the tapped kind's. A
/// quit inside the delay runs it at once (`runPending`, from `applicationWillTerminate`) instead of
/// dropping the reloads it would have asked for.
@MainActor
final class DeferredFlush {
    let delay: TimeInterval
    private let flush: () -> Void
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval, flush: @escaping () -> Void) {
        self.delay = delay
        self.flush = flush
    }

    var isPending: Bool { pending != nil }

    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Runs a pending flush now. Returns whether one was pending.
    @discardableResult
    func runPending() -> Bool {
        guard pending != nil else { return false }
        fire()
        return true
    }

    private func fire() {
        pending?.cancel()
        pending = nil
        flush()
    }
}

/// When to give the front back after a quiet batch (D-019). A real widget click activates the
/// agent before the link arrives (`activeAtReceipt`); waiting 250 ms after the work, then
/// re-activating the previous app, kept desktop widgets dimmed for about half a second per tap. When
/// the link just activated a warm agent, hand back right after the work (the timeline reload is already
/// issued, while still active); a cold launch, or a link that arrived before the activation, keeps the
/// 250 ms check (`HidePolicy`).
enum HandBackPolicy {
    /// One-line switch: false restores the 250 ms hide for every quiet batch.
    nonisolated(unsafe) static var immediate = true

    enum When: Equatable {
        /// Hand back now, then hide.
        case now
        /// Check again in 250 ms (HidePolicy decides).
        case later
    }

    static func when(isActive: Bool, cold: Bool, activeAtReceipt: Bool, sinceActivation: TimeInterval,
                     immediate: Bool = HandBackPolicy.immediate) -> When {
        guard immediate, !cold, activeAtReceipt, isActive, sinceActivation < HidePolicy.freshActivation else { return .later }
        return .now
    }
}

/// When a link brought the agent forward, quiet routes hide it again (250 ms later) so the user's app
/// comes back; `open -g` probes never activate it.
enum HidePolicy {
    /// Activated this recently = by the link (not a user already working in our window).
    static let freshActivation: TimeInterval = 1.5

    /// - `cold`: launched by this link (< 4 s ago).
    /// - `sinceActivation`: seconds since the agent last became active.
    static func shouldHide(isActive: Bool, cold: Bool, activeAtReceipt: Bool, sinceActivation: TimeInterval) -> Bool {
        isActive && (cold || !activeAtReceipt || sinceActivation < freshActivation)
    }
}

/// The last app that was frontmost before the agent. NSWorkspace activation notifications feed
/// it; our own activations are ignored, so after a widget tap it still names the user's app.
struct FrontAppMemory: Equatable {
    let ownPid: Int32
    private(set) var lastPid: Int32?
    private(set) var lastBundleId: String?

    init(ownPid: Int32) { self.ownPid = ownPid }

    mutating func didActivate(pid: Int32, bundleId: String?) {
        guard pid > 0, pid != ownPid else { return }
        lastPid = pid
        lastBundleId = bundleId
    }

    mutating func didTerminate(pid: Int32) {
        guard pid == lastPid else { return }
        lastPid = nil
        lastBundleId = nil
    }

    /// The app to hand the front back to, if it's still running.
    func target(isRunning: (Int32) -> Bool) -> Int32? {
        guard let lastPid, lastPid != ownPid, isRunning(lastPid) else { return nil }
        return lastPid
    }
}

enum FrontRestorePolicy {
    /// After a quiet batch the agent hid itself (or a Peek is showing and the link activated it):
    /// re-activate the user's app unless it is already in front.
    static func shouldRestore(agentWasActivated: Bool, target: Int32?, frontmost: Int32?) -> Bool {
        guard agentWasActivated, let target else { return false }
        return frontmost != target
    }

    /// What the router does after a batch of links, by what the routes ended up doing. `handedOff`: a
    /// Join opened the meeting in its app, which takes the front itself (restoring the previous app
    /// would fight it).
    enum Outcome: Equatable { case quiet, peek, window, handedOff, nothing }

    enum Follow: Equatable {
        /// Hide (if the link activated us) and give the front back.
        case hideAndRestore
        /// A Peek is up: give the front back so desktop widgets regain colour, keep the panel.
        case restoreKeepPeek
        /// A window opened (Accounts, Widgets…), or a Join handed the front to the meeting: stay.
        case stay
    }

    static func follow(_ outcomes: [Outcome]) -> Follow {
        if outcomes.contains(.window) || outcomes.contains(.handedOff) { return .stay }
        if outcomes.contains(.peek) { return .restoreKeepPeek }
        return outcomes.isEmpty ? .stay : .hideAndRestore
    }
}
