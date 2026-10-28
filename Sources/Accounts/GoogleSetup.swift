import Foundation

// Bring-your-own Google sign-in (D-038): the six setup steps and their Google
// Cloud pages, the "Why do I need this?" lines, the "Check my setup" probe and the advice for the errors
// a fresh Google project produces. No AppKit here, so the accounts tests read all of it. The console
// pages open in the user's browser (NSWorkspace through `AccountsEnvironment.openURL`), never through HTTP;
// only the two probe requests go through `HTTP`, to hosts already on its allowlist.

/// The Google Cloud pages the guide opens.
enum GoogleConsole {
    static let projectCreate = URL(string: "https://console.cloud.google.com/projectcreate")!
    static let overview = URL(string: "https://console.developers.google.com/auth/overview")!
    static let branding = URL(string: "https://console.developers.google.com/auth/branding")!
    static let audience = URL(string: "https://console.developers.google.com/auth/audience")!
    static let clients = URL(string: "https://console.developers.google.com/auth/clients")!
    /// Where anyone can see and revoke what their Google account has allowed.
    static let permissions = URL(string: "https://myaccount.google.com/permissions")!

    /// Every page the guide may open (tests check the list; nothing else is ever opened from here).
    static var all: [URL] {
        [projectCreate, overview, branding, audience, clients, permissions]
            + GoogleAPIKind.allCases.map { $0.enableURL(projectNumber: nil) }
    }
}

/// The two Google APIs the app needs turned on in the user's project.
enum GoogleAPIKind: String, CaseIterable, Sendable {
    case calendar, gmail

    var name: String {
        switch self {
        case .calendar: return "Google Calendar API"
        case .gmail: return "Gmail API"
        }
    }

    /// Google's service name, as the 403 `SERVICE_DISABLED` details carry it.
    var service: String {
        switch self {
        case .calendar: return "calendar-json.googleapis.com"
        case .gmail: return "gmail.googleapis.com"
        }
    }

    /// The "Enable" page. With the project number (the client ID's leading digits) it opens in the
    /// right project; the link goes to the user's own browser only.
    func enableURL(projectNumber: String?) -> URL {
        var text: String
        switch self {
        case .calendar: text = "https://console.cloud.google.com/flows/enableapi?apiid=\(service)"
        case .gmail: text = "https://console.cloud.google.com/apis/enableflow;apiid=\(service)"
        }
        if let projectNumber, !projectNumber.isEmpty, projectNumber.allSatisfy(\.isNumber) {
            text += (text.contains("?") ? "&" : "?") + "project=\(projectNumber)"
        }
        return URL(string: text)!
    }
}

/// One step of the guide: what to do, and the page that does it.
enum GoogleSetupStep: Int, CaseIterable, Identifiable, Sendable {
    case project = 1, apis, branding, audience, client, file

    var id: Int { rawValue }

    struct Link: Equatable {
        let title: String
        let url: URL
    }

    var title: String {
        switch self {
        case .project: return "Create a Google Cloud project"
        case .apis: return "Turn on the Gmail and Calendar APIs"
        case .branding: return "Name your app"
        case .audience: return "Choose External, then publish"
        case .client: return "Make a Desktop client"
        case .file: return "Drop the file here"
        }
    }

    /// Short lines, in order. `**bold**` marks the words on Google's buttons.
    var lines: [String] {
        switch self {
        case .project:
            return ["Sign in to Google Cloud with any Google account and create a project. Call it something like \u{201C}Yaya\u{2019}s Calendar (mine)\u{201D}.",
                    "No billing account is needed."]
        case .apis:
            return ["Open each link, check the project at the top is yours, and click **Enable**."]
        case .branding:
            return ["In Google Auth Platform click **Get started**. App name: **Yaya\u{2019}s Calendar**. Use your own email for support and contact.",
                    "Google shows this name when you sign in, so pick one you\u{2019}ll recognise."]
        case .audience:
            return ["Choose **External**, then click **Publish app** so it says *In production*.",
                    "Left in Testing, Google signs you out every 7 days. The \u{201C}unverified\u{201D} warning you\u{2019}ll see later is about your own app."]
        case .client:
            return ["Click **Create client** \u{2192} **Desktop app** \u{2192} **Create**.",
                    "Then click **Download JSON** in the dialog that appears. Google shows the secret only once, in that dialog."]
        case .file:
            return ["The file you downloaded in step 5 goes straight into your Keychain.",
                    "Afterwards I\u{2019}ll offer to move the download to the Trash."]
        }
    }

