import Foundation

// Join with Fathom (D-045), free of AppKit so the test binary checks all of it: which Fathom account a meeting
// records to (each connected account links to one, by its sign-in address), which account the Fathom app on this
// Mac is signed into, and what a Join with Fathom does when the two differ. The live pieces (reading Fathom's
// file, opening links, the clock) come in through `FathomSession.Environment`; renders and tests pass fakes.

// MARK: - Preferences

/// Which Fathom account an account's meetings record to. Stored per account in the preferences:
/// absent = the account's own address, "off", or "addr:<address>".
enum FathomLink: Equatable {
    case ownAddress
    case address(String)
    case off

    /// The Fathom sign-in address for an account whose own address is `accountEmail`; nil when off.
    func email(account accountEmail: String) -> String? {
        switch self {
        case .ownAddress: return FathomAddress.normalized(accountEmail)
        case .address(let a): return FathomAddress.normalized(a)
        case .off: return nil
        }
    }

    var stored: String? {
        switch self {
        case .ownAddress: return nil
        case .off: return "off"
        case .address(let a): return FathomAddress.normalized(a).map { "addr:" + $0 }
        }
    }

    init(stored: String?) {
        guard let stored else { self = .ownAddress; return }
        if stored == "off" { self = .off; return }
        if stored.hasPrefix("addr:"), let a = FathomAddress.normalized(String(stored.dropFirst(5))) {
            self = .address(a)
            return
        }
        self = .ownAddress
    }
}

enum FathomAddress {
    /// Lowercased and trimmed; nil unless it looks like one address (one @, a dot after it, no spaces, ≤ 254).
    static func normalized(_ raw: String) -> String? {
        let a = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard a.count <= 254, !a.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }) else { return nil }
        let parts = a.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return nil }
        return a
    }
}

enum FathomPrefs {
    static let hotkeyKey = "fathom.hotkeyRecords"
    /// Posted (default center) when a link or the ⌃⌥J switch changes: the widgets republish, open surfaces reload.
    static let changed = Notification.Name("YCFathomPrefsChanged")

    static func linkKey(_ account: UUID) -> String { "fathom.link." + account.uuidString }

    static func link(_ account: UUID, _ bag: PreferenceBag = DefaultsBag.shared) -> FathomLink {
        FathomLink(stored: bag.object(linkKey(account)) as? String)
    }

    static func setLink(_ link: FathomLink, for account: UUID, _ bag: PreferenceBag = DefaultsBag.shared) {
        bag.set(link.stored, linkKey(account))
    }

    /// ⌃⌥J records with Fathom when the meeting's account has one linked (Settings; off by default).
    static func hotkeyRecords(_ bag: PreferenceBag = DefaultsBag.shared) -> Bool {
        (bag.object(hotkeyKey) as? Bool) ?? false
    }

    static func setHotkeyRecords(_ on: Bool, _ bag: PreferenceBag = DefaultsBag.shared) {
        bag.set(on ? true : nil, hotkeyKey)
    }
}

// MARK: - Which account Fathom is signed into

/// The Fathom app's own record of its signed-in account: `bridge-config.json` in its data folder names it
/// (`account.userId`, `account.email`) and the Chrome bridge manifest it writes for that account carries the id.
/// Both are Fathom's, undocumented, and rewritten when its account changes; when they disagree or either is
/// missing, the answer is `.unknown` and the app asks before recording.
enum FathomSignIn: Equatable {
    case signedIn(String)
    case signedOut
    case unknown

    static let configLimit = 64 * 1024
    static let hostPrefix = "video.fathom.chrome_extension_bridge"

