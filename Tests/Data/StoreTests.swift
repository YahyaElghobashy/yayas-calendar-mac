import Foundation
import SQLite3

enum StoreTests {
    static func run() {
        migratesFromV1()
        freshSchema()
        upsertKeepsR()
        vanishedRowsDeleted()
        calendarReplaceCascades()
        accountRemovalCascades()
        widgetRepo()
        syncStatus()
    }

    /// A store written by the first build (v1: accounts + settings) opens as v5 with its rows intact.
    static func migratesFromV1() {
        let dir = DataTests.folder("store-v1")
        let url = dir.appendingPathComponent("store.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { expect(false, "v1 file opens"); return }
        for sql in AppDatabase.migrations[0] { sqlite3_exec(handle, sql, nil, nil, nil) }
        sqlite3_exec(handle, "PRAGMA user_version = 1", nil, nil, nil)
        sqlite3_exec(handle, """
            INSERT INTO accounts(id, provider, email, display_name, tag, color, created_at)
            VALUES ('6F9619FF-8B86-D011-B42D-00C04FC964FF', 'google', 'a@orb.example', 'ORB', 'ORB', 1, 1000)
            """, nil, nil, nil)
        sqlite3_exec(handle, "INSERT INTO settings(key, value) VALUES ('k', 'v')", nil, nil, nil)
        sqlite3_close(handle)

        guard let db = try? AppDatabase(url: url) else { expect(false, "v1 store migrates"); return }
        expect(db.schemaVersion == 6, "v1 → v6")
        expect(AppDatabase.migrations.count == 6, "migrations v2…v6 appended (v4 mail, v5 action queue, v6 rich mail)")
        expect((try? AccountRepo(db: db).count()) == 1, "v1 account kept")
        expect((try? db.setting("k")) == "v", "v1 setting kept")
        let tables = Set((try? db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.string(0) }) ?? [])
        expect(tables.isSuperset(of: ["accounts", "settings", "calendars", "events", "sync_state", "widget_settings",
                                      "widget_state", "mail_threads", "mail_state", "mail_prefs", "image_allow",
                                      "body_cache", "actions"]), "v2…v5 tables exist")
        // Reopen: no migration runs twice.
        expect((try? AppDatabase(url: url))?.schemaVersion == 6, "reopen stays v6")
    }

    static func freshSchema() {
        let (db, _) = Seed.database("store-fresh")
        func columns(_ table: String) -> [String] { (try? db.query("PRAGMA table_info(\(table))") { $0.string(1) }) ?? [] }
        expect(columns("calendars") == ["account_id", "calendar_id", "summary", "selected", "color", "access_role"],
               "calendars columns")
        expect(columns("events") == ["r", "account_id", "calendar_id", "event_id", "instance_start", "ical_uid", "group_id",
                                     "title", "start", "end", "all_day", "busy", "location", "join_url", "web_url", "notes",
                                     "organizer_json", "attendees_json", "my_response", "etag", "status", "updated"],
               "events columns")
        expect(columns("sync_state") == ["account_id", "calendar_id", "sync_token", "last_list_at"], "sync_state columns")
        expect(columns("widget_settings") == ["kind", "style_json", "title", "custom_content", "account_ids_json", "range_days"],
               "widget_settings columns")
        expect(columns("widget_state") == ["kind", "family", "page", "page_set_at", "selected_day", "month_shown",
                                           "range_days", "state_set_at"], "widget_state columns")
        let unique = (try? db.query("PRAGMA index_list(events)") { ($0.string(1), $0.int(2)) }) ?? []
        expect(unique.contains { $0.1 == 1 }, "events has a UNIQUE index (account, calendar, event id)")
    }

