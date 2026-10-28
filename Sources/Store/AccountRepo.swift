import Foundation

/// How an account's last token refresh went, as stored in `accounts.health`.
enum HealthState: String, CaseIterable, Sendable {
    /// Never checked (fresh row) or an unrecognised stored value.
    case unknown
    case checking
    case ok
    /// Google said `invalid_grant`: only a new sign-in fixes it.
    case reauthNeeded
    /// Workspace policy or a declined consent blocks the app.
    case adminBlocked
    case offline
    /// Keychain locked, dark wake or a read that would need a prompt: transient, retried later.
    case keychainLocked
    /// The provider's OAuth client is not in the Keychain yet (Provider Setup).
    case setupNeeded
    case failing

    init(stored: String) { self = HealthState(rawValue: stored) ?? .unknown }

    /// States that clear up on their own (the next check retries them).
    var isTransient: Bool {
        switch self {
        case .offline, .keychainLocked, .checking, .unknown: return true
        default: return false
        }
    }
}

/// One row of `accounts`. Provider is kept as its raw string so the store does not depend on Auth.
struct AccountRecord: Equatable, Identifiable, Sendable {
    var id: UUID
    var provider: String
    var email: String
    var displayName: String
    var tag: String
    var color: UInt32
    var logoFile: String?
    var includeInAll: Bool = true
    var mailEnabled: Bool = true
    var calendarEnabled: Bool = true
    var sortOrder: Int = 0
    var health: HealthState = .unknown
    var healthDetail: String? = nil
    var createdAt: Date
}

/// CRUD over `accounts`. Every call is one statement or one transaction on the database queue.
struct AccountRepo: Sendable {
    let db: AppDatabase

    private static let columns = """
        id, provider, email, display_name, tag, color, logo_file, include_in_all, mail_enabled,
        calendar_enabled, sort_order, health, health_detail, created_at
        """

    func all() throws -> [AccountRecord] {
        try db.query("SELECT \(Self.columns) FROM accounts ORDER BY sort_order, created_at, id", row: Self.decode)
            .compactMap { $0 }
    }

    func get(_ id: UUID) throws -> AccountRecord? {
        try db.query("SELECT \(Self.columns) FROM accounts WHERE id = ?", [id.uuidString], row: Self.decode)
            .compactMap { $0 }.first
    }

    func count() throws -> Int {
        try db.query("SELECT count(*) FROM accounts") { $0.int(0) }.first ?? 0
    }

    func insert(_ r: AccountRecord) throws {
        try db.run("""
            INSERT INTO accounts(\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [r.id.uuidString, r.provider, r.email, r.displayName, r.tag, r.color, r.logoFile,
                  r.includeInAll, r.mailEnabled, r.calendarEnabled, r.sortOrder, r.health.rawValue,
                  r.healthDetail, r.createdAt.timeIntervalSince1970])
    }

    /// Writes every column except `id`; returns false when the row does not exist.
    @discardableResult
    func update(_ r: AccountRecord) throws -> Bool {
        try db.run("""
            UPDATE accounts SET provider = ?, email = ?, display_name = ?, tag = ?, color = ?, logo_file = ?,
              include_in_all = ?, mail_enabled = ?, calendar_enabled = ?, sort_order = ?, health = ?,
              health_detail = ?, created_at = ?
            WHERE id = ?
            """, [r.provider, r.email, r.displayName, r.tag, r.color, r.logoFile, r.includeInAll, r.mailEnabled,
                  r.calendarEnabled, r.sortOrder, r.health.rawValue, r.healthDetail,
                  r.createdAt.timeIntervalSince1970, r.id.uuidString]) > 0
    }

    @discardableResult
    func setHealth(_ id: UUID, _ health: HealthState, detail: String?) throws -> Bool {
        try db.run("UPDATE accounts SET health = ?, health_detail = ? WHERE id = ?",
                   [health.rawValue, detail, id.uuidString]) > 0
    }

    @discardableResult
    func delete(_ id: UUID) throws -> Bool {
        try db.run("DELETE FROM accounts WHERE id = ?", [id.uuidString]) > 0
    }

    func nextSortOrder() throws -> Int {
        try db.query("SELECT coalesce(max(sort_order) + 1, 0) FROM accounts") { $0.int(0) }.first ?? 0
    }

    /// Puts `ids` first, in that order, then every other account in its current order; renumbers 0…n-1.
    func reorder(_ ids: [UUID]) throws {
        try db.transaction {
            let current = try all().map(\.id)
            var seen = Set<UUID>()
            let wanted = ids.filter { current.contains($0) && seen.insert($0).inserted }
            let order = wanted + current.filter { !seen.contains($0) }
            for (index, id) in order.enumerated() {
                try db.run("UPDATE accounts SET sort_order = ? WHERE id = ?", [index, id.uuidString])
            }
        }
    }

    /// Moves one account up (negative) or down (positive), clamped to the ends. Returns the new order.
    @discardableResult
    func move(_ id: UUID, by offset: Int) throws -> [UUID] {
        try db.transaction {
            var order = try all().map(\.id)
            guard let from = order.firstIndex(of: id) else { return order }
            let to = min(max(from + offset, 0), order.count - 1)
            order.remove(at: from)
            order.insert(id, at: to)
            try reorder(order)
            return order
        }
    }

    private static func decode(_ row: AppDatabase.Row) -> AccountRecord? {
        guard let id = UUID(uuidString: row.string(0)) else { return nil }
        return AccountRecord(id: id, provider: row.string(1), email: row.string(2), displayName: row.string(3),
                             tag: row.string(4), color: UInt32(truncatingIfNeeded: row.int64(5)),
                             logoFile: row.optionalString(6), includeInAll: row.bool(7), mailEnabled: row.bool(8),
                             calendarEnabled: row.bool(9), sortOrder: row.int(10),
                             health: HealthState(stored: row.string(11)), healthDetail: row.optionalString(12),
                             createdAt: Date(timeIntervalSince1970: row.double(13)))
    }
}