    /// `config`: the bytes of `bridge-config.json` (nil = missing or unreadable). `manifests`: the file names in
    /// Chrome's NativeMessagingHosts folder (nil = unreadable).
    static func parse(config: Data?, manifests: [String]?) -> FathomSignIn {
        guard let config, config.count <= configLimit,
              let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              object.keys.contains("account") else { return .unknown }
        if object["account"] is NSNull { return .signedOut }
        guard let account = object["account"] as? [String: Any],
              let userId = (account["userId"] as? NSNumber)?.int64Value,
              let raw = account["email"] as? String, let email = FathomAddress.normalized(raw) else { return .unknown }
        let host = "\(hostPrefix).\(userId)"
        if let named = object["hostName"] as? String, named != host { return .unknown }
        guard let manifests, manifests.contains(host + ".json") else { return .unknown }
        return .signedIn(email)
    }
}

/// One Fathom account a meeting can record to: a connected account that has the meeting, and its link.
struct FathomTarget: Equatable, Identifiable {
    var id: UUID { accountId }
    let accountId: UUID
    let tag: String
    let email: String
}

/// Whether a Join with Fathom for `target` would record in the right place right now.
enum FathomCheck: Equatable {
    case ready
    /// Fathom is signed into another account (its address).
    case otherAccount(String)
    case signedOut
    case unknown

    static func of(_ target: FathomTarget, _ signIn: FathomSignIn) -> FathomCheck {
        switch signIn {
        case .signedIn(let email): return email == target.email ? .ready : .otherAccount(email)
        case .signedOut: return .signedOut
        case .unknown: return .unknown
        }
    }
}

enum FathomRouting {
    /// Every account that has the meeting and records with Fathom, primary copy first, one per Fathom address.
    static func targets(_ event: CalendarEvent, directory: AccountDirectory, link: (UUID) -> FathomLink) -> [FathomTarget] {
        var seen = Set<String>()
        var out: [FathomTarget] = []
        for id in event.accountIds {
            guard let account = directory.account(id), let email = link(id).email(account: account.email),
                  seen.insert(email).inserted else { continue }
            out.append(FathomTarget(accountId: id, tag: account.tag.isEmpty ? account.name : account.tag, email: email))
        }
        return out
    }

    /// A widget's Fathom button: the meeting has a join link and one of its accounts records with Fathom.
    static func offered(accountIds: [UUID], hasJoin: Bool, link: (UUID) -> FathomLink) -> Bool {
        hasJoin && accountIds.contains { link($0) != .off }
    }

    /// How the surfaces name an address: the tag of the account whose Fathom link it is, else the address.
    static func label(_ email: String, directory: AccountDirectory, link: (UUID) -> FathomLink) -> String {
        directory.accounts.first { link($0.id).email(account: $0.email) == email }.map { $0.tag.isEmpty ? $0.name : $0.tag } ?? email
    }
}

/// Fathom's own links: `fathom://start-capture?url=<meeting>` asks the signed-in Fathom app to capture that
/// meeting (undocumented; a Fathom setting can turn the start off, then its live panel opens instead), and
/// `fathom://open-app` brings its window up so the person can switch accounts.
enum FathomURLs {
    static let bundleId = "video.fathom.electron"
    static let openApp = URL(string: "fathom://open-app")!

    static func startCapture(meeting: URL) -> URL? {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard JoinPolicy.isAllowed(meeting),
              let value = meeting.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "fathom://start-capture?url=" + value)
    }
}

// MARK: - Words

enum FathomText {
    enum Tone: Equatable { case ok, warn, quiet }

    /// The line under a Join with Fathom button.
    static func status(_ target: FathomTarget, _ check: FathomCheck, label: (String) -> String) -> (text: String, tone: Tone) {
        switch check {
        case .ready: return ("Records to \(target.email)", .ok)
        case .otherAccount(let email): return ("Fathom is signed in as \(label(email)), not \(target.tag)", .warn)
        case .signedOut: return ("Fathom isn\u{2019}t signed in", .warn)
        case .unknown: return ("I can\u{2019}t tell which account Fathom is on", .quiet)
        }
    }

