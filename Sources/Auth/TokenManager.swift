import Foundation

/// Where refresh tokens persist: `TokenVault` in the app, an in-memory store in tests.
protocol CredentialStore: Sendable {
    func readCredential(_ accountId: UUID) throws -> StoredCredential
    func saveCredential(_ credential: StoredCredential, for accountId: UUID) throws
}

extension TokenVault: CredentialStore {
    func readCredential(_ accountId: UUID) throws -> StoredCredential { try read(accountId) }
    func saveCredential(_ credential: StoredCredential, for accountId: UUID) throws { try save(credential, for: accountId) }
}

/// Per-account state surfaced in the app, widgets and popover.
enum AccountHealth: Equatable, Sendable {
    case ok
    case refreshing
    case reauthNeeded(code: String)
    case adminBlocked(code: String)
    case offline
    /// The keychain is locked (or in dark wake); retry after unlock or wake.
    case keychainLocked
    case failing(String)

    init(error: Error) {
        switch error {
        case AuthError.reauthNeeded(let code): self = .reauthNeeded(code: code)
        case AuthError.adminBlocked(let code): self = .adminBlocked(code: code)
        case AuthError.offline: self = .offline
        case let keychain as KeychainError where keychain.isTransient: self = .keychainLocked
        case TokenManagerError.persistFailed(let keychain) where keychain.isTransient: self = .keychainLocked
        default: self = .failing(String(describing: error))
        }
    }
}

enum TokenManagerError: Error, Equatable, Sendable {
    /// The stored credential belongs to the other provider.
    case providerMismatch
    /// A rotated refresh token could not be saved; the access token was withheld so the stored one stays
    /// the newest token anyone has used.
    case persistFailed(KeychainError)
}

/// Hands out access tokens for one account.
///
/// - Single flight: concurrent callers share one refresh.
/// - Caches the access token until 60 s before it expires.
/// - Reads the refresh token from the store on every refresh, so the keychain stays the source of truth.
/// - When the provider rotates the refresh token (Microsoft does on every use), the new one is persisted
///   **before** the access token is returned. If that save fails, the access token is withheld.
actor TokenManager {
    typealias Refresher = @Sendable (_ refreshToken: String) async throws -> TokenGrant

    static let expiryMargin: TimeInterval = 60

    nonisolated let accountId: UUID
    nonisolated let provider: Provider
    private let store: any CredentialStore
    private let refresher: Refresher
    private let now: @Sendable () -> Date

    private var cached: (token: String, expiresAt: Date)?
    private var inflight: Task<String, Error>?
    private(set) var health: AccountHealth = .ok

    init(accountId: UUID, provider: Provider, client: ProviderClient,
         store: any CredentialStore = TokenVault(), http: HTTP = .shared) {
        let flow = OAuthFlow(provider: provider, client: client, http: http)
        self.init(accountId: accountId, provider: provider, store: store,
                  refresher: { try await flow.refresh(using: $0) })
    }

    init(accountId: UUID, provider: Provider, store: any CredentialStore,
         refresher: @escaping Refresher, now: @escaping @Sendable () -> Date = { Date() }) {
        self.accountId = accountId
        self.provider = provider
        self.store = store
        self.refresher = refresher
        self.now = now
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached, cached.expiresAt.timeIntervalSince(now()) > Self.expiryMargin {
            return cached.token
        }
        if let inflight { return try await inflight.value }

        let task = Task { try await self.refreshAndPersist() }
        inflight = task
        defer { if inflight == task { inflight = nil } }
        return try await task.value
    }

    /// Caches the access token from a fresh sign-in so the first API calls skip a refresh.
    func seed(_ grant: TokenGrant) {
        cached = (grant.accessToken, grant.expiresAt)
        health = .ok
    }

    /// After a 401: the next caller refreshes.
    func invalidateAccessToken() {
        cached = nil
    }

    private func refreshAndPersist() async throws -> String {
        health = .refreshing
        do {
            let stored = try store.readCredential(accountId)
            guard stored.provider == provider else { throw TokenManagerError.providerMismatch }

            let grant = try await refresher(stored.refreshToken)
            if let rotated = grant.refreshToken, rotated != stored.refreshToken {
                var updated = stored
                updated.refreshToken = rotated
                updated.savedAt = now()
                if !grant.grantedScopes.isEmpty { updated.scopes = grant.grantedScopes }
                do {
                    try store.saveCredential(updated, for: accountId)
                } catch let error as KeychainError {
                    throw TokenManagerError.persistFailed(error)
                }
            }

            cached = (grant.accessToken, grant.expiresAt)
            health = .ok
            return grant.accessToken
        } catch {
            let next = AccountHealth(error: error)
            switch next {
            case .reauthNeeded, .adminBlocked: cached = nil
            default: break
            }
            health = next
            throw error
        }
    }
}
