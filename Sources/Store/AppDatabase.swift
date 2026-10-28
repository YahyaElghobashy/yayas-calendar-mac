import Foundation
import SQLite3

// SQLite plumbing adapted from Deck's store (same author, MIT; see THIRD_PARTY_NOTICES.md): WAL, forward-only `user_version` migrations, one connection.

struct DatabaseError: Error, Equatable, CustomStringConvertible {
    let description: String
}

/// The app's SQLite file (`Paths.store`): accounts, settings, calendars and events, sync state, widget
/// settings and state, and mail (threads, bodies, actions, attachments, correspondents), each table added
/// by a forward-only migration below.
///
/// - One connection, owned by one serial queue: every statement — reads included — runs on it, so
///   there is exactly one writer and callers never interleave inside a transaction.
/// - The folder is created 0700 and the file 0600. SQLite gives `-wal`/`-shm` the database file's
///   permissions, so they are 0600 too.
/// - Migrations run forward only, keyed on `PRAGMA user_version`, each in its own transaction.
final class AppDatabase: @unchecked Sendable {
    /// Index i holds the statements that take the schema from version i to i + 1. Append only.
    static let migrations: [[String]] = [
        [
            """
            CREATE TABLE accounts(
              id TEXT PRIMARY KEY NOT NULL,
              provider TEXT NOT NULL,
              email TEXT NOT NULL,
              display_name TEXT NOT NULL,
              tag TEXT NOT NULL,
              color INTEGER NOT NULL,
              logo_file TEXT,
              include_in_all INTEGER NOT NULL DEFAULT 1,
              mail_enabled INTEGER NOT NULL DEFAULT 1,
              calendar_enabled INTEGER NOT NULL DEFAULT 1,
              sort_order INTEGER NOT NULL DEFAULT 0,
              health TEXT NOT NULL DEFAULT 'unknown',
              health_detail TEXT,
              created_at REAL NOT NULL)
            """,
            "CREATE INDEX accounts_sort ON accounts(sort_order, created_at)",
            "CREATE TABLE settings(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)",
        ],
        // v2: Google calendars, events, sync state. Removing an account removes its
        // calendars, and a calendar's events and sync state go with it (ON DELETE CASCADE). `r` is a
        // deterministic id (EventIds.rowId) so it survives re-lists; `busy` = transparency opaque.
        // "end" is quoted everywhere: it is an SQL keyword.
        [
            """
            CREATE TABLE calendars(
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              calendar_id TEXT NOT NULL,
              summary TEXT NOT NULL DEFAULT '',
              selected INTEGER NOT NULL DEFAULT 0,
              color INTEGER,
              access_role TEXT NOT NULL DEFAULT 'reader',
              PRIMARY KEY(account_id, calendar_id))
            """,
            """
            CREATE TABLE events(
              r TEXT PRIMARY KEY NOT NULL,
              account_id TEXT NOT NULL,
              calendar_id TEXT NOT NULL,
              event_id TEXT NOT NULL,
              instance_start REAL NOT NULL,
              ical_uid TEXT NOT NULL DEFAULT '',
              group_id TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '',
              start REAL NOT NULL,
              "end" REAL NOT NULL,
              all_day INTEGER NOT NULL DEFAULT 0,
              busy INTEGER NOT NULL DEFAULT 1,
              location TEXT,
              join_url TEXT,
              web_url TEXT,
              notes TEXT,
              organizer_json TEXT,
              attendees_json TEXT,
              my_response TEXT NOT NULL DEFAULT 'accepted',
              etag TEXT,
              status TEXT NOT NULL DEFAULT 'confirmed',
              updated TEXT,
              UNIQUE(account_id, calendar_id, event_id),
              FOREIGN KEY(account_id, calendar_id) REFERENCES calendars(account_id, calendar_id) ON DELETE CASCADE)
            """,
            "CREATE INDEX events_range ON events(start, \"end\")",
            "CREATE INDEX events_group ON events(group_id)",
            """
            CREATE TABLE sync_state(
              account_id TEXT NOT NULL,
              calendar_id TEXT NOT NULL,
              sync_token TEXT,
              last_list_at REAL,
              PRIMARY KEY(account_id, calendar_id),
              FOREIGN KEY(account_id, calendar_id) REFERENCES calendars(account_id, calendar_id) ON DELETE CASCADE)
            """,
        ],
        // v3: Widget Studio settings per kind, and widget route state per kind + family.
        // Kind-level state (picked day, month shown, range from a widget tap) lives in the row whose
        // family is "*"; `state_set_at` lets midnight clear it. Pages live in the per-family rows.
        [
            """
            CREATE TABLE widget_settings(
              kind TEXT PRIMARY KEY NOT NULL,
              style_json TEXT,
              title TEXT,
              custom_content TEXT,
              account_ids_json TEXT,
              range_days INTEGER NOT NULL DEFAULT 7)
            """,
            """
            CREATE TABLE widget_state(
              kind TEXT NOT NULL,
              family TEXT NOT NULL,
              page INTEGER NOT NULL DEFAULT 1,
              page_set_at REAL,
              selected_day TEXT,
              month_shown TEXT,
              range_days INTEGER,
              state_set_at REAL,
              PRIMARY KEY(kind, family))
            """,
        ],
        // v4: Gmail threads (rows are threads, `r` = MailIds.threadR), per-account mail
        // sync state, mail preferences, the remote-image allow list and the body cache index (files in
        // `<store folder>/mailcache`). Everything per account cascades when the account goes.
        [
            """
            CREATE TABLE mail_threads(
              r TEXT PRIMARY KEY NOT NULL,
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              thread_id TEXT NOT NULL,
              history_id TEXT,
              subject TEXT NOT NULL DEFAULT '',
              sender_name TEXT NOT NULL DEFAULT '',
              sender_email TEXT NOT NULL DEFAULT '',
              snippet TEXT NOT NULL DEFAULT '',
              last_at REAL NOT NULL DEFAULT 0,
              unread INTEGER NOT NULL DEFAULT 0,
              starred INTEGER NOT NULL DEFAULT 0,
              in_inbox INTEGER NOT NULL DEFAULT 1,
              category_primary INTEGER NOT NULL DEFAULT 1,
              message_count INTEGER NOT NULL DEFAULT 0,
              last_message_id_header TEXT,
              labels_json TEXT,
              message_ids_json TEXT,
              UNIQUE(account_id, thread_id))
            """,
            "CREATE INDEX mail_threads_inbox ON mail_threads(account_id, in_inbox, last_at)",
            """
            CREATE TABLE mail_state(
              account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              history_id TEXT,
              last_full_at REAL,
              last_sync_at REAL,
              last_error TEXT,
              unread_inbox INTEGER,
              send_as_name TEXT)
            """,
            """
            CREATE TABLE mail_prefs(
              account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              primary_only INTEGER NOT NULL,
              signature TEXT NOT NULL DEFAULT '')
            """,
            "CREATE TABLE image_allow(sender TEXT PRIMARY KEY NOT NULL)",
            """
            CREATE TABLE body_cache(
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              message_id TEXT NOT NULL,
              thread_r TEXT NOT NULL,
              file TEXT NOT NULL,
              bytes INTEGER NOT NULL,
              accessed_at REAL NOT NULL,
              PRIMARY KEY(account_id, message_id))
            """,
            "CREATE INDEX body_cache_lru ON body_cache(accessed_at)",
        ],
        // v5: the mail action queue. Optimistic changes are applied locally first; a
        // row per action carries what to send (and what to restore on failure), its state
        // (pending → running → done | failed | cancelled | undone) and the undo deadline.
        [
            """
            CREATE TABLE actions(
              id TEXT PRIMARY KEY NOT NULL,
              kind TEXT NOT NULL,
              r TEXT NOT NULL,
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              payload_json TEXT NOT NULL DEFAULT '{}',
              state TEXT NOT NULL DEFAULT 'pending',
              created_at REAL NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              undo_until REAL)
            """,
            "CREATE INDEX actions_r ON actions(r, state)",
            "CREATE INDEX actions_state ON actions(state, created_at)",
        ],
        // v6 (rich mail, D-043): the rich signature (RTFD, base64) beside the plain one; the attachment cache index
        // (files in `<data root>/attachments`, keyed by Gmail part id: attachment ids change on every fetch); the
        // people the user has written to ("Images from people you've written to"). Both new tables are quiet
        // (`quietTables`): writing them moves no write generation, so the widget publisher doesn't re-read.
        [
            "ALTER TABLE mail_prefs ADD COLUMN signature_rich TEXT",
            """
            CREATE TABLE attachment_cache(
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              message_id TEXT NOT NULL,
              part_id TEXT NOT NULL,
              file TEXT NOT NULL,
              bytes INTEGER NOT NULL,
              mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
              sha256 TEXT NOT NULL,
              accessed_at REAL NOT NULL,
              PRIMARY KEY(account_id, message_id, part_id))
            """,
            "CREATE INDEX attachment_cache_lru ON attachment_cache(accessed_at)",
            """
            CREATE TABLE mail_correspondents(
              account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
              address TEXT NOT NULL,
              last_at REAL NOT NULL,
              PRIMARY KEY(account_id, address))
            """,
        ],
    ]

