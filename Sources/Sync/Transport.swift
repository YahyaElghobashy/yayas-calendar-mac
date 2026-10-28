import Foundation

/// How the data layer reaches the network: `HTTP.shared` (allowlisted hosts, no redirects, no
/// cookies) in the app, a fake server in tests.
protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

extension HTTP: HTTPTransport {}

/// Access tokens for one account. `TokenManager` in the app (single flight, cached until 60 s before
/// expiry, never prompts); a fake in tests.
protocol AccessTokenSource: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
    /// After a 401: the next caller refreshes.
    func invalidateAccessToken() async
}

extension TokenManager: AccessTokenSource {}

/// What the sync engine needs from the accounts side (AccountsModel in the app). Account rows
/// themselves are read from the shared store (`AccountRepo`), which AccountsModel keeps current.
protocol SyncAccountsSource: AnyObject, Sendable {
    /// Nil while the provider's OAuth client is missing or unreadable (locked keychain).
    func tokenSource(for accountId: UUID) async -> AccessTokenSource?
    /// Google said `invalid_grant`: only a new sign-in fixes it. Shown as "Sign in again".
    func markReauthNeeded(_ accountId: UUID) async
    /// `api` ("calendar" / "gmail") is turned off in the user's Google project (403 accessNotConfigured /
    /// SERVICE_DISABLED), or answered again. Shown as "Turn on the … API" on the account card.
    func apiAvailability(_ accountId: UUID, api: String, available: Bool) async
}

extension SyncAccountsSource {
    func apiAvailability(_ accountId: UUID, api: String, available: Bool) async {}
}
