import Foundation

// Recording per account (D-046), free of AppKit so the test binary checks all of it. Each connected account chooses
// how its meetings are recorded: Fathom, Yaya's Murmur, Ask each time or Off. The choice matters only while Yaya's
// Murmur is on this Mac; without Murmur every surface is exactly what Join with Fathom (D-045) made it.

// MARK: - The choice

/// An account's "Record with" choice, stored per account in the preferences (`recorder.<account UUID>`):
/// absent = automatic, or "fathom", "murmur", "ask", "off".
enum RecorderChoice: Equatable, CaseIterable {
    case automatic, fathom, murmur, ask, off

    var stored: String? {
        switch self {
        case .automatic: return nil
        case .fathom: return "fathom"
        case .murmur: return "murmur"
        case .ask: return "ask"
        case .off: return "off"
        }
    }

    /// Anything unknown reads as automatic.
    init(stored: String?) {
        switch stored {
        case "fathom": self = .fathom
        case "murmur": self = .murmur
        case "ask": self = .ask
        case "off": self = .off
        default: self = .automatic
        }
    }
}

/// What a meeting's recording join does, once the choice is resolved.
enum Recorder: String, Equatable, CaseIterable {
    /// Join with Fathom, in the Fathom account the meeting's account links to (D-045).
    case fathom
    /// Join with Yaya's Murmur: its join link for the event, then the meeting.
    case murmur
    /// "Join and record…" asks which, with the Join menu.
    case ask
    /// Nothing records; Join only joins.
    case off

    /// The words on the account card's picker.
    var title: String {
        switch self {
        case .fathom: return "Fathom"
        case .murmur: return "Yaya\u{2019}s Murmur"
        case .ask: return "Ask each time"
        case .off: return "Off"
        }
    }
}

enum RecorderPrefs {
    static func key(_ account: UUID) -> String { "recorder." + account.uuidString }

    static func choice(_ account: UUID, _ bag: PreferenceBag = DefaultsBag.shared) -> RecorderChoice {
        RecorderChoice(stored: bag.object(key(account)) as? String)
    }

    static func setChoice(_ choice: RecorderChoice, for account: UUID, _ bag: PreferenceBag = DefaultsBag.shared) {
        bag.set(choice.stored, key(account))
    }
}

// MARK: - Resolution

enum RecorderRouting {
    /// One account's recorder while Murmur is on this Mac. Automatic keeps Join with Fathom for an account linked to a
    /// Fathom account (Fathom installed and its link not off) and gives every other account Yaya's Murmur. A Fathom
    /// choice that Fathom can't honour any more (removed from this Mac, or its link turned off) records nothing.
    static func resolve(_ choice: RecorderChoice, fathomInstalled: Bool, fathomLink: FathomLink) -> Recorder {
        let fathomReady = fathomInstalled && fathomLink != .off
        switch choice {
        case .automatic: return fathomReady ? .fathom : .murmur
        case .fathom: return fathomReady ? .fathom : .off
        case .murmur: return .murmur
        case .ask: return .ask
        case .off: return .off
        }
    }

    /// A meeting's recorder: its primary copy's account decides (a merged invite records the way that account says).
    /// nil = Murmur isn't on this Mac: the routing is off and every surface stays as before.
    static func meeting(accountIds: [UUID], murmurInstalled: Bool, fathomInstalled: Bool,
                        link: (UUID) -> FathomLink, choice: (UUID) -> RecorderChoice) -> Recorder? {
        guard murmurInstalled else { return nil }
        guard let primary = accountIds.first else { return .off }
        return resolve(choice(primary), fathomInstalled: fathomInstalled, fathomLink: link(primary))
    }

    /// What a widget's record button and a heads-up's second action do for a meeting with a join link: "fathom",
    /// "murmur", "ask", or nil for none. Without Murmur, exactly D-045: "fathom" when one of its accounts records with
    /// Fathom.
    static func offeredKind(accountIds: [UUID], hasJoin: Bool, murmurInstalled: Bool, fathomInstalled: Bool,
                            link: (UUID) -> FathomLink, choice: (UUID) -> RecorderChoice) -> String? {
        guard hasJoin else { return nil }
        guard let recorder = meeting(accountIds: accountIds, murmurInstalled: murmurInstalled,
                                     fathomInstalled: fathomInstalled, link: link, choice: choice) else {
            return fathomInstalled && FathomRouting.offered(accountIds: accountIds, hasJoin: hasJoin, link: link) ? "fathom" : nil
        }
        return recorder == .off ? nil : recorder.rawValue
    }
}

// MARK: - The Join menu

/// The "▾" beside Join (shown only while Murmur is on this Mac): every way to join this meeting, whatever its account
/// chose. Join with Fathom per linked account, Join with Yaya's Murmur ▸ Home lab / MacBook, and Just join.
enum JoinMenu {
    enum Entry: Equatable {
        case fathom(FathomTarget)
        /// Join with Yaya's Murmur in that mode.
        case murmur(MurmurMode?)
        case justJoin
    }

