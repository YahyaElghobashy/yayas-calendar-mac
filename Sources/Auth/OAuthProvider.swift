import Foundation

/// The two identity providers and everything about them that is fixed: endpoints, scopes and the
/// extra authorize parameters each needs. Scopes are requested all at once (Google has no incremental
/// authorization for installed apps).
enum Provider: String, Codable, CaseIterable, Sendable {
    case google
    case microsoft

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .microsoft: return "Microsoft"
        }
    }

    var authorizeURL: URL {
        switch self {
        case .google: return URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        }
    }

    var tokenURL: URL {
        switch self {
        case .google: return URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        }
    }

    /// Microsoft has no OAuth endpoint that revokes a single refresh token; removing an account there
    /// only forgets it locally (the user can remove the app at account.live.com/consent/Manage).
    var revokeURL: URL? {
        switch self {
        case .google: return URL(string: "https://oauth2.googleapis.com/revoke")!
        case .microsoft: return nil
        }
    }

    var scopes: [String] {
        switch self {
        case .google:
            return [
                "openid",
                "email",
                "https://www.googleapis.com/auth/gmail.modify",
                "https://www.googleapis.com/auth/calendar.events",
                "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            ]
        case .microsoft:
            return ["offline_access", "openid", "profile", "email", "User.Read",
                    "Mail.ReadWrite", "Mail.Send", "Calendars.ReadWrite"]
        }
    }

    var scope: String { scopes.joined(separator: " ") }

    /// Google: `access_type=offline` + `prompt=consent` guarantee a refresh token on every sign-in;
    /// `select_account` makes the chooser appear even with one signed-in session, which adding a second
    /// account needs. Microsoft: refresh tokens come from `offline_access`; `select_account` likewise.
    var extraAuthorizeParameters: [(name: String, value: String)] {
        switch self {
        case .google:
            return [("access_type", "offline"), ("prompt", "consent select_account")]
        case .microsoft:
            return [("prompt", "select_account"), ("response_mode", "query")]
        }
    }

    var loopbackBinding: LoopbackServer.Binding {
        switch self {
        case .google: return .ipv4
        case .microsoft: return .localhost
        }
    }

    /// Google's token endpoint rejects Desktop clients without the (non-confidential) secret.
    var requiresClientSecret: Bool { self == .google }

    /// Microsoft rotates the refresh token on every use; the new one must be persisted before use.
    var rotatesRefreshTokens: Bool { self == .microsoft }

    /// Microsoft redeems codes and refresh tokens only for the scopes named again in the request.
    var tokenRequestScope: String? { self == .microsoft ? scope : nil }

    /// The API scopes the app cannot work without, as the token endpoint echoes them back.
    var requiredGrantedScopes: [String] {
        switch self {
        case .google:
            return ["https://www.googleapis.com/auth/gmail.modify",
                    "https://www.googleapis.com/auth/calendar.events",
                    "https://www.googleapis.com/auth/calendar.calendarlist.readonly"]
        case .microsoft:
            return ["Mail.ReadWrite", "Mail.Send", "Calendars.ReadWrite", "User.Read"]
        }
    }

    /// Required scopes missing from a grant: Google's granular consent lets people untick boxes.
    /// Graph may echo scopes fully qualified (`https://graph.microsoft.com/Mail.Send`), so the
    /// comparison is on the last path segment, case-insensitively.
    func missingScopes(granted: [String]) -> [String] {
        let have = Set(granted.map(Self.normalizedScope))
        return requiredGrantedScopes.filter { !have.contains(Self.normalizedScope($0)) }
    }

    private static func normalizedScope(_ scope: String) -> String {
        switch scope.lowercased() {
        case let value where value.hasPrefix("https://graph.microsoft.com/"):
            return String(value.dropFirst("https://graph.microsoft.com/".count))
        case let value:
            return value
        }
    }
}
