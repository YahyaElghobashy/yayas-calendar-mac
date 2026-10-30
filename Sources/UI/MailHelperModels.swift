import CryptoKit
import Foundation

// The link to Yaya's Mail Helper (D-050), the private companion app that sorts mail on the owner's own server, free
// of AppKit so the test binary checks all of it: whether the helper is installed (a handler of its URL scheme that
// carries its bundle id), its two files (`share/state.json`, `share/digest.json` in its data folder) and the answers it
// leaves (`share/results/<id>.json`), the command files the calendar writes in its own data folder and the one link
// that announces them, the sealed hand-over of a sign-in, the inbox's Priority-first order, and the meeting people.
// The calendar never talks to the helper's server: the helper does. The live pieces (LaunchServices, files, opening
// the link, the Keychain) come in through `MailHelperSession.Environment` and `MailHelperModel`.
// The helper's side of the contract: its docs/CONTRACT.md, "Helper ⇄ Calendar".

// MARK: - Names and limits

enum MailHelperFiles {
    /// The helper's folder inside its data root (`<mailHelperDataRoot>/share/`).
    static let shareFolder = "share"
    static let stateFile = "state.json"
    static let digestFile = "digest.json"
    static let resultsFolder = "results"
    /// The calendar's own command folder, inside its data root's `share/` (0700; files 0600).
    static let commandFolder = "mailhelper"
    /// Voice notes handed to the helper (v1.3): `voice-<lowercase uuid>.wav`, deleted by the helper once read.
    static func clipName(_ id: UUID) -> String { "voice-" + id.uuidString.lowercased() + ".wav" }
    static func isClip(_ name: String) -> Bool {
        guard name.hasPrefix("voice-"), name.hasSuffix(".wav"), let id = UUID(uuidString: String(name.dropFirst(6).dropLast(4))) else { return false }
        return clipName(id) == name
    }
    /// The helper's files are refused past 4 MiB before they are read.
    static let fileLimit = 4 * 1024 * 1024
    /// A command file never exceeds 64 KiB.
    static let commandLimit = 64 * 1024
    /// Posted by the helper (DistributedNotificationCenter, no object, no userInfo) after any of its files changed.
    static var changedNotification: String { Profile.mailHelperBundleId + ".changed" }

    static func commandName(_ id: UUID) -> String { "cmd-" + id.uuidString.lowercased() + ".json" }
    static func resultName(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }
}

enum MailHelperPresence {
    /// Installed when an app that handles the helper's URL scheme carries its bundle id (a look-alike claiming the
    /// scheme leaves every Mail helper surface hidden).
    static func isInstalled(handlers: [String?], expected: String = Profile.mailHelperBundleId) -> Bool {
        let want = expected.lowercased()
        return handlers.contains { id in
            guard let id, !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return id.lowercased() == want
        }
    }
}

/// The one link: `<scheme>://cmd?id=<uuid>`, built with URLComponents from the profile's scheme. The helper reads the
/// command file of that id from the calendar's data folder and accepts the link only from this app's signature.
enum MailHelperLinks {
    static func command(_ id: UUID, scheme: String = Profile.mailHelperScheme) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "cmd"
        c.queryItems = [URLQueryItem(name: "id", value: id.uuidString.lowercased())]
        return c.url
    }
}

// MARK: - JSON

/// A JSON value as the helper's files carry it. Every read goes through the typed accessors, so a value of the wrong
/// type reads as absent.
enum MailHelperJSON: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([MailHelperJSON])
    case object([String: MailHelperJSON])

    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                let d = n.doubleValue
                if d.isFinite, d == d.rounded(), abs(d) < 9.0e15 { self = .int(Int(d)) } else { self = .number(d) }
            }
        case let a as [Any]: self = .array(a.map { MailHelperJSON(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { MailHelperJSON(any: $0) })
        default: self = .null
        }
    }

    static func parse(_ data: Data) -> MailHelperJSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return MailHelperJSON(any: any)
    }

    /// For JSONSerialization.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    subscript(key: String) -> MailHelperJSON? { if case .object(let o) = self { return o[key] } else { return nil } }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var int: Int? { if case .int(let i) = self { return i } else { return nil } }
    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .number(let d): return d
        default: return nil
        }
    }
    var array: [MailHelperJSON]? { if case .array(let a) = self { return a } else { return nil } }
    var object: [String: MailHelperJSON]? { if case .object(let o) = self { return o } else { return nil } }
    var isNull: Bool { self == .null }
    /// Unix seconds → a date.
    var date: Date? { double.flatMap { $0 > 0 && $0 < 1e11 ? Date(timeIntervalSince1970: $0) : nil } }

    /// Compact, sorted keys: the same command always writes the same bytes.
    func encoded() -> Data? {
        guard JSONSerialization.isValidJSONObject(any) else { return nil }
        return try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// Text the helper wrote, made safe to draw: control and direction characters removed, white space folded, capped.
/// The views draw it with `Text(verbatim:)` (plain text: no Markdown, no links).
enum MailHelperPlain {
    static func clean(_ text: String?, _ limit: Int) -> String? {
        guard let text else { return nil }
        var out = String.UnicodeScalarView()
        var space = false
        for s in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(s) {
                space = !out.isEmpty
                continue
            }
            if s.properties.generalCategory == .control || s.properties.generalCategory == .format { continue }
            if space { out.append(" "); space = false }
            out.append(s)
            if out.count >= limit { break }
        }
        let s = String(out)
        return s.isEmpty ? nil : s
    }
}

// MARK: - Words the contract fixes

enum MailCategory: String, CaseIterable, Identifiable {
    case people, newsletters, updates, promotions, money, security, travel, orders, calendar, social, review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "People"
        case .newsletters: return "Newsletters"
        case .updates: return "Updates"
        case .promotions: return "Promotions"
        case .money: return "Money"
        case .security: return "Security"
        case .travel: return "Travel"
        case .orders: return "Orders"
        case .calendar: return "Calendar"
        case .social: return "Social"
        case .review: return "Review"
        }
    }

    /// Where a person may move mail (Review is the engine's own "not sure").
    static var choices: [MailCategory] { allCases.filter { $0 != .review } }
    /// The buttons a Review row shows first; the rest sit in its "More" menu.
    static var quick: [MailCategory] { [.people, .newsletters, .updates, .promotions] }
}

enum MailAIPolicy: String, CaseIterable, Identifiable {
    case off
    case local
    case localClaude = "local+claude"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .local: return "Local"
        case .localClaude: return "Local + cloud"
        }
    }
}

/// A model the writer can use, from the helper's live list (`status.models`, contract v1.2): Local, then whatever Claude and
/// Codex offer now, each with its own thinking levels. Before the first list arrives, the built-in Claude three stand in.
struct MailDraftModel: Equatable, Hashable, Identifiable {
    /// local, claude or codex
    var provider: String
    var id: String
    var title: String
    var efforts: [String]
    var defaultEffort: String?

