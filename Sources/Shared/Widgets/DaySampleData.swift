import AppKit
import Foundation

/// Day widget design fixtures (renders, the bench and DayLayout tests): one day each, on the
/// sample week's Monday 19 October 2026, built from the sample accounts with their Accounts colours.
enum DaySample {
    struct Scenario {
        let key: String
        let label: String
        let now: Date
        let meetings: [WidgetMeeting]
    }

    /// Sample accounts with the colours the fixture accounts carry (the cast's Accounts swatches).
    static func accounts(logos: URL?) -> [String: WidgetAccount] {
        var a = WidgetSample.accounts(logos: logos)
        let colours: [String: Cast.Account] = ["ORB": Cast.orb, "CMT": Cast.cmt, "FAM": Cast.fam, "ME": Cast.home]
        for (key, account) in colours { a[key]?.color = Int(account.color) }
        return a
    }

    static func all(logos: URL?, calendar: Calendar = WidgetCalendar.current) -> [Scenario] {
        let now = WidgetSample.fixedNow
        return [
            Scenario(key: "busy", label: "Busy day · 3- and 4-way overlaps", now: now,
                     meetings: busy(logos: logos, calendar: calendar)),
            Scenario(key: "allday", label: "All-day events + early and late meetings", now: now,
                     meetings: allDayEarlyLate(logos: logos, calendar: calendar)),
            Scenario(key: "light", label: "Light day · 2 meetings", now: now,
                     meetings: light(logos: logos, calendar: calendar)),
            Scenario(key: "empty", label: "Empty day", now: now, meetings: []),
            Scenario(key: "now", label: "Now, mid-meeting (10:20 AM)", now: at(10, 20, calendar: calendar),
                     meetings: busy(logos: logos, calendar: calendar)),
        ]
    }

    static func at(_ hour: Int, _ minute: Int, calendar cal: Calendar = WidgetCalendar.current) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.startOfDay(for: WidgetSample.fixedNow))!
    }

    private final class Builder {
        let a: [String: WidgetAccount]
        let cal: Calendar
        var out: [WidgetMeeting] = []
        init(_ a: [String: WidgetAccount], _ cal: Calendar) { self.a = a; self.cal = cal }

        func m(_ acct: String, _ title: String, _ h: Int, _ min: Int, _ length: Int, place: String? = nil,
               link: Bool = true, reply: WidgetMeeting.Reply = .accepted, allDay: Bool = false) {
            let start = allDay ? cal.startOfDay(for: WidgetSample.fixedNow) : DaySample.at(h, min, calendar: cal)
            let end = allDay ? cal.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(Double(length * 60))
            var meeting = WidgetMeeting(id: out.count + 1, account: a[acct]!, title: title, start: start, end: end,
                                        place: place, hasLink: link, reply: reply)
            meeting.allDay = allDay
            out.append(meeting)
        }
    }

    /// (a) Back-to-back, same start, nested, a 4-way at 10:30, a long workshop with short ones inside.
    static func busy(logos: URL?, calendar: Calendar = WidgetCalendar.current) -> [WidgetMeeting] {
        let b = Builder(accounts(logos: logos), calendar)
        b.m("ME", "Inbox hour", 8, 30, 30, link: false)
        b.m("ORB", "Team stand-up", 9, 0, 15)
        b.m("ORB", "1:1 with Juniper", 9, 15, 15)                                // back-to-back
        b.m("CMT", "The Comets weekly sync", 10, 0, 45)                          // same start ↓
        b.m("FAM", "Party planning", 10, 0, 40)
        b.m("ORB", "Prep · Pickle × Comets", 10, 15, 45)
        b.m("ME", "Call the bank", 10, 30, 15, link: false)                      // 4-way 10:30–10:40
        b.m("FAM", "Holiday plan review", 11, 30, 60)
        b.m("CMT", "Budget check", 11, 45, 30, reply: .maybe)                    // nested + tentative
        b.m("ME", "Lunch with Rafa", 13, 0, 60, place: "Café Nowhere", link: false)
        b.m("ORB", "Q4 planning workshop", 14, 0, 180, place: "Room 404")        // long ↓ short inside
        b.m("CMT", "Album artwork walkthrough", 14, 30, 30, reply: .needsReply)
        b.m("FAM", "Quick call", 15, 0, 15)
        b.m("FAM", "School trip check-in", 15, 30, 30)
        b.m("ORB", "Wrap-up", 17, 30, 30)
        b.m("ME", "Gym", 18, 30, 60, place: "Basement B", link: false)
        return b.out
    }

    /// (b) Two all-day events, a 7 AM call and two late ones.
    static func allDayEarlyLate(logos: URL?, calendar: Calendar = WidgetCalendar.current) -> [WidgetMeeting] {
        let b = Builder(accounts(logos: logos), calendar)
        b.m("ORB", "Company offsite", 0, 0, 0, allDay: true)
        b.m("ME", "Mom's birthday", 0, 0, 0, link: false, allDay: true)
        b.m("CMT", "Early call · Tokyo office", 7, 0, 30)
        b.m("ORB", "Offsite: kickoff", 9, 30, 60, place: "The lake house")
        b.m("FAM", "Video call with Grandma", 13, 0, 45)
        b.m("FAM", "Late sync · West coast", 21, 0, 60)
        b.m("CMT", "Late show soundcheck", 22, 30, 45)
        return b.out
    }

    /// (c) Two meetings.
    static func light(logos: URL?, calendar: Calendar = WidgetCalendar.current) -> [WidgetMeeting] {
        let b = Builder(accounts(logos: logos), calendar)
        b.m("CMT", "Mix notes with Milo", 11, 0, 45)
        b.m("FAM", "Homework club", 15, 30, 30)
        return b.out
    }

    /// The bench's 20-meeting day: the busy day plus four more, one of them a 5-way pile-up.
    static func twenty(logos: URL?, calendar: Calendar = WidgetCalendar.current) -> [WidgetMeeting] {
        var out = busy(logos: logos, calendar: calendar)
        let b = Builder(accounts(logos: logos), calendar)
        b.m("CMT", "Venue intro", 10, 30, 30)
        b.m("ORB", "Design crit", 16, 0, 45, reply: .maybe)
        b.m("FAM", "Homework club", 16, 15, 45)
        b.m("ME", "Pick up groceries", 16, 30, 20, link: false)
        for var m in b.out { m = WidgetMeeting(id: out.count + 1, account: m.account, title: m.title, start: m.start, end: m.end,
                                               place: m.place, hasLink: m.hasLink, reply: m.reply); out.append(m) }
        return out
    }
}