    struct Wait: Equatable {
        let title: String
        let body: String
        /// "Open Fathom", "Record anyway" or "Try again".
        let primary: String
    }

    /// What the switch panel says, by what Fathom is doing. `current` names an address (a tag when it is one of
    /// the links).
    static func wait(_ p: FathomSession.Pending, current: (String) -> String) -> Wait {
        let t = p.target
        if p.phase == .timedOut {
            return Wait(title: "Fathom didn\u{2019}t switch",
                        body: "It\u{2019}s still not on \(t.tag) (\(t.email)). Switch it, then try again, or join without recording.",
                        primary: "Try again")
        }
        switch p.check {
        case .otherAccount(let email):
            return Wait(title: "Switch Fathom to \(t.tag)",
                        body: "Fathom is signed in as \(current(email)). Sign out there and in as \(t.email). I\u{2019}ll join and start recording as soon as it switches.",
                        primary: "Open Fathom")
        case .signedOut:
            return Wait(title: "Sign Fathom in as \(t.tag)",
                        body: "Fathom isn\u{2019}t signed in. Sign in as \(t.email) and I\u{2019}ll join and start recording as soon as you do.",
                        primary: "Open Fathom")
        case .unknown, .ready:
            return Wait(title: "Which account is Fathom on?",
                        body: "I can\u{2019}t tell which account Fathom is signed into, so I can\u{2019}t promise this lands in \(t.tag)\u{2019}s Fathom (\(t.email)).",
                        primary: "Record anyway")
        }
    }

    /// "2:51 left" for the wait (headless renders and VoiceOver).
    static func left(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return "\(s / 60):" + String(format: "%02d", s % 60) + " left"
    }
}

/// How the switch panel's own buttons ended a wait (the Event Peek closes or measures itself again).
enum FathomDone { case recorded, joined, cancelled, resized }

// MARK: - The session

/// One Join with Fathom at a time: records at once when Fathom is on the meeting's account, else waits (at most
/// `waitLimit`) for Fathom to switch and records then, without asking again. The popover and the Event Peek draw
/// `pending`; the widget's Fathom button, ⌃⌥J and the heads-up open the Event Peek when it waits.
@MainActor
final class FathomSession: ObservableObject {
    static var shared = FathomSession()

    struct Environment {
        var installed: () -> Bool = { false }
        var signIn: () -> FathomSignIn = { .unknown }
        var link: (UUID) -> FathomLink = { FathomPrefs.link($0) }
        var open: (URL) -> Bool = { _ in false }
        /// Runs the work after the delay (the meeting opens just after Fathom's capture link).
        var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { _, work in work() }
        /// Calls `tick` every second while a wait runs; returns its stop.
        var every: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { _, _ in {} }
        var clock: () -> Date = { Date() }
    }

    struct Pending: Equatable {
        enum Phase: Equatable { case waiting, timedOut }
        let event: CalendarEvent
        let target: FathomTarget
        var check: FathomCheck
        var deadline: Date
        var phase: Phase
        var r: String { event.r }
    }

    enum Outcome: Equatable {
        /// Fathom's capture link and the meeting opened.
        case started
        /// Fathom is on another account (or can't be read): `pending` is set and the surfaces ask.
        case waiting
        /// No allowlisted join link, or nothing opened.
        case blocked
        /// None of the meeting's accounts records with Fathom (or Fathom isn't on this Mac).
        case notLinked
    }

    static let waitLimit: TimeInterval = 180
    /// Fathom's capture link goes first, so it is waiting when its browser extension sees the meeting open.
    static let meetingDelay: TimeInterval = 0.6

    @Published private(set) var pending: Pending?
    @Published private(set) var signIn: FathomSignIn = .unknown
    @Published private(set) var installed = false

    var env: Environment
    private var stopTicker: (() -> Void)?

    init(env: Environment = Environment()) {
        self.env = env
    }