    func links(projectNumber: String? = nil) -> [Link] {
        switch self {
        case .project: return [Link(title: "Create a project", url: GoogleConsole.projectCreate)]
        case .apis:
            return GoogleAPIKind.allCases.reversed().map { Link(title: $0.name, url: $0.enableURL(projectNumber: projectNumber)) }
        case .branding:
            return [Link(title: "Get started", url: GoogleConsole.overview), Link(title: "Branding", url: GoogleConsole.branding)]
        case .audience: return [Link(title: "Open Audience", url: GoogleConsole.audience)]
        case .client: return [Link(title: "Open Clients", url: GoogleConsole.clients)]
        case .file: return []
        }
    }

    var next: GoogleSetupStep? { GoogleSetupStep(rawValue: rawValue + 1) }
    var previous: GoogleSetupStep? { GoogleSetupStep(rawValue: rawValue - 1) }

    /// "Step 2 of 6".
    var counter: String { "Step \(rawValue) of \(Self.allCases.count)" }
}

enum GoogleSetupText {
    static let why = "Why do I need this?"
    /// Three lines, plain (no humour in the Google setup).
    static let whyLines = [
        "I have no server, so there is no shared Google app for me to use.",
        "You make your own private one in Google Cloud. It\u{2019}s free and only you use it.",
        "When Google calls it unverified, it means that app of yours, not someone else\u{2019}s.",
    ]
    static let intro = "Your own private Google sign-in, made in Google Cloud. Free, and only you use it."
    static let consentHint = "When you add an account, Google says it hasn\u{2019}t verified the app. That\u{2019}s the one you made: click **Advanced**, then **Go to Yaya\u{2019}s Calendar (unsafe)**. Google shows your app\u{2019}s name there, the one you gave it in step 3."
}

/// Plain advice for what a fresh Google project gets wrong. No humour (Google setup and errors).
enum GoogleSetupAdvice {
    /// 403 reasons Google uses when an API is off in the project.
    static let disabledReasons: Set<String> = ["accessNotConfigured", "SERVICE_DISABLED"]

    static func isDisabled(reason: String) -> Bool { disabledReasons.contains(reason) }

    static func turnOn(_ api: GoogleAPIKind) -> String {
        "Turn on the \(api.name) in your Google Cloud project, then sync again."
    }

    /// `access_denied` on the consent page.
    static let testingHint = "If your Google app is still in Testing, open Audience in Google Cloud and click Publish app (or add this account as a test user)."

    /// `invalid_grant` about a week after consent.
    static let stillInTesting = "Google signed this account out about a week after you approved it. Your Google app looks like it\u{2019}s still in Testing: open Audience and click Publish app so this stops, then sign in again."

    /// A client file without its secret.
    static let noSecret = "This file has no client secret. Google shows it only once: in Google Cloud \u{2192} Clients \u{2192} your client, add a secret and download the JSON again, or make a new Desktop client."

    /// The client was deleted (Google removes clients unused for 6 months).
    static let clientGone = "Your Google client is gone. Google deletes clients that go unused for 6 months. Make a new Desktop client and drop its file in Google sign-in."

    /// Testing-mode refresh tokens die 7 days after consent; a sign-out 6 to 8 days in is that, most likely.
    static func looksLikeTestingExpiry(consentAt: Date?, now: Date) -> Bool {
        guard let consentAt else { return false }
        let days = now.timeIntervalSince(consentAt) / 86_400
        return days >= 6 && days <= 8
    }

