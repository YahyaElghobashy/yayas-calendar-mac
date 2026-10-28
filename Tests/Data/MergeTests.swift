import Foundation

/// Cross-account merge, primary choice, clash rules, and the CalendarStore reads.
enum MergeTests {
    static func run() {
        mergeAndPrimary()
        clashes()
        storeReads()
    }

    static func mergeAndPrimary() {
        let (db, _) = Seed.database("merge")
        let orb = Seed.account(db, email: "avery@orb.example", tag: "ORB", sort: 0)
        let cmt = Seed.account(db, email: "avery@cmt.example", tag: "CMT", sort: 1)
        let fam = Seed.account(db, email: "avery@fam.example", tag: "FAM", sort: 2)
        let all = [orb, cmt, fam]
        let start = TestCal.local(2026, 10, 20, 11)
        let end = start.addingTimeInterval(3600)
        // Same meeting (iCalUID + instance start) invited to ORB and CMT; client organizes it.
        let orbCopy = Seed.row(orb.id, id: "m1", title: "Kickoff", start: start, end: end, uid: "kick@client.example",
                               response: "needsAction", attendees: [StoredPerson(email: "avery@orb.example", response: "needsAction", isSelf: true, isOrganizer: false)])
        let cmtCopy = Seed.row(cmt.id, id: "x9", title: "Kickoff (CMT copy)", start: start, end: end, uid: "kick@client.example",
                               response: "accepted")
        let assembler = CalendarAssembler(accounts: all, calendars: [])
        let merged = assembler.events(rows: [cmtCopy, orbCopy], included: Set(all.map(\.id)))
        expect(merged.count == 1, "same iCalUID + instance start → one meeting")
        expect(merged.first?.accountIds == [orb.id, cmt.id], "no organizer copy: primary = first in account order")
        expect(merged.first?.r == orbCopy.groupId && orbCopy.groupId == cmtCopy.groupId, "merged r = shared group id")
        expect(merged.first?.title == "Kickoff" && merged.first?.myResponse == .needsAction, "fields from the primary copy")

        // The organizer's account wins, whatever the order.
        var organized = cmtCopy
        organized.organizerJSON = StoredPerson.encode(StoredPerson(email: "avery@cmt.example", isSelf: true, isOrganizer: true))
        let byOrganizer = assembler.events(rows: [orbCopy, organized], included: Set(all.map(\.id)))
        expect(byOrganizer.first?.accountIds == [cmt.id, orb.id], "organizer's account is primary")
        var organizedByEmail = cmtCopy
        organizedByEmail.organizerJSON = StoredPerson.encode(StoredPerson(email: "AVERY@cmt.example", isSelf: false, isOrganizer: true))
        expect(assembler.events(rows: [orbCopy, organizedByEmail], included: Set(all.map(\.id))).first?.accountIds.first == cmt.id,
               "organizer matched by account email (case-insensitive)")

        // Only included accounts appear; the primary is chosen among them.
        let onlyCMT = assembler.events(rows: [orbCopy, cmtCopy], included: [cmt.id])
        expect(onlyCMT.first?.accountIds == [cmt.id] && onlyCMT.first?.title == "Kickoff (CMT copy)", "excluded accounts drop out")

        // Different instance start = different meeting (recurring occurrences).
        let nextWeek = Seed.row(cmt.id, id: "x10", title: "Kickoff", start: start.addingTimeInterval(7 * 86_400),
                                end: end.addingTimeInterval(7 * 86_400), uid: "kick@client.example")
        expect(assembler.events(rows: [orbCopy, nextWeek], included: Set(all.map(\.id))).count == 2, "other occurrence not merged")

        // Two calendars in one account carrying the same meeting: one event, account listed once.
        let team = Seed.row(orb.id, calendar: googleCalendarID("team"), id: "m1", title: "Kickoff", start: start, end: end,
                            uid: "kick@client.example")
        let both = assembler.events(rows: [orbCopy, team], included: Set(all.map(\.id)))
        expect(both.count == 1 && both.first?.accountIds == [orb.id], "same account twice → listed once")
        expect(assembler.events(rows: [team, orbCopy], included: [orb.id]).first?.title == "Kickoff", "deterministic primary within an account")
    }