    var usesCloud: Bool { provider != "local" }
    var usesClaude: Bool { provider == "claude" }
    var providerTitle: String { provider == "codex" ? "Codex" : provider == "claude" ? "Claude" : "Local" }

    static let providers: Set<String> = ["local", "claude", "codex"]
    static let claudeLevels = ["low", "medium", "high", "xhigh", "max"]
    static let local = MailDraftModel(provider: "local", id: "local", title: "Local", efforts: [], defaultEffort: nil)
    static let builtIn: [MailDraftModel] = [local] + [("haiku", "Haiku"), ("sonnet", "Sonnet"), ("opus", "Opus")].map {
        MailDraftModel(provider: "claude", id: "claude-\($0.0)-5-5", title: "Claude \($0.1) 5.5", efforts: claudeLevels, defaultEffort: "low")
    }

    static let haiku = builtIn[1], sonnet = builtIn[2], opus = builtIn[3]

    /// Ids and levels the helper accepts (it checks them against the live list too).
    static func isModelId(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.utf8.count <= 64 else { return false }
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first)
            && s.unicodeScalars.allSatisfy { ok.contains($0) }
    }
    static func isEffort(_ s: String) -> Bool {
        (2...12).contains(s.utf8.count) && s.unicodeScalars.allSatisfy { CharacterSet.lowercaseLetters.contains($0) && $0.isASCII }
    }

    /// The level to use with this model: the one asked for if it has it, else its default, else its first.
    func effort(_ wanted: String) -> String {
        if efforts.isEmpty || efforts.contains(wanted) { return efforts.isEmpty ? "low" : wanted }
        return defaultEffort.flatMap { efforts.contains($0) ? $0 : nil } ?? efforts[0]
    }
}

