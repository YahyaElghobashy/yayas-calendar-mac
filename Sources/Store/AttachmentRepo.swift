import Foundation

// Rich mail (v6, D-043): the attachment cache index and the people the user has written to. Both tables
// are quiet (`AppDatabase.quietTables`): no widget snapshot reads them, so writes move no generation.

/// One row of `attachment_cache`: a Gmail attachment's bytes on disk under `<data root>/attachments`.
/// `file` is a name inside that folder (a hash; never the sender's filename, never a path).
struct AttachmentCacheEntry: Equatable, Sendable {
    var accountId: UUID
    var messageId: String
    /// Gmail part id ("1", "1.2"): stable across fetches, unlike the attachment id.
    var partId: String
    var file: String
    var bytes: Int
    var mimeType: String
    /// Hex SHA-256 of the bytes on disk.
    var sha256: String
    var accessedAt: Date
}

struct AttachmentCacheRepo: Sendable {
    let db: AppDatabase

    private static let columns = "account_id, message_id, part_id, file, bytes, mime_type, sha256, accessed_at"

    func get(accountId: UUID, messageId: String, partId: String) throws -> AttachmentCacheEntry? {
        try db.query("SELECT \(Self.columns) FROM attachment_cache WHERE account_id = ? AND message_id = ? AND part_id = ?",
                     [accountId.uuidString, messageId, partId], row: Self.decode).compactMap { $0 }.first
    }

    /// Insert or replace the row for (account, message, part).
    func put(_ e: AttachmentCacheEntry) throws {
        try db.run("""
            INSERT INTO attachment_cache(\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, message_id, part_id) DO UPDATE SET file = excluded.file, bytes = excluded.bytes,
              mime_type = excluded.mime_type, sha256 = excluded.sha256, accessed_at = excluded.accessed_at
            """, [e.accountId.uuidString, e.messageId, e.partId, e.file, e.bytes, e.mimeType, e.sha256,
                  e.accessedAt.timeIntervalSince1970])
    }

    func touch(accountId: UUID, messageId: String, partId: String, at date: Date) throws {
        try db.run("UPDATE attachment_cache SET accessed_at = ? WHERE account_id = ? AND message_id = ? AND part_id = ?",
                   [date.timeIntervalSince1970, accountId.uuidString, messageId, partId])
    }

    func delete(accountId: UUID, messageId: String, partId: String) throws {
        try db.run("DELETE FROM attachment_cache WHERE account_id = ? AND message_id = ? AND part_id = ?",
                   [accountId.uuidString, messageId, partId])
    }

    /// Settings → Mail "Clear": every row (the caller removes the files).
    @discardableResult
    func deleteAll() throws -> Int {
        try db.run("DELETE FROM attachment_cache")
    }

    /// Total bytes indexed.
    func bytes() throws -> Int {
        try db.query("SELECT coalesce(sum(bytes), 0) FROM attachment_cache") { $0.int(0) }.first ?? 0
    }

    /// Least recently opened first (LRU trim).
    func oldest(limit: Int) throws -> [AttachmentCacheEntry] {
        try db.query("SELECT \(Self.columns) FROM attachment_cache ORDER BY accessed_at, file LIMIT ?", [limit],
                     row: Self.decode).compactMap { $0 }
    }

    /// Every indexed file name (orphan sweep: files on disk without a row are deleted).
    func files() throws -> Set<String> {
        Set(try db.query("SELECT file FROM attachment_cache") { $0.string(0) })
    }

    private static func decode(_ row: AppDatabase.Row) -> AttachmentCacheEntry? {
        guard let account = UUID(uuidString: row.string(0)) else { return nil }
        return AttachmentCacheEntry(accountId: account, messageId: row.string(1), partId: row.string(2), file: row.string(3),
                                    bytes: row.int(4), mimeType: row.string(5), sha256: row.string(6),
                                    accessedAt: Date(timeIntervalSince1970: row.double(7)))
    }
}

/// `mail_correspondents`: addresses the user has written to (or replied to), per account, for "Images from
/// people you've written to" (`mail.images.fromCorrespondents`, off by default; recorded only while it is on, and every
/// row is deleted when it is turned off). Addresses are stored trimmed and lowercased; anything without an "@" is
/// ignored, and so are the user's own addresses (every connected account's): a sender claiming to be you never counts.
struct CorrespondentRepo: Sendable {
    let db: AppDatabase

    static func key(_ address: String) -> String? {
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = key.firstIndex(of: "@"), at != key.startIndex, key.index(after: at) != key.endIndex,
              !key.contains(where: { $0.isWhitespace }) else { return nil }
        return key
    }

    /// Records `addresses` for `accountId` (keeps the newest `last_at`), leaving out your own. Returns how many were
    /// recorded. `enabled` is asked again inside the write transaction: the setting is saved off before `removeAll()`
    /// runs on the same serial queue, so a sync or send that checked it a moment earlier records nothing after the clear.
    @discardableResult
    func add(accountId: UUID, addresses: [String], at date: Date, onlyIf enabled: () -> Bool = { true }) throws -> Int {
        let own = try ownAddresses()
        let keys = Array(Set(addresses.compactMap(Self.key)).subtracting(own)).sorted()
        guard !keys.isEmpty else { return 0 }
        return try db.transaction {
            guard enabled() else { return 0 }
            for key in keys {
                try db.run("""
                    INSERT INTO mail_correspondents(account_id, address, last_at) VALUES (?, ?, ?)
                    ON CONFLICT(account_id, address) DO UPDATE SET last_at = max(last_at, excluded.last_at)
                    """, [accountId.uuidString, key, date.timeIntervalSince1970])
            }
            return keys.count
        }
    }

    /// Forgets every recorded address, all accounts ("Images from people you've written to" turned off). Returns how
    /// many rows went.
    @discardableResult
    func removeAll() throws -> Int {
        try db.run("DELETE FROM mail_correspondents")
    }

    /// How many rows are recorded, all accounts.
    func count() throws -> Int {
        try db.query("SELECT COUNT(*) FROM mail_correspondents") { $0.int(0) }.first ?? 0
    }

    /// Every connected account's address, lowercased.
    func ownAddresses() throws -> Set<String> {
        Set(try db.query("SELECT email FROM accounts") { $0.string(0) }.compactMap(Self.key))
    }

    /// Has the user written to `address` from any account (or from `accountId` when given)?
    func contains(_ address: String, accountId: UUID? = nil) throws -> Bool {
        guard let key = Self.key(address) else { return false }
        if let accountId {
            return try db.query("SELECT 1 FROM mail_correspondents WHERE account_id = ? AND address = ? LIMIT 1",
                                [accountId.uuidString, key]) { $0.int(0) }.first != nil
        }
        return try db.query("SELECT 1 FROM mail_correspondents WHERE address = ? LIMIT 1", [key]) { $0.int(0) }.first != nil
    }
}
