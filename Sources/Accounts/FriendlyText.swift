import Foundation

/// Why adding (or re-connecting) an account didn't work, in terms the screen can act on.
enum AddAccountFailure: Error, Equatable, Sendable {
    case cancelled
    case timedOut
    case adminBlocked(code: String)
    case missingScopes([String])
    case offline
    case browserUnavailable
    case loopbackUnavailable
    case clientRejected(code: String)
    case notConfigured
    case keychain
    case noEmail
    case other(code: String)

    init(error: Error) {
        switch error {
        case let failure as AddAccountFailure:
            self = failure
        case let auth as AuthError:
            switch auth {
            case .cancelled: self = .cancelled
            case .timedOut: self = .timedOut
            case .adminBlocked(let code): self = .adminBlocked(code: code)
            case .offline: self = .offline
            case .browserUnavailable: self = .browserUnavailable
            case .loopbackUnavailable: self = .loopbackUnavailable
            case .clientRejected(let code): self = .clientRejected(code: code)
            case .notConfigured: self = .notConfigured
            case .server(let status): self = .other(code: "server \(status)")
            case .reauthNeeded(let code), .provider(let code): self = .other(code: code)
            case .invalidResponse: self = .other(code: "unexpected reply")
            case .missingRefreshToken: self = .other(code: "no refresh token")
            case .nonceMismatch: self = .other(code: "nonce mismatch")
            }
        case is KeychainError, is TokenManagerError:
            self = .keychain
        case is OAuthConfigError:
            self = .notConfigured
        case is CancellationError:
            self = .cancelled
        default:
            self = .other(code: "unexpected")
        }
    }

    var isAdminBlocked: Bool {
        if case .adminBlocked = self { return true }
        return false
    }

    /// `access_denied`: the commonest cause with your own client is a project still in Testing.
    var suggestsPublishing: Bool { self == .adminBlocked(code: "access_denied") }

    var title: String {
        switch self {
        case .cancelled: return "Cancelled"
        case .timedOut: return "That took too long"
        case .adminBlocked(let code):
            return code == "access_denied" ? "Google didn\u{2019}t let me in" : "Blocked by your admin"
        case .missingScopes: return "Some boxes weren\u{2019}t ticked"
        case .offline: return "Can\u{2019}t reach Google"
        case .browserUnavailable: return "Your browser didn\u{2019}t open"
        case .loopbackUnavailable: return "I couldn\u{2019}t listen for Google\u{2019}s answer"
        case .clientRejected(let code) where code == "deleted_client": return "Your Google client is gone"
        case .clientRejected: return "Google didn\u{2019}t accept my sign-in setup"
        case .notConfigured: return "Google sign-in isn\u{2019}t set up yet"
        case .keychain: return "Your Keychain said no"
        case .noEmail: return "Google didn\u{2019}t say which account that was"
        case .other: return "Google said no"
        }
    }

    var message: String {
        switch self {
        case .cancelled:
            return "No harm done. Start again whenever you like."
        case .timedOut:
            return "The sign-in link expired after 5 minutes. Start again when you\u{2019}re ready."
        case .adminBlocked(let code) where code == "access_denied":
            return "Either \u{201C}Cancel\u{201D} got pressed on Google\u{2019}s page, or Google turned the account away. "
                + GoogleSetupAdvice.testingHint
                + " A work account may also need your Workspace admin: the steps are below."
        case .adminBlocked:
            return "Your Google Workspace admin hasn\u{2019}t allowed Yaya\u{2019}s Calendar yet. Send them the steps below, then try again."
        case .missingScopes:
            return "Some boxes weren\u{2019}t ticked \u{2014} try again and tick all of them. I need mail and calendar to fill your widgets."
        case .offline:
            return "Check your connection and try again."
        case .browserUnavailable:
            return "Use \u{201C}Copy sign-in link\u{201D} and paste it into your browser instead."
        case .loopbackUnavailable:
            return "Something on this Mac blocked my little local listener. Try again in a moment."
        case .clientRejected(let code) where code == "deleted_client":
            return GoogleSetupAdvice.clientGone
        case .clientRejected(let code):
            return "Re-check the Google client in \u{201C}Google sign-in\u{201D} below. (\(code))"
        case .notConfigured:
            return "Add your Google client file in \u{201C}Google sign-in\u{201D} below first."
        case .keychain:
            return "I couldn\u{2019}t save the sign-in to your Keychain. Unlock your Mac and try again."
        case .noEmail:
            return "Try again, and pick the account on Google\u{2019}s list."
        case .other(let code):
            return "Try again in a moment. If it keeps happening, this is the code: \(code)."
        }
    }
}