/// Thinking levels as people read them.
enum MailDraftEffort {
    static func title(_ raw: String) -> String {
        switch raw {
        case "xhigh": return "Extra high"
        case "max": return "Max"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

/// Ids the contract allows: accounts and credential names (`[A-Za-z0-9_-]{1,64}`), Gmail thread ids (`[0-9a-f]{1,32}`),
/// backlog runs (`bf-` and 12 hex digits).
enum MailHelperIDs {
    static func isAccount(_ s: String) -> Bool { matches(s, 1...64, extra: "_-", hexOnly: false) }
    static func isThread(_ s: String) -> Bool { matches(s, 1...32, extra: "", hexOnly: true) }
    static func isRun(_ s: String) -> Bool {
        s.hasPrefix("bf-") && s.utf8.count == 15 && matches(String(s.dropFirst(3)), 12...12, extra: "", hexOnly: true)
    }

    private static func matches(_ s: String, _ length: ClosedRange<Int>, extra: String, hexOnly: Bool) -> Bool {
        guard length.contains(s.utf8.count) else { return false }
        let extras = Set(extra.utf8)
        return s.utf8.allSatisfy { b in
            if hexOnly { return (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) }
            return (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || extras.contains(b)
        }
    }

    /// The calendar's account id as the helper knows it: the account's UUID string.
    static func account(_ id: UUID) -> String { id.uuidString }
}

// MARK: - state.json

/// What the helper reports, v1. Read with care: the helper is another app, so every field is checked, an item that
/// fails is skipped, and anything unexpected reads as absent.
struct MailHelperState: Equatable {
    struct Lab: Equatable {
        var paired = false
        var reachable = false
        var origin: String?
        var lastOkAt: Date?
        var error: String?
    }

    struct BackfillRef: Equatable {
        var id: String
        var state: String
        var scanned: Int
        var applied: Int
    }

    struct Account: Equatable, Identifiable {
        var id: String
        var email: String
        var kind: String
        var enabled: Bool
        var paused: Bool
        /// new, ready, degraded, reauth, disconnected
        var state: String
        var detail: String?
        var aiPolicy: MailAIPolicy?
        var claudeCredential: String?
        var claudeReady: Bool
        /// v1.2: the Codex sign-in this account uses, and why Claude or Codex won't write for it (the lab's words).
        var codexCredential: String? = nil
        var codexReady = false
        var claudeOffReason: String? = nil
        var codexOffReason: String? = nil
        var lastSyncAt: Date?
        /// Today's sorted mail per category (Priority included when the helper counts it).
        var today: [String: Int]
        var reviewWaiting: Int
        var backfill: BackfillRef?
        var hasSignIn: Bool

        var uuid: UUID? { UUID(uuidString: id) }
    }

    struct Label: Equatable {
        var labelId: String
        var path: String
        var category: String
        var topic: String?
    }

    struct Proposal: Equatable, Identifiable {
        var id: Int
        var account: String
        /// rule_suggested, rule_active, new_label, merge, full
        var kind: String
        var sender: String?
        var category: String?
        var topic: String?
        var priority: Bool?
        var mails: Int?
        var senders: Int?
        var createdAt: Date?
    }

    struct ReviewThread: Equatable, Identifiable {
        var account: String
        var threadId: String
        var sender: String
        var subject: String
        var reasons: [String]
        var confidence: Double?
        var decidedAt: Date?
        var id: String { account + "/" + threadId }
    }

    struct Action: Equatable, Identifiable {
        var id: Int
        var account: String
        var threadId: String
        var at: Date
        var batch: String?
        var added: [String]
        var removed: [String]
        var reason: String
        var source: String
        var undone: Bool
        var subject: String?
        var sender: String?
        var category: String?
        var topic: String?
    }

    struct SenderCount: Equatable { var sender: String; var count: Int }
    struct Sample: Equatable { var threadId: String; var sender: String; var subject: String }

    struct Group: Equatable, Identifiable {
        var label: String
        var category: String
        var topic: String?
        var count: Int
        var staysInInbox: Int
        var senders: [SenderCount]
        var samples: [Sample]
        var id: String { label }
    }

    struct Backfill: Equatable {
        var run: String
        var account: String
        /// scanning, ready, applying, applied, undone
        var state: String
        var scanned: Int
        var applied: Int
        var totals: [String: Int]
        var groups: [Group]
        var newLabels: [String]
    }

    var updatedAt: Date?
    var lab = Lab()
    var sealKey: Data?
    var sealFingerprint: String?
    var accounts: [Account] = []
    var claudeCredentials: [String] = []
    var codexCredentials: [String] = []
    /// The writer's models, live from the providers (Local first); the built-in list until the helper sends one.
    var models: [MailDraftModel] = MailDraftModel.builtIn
    var localModel = false
    var rootLabel = "Sorted"
    var digestAt: String?
    var errors: [String] = []
    var labels: [String: [Label]] = [:]
    var proposals: [Proposal] = []
    var review: [ReviewThread] = []
    var activity: [Action] = []
    var backfills: [String: Backfill] = [:]

    func account(_ id: UUID) -> Account? { accounts.first { $0.uuid == id } }
    func labels(_ id: UUID) -> [Label] {
        labels.first { UUID(uuidString: $0.key) == id }?.value ?? []
    }
    /// The account's latest backlog run (the one its status names): its summary when the helper sent one, else what
    /// the status says about it (state and counts, no label groups).
    func backfill(_ id: UUID) -> Backfill? {
        guard let a = account(id), let ref = a.backfill else { return nil }
        return backfills[ref.id] ?? Backfill(run: ref.id, account: a.id, state: ref.state, scanned: ref.scanned, applied: ref.applied,
                                             totals: [:], groups: [], newLabels: [])
    }
}

/// A file of the helper's as read: missing, refused, newer than this app understands, or its contents.
enum MailHelperRead<Value: Equatable>: Equatable {
    case missing
    case unreadable
    case newer
    case ready(Value)

    var value: Value? { if case .ready(let v) = self { return v } else { return nil } }
}

enum MailHelperParse {
    static let activityLimit = 150

    /// `version` must be the integer 1; higher is "newer"; anything else is "unreadable".
    static func versioned(_ data: Data?) -> MailHelperRead<MailHelperJSON> {
        guard let data else { return .missing }
        guard data.count <= MailHelperFiles.fileLimit, let json = MailHelperJSON.parse(data), json.object != nil,
              let v = json["version"]?.int else { return .unreadable }
        if v > 1 { return .newer }
        return v == 1 ? .ready(json) : .unreadable
    }

    static func state(_ data: Data?) -> MailHelperRead<MailHelperState> {
        switch versioned(data) {
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .newer: return .newer
        case .ready(let j): return .ready(state(j))
        }
    }

    static func state(_ j: MailHelperJSON) -> MailHelperState {
        var s = MailHelperState()
        s.updatedAt = j["updated_at"]?.date
        if let lab = j["lab"] {
            s.lab.paired = lab["paired"]?.bool ?? false
            s.lab.reachable = lab["reachable"]?.bool ?? false
            s.lab.origin = MailHelperPlain.clean(lab["origin"]?.string, 200)
            s.lab.lastOkAt = lab["last_ok_at"]?.date
            s.lab.error = MailHelperPlain.clean(lab["error"]?.string, 300)
        }
        if let server = j["server"] {
            if let key = server["seal_key"]?.string, let raw = Data(base64Encoded: key), raw.count == 32 { s.sealKey = raw }
            s.sealFingerprint = MailHelperPlain.clean(server["seal_fingerprint"]?.string, 40)
        }
        if let status = j["status"], status.object != nil {
            s.accounts = (status["accounts"]?.array ?? []).compactMap(account)
            s.claudeCredentials = (status["claude_credentials"]?.array ?? []).compactMap { $0.string }
                .filter(MailHelperIDs.isAccount).sorted()
            s.codexCredentials = (status["codex_credentials"]?.array ?? []).compactMap { $0.string }
                .filter(MailHelperIDs.isAccount).sorted()
            if let list = models(status["models"]), !list.isEmpty { s.models = list }
            s.localModel = status["local_model"]?.bool ?? false
            if let root = MailHelperPlain.clean(status["root_label"]?.string, 40) { s.rootLabel = root }
            s.digestAt = MailHelperPlain.clean(status["digest_at"]?.string, 8)
            s.errors = (status["errors"]?.array ?? []).compactMap { MailHelperPlain.clean($0["error"]?.string, 200) }
        }
        for (key, list) in j["labels"]?.object ?? [:] where MailHelperIDs.isAccount(key) {
            s.labels[key] = (list.array ?? []).compactMap { l in
                guard let id = l["label_id"]?.string, !id.isEmpty, id.utf8.count <= 64,
                      let path = MailHelperPlain.clean(l["path"]?.string, 200),
                      let category = l["category"]?.string else { return nil }
                return MailHelperState.Label(labelId: id, path: path, category: category,
                                             topic: MailHelperPlain.clean(l["topic"]?.string, 60))
            }
        }
        s.proposals = (j["proposals"]?.array ?? []).compactMap(proposal)
        s.review = (j["review"]?.array ?? []).compactMap(review)
        s.activity = Array((j["activity"]?.array ?? []).compactMap(action).prefix(activityLimit))
        for (run, body) in j["backfills"]?.object ?? [:] where MailHelperIDs.isRun(run) {
            if let b = backfill(body, run: run) { s.backfills[run] = b }
        }
        return s
    }

    /// `status.models.providers[].models[]`: ids and levels checked by shape, titles cleaned, at most 12 per provider.
    static func models(_ m: MailHelperJSON?) -> [MailDraftModel]? {
        guard let providers = m?["providers"]?.array else { return nil }
        var out: [MailDraftModel] = []
        for p in providers {
            guard let pid = p["id"]?.string, MailDraftModel.providers.contains(pid) else { continue }
            for e in (p["models"]?.array ?? []).prefix(12) {
                guard let id = e["id"]?.string, MailDraftModel.isModelId(id) else { continue }
                let levels = (e["efforts"]?.array ?? []).compactMap { $0.string }.filter(MailDraftModel.isEffort)
                let def = e["default_effort"]?.string.flatMap { levels.contains($0) ? $0 : nil }
                out.append(MailDraftModel(provider: pid, id: id, title: MailHelperPlain.clean(e["title"]?.string, 60) ?? id,
                                          efforts: pid == "local" ? [] : Array(levels.prefix(8)), defaultEffort: def))
            }
        }
        if !out.contains(where: { $0.provider == "local" }) { out.insert(.local, at: 0) }
        return out
    }

    static func account(_ a: MailHelperJSON) -> MailHelperState.Account? {
        guard let id = a["id"]?.string, MailHelperIDs.isAccount(id) else { return nil }
        var today: [String: Int] = [:]
        for (k, v) in a["today"]?.object ?? [:] { if let n = v.int, n >= 0 { today[k] = n } }
        var ref: MailHelperState.BackfillRef?
        if let b = a["backfill"], let run = b["id"]?.string, MailHelperIDs.isRun(run) {
            ref = MailHelperState.BackfillRef(id: run, state: b["state"]?.string ?? "", scanned: b["scanned"]?.int ?? 0,
                                              applied: b["applied"]?.int ?? 0)
        }
        let credential = a["claude_credential"]?.string.flatMap { MailHelperIDs.isAccount($0) ? $0 : nil }
        return MailHelperState.Account(
            id: id, email: MailHelperPlain.clean(a["email"]?.string, 254) ?? "", kind: a["kind"]?.string ?? "personal",
            enabled: a["enabled"]?.bool ?? false, paused: a["paused"]?.bool ?? false, state: a["state"]?.string ?? "new",
            detail: MailHelperPlain.clean(a["detail"]?.string, 200), aiPolicy: a["ai_policy"]?.string.flatMap(MailAIPolicy.init),
            claudeCredential: credential, claudeReady: a["claude_ready"]?.bool ?? false,
            codexCredential: a["codex_credential"]?.string.flatMap { MailHelperIDs.isAccount($0) ? $0 : nil },
            codexReady: a["codex_ready"]?.bool ?? false,
            claudeOffReason: MailHelperPlain.clean(a["claude_off_reason"]?.string, 300),
            codexOffReason: MailHelperPlain.clean(a["codex_off_reason"]?.string, 300), lastSyncAt: a["last_sync_at"]?.date,
            today: today, reviewWaiting: max(0, a["review_waiting"]?.int ?? 0), backfill: ref,
            hasSignIn: a["has_sign_in"]?.bool ?? false)
    }

    static func proposal(_ p: MailHelperJSON) -> MailHelperState.Proposal? {
        guard let id = p["id"]?.int, let account = p["account"]?.string, MailHelperIDs.isAccount(account),
              let kind = p["kind"]?.string, p["status"]?.string ?? "open" == "open" else { return nil }
        let payload = p["payload"]
        return MailHelperState.Proposal(
            id: id, account: account, kind: kind, sender: MailHelperPlain.clean(payload?["sender"]?.string, 254),
            category: payload?["category"]?.string, topic: MailHelperPlain.clean(payload?["topic"]?.string, 60),
            priority: payload?["priority"]?.bool, mails: payload?["mails"]?.int, senders: payload?["senders"]?.int,
            createdAt: p["created_at"]?.date)
    }

    static func review(_ r: MailHelperJSON) -> MailHelperState.ReviewThread? {
        guard let account = r["account"]?.string, MailHelperIDs.isAccount(account),
              let thread = r["thread_id"]?.string, MailHelperIDs.isThread(thread) else { return nil }
        return MailHelperState.ReviewThread(
            account: account, threadId: thread, sender: MailHelperPlain.clean(r["sender"]?.string, 254) ?? "",
            subject: MailHelperPlain.clean(r["subject"]?.string, 300) ?? "",
            reasons: (r["reasons"]?.array ?? []).compactMap { MailHelperPlain.clean($0.string, 120) }.prefix(3).map { $0 },
            confidence: r["confidence"]?.double, decidedAt: r["decided_at"]?.date)
    }

    static func action(_ a: MailHelperJSON) -> MailHelperState.Action? {
        guard let id = a["id"]?.int, let account = a["account"]?.string, MailHelperIDs.isAccount(account),
              let thread = a["thread_id"]?.string, MailHelperIDs.isThread(thread), let at = a["at"]?.date else { return nil }
        func labels(_ key: String) -> [String] { (a[key]?.array ?? []).compactMap { MailHelperPlain.clean($0.string, 200) } }
        return MailHelperState.Action(
            id: id, account: account, threadId: thread, at: at, batch: MailHelperPlain.clean(a["batch"]?.string, 80),
            added: labels("added"), removed: labels("removed"), reason: MailHelperPlain.clean(a["reason"]?.string, 200) ?? "",
            source: a["source"]?.string ?? "", undone: a["undone"]?.bool ?? false,
            subject: MailHelperPlain.clean(a["subject"]?.string, 300), sender: MailHelperPlain.clean(a["sender"]?.string, 254),
            category: a["category"]?.string, topic: MailHelperPlain.clean(a["topic"]?.string, 60))
    }

    static func backfill(_ b: MailHelperJSON, run: String) -> MailHelperState.Backfill? {
        guard let account = b["account"]?.string, MailHelperIDs.isAccount(account) else { return nil }
        var totals: [String: Int] = [:]
        for (k, v) in b["totals"]?.object ?? [:] { if let n = v.int { totals[k] = n } }
        let groups: [MailHelperState.Group] = (b["labels"]?.array ?? []).compactMap { g in
            guard let label = MailHelperPlain.clean(g["label"]?.string, 200), let category = g["category"]?.string else { return nil }
            let senders = (g["senders"]?.array ?? []).compactMap { s -> MailHelperState.SenderCount? in
                guard let who = MailHelperPlain.clean(s["sender"]?.string, 254) else { return nil }
                return MailHelperState.SenderCount(sender: who, count: s["count"]?.int ?? 0)
            }
            let samples = (g["samples"]?.array ?? []).compactMap { s -> MailHelperState.Sample? in
                guard let thread = s["thread_id"]?.string, MailHelperIDs.isThread(thread) else { return nil }
                return MailHelperState.Sample(threadId: thread, sender: MailHelperPlain.clean(s["sender"]?.string, 254) ?? "",
                                              subject: MailHelperPlain.clean(s["subject"]?.string, 300) ?? "")
            }
            return MailHelperState.Group(label: label, category: category, topic: MailHelperPlain.clean(g["topic"]?.string, 60),
                                         count: g["count"]?.int ?? 0, staysInInbox: g["stays_in_inbox"]?.int ?? 0,
                                         senders: Array(senders.prefix(5)), samples: Array(samples.prefix(3)))
        }
        return MailHelperState.Backfill(
            run: run, account: account, state: b["state"]?.string ?? "", scanned: b["scanned"]?.int ?? 0,
            applied: b["applied"]?.int ?? 0, totals: totals, groups: groups,
            newLabels: (b["new_labels"]?.array ?? []).compactMap { MailHelperPlain.clean($0.string, 200) })
    }

    // MARK: digest.json

    static func digest(_ data: Data?) -> MailHelperRead<MailHelperDigest?> {
        switch versioned(data) {
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .newer: return .newer
        case .ready(let j):
            guard let d = j["digest"], d.object != nil else { return .ready(nil) }
            return .ready(digest(d))
        }
    }

    static func digest(_ d: MailHelperJSON) -> MailHelperDigest? {
        guard let id = d["id"]?.int else { return nil }
        var read: [String: Bool] = [:]
        for (k, v) in d["read"]?.object ?? [:] { if let b = v.bool { read[k] = b } }
        let sections: [MailHelperDigest.Section] = (d["sections"]?.array ?? []).compactMap { s in
            guard let key = s["key"]?.string, MailHelperIDs.isAccount(key) else { return nil }
            let items = (s["items"]?.array ?? []).enumerated().compactMap { index, item in digestItem(item, index: index) }
            guard !items.isEmpty else { return nil }
            return MailHelperDigest.Section(key: key, title: MailHelperPlain.clean(s["title"]?.string, 60) ?? key.capitalized,
                                            count: s["count"]?.int ?? items.count, items: items)
        }
        return MailHelperDigest(id: id, day: MailHelperPlain.clean(d["day"]?.string, 10) ?? "", builtAt: d["built_at"]?.date,
                                sections: sections, total: d["total"]?.int ?? sections.reduce(0) { $0 + $1.count }, read: read)
    }

    static func digestItem(_ i: MailHelperJSON, index: Int) -> MailHelperDigest.Item? {
        guard let account = i["account"]?.string, MailHelperIDs.isAccount(account),
              let thread = i["thread_id"]?.string, MailHelperIDs.isThread(thread) else { return nil }
        var item = MailHelperDigest.Item(index: index, account: account, threadId: thread)
        if let service = MailHelperPlain.clean(i["service"]?.string, 120) {
            item.service = service
            item.subjects = (i["subjects"]?.array ?? []).compactMap { MailHelperPlain.clean($0.string, 300) }
            item.threads = (i["threads"]?.array ?? []).compactMap { t in
                guard let a = t["account"]?.string, MailHelperIDs.isAccount(a), let id = t["thread_id"]?.string,
                      MailHelperIDs.isThread(id) else { return nil }
                return MailHelperDigest.ThreadRef(account: a, threadId: id)
            }
            if item.threads.isEmpty { item.threads = [MailHelperDigest.ThreadRef(account: account, threadId: thread)] }
            return item
        }
        item.accountEmail = MailHelperPlain.clean(i["account_email"]?.string, 254)
        item.sender = MailHelperPlain.clean(i["sender"]?.string, 254) ?? ""
        item.subject = MailHelperPlain.clean(i["subject"]?.string, 300) ?? ""
        item.topic = MailHelperPlain.clean(i["topic"]?.string, 60)
        item.headline = MailHelperPlain.clean(i["headline"]?.string, 140)
        item.bullets = (i["bullets"]?.array ?? []).compactMap { MailHelperPlain.clean($0.string, 200) }.prefix(3).map { $0 }
        item.worthOpening = i["worth_opening"]?.bool ?? false
        item.threads = [MailHelperDigest.ThreadRef(account: account, threadId: thread)]
        return item
    }

    // MARK: results/<id>.json

    static func result(_ data: Data?, id: UUID) -> MailHelperResult? {
        guard case .ready(let j) = versioned(data) else {
            return data == nil ? nil : .failure(id, "Yaya\u{2019}s Mail Helper answered in a way I can\u{2019}t read.")
        }
        guard j["id"]?.string?.lowercased() == id.uuidString.lowercased() else {
            return .failure(id, "Yaya\u{2019}s Mail Helper answered in a way I can\u{2019}t read.")
        }
        let ok = j["ok"]?.bool ?? false
        return MailHelperResult(id: id, ok: ok,
                                error: ok ? nil : (MailHelperPlain.clean(j["error"]?.string, 300) ?? "Something went wrong."),
                                data: j["data"] ?? .null)
    }
}

// MARK: - digest.json

struct MailHelperDigest: Equatable {
    struct ThreadRef: Equatable, Hashable { var account: String; var threadId: String }

    /// One entry: a summarised newsletter or promotion (headline, bullets, "worth opening"), a group of updates from
    /// one service (`service` and its subjects), or a plain subject.
    struct Item: Equatable, Identifiable {
        var index: Int
        var account: String
        var threadId: String
        var accountEmail: String?
        var sender = ""
        var subject = ""
        var topic: String?
        var headline: String?
        var bullets: [String] = []
        var worthOpening = false
        var service: String?
        var subjects: [String] = []
        var threads: [ThreadRef] = []

        var id: String { "\(index)-\(account)-\(threadId)" }
        var isGroup: Bool { service != nil }
        var isSummary: Bool { headline != nil || !bullets.isEmpty }
    }

    struct Section: Equatable, Identifiable {
        var key: String
        var title: String
        var count: Int
        var items: [Item]
        var id: String { key }
    }

    var id: Int
    var day: String
    var builtAt: Date?
    var sections: [Section]
    var total: Int
    /// Sections the helper has already marked read (section key → done).
    var read: [String: Bool]

    /// The undo batch of a section's "read" (the helper's own name for it): `digest:<id>:<section>` or `…:all`.
    func batch(_ section: String?) -> String { "digest:\(id):\(section ?? "all")" }
}

// MARK: - Answers

struct MailHelperResult: Equatable {
    var id: UUID
    var ok: Bool
    var error: String?
    var data: MailHelperJSON

    static func failure(_ id: UUID, _ message: String) -> MailHelperResult {
        MailHelperResult(id: id, ok: false, error: message, data: .null)
    }
}

// MARK: - Commands

/// One command file: `{ "version":1, "id":"<uuid>", "kind":"…", "args":{…} }`. Built only through the kinds below,
/// each of which checks its ids; nil = refused before anything is written.
struct MailHelperCommand: Equatable {
    let id: UUID
    let kind: String
    let args: [String: MailHelperJSON]

    init(kind: String, args: [String: MailHelperJSON] = [:], id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.args = args
    }

    /// The file's bytes, or nil past 64 KiB.
    func encoded() -> Data? {
        let body = MailHelperJSON.object(["version": .int(1), "id": .string(id.uuidString.lowercased()),
                                          "kind": .string(kind), "args": .object(args)])
        guard let data = body.encoded(), data.count <= MailHelperFiles.commandLimit else { return nil }
        return data
    }

    var traceName: String { kind }

    // MARK: Kinds

    static func refresh() -> MailHelperCommand { MailHelperCommand(kind: "refresh") }

    static func handover(account: UUID, kind: String, envelope: [String: MailHelperJSON]) -> MailHelperCommand? {
        guard kind == "personal" || kind == "work" else { return nil }
        return MailHelperCommand(kind: "handover", args: ["account": .string(MailHelperIDs.account(account)),
                                                          "kind": .string(kind), "envelope": .object(envelope)])
    }

    static func setPaused(_ paused: Bool, account: UUID) -> MailHelperCommand {
        MailHelperCommand(kind: "account", args: ["account": .string(MailHelperIDs.account(account)), "paused": .bool(paused)])
    }

    static func setPolicy(_ policy: MailAIPolicy, account: UUID) -> MailHelperCommand {
        MailHelperCommand(kind: "account", args: ["account": .string(MailHelperIDs.account(account)), "ai_policy": .string(policy.rawValue)])
    }

    /// nil name = no Claude credential for this account.
    static func setCredential(_ name: String?, account: UUID) -> MailHelperCommand? {
        if let name, !MailHelperIDs.isAccount(name) { return nil }
        return MailHelperCommand(kind: "account", args: ["account": .string(MailHelperIDs.account(account)),
                                                         "claude_credential": name.map { .string($0) } ?? .null])
    }

    /// nil name = no Codex sign-in for this account (v1.2).
    static func setCodexCredential(_ name: String?, account: UUID) -> MailHelperCommand? {
        if let name, !MailHelperIDs.isAccount(name) { return nil }
        return MailHelperCommand(kind: "account", args: ["account": .string(MailHelperIDs.account(account)),
                                                         "codex_credential": name.map { .string($0) } ?? .null])
    }

    /// Cloud AI on, with this Claude credential, in one go (the draft pop-over's "Turn on").
    static func enableClaude(_ name: String, account: UUID) -> MailHelperCommand? {
        guard MailHelperIDs.isAccount(name) else { return nil }
        return MailHelperCommand(kind: "account", args: ["account": .string(MailHelperIDs.account(account)),
                                                         "ai_policy": .string(MailAIPolicy.localClaude.rawValue),
                                                         "claude_credential": .string(name)])
    }

    /// Ask Claude and Codex for their current models and thinking levels (v1.2).
    static func modelsRefresh() -> MailHelperCommand { MailHelperCommand(kind: "models_refresh") }

    /// A voice note to transcribe on this Mac (v1.3): `voice-<uuid>.wav` in the share folder, 16 kHz mono WAV.
    static func transcribe(clip: String) -> MailHelperCommand? {
        guard MailHelperFiles.isClip(clip) else { return nil }
        return MailHelperCommand(kind: "transcribe", args: ["clip": .string(clip)])
    }

    static func setKind(_ kind: String, account: UUID) -> MailHelperCommand? {
        guard kind == "personal" || kind == "work" else { return nil }
        return MailHelperCommand(kind: "account", args: ["account": .string(MailHelperIDs.account(account)), "kind": .string(kind)])
    }

    static func forget(account: UUID) -> MailHelperCommand {
        MailHelperCommand(kind: "forget", args: ["account": .string(MailHelperIDs.account(account))])
    }

    enum PeopleKind: String { case vip, vipDomain = "vip_domain", meeting }

    /// The whole list of that kind (the helper replaces it). Addresses are lowercased, checked and de-duplicated, at most
    /// `limit`; the list is cut further (keeping its order) until the file fits in 64 KiB.
    static func people(_ kind: PeopleKind, addresses: [String], account: UUID, limit: Int = 2000) -> MailHelperCommand {
        var seen = Set<String>()
        var clean: [String] = []
        for raw in addresses {
            let a = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ok = kind == .vipDomain ? MailHelperPeople.isDomain(a) : MailHelperPeople.isAddress(a)
            if ok, seen.insert(a).inserted { clean.append(a) }
            if clean.count >= limit { break }
        }
        let id = UUID()
        func make(_ list: [String]) -> MailHelperCommand {
            MailHelperCommand(kind: "people", args: ["account": .string(MailHelperIDs.account(account)),
                                                     "kind": .string(kind.rawValue), "addresses": .array(list.map { .string($0) })], id: id)
        }
        var command = make(clean)
        while command.encoded() == nil, !clean.isEmpty {
            clean.removeLast(max(1, clean.count / 20))
            command = make(clean)
        }
        return command
    }

    static func undo(actions ids: [Int]) -> MailHelperCommand {
        MailHelperCommand(kind: "undo", args: ["action_ids": .array(ids.prefix(5000).map { .int($0) })])
    }

    static func undo(batch: String) -> MailHelperCommand {
        MailHelperCommand(kind: "undo", args: ["batch": .string(batch)])
    }

    static func undo(since: Date, account: UUID? = nil) -> MailHelperCommand {
        var args: [String: MailHelperJSON] = ["since": .int(Int(since.timeIntervalSince1970))]
        if let account { args["account"] = .string(MailHelperIDs.account(account)) }
        return MailHelperCommand(kind: "undo", args: args)
    }

    static func proposal(_ id: Int, accept: Bool) -> MailHelperCommand {
        MailHelperCommand(kind: "proposal", args: ["id": .int(id), "decision": .string(accept ? "accept" : "reject")])
    }

    static func review(account: String, thread: String, category: MailCategory, onlyThisThread: Bool = false) -> MailHelperCommand? {
        guard MailHelperIDs.isAccount(account), MailHelperIDs.isThread(thread), category != .review else { return nil }
        return MailHelperCommand(kind: "review", args: ["account": .string(account), "thread_id": .string(thread),
                                                        "category": .string(category.rawValue),
                                                        "scope": .string(onlyThisThread ? "thread" : "sender")])
    }

    static func backfillStart(account: UUID) -> MailHelperCommand {
        MailHelperCommand(kind: "backfill_start", args: ["account": .string(MailHelperIDs.account(account))])
    }

    static func backfillOverride(run: String, sender: String, category: MailCategory) -> MailHelperCommand? {
        guard MailHelperIDs.isRun(run), !sender.isEmpty, sender.utf8.count <= 254, category != .review else { return nil }
        return MailHelperCommand(kind: "backfill_override", args: ["run": .string(run), "sender": .string(sender),
                                                                   "category": .string(category.rawValue)])
    }

    enum BackfillStep: String { case apply = "backfill_apply", stop = "backfill_stop", undo = "backfill_undo" }

    static func backfill(_ step: BackfillStep, run: String) -> MailHelperCommand? {
        guard MailHelperIDs.isRun(run) else { return nil }
        return MailHelperCommand(kind: step.rawValue, args: ["run": .string(run)])
    }

    static func digestBuild() -> MailHelperCommand { MailHelperCommand(kind: "digest_build") }

    static func digestRead(_ id: Int, section: String?) -> MailHelperCommand {
        var args: [String: MailHelperJSON] = ["id": .int(id)]
        if let section { args["section"] = .string(section) }
        return MailHelperCommand(kind: "digest_read", args: args)
    }

    static func needsReply(account: UUID? = nil) -> MailHelperCommand {
        MailHelperCommand(kind: "needs_reply", args: account.map { ["account": .string(MailHelperIDs.account($0))] } ?? [:])
    }

    static func voiceGet(account: UUID) -> MailHelperCommand {
        MailHelperCommand(kind: "voice_get", args: ["account": .string(MailHelperIDs.account(account))])
    }

    /// The helper keeps at most 3,000 characters of a style card.
    static let voiceCardLimit = 3000

    static func voicePut(account: UUID, card: String) -> MailHelperCommand {
        MailHelperCommand(kind: "voice_put", args: ["account": .string(MailHelperIDs.account(account)),
                                                    "card": .string(String(card.prefix(voiceCardLimit)))])
    }

    static func voiceBuild(account: UUID, useClaude: Bool) -> MailHelperCommand {
        MailHelperCommand(kind: "voice_build", args: ["account": .string(MailHelperIDs.account(account)), "use_claude": .bool(useClaude)])
    }

    /// The helper reads at most 1,000 characters of an instruction.
    static let instructionLimit = 1000

    static func draft(account: UUID, thread: String, model: MailDraftModel, effort: String,
                      instruction: String) -> MailHelperCommand? {
        guard MailHelperIDs.isThread(thread), MailDraftModel.isModelId(model.id), MailDraftModel.providers.contains(model.provider)
        else { return nil }
        let level = model.effort(effort)
        var args: [String: MailHelperJSON] = ["account": .string(MailHelperIDs.account(account)), "thread_id": .string(thread),
                                              "model": .string(model.id), "effort": .string(level),
                                              "provider": .string(model.provider)]
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { args["instruction"] = .string(String(text.prefix(instructionLimit))) }
        return MailHelperCommand(kind: "draft", args: args)
    }
}

/// Addresses and domains for the people lists.
enum MailHelperPeople {
    static func isAddress(_ s: String) -> Bool {
        guard s.utf8.count <= 254, !s.contains(where: { $0.isWhitespace || $0 == "," || $0 == "<" || $0 == ">" }) else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return isDomain(String(parts[1]))
    }

    static func isDomain(_ s: String) -> Bool {
        guard (3...253).contains(s.utf8.count), s.contains("."), !s.hasPrefix("."), !s.hasSuffix("."), !s.contains("..") else { return false }
        return s.utf8.allSatisfy { b in (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E }
    }

    /// One address or domain per line, or separated by commas; "Name <a@b.example>" keeps the address.
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n")).compactMap { raw in
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
                s = String(s[s.index(after: open)..<close])
            }
            if s.hasPrefix("@") { s.removeFirst() }
            s = s.lowercased()
            return s.isEmpty ? nil : s
        }
    }
}

// MARK: - Sealing a sign-in (CONTRACT §2)

/// What a hand-over carries, sealed. Never logged or drawn: its description is redacted.
struct MailHelperSignIn: CustomStringConvertible, CustomDebugStringConvertible {
    var refreshToken: String
    var clientId: String
    var clientSecret: String
    var email: String

    var description: String { "MailHelperSignIn(redacted)" }
    var debugDescription: String { description }

    /// `{"refresh_token","client_id","client_secret","email"}`.
    func plaintext() -> Data? {
        MailHelperJSON.object(["refresh_token": .string(refreshToken), "client_id": .string(clientId),
                               "client_secret": .string(clientSecret), "email": .string(email)]).encoded()
    }
}

enum MailHelperSealError: Error, Equatable {
    case noKey
    case fingerprintMismatch
    case failed
}

enum MailHelperSeal {
    static let info = "yaya-mail-helper seal v1"
    static let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")

    /// The fingerprint shown before sealing: SHA-256 of the raw key, its first 12 bytes mapped to the alphabet by
    /// `byte % 30`, in groups of 4 joined by "-".
    static func fingerprint(_ key: Data) -> String {
        let digest = Array(SHA256.hash(data: key)).prefix(12)
        let chars = digest.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 12, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    static func aad(purpose: String, account: String) -> Data { Data("mh-seal-v1|\(purpose)|\(account)".utf8) }

    /// X25519 (fresh key per envelope) → HKDF-SHA256 (empty salt, the info above, 32 bytes) → ChaCha20-Poly1305 over
    /// `mh-seal-v1|<purpose>|<account>`. Only the server holding the private half of `sealKey` can open it.
    static func envelope(_ plaintext: Data, sealKey: Data, purpose: String, account: String,
                         nonce: Data? = nil) throws -> [String: MailHelperJSON] {
        let server: Curve25519.KeyAgreement.PublicKey
        do { server = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sealKey) } catch { throw MailHelperSealError.noKey }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        do {
            let shared = try eph.sharedSecretFromKeyAgreement(with: server)
            let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data(info.utf8), outputByteCount: 32)
            let n = try nonce.map { try ChaChaPoly.Nonce(data: $0) } ?? ChaChaPoly.Nonce()
            let bytes = n.withUnsafeBytes { Data($0) }
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: n,
                                          authenticating: aad(purpose: purpose, account: account))
            return ["v": .int(1), "purpose": .string(purpose), "account": .string(account),
                    "epk": .string(eph.publicKey.rawRepresentation.base64EncodedString()),
                    "nonce": .string(bytes.base64EncodedString()),
                    "ct": .string((box.ciphertext + box.tag).base64EncodedString())]
        } catch let e as MailHelperSealError {
            throw e
        } catch {
            throw MailHelperSealError.failed
        }
    }

