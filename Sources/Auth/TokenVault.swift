// Non-interactive keychain access adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz; portions © the author (MIT). See THIRD_PARTY_NOTICES.md.

import Foundation
import Security

/// Why a keychain call did not succeed.
enum KeychainError: Error, Equatable, Sendable {
    case notFound
    /// The keychain is locked, the Mac is in dark wake, or the read would need a prompt — which is what
    /// a signature that no longer satisfies the item's access list looks like. Transient from the app's
    /// side: retry after unlock or wake. If it persists across unlocks, the signature changed.
    case locked(OSStatus)
    /// Someone clicked Deny, or authentication failed.
    case refused(OSStatus)
    case duplicate
    /// The item exists but holds something this app did not write.
    case corrupt
    case unexpected(OSStatus)
    /// The call didn't run, or hasn't answered within 3 s: macOS is most likely showing its "allow
    /// access" dialog (`KeychainGate`, D-021), or it was asked on the main thread. Transient.
    case waiting

    init(status: OSStatus) {
        switch status {
        case errSecItemNotFound:
            self = .notFound
        // errSecInteractionNotAllowed (-25308), errSecInDarkWake (-25320),
        // errAuthorizationInteractionNotAllowed (-60008), errSecNotAvailable (-25291).
        case errSecInteractionNotAllowed, -25320, -60008, errSecNotAvailable:
            self = .locked(status)
        case errSecAuthFailed, errSecUserCanceled:
            self = .refused(status)
        case errSecDuplicateItem:
            self = .duplicate
        default:
            self = .unexpected(status)
        }
    }

    var isTransient: Bool {
        switch self {
        case .locked, .waiting: return true
        default: return false
        }
    }
}

/// Generic-password items under one service in the user's **file-based** keychain.
///
/// The data-protection keychain flag is deliberately never set: that keychain needs a provisioning
/// profile. File-based items carry an access list keyed to the creating app's designated requirement,
/// plus a partition ID securityd derives from the creator's signature (`teamid:` for Apple-issued
/// certificates, the build's cdhash otherwise). Reads survive rebuilds signed with the same self-signed
/// identity (measured; docs/CONTRACTS.md, Keychain).
///
/// Every query carries kSecUseAuthenticationUIFail, so a background refresh can never put a dialog in
/// front of the user; a call that would have prompted fails with `.locked` instead. That flag does not
/// cover the legacy access-list dialog of a file-based item (live, 2026-10-20), so every call also runs
/// through `KeychainGate`: on its serial background queue, never on the main thread, at most 3 s per
/// caller (`.waiting` after that).
struct KeychainStore: Sendable {
    struct Entry: Equatable, Sendable {
        let account: String
        let label: String?
        let createdAt: Date?
        let modifiedAt: Date?
    }

    let service: String

    /// Never interactive: the base query carries `kSecUseAuthenticationUIFail`, so an item that would need a
    /// dialog fails with an error instead of prompting.
    func read(account: String) throws -> Data {
        var query = scopedQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let request = query
        return try KeychainGate.shared.sync("read") {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &item)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            guard let data = item as? Data else { throw KeychainError.corrupt }
            return data
        }
    }

    /// Updates in place (which keeps the item's access list), adds when missing, and retries the update
    /// once if another writer added it in between.
    func save(_ data: Data, account: String, label: String? = nil) throws {
        let query = scopedQuery(account: account)
        try KeychainGate.shared.sync("save") { try Self.save(data, query: query, label: label) }
    }

    private static func save(_ data: Data, query: [String: Any], label: String?) throws {
        var changes: [String: Any] = [kSecValueData as String: data]
        if let label { changes[kSecAttrLabel as String] = label }

        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.filter { $0.key != (kSecMatchSearchList as String) && $0.key != (kSecUseAuthenticationUI as String) }
            item.merge(changes) { _, new in new }
            if let keychain = KeychainInteraction.defaultKeychain { item[kSecUseKeychain as String] = keychain }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Returns false when there was nothing to delete.
    @discardableResult
    func delete(account: String) throws -> Bool {
        let query = scopedQuery(account: account)
        return try KeychainGate.shared.sync("delete") {
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess: return true
            case errSecItemNotFound: return false
            default: throw KeychainError(status: status)
            }
        }
    }

    /// Attributes only. The access list guards an item's data, not its attributes, so this never
    /// prompts even when a read of the same item would.
    func entries() throws -> [Entry] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let request = query
        let result: CFTypeRef? = try KeychainGate.shared.sync("entries") {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            return result
        }
        guard let result else { return [] }

        // One match can come back as a bare dictionary rather than an array of one.
        let items = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            return Entry(account: account,
                         label: attributes[kSecAttrLabel as String] as? String,
                         createdAt: attributes[kSecAttrCreationDate as String] as? Date,
                         modifiedAt: attributes[kSecAttrModificationDate as String] as? Date)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let keychain = KeychainInteraction.defaultKeychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    private func scopedQuery(account: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        return query
    }
}

