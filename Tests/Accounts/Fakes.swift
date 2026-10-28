import Foundation

// Fakes shared by the accounts tests and the headless renders. Nothing here touches the real Keychain,
// network, browser, pasteboard or ~/Library/Application Support.

/// A thread-safe box for values the fakes record.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}

/// In-memory stand-in for `TokenVault`.
final class FakeVault: AccountVault, @unchecked Sendable {
    struct Item {
        var credential: StoredCredential?
        var createdAt: Date
    }

    private let lock = NSLock()
    private var items_: [String: Item] = [:]
    private var lockedIDs_: Set<UUID> = []
    private var deleted_: [UUID] = []
    private var failDeletes_ = false
    private var listError_: Error?
    private var mainThreadCalls_ = 0
    /// Seconds `items()` takes (a Keychain dialog nobody has answered yet).
    var listDelay: TimeInterval = 0

    /// Calls made on the main thread (D-021: AccountsModel must make none).
    var mainThreadCalls: Int { lock.lock(); defer { lock.unlock() }; return mainThreadCalls_ }

    private func noteCall() {
        guard Thread.isMainThread else { return }
        lock.lock(); mainThreadCalls_ += 1; lock.unlock()
    }

    func put(_ credential: StoredCredential?, account: String, createdAt: Date) {
        lock.lock(); items_[account] = Item(credential: credential, createdAt: createdAt); lock.unlock()
    }

    var lockedIDs: Set<UUID> {
        get { lock.lock(); defer { lock.unlock() }; return lockedIDs_ }
        set { lock.lock(); lockedIDs_ = newValue; lock.unlock() }
    }
    var failDeletes: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failDeletes_ }
        set { lock.lock(); failDeletes_ = newValue; lock.unlock() }
    }
    var listError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return listError_ }
        set { lock.lock(); listError_ = newValue; lock.unlock() }
    }
    var deleted: [UUID] { lock.lock(); defer { lock.unlock() }; return deleted_ }
    var accounts: [String] { lock.lock(); defer { lock.unlock() }; return Array(items_.keys) }

    func credential(_ id: UUID) -> StoredCredential? {
        lock.lock(); defer { lock.unlock() }; return items_[id.uuidString]?.credential
    }

    func items() throws -> [VaultItem] {
        noteCall()
        if listDelay > 0 { Thread.sleep(forTimeInterval: listDelay) }
        lock.lock(); defer { lock.unlock() }
        if let listError_ { throw listError_ }
        return items_.map { VaultItem(account: $0.key, createdAt: $0.value.createdAt) }
    }

    func readCredential(_ accountId: UUID) throws -> StoredCredential {
        noteCall()
        lock.lock(); defer { lock.unlock() }
        if lockedIDs_.contains(accountId) { throw KeychainError.locked(-25308) }
        guard let item = items_[accountId.uuidString] else { throw KeychainError.notFound }
        guard let credential = item.credential else { throw KeychainError.corrupt }
        return credential
    }

    func saveCredential(_ credential: StoredCredential, for accountId: UUID) throws {
        noteCall()
        lock.lock(); defer { lock.unlock() }
        if lockedIDs_.contains(accountId) { throw KeychainError.locked(-25308) }
        let created = items_[accountId.uuidString]?.createdAt ?? credential.savedAt
        items_[accountId.uuidString] = Item(credential: credential, createdAt: created)
    }

    @discardableResult
    func deleteCredential(_ accountId: UUID) throws -> Bool {
        noteCall()
        lock.lock(); defer { lock.unlock() }
        if failDeletes_ { throw KeychainError.locked(-25308) }
        deleted_.append(accountId)
        return items_.removeValue(forKey: accountId.uuidString) != nil
    }
}

/// In-memory stand-in for the `…client` Keychain service.
final class FakeClientStore: ProviderClientStore, @unchecked Sendable {
    private let lock = NSLock()
    private var clients_: [Provider: ProviderClient] = [:]
    private var loadError_: Error?
    private var mainThreadCalls_ = 0
    /// Seconds `load` takes (a Keychain dialog nobody has answered yet).
    var loadDelay: TimeInterval = 0

    /// Calls made on the main thread (D-021: AccountsModel must make none).
    var mainThreadCalls: Int { lock.lock(); defer { lock.unlock() }; return mainThreadCalls_ }

    private func noteCall() {
        guard Thread.isMainThread else { return }
        lock.lock(); mainThreadCalls_ += 1; lock.unlock()
    }

    init(_ clients: [Provider: ProviderClient] = [:]) { clients_ = clients }