    static func upsertKeepsR() {
        let (db, _) = Seed.database("store-upsert")
        let a = Seed.account(db, email: "a@orb.example", tag: "ORB", sort: 0)
        Seed.calendar(db, a.id, "primary")
        let repo = EventRepo(db: db)
        var row = Seed.row(a.id, id: "ev1", title: "Standup", start: TestCal.local(2026, 10, 20, 9), end: TestCal.local(2026, 10, 20, 9, 30))
        try? repo.upsert(row)
        let r = row.r
        expect(r == EventIds.rowId(accountId: a.id, calendarId: "primary", eventId: "ev1"), "r is the deterministic row id")
        expect(r.count == 23 && Route.isSafeValue(r), "r is short and link-safe")
        row.title = "Standup (moved)"
        row.r = "should-not-replace"
        try? repo.upsert(row)
        let rows = (try? repo.overlapping(from: TestCal.local(2026, 10, 1), to: TestCal.local(2026, 11, 1))) ?? []
        expect(rows.count == 1, "upsert on (account, calendar, event) makes no second row")
        expect(rows.first?.r == r, "upsert keeps r")
        expect(rows.first?.title == "Standup (moved)", "upsert updates fields")
        let g1 = EventIds.groupId(icalUID: "x@google.example", instanceStart: TestCal.local(2026, 10, 20, 9))
        let g2 = EventIds.groupId(icalUID: "x@google.example", instanceStart: TestCal.local(2026, 10, 20, 9))
        let g3 = EventIds.groupId(icalUID: "x@google.example", instanceStart: TestCal.local(2026, 10, 27, 9))
        expect(g1 == g2 && g1 != g3 && g1.hasPrefix("g") && Route.isSafeValue(g1), "group id = hash(iCalUID + instance start)")
    }

    static func vanishedRowsDeleted() {
        let (db, _) = Seed.database("store-vanish")
        let a = Seed.account(db, email: "a@orb.example", tag: "ORB", sort: 0)
        Seed.calendar(db, a.id, "primary")
        Seed.calendar(db, a.id, "team")
        let repo = EventRepo(db: db)
        let day = TestCal.local(2026, 10, 21, 10)
        let rows = ["A", "B", "C"].map { Seed.row(a.id, id: $0, title: $0, start: day, end: day.addingTimeInterval(1800)) }
        let other = Seed.row(a.id, calendar: "team", id: "T", title: "T", start: day, end: day.addingTimeInterval(1800))
        try? repo.upsert(other)
        _ = try? repo.replaceCalendar(accountId: a.id, calendarId: "primary", with: rows)
        var changed = rows[2]
        changed.title = "C2"
        let result = try? repo.replaceCalendar(accountId: a.id, calendarId: "primary", with: [rows[0], changed, rows[1]],
                                               cancelled: ["B"])
        let ids = Set((try? repo.eventIds(accountId: a.id, calendarId: "primary")) ?? [])
        expect(ids == ["A", "C"], "cancelled id deleted, others kept")
        expect(result?.deleted == 1 && result?.upserted == 2, "replace reports 2 upserts, 1 delete")
        _ = try? repo.replaceCalendar(accountId: a.id, calendarId: "primary", with: [rows[0]])
        expect(Set((try? repo.eventIds(accountId: a.id, calendarId: "primary")) ?? []) == ["A"], "rows missing from a full list vanish")
        expect((try? repo.eventIds(accountId: a.id, calendarId: "team")) == ["T"], "other calendars untouched")
    }