/// The keychain the app's items live in.
enum KeychainInteraction {

    /// The user's default (login) keychain. Searches are pinned to it so a locked keychain elsewhere in
    /// the search list (signing keychains, VPN) can neither answer nor fail a lookup.
    static let defaultKeychain: SecKeychain? = {
        var keychain: SecKeychain?
        guard SecKeychainCopyDomainDefault(.user, &keychain) == errSecSuccess else { return nil }
        return keychain
    }()

    // Never call SecKeychainSetUserInteractionAllowed(false): measured 2026-10-19, it makes reads
    // of items written by an earlier build fail with errSecAuthFailed (-25293), while the per-query
    // kSecUseAuthenticationUIFail flag alone reads them silently across rebuilds signed with the same
    // certificate. docs/CONTRACTS.md (Keychain) has the matrix.
}

// MARK: - OAuth refresh tokens

/// What is stored per connected account. Access tokens are never stored; they live in memory only.
struct StoredCredential: Codable, Equatable, Sendable, CustomStringConvertible {
    var v: Int = 1
    var provider: Provider
    var refreshToken: String
    var email: String?
    var scopes: [String]
    var savedAt: Date

    var description: String {
        "StoredCredential(provider: \(provider.rawValue), refreshToken: redacted, scopes: \(scopes.count), savedAt: \(savedAt))"
    }
}

/// Refresh tokens, one keychain item per account: service `Profile.keychainOAuth`
/// (`<bundle id>.oauth`), account = the account's UUID string, data = `StoredCredential` JSON.
struct TokenVault: Sendable {
    static let service = Profile.keychainOAuth

    private let store: KeychainStore

    init(service: String = TokenVault.service) {
        store = KeychainStore(service: service)
    }

    func save(_ credential: StoredCredential, for accountId: UUID) throws {
        let label = "Yaya\u{2019}s Calendar \u{2014} \(credential.email ?? "account") (\(credential.provider.displayName))"
        try store.save(Self.encoder.encode(credential), account: accountId.uuidString, label: label)
    }

    func read(_ accountId: UUID) throws -> StoredCredential {
        let data = try store.read(account: accountId.uuidString)
        do {
            return try Self.decoder.decode(StoredCredential.self, from: data)
        } catch {
            throw KeychainError.corrupt
        }
    }

    @discardableResult
    func delete(_ accountId: UUID) throws -> Bool {
        try store.delete(account: accountId.uuidString)
    }

    /// Every item under the service, attributes only (including non-account items such as probes).
    func entries() throws -> [KeychainStore.Entry] {
        try store.entries()
    }

    /// Accounts whose item name is a UUID, oldest first.
    func accountIDs() throws -> [UUID] {
        try entries()
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            .compactMap { UUID(uuidString: $0.account) }
    }

    // Raw access for self-tests and probes that need an item outside the account namespace.
    func saveRaw(_ data: Data, account: String) throws { try store.save(data, account: account) }
    func readRaw(account: String) throws -> Data { try store.read(account: account) }
    @discardableResult
    func deleteRaw(account: String) throws -> Bool { try store.delete(account: account) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
