import CryptoKit
import Foundation

/// Where the widget-link HMAC key lives: the Keychain in the app, memory in tests.
protocol LinkKeyStore: Sendable {
    /// The stored key, or nil when none was created yet. Throws `KeychainError` (`.locked` = try later).
    func load() throws -> Data?
    func save(_ key: Data) throws
}

/// Keychain service `Profile.keychainLinkKey`, `<bundle id>.linkkey` (docs/CONTRACTS.md). `KeychainStore`
/// pins every query to the login keychain with kSecUseAuthenticationUIFail: never a dialog, and never
/// SecKeychainSetUserInteractionAllowed (docs/CONTRACTS.md, Keychain).
struct KeychainLinkKeyStore: LinkKeyStore {
    static let service = Profile.keychainLinkKey
    static let account = "link-key-v1"

    /// Never on the main thread (D-021): a tap there gets `.waiting` (LinkTokens then keeps its current
    /// key, or an ephemeral one, and loads the stored key in the background).
    func load() throws -> Data? {
        if Thread.isMainThread && !KeychainGate.allowMainThread { throw KeychainError.waiting }
        do {
            return try KeychainStore(service: Self.service).read(account: Self.account)
        } catch KeychainError.notFound {
            return nil
        }
    }

    func save(_ key: Data) throws {
        if Thread.isMainThread && !KeychainGate.allowMainThread { throw KeychainError.waiting }
        try KeychainStore(service: Self.service).save(key, account: Self.account,
                                                      label: "Yaya\u{2019}s Calendar \u{2014} widget link key")
    }
}

/// Link keys (docs/CONTRACTS.md "Link keys"): `k` = base64url (no padding) of the first 12 bytes of
/// HMAC-SHA256(linkkey, r). One key per row id, valid for every route on that row; verified in
/// constant time.
///
/// The 32-byte key is created once. If the Keychain is locked when the agent starts, an in-memory key
/// stands in (links still verify in this session) and `prepare()` swaps in the real one as soon as it
/// can be read; the publisher then rewrites every snapshot.
///
/// The store is read outside the state lock (D-021): `k(for:)` and `verify` on the main thread (a tap)
/// never wait behind a Keychain read, and the main thread never starts one itself while another thread's
/// read is under way (`KeychainLinkKeyStore` refuses the main thread outright).
final class LinkTokens: @unchecked Sendable {
    static let keyBytes = 32
    static let macBytes = 12

    private let store: LinkKeyStore
    private let lock = NSLock()
    /// One store read at a time (never held by the state lock).
    private let io = NSLock()
    private var key: SymmetricKey?
    private var ephemeral = false

    init(store: LinkKeyStore) {
        self.store = store
    }

    var isEphemeral: Bool { lock.lock(); defer { lock.unlock() }; return ephemeral }

    private var hasStoredKey: Bool { lock.lock(); defer { lock.unlock() }; return key != nil && !ephemeral }

    /// Loads (or creates) the stored key. Returns true when the key in use changed.
    @discardableResult
    func prepare() -> Bool {
        if hasStoredKey { return false }
        if Thread.isMainThread {
            // A tap: never wait for a read another thread is doing.
            guard io.try() else { return standIn() }
        } else {
            io.lock()
        }
        defer { io.unlock() }
        if hasStoredKey { return false }
        do {
            var data = try store.load()
            if data?.count != Self.keyBytes {
                try store.save(try SecureRandom.bytes(Self.keyBytes))
                data = try store.load()
            }
            guard let data, data.count == Self.keyBytes else { throw KeychainError.corrupt }
            lock.lock()
            key = SymmetricKey(data: data)
            ephemeral = false
            lock.unlock()
            return true
        } catch {
            return standIn()
        }
    }

    /// No stored key now: keep the key in use, or make an in-memory one. True when one was made.
    private func standIn() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard key == nil else { return false }
        key = SymmetricKey(size: .bits256)
        ephemeral = true
        return true
    }

    func k(for r: String) -> String {
        Data(mac(r).prefix(Self.macBytes)).base64URLEncodedString()
    }

    /// False for stale or forged links. Constant time over the 12 bytes.
    func verify(r: String, k: String) -> Bool {
        guard !r.isEmpty, k.utf8.count == 16, let given = Data(base64URLEncoded: k), given.count == Self.macBytes
        else { return false }
        let expected = Array(mac(r).prefix(Self.macBytes))
        let actual = Array(given)
        var diff: UInt8 = 0
        for i in 0..<Self.macBytes { diff |= expected[i] ^ actual[i] }
        return diff == 0
    }

    private func currentKey() -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    private func mac(_ r: String) -> Data {
        if currentKey() == nil { prepare() }
        let usable = currentKey() ?? SymmetricKey(size: .bits256)
        return Data(HMAC<SHA256>.authenticationCode(for: Data(r.utf8), using: usable))
    }
}