    /// The Gmail envelope for one account, after checking that the key the helper reports is the one its fingerprint
    /// names (the fingerprint is what the owner approves).
    static func gmail(_ signIn: MailHelperSignIn, account: UUID, state: MailHelperState) throws -> [String: MailHelperJSON] {
        guard let key = state.sealKey else { throw MailHelperSealError.noKey }
        guard let shown = state.sealFingerprint, shown == fingerprint(key) else { throw MailHelperSealError.fingerprintMismatch }
        guard var plain = signIn.plaintext() else { throw MailHelperSealError.failed }
        defer { plain.resetBytes(in: 0..<plain.count) }
        return try envelope(plain, sealKey: key, purpose: "gmail", account: MailHelperIDs.account(account))
    }
}

/// The approval card's facts (in the spirit of D-023): which account, the server key's fingerprint, personal or work.
struct MailHelperHandover: Equatable {
    var account: UUID
    var tag: String
    var name: String
    var email: String
    var fingerprint: String
    var kind: String
    var shownAt: Date
    /// The card's button and Return act only 0.3 s after the card appears (never a held or repeating key).
    static let armDelay: TimeInterval = 0.3

    /// "personal" for consumer Google addresses (`personalDomains`, the app's own list), "work" otherwise.
    static func defaultKind(email: String, personalDomains: Set<String>) -> String {
        let domain = email.lowercased().split(separator: "@").last.map(String.init) ?? ""
        return personalDomains.contains(domain) ? "personal" : "work"
    }
}

