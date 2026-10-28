import Foundation

/// RSVP: fresh GET → PATCH attendees with If-Match, every pending copy, 412 → refetch + one retry.
enum RSVPTests {
    static func run() async {
        await everyPendingCopy()
        await preconditionRetry()
        await changedMind()
    }

    static func patches(_ google: FakeGoogle) -> [HTTPRequest] { google.requests.filter { $0.method == .patch } }

    /// ORB and CMT both got the client's invite; both copies are pending.
    static func setup(_ name: String, orbResponse: String = "needsAction", cmtResponse: String = "needsAction")
        -> (Harness, AccountRecord, AccountRecord, String, String) {
        let h = Harness(name)
        let (orb, orbToken) = h.account("avery@orb.example", tag: "ORB", sort: 0)
        let (cmt, cmtToken) = h.account("avery@cmt.example", tag: "CMT", sort: 1)
        for (token, me, response, id) in [(orbToken, "avery@orb.example", orbResponse, "orbcopy"), (cmtToken, "avery@cmt.example", cmtResponse, "cmtcopy")] {
            h.google.put(token: token, calendar: me,
                         G.timed(id, "Project kickoff", "2026-10-22T12:00:00+01:00", "2026-10-22T13:00:00+01:00", uid: "kick@client.example",
                                 attendees: [G.guest("boss@client.example", organizer: true), G.guest("other@client.example", "declined"),
                                             G.me(me, response)],
                                 organizer: G.organizer("boss@client.example")))
        }
        return (h, orb, cmt, orbToken, cmtToken)
    }

    static func everyPendingCopy() async {
        let (h, orb, cmt, orbToken, cmtToken) = setup("rsvp-both")
        let engine = h.engine
        _ = await engine.syncAccount(orb.id, force: true)
        _ = await engine.syncAccount(cmt.id, force: true)
        guard let event = try? engine.calendarStore.events(from: TestCal.local(2026, 10, 22), to: TestCal.local(2026, 10, 23),
                                                           accounts: nil).first else {
            expect(false, "merged invite listed"); return
        }
        expect(event.accountIds == [orb.id, cmt.id] && event.myResponse == .needsAction, "merged pending invite")
        h.google.clearLog()
        h.reloader.reset()
        do {
            try await engine.calendarStore.rsvp(r: event.r, response: .accepted)
        } catch {
            expect(false, "rsvp threw \(error)")
        }
        let sent = patches(h.google)
        expect(sent.count == 2, "both pending copies patched")
        let gets = h.google.requests.filter { $0.method == .get && $0.url.path.contains("/events/") && !$0.url.path.hasSuffix("/events") }
        expect(gets.count == 2, "a fresh GET before each PATCH")
        expect(sent.allSatisfy { $0.headers["If-Match"]?.hasPrefix("\"") == true }, "PATCH carries If-Match with the etag")
        expect(sent.allSatisfy { $0.url.query?.contains("sendUpdates=all") == true }, "sendUpdates on the PATCH")
        for (token, me, id) in [(orbToken, "avery@orb.example", "orbcopy"), (cmtToken, "avery@cmt.example", "cmtcopy")] {
            let attendees = h.google.event(token: token, calendar: me, eventId: id)?["attendees"] as? [[String: Any]] ?? []
            let mine = attendees.first { ($0["self"] as? Bool) == true }
            expect(mine?["responseStatus"] as? String == "accepted", "\(id): self attendee accepted on Google")
            expect(attendees.count == 3 && attendees.contains { ($0["email"] as? String) == "other@client.example"
                && ($0["responseStatus"] as? String) == "declined" }, "\(id): other attendees sent back untouched")
        }
        let after = try? engine.calendarStore.event(r: event.r)
        expect(after?.myResponse == .accepted, "local copy updated (and re-listed)")
        expect(lists(h.google) >= 2, "both touched accounts re-listed after the RSVP")
        expect(h.reloader.reloads.value.contains("agenda.all"), "RSVP republishes and reloads widgets now")

        // Nothing pending any more: only the primary copy is patched when the answer changes.
        h.google.clearLog()
        try? await engine.calendarStore.rsvp(r: event.r, response: .declined)
        expect(patches(h.google).count == 1 && patches(h.google).first?.url.absoluteString.contains("orb.example") == true,
               "changed mind: only the primary copy is patched")
    }