    static func clashes() {
        let (db, _) = Seed.database("clash")
        let orb = Seed.account(db, email: "a@orb.example", tag: "ORB", sort: 0)
        let cmt = Seed.account(db, email: "a@cmt.example", tag: "CMT", sort: 1)
        let assembler = CalendarAssembler(accounts: [orb, cmt], calendars: [])
        let base = TestCal.local(2026, 10, 21, 10)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        func flags(_ rows: [EventRecord], _ included: Set<UUID>? = nil) -> [String: Bool] {
            var out: [String: Bool] = [:]
            for e in assembler.events(rows: rows, included: included ?? [orb.id, cmt.id]) { out[e.title] = e.clashes }
            return out
        }
        let a = Seed.row(orb.id, id: "a", title: "A", start: at(0), end: at(60))
        let b = Seed.row(cmt.id, id: "b", title: "B", start: at(30), end: at(90))
        expect(flags([a, b]) == ["A": true, "B": true], "30-minute overlap across accounts clashes")
        let backToBack = Seed.row(cmt.id, id: "c", title: "C", start: at(60), end: at(120))
        expect(flags([a, backToBack]) == ["A": false, "C": false], "back to back is no clash")
        let oneMinute = Seed.row(cmt.id, id: "d", title: "D", start: at(59), end: at(120))
        expect(flags([a, oneMinute]) == ["A": true, "D": true], "exactly 1 minute overlap clashes")
        let underMinute = Seed.row(cmt.id, id: "e", title: "E", start: at(59.5), end: at(120))
        expect(flags([a, underMinute]) == ["A": false, "E": false], "30 s overlap is no clash")
        let free = Seed.row(cmt.id, id: "f", title: "F", start: at(10), end: at(20), busy: false)
        expect(flags([a, free]) == ["A": false, "F": false], "transparent (free) events never clash")
        let declined = Seed.row(cmt.id, id: "g", title: "G", start: at(10), end: at(20), response: "declined")
        expect(flags([a, declined]) == ["A": false, "G": false], "declined events never clash")
        let tentative = Seed.row(cmt.id, id: "t", title: "T", start: at(10), end: at(20), response: "tentative")
        expect(flags([a, tentative]) == ["A": true, "T": true], "tentative still clashes")
        let allDay = Seed.row(cmt.id, id: "h", title: "H", start: TestCal.local(2026, 10, 21), end: TestCal.local(2026, 10, 22), allDay: true)
        expect(flags([a, allDay]) == ["A": false, "H": false], "all-day events never clash")
        let mergedCopy = Seed.row(cmt.id, id: "a2", title: "A copy", start: at(0), end: at(60), uid: a.icalUID)
        expect(flags([a, mergedCopy]) == ["A": false], "merged copies don't clash with themselves")
        let sameAccount = Seed.row(orb.id, id: "s", title: "S", start: at(45), end: at(50))
        expect(flags([a, sameAccount]) == ["A": true, "S": true], "same-account overlap clashes too")
        let three = Seed.row(cmt.id, id: "z", title: "Z", start: at(200), end: at(260))
        expect(flags([a, b, three]) == ["A": true, "B": true, "Z": false], "only the overlapping pair is marked")
        expect(flags([a, b], [orb.id]) == ["A": false], "excluded accounts don't cause clashes")
    }

    static func storeReads() {
        let (db, _) = Seed.database("calendar-store")
        let orb = Seed.account(db, email: "a@orb.example", tag: "ORB", sort: 0)
        let cmt = Seed.account(db, email: "a@cmt.example", tag: "CMT", sort: 1)
        let off = Seed.account(db, email: "a@off.example", tag: "OFF", sort: 2, calendarOn: false)
        for acct in [orb, cmt, off] { Seed.calendar(db, acct.id, "primary", summary: "\(acct.tag) cal") }
        Seed.calendar(db, orb.id, "hidden", selected: false)
        let repo = EventRepo(db: db)
        let day = TestCal.local(2026, 10, 22)
        let edge = Seed.row(orb.id, id: "edge", title: "Edge", start: day.addingTimeInterval(-1800), end: day.addingTimeInterval(1800))
        let inside = Seed.row(cmt.id, id: "in", title: "Inside", start: day.addingTimeInterval(-600), end: day.addingTimeInterval(600),
                              join: "https://meet.google.com/abc-defg-hij")
        let offRow = Seed.row(off.id, id: "off", title: "Off", start: day.addingTimeInterval(3600), end: day.addingTimeInterval(7200))
        let other = Seed.row(orb.id, id: "next", title: "Next day", start: day.addingTimeInterval(86_400 + 3600),
                             end: day.addingTimeInterval(86_400 + 7200))
        for row in [edge, inside, offRow, other] { try? repo.upsert(row) }
        try? repo.upsert(Seed.row(orb.id, calendar: "hidden", id: "hid", title: "Hidden", start: day, end: day.addingTimeInterval(60)))

        let store = LocalCalendarStore(db: db)
        let dayEvents = (try? store.events(from: day, to: day.addingTimeInterval(86_400), accounts: nil)) ?? []
        expect(dayEvents.map(\.title) == ["Edge", "Inside"], "overlapping events, calendar-off account and unselected calendar excluded")
        expect(dayEvents.allSatisfy(\.clashes), "clash across the range edge still detected")
        expect(dayEvents.first?.calendarName == "ORB cal", "calendar name from the calendar list")
        let onlyCMT = (try? store.events(from: day, to: day.addingTimeInterval(86_400), accounts: [cmt.id])) ?? []
        expect(onlyCMT.map(\.title) == ["Inside"] && onlyCMT.first?.clashes == false, "account filter; no clash with excluded")
        let byGroup = try? store.event(r: inside.groupId)
        expect(byGroup?.title == "Inside" && byGroup?.joinURL?.host == "meet.google.com", "event(r:) by group id")
        expect((try? store.event(r: inside.r))?.r == inside.groupId, "event(r:) by row id resolves the group")
        expect((try? store.event(r: offRow.groupId)) ?? nil == nil, "calendar-off account's event not served")
        expect((try? store.event(r: "nope")) ?? nil == nil, "unknown r → nil")
        expect(((try? store.events(from: day, to: day, accounts: nil)) ?? [CalendarEvent]()).isEmpty, "empty range → nothing")
    }
}