    static func calendarReplaceCascades() {
        let (db, _) = Seed.database("store-calendars")
        let a = Seed.account(db, email: "a@orb.example", tag: "ORB", sort: 0)
        let cals = CalendarRepo(db: db)
        let list = ["primary", "team", "gone"].map {
            CalendarRecord(accountId: a.id, calendarId: $0, summary: $0, selected: true, color: 0x112233, accessRole: "owner")
        }
        _ = try? cals.replace(accountId: a.id, with: list)
        let day = TestCal.local(2026, 10, 21, 10)
        for c in ["primary", "team", "gone"] {
            try? EventRepo(db: db).upsert(Seed.row(a.id, calendar: c, id: "e-\(c)", title: c, start: day, end: day.addingTimeInterval(600)))
            try? SyncStateRepo(db: db).setToken("s1", accountId: a.id, calendarId: c)
        }
        var next = Array(list.prefix(2))
        next[1].selected = false
        let dropped = (try? cals.replace(accountId: a.id, with: next)) ?? []
        expect(Set(dropped) == ["gone", "team"], "removed and deselected calendars reported")
        expect((try? cals.all(accountId: a.id).map(\.calendarId)) == ["primary", "team"], "calendar left the list → row gone")
        expect((try? EventRepo(db: db).count(accountId: a.id)) == 1, "events of gone + deselected calendars removed")
        expect((try? SyncStateRepo(db: db).tokenCount(accountId: a.id)) == 1, "their sync state removed too")
        expect((try? cals.get(accountId: a.id, calendarId: "primary"))?.color == 0x112233, "colour stored")
    }

    static func accountRemovalCascades() {
        let (db, _) = Seed.database("store-account-cascade")
        let a = Seed.account(db, email: "a@orb.example", tag: "ORB", sort: 0)
        let b = Seed.account(db, email: "b@cmt.example", tag: "CMT", sort: 1)
        for acct in [a, b] {
            Seed.calendar(db, acct.id, "primary")
            try? EventRepo(db: db).upsert(Seed.row(acct.id, id: "x", title: "x", start: TestCal.labNow, end: TestCal.labNow))
            try? SyncStateRepo(db: db).setToken("s", accountId: acct.id, calendarId: "primary")
        }
        _ = try? AccountRepo(db: db).delete(a.id)
        expect((try? EventRepo(db: db).count(accountId: a.id)) == 0, "removed account's events cascade away")
        expect((try? CalendarRepo(db: db).all(accountId: a.id).count) == 0, "…and its calendars")
        expect((try? SyncStateRepo(db: db).tokenCount(accountId: a.id)) == 0, "…and its sync state")
        expect((try? EventRepo(db: db).count(accountId: b.id)) == 1, "other account untouched")
    }

    static func widgetRepo() {
        let (db, _) = Seed.database("store-widgets")
        let repo = WidgetRepo(db: db)
        let t = TestCal.labNow
        try? repo.setPage(kind: "agenda.all", family: "L", page: 3, at: t)
        try? repo.setKindState(kind: "month", selectedDay: "2026-10-22", at: t)
        try? repo.setKindState(kind: "month", monthShown: "2026-11", at: t.addingTimeInterval(5))
        let month = (try? repo.states(kind: "month"))?.first
        expect(month?.selectedDay == "2026-10-22" && month?.monthShown == "2026-11", "kind state merges fields")
        expect((try? repo.states(kind: "agenda.all"))?.first?.page == 3, "page stored per family")
        let cleared = (try? repo.clearKindState(setBefore: t.addingTimeInterval(60))) ?? 0
        expect(cleared == 1 && (try? repo.states(kind: "month"))?.first?.selectedDay == nil, "midnight clears kind state")
        try? repo.saveSettings(WidgetSettingsRow(kind: "custom.a", styleJSON: nil, title: "Work", customContent: "month",
                                                 accountIdsJSON: "[]", rangeDays: 2))
        expect((try? repo.settings(kind: "custom.a"))?.title == "Work", "settings stored")
    }

    static func syncStatus() {
        let (db, _) = Seed.database("store-status")
        let a = Seed.account(db, email: "a@orb.example", tag: "ORB", sort: 0)
        let status = SyncStatusRepo(db: db)
        status.recordError(a.id, code: "offline")
        expect(status.lastError(a.id) == "offline", "error recorded")
        status.recordSuccess(a.id, at: TestCal.labNow)
        expect(status.lastSuccess(a.id) == TestCal.labNow && status.lastError(a.id) == nil, "success clears the error")
        let ghost = UUID()
        status.recordSuccess(ghost, at: TestCal.labNow)
        status.prune(keeping: [a.id])
        expect(status.lastSuccess(ghost) == nil && status.lastSuccess(a.id) != nil, "prune drops removed accounts' keys")
    }
}

