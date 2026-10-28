import Foundation

/// Rows → `CalendarEvent`s across accounts.
///
/// - **Merged invites:** copies with the same group id (iCalUID + instance start) become one event
///   whose `r` is the group id. `accountIds` lists every included account that has it, the primary
///   first: the organizer's account when it is one of them, else the first in the user's order.
///   Title, times, place, links and the user's response come from the primary copy.
/// - **Clashes:** two timed, busy (opaque), non-declined events overlapping by at least one minute.
///   Copies of one merged meeting are one event, so they never clash with each other.
struct CalendarAssembler {
    static let clashMinimum: TimeInterval = 60
    static let untitled = "(No title)"

    let order: [UUID: Int]
    let emails: [UUID: String]
    let calendarNames: [String: String]

    init(accounts: [AccountRecord], calendars: [CalendarRecord]) {
        var order: [UUID: Int] = [:]
        var emails: [UUID: String] = [:]
        for (index, account) in accounts.enumerated() {
            order[account.id] = index
            emails[account.id] = account.email.lowercased()
        }
        self.order = order
        self.emails = emails
        var names: [String: String] = [:]
        for c in calendars { names[Self.key(c.accountId, c.calendarId)] = c.summary }
        calendarNames = names
    }

    static func key(_ account: UUID, _ calendar: String) -> String { "\(account.uuidString)|\(calendar)" }

    /// Events from `rows` limited to `included` accounts, merged, clash-marked and sorted. `people`:
    /// decode organizer and attendees (Peeks, the Calendar section); the widget snapshots never show
    /// them, so the publisher skips the per-event JSON decoding.
    func events(rows: [EventRecord], included: Set<UUID>, people: Bool = true) -> [CalendarEvent] {
        var groups: [String: [EventRecord]] = [:]
        var keys: [String] = []
        for row in rows where included.contains(row.accountId) && row.status != "cancelled" {
            if groups[row.groupId] == nil { keys.append(row.groupId) }
            groups[row.groupId, default: []].append(row)
        }
        var built = keys.compactMap { key in groups[key].map { build($0, people: people) } }
        markClashes(&built)
        built.sort { a, b in
            if a.event.start != b.event.start { return a.event.start < b.event.start }
            if a.event.allDay != b.event.allDay { return a.event.allDay }
            if a.event.end != b.event.end { return a.event.end < b.event.end }
            if a.event.title != b.event.title { return a.event.title < b.event.title }
            return a.event.r < b.event.r
        }
        return built.map(\.event)
    }

    /// The copy that speaks for a merged meeting.
    func primary(of copies: [EventRecord]) -> EventRecord {
        // One copy speaks for itself (no organizer JSON to decode).
        if copies.count == 1 { return copies[0] }
        let ranked = copies.sorted(by: rank)
        let organizerCopy = ranked.first { copy in
            guard let organizer = StoredPerson.decodeOne(copy.organizerJSON) else { return false }
            return organizer.isSelf || organizer.email.lowercased() == emails[copy.accountId]
        }
        return organizerCopy ?? ranked[0]
    }

    private func rank(_ a: EventRecord, _ b: EventRecord) -> Bool {
        let oa = order[a.accountId] ?? Int.max, ob = order[b.accountId] ?? Int.max
        if oa != ob { return oa < ob }
        // Within one account, the account's own (primary) calendar first.
        let pa = a.calendarId.lowercased() == emails[a.accountId], pb = b.calendarId.lowercased() == emails[b.accountId]
        if pa != pb { return pa }
        if a.calendarId != b.calendarId { return a.calendarId < b.calendarId }
        return a.r < b.r
    }

    struct Built {
        var event: CalendarEvent
        var busy: Bool
    }

    private func build(_ copies: [EventRecord], people: Bool) -> Built {
        let p = primary(of: copies)
        let ranked = copies.count == 1 ? copies : copies.sorted(by: rank)
        var ids = [p.accountId]
        for copy in ranked where !ids.contains(copy.accountId) { ids.append(copy.accountId) }
        let join = p.joinURL.flatMap(URL.init(string:))
            ?? ranked.lazy.compactMap { $0.joinURL.flatMap(URL.init(string:)) }.first
        let event = CalendarEvent(
            r: p.groupId, accountIds: ids,
            calendarName: calendarNames[Self.key(p.accountId, p.calendarId)] ?? "",
            title: p.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.untitled : p.title,
            start: p.start, end: p.end, allDay: p.allDay, location: p.location,
            joinURL: join, webURL: p.webURL.flatMap(URL.init(string:)), notes: p.notes,
            organizer: people ? StoredPerson.decodeOne(p.organizerJSON).map(Self.attendee) : nil,
            attendees: people ? StoredPerson.decodeList(p.attendeesJSON).map(Self.attendee) : [],
            myResponse: CalendarEvent.Response(rawValue: p.myResponse) ?? .needsAction,
            clashes: false)
        return Built(event: event, busy: p.busy)
    }

    static func attendee(_ person: StoredPerson) -> CalendarEvent.Attendee {
        CalendarEvent.Attendee(name: person.name, email: person.email,
                               response: person.response.flatMap(CalendarEvent.Response.init(rawValue:)) ?? .needsAction,
                               isSelf: person.isSelf, isOrganizer: person.isOrganizer)
    }

    private func markClashes(_ built: inout [Built]) {
        let candidates = built.indices.filter {
            !built[$0].event.allDay && built[$0].busy && built[$0].event.myResponse != .declined
                && built[$0].event.end.timeIntervalSince(built[$0].event.start) >= Self.clashMinimum
        }.sorted { built[$0].event.start < built[$1].event.start }
        for (n, i) in candidates.enumerated() {
            let a = built[i].event
            for j in candidates[(n + 1)...] {
                let b = built[j].event
                if b.start >= a.end { break }
                let overlap = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
                if overlap >= Self.clashMinimum {
                    built[i].event.clashes = true
                    built[j].event.clashes = true
                }
            }
        }
    }
}
