import Foundation

/// One row of `calendars`: a calendar from the account's calendar list.
struct CalendarRecord: Equatable, Sendable {
    var accountId: UUID
    var calendarId: String
    var summary: String
    /// Included in the app (Google's own "selected" flag, minus hidden and free/busy-only calendars).
    var selected: Bool
    /// 0xRRGGBB from the calendar list, if any.
    var color: UInt32?
    /// owner | writer | reader | freeBusyReader
    var accessRole: String
}

/// CRUD over `calendars`. Never `INSERT OR REPLACE`: that deletes the row first, and the cascade would
/// take the calendar's events and sync state with it.
struct CalendarRepo: Sendable {
    let db: AppDatabase

    private static let columns = "account_id, calendar_id, summary, selected, color, access_role"

    func all(accountId: UUID? = nil) throws -> [CalendarRecord] {
        if let accountId {
            return try db.query("SELECT \(Self.columns) FROM calendars WHERE account_id = ? ORDER BY calendar_id",
                                [accountId.uuidString], row: Self.decode).compactMap { $0 }
        }
        return try db.query("SELECT \(Self.columns) FROM calendars ORDER BY account_id, calendar_id", row: Self.decode)
            .compactMap { $0 }
    }

    func selected(accountId: UUID) throws -> [CalendarRecord] {
        try all(accountId: accountId).filter(\.selected)
    }

    func get(accountId: UUID, calendarId: String) throws -> CalendarRecord? {
        try db.query("SELECT \(Self.columns) FROM calendars WHERE account_id = ? AND calendar_id = ?",
                     [accountId.uuidString, calendarId], row: Self.decode).compactMap { $0 }.first
    }

    func upsert(_ c: CalendarRecord) throws {
        try db.run("""
            INSERT INTO calendars(\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, calendar_id) DO UPDATE SET summary = excluded.summary,
              selected = excluded.selected, color = excluded.color, access_role = excluded.access_role
            """, [c.accountId.uuidString, c.calendarId, c.summary, c.selected, c.color.map { Int64($0) },
                  c.accessRole])
    }

    /// Makes the account's calendars exactly `list`: upserts every entry, drops calendars that left the
    /// list (their events and sync state cascade) and clears events + sync state of calendars that are
    /// no longer selected. Returns the ids that were removed or deselected.
    @discardableResult
    func replace(accountId: UUID, with list: [CalendarRecord]) throws -> [String] {
        try db.transaction {
            let before = try all(accountId: accountId)
            let keep = Set(list.map(\.calendarId))
            var dropped: [String] = []
            for old in before where !keep.contains(old.calendarId) {
                try db.run("DELETE FROM calendars WHERE account_id = ? AND calendar_id = ?",
                           [accountId.uuidString, old.calendarId])
                dropped.append(old.calendarId)
            }
            for c in list {
                try upsert(c)
                if !c.selected {
                    let removed = try db.run("DELETE FROM events WHERE account_id = ? AND calendar_id = ?",
                                             [accountId.uuidString, c.calendarId])
                    try db.run("DELETE FROM sync_state WHERE account_id = ? AND calendar_id = ?",
                               [accountId.uuidString, c.calendarId])
                    if removed > 0 || before.contains(where: { $0.calendarId == c.calendarId && $0.selected }) {
                        dropped.append(c.calendarId)
                    }
                }
            }
            return dropped
        }
    }

    func count(accountId: UUID) throws -> (all: Int, selected: Int) {
        let rows = try db.query("SELECT count(*), coalesce(sum(selected), 0) FROM calendars WHERE account_id = ?",
                                [accountId.uuidString]) { ($0.int(0), $0.int(1)) }
        return rows.first ?? (0, 0)
    }

