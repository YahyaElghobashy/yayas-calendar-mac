import CryptoKit
import Foundation

enum MailIds {
    /// The row id `r` of a Gmail thread: deterministic per (account, thread id), short and link-safe.
    static func threadR(accountId: UUID, threadId: String) -> String {
        let bytes = Data(SHA256.hash(data: Data("mail\u{1F}\(accountId.uuidString)\u{1F}\(threadId)".utf8)).prefix(16))
        return "m" + bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// One row of `mail_threads`: a Gmail thread as the inbox shows it.
struct MailThreadRecord: Equatable, Sendable {
    var r: String
    var accountId: UUID
    var threadId: String
    /// Gmail's thread historyId when we last read it: unchanged → no metadata GET on a full resync.
    var historyId: String?
    var subject: String
    var senderName: String
    var senderEmail: String
    var snippet: String
    /// The newest message's internalDate.
    var lastAt: Date
    var unread: Bool
    var starred: Bool
    var inInbox: Bool
    /// In Gmail's Primary tab (CATEGORY_PERSONAL, or no category at all).
    var categoryPrimary: Bool
    var messageCount: Int
    /// The newest message's Message-ID header (replies thread under it).
    var lastMessageIdHeader: String?
    var labels: [String]
    /// Gmail message ids, oldest first (the newest gets the star; the body cache is keyed by them).
    var messageIds: [String]
}

/// `mail_prefs` as stored (the store compiles without the app seam, so this mirrors MailAccountPrefs).
struct MailPrefsRecord: Equatable, Sendable {
    var primaryOnly: Bool
    var signature: String
    /// v6: the rich signature, RTFD as base64 (nil = the plain `signature` in the default font).
    var signatureRich: String? = nil
}

/// `mail_state`: per-account sync bookkeeping. No subjects or addresses.
struct MailStateRecord: Equatable, Sendable {
    var historyId: String?
    var lastFullAt: Date?
    var lastSyncAt: Date?
    var lastError: String?
    /// Gmail's INBOX threadsUnread (accounts that show the whole inbox).
    var unreadInbox: Int?
    /// The primary send-as display name ("Avery Moonfield"), for From.
    var sendAsName: String?
}

struct MailRepo: Sendable {
    let db: AppDatabase

    private static let columns = """
        r, account_id, thread_id, history_id, subject, sender_name, sender_email, snippet, last_at, unread, starred,
        in_inbox, category_primary, message_count, last_message_id_header, labels_json, message_ids_json
        """

    // MARK: Threads

    func upsert(_ t: MailThreadRecord) throws {
        try db.run("""
            INSERT INTO mail_threads(\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, thread_id) DO UPDATE SET history_id = excluded.history_id,
              subject = excluded.subject, sender_name = excluded.sender_name, sender_email = excluded.sender_email,
              snippet = excluded.snippet, last_at = excluded.last_at, unread = excluded.unread,
              starred = excluded.starred, in_inbox = excluded.in_inbox, category_primary = excluded.category_primary,
              message_count = excluded.message_count, last_message_id_header = excluded.last_message_id_header,
              labels_json = excluded.labels_json, message_ids_json = excluded.message_ids_json
            """, [t.r, t.accountId.uuidString, t.threadId, t.historyId, t.subject, t.senderName, t.senderEmail, t.snippet,
                  t.lastAt.timeIntervalSince1970, t.unread, t.starred, t.inInbox, t.categoryPrimary, t.messageCount,
                  t.lastMessageIdHeader, Self.json(t.labels), Self.json(t.messageIds)])
    }

    func thread(r: String) throws -> MailThreadRecord? {
        try db.query("SELECT \(Self.columns) FROM mail_threads WHERE r = ?", [r], row: Self.decode).compactMap { $0 }.first
    }

    func thread(accountId: UUID, threadId: String) throws -> MailThreadRecord? {
        try db.query("SELECT \(Self.columns) FROM mail_threads WHERE account_id = ? AND thread_id = ?",
                     [accountId.uuidString, threadId], row: Self.decode).compactMap { $0 }.first
    }

    /// Inbox rows of these accounts, newest first.
    func inbox(accountIds: [UUID], limit: Int) throws -> [MailThreadRecord] {
        guard !accountIds.isEmpty, limit > 0 else { return [] }
        let marks = Array(repeating: "?", count: accountIds.count).joined(separator: ", ")
        return try db.query("""
            SELECT \(Self.columns) FROM mail_threads WHERE in_inbox = 1 AND account_id IN (\(marks))
            ORDER BY last_at DESC, r LIMIT ?
            """, accountIds.map(\.uuidString) + [limit], row: Self.decode).compactMap { $0 }
    }

    func threads(r ids: [String]) throws -> [MailThreadRecord] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try db.query("SELECT \(Self.columns) FROM mail_threads WHERE r IN (\(marks))", ids, row: Self.decode)
            .compactMap { $0 }
    }

    /// thread id → stored historyId, for one account (skip unchanged threads on a resync).
    func historyIds(accountId: UUID) throws -> [String: String] {
        var out: [String: String] = [:]
        for (id, history) in try db.query("SELECT thread_id, history_id FROM mail_threads WHERE account_id = ? AND in_inbox = 1",
                                          [accountId.uuidString], row: { ($0.string(0), $0.optionalString(1)) }) {
            if let history { out[id] = history }
        }
        return out
    }

    func setFlags(r: String, unread: Bool? = nil, starred: Bool? = nil, inInbox: Bool? = nil) throws {
        if let unread { try db.run("UPDATE mail_threads SET unread = ? WHERE r = ?", [unread, r]) }
        if let starred { try db.run("UPDATE mail_threads SET starred = ? WHERE r = ?", [starred, r]) }
        if let inInbox { try db.run("UPDATE mail_threads SET in_inbox = ? WHERE r = ?", [inInbox, r]) }
    }

    /// After a full list: every inbox row of the account that the list didn't return leaves the inbox.
    @discardableResult
    func markOutOfInbox(accountId: UUID, keeping threadIds: Set<String>) throws -> Int {
        try db.transaction {
            let rows = try db.query("SELECT thread_id FROM mail_threads WHERE account_id = ? AND in_inbox = 1",
                                    [accountId.uuidString]) { $0.string(0) }
            var changed = 0
            for id in rows where !threadIds.contains(id) {
                changed += try db.run("UPDATE mail_threads SET in_inbox = 0 WHERE account_id = ? AND thread_id = ?",
                                      [accountId.uuidString, id])
            }
            return changed
        }
    }

    @discardableResult
    func markOutOfInbox(accountId: UUID, threadId: String) throws -> Bool {
        try db.run("UPDATE mail_threads SET in_inbox = 0 WHERE account_id = ? AND thread_id = ?",
                   [accountId.uuidString, threadId]) > 0
    }

    /// Rows out of the inbox go, unless an action is still running for them or their undo window
    /// (the widget's "Archived · Undo") is open.
    @discardableResult
    func prune(now: Date) throws -> Int {
        try db.run("""
            DELETE FROM mail_threads WHERE in_inbox = 0 AND r NOT IN (
              SELECT r FROM actions WHERE state IN ('pending', 'running') OR (undo_until IS NOT NULL AND undo_until > ?))
            """, [now.timeIntervalSince1970])
    }

    /// Keeps the newest `keep` inbox rows of an account (history can grow the inbox past the full list).
    @discardableResult
    func trimInbox(accountId: UUID, keep: Int) throws -> Int {
        try db.run("""
            UPDATE mail_threads SET in_inbox = 0 WHERE account_id = ? AND in_inbox = 1 AND r NOT IN (
              SELECT r FROM mail_threads WHERE account_id = ? AND in_inbox = 1 ORDER BY last_at DESC LIMIT ?)
            """, [accountId.uuidString, accountId.uuidString, keep])
    }

    func counts(accountId: UUID) throws -> (threads: Int, inbox: Int, unread: Int) {
        try db.query("""
            SELECT count(*), coalesce(sum(in_inbox), 0), coalesce(sum(CASE WHEN in_inbox = 1 AND unread = 1 THEN 1 ELSE 0 END), 0)
            FROM mail_threads WHERE account_id = ?
            """, [accountId.uuidString]) { ($0.int(0), $0.int(1), $0.int(2)) }.first ?? (0, 0, 0)
    }

    // MARK: State

    func state(accountId: UUID) throws -> MailStateRecord {
        try db.query("""
            SELECT history_id, last_full_at, last_sync_at, last_error, unread_inbox, send_as_name FROM mail_state WHERE account_id = ?
            """, [accountId.uuidString]) {
            MailStateRecord(historyId: $0.optionalString(0),
                            lastFullAt: $0.isNull(1) ? nil : Date(timeIntervalSince1970: $0.double(1)),
                            lastSyncAt: $0.isNull(2) ? nil : Date(timeIntervalSince1970: $0.double(2)),
                            lastError: $0.optionalString(3), unreadInbox: $0.isNull(4) ? nil : $0.int(4),
                            sendAsName: $0.optionalString(5))
        }.first ?? MailStateRecord()
    }

    private func ensureState(_ accountId: UUID) throws {
        try db.run("INSERT INTO mail_state(account_id) VALUES (?) ON CONFLICT(account_id) DO NOTHING", [accountId.uuidString])
    }

    func setHistory(accountId: UUID, historyId: String?, fullAt: Date? = nil) throws {
        try db.transaction {
            try ensureState(accountId)
            try db.run("UPDATE mail_state SET history_id = ? WHERE account_id = ?", [historyId, accountId.uuidString])
            if let fullAt {
                try db.run("UPDATE mail_state SET last_full_at = ? WHERE account_id = ?",
                           [fullAt.timeIntervalSince1970, accountId.uuidString])
            }
        }
    }

    func recordSuccess(accountId: UUID, at date: Date) throws {
        try db.transaction {
            try ensureState(accountId)
            try db.run("UPDATE mail_state SET last_sync_at = ?, last_error = NULL WHERE account_id = ?",
                       [date.timeIntervalSince1970, accountId.uuidString])
        }
    }

    func recordError(accountId: UUID, code: String) throws {
        try db.transaction {
            try ensureState(accountId)
            try db.run("UPDATE mail_state SET last_error = ? WHERE account_id = ?", [String(code.prefix(80)), accountId.uuidString])
        }
    }

    func setUnreadInbox(accountId: UUID, _ count: Int?) throws {
        try db.transaction {
            try ensureState(accountId)
            try db.run("UPDATE mail_state SET unread_inbox = ? WHERE account_id = ?", [count, accountId.uuidString])
        }
    }

    /// Optimistic unread change (mark read, archive an unread thread) until the next labels.get.
    func adjustUnreadInbox(accountId: UUID, by delta: Int) throws {
        try db.run("UPDATE mail_state SET unread_inbox = max(0, unread_inbox + ?) WHERE account_id = ? AND unread_inbox IS NOT NULL",
                   [delta, accountId.uuidString])
    }

    func setSendAsName(accountId: UUID, _ name: String?) throws {
        try db.transaction {
            try ensureState(accountId)
            try db.run("UPDATE mail_state SET send_as_name = ? WHERE account_id = ?", [name, accountId.uuidString])
        }
    }

    // MARK: Preferences

    func prefs(accountId: UUID) throws -> MailPrefsRecord? {
        try db.query("SELECT primary_only, signature, signature_rich FROM mail_prefs WHERE account_id = ?", [accountId.uuidString]) {
            MailPrefsRecord(primaryOnly: $0.bool(0), signature: $0.string(1), signatureRich: $0.optionalString(2))
        }.first
    }

    func savePrefs(accountId: UUID, _ prefs: MailPrefsRecord) throws {
        try db.run("""
            INSERT INTO mail_prefs(account_id, primary_only, signature, signature_rich) VALUES (?, ?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET primary_only = excluded.primary_only, signature = excluded.signature,
              signature_rich = excluded.signature_rich
            """, [accountId.uuidString, prefs.primaryOnly, prefs.signature, prefs.signatureRich])
    }

    func allowsImages(sender: String) throws -> Bool {
        try db.query("SELECT 1 FROM image_allow WHERE sender = ?", [sender]) { $0.int(0) }.first != nil
    }

    /// Every sender whose remote images load without asking (Settings → Mail lists them).
    func allowedSenders() throws -> [String] {
        try db.query("SELECT sender FROM image_allow ORDER BY sender", []) { $0.string(0) }
    }

    func setAllowsImages(sender: String, _ allowed: Bool) throws {
        if allowed {
            try db.run("INSERT INTO image_allow(sender) VALUES (?) ON CONFLICT(sender) DO NOTHING", [sender])
        } else {
            try db.run("DELETE FROM image_allow WHERE sender = ?", [sender])
        }
    }

    // MARK: Body cache index

    struct CacheEntry: Equatable, Sendable {
        var accountId: UUID
        var messageId: String
        var file: String
        var bytes: Int
    }

    func cacheEntry(accountId: UUID, messageId: String) throws -> CacheEntry? {
        try db.query("SELECT account_id, message_id, file, bytes FROM body_cache WHERE account_id = ? AND message_id = ?",
                     [accountId.uuidString, messageId], row: Self.decodeCache).compactMap { $0 }.first
    }

    func putCache(_ entry: CacheEntry, threadR: String, at date: Date) throws {
        try db.run("""
            INSERT INTO body_cache(account_id, message_id, thread_r, file, bytes, accessed_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, message_id) DO UPDATE SET thread_r = excluded.thread_r, file = excluded.file,
              bytes = excluded.bytes, accessed_at = excluded.accessed_at
            """, [entry.accountId.uuidString, entry.messageId, threadR, entry.file, entry.bytes, date.timeIntervalSince1970])
    }

    func touchCache(accountId: UUID, messageId: String, at date: Date) throws {
        try db.run("UPDATE body_cache SET accessed_at = ? WHERE account_id = ? AND message_id = ?",
                   [date.timeIntervalSince1970, accountId.uuidString, messageId])
    }

    func deleteCache(accountId: UUID, messageId: String) throws {
        try db.run("DELETE FROM body_cache WHERE account_id = ? AND message_id = ?", [accountId.uuidString, messageId])
    }

    func cacheBytes() throws -> Int {
        try db.query("SELECT coalesce(sum(bytes), 0) FROM body_cache") { $0.int(0) }.first ?? 0
    }

    /// Least recently read first.
    func cacheOldest(limit: Int) throws -> [CacheEntry] {
        try db.query("SELECT account_id, message_id, file, bytes FROM body_cache ORDER BY accessed_at, file LIMIT ?", [limit],
                     row: Self.decodeCache).compactMap { $0 }
    }

    func cacheFiles() throws -> Set<String> {
        Set(try db.query("SELECT file FROM body_cache") { $0.string(0) })
    }

    // MARK: Coding

    static func json(_ list: [String]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func list(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func decode(_ row: AppDatabase.Row) -> MailThreadRecord? {
        guard let account = UUID(uuidString: row.string(1)) else { return nil }
        return MailThreadRecord(r: row.string(0), accountId: account, threadId: row.string(2), historyId: row.optionalString(3),
                                subject: row.string(4), senderName: row.string(5), senderEmail: row.string(6),
                                snippet: row.string(7), lastAt: Date(timeIntervalSince1970: row.double(8)),
                                unread: row.bool(9), starred: row.bool(10), inInbox: row.bool(11),
                                categoryPrimary: row.bool(12), messageCount: row.int(13),
                                lastMessageIdHeader: row.optionalString(14), labels: list(row.optionalString(15)),
                                messageIds: list(row.optionalString(16)))
    }

    private static func decodeCache(_ row: AppDatabase.Row) -> CacheEntry? {
        guard let account = UUID(uuidString: row.string(0)) else { return nil }
        return CacheEntry(accountId: account, messageId: row.string(1), file: row.string(2), bytes: row.int(3))
    }
}

// MARK: - Actions (v5)

enum MailActionKind: String, Sendable, CaseIterable {
    case read, unread, star, unstar, archive, unarchive, trash, untrash, send

    /// The local (optimistic) effect on a thread row; `send` has none.
    func apply(to t: inout MailThreadRecord) {
        switch self {
        case .read: t.unread = false
        case .unread: t.unread = true
        case .star: t.starred = true
        case .unstar: t.starred = false
        case .archive, .trash: t.inInbox = false
        case .unarchive, .untrash: t.inInbox = true
        case .send: break
        }
    }

    var removesFromInbox: Bool { self == .archive || self == .trash }
}

enum MailActionState: String, Sendable {
    case pending, running, done, failed, cancelled, undone
}

struct MailActionRecord: Equatable, Sendable {
    var id: String
    var kind: MailActionKind
    var r: String
    var accountId: UUID
    /// Strings only: what to send, and the values to restore if it fails.
    var payload: [String: String]
    var state: MailActionState
    var createdAt: Date
    var attempts: Int = 0
    var undoUntil: Date?
}

struct ActionRepo: Sendable {
    let db: AppDatabase

    private static let columns = "id, kind, r, account_id, payload_json, state, created_at, attempts, undo_until"

    func insert(_ a: MailActionRecord) throws {
        try db.run("INSERT INTO actions(\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   [a.id, a.kind.rawValue, a.r, a.accountId.uuidString, Self.encode(a.payload), a.state.rawValue,
                    a.createdAt.timeIntervalSince1970, a.attempts, a.undoUntil?.timeIntervalSince1970])
    }

    func get(_ id: String) throws -> MailActionRecord? {
        try db.query("SELECT \(Self.columns) FROM actions WHERE id = ?", [id], row: Self.decode).compactMap { $0 }.first
    }

    /// Moves to `state`; with `from`, only when the row is currently in that state (returns false otherwise).
    @discardableResult
    func setState(_ id: String, _ state: MailActionState, from: MailActionState? = nil) throws -> Bool {
        if let from {
            return try db.run("UPDATE actions SET state = ? WHERE id = ? AND state = ?", [state.rawValue, id, from.rawValue]) > 0
        }
        return try db.run("UPDATE actions SET state = ? WHERE id = ?", [state.rawValue, id]) > 0
    }

    func setAttempts(_ id: String, _ attempts: Int) throws {
        try db.run("UPDATE actions SET attempts = ? WHERE id = ?", [attempts, id])
    }

    func setUndoUntil(_ id: String, _ date: Date?) throws {
        try db.run("UPDATE actions SET undo_until = ? WHERE id = ?", [date?.timeIntervalSince1970, id])
    }

    func setPayload(_ id: String, _ payload: [String: String]) throws {
        try db.run("UPDATE actions SET payload_json = ? WHERE id = ?", [Self.encode(payload), id])
    }

    /// Actions not yet confirmed by Gmail for these rows, oldest first (a sync overlays them).
    func inFlight(r: String) throws -> [MailActionRecord] {
        try db.query("SELECT \(Self.columns) FROM actions WHERE r = ? AND state IN ('pending', 'running') ORDER BY created_at, id",
                     [r], row: Self.decode).compactMap { $0 }
    }

    /// Send actions in these states, oldest first (the outbox sweep keeps their files; rich mail, D-044).
    func sends(in states: [MailActionState]) throws -> [MailActionRecord] {
        guard !states.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: states.count).joined(separator: ", ")
        return try db.query("SELECT \(Self.columns) FROM actions WHERE kind = 'send' AND state IN (\(marks)) ORDER BY created_at, id",
                            states.map { $0.rawValue as Any? }, row: Self.decode).compactMap { $0 }
    }

    func unfinished() throws -> [MailActionRecord] {
        try db.query("SELECT \(Self.columns) FROM actions WHERE state IN ('pending', 'running') ORDER BY created_at, id",
                     row: Self.decode).compactMap { $0 }
    }

    /// Rows archived or trashed whose undo window is still open: r → when (the widget's archivedAt).
    func removedFromInbox(now: Date) throws -> [String: Date] {
        var out: [String: Date] = [:]
        for (r, at) in try db.query("""
            SELECT r, created_at FROM actions WHERE kind IN ('archive', 'trash') AND state IN ('pending', 'running', 'done')
              AND undo_until IS NOT NULL AND undo_until > ? ORDER BY created_at
            """, [now.timeIntervalSince1970], row: { ($0.string(0), Date(timeIntervalSince1970: $0.double(1))) }) {
            out[r] = at
        }
        return out
    }

    /// The earliest open undo window's end (the publisher drops the row then).
    func nextUndoExpiry(now: Date) throws -> Date? {
        try db.query("""
            SELECT min(undo_until) FROM actions WHERE kind IN ('archive', 'trash') AND state IN ('pending', 'running', 'done')
              AND undo_until > ?
            """, [now.timeIntervalSince1970]) { $0.isNull(0) ? nil : Date(timeIntervalSince1970: $0.double(0)) }.first ?? nil
    }

    func count(state: MailActionState) throws -> Int {
        try db.query("SELECT count(*) FROM actions WHERE state = ?", [state.rawValue]) { $0.int(0) }.first ?? 0
    }

    /// Finished actions older than `cutoff` (their undo windows closed long ago).
    @discardableResult
    func purge(before cutoff: Date) throws -> Int {
        try db.run("DELETE FROM actions WHERE state IN ('done', 'failed', 'cancelled', 'undone') AND created_at < ?",
                   [cutoff.timeIntervalSince1970])
    }

    static func encode(_ payload: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func decode(_ row: AppDatabase.Row) -> MailActionRecord? {
        guard let kind = MailActionKind(rawValue: row.string(1)), let account = UUID(uuidString: row.string(3)),
              let state = MailActionState(rawValue: row.string(5)) else { return nil }
        let payload = (row.string(4).data(using: .utf8)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return MailActionRecord(id: row.string(0), kind: kind, r: row.string(2), accountId: account, payload: payload,
                                state: state, createdAt: Date(timeIntervalSince1970: row.double(6)), attempts: row.int(7),
                                undoUntil: row.isNull(8) ? nil : Date(timeIntervalSince1970: row.double(8)))
    }
}