/// Health check outcome → stored state + the line the account card shows.
enum HealthText {
    static func state(for error: Error, provider: Provider = .google) -> (HealthState, String) {
        switch error {
        case AuthError.reauthNeeded(let code):
            // Google ends a refresh token only with invalid_grant; anything else is worth retrying.
            if provider == .microsoft || code == "invalid_grant" || code.hasPrefix("AADSTS") {
                return (.reauthNeeded, detail(.reauthNeeded))
            }
            return (.failing, "Google had a hiccup (\(code)). I\u{2019}ll try again later.")
        case AuthError.adminBlocked:
            return (.adminBlocked, detail(.adminBlocked))
        case AuthError.offline, AuthError.timedOut:
            return (.offline, detail(.offline))
        case AuthError.server:
            return (.failing, "Google is having a moment. I\u{2019}ll try again later.")
        case AuthError.notConfigured:
            return (.setupNeeded, detail(.setupNeeded))
        case AuthError.clientRejected(let code) where code == "deleted_client":
            return (.setupNeeded, GoogleSetupAdvice.clientGone)
        case AuthError.clientRejected(let code):
            return (.failing, "Google didn\u{2019}t accept the sign-in setup (\(code)). Check Google sign-in below.")
        case let keychain as KeychainError:
            return keychainState(keychain)
        case TokenManagerError.persistFailed(let keychain):
            return keychainState(keychain)
        case TokenManagerError.providerMismatch:
            return (.failing, "This sign-in belongs to a different provider.")
        case let auth as AuthError:
            return (.failing, "Something went wrong (\(auth)). I\u{2019}ll try again later.")
        default:
            return (.failing, "Something went wrong. I\u{2019}ll try again later.")
        }
    }

    /// Locked keychain, dark wake, a read that would need a prompt, or a refused read: all of them
    /// clear up without a new sign-in, so none of them ever says "sign in again".
    private static func keychainState(_ error: KeychainError) -> (HealthState, String) {
        switch error {
        case .notFound:
            return (.reauthNeeded, "I lost this sign-in. Sign in again to reconnect.")
        case .corrupt:
            return (.reauthNeeded, "This sign-in got scrambled. Sign in again to reconnect.")
        case .waiting:
            return (.keychainLocked, waitingForKeychain)
        default:
            return (.keychainLocked, detail(.keychainLocked))
        }
    }

    /// A Keychain read past 3 s: macOS is asking whether we may read our own saved sign-in (D-021).
    static let waitingForKeychain = "Waiting for Keychain access. If macOS asks, click Always Allow."

    static func detail(_ state: HealthState) -> String {
        switch state {
        case .ok: return "Connected"
        case .checking: return "Checking\u{2026}"
        case .unknown: return "Not checked yet"
        case .reauthNeeded: return "Google signed this account out. Sign in again to reconnect."
        case .adminBlocked: return "Blocked by your admin"
        case .offline: return "Offline. I\u{2019}ll check again when you\u{2019}re back."
        case .keychainLocked: return "Your Keychain is locked. I\u{2019}ll retry once the Mac is unlocked."
        case .setupNeeded: return "Google sign-in isn\u{2019}t set up yet (see below)."
        case .failing: return "Something went wrong. I\u{2019}ll try again later."
        }
    }

    /// "Connected · checked 2 min ago"
    static func connectedLine(checkedAt: Date?, now: Date) -> String {
        guard let checkedAt else { return "Connected" }
        return "Connected \u{00B7} checked \(relative(checkedAt, now: now))"
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<45: return "just now"
        case ..<3600: return "\(max(1, (seconds + 30) / 60)) min ago"
        case ..<86_400:
            let hours = seconds / 3600
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        default:
            let days = seconds / 86_400
            return days == 1 ? "yesterday" : "\(days) days ago"
        }
    }
}

/// What to send a Workspace admin who blocks the app (D-005: Workspace accounts may need the admin to trust
/// the user's own OAuth client).
enum AdminKit {
    static let steps: [String] = [
        "Open admin.google.com and go to Security \u{2192} Access and data control \u{2192} API controls.",
        "Choose Manage Third-Party App Access \u{2192} Add app \u{2192} OAuth App Name Or Client ID.",
        "Paste the client ID below, select Yaya\u{2019}s Calendar, and set it to Trusted.",
    ]

    static func message(clientID: String?) -> String {
        var lines = ["Hi! Could you allow Yaya\u{2019}s Calendar (a personal Mac app) for my Google account?"]
        lines.append(contentsOf: steps.enumerated().map { "\($0.offset + 1). \($0.element)" })
        lines.append("Client ID: \(clientID ?? "(set up Google sign-in first)")")
        lines.append("Thank you!")
        return lines.joined(separator: "\n")
    }
}
