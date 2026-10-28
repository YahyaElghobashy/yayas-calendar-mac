import Foundation

// Google Calendar API v3 wire types: only the fields the app asks for (`fields=`) and reads.
// https://developers.google.com/workspace/calendar/api/v3/reference

struct GCalendarList: Decodable {
    var items: [GCalendarListEntry]?
    var nextPageToken: String?
}

struct GCalendarListEntry: Decodable, Equatable {
    var id: String
    var summary: String?
    var summaryOverride: String?
    /// Shown in Google's own UI. Omitted when false.
    var selected: Bool?
    var hidden: Bool?
    var deleted: Bool?
    var primary: Bool?
    var accessRole: String?
    var backgroundColor: String?

    /// The app's default: what the user sees in Google Calendar (holidays, birthdays and other
    /// subscriptions only when ticked there), never hidden or deleted calendars, and never calendars we
    /// may only see free/busy blocks of.
    var includedByDefault: Bool {
        (selected ?? false) && !(hidden ?? false) && !(deleted ?? false) && accessRole != "freeBusyReader"
    }

    var displayName: String { summaryOverride ?? summary ?? id }

    /// "#9fe1e7" → 0x9FE1E7.
    var color: UInt32? {
        guard let hex = backgroundColor, hex.hasPrefix("#"), hex.count == 7 else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }
}

struct GEventList: Decodable {
    var items: [GEvent]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

/// The change feed only asks for ids.
struct GEventIdList: Decodable {
    struct Item: Decodable { var id: String? }
    var items: [Item]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

struct GEventTime: Decodable, Equatable {
    /// All-day: "2026-10-29".
    var date: String?
    /// Timed: RFC 3339 with offset.
    var dateTime: String?
    var timeZone: String?
}

struct GPerson: Decodable, Equatable {
    var email: String?
    var displayName: String?
    var isSelf: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName
        case isSelf = "self"
    }
}

struct GAttendee: Decodable, Equatable {
    var email: String?
    var displayName: String?
    var responseStatus: String?
    var isSelf: Bool?
    var organizer: Bool?
    var resource: Bool?
    var optional: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer, resource, optional
        case isSelf = "self"
    }
}

struct GEntryPoint: Decodable, Equatable {
    var entryPointType: String?
    var uri: String?
}

struct GConferenceData: Decodable, Equatable {
    var entryPoints: [GEntryPoint]?
}

struct GEvent: Decodable, Equatable {
    var id: String
    var status: String?
    var summary: String?
    var description: String?
    var location: String?
    var htmlLink: String?
    var hangoutLink: String?
    var iCalUID: String?
    var recurringEventId: String?
    var originalStartTime: GEventTime?
    var start: GEventTime?
    var end: GEventTime?
    var transparency: String?
    var etag: String?
    var updated: String?
    var eventType: String?
    var attendees: [GAttendee]?
    var organizer: GPerson?
    var conferenceData: GConferenceData?
}

/// `{"error":{"code":403,"message":"…","errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}`
struct GErrorEnvelope: Decodable {
    struct Body: Decodable {
        struct Item: Decodable { var reason: String?; var domain: String? }
        /// `google.rpc.ErrorInfo` entries: a turned-off API says `SERVICE_DISABLED` here.
        struct Detail: Decodable { var reason: String? }
        var code: Int?
        var status: String?
        var errors: [Item]?
        var details: [Detail]?
    }
    var error: Body?

    var reasons: [String] { (error?.errors?.compactMap(\.reason) ?? []) + (error?.details?.compactMap(\.reason) ?? []) }
}