    struct Item: Equatable {
        let title: String
        /// nil = a submenu (its `children`) or a separator.
        let entry: Entry?
        var children: [Item] = []
        var isSeparator: Bool { title == "-" }
        static let separator = Item(title: "-", entry: nil)
    }

    static func items(fathomTargets: [FathomTarget], murmurInstalled: Bool) -> [Item] {
        var out: [Item] = []
        for t in fathomTargets {
            out.append(Item(title: fathomTargets.count > 1 ? "Join with Fathom \u{00B7} \(t.tag)" : "Join with Fathom",
                            entry: .fathom(t)))
        }
        if murmurInstalled {
            out.append(Item(title: "Join with Yaya\u{2019}s Murmur", entry: nil,
                            children: MurmurMode.allCases.map { Item(title: $0.title, entry: .murmur($0)) }))
        }
        if !out.isEmpty { out.append(.separator) }
        out.append(Item(title: "Just join", entry: .justJoin))
        return out
    }
}

// MARK: - Words

enum RecorderText {
    /// The line under Join with Yaya's Murmur: where it records, when its mark says.
    static func murmurStatus(_ mark: MurmurMark?) -> String {
        if let mode = mark?.mode { return "Yaya\u{2019}s Murmur records it \(mode.place)" }
        return "Yaya\u{2019}s Murmur listens when the call starts"
    }

    /// The account card's line under "Record with".
    static func cardDetail(_ choice: RecorderChoice, resolved: Recorder, fathomInstalled: Bool) -> String {
        let auto = choice == .automatic ? "Automatic: " : ""
        switch resolved {
        case .fathom:
            return auto + "Join with Fathom records this account\u{2019}s meetings in its linked Fathom account."
        case .murmur:
            return auto + "Join with Yaya\u{2019}s Murmur opens the call and has Yaya\u{2019}s Murmur listen on this Mac."
        case .ask:
            return "Join and record\u{2026} asks which recorder, every time."
        case .off:
            if choice == .fathom && !fathomInstalled {
                return "Fathom isn\u{2019}t on this Mac, so this account\u{2019}s meetings record nothing. The \u{25BE} beside Join still offers Yaya\u{2019}s Murmur."
            }
            if choice == .fathom {
                return "Fathom is off for this account below, so its meetings record nothing."
            }
            return "Join only joins. The \u{25BE} beside Join still offers every recorder for one meeting."
        }
    }

    static func joinTitle(_ recorder: Recorder) -> String {
        switch recorder {
        case .fathom: return "Join with Fathom"
        case .murmur: return "Join with Yaya\u{2019}s Murmur"
        case .ask: return "Join and record\u{2026}"
        case .off: return "Join"
        }
    }
}

// MARK: - Settings and Accounts

/// The account cards' "Record with" pickers. Writes the preference and posts `FathomPrefs.changed` (the widgets
/// republish their record buttons, open surfaces reload).
@MainActor
final class RecorderChoicesModel: ObservableObject {
    static let shared = RecorderChoicesModel()

    @Published private(set) var revision = 0
    let fathom: FathomSession
    let murmur: MurmurSession
    private let bag: PreferenceBag
    private let post: () -> Void

    init(bag: PreferenceBag = DefaultsBag.shared, fathom: FathomSession? = nil, murmur: MurmurSession? = nil,
         post: @escaping () -> Void = { NotificationCenter.default.post(name: FathomPrefs.changed, object: nil) }) {
        self.bag = bag
        self.fathom = fathom ?? .shared
        self.murmur = murmur ?? .shared
        self.post = post
    }

    /// The card shows "Record with" only while Murmur is on this Mac.
    var active: Bool { murmur.installed }

    func choice(_ account: UUID) -> RecorderChoice { RecorderPrefs.choice(account, bag) }

    func resolved(_ account: UUID) -> Recorder {
        RecorderRouting.resolve(choice(account), fathomInstalled: fathom.installed, fathomLink: fathom.env.link(account))
    }

    func detail(_ account: UUID) -> String {
        RecorderText.cardDetail(choice(account), resolved: resolved(account), fathomInstalled: fathom.installed)
    }

    /// Picking Fathom for an account whose Fathom link is off turns the link back on (its own address), so the
    /// choice records.
    func set(_ choice: RecorderChoice, for account: UUID, links: FathomLinksModel? = nil) {
        RecorderPrefs.setChoice(choice, for: account, bag)
        if choice == .fathom, let links, links.link(account) == .off { links.set(.ownAddress, for: account) }
        revision += 1
        Trace.app("recorder-choice", ["kind": choice.stored ?? "automatic"])
        post()
    }

    func refresh() {
        fathom.refresh()
        murmur.refresh()
        revision += 1
    }
}