    /// Reads Fathom's state again (surfaces call it when they load).
    func refresh() {
        installed = env.installed()
        signIn = installed ? env.signIn() : .unknown
    }

    func targets(_ event: CalendarEvent, directory: AccountDirectory) -> [FathomTarget] {
        guard installed, JoinPolicy.isAllowed(event.joinURL) else { return [] }
        return FathomRouting.targets(event, directory: directory, link: env.link)
    }

    func check(_ target: FathomTarget) -> FathomCheck { FathomCheck.of(target, signIn) }

    func label(_ email: String, directory: AccountDirectory) -> String {
        FathomRouting.label(email, directory: directory, link: env.link)
    }

    /// Join with Fathom. `target` nil = the meeting's first linked account (primary copy first).
    @discardableResult
    func join(_ event: CalendarEvent, target chosen: FathomTarget? = nil, directory: AccountDirectory, via: String) -> Outcome {
        refresh()
        guard JoinPolicy.isAllowed(event.joinURL) else { trace(via, "blocked"); return .blocked }
        let all = targets(event, directory: directory)
        guard let target = chosen.flatMap({ c in all.first { $0 == c } }) ?? all.first else {
            trace(via, "not-linked")
            return .notLinked
        }
        let now = check(target)
        if now == .ready {
            cancelWait()
            return start(event, target: target, via: via) ? .started : .blocked
        }
        pending = Pending(event: event, target: target, check: now, deadline: env.clock().addingTimeInterval(Self.waitLimit),
                          phase: .waiting)
        startTicker()
        trace(via, "wait-\(Self.traceName(now))")
        return .waiting
    }

    /// Once a second while waiting: records as soon as Fathom is on the right account; stops at the deadline.
    func tick() {
        guard var p = pending, p.phase == .waiting else { stop(); return }
        refresh()
        p.check = check(p.target)
        if p.check == .ready {
            pending = nil
            stop()
            _ = start(p.event, target: p.target, via: "switched")
            return
        }
        if env.clock() >= p.deadline {
            p.phase = .timedOut
            stop()
            trace("wait", "timeout")
        }
        pending = p
    }

    /// "Open Fathom": its window, where the person switches accounts; the wait goes on.
    func openFathom() {
        let ok = env.open(FathomURLs.openApp)
        trace("open-fathom", ok ? "opened" : "failed")
    }

    /// "Try again" after a timeout: another full wait.
    func retry() {
        guard var p = pending else { return }
        refresh()
        p.check = check(p.target)
        if p.check == .ready {
            pending = nil
            _ = start(p.event, target: p.target, via: "retry")
            return
        }
        p.phase = .waiting
        p.deadline = env.clock().addingTimeInterval(Self.waitLimit)
        pending = p
        startTicker()
    }

    /// "Record anyway" when Fathom's account can't be read: capture with whatever account it has.
    @discardableResult
    func recordAnyway() -> Bool {
        guard let p = pending else { return false }
        cancelWait()
        return start(p.event, target: p.target, via: "anyway")
    }

    /// "Join without recording": the meeting only.
    @discardableResult
    func joinWithoutRecording() -> Bool {
        guard let p = pending, let url = p.event.joinURL, JoinPolicy.isAllowed(url) else { cancelWait(); return false }
        cancelWait()
        let ok = env.open(url)
        trace("join-only", ok ? "opened" : "failed")
        return ok
    }

    func cancelWait() {
        stop()
        pending = nil
    }

    func isPending(_ r: String) -> Bool { pending?.r == r }

    // MARK: Private

    private func start(_ event: CalendarEvent, target: FathomTarget, via: String) -> Bool {
        guard let meeting = event.joinURL, JoinPolicy.isAllowed(meeting), let capture = FathomURLs.startCapture(meeting: meeting) else {
            trace(via, "blocked")
            return false
        }
        let captured = env.open(capture)
        env.after(Self.meetingDelay) { [env] in _ = env.open(meeting) }
        trace(via, captured ? "started" : "capture-failed")
        return true
    }

