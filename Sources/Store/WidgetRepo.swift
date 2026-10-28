import Foundation

/// One row of `widget_settings` (Widget Studio), as stored. JSON columns stay strings here; the
/// publisher turns them into `WidgetSettings`.
struct WidgetSettingsRow: Equatable, Sendable {
    var kind: String
    var styleJSON: String?
    var title: String?
    var customContent: String?
    /// JSON array of account UUID strings; nil = every account marked "Include in All".
    var accountIdsJSON: String?
    var rangeDays: Int = 7
}

/// One row of `widget_state`. Per-family rows carry the page; the kind-level row (family `*`) carries
/// the picked day, month shown and range set from the widget.
struct WidgetStateRow: Equatable, Sendable {
    static let kindLevel = "*"

    var kind: String
    var family: String
    var page: Int = 1
    var pageSetAt: Date?
    var selectedDay: String?
    var monthShown: String?
    var rangeDays: Int?
    var stateSetAt: Date?
}

struct WidgetRepo: Sendable {
    let db: AppDatabase

    func settings(kind: String) throws -> WidgetSettingsRow? {
        try db.query("""
            SELECT kind, style_json, title, custom_content, account_ids_json, range_days FROM widget_settings WHERE kind = ?
            """, [kind]) {
            WidgetSettingsRow(kind: $0.string(0), styleJSON: $0.optionalString(1), title: $0.optionalString(2),
                              customContent: $0.optionalString(3), accountIdsJSON: $0.optionalString(4),
                              rangeDays: $0.int(5))
        }.first
    }

    func saveSettings(_ s: WidgetSettingsRow) throws {
        try db.run("""
            INSERT INTO widget_settings(kind, style_json, title, custom_content, account_ids_json, range_days)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(kind) DO UPDATE SET style_json = excluded.style_json, title = excluded.title,
              custom_content = excluded.custom_content, account_ids_json = excluded.account_ids_json,
              range_days = excluded.range_days
            """, [s.kind, s.styleJSON, s.title, s.customContent, s.accountIdsJSON, s.rangeDays])
    }

    func states(kind: String) throws -> [WidgetStateRow] {
        try db.query("""
            SELECT kind, family, page, page_set_at, selected_day, month_shown, range_days, state_set_at
            FROM widget_state WHERE kind = ? ORDER BY family
            """, [kind]) {
            WidgetStateRow(kind: $0.string(0), family: $0.string(1), page: $0.int(2),
                           pageSetAt: $0.isNull(3) ? nil : Date(timeIntervalSince1970: $0.double(3)),
                           selectedDay: $0.optionalString(4), monthShown: $0.optionalString(5),
                           rangeDays: $0.isNull(6) ? nil : $0.int(6),
                           stateSetAt: $0.isNull(7) ? nil : Date(timeIntervalSince1970: $0.double(7)))
        }
    }

    func setPage(kind: String, family: String, page: Int, at date: Date) throws {
        try db.run("""
            INSERT INTO widget_state(kind, family, page, page_set_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(kind, family) DO UPDATE SET page = excluded.page, page_set_at = excluded.page_set_at
            """, [kind, family, page, date.timeIntervalSince1970])
    }

    /// Writes the kind-level row. Fields left nil keep their stored value.
    func setKindState(kind: String, selectedDay: String? = nil, monthShown: String? = nil, rangeDays: Int? = nil,
                      at date: Date) throws {
        try db.transaction {
            var row = try states(kind: kind).first { $0.family == WidgetStateRow.kindLevel }
                ?? WidgetStateRow(kind: kind, family: WidgetStateRow.kindLevel)
            if let selectedDay { row.selectedDay = selectedDay }
            if let monthShown { row.monthShown = monthShown }
            if let rangeDays { row.rangeDays = rangeDays }
            row.stateSetAt = date
            try db.run("""
                INSERT INTO widget_state(kind, family, page, selected_day, month_shown, range_days, state_set_at)
                VALUES (?, ?, 1, ?, ?, ?, ?)
                ON CONFLICT(kind, family) DO UPDATE SET selected_day = excluded.selected_day,
                  month_shown = excluded.month_shown, range_days = excluded.range_days,
                  state_set_at = excluded.state_set_at
                """, [kind, WidgetStateRow.kindLevel, row.selectedDay, row.monthShown, row.rangeDays,
                      date.timeIntervalSince1970])
        }
    }

    /// Midnight: forget picked days, months and ranges set before `cutoff`.
    @discardableResult
    func clearKindState(setBefore cutoff: Date) throws -> Int {
        try db.run("""
            UPDATE widget_state SET selected_day = NULL, month_shown = NULL, range_days = NULL, state_set_at = NULL
            WHERE family = ? AND state_set_at IS NOT NULL AND state_set_at < ?
            """, [WidgetStateRow.kindLevel, cutoff.timeIntervalSince1970])
    }
}
