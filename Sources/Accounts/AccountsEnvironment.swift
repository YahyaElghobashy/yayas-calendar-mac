import AppKit
import Foundation

/// One Keychain item under the OAuth service, attributes only (reading attributes never prompts).
struct VaultItem: Equatable, Sendable {
    let account: String
    let createdAt: Date?
}

/// Where connected accounts' refresh tokens live. `TokenVault` in the app; an in-memory fake in tests,
/// which must never touch the real Keychain.
protocol AccountVault: CredentialStore {
    func items() throws -> [VaultItem]
    @discardableResult func deleteCredential(_ accountId: UUID) throws -> Bool
}

extension TokenVault: AccountVault {
    func items() throws -> [VaultItem] {
        try entries().map { VaultItem(account: $0.account, createdAt: $0.createdAt) }
    }

    @discardableResult
    func deleteCredential(_ accountId: UUID) throws -> Bool { try delete(accountId) }
}

/// Where the user's OAuth clients live (Provider Setup). Keychain service
/// `com.yahyaelghobashy.yayascalendar.client` in the app; a fake in tests.
protocol ProviderClientStore: Sendable {
    func load(_ provider: Provider) throws -> ProviderClient?
    func save(_ client: ProviderClient, for provider: Provider) throws
    /// "Remove Google client". Stores that can't delete say so.
    func delete(_ provider: Provider) throws
}

extension ProviderClientStore {
    func delete(_ provider: Provider) throws { throw KeychainError.notFound }
}

struct KeychainClientStore: ProviderClientStore {
    func load(_ provider: Provider) throws -> ProviderClient? { try OAuthConfig.load(provider) }
    func save(_ client: ProviderClient, for provider: Provider) throws { try OAuthConfig.save(client, for: provider) }
    func delete(_ provider: Provider) throws { _ = try OAuthConfig.delete(provider) }
}

/// Everything `AccountsModel` reaches outside itself. `live` is the app; tests and renders build their
/// own with fakes and folders under the worktree's `.work/`.
struct AccountsEnvironment {
    typealias Authorize = @Sendable (_ provider: Provider, _ client: ProviderClient,
                                      _ opener: @escaping OAuthFlow.BrowserOpener,
                                      _ loginHint: String?, _ timeout: TimeInterval) async throws -> AuthorizationResult
    typealias MakeRefresher = @Sendable (_ provider: Provider, _ client: ProviderClient) -> TokenManager.Refresher
    typealias Revoke = @Sendable (_ provider: Provider, _ client: ProviderClient, _ token: String) async -> Bool
    typealias FetchLogo = @Sendable (_ domain: String) async -> Data?
    /// One read-only GET with a bearer token ("Check my setup"); nil when Google couldn't be reached.
    typealias Probe = @Sendable (_ url: URL, _ accessToken: String) async -> (status: Int, body: Data)?

    var storeURL: URL
    var logosDirectory: URL
    var vault: any AccountVault
    var clients: any ProviderClientStore
    var authorize: Authorize
    var makeRefresher: MakeRefresher
    var revoke: Revoke
    var fetchLogo: FetchLogo
    var copyToPasteboard: @MainActor (String) -> Void
    /// "Open in browser" (the default browser in the app; a recorder in tests — never a real browser).
    var openInBrowser: OAuthFlow.BrowserOpener
    /// Where "Import from developer file" looks; nil hides the button. Release builds: always nil (D-035).
    var findDeveloperClient: () -> URL?
    var now: @Sendable () -> Date
    /// How long the add-account loopback waits for the browser.
    var signInTimeout: TimeInterval = LoopbackServer.defaultTimeout
    /// Budget for the best-effort token revoke when an account is removed.
    var revokeBudget: TimeInterval = 5
    /// How long before a locked keychain / offline / hiccup state is checked again.
    var retryDelay: TimeInterval = 300
    /// Where every vault and client-store call runs: one serial background queue, never the main thread
    /// (D-021). Tests pass their own gate (a shorter `slowAfter`).
    var keychain: KeychainGate = .shared
    /// The Google setup guide's links: the user's browser in the app; tests and renders record or drop
    /// them (never a real browser).
    var openURL: @MainActor (URL) -> Void = { _ in }
    /// "Move the download to the Trash" after a client file was imported (the Trash, never a delete).
    var trashFile: @MainActor (URL) -> Bool = { _ in false }
    /// "Check my setup" requests; nil answers mean offline. Tests fake it.
    var probe: Probe = { _, _ in nil }
    /// Settings → "Fetch company logos": when on, connecting a work account asks that company's
    /// website for its icon (disclosed in Settings and on the success screen).
    var autoLogo: () -> Bool = { true }
    /// Where the setup guide remembers its step between launches; nil = this run only.
    var preferences: UserDefaults? = nil

    static var live: AccountsEnvironment {
        AccountsEnvironment(
            storeURL: Paths.store,
            logosDirectory: Paths.logos,
            vault: TokenVault(),
            clients: KeychainClientStore(),
            authorize: { provider, client, opener, hint, timeout in
                try await OAuthFlow(provider: provider, client: client, openBrowser: opener)
                    .authorize(loginHint: hint, timeout: timeout)
            },
            makeRefresher: { provider, client in
                let flow = OAuthFlow(provider: provider, client: client)
                return { try await flow.refresh(using: $0) }
            },
            revoke: { provider, client, token in
                await OAuthFlow(provider: provider, client: client).revoke(token)
            },
            fetchLogo: { domain in await LogoFetcher().fetch(domain: domain) },
            copyToPasteboard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            openInBrowser: OAuthFlow.openInDefaultBrowser,
            findDeveloperClient: {
                #if YC_DEV_TOOLS
                DevClientFile.locate(environment: ProcessInfo.processInfo.environment,
                                     executable: Bundle.main.executableURL)
                #else
                nil   // release builds never look for a developer file (D-035)
                #endif
            },
            now: { Date() },
            openURL: { url in NSWorkspace.shared.open(url) },
            trashFile: { url in (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil },
            probe: { url, token in
                guard let response = try? await HTTP.shared.get(url, bearer: token, byteLimit: 64 << 10) else { return nil }
                return (response.status, response.body)
            },
            autoLogo: { AccountsPreferences.fetchLogos },
            preferences: .standard)
    }
}

/// Runs `operation` but gives up after `seconds`; nil when the budget ran out.
func withTimeBudget<T: Sendable>(_ seconds: TimeInterval,
                                 _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Accounts preferences in UserDefaults (Settings writes them).
enum AccountsPreferences {
    static let fetchLogosKey = "accounts.fetchLogos"

    /// Default on: the fetch is disclosed in Settings and when an account connects.
    static var fetchLogos: Bool {
        get { UserDefaults.standard.object(forKey: fetchLogosKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: fetchLogosKey) }
    }
}
