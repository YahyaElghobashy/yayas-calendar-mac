import Foundation

// The welcome guide's steps and where it resumes, free of AppKit and the accounts store so the
// test binary checks them. OnboardingView draws them; OnboardingModel feeds in the facts.

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case google = 1, accounts, looks, widget, notifications, running

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .google: return "Set up Google sign-in"
        case .accounts: return "Connect your accounts"
        case .looks: return "Give each one a logo and colour"
        case .widget: return "Put your first widget on the desktop"
        case .notifications: return "Let me tap you on the shoulder"
        case .running: return "Keep me running"
        }
    }

    var detail: String {
        switch self {
        case .google: return "Google wants a client of your own before any app reads your mail. About 5 minutes, once. I\u{2019}ll walk you through it."
        case .accounts: return "Workspace or personal Gmail, as many as you like. Each signs in on Google\u{2019}s own page."
        case .looks: return "So every meeting and message says whose it is at a glance."
        case .widget: return "Three clicks. macOS won\u{2019}t let me place it for you, but I\u{2019}ll point the way."
        case .notifications: return "A nudge a minute before a meeting, with Join right there. Or press \(JoinHotkey.display) from anywhere to join the next one."
        case .running: return "Start with your Mac, quietly in the menu bar, so your widgets always have someone to talk to."
        }
    }
}

/// What the guide knows about the Mac right now.
struct OnboardingFacts: Equatable {
    var googleReady = false
    var accounts = 0
    /// "Looks good" was pressed on the logos and colours step (stored).
    var looksConfirmed = false
    /// A widget was found on the desktop, or "I've added one" was pressed (stored).
    var widgetPlaced = false
    /// granted | denied | undetermined (the installer flags' words, `SuiteJSON`).
    var notifications = "undetermined"
    /// The login item is on, or "Not now" was pressed on the last step (stored).
    var runningSettled = false
}

enum OnboardingFlow {
    static let stepKey = "onboarding.step"
    static let looksKey = "onboarding.looksConfirmed"
    static let widgetKey = "onboarding.widgetPlaced"
    /// "Not now" on Keep me running.
    static let runningKey = "onboarding.runningDecided"
    /// When the guide was finished: set when it closes with an account connected or every step done.
    static let completedKey = "onboarding.completedAt"

    static func isDone(_ step: OnboardingStep, _ f: OnboardingFacts) -> Bool {
        switch step {
        case .google: return f.googleReady
        case .accounts: return f.accounts > 0
        case .looks: return f.looksConfirmed
        case .widget: return f.widgetPlaced
        case .notifications: return f.notifications != "undetermined"
        case .running: return f.runningSettled
        }
    }

    /// Accounts need Google sign-in first; logos need an account.
    static func isAvailable(_ step: OnboardingStep, _ f: OnboardingFacts) -> Bool {
        switch step {
        case .accounts: return f.googleReady
        case .looks: return f.accounts > 0
        default: return true
        }
    }

    static func doneCount(_ f: OnboardingFacts) -> Int { OnboardingStep.allCases.filter { isDone($0, f) }.count }

    /// The first step that still needs doing and can be done now.
    static func firstOpen(_ f: OnboardingFacts) -> OnboardingStep? {
        OnboardingStep.allCases.first { !isDone($0, f) && isAvailable($0, f) }
    }

    /// Where the guide opens: the step you were on, if it still needs you; else the first open one;
    /// else the last step (everything done).
    static func resume(_ f: OnboardingFacts, stored: Int?) -> OnboardingStep {
        if let stored, let step = OnboardingStep(rawValue: stored), !isDone(step, f), isAvailable(step, f) { return step }
        return firstOpen(f) ?? OnboardingStep.allCases[OnboardingStep.allCases.count - 1]
    }

    /// After a step completes: move on if the step shown is now done.
    static func advance(from shown: OnboardingStep, _ f: OnboardingFacts) -> OnboardingStep {
        guard isDone(shown, f) else { return shown }
        return OnboardingStep.allCases.first { $0.rawValue > shown.rawValue && !isDone($0, f) && isAvailable($0, f) }
            ?? firstOpen(f) ?? shown
    }

    /// "2 of 6 done" / "All set".
    static func progress(_ f: OnboardingFacts) -> String {
        let done = doneCount(f)
        return done == OnboardingStep.allCases.count ? "All set" : "\(done) of \(OnboardingStep.allCases.count) done"
    }

    /// "Six short steps" (the guide's subtitle follows the step count).
    static var countWord: String {
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]
        let n = OnboardingStep.allCases.count
        return n < words.count ? words[n] : "\(n)"
    }

    /// A plain launch opens the window and the guide when nothing is connected yet and the guide was
    /// never finished. An installer's `--onboarding` opens it on its own.
    static func opensOnLaunch(accounts: Int, completedAt: Date?, suiteRequested: Bool, storeOpen: Bool) -> Bool {
        !suiteRequested && storeOpen && accounts == 0 && completedAt == nil
    }

    /// Closing the guide counts as finishing it once an account is connected (or everything is done);
    /// closed with nothing connected, it opens again next launch.
    static func finishes(_ f: OnboardingFacts) -> Bool {
        f.accounts > 0 || doneCount(f) == OnboardingStep.allCases.count
    }
}

// MARK: - Move me to Applications (D-039)

/// What one copy of the app on disk looks like, for deciding whether this one may take its place.
struct BundleFacts: Equatable {
    var path: String
    /// CFBundleVersion: dotted numbers, compared field by field (`AppPlacement.isNewer`).
    var version: String
    /// The signing certificate's fingerprint; nil for ad-hoc or unsigned.
    var signer: String?
    /// That copy is running right now.
    var running = false
}

enum PlacementChoice: Equatable {
    /// Already in /Applications or ~/Applications.
    case inApplications
    /// /Applications is free, or holds an older copy signed the same way (`replacing`).
    case moveToApplications(replacing: Bool)
    /// /Applications holds a copy that isn't ours to replace: offer ~/Applications or "Not now".
    case offerUserApplications(reason: String)
    /// Neither place takes this copy.
    case notNow(reason: String)
}

enum AppPlacement {
    static func isInApplications(_ path: String, home: String) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Never replaces a copy signed by someone else, a newer one or one that's running: those stay, and
    /// ~/Applications is offered instead (if it is free or holds an older copy of ours).
    static func decide(current: BundleFacts, system: BundleFacts?, user: BundleFacts?, home: String) -> PlacementChoice {
        if isInApplications(current.path, home: home) { return .inApplications }
        guard let system else { return .moveToApplications(replacing: false) }
        if let reason = refusal(current: current, existing: system) {
            if let user, let userReason = refusal(current: current, existing: user) {
                return .notNow(reason: reason + " " + userReason.replacingOccurrences(of: "Applications", with: "your own Applications folder"))
            }
            return .offerUserApplications(reason: reason)
        }
        return .moveToApplications(replacing: true)
    }

    /// Why `existing` must stay, or nil when this copy may replace it.
    static func refusal(current: BundleFacts, existing: BundleFacts) -> String? {
        if existing.running { return "The copy in Applications is running." }
        guard let mine = current.signer, let theirs = existing.signer, mine == theirs else {
            return "The copy in Applications is signed by someone else."
        }
        if isNewer(existing.version, than: current.version) { return "Applications already has a newer copy." }
        return nil
    }

    /// Dotted numeric versions, field by field as numbers ("20261102.10" > "20261102.9" > "20261101.3"); non-numbers
    /// compare as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