// MARK: - Inbox: Priority first and chips

enum MailHelperChip: String, Equatable {
    case priority, review

    var title: String { self == .priority ? "Priority" : "Review" }
}

/// Per account, the Gmail label ids the helper uses for Priority and for Review (state.json `labels`).
struct MailHelperInboxLabels: Equatable {
    var priority: [UUID: Set<String>] = [:]
    var review: [UUID: Set<String>] = [:]

    /// Nil when the helper reports no such labels (the inbox then stays exactly as it was).
    init?(_ state: MailHelperState?) {
        guard let state else { return nil }
        for (key, list) in state.labels {
            guard let id = UUID(uuidString: key) else { continue }
            let p = Set(list.filter { $0.category == "priority" }.map(\.labelId))
            let r = Set(list.filter { $0.category == "review" }.map(\.labelId))
            if !p.isEmpty { priority[id] = p }
            if !r.isEmpty { review[id] = r }
        }
        if priority.isEmpty && review.isEmpty { return nil }
    }

    func chips(_ t: MailThread) -> [MailHelperChip] {
        var out: [MailHelperChip] = []
        if let p = priority[t.accountId], t.labels.contains(where: p.contains) { out.append(.priority) }
        if let r = review[t.accountId], t.labels.contains(where: r.contains) { out.append(.review) }
        return out
    }