    let url: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: Profile.scoped("store"))
    private let onQueueKey = DispatchSpecificKey<Bool>()

    init(url: URL) throws {
        self.url = url
        queue.setSpecific(key: onQueueKey, value: true)
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DatabaseError(description: "cannot create \(url.lastPathComponent)")
            }
        }
        // An existing file keeps whatever mode it had; tighten it before SQLite copies it to -wal/-shm.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw DatabaseError(description: "cannot open \(url.lastPathComponent): \(message)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA foreign_keys = ON")
        try migrate()
    }

    deinit { sqlite3_close_v2(db) }

    var schemaVersion: Int {
        (try? query("PRAGMA user_version") { $0.int(0) }.first) ?? 0
    }

    // MARK: - Serial access

    /// Runs `body` on the database queue. Re-entrant, so a transaction body can call `run`/`query`.
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: onQueueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    /// `BEGIN IMMEDIATE` … `COMMIT`, rolled back if `body` throws. Nested calls become savepoints, so
    /// a repository method that uses a transaction can be called from inside another one.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try sync {
            let nested = sqlite3_get_autocommit(db) == 0
            try exec(nested ? "SAVEPOINT nested" : "BEGIN IMMEDIATE")
            do {
                let value = try body()
                try exec(nested ? "RELEASE nested" : "COMMIT")
                return value
            } catch {
                if nested {
                    try? exec("ROLLBACK TO nested")
                    try? exec("RELEASE nested")
                } else {
                    try? exec("ROLLBACK")
                }
                throw error
            }
        }
    }

    private func migrate() throws {
        let from = schemaVersion
        guard from < Self.migrations.count else { return }
        for version in from..<Self.migrations.count {
            try transaction {
                for sql in Self.migrations[version] { try exec(sql) }
                try exec("PRAGMA user_version = \(version + 1)")
            }
        }
    }

    // MARK: - Statements

    func exec(_ sql: String) throws {
        try sync {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(err)
                throw DatabaseError(description: "\(message) in: \(sql.prefix(60))")
            }
        }
    }

    /// Runs one statement and returns how many rows it changed.
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        try sync {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError(sql) }
            let changed = Int(sqlite3_changes(db))
            if changed > 0 { noteWrite(sql) }
            return changed
        }
    }

    // MARK: - Write generations

    /// Counters that move on every write, by what the widget snapshots read: `calendar` (events,
    /// calendars, accounts, sync state, settings = last good sync per account) and `mail` (threads, mail
    /// state and prefs, actions, body cache, image allow list).
    /// Widget state and Studio settings don't count: snapshots read those themselves. Quiet tables
    /// (attachment cache, correspondents) don't count either: no snapshot reads them. The publisher
    /// caches what it read from the store until a counter moves (D-019).
    struct Generations: Equatable, Sendable {
        var calendar: UInt64 = 0
        var mail: UInt64 = 0
    }

    var generations: Generations {
        generationLock.lock(); defer { generationLock.unlock() }
        return writeGenerations
    }

    private let generationLock = NSLock()
    private var writeGenerations = Generations()

    static let mailTables: Set<String> = ["mail_threads", "mail_state", "mail_prefs", "actions", "body_cache", "image_allow"]
    static let widgetTables: Set<String> = ["widget_state", "widget_settings"]
    /// Tables no widget snapshot reads (v6): writes to them move neither generation.
    static let quietTables: Set<String> = ["attachment_cache", "mail_correspondents"]

    /// The table an INSERT / UPDATE / DELETE / REPLACE writes (nil for anything else).
    static func writtenTable(_ sql: String) -> String? {
        let words = sql.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "(" }).prefix(6).map { $0.lowercased() }
        guard let verb = words.first else { return nil }
        switch verb {
        case "insert", "replace":
            guard let into = words.firstIndex(of: "into"), into + 1 < words.count else { return nil }
            return words[into + 1]
        case "update":
            var i = 1
            if i < words.count, words[i] == "or" { i += 2 }
            return i < words.count ? words[i] : nil
        case "delete":
            guard words.count > 2, words[1] == "from" else { return nil }
            return words[2]
        default:
            return nil
        }
    }

    private func noteWrite(_ sql: String) {
        let table = Self.writtenTable(sql) ?? "?"
        guard !Self.widgetTables.contains(table), !Self.quietTables.contains(table) else { return }
        generationLock.lock()
        if Self.mailTables.contains(table) {
            writeGenerations.mail &+= 1
        } else {
            writeGenerations.calendar &+= 1
            if table == "?" { writeGenerations.mail &+= 1 }   // unrecognised statement: both, to be safe
        }
        generationLock.unlock()
    }

    func query<T>(_ sql: String, _ args: [Any?] = [], row: (Row) throws -> T) throws -> [T] {
        try sync {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW { out.append(try row(Row(stmt: stmt))); continue }
                if rc == SQLITE_DONE { return out }
                throw lastError(sql)
            }
        }
    }

    /// A row of the statement being stepped. Valid only inside the `query` closure.
    struct Row {
        fileprivate let stmt: OpaquePointer

        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func string(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func optionalString(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError(sql) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as UInt32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default:
                sqlite3_finalize(stmt)
                throw DatabaseError(description: "unsupported value of type \(type(of: arg!))")
            }
        }
        return stmt
    }

    private func lastError(_ sql: String) -> DatabaseError {
        DatabaseError(description: "\(String(cString: sqlite3_errmsg(db))) in: \(sql.prefix(60))")
    }

    // MARK: - Settings

    func setting(_ key: String) throws -> String? {
        try query("SELECT value FROM settings WHERE key = ?", [key]) { $0.string(0) }.first
    }

    func setSetting(_ key: String, _ value: String) throws {
        try run("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [key, value])
    }

    @discardableResult
    func removeSetting(_ key: String) throws -> Bool {
        try run("DELETE FROM settings WHERE key = ?", [key]) > 0
    }
}
