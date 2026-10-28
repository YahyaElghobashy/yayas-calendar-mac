import Foundation

/// Google event → row: UTC instants, all-day at local midnight (London DST fixture), recurring
/// instances, cancelled, responses, people, join links.
enum MapperTests {
    static let account = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    static func map(_ json: [String: Any], calendar: String = "primary") -> GoogleEventMapper.Outcome {
        GoogleEventMapper.map(G.decode(json), accountId: account, calendarId: calendar, calendar: TestCal.lab)
    }

    static func record(_ json: [String: Any]) -> EventRecord? {
        if case .event(let r) = map(json) { return r }
        return nil
    }

    static func run() {
        // Timed: the instant is kept, whatever offset Google used.
        let t = record(G.timed("t1", "Standup", "2026-10-20T09:00:00+01:00", "2026-10-20T09:30:00+01:00"))
        expect(t?.start == TestCal.iso("2026-10-20T08:00:00Z") && t?.end == TestCal.iso("2026-10-20T08:30:00Z"),
               "timed event stored as UTC instants")
        expect(t?.allDay == false && t?.busy == true && t?.myResponse == "accepted", "timed defaults")
        expect(t?.instanceStart == t?.start && t?.icalUID == "t1@google.example", "single event: instance start = start")
        let z = record(G.timed("t2", "UTC", "2026-10-20T06:00:00.000Z", "2026-10-20T07:00:00Z"))
        expect(z?.start == TestCal.iso("2026-10-20T06:00:00Z"), "fractional seconds and Z parse")

        // London DST fixture: clocks go back at 02:00 on Sun 25 Oct (BST +1 → GMT +0).
        let before = record(G.timed("d1", "Late call", "2026-10-25T01:30:00+01:00", "2026-10-25T01:59:00+01:00"))
        let repeated = record(G.timed("d2", "Repeated hour", "2026-10-25T01:30:00+00:00", "2026-10-25T02:30:00+00:00"))
        expect(before?.start == TestCal.iso("2026-10-25T00:30:00Z"), "01:30 BST = 00:30Z")
        expect(repeated?.start == TestCal.iso("2026-10-25T01:30:00Z"), "01:30 GMT (the repeated hour) = 01:30Z")
        expect(DayKey.string(repeated!.start, TestCal.lab) == "2026-10-25", "repeated hour stays on the 25th")
        let allDay25 = record(G.allDay("a25", "Holiday", "2026-10-25", "2026-10-26"))
        expect(allDay25?.allDay == true, "date-only = all-day")
        expect(allDay25?.start == TestCal.iso("2026-10-24T23:00:00Z"), "all-day starts at local midnight (+1)")
        expect(allDay25?.end == TestCal.iso("2026-10-26T00:00:00Z"), "all-day ends at the next local midnight (+0)")
        expect(allDay25.map { $0.end.timeIntervalSince($0.start) } == 25 * 3600, "the DST day spans 25 hours")
        expect(allDay25?.busy == false, "transparent all-day is not busy")
        let allDay26 = record(G.allDay("a26", "Day after", "2026-10-26", "2026-10-27"))
        expect(allDay26.map { $0.end.timeIntervalSince($0.start) } == 24 * 3600, "the 26th is 24 hours")
        let multi = record(G.allDay("am", "Trip", "2026-10-28", "2026-11-01"))
        expect(multi?.start == DayKey.date("2026-10-28", TestCal.lab) && multi?.end == DayKey.date("2026-11-01", TestCal.lab),
               "multi-day all-day spans dates (end exclusive)")
        let zeroLength = record(G.allDay("az", "Bad end", "2026-10-28", "2026-10-28"))
        expect(zeroLength.map { $0.end.timeIntervalSince($0.start) } == 24 * 3600, "all-day with end ≤ start gets one day")

        // Recurring instances: same iCalUID, own ids, own instance starts.
        let i1 = record(G.timed("w_20261020T080000Z", "Weekly", "2026-10-20T09:00:00+01:00", "2026-10-20T10:00:00+01:00",
                                uid: "weekly@google.example", recurring: "w", original: "2026-10-20T09:00:00+01:00"))
        let i2 = record(G.timed("w_20261027T090000Z", "Weekly", "2026-10-27T09:00:00+00:00", "2026-10-27T10:00:00+00:00",
                                uid: "weekly@google.example", recurring: "w", original: "2026-10-27T09:00:00+00:00"))
        let moved = record(G.timed("w_20261103T090000Z", "Weekly (moved)", "2026-11-03T15:00:00+00:00", "2026-11-03T16:00:00+00:00",
                                   uid: "weekly@google.example", recurring: "w", original: "2026-11-03T09:00:00+00:00"))
        expect(i1?.icalUID == i2?.icalUID && i1?.r != i2?.r && i1?.groupId != i2?.groupId, "instances: same uid, own r and group")
        expect(i2?.start == TestCal.iso("2026-10-27T09:00:00Z"), "after DST the 9:00 instance is 09:00Z")
        expect(moved?.instanceStart == TestCal.iso("2026-11-03T09:00:00Z") && moved?.start == TestCal.iso("2026-11-03T15:00:00Z"),
               "moved instance keeps its original start as instance start")

        // Cancelled and ignored types.
        expect(map(G.timed("c1", "Gone", "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z", status: "cancelled")) == .cancelled("c1"),
               "cancelled → delete")
        expect(map(G.timed("wl", "Home", "2026-10-20T09:00:00Z", "2026-10-20T10:00:00Z", type: "workingLocation")) == .skipped,
               "working location markers skipped")
        expect(map(["id": "x", "summary": "no times"]) == .skipped, "event without times skipped")

        // People and responses.
        let invite = record(G.timed("inv", "Review", "2026-10-21T12:00:00Z", "2026-10-21T13:00:00Z",
                                    attendees: [G.guest("boss@client.example", organizer: true), G.me("me@orb.example", "tentative"),
                                                ["email": googleCalendarID("room-4b", "resource.calendar.google.com"), "resource": true, "responseStatus": "accepted"]],
                                    organizer: G.organizer("boss@client.example")))
        expect(invite?.myResponse == "tentative", "my response from the self attendee")
        let people = StoredPerson.decodeList(invite?.attendeesJSON)
        expect(people.count == 2 && people.contains { $0.isSelf } && !people.contains { $0.email.contains("resource") },
               "attendees stored without rooms")
        expect(StoredPerson.decodeOne(invite?.organizerJSON)?.email == "boss@client.example", "organizer stored")
        let pending = record(G.timed("p", "Pending", "2026-10-21T12:00:00Z", "2026-10-21T13:00:00Z",
                                     attendees: [G.me("me@orb.example", "needsAction")]))
        expect(pending?.myResponse == "needsAction", "pending invite")
        let weird = record(G.timed("q", "Odd", "2026-10-21T12:00:00Z", "2026-10-21T13:00:00Z", attendees: [G.me("me@orb.example", "bogus")]))
        expect(weird?.myResponse == "needsAction", "unknown response → needsAction")
        expect(record(G.timed("o", "Own", "2026-10-21T12:00:00Z", "2026-10-21T13:00:00Z"))?.myResponse == "accepted",
               "no attendees → accepted")

        // Links, notes, place.
        let rich = record(G.timed("j", "Call", "2026-10-21T12:00:00Z", "2026-10-21T13:00:00Z", location: "Suite 404",
                                  description: "<p>Agenda</p><a href=\"https://zoom.us/j/5\">Zoom</a>",
                                  hangout: "https://meet.google.com/abc-defg-hij", video: ["https://meet.google.com/abc-defg-hij"]))
        expect(rich?.joinURL == "https://meet.google.com/abc-defg-hij", "conference video link wins")
        expect(rich?.notes == "Agenda\nZoom", "description stored as plain text")
        expect(rich?.location == "Suite 404", "location stored")
        expect(rich?.webURL?.hasPrefix("https://www.google.com/calendar/event") == true, "htmlLink kept as webURL")
        var insecure = G.timed("h", "x", "2026-10-21T12:00:00Z", "2026-10-21T13:00:00Z")
        insecure["htmlLink"] = "http://www.google.com/calendar/event?eid=h"
        expect(record(insecure)?.webURL == nil, "non-https htmlLink dropped")
        let untitled = record(["id": "u", "start": ["dateTime": "2026-10-21T12:00:00Z"], "end": ["dateTime": "2026-10-21T12:00:00Z"]])
        expect(untitled?.title == "" && untitled?.icalUID == "u", "missing summary/iCalUID tolerated")

        // Calendar list defaults.
        func entry(_ json: [String: Any]) -> GCalendarListEntry {
            try! JSONDecoder().decode(GCalendarListEntry.self, from: JSONSerialization.data(withJSONObject: json))
        }
        expect(entry(["id": "me@orb.example", "selected": true, "accessRole": "owner"]).includedByDefault, "selected → included")
        expect(!entry(["id": googleCalendarID("en.uk#holiday", "group.v.calendar.google.com"), "accessRole": "reader"]).includedByDefault,
               "holidays not selected (flag omitted) → excluded")
        expect(entry(["id": googleCalendarID("addressbook#contacts", "group.v.calendar.google.com"), "selected": true, "accessRole": "reader"]).includedByDefault,
               "birthdays selected in Google → included")
        expect(!entry(["id": "h", "selected": true, "hidden": true]).includedByDefault, "hidden → excluded")
        expect(!entry(["id": "f", "selected": true, "accessRole": "freeBusyReader"]).includedByDefault, "free/busy only → excluded")
        expect(entry(["id": "c", "backgroundColor": "#9fe1e7"]).color == 0x9FE1E7, "calendar colour parsed")
        expect(entry(["id": "c", "summary": "Team", "summaryOverride": "Mine"]).displayName == "Mine", "summaryOverride wins")
    }
}
