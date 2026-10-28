import Foundation

/// GoogleCalendarClient against the fake server: URLs, paging, the change feed, errors.
enum ProviderTests {
    static func client(_ google: FakeGoogle, _ tokens: FakeTokens, pageSize: Int = 250) -> GoogleCalendarClient {
        GoogleCalendarClient(transport: google, tokens: tokens, pageSize: pageSize)
    }

    static func run() async {
        await encoding()
        await calendarListPaging()
        await windowPaging()
        await feed()
        await errors()
    }

    static func encoding() async {
        let holidays = "group.v.calendar.google.com"
        let holiday = googleCalendarID("en.uk#holiday", holidays)
        expect(GoogleCalendarClient.segment(holiday) == "en.uk%23holiday%40\(holidays)", "# and @ percent-encoded")
        expect(GoogleCalendarClient.eventPath("a/b@x", "ev 1") == "/calendars/a%2Fb%40x/events/ev%201", "every segment encoded")
        let google = FakeGoogle()
        let tokens = FakeTokens(token: "tok")
        google.addCalendar(token: "tok", id: holiday, summary: "Holidays", selected: true, accessRole: "reader")
        google.put(token: "tok", calendar: holiday, G.allDay("h1", "Bank holiday", "2026-10-12", "2026-10-13"))
        let events = (try? await client(google, tokens).listWindow(calendarId: holiday, timeMin: TestCal.local(2026, 10, 1),
                                                                   timeMax: TestCal.local(2026, 11, 1))) ?? []
        expect(events.map(\.id) == ["h1"], "events of a #/@ calendar listed")
        let url = google.requests.last?.url
        expect(url?.absoluteString.contains("/calendars/en.uk%23holiday%40\(holidays)/events?") == true,
               "request path carries the encoded id")
        expect(url.map { (try? HTTP.validate($0)) != nil } == true && url?.fragment == nil, "no fragment: passes the HTTP policy")
        expect(google.requests.last?.headers["Authorization"] == "Bearer tok", "bearer token sent")
    }

    static func calendarListPaging() async {
        let google = FakeGoogle()
        google.calendarListPageSize = 2
        for i in 0..<5 { google.addCalendar(token: "tok", id: "cal\(i)", summary: "C\(i)", selected: i % 2 == 0) }
        let list = (try? await client(google, FakeTokens(token: "tok")).calendarList()) ?? []
        expect(list.map(\.id) == ["cal0", "cal1", "cal2", "cal3", "cal4"], "calendarList pages through all entries")
        expect(google.requests.count == 3, "5 entries at 2 per page = 3 requests")
        expect(list.filter(\.includedByDefault).map(\.id) == ["cal0", "cal2", "cal4"], "selected flags read")
    }

    static func windowPaging() async {
        let google = FakeGoogle()
        google.addCalendar(token: "tok", id: "me@orb.example", summary: "me")
        for i in 0..<5 {
            google.put(token: "tok", calendar: "me@orb.example",
                       G.timed("e\(i)", "E\(i)", "2026-10-2\(i)T09:00:00+01:00", "2026-10-2\(i)T10:00:00+01:00"))
        }
        google.put(token: "tok", calendar: "me@orb.example", G.timed("out", "Outside", "2027-03-01T09:00:00Z", "2027-03-01T10:00:00Z"))
        let events = (try? await client(google, FakeTokens(token: "tok"), pageSize: 2)
            .listWindow(calendarId: "me@orb.example", timeMin: TestCal.local(2026, 10, 1), timeMax: TestCal.local(2027, 1, 1))) ?? []
        expect(events.map(\.id) == ["e0", "e1", "e2", "e3", "e4"], "window list: all pages, in start order, window only")
        expect(google.requests.count == 3, "5 events at 2 per page = 3 requests")
        let query = google.requests.first.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        expect(value("singleEvents") == "true" && value("orderBy") == "startTime", "singleEvents + orderBy=startTime")
        expect(value("timeMin") == "2026-09-30T23:00:00Z" && value("timeMax") == "2027-01-01T00:00:00Z", "RFC 3339 UTC bounds")
        expect(value("syncToken") == nil, "never a syncToken on the window list")
        expect(value("maxAttendees") == "60" && value("fields")?.contains("conferenceData") == true, "fields + maxAttendees")
    }