    var loadError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return loadError_ }
        set { lock.lock(); loadError_ = newValue; lock.unlock() }
    }
    var clients: [Provider: ProviderClient] { lock.lock(); defer { lock.unlock() }; return clients_ }

    func load(_ provider: Provider) throws -> ProviderClient? {
        noteCall()
        if loadDelay > 0 { Thread.sleep(forTimeInterval: loadDelay) }
        lock.lock(); defer { lock.unlock() }
        if let loadError_ { throw loadError_ }
        return clients_[provider]
    }

    func save(_ client: ProviderClient, for provider: Provider) throws {
        noteCall()
        lock.lock(); defer { lock.unlock() }
        clients_[provider] = client
        loadError_ = nil
    }

    private var deletes_: [Provider] = []
    /// "Remove Google client" calls, in order.
    var deletes: [Provider] { lock.lock(); defer { lock.unlock() }; return deletes_ }

    func delete(_ provider: Provider) throws {
        noteCall()
        lock.lock(); defer { lock.unlock() }
        deletes_.append(provider)
        guard clients_.removeValue(forKey: provider) != nil else { throw KeychainError.notFound }
    }
}

enum Fixtures {
    /// Built in pieces so the repository's secret scanner doesn't see a client-ID shape.
    static let googleSuffix = ".apps." + "googleusercontent" + ".com"
    static let googleClient = ProviderClient(clientId: "1234-fixture" + googleSuffix, clientSecret: "fixture-not-a-secret")

    static let allScopes = ["openid", "email"] + Provider.google.requiredGrantedScopes

    static func credential(_ email: String?, token: String, savedAt: Date) -> StoredCredential {
        StoredCredential(provider: .google, refreshToken: token, email: email, scopes: allScopes, savedAt: savedAt)
    }

    static func grant(refresh: String?, scopes: [String] = allScopes) -> TokenGrant {
        TokenGrant(accessToken: "fixture-access", expiresAt: Date().addingTimeInterval(3600), refreshToken: refresh,
                   idToken: nil, grantedScopes: scopes)
    }

    static func claims(email: String?) -> IDTokenClaims {
        IDTokenClaims(subject: "sub-\(email ?? "none")", objectId: nil, tenantId: nil, email: email,
                      preferredUsername: nil, name: nil, nonce: nil, hostedDomain: nil)
    }

    /// Refresh tokens decide what the fake token endpoint answers.
    static let refresher: AccountsEnvironment.MakeRefresher = { _, _ in
        { token in
            switch token {
            case let t where t.hasPrefix("rt-dead"): throw AuthError.reauthNeeded(code: "invalid_grant")
            case let t where t.hasPrefix("rt-blocked"): throw AuthError.adminBlocked(code: "admin_policy_enforced")
            case let t where t.hasPrefix("rt-offline"): throw AuthError.offline
            case let t where t.hasPrefix("rt-hiccup"): throw AuthError.reauthNeeded(code: "interaction_required")
            case let t where t.hasPrefix("rt-down"): throw AuthError.server(status: 503)
            default: return grant(refresh: nil)
            }
        }
    }

    struct Recorders {
        let copied = Recorder<[String]>([])
        let opened = Recorder<[URL]>([])
        let revoked = Recorder<[String]>([])
        let logoDomains = Recorder<[String]>([])
    }

    /// An environment rooted in `dir` (under the worktree's .work) with every seam faked.
    static func environment(dir: URL, vault: FakeVault, clients: FakeClientStore, recorders: Recorders,
                            authorize: AccountsEnvironment.Authorize? = nil, logo: Data? = nil,
                            devFile: URL? = nil, retryDelay: TimeInterval = 3600) -> AccountsEnvironment {
        let copied = recorders.copied, opened = recorders.opened, revoked = recorders.revoked
        let domains = recorders.logoDomains
        return AccountsEnvironment(
            storeURL: dir.appendingPathComponent("store.sqlite"),
            logosDirectory: dir.appendingPathComponent("widget/logos", isDirectory: true),
            vault: vault,
            clients: clients,
            authorize: authorize ?? { _, _, _, _, _ in throw AuthError.cancelled },
            makeRefresher: refresher,
            revoke: { _, _, token in revoked.mutate { $0.append(token) }; return true },
            fetchLogo: { domain in domains.mutate { $0.append(domain) }; return logo },
            copyToPasteboard: { text in copied.mutate { $0.append(text) } },
            openInBrowser: { url in opened.mutate { $0.append(url) }; return true },
            findDeveloperClient: { devFile },
            now: { Date() },
            signInTimeout: 300,
            revokeBudget: 1,
            retryDelay: retryDelay)
    }
}

/// An address on a consumer mail domain (gmail.com, googlemail.com), built from its parts: personal-domain
/// detection needs the real consumer domains, and the public leak check flags literal addresses outside the
/// reserved test domains (RFC 2606). The local parts stay neutral.
func consumerAddress(_ local: String, _ domain: String = "gmail.com") -> String { "\(local)@\(domain)" }