    func isPriority(_ t: MailThread) -> Bool {
        guard let p = priority[t.accountId] else { return false }
        return t.labels.contains(where: p.contains)
    }
}

enum MailHelperInbox {
    /// Priority threads first, each group in its existing order (stable); nil labels = unchanged.
    static func order(_ threads: [MailThread], _ labels: MailHelperInboxLabels?) -> [MailThread] {
        guard let labels else { return threads }
        let first = threads.filter(labels.isPriority)
        guard !first.isEmpty else { return threads }
        return first + threads.filter { !labels.isPriority($0) }
    }

    /// What the inbox reads, from any thread: set by the session while the helper is installed and reports labels.
    static let current = MailHelperBox<MailHelperInboxLabels?>(nil)
    /// Posted (default center, main queue) when `current` changes: an open Inbox reorders.
    static let changed = Notification.Name("YCMailHelperInboxChanged")
}

/// A value behind a lock (read off the main thread by the inbox's loads).
final class MailHelperBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

// MARK: - Meeting people

enum MailHelperMeetings {
    /// At most this many addresses per account.
    static let cap = 2000
    static let back: TimeInterval = 60 * 86400
    static let ahead: TimeInterval = 30 * 86400

    /// The distinct attendee and organizer addresses of the account's meetings in [now − 60 days, now + 30 days),
    /// lowercased, without the person's own addresses and rooms or groups Google marks as resources, nearest
    /// meetings first, at most `cap`.
    static func addresses(_ events: [CalendarEvent], account: UUID, own: Set<String>, now: Date) -> [String] {
        let from = now.addingTimeInterval(-back), to = now.addingTimeInterval(ahead)
        let mine = Set(own.map { $0.lowercased() })
        let nearest = events.filter { $0.accountIds.contains(account) && $0.end > from && $0.start < to }
            .sorted { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
        var seen = Set<String>()
        var out: [String] = []
        for e in nearest {
            for person in (e.organizer.map { [$0] } ?? []) + e.attendees where !person.isSelf {
                let a = person.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard MailHelperPeople.isAddress(a), !mine.contains(a), !a.hasSuffix(".calendar.google.com"),
                      seen.insert(a).inserted else { continue }
                out.append(a)
                if out.count >= cap { return out }
            }
        }
        return out
    }

    /// Once a day: never sent, sent on another day, or more than 24 hours ago.
    static func due(last: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let last else { return true }
        return !calendar.isDate(last, inSameDayAs: now) || now.timeIntervalSince(last) >= 86400
    }
}

// MARK: - Words

enum MailHelperText {
    /// "Sorted/Newsletters/AI & Tech" → "Newsletters/AI & Tech".
    static func label(_ path: String, root: String) -> String {
        let prefix = root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// What one action did, in a few words: "Out of the inbox · Newsletters/AI & Tech · marked read".
    static func change(_ a: MailHelperState.Action, root: String) -> String {
        var parts: [String] = []
        if a.removed.contains("INBOX") { parts.append("Out of the inbox") }
        if a.added.contains("INBOX") { parts.append("Back in the inbox") }
        for l in a.added where !["INBOX", "UNREAD", "IMPORTANT", "STARRED"].contains(l) { parts.append(label(l, root: root)) }
        for l in a.removed where !["INBOX", "UNREAD", "IMPORTANT", "STARRED"].contains(l) { parts.append("no longer " + label(l, root: root)) }
        if a.removed.contains("UNREAD") { parts.append("marked read") }
        if a.added.contains("UNREAD") { parts.append("marked unread") }
        if a.added.contains("IMPORTANT") { parts.append("marked important") }
        if a.removed.contains("IMPORTANT") { parts.append("not important") }
        return parts.isEmpty ? "No change" : parts.joined(separator: " \u{00B7} ")
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { let h = Int(s / 3600); return h == 1 ? "1 hour ago" : "\(h) hours ago" }
        let d = Int(s / 86400)
        return d == 1 ? "yesterday" : "\(d) days ago"
    }

    static func category(_ raw: String?) -> String {
        guard let raw else { return "" }
        if raw == "priority" { return "Priority" }
        return MailCategory(rawValue: raw)?.title ?? raw.capitalized
    }

    static func place(_ category: String?, _ topic: String?) -> String {
        let c = self.category(category)
        guard let topic, !topic.isEmpty else { return c }
        return c + "/" + topic
    }

    /// A suggestion as a question and its two answers.
    static func proposal(_ p: MailHelperState.Proposal) -> (title: String, detail: String, accept: String, reject: String) {
        let place = self.place(p.category, p.topic)
        switch p.kind {
        case "rule_suggested":
            return ("Sort mail from \(p.sender ?? "this sender") into \(place)?",
                    "You moved one of their emails there.", "Always", "No")
        case "rule_active":
            return ("I now sort \(p.sender ?? "this sender") into \(place)",
                    "You moved their mail there twice, so it became a rule.", "Keep", "Turn off")
        case "new_label":
            let mails = p.mails.map { $0 == 1 ? "1 email" : "\($0) emails" } ?? "Some emails"
            return ("New label: \(place)", "\(mails) from \(p.senders ?? 2) senders moved in.", "Keep", "Merge back")
        case "merge":
            return ("Merge \(place) back into \(self.category(p.category))?",
                    "Only \(p.mails ?? 0) in the last 60 days.", "Merge", "Keep")
        case "full":
            return ("\(self.category(p.category)) has no room for \(p.topic ?? "a new label")",
                    "It already has 8 labels; that mail stays in \(self.category(p.category)).", "OK", "Dismiss")
        default:
            return ("A suggestion about \(place)", "", "Accept", "Reject")
        }
    }

    /// An account's state for its card.
    static func accountState(_ a: MailHelperState.Account?, handedOver: Bool) -> (text: String, tone: Tone) {
        guard let a, handedOver else { return ("Not handed over yet", .quiet) }
        switch a.state {
        case "new": return (a.detail.map { "Getting ready: \($0)" } ?? "Getting ready", .busy)
        case "ready": return a.paused ? ("Paused", .quiet) : ("Sorting", .good)
        case "degraded": return ("Having trouble" + (a.detail.map { ": \($0)" } ?? ""), .warn)
        case "reauth": return ("Google refused the sign-in. Hand it over again.", .bad)
        case "disconnected": return ("Disconnected", .quiet)
        default: return (a.state.capitalized, .quiet)
        }
    }

    enum Tone: Equatable { case good, busy, warn, bad, quiet }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func backfillState(_ b: MailHelperState.Backfill) -> String {
        let total = number(b.totals["threads"] ?? b.scanned)
        switch b.state {
        case "scanning": return "Looking through the inbox: \(number(b.scanned)) read so far. Nothing in Gmail changes yet."
        case "ready": return "Plan ready: \(total) conversations. Nothing has moved yet."
        case "applying": return "Moving mail: \(number(b.applied)) of \(total) done."
        case "applied": return "Done: \(number(b.applied)) conversations sorted. Undo all puts every one back."
        case "undone": return "Undone: every conversation is back where it was."
        default: return b.state.capitalized
        }
    }
}
