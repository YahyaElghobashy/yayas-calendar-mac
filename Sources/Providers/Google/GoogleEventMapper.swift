import Foundation

/// A person as stored in `events.organizer_json` / `attendees_json`.
struct StoredPerson: Codable, Equatable, Sendable {
    var email: String
    var name: String?
    /// accepted | tentative | declined | needsAction
    var response: String?
    var isSelf: Bool
    var isOrganizer: Bool

    static func encode(_ value: some Encodable) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeOne(_ json: String?) -> StoredPerson? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? decoder.decode(StoredPerson.self, from: data)
    }

    static func decodeList(_ json: String?) -> [StoredPerson] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? decoder.decode([StoredPerson].self, from: data)) ?? []
    }

    /// One decoder for every row (assembly decoded thousands per publish, each with a new decoder).
    private static let decoder = JSONDecoder()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

/// Google event → `EventRecord`. Timed events keep their absolute instant (stored as UTC epoch);
/// all-day events become local midnight of their dates in the Mac's calendar (end exclusive), so a
/// 25-hour day at the end of DST (London, 25 Oct 2026) stays one day.
enum GoogleEventMapper {
    enum Outcome: Equatable {
        case event(EventRecord)
        /// Deleted or cancelled occurrence: drop the row.
        case cancelled(String)
        /// Not shown in the app (working-location markers, unreadable times).
        case skipped
    }

    static let ignoredTypes: Set<String> = ["workingLocation"]

    static func map(_ e: GEvent, accountId: UUID, calendarId: String, calendar cal: Calendar) -> Outcome {
        if e.status == "cancelled" { return .cancelled(e.id) }
        if let type = e.eventType, ignoredTypes.contains(type) { return .skipped }
        guard let startTime = e.start, let first = instant(startTime, cal) else { return .skipped }
        let start = first.date, allDay = first.allDay
        var end = e.end.flatMap { instant($0, cal)?.date } ?? start
        if allDay, end <= start { end = cal.date(byAdding: .day, value: 1, to: start) ?? start }
        if end < start { end = start }
        let instanceStart = e.originalStartTime.flatMap { instant($0, cal)?.date } ?? start
        let uid = (e.iCalUID?.isEmpty == false ? e.iCalUID : nil) ?? e.id

        let attendees = (e.attendees ?? []).filter { !($0.resource ?? false) }.compactMap { a -> StoredPerson? in
            guard let email = a.email, !email.isEmpty else { return nil }
            return StoredPerson(email: email, name: a.displayName, response: a.responseStatus,
                                isSelf: a.isSelf ?? false, isOrganizer: a.organizer ?? false)
        }
        let organizer = e.organizer.flatMap { o -> StoredPerson? in
            guard let email = o.email, !email.isEmpty else { return nil }
            return StoredPerson(email: email, name: o.displayName, response: nil, isSelf: o.isSelf ?? false,
                                isOrganizer: true)
        }
        let selfResponse = (e.attendees ?? []).first { $0.isSelf ?? false }?.responseStatus
        let video = (e.conferenceData?.entryPoints ?? []).filter { $0.entryPointType == "video" }.compactMap(\.uri)
        let join = JoinLinks.extract(videoEntryPoints: video, hangoutLink: e.hangoutLink, location: e.location,
                                     description: e.description)
        let web = e.htmlLink.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }

        let record = EventRecord(
            r: EventIds.rowId(accountId: accountId, calendarId: calendarId, eventId: e.id),
            accountId: accountId, calendarId: calendarId, eventId: e.id,
            instanceStart: instanceStart, icalUID: uid,
            groupId: EventIds.groupId(icalUID: uid, instanceStart: instanceStart),
            title: e.summary ?? "", start: start, end: end, allDay: allDay,
            busy: e.transparency != "transparent",
            location: e.location.flatMap { $0.isEmpty ? nil : $0 },
            joinURL: join?.absoluteString, webURL: web?.absoluteString,
            notes: PlainText.fromHTML(e.description),
            organizerJSON: organizer.flatMap { StoredPerson.encode($0) },
            attendeesJSON: attendees.isEmpty ? nil : StoredPerson.encode(attendees),
            myResponse: normalizedResponse(selfResponse),
            etag: e.etag, status: e.status ?? "confirmed", updated: e.updated)
        return .event(record)
    }

    static func normalizedResponse(_ value: String?) -> String {
        switch value {
        case "accepted", "tentative", "declined", "needsAction": return value!
        case nil: return "accepted"
        default: return "needsAction"
        }
    }

    /// (instant, isAllDay). Date-only values are local midnight in `cal`.
    static func instant(_ t: GEventTime, _ cal: Calendar) -> (date: Date, allDay: Bool)? {
        if let day = t.date { return DayKey.date(day, cal).map { ($0, true) } }
        if let text = t.dateTime { return parseDateTime(text).map { ($0, false) } }
        return nil
    }

    static func parseDateTime(_ text: String) -> Date? {
        plain.date(from: text) ?? fractional.date(from: text)
    }

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
