import Foundation

/// Turns refresh tokens already in the Keychain (from a sign-in test build, a reinstall, or a database that was
/// deleted) into account rows, without ever signing in again.
///
/// Rules: only items named by a UUID are accounts (probe/self-test items such as `probe-1` are not);
/// rows that already exist are left alone; an item that can't be read right now (locked keychain,
/// dark wake) is skipped and retried at the next launch; when several items hold the same address, the
/// newest `savedAt` wins. Nothing here deletes a Keychain item or asks for a password: every read goes
/// through `kSecUseAuthenticationUIFail`.
enum Adoption {
    struct Candidate: Equatable, Sendable {
        let id: UUID
        let credential: StoredCredential
        let createdAt: Date
    }

    struct Plan: Equatable, Sendable {
        var adopt: [Candidate] = []
        /// Items whose address is already connected under another UUID (left in the Keychain).
        var duplicates: [UUID] = []
        /// Items that could not be read this time.
        var unreadable: [UUID] = []
        /// Non-UUID items (probe, self-test).
        var ignored: [String] = []
    }

    static func plan(vault: any AccountVault, existing: [AccountRecord]) -> Plan {
        var plan = Plan()
        let items: [VaultItem]
        do {
            items = try vault.items()
        } catch {
            return plan
        }
        let known = Set(existing.map(\.id))
        let knownAddresses = Set(existing.map { identity($0.provider, $0.email) })

        var readable: [Candidate] = []
        for item in items {
            guard let id = UUID(uuidString: item.account) else {
                plan.ignored.append(item.account)
                continue
            }
            guard !known.contains(id) else { continue }
            guard let credential = try? vault.readCredential(id) else {
                plan.unreadable.append(id)
                continue
            }
            readable.append(Candidate(id: id, credential: credential,
                                      createdAt: item.createdAt ?? credential.savedAt))
        }

        var newest: [String: Candidate] = [:]
        for candidate in readable {
            let key = identity(candidate.credential.provider.rawValue, candidate.credential.email ?? "")
            if knownAddresses.contains(key), !(candidate.credential.email ?? "").isEmpty {
                plan.duplicates.append(candidate.id)
                continue
            }
            // Items without an address can't be compared, so each one stands alone.
            let slot = (candidate.credential.email ?? "").isEmpty ? candidate.id.uuidString : key
            if let other = newest[slot] {
                if candidate.credential.savedAt > other.credential.savedAt {
                    plan.duplicates.append(other.id)
                    newest[slot] = candidate
                } else {
                    plan.duplicates.append(candidate.id)
                }
            } else {
                newest[slot] = candidate
            }
        }
        plan.adopt = newest.values.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        return plan
    }

    /// The row a new account starts with. `existing` decides the free colour, tag and sort order.
    static func newRecord(id: UUID, provider: Provider, email: String, createdAt: Date,
                          existing: [AccountRecord]) -> AccountRecord {
        AccountRecord(
            id: id, provider: provider.rawValue, email: email.lowercased(),
            displayName: AccountNaming.displayName(for: email),
            tag: AccountNaming.tag(for: email, taken: Set(existing.map(\.tag))),
            color: AccountNaming.nextColor(used: existing.map(\.color)),
            logoFile: nil, includeInAll: true, mailEnabled: true, calendarEnabled: true,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1,
            health: .unknown, healthDetail: nil, createdAt: createdAt)
    }

    static func identity(_ provider: String, _ email: String) -> String {
        "\(provider.lowercased())|\(email.lowercased())"
    }
}