    /// The Google Cloud project number: the client ID's leading digits (used only to deep-link).
    static func projectNumber(clientId: String?) -> String? {
        guard let clientId, let dash = clientId.firstIndex(of: "-") else { return nil }
        let digits = clientId[..<dash]
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) ? String(digits) : nil
    }

    /// Google's error JSON → its reasons (`errors[].reason`, `details[].reason`) and the disabled API
    /// named in `details[].metadata.service`, if any. Nothing else is read.
    static func reasons(in body: Data) -> (reasons: [String], service: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return ([], nil) }
        var reasons: [String] = []
        var service: String?
        for item in error["errors"] as? [[String: Any]] ?? [] {
            if let reason = item["reason"] as? String { reasons.append(reason) }
        }
        for item in error["details"] as? [[String: Any]] ?? [] {
            if let reason = item["reason"] as? String { reasons.append(reason) }
            if let meta = item["metadata"] as? [String: Any], let s = meta["service"] as? String { service = s }
        }
        return (reasons, service)
    }
}

/// "Check my setup": one token refresh, then `calendarList` and `users/me/profile`.
struct GoogleSetupCheck: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case ok
        /// The API is off in the project (403 accessNotConfigured / SERVICE_DISABLED).
        case disabled
        case offline
        case failed(String)
    }

    /// The account the check signed in with (its tag).
    var account: String
    var signIn: Result
    var apis: [GoogleAPIKind: Result]

    var allGood: Bool { signIn == .ok && GoogleAPIKind.allCases.allSatisfy { apis[$0] == .ok } }

    /// The calls the check makes, read-only.
    static func probeURL(_ api: GoogleAPIKind) -> URL {
        switch api {
        case .calendar: return URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=1")!
        case .gmail: return URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
        }
    }

    static func classify(status: Int, body: Data) -> Result {
        if (200..<300).contains(status) { return .ok }
        let found = GoogleSetupAdvice.reasons(in: body)
        if status == 403, found.reasons.contains(where: GoogleSetupAdvice.isDisabled) { return .disabled }
        let reason = found.reasons.first.map { "_" + String($0.prefix(32).filter { $0.isLetter || $0.isNumber }) } ?? ""
        return .failed("http_\(status)\(reason)")
    }

    /// One line per row of the result card.
    func line(for api: GoogleAPIKind) -> String {
        switch apis[api] ?? .failed("not_checked") {
        case .ok: return "\(api.name): on"
        case .disabled: return "\(api.name): off. Turn it on in your project, then check again."
        case .offline: return "\(api.name): couldn\u{2019}t reach Google"
        case .failed(let code): return "\(api.name): Google answered \(code)"
        }
    }

    var signInLine: String {
        switch signIn {
        case .ok: return "Sign-in with \(account): works"
        case .disabled: return "Sign-in with \(account): blocked"
        case .offline: return "Sign-in with \(account): couldn\u{2019}t reach Google"
        case .failed(let code): return "Sign-in with \(account): failed (\(code))"
        }
    }
}

/// What the client-file importer couldn't use, so the guide can say how to fix it.
enum ClientFileProblem: Equatable, Sendable {
    case noSecret
    case webClient
    case notAClientFile
    case tooBig

    var message: String {
        switch self {
        case .noSecret: return GoogleSetupAdvice.noSecret
        case .webClient: return "That\u{2019}s a Web client. Make a Desktop app client instead (Clients \u{2192} Create client \u{2192} Desktop app)."
        case .notAClientFile: return "That isn\u{2019}t a Google client file. Download the Desktop client\u{2019}s JSON from Google Cloud."
        case .tooBig: return "That file is too big to be a Google client file."
        }
    }

    /// Where the fix happens.
    var link: GoogleSetupStep.Link? {
        switch self {
        case .noSecret, .webClient: return GoogleSetupStep.Link(title: "Open Clients", url: GoogleConsole.clients)
        case .notAClientFile, .tooBig: return nil
        }
    }
}

/// "Replace…" with a different client while accounts are connected: their sign-ins belong to the old one.
struct PendingClientSwitch: Equatable, Sendable {
    let client: ProviderClient
    let accounts: Int
    /// The file it came from (offered to the Trash after the switch).
    let source: URL?

    var message: String {
        accounts == 1
            ? "Switching Google clients signs out your 1 account. You\u{2019}ll approve it again."
            : "Switching Google clients signs out all \(accounts) accounts. You\u{2019}ll approve each again."
    }
}