enum TimeTests {
    static func run() {
        let cal = TestCal.lab
        // Monday 19 Oct 2026: October starts on a Thursday → the Monday-first grid starts Mon 28 Sep.
        let w = SyncWindow.current(now: TestCal.labNow, calendar: cal)
        expect(DayKey.string(w.start, cal) == "2026-09-28", "window starts at the grid's first Monday")
        expect(w.start == TestCal.iso("2026-09-27T23:00:00Z"), "window start is London midnight (BST, +1)")
        expect(w.end == TestCal.iso("2027-01-01T00:00:00Z"), "window ends after 31 December (today + 60 = 18 Dec), GMT +0")
        expect(w.dayKeys(cal).first == "2026-09-28" && w.dayKeys(cal).last == "2026-12-31", "window day keys")

        // Every first weekday a region can set (1 = Sunday … 7 = Saturday). 1 October 2026 is a Thursday, so the
        // October grid starts on the last such weekday on or before it; a month that starts on that weekday has no lead.
        let weekStarts: [(firstWeekday: Int, name: String, october: String, noLead: (month: Int, start: String))] = [
            (1, "Sunday", "2026-09-27", (2, "2026-02-01")),
            (2, "Monday", "2026-09-28", (6, "2026-06-01")),
            (3, "Tuesday", "2026-09-29", (9, "2026-09-01")),
            (4, "Wednesday", "2026-09-30", (4, "2026-04-01")),
            (5, "Thursday", "2026-10-01", (1, "2026-01-01")),
            (6, "Friday", "2026-09-25", (5, "2026-05-01")),
            (7, "Saturday", "2026-09-26", (8, "2026-08-01")),
        ]
        for week in weekStarts {
            var c = cal
            c.firstWeekday = week.firstWeekday
            expect(DayKey.string(SyncWindow.current(now: TestCal.labNow, calendar: c).start, c) == week.october,
                   "\(week.name)-first grid starts \(week.october)")
            let lead = SyncWindow.current(now: TestCal.local(2026, week.noLead.month, 10, 12), calendar: c)
            expect(DayKey.string(lead.start, c) == week.noLead.start, "\(week.noLead.start) is a \(week.name): no lead")
        }
        // Year end: 1 Dec + 60 = 30 Jan → end of January.
        let dec = SyncWindow.current(now: TestCal.local(2026, 12, 1, 8), calendar: cal)
        expect(DayKey.string(dec.end, cal) == "2027-02-01", "window crosses the year")

        // London's summer time ends Sun 25 Oct 2026 at 02:00 BST → 01:00 GMT: the 25th is 25 hours long.
        let d25 = DayKey.date("2026-10-25", cal)!
        let d26 = DayKey.date("2026-10-26", cal)!
        expect(d25 == TestCal.iso("2026-10-24T23:00:00Z"), "25 Oct starts at 23:00Z the day before (+1)")
        expect(d26 == TestCal.iso("2026-10-26T00:00:00Z"), "26 Oct starts at 00:00Z (+0)")
        expect(d26.timeIntervalSince(d25) == 25 * 3600, "25 Oct has 25 hours")
        expect(DayKey.string(TestCal.iso("2026-10-25T01:30:00Z"), cal) == "2026-10-25", "the repeated hour is still the 25th")
        expect(DayKey.string(TestCal.iso("2026-10-26T00:00:00Z"), cal) == "2026-10-26", "00:00Z is the 26th")
        expect(DayKey.date("2026-02-30", cal) == nil && DayKey.date("2026-1-01", cal) == nil && DayKey.date("x", cal) == nil,
               "invalid day keys rejected")
        expect(DayKey.monthStart("2026-11", cal) == DayKey.date("2026-11-01", cal), "month key → first day")
        expect(DayKey.month(TestCal.labNow, cal) == "2026-10", "month key")
    }
}
