import Foundation

/// `CalendarStore` + `CalendarActions` over the local database (docs/CONTRACTS.md "App seam").
/// Reads are synchronous SQLite queries; RSVP and "Sync now" go through the engine.
final class LocalCalendarStore: CalendarStore, CalendarActions, @unchecked Sendable {
    let db: AppDatabase
    weak var engine: DataEngine?

    init(db: AppDatabase) {
        self.db = db
    }

    /// Clashes need the neighbours of the edge events, so rows are read with a margin.
    static let margin: TimeInterval = 2 * 86_400

    func events(from: Date, to: Date, accounts: Set<UUID>?) throws -> [CalendarEvent] {
        guard from < to else { return [] }
        let all = try AccountRepo(db: db).all()
        let included = Set(all.filter { $0.calendarEnabled && (accounts?.contains($0.id) ?? true) }.map(\.id))
        guard !included.isEmpty else { return [] }
        let rows = try EventRepo(db: db).overlapping(from: from.addingTimeInterval(-Self.margin),
                                                     to: to.addingTimeInterval(Self.margin), accountIds: included)
        let assembler = CalendarAssembler(accounts: all, calendars: try CalendarRepo(db: db).all())
        return assembler.events(rows: rows, included: included)
            .filter { $0.start < to && max($0.end, $0.start.addingTimeInterval(1)) > from }
    }

    /// `r` is a meeting's group id (what widgets and the Calendar section hand out) or a row id.
    func event(r: String) throws -> CalendarEvent? {
        let copies = try EventRepo(db: db).copies(of: r)
        guard let first = copies.first else { return nil }
        let start = copies.map(\.start).min() ?? first.start
        let end = copies.map(\.end).max() ?? first.end
        let all = try AccountRepo(db: db).all()
        let included = Set(all.filter(\.calendarEnabled).map(\.id))
        let rows = try EventRepo(db: db).overlapping(from: start.addingTimeInterval(-Self.margin),
                                                     to: max(end, start.addingTimeInterval(1)).addingTimeInterval(Self.margin),
                                                     accountIds: included)
        let assembler = CalendarAssembler(accounts: all, calendars: try CalendarRepo(db: db).all())
        return assembler.events(rows: rows, included: included).first { $0.r == first.groupId }
    }

    func rsvp(r: String, response: CalendarEvent.Response) async throws {
        guard let engine else { throw ServiceError(description: "Calendar sync isn\u{2019}t running yet.") }
        try await engine.rsvp(r: r, response: response)
    }

    func syncNow() async {
        await engine?.syncAll(force: true)
    }
}