    private static func decode(_ row: AppDatabase.Row) -> CalendarRecord? {
        guard let id = UUID(uuidString: row.string(0)) else { return nil }
        return CalendarRecord(accountId: id, calendarId: row.string(1), summary: row.string(2), selected: row.bool(3),
                              color: row.isNull(4) ? nil : UInt32(truncatingIfNeeded: row.int64(4)),
                              accessRole: row.string(5))
    }
}

/// `sync_state`: the change-feed token and the last full window list, per calendar.
struct SyncStateRepo: Sendable {
    let db: AppDatabase

    struct State: Equatable, Sendable {
        var syncToken: String?
        var lastListAt: Date?
    }

    func get(accountId: UUID, calendarId: String) throws -> State {
        try db.query("SELECT sync_token, last_list_at FROM sync_state WHERE account_id = ? AND calendar_id = ?",
                     [accountId.uuidString, calendarId]) {
            State(syncToken: $0.optionalString(0),
                  lastListAt: $0.isNull(1) ? nil : Date(timeIntervalSince1970: $0.double(1)))
        }.first ?? State()
    }

    func setToken(_ token: String?, accountId: UUID, calendarId: String) throws {
        try db.run("""
            INSERT INTO sync_state(account_id, calendar_id, sync_token) VALUES (?, ?, ?)
            ON CONFLICT(account_id, calendar_id) DO UPDATE SET sync_token = excluded.sync_token
            """, [accountId.uuidString, calendarId, token])
    }

    func setListed(_ date: Date, accountId: UUID, calendarId: String) throws {
        try db.run("""
            INSERT INTO sync_state(account_id, calendar_id, last_list_at) VALUES (?, ?, ?)
            ON CONFLICT(account_id, calendar_id) DO UPDATE SET last_list_at = excluded.last_list_at
            """, [accountId.uuidString, calendarId, date.timeIntervalSince1970])
    }

    func lastList(accountId: UUID) throws -> Date? {
        try db.query("SELECT max(last_list_at) FROM sync_state WHERE account_id = ?", [accountId.uuidString]) {
            $0.isNull(0) ? nil : Date(timeIntervalSince1970: $0.double(0))
        }.first ?? nil
    }

    func tokenCount(accountId: UUID) throws -> Int {
        try db.query("SELECT count(sync_token) FROM sync_state WHERE account_id = ?", [accountId.uuidString]) {
            $0.int(0)
        }.first ?? 0
    }
}

/// Per-account sync outcome in `settings` (`sync.ok.<uuid>` = epoch seconds of the last successful
/// sync, `sync.err.<uuid>` = a short PII-free code). Survives relaunches, so the widget's "stale" state
/// is right from the first publish.
struct SyncStatusRepo: Sendable {
    let db: AppDatabase

    static func okKey(_ id: UUID) -> String { "sync.ok.\(id.uuidString)" }
    static func errorKey(_ id: UUID) -> String { "sync.err.\(id.uuidString)" }

    func lastSuccess(_ id: UUID) -> Date? {
        guard let value = try? db.setting(Self.okKey(id)), let seconds = Double(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func lastError(_ id: UUID) -> String? { (try? db.setting(Self.errorKey(id))) ?? nil }

    func recordSuccess(_ id: UUID, at date: Date) {
        try? db.setSetting(Self.okKey(id), String(date.timeIntervalSince1970))
        _ = try? db.removeSetting(Self.errorKey(id))
    }

    func recordError(_ id: UUID, code: String) {
        try? db.setSetting(Self.errorKey(id), String(code.prefix(80)))
    }

    /// Drops the keys of accounts that no longer exist.
    func prune(keeping ids: Set<UUID>) {
        let keys = (try? db.query("SELECT key FROM settings WHERE key LIKE 'sync.ok.%' OR key LIKE 'sync.err.%'") {
            $0.string(0)
        }) ?? []
        for key in keys {
            guard let id = UUID(uuidString: String(key.split(separator: ".").last ?? "")), !ids.contains(id) else { continue }
            _ = try? db.removeSetting(key)
        }
    }
}
