import Foundation

/// Why a Google Calendar call failed, in terms the sync engine acts on. Descriptions carry no tokens,
/// ids, titles or addresses.
enum GoogleAPIError: Error, Equatable, CustomStringConvertible {
    /// 410: the sync token expired; reset it and re-list.
    case gone
    /// 412: the etag sent with If-Match is stale.
    case preconditionFailed
    case notFound
    /// 429, or 403 with a rate/quota reason: back off.
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, retryAfter: TimeInterval?)
    case forbidden(reason: String)
    case unauthorized
    case badRequest(reason: String)
    case offline
    case transport(String)
    case undecodable
    case tooManyPages
    case http(status: Int)

    init(response: HTTPResponse, now: Date = Date()) {
        let reasons = (try? JSONDecoder().decode(GErrorEnvelope.self, from: response.body))?.reasons ?? []
        let retry = response.retryAfter(now: now)
        switch response.status {
        case 410: self = .gone
        case 412: self = .preconditionFailed
        case 404: self = .notFound
        case 401: self = .unauthorized
        case 429: self = .rateLimited(retryAfter: retry)
        case 403:
            if reasons.contains(where: Self.rateReasons.contains) {
                self = .rateLimited(retryAfter: retry)
            } else if let off = reasons.first(where: Self.serviceDisabledReasons.contains) {
                self = .forbidden(reason: off)
            } else {
                self = .forbidden(reason: Self.safe(reasons.first ?? "forbidden"))
            }
        case 400: self = .badRequest(reason: Self.safe(reasons.first ?? "badRequest"))
        case 500...599: self = .server(status: response.status, retryAfter: retry)
        default: self = .http(status: response.status)
        }
    }

    static let rateReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded",
                                           "dailyLimitExceeded"]
    /// The API is turned off in the user's Google Cloud project (D-038): the account card says which one
    /// to turn on, instead of a calendar silently skipped.
    static let serviceDisabledReasons: Set<String> = ["accessNotConfigured", "SERVICE_DISABLED"]

    var isServiceDisabled: Bool {
        if case .forbidden(let reason) = self { return Self.serviceDisabledReasons.contains(reason) }
        return false
    }

    private static func safe(_ reason: String) -> String {
        String(reason.prefix(40).filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    /// Short code for logs and diagnostics.
    var code: String {
        switch self {
        case .gone: return "gone"
        case .preconditionFailed: return "precondition_failed"
        case .notFound: return "not_found"
        case .rateLimited: return "rate_limited"
        case .server(let status, _): return "server_\(status)"
        case .forbidden(let reason): return "forbidden_\(reason)"
        case .unauthorized: return "unauthorized"
        case .badRequest(let reason): return "bad_request_\(reason)"
        case .offline: return "offline"
        case .transport(let what): return "transport_\(what)"
        case .undecodable: return "undecodable"
        case .tooManyPages: return "too_many_pages"
        case .http(let status): return "http_\(status)"
        }
    }

    var description: String { code }
}

/// One change-feed read: the ids that changed since the token (empty on the first read) and the
/// token to use next time.
struct ChangeFeed: Equatable {
    var changedIds: [String]
    var nextSyncToken: String
    /// No token was given: this read only fetched one, so the caller must re-list.
    var initial: Bool
}

/// Google Calendar API v3 over `HTTPTransport`, authenticated per account.
///
/// Sync design (D-015): Google rejects `syncToken` together with `timeMin`/`timeMax`, so the window
/// (`singleEvents=true&orderBy=startTime`) is re-listed in full, and a separate unbounded `syncToken`
/// feed asking only for ids says when to do it.
struct GoogleCalendarClient: Sendable {
    static let base = "https://www.googleapis.com/calendar/v3"
    /// RSVP replies: "all" lets Google send the reply to the organizer (including organizers outside
    /// Google, who need the iMIP reply). Verify live with a [YC-TEST] invite.
    static let rsvpSendUpdates = "all"
    static let maxAttendees = 60

    static let eventFields = "nextPageToken,items(id,status,summary,description,location,htmlLink,hangoutLink,"
        + "iCalUID,recurringEventId,originalStartTime,start,end,transparency,etag,updated,eventType,"
        + "attendees(email,displayName,responseStatus,self,organizer,resource,optional),"
        + "organizer(email,displayName,self),conferenceData(entryPoints(entryPointType,uri)))"

    let transport: HTTPTransport
    let tokens: AccessTokenSource
    var pageSize = 250
    var feedPageSize = 2500
    var maxPages = 400

    // MARK: - Calls

    func calendarList() async throws -> [GCalendarListEntry] {
        var out: [GCalendarListEntry] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var query = [("maxResults", "250"),
                         ("fields", "nextPageToken,items(id,summary,summaryOverride,selected,hidden,deleted,primary,accessRole,backgroundColor)")]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page: GCalendarList = try await getJSON(url("/users/me/calendarList", query))
            out += page.items ?? []
            pageToken = page.nextPageToken
            pages += 1
            if pages >= maxPages { throw GoogleAPIError.tooManyPages }
        } while pageToken != nil
        return out
    }

    /// Every occurrence overlapping [timeMin, timeMax), all pages.
    func listWindow(calendarId: String, timeMin: Date, timeMax: Date) async throws -> [GEvent] {
        var out: [GEvent] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var query = [("singleEvents", "true"), ("orderBy", "startTime"),
                         ("timeMin", Self.rfc3339(timeMin)), ("timeMax", Self.rfc3339(timeMax)),
                         ("maxResults", "\(pageSize)"), ("maxAttendees", "\(Self.maxAttendees)"),
                         ("fields", Self.eventFields)]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page: GEventList = try await getJSON(url(Self.eventsPath(calendarId), query))
            out += page.items ?? []
            pageToken = page.nextPageToken
            pages += 1
            if pages >= maxPages { throw GoogleAPIError.tooManyPages }
        } while pageToken != nil
        return out
    }

    /// The change feed. Without a token it only pages to the end to get one (`fields=nextSyncToken`).
    func changeFeed(calendarId: String, syncToken: String?) async throws -> ChangeFeed {
        var ids: [String] = []
        var pageToken: String?
        var pages = 0
        while true {
            var query = [("maxResults", "\(feedPageSize)")]
            if let syncToken {
                query.append(("syncToken", syncToken))
                query.append(("fields", "items(id),nextPageToken,nextSyncToken"))
            } else {
                query.append(("fields", "nextPageToken,nextSyncToken"))
            }
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page: GEventIdList = try await getJSON(url(Self.eventsPath(calendarId), query), byteLimit: 16 << 20)
            ids += page.items?.compactMap(\.id) ?? []
            if let next = page.nextPageToken {
                pageToken = next
                pages += 1
                if pages >= maxPages { throw GoogleAPIError.tooManyPages }
                continue
            }
            guard let token = page.nextSyncToken else { throw GoogleAPIError.undecodable }
            return ChangeFeed(changedIds: ids, nextSyncToken: token, initial: syncToken == nil)
        }
    }

    /// A fresh copy of one event: decoded, plus the raw JSON (RSVP sends attendees back untouched).
    func getEvent(calendarId: String, eventId: String) async throws -> (event: GEvent, json: [String: Any]) {
        let response = try await send(.get, url(Self.eventPath(calendarId, eventId), []))
        guard let event = try? JSONDecoder().decode(GEvent.self, from: response.body),
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { throw GoogleAPIError.undecodable }
        return (event, json)
    }

    /// PATCH the attendee list with If-Match, so a change made in between fails with 412 instead of
    /// being overwritten.
    func patchAttendees(calendarId: String, eventId: String, attendees: [[String: Any]], etag: String) async throws -> GEvent {
        let body = try JSONSerialization.data(withJSONObject: ["attendees": attendees])
        let response = try await send(.patch, url(Self.eventPath(calendarId, eventId), [("sendUpdates", Self.rsvpSendUpdates)]),
                                      body: body, headers: ["If-Match": etag])
        guard let event = try? JSONDecoder().decode(GEvent.self, from: response.body) else { throw GoogleAPIError.undecodable }
        return event
    }

    // MARK: - URLs

    /// One path segment, everything outside RFC 3986 "unreserved" percent-encoded: calendar ids carry
    /// `#` and `@` (a public holiday calendar is `en.usa#holiday` at `group.v.calendar.google.com`).
    static func segment(_ value: String) -> String { FormURLEncoding.escape(value) }

    static func eventsPath(_ calendarId: String) -> String { "/calendars/\(segment(calendarId))/events" }

    static func eventPath(_ calendarId: String, _ eventId: String) -> String {
        "\(eventsPath(calendarId))/\(segment(eventId))"
    }

    func url(_ path: String, _ query: [(String, String)]) -> URL {
        var text = Self.base + path
        if !query.isEmpty {
            text += "?" + query.map { "\(FormURLEncoding.escape($0.0))=\(FormURLEncoding.escape($0.1))" }.joined(separator: "&")
        }
        return URL(string: text)!
    }

    static func rfc3339(_ date: Date) -> String { rfcFormatter.string(from: date) }

    private static let rfcFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Sending

    private func getJSON<T: Decodable>(_ url: URL, byteLimit: Int = 8 << 20) async throws -> T {
        let response = try await send(.get, url, byteLimit: byteLimit)
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw GoogleAPIError.undecodable
        }
    }

    /// Bearer auth; one retry with a fresh token after a 401. Token errors (invalid_grant, locked
    /// keychain) pass through unchanged so the scheduler can tell them apart.
    private func send(_ method: HTTPMethod, _ url: URL, body: Data? = nil, headers: [String: String] = [:],
                      byteLimit: Int = 8 << 20) async throws -> HTTPResponse {
        var refreshed = false
        while true {
            let token = try await tokens.accessToken(forceRefresh: refreshed)
            var all = headers
            all["Authorization"] = "Bearer \(token)"
            if body != nil { all["Content-Type"] = "application/json" }
            let response: HTTPResponse
            do {
                response = try await transport.send(HTTPRequest(method: method, url: url, headers: all, body: body,
                                                                byteLimit: byteLimit))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.classify(transport: error)
            }
            if response.status == 401 && !refreshed {
                await tokens.invalidateAccessToken()
                refreshed = true
                continue
            }
            guard response.isSuccess else { throw GoogleAPIError(response: response) }
            return response
        }
    }

    static func classify(transport error: Error) -> GoogleAPIError {
        switch OAuthFlow.classify(transport: error) {
        case .offline: return .offline
        case .provider(let code): return .transport(String(code.prefix(24)))
        default: return .transport("other")
        }
    }
}