    static func feed() async {
        let google = FakeGoogle()
        google.feedPageSize = 1
        google.addCalendar(token: "tok", id: "me@orb.example", summary: "me")
        let api = client(google, FakeTokens(token: "tok"))
        let first = try? await api.changeFeed(calendarId: "me@orb.example", syncToken: nil)
        expect(first?.initial == true && first?.changedIds.isEmpty == true && first?.nextSyncToken == "s1",
               "first read pages to the end for a token")
        let firstQuery = google.requests.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        expect(google.requests.count == 2, "token fetch followed nextPageToken")
        expect(firstQuery.allSatisfy { q in q.first { $0.name == "fields" }?.value == "nextPageToken,nextSyncToken" },
               "token fetch asks only for nextSyncToken/nextPageToken")
        expect(firstQuery.allSatisfy { q in !q.contains { $0.name == "timeMin" || $0.name == "singleEvents" } },
               "feed is unbounded (no timeMin/timeMax/singleEvents)")
        google.feedPageSize = nil
        google.put(token: "tok", calendar: "me@orb.example", G.timed("n1", "New", "2026-10-22T09:00:00Z", "2026-10-22T10:00:00Z"))
        google.clearLog()
        let second = try? await api.changeFeed(calendarId: "me@orb.example", syncToken: first?.nextSyncToken)
        expect(second?.changedIds == ["n1"] && second?.initial == false && second?.nextSyncToken == "s2", "incremental feed reports ids")
        let q = google.requests.first.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        expect(q.first { $0.name == "syncToken" }?.value == "s1" && !q.contains { $0.name == "timeMin" || $0.name == "orderBy" },
               "syncToken never combined with timeMin/orderBy")
        expect(q.first { $0.name == "fields" }?.value == "items(id),nextPageToken,nextSyncToken", "feed asks for ids only")
        google.expireTokens(token: "tok", calendar: "me@orb.example")
        do {
            _ = try await api.changeFeed(calendarId: "me@orb.example", syncToken: second?.nextSyncToken)
            expect(false, "expired token should fail")
        } catch {
            expect(error as? GoogleAPIError == .gone, "410 → .gone")
        }
    }

    static func errors() async {
        let google = FakeGoogle()
        google.addCalendar(token: "tok", id: "me@orb.example", summary: "me")
        let tokens = FakeTokens(token: "tok")
        let api = client(google, tokens)

        google.inject("calendarList", status: 401, body: #"{"error":{"code":401}}"#)
        let afterRefresh = try? await api.calendarList()
        expect(afterRefresh?.count == 1, "401 → refresh token and retry once")
        expect(tokens.invalidations.value == 1 && tokens.forced.value == 1, "access token invalidated and force-refreshed")

        google.inject("calendarList", status: 401, body: "{}", times: 2)
        await expectError(GoogleAPIError.unauthorized, "second 401 → unauthorized") { _ = try await api.calendarList() }

        google.inject("calendarList", status: 429, body: "{}", headers: ["retry-after": "30"])
        await expectError(GoogleAPIError.rateLimited(retryAfter: 30), "429 → rateLimited with Retry-After") { _ = try await api.calendarList() }

        google.inject("calendarList", status: 403, body: #"{"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"rateLimitExceeded"}]}}"#)
        await expectError(GoogleAPIError.rateLimited(retryAfter: nil), "403 rateLimitExceeded → rateLimited") { _ = try await api.calendarList() }

        google.inject("calendarList", status: 403, body: #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#)
        await expectError(GoogleAPIError.rateLimited(retryAfter: nil), "403 userRateLimitExceeded → rateLimited") { _ = try await api.calendarList() }

        google.inject("calendarList", status: 403, body: #"{"error":{"code":403,"errors":[{"reason":"forbidden"}]}}"#)
        await expectError(GoogleAPIError.forbidden(reason: "forbidden"), "403 other → forbidden") { _ = try await api.calendarList() }

        google.inject("calendarList", status: 503, body: "{}")
        await expectError(GoogleAPIError.server(status: 503, retryAfter: nil), "503 → server") { _ = try await api.calendarList() }

        google.inject("calendarList", status: 200, body: "not json")
        await expectError(GoogleAPIError.undecodable, "garbage → undecodable") { _ = try await api.calendarList() }

        tokens.error.value = AuthError.reauthNeeded(code: "invalid_grant")
        do {
            _ = try await api.calendarList()
            expect(false, "token error should throw")
        } catch {
            expect(error as? AuthError == .reauthNeeded(code: "invalid_grant"), "token errors pass through unchanged")
        }
        tokens.error.value = nil
        expect(GoogleAPIError.server(status: 502, retryAfter: 5).code == "server_502", "error codes are short")
    }

    static func expectError(_ expected: GoogleAPIError, _ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            expect(false, name + " (no error)")
        } catch {
            expect(error as? GoogleAPIError == expected, name + " (got \(error))")
        }
    }
}
