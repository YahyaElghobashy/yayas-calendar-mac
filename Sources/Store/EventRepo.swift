import CryptoKit
import Foundation

/// Deterministic ids. Both are short base64url strings (safe in `yayacal://` links, no PII).
enum EventIds {
    /// The row id `r`: the same event in the same calendar always gets the same `r`, even after it
    /// left the window and came back.
    static func rowId(accountId: UUID, calendarId: String, eventId: String) -> String {
        "e" + digest("\(accountId.uuidString)\u{1F}\(calendarId)\u{1F}\(eventId)")
    }

    /// Merged invites: the same meeting (iCalUID + instance start) in several accounts shares this id.
    static func groupId(icalUID: String, instanceStart: Date) -> String {
        "g" + digest("\(icalUID)\u{1F}\(Int64(instanceStart.timeIntervalSince1970.rounded()))")
    }

    /// 16 bytes of SHA-256 → 22 base64url characters.
    private static func digest(_ text: String) -> String {
        let bytes = Data(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One row of `events`: one copy of one occurrence in one calendar. Times are absolute instants (UTC);
/// all-day events start and end at local midnight of their dates (end exclusive).
struct EventRecord: Equatable, Sendable {
    var r: String
    var accountId: UUID
    var calendarId: String
    var eventId: String
    /// The occurrence's original start (recurring instances) or its start; with the iCalUID it names
    /// the meeting across accounts.
    var instanceStart: Date
    var icalUID: String
    var groupId: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    /// Blocks time (Google transparency "opaque", the default).
    var busy: Bool = true
    var location: String?
    var joinURL: String?
    var webURL: String?
    var notes: String?
    var organizerJSON: String?
    var attendeesJSON: String?
    /// accepted | tentative | declined | needsAction
    var myResponse: String = "accepted"
    var etag: String?
    var status: String = "confirmed"
    var updated: String?
}

/// CRUD over `events`. Upserts key on (account_id, calendar_id, event_id) and never touch `r`.
struct EventRepo: Sendable {
    let db: AppDatabase

    static let columns = """
        e.r, e.account_id, e.calendar_id, e.event_id, e.instance_start, e.ical_uid, e.group_id, e.title, e.start,
        e."end", e.all_day, e.busy, e.location, e.join_url, e.web_url, e.notes, e.organizer_json, e.attendees_json,
        e.my_response, e.etag, e.status, e.updated
        """

    func upsert(_ e: EventRecord) throws {
        try db.run("""
            INSERT INTO events(r, account_id, calendar_id, event_id, instance_start, ical_uid, group_id, title, start,
              "end", all_day, busy, location, join_url, web_url, notes, organizer_json, attendees_json, my_response,
              etag, status, updated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, calendar_id, event_id) DO UPDATE SET
              instance_start = excluded.instance_start, ical_uid = excluded.ical_uid, group_id = excluded.group_id,
              title = excluded.title, start = excluded.start, "end" = excluded."end", all_day = excluded.all_day,
              busy = excluded.busy, location = excluded.location, join_url = excluded.join_url,
              web_url = excluded.web_url, notes = excluded.notes, organizer_json = excluded.organizer_json,
              attendees_json = excluded.attendees_json, my_response = excluded.my_response, etag = excluded.etag,
              status = excluded.status, updated = excluded.updated
            """, [e.r, e.accountId.uuidString, e.calendarId, e.eventId, e.instanceStart.timeIntervalSince1970,
                  e.icalUID, e.groupId, e.title, e.start.timeIntervalSince1970, e.end.timeIntervalSince1970,
                  e.allDay, e.busy, e.location, e.joinURL, e.webURL, e.notes, e.organizerJSON, e.attendeesJSON,
                  e.myResponse, e.etag, e.status, e.updated])
    }

    struct ReplaceResult: Equatable, Sendable {
        var upserted = 0
        var deleted = 0
    }

    /// The result of a complete window list for one calendar: upserts every listed event, deletes the
    /// ids in `cancelled`, and deletes every other row of that calendar that the list no longer has
    /// (vanished, or older than the window). One transaction, so readers never see half a list.
    @discardableResult
    func replaceCalendar(accountId: UUID, calendarId: String, with events: [EventRecord],
                         cancelled: Set<String> = [], extra: (() throws -> Void)? = nil) throws -> ReplaceResult {
        try db.transaction {
            var result = ReplaceResult()
            let existing = Set(try eventIds(accountId: accountId, calendarId: calendarId))
            var seen = Set<String>()
            for e in events where !cancelled.contains(e.eventId) {
                try upsert(e)
                seen.insert(e.eventId)
                result.upserted += 1
            }
            for id in existing where !seen.contains(id) {
                result.deleted += try db.run("DELETE FROM events WHERE account_id = ? AND calendar_id = ? AND event_id = ?",
                                             [accountId.uuidString, calendarId, id])
            }
            try extra?()
            return result
        }
    }

    @discardableResult
    func delete(accountId: UUID, calendarId: String, eventId: String) throws -> Bool {
        try db.run("DELETE FROM events WHERE account_id = ? AND calendar_id = ? AND event_id = ?",
                   [accountId.uuidString, calendarId, eventId]) > 0
    }

    func eventIds(accountId: UUID, calendarId: String) throws -> [String] {
        try db.query("SELECT event_id FROM events WHERE account_id = ? AND calendar_id = ?",
                     [accountId.uuidString, calendarId]) { $0.string(0) }
    }

    /// Rows of selected calendars overlapping [from, to). Zero-length events count when they start
    /// inside the range.
    func overlapping(from: Date, to: Date, accountIds: Set<UUID>? = nil) throws -> [EventRecord] {
        let rows = try db.query("""
            SELECT \(Self.columns) FROM events e
            JOIN calendars c ON c.account_id = e.account_id AND c.calendar_id = e.calendar_id
            WHERE c.selected = 1 AND e.start < ? AND max(e."end", e.start + 1) > ?
            ORDER BY e.start, e."end", e.r
            """, [to.timeIntervalSince1970, from.timeIntervalSince1970], row: Self.decode).compactMap { $0 }
        guard let accountIds else { return rows }
        return rows.filter { accountIds.contains($0.accountId) }
    }

    /// Every copy of a meeting: rows whose group id is `id`, or the row whose `r` is `id`.
    func copies(of id: String) throws -> [EventRecord] {
        try db.query("""
            SELECT \(Self.columns) FROM events e
            JOIN calendars c ON c.account_id = e.account_id AND c.calendar_id = e.calendar_id
            WHERE c.selected = 1 AND (e.group_id = ? OR e.group_id = (SELECT group_id FROM events WHERE r = ?))
            ORDER BY e.r
            """, [id, id], row: Self.decode).compactMap { $0 }
    }

    func get(r: String) throws -> EventRecord? {
        try db.query("SELECT \(Self.columns) FROM events e WHERE e.r = ?", [r], row: Self.decode).compactMap { $0 }.first
    }

    func get(accountId: UUID, calendarId: String, eventId: String) throws -> EventRecord? {
        try db.query("SELECT \(Self.columns) FROM events e WHERE e.account_id = ? AND e.calendar_id = ? AND e.event_id = ?",
                     [accountId.uuidString, calendarId, eventId], row: Self.decode).compactMap { $0 }.first
    }

    func setResponse(r: String, response: String, etag: String?) throws {
        try db.run("UPDATE events SET my_response = ?, etag = coalesce(?, etag) WHERE r = ?", [response, etag, r])
    }

    func count(accountId: UUID) throws -> Int {
        try db.query("SELECT count(*) FROM events WHERE account_id = ?", [accountId.uuidString]) { $0.int(0) }.first ?? 0
    }

    static func decode(_ row: AppDatabase.Row) -> EventRecord? {
        guard let account = UUID(uuidString: row.string(1)) else { return nil }
        return EventRecord(r: row.string(0), accountId: account, calendarId: row.string(2), eventId: row.string(3),
                           instanceStart: Date(timeIntervalSince1970: row.double(4)), icalUID: row.string(5),
                           groupId: row.string(6), title: row.string(7),
                           start: Date(timeIntervalSince1970: row.double(8)),
                           end: Date(timeIntervalSince1970: row.double(9)), allDay: row.bool(10), busy: row.bool(11),
                           location: row.optionalString(12), joinURL: row.optionalString(13),
                           webURL: row.optionalString(14), notes: row.optionalString(15),
                           organizerJSON: row.optionalString(16), attendeesJSON: row.optionalString(17),
                           myResponse: row.string(18), etag: row.optionalString(19), status: row.string(20),
                           updated: row.optionalString(21))
    }
}