    static func lists(_ google: FakeGoogle) -> Int {
        google.requests.filter { $0.url.query?.contains("singleEvents=true") ?? false }.count
    }

    static func preconditionRetry() async {
        let (h, orb, _, orbToken, _) = setup("rsvp-412")
        let engine = h.engine
        _ = await engine.syncAccount(orb.id, force: true)
        let r = (try? engine.calendarStore.events(from: TestCal.local(2026, 10, 22), to: TestCal.local(2026, 10, 23), accounts: [orb.id]))?.first?.r ?? ""
        h.google.forced412 = 1
        h.google.clearLog()
        do {
            try await engine.calendarStore.rsvp(r: r, response: .tentative)
        } catch {
            expect(false, "a single 412 should be retried, got \(error)")
        }
        expect(patches(h.google).count == 2, "412 → refetch and one retry")
        let gets = h.google.requests.filter { $0.method == .get && $0.url.path.hasSuffix("/events/orbcopy") }
        expect(gets.count == 2, "the retry starts with a fresh GET (new etag)")
        let mine = (h.google.event(token: orbToken, calendar: "avery@orb.example", eventId: "orbcopy")?["attendees"] as? [[String: Any]])?
            .first { ($0["self"] as? Bool) == true }
        expect(mine?["responseStatus"] as? String == "tentative", "retry succeeded")

        h.google.forced412 = 2
        h.google.clearLog()
        do {
            try await engine.calendarStore.rsvp(r: r, response: .declined)
            expect(false, "two 412s should fail")
        } catch {
            expect(error as? GoogleAPIError == .preconditionFailed, "a second 412 surfaces")
        }
        expect(patches(h.google).count == 2, "only one retry")
    }

    static func changedMind() async {
        let (h, orb, cmt, _, _) = setup("rsvp-partial", orbResponse: "accepted", cmtResponse: "needsAction")
        let engine = h.engine
        _ = await engine.syncAccount(orb.id, force: true)
        _ = await engine.syncAccount(cmt.id, force: true)
        let r = (try? engine.calendarStore.events(from: TestCal.local(2026, 10, 22), to: TestCal.local(2026, 10, 23), accounts: nil))?.first?.r ?? ""
        h.google.clearLog()
        try? await engine.calendarStore.rsvp(r: r, response: .accepted)
        expect(patches(h.google).count == 1 && patches(h.google).first?.url.absoluteString.contains("cmt.example") == true,
               "only the copy still pending is answered")

        // Not a guest (own event without attendees) → a clear error, no PATCH.
        h.google.put(token: "access-\(orb.id.uuidString)", calendar: "avery@orb.example",
                     G.timed("own", "Focus", "2026-10-23T09:00:00Z", "2026-10-23T10:00:00Z"))
        _ = await engine.syncAccount(orb.id, force: true)
        let own = (try? engine.calendarStore.events(from: TestCal.local(2026, 10, 23), to: TestCal.local(2026, 10, 24), accounts: nil))?
            .first { $0.title == "Focus" }
        h.google.clearLog()
        do {
            try await engine.calendarStore.rsvp(r: own?.r ?? "", response: .accepted)
            expect(false, "rsvp on own event should fail")
        } catch {
            expect(error is ServiceError && patches(h.google).isEmpty, "not a guest → ServiceError, no PATCH")
        }
        do {
            try await engine.calendarStore.rsvp(r: "missing", response: .accepted)
            expect(false, "unknown r should fail")
        } catch {
            expect(error is ServiceError, "unknown meeting → ServiceError")
        }
    }
}