    private func startTicker() {
        stop()
        stopTicker = env.every(1) { [weak self] in self?.tick() }
    }

    private func stop() {
        stopTicker?()
        stopTicker = nil
    }

    private func trace(_ via: String, _ result: String) {
        Trace.app("fathom", ["via": via, "result": result])
    }

    static func traceName(_ check: FathomCheck) -> String {
        switch check {
        case .ready: return "ready"
        case .otherAccount: return "other-account"
        case .signedOut: return "signed-out"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Settings and Accounts

/// The links on the account cards and Settings → "⌃⌥J records with Fathom". Writes the preference and posts
/// `FathomPrefs.changed` (the widgets republish their Fathom buttons).
@MainActor
final class FathomLinksModel: ObservableObject {
    static let shared = FathomLinksModel()

    /// Bumped on every change, so cards and Settings redraw.
    @Published private(set) var revision = 0
    let session: FathomSession
    private let bag: PreferenceBag
    private let post: () -> Void

    init(bag: PreferenceBag = DefaultsBag.shared, session: FathomSession? = nil,
         post: @escaping () -> Void = { NotificationCenter.default.post(name: FathomPrefs.changed, object: nil) }) {
        self.bag = bag
        self.session = session ?? .shared
        self.post = post
    }

    var installed: Bool { session.installed }
    var hotkeyRecords: Bool { FathomPrefs.hotkeyRecords(bag) }

    func link(_ account: UUID) -> FathomLink { FathomPrefs.link(account, bag) }

    func set(_ link: FathomLink, for account: UUID) {
        FathomPrefs.setLink(link, for: account, bag)
        revision += 1
        Trace.app("fathom-link", ["kind": Self.kindName(link)])
        post()
    }

    /// "Another address…": refused (false) unless it is one address.
    @discardableResult
    func setAddress(_ raw: String, for account: UUID, own: String) -> Bool {
        guard let address = FathomAddress.normalized(raw) else { return false }
        set(address == FathomAddress.normalized(own) ? .ownAddress : .address(address), for: account)
        return true
    }

    func setHotkeyRecords(_ on: Bool) {
        FathomPrefs.setHotkeyRecords(on, bag)
        revision += 1
        post()
    }

    func refresh() {
        session.refresh()
        revision += 1
    }

    /// The card's line under the switch.
    func detail(_ account: UUID, email: String) -> String {
        switch link(account) {
        case .ownAddress:
            return "Join with Fathom records this account\u{2019}s meetings in its own Fathom account, \(FathomAddress.normalized(email) ?? email)."
        case .address(let a):
            return "Join with Fathom records this account\u{2019}s meetings in the Fathom account \(a)."
        case .off:
            return "Off: this account\u{2019}s meetings get no Join with Fathom."
        }
    }

    /// True when Fathom on this Mac is signed into this account's Fathom account right now.
    func isSignedIn(_ account: UUID, email: String) -> Bool {
        guard case .signedIn(let current) = session.signIn, let mine = link(account).email(account: email) else { return false }
        return current == mine
    }

    /// Settings → Fathom on this Mac.
    func appStatus(directory: AccountDirectory) -> String {
        guard installed else { return "Fathom isn\u{2019}t on this Mac." }
        switch session.signIn {
        case .signedIn(let email):
            let label = session.label(email, directory: directory)
            return label == email ? "Signed in as \(email)." : "Signed in as \(email) (\(label))."
        case .signedOut: return "Not signed in."
        case .unknown: return "I can\u{2019}t tell which account it\u{2019}s signed into, so I ask before recording."
        }
    }

    static func kindName(_ link: FathomLink) -> String {
        switch link {
        case .ownAddress: return "own"
        case .address: return "other"
        case .off: return "off"
        }
    }
}
