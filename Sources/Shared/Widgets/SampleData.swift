import AppKit
import Foundation

struct WidgetAccount {
    /// Stable key: the account UUID (snapshots: its logo is `widget/logos/<id>.png`) or a sample key.
    let id: String
    /// The tag shown on rows and chips ("ORB", "Personal").
    let short: String
    let name: String
    let logo: NSImage?   // nil = no badge (a personal account)
    /// 0xRRGGBB chosen in Accounts (snapshots); nil for sample accounts.
    var color: Int? = nil
}

struct WidgetMeeting {
    enum Reply { case accepted, maybe, needsReply }
    /// Position in its list (sample rows ping with it: `ping?probe=<kind>.<fam>.row.<id>`).
    let id: Int
    /// The primary copy's account.
    let account: WidgetAccount
    let title: String
    let start: Date
    let end: Date
    let place: String?
    let hasLink: Bool
    var reply: Reply = .accepted
    var clashes = false
    /// Snapshot rows: stable local row id + link key (CONTRACTS "Link keys"). Nil for sample data,
    /// whose rows keep pinging.
    var r: String? = nil
    var k: String? = nil
    /// Other accounts that have the same meeting (merged invites), after `account`.
    var also: [WidgetAccount] = []
    var allDay = false

    /// Every account that has it, primary first.
    var accountIds: [String] { [account.id] + also.map(\.id) }
    /// "ORB+CMT" for merged invites, the tag alone otherwise.
    var accountsLabel: String { ([account] + also).map(\.short).filter { !$0.isEmpty }.joined(separator: "+") }
    var isMerged: Bool { !also.isEmpty }
}

struct WidgetMail {
    let id: Int
    let account: WidgetAccount
    let sender: String
    let subject: String
    let at: Date
    let unread: Bool
    var r: String? = nil
    var k: String? = nil
    var starred = false
    /// Snapshot rows archived from a widget: the row reads "Archived · Undo" until `archivedAt + 30 s`,
    /// then leaves the list (`SnapshotModel.data(at:)` drops it).
    var archivedAt: Date? = nil
}

/// Whole-card states that replace the design: what a widget shows when there is nothing to draw.
enum WidgetCardState: Equatable {
    /// The design itself.
    case content
    /// On the desktop with no `widget/<kind>.json` yet: "Open Yaya's Calendar to connect your calendars".
    case noSnapshot
    /// The snapshot says no account is connected.
    case noAccounts
    /// Custom slot not set up yet.
    case setup
    /// Mail-backed content while mail is off: "Mail is off" (MailOffCopy).
    case mailComingSoon
}

/// Sync health as the widget renders it. Everything time-relative is computed from the entry date.
struct WidgetHealthInfo: Equatable {
    /// Tag of the account that needs a fresh sign-in, and the `reauth?a&k` link.
    var reauthTag: String? = nil
    var reauthLink: URL? = nil
    var syncedAt: Date? = nil
    /// The data layer marked the snapshot stale.
    var markedStale = false

    /// Past this, "Last synced …" shows even if the data layer still said ok (the app may have quit).
    static let staleAfter: TimeInterval = 30 * 60

    /// After a good sync, ↻ reads ✓ this long ("synced just now"): a widget can't animate while the app
    /// syncs, so the reload that follows a refresh tap says it worked. One timeline entry ends it.
    static let justSyncedWindow: TimeInterval = 30

    /// A healthy sync less than `justSyncedWindow` before `now`.
    func justSynced(at now: Date) -> Bool {
        guard reauthTag == nil, !markedStale, let syncedAt else { return false }
        let age = now.timeIntervalSince(syncedAt)
        return age >= 0 && age < Self.justSyncedWindow
    }

    func isStale(at now: Date) -> Bool {
        if markedStale { return true }
        guard let syncedAt else { return false }
        return now.timeIntervalSince(syncedAt) > Self.staleAfter
    }

    func footer(at now: Date) -> WidgetFooter {
        if let reauthTag { return .reauth(tag: reauthTag, link: reauthLink) }
        if isStale(at: now) {
            guard let syncedAt else { return .stale("Not synced yet") }
            return .stale("Last synced " + SyncText.ago(syncedAt, now: now))
        }
        return .none
    }
}

/// The one-line strip at the bottom of a widget: amber for re-auth, quiet for stale.
enum WidgetFooter: Equatable {
    case none
    case stale(String)
    case reauth(tag: String, link: URL?)
}

enum SyncText {
    /// "just now", "4 min ago", "2 h ago", "yesterday", "3 days ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}

/// Everything one widget render needs. Sample data fills the first four fields; a snapshot fills the rest
/// (SnapshotModel), with every value already resolved for one timeline entry date.
struct WidgetData {
    var now: Date
    var meetings: [WidgetMeeting]
    var mail: [WidgetMail]
    /// The Month widget's picked day.
    var selectedDay: Date
    /// Month shown by the Month grid (any date inside it); nil = the month of `now`.
    var monthShown: Date? = nil
    /// Days with at least one meeting, `YYYY-MM-DD` (Month dots beyond the meetings carried).
    var busyDays: Set<String> = []
    /// Sync window: Month arrows never leave it. Nil (sample data) = unbounded.
    var windowStart: Date? = nil
    var windowEnd: Date? = nil
    /// Agenda range in days from today (1, 2, 7); nil = everything carried.
    var rangeDays: Int? = nil
    /// Custom slots: the name chosen in Widget Studio.
    var title: String? = nil
    var accounts: [WidgetAccount] = []
    var health = WidgetHealthInfo()
    var unreadCount: Int? = nil
    /// What to draw; nil = the kind's own content (custom slots: the type chosen in Widget Studio).
    var content: WidgetContent? = nil
    var state: WidgetCardState = .content

    /// Meetings inside the agenda range (Agenda, Agenda & Inbox lists).
    var agendaMeetings: [WidgetMeeting] {
        guard let rangeDays, rangeDays > 0 else { return meetings }
        let cal = WidgetCalendar.current
        guard let end = cal.date(byAdding: .day, value: rangeDays, to: cal.startOfDay(for: now)) else { return meetings }
        return meetings.filter { $0.start < end }
    }

    /// An empty frame for a whole-card state.
    static func card(_ state: WidgetCardState, now: Date) -> WidgetData {
        WidgetData(now: now, meetings: [], mail: [], selectedDay: WidgetCalendar.current.startOfDay(for: now), state: state)
    }
}

/// The sample week, anchored to any day: offsets are relative to "Monday" (the anchor day), so
/// the live widget can show the same week starting today while renders pin Monday 19 October 2026.
/// Everything in it is the fictional Moonfield desk (`Cast`).
enum WidgetSample {
    /// The sample week's fixed "now": Monday 19 October 2026, 9:48 AM, London.
    static var fixedNow: Date {
        WidgetCalendar.fixed.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9, minute: 48))!
    }

    /// A `logos` value for callers with no folder at hand (the bench): draws the cast badges.
    static let badges = URL(fileURLWithPath: "/", isDirectory: true)

    /// The sample accounts, keyed by tag ("ORB", "CMT", "FAM") and "ME" for Personal. `logos`: nil = no
    /// badges (tests, fixture rows); any folder (the widget passes its own) = the cast's built-in badges,
    /// drawn in code. The folder is never read, so the logos of a Mac's own accounts never reach the
    /// sample. Personal never has a badge.
    static func accounts(logos: URL?) -> [String: WidgetAccount] {
        func account(_ c: Cast.Account) -> WidgetAccount {
            WidgetAccount(id: c.key, short: c.tag, name: c.name, logo: logos == nil ? nil : Cast.badge(key: c.key))
        }
        return ["ORB": account(Cast.orb), "CMT": account(Cast.cmt), "FAM": account(Cast.fam), "ME": account(Cast.home)]
    }

    /// The sample week with "now" at `now` (renders: `fixedNow`; widget: the real time).
    static func week(now: Date, logos: URL?, calendar: Calendar = WidgetCalendar.current) -> WidgetData {
        let a = accounts(logos: logos)
        let anchor = calendar.startOfDay(for: now)
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            let d = calendar.date(byAdding: .day, value: day - 19, to: anchor)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
        }
        var meetings: [WidgetMeeting] = []
        func m(_ acct: String, _ title: String, _ day: Int, _ h: Int, _ min: Int, _ length: Int,
               place: String? = nil, link: Bool = true, reply: WidgetMeeting.Reply = .accepted, clash: Bool = false) {
            let start = at(day, h, min)
            meetings.append(WidgetMeeting(id: meetings.count + 1, account: a[acct]!, title: title, start: start,
                                          end: start.addingTimeInterval(Double(length * 60)), place: place,
                                          hasLink: link, reply: reply, clashes: clash))
        }
        m("ORB", "Team stand-up", 19, 9, 30, 15)
        m("CMT", "The Comets weekly sync", 19, 10, 0, 45)
        m("FAM", "Holiday plan review", 19, 11, 30, 60)
        m("ME", "Lunch with Rafa", 19, 13, 0, 60, place: "Café Nowhere", link: false)
        m("ORB", "Pickle × Comets jingle weekly", 19, 14, 0, 60, clash: true)
        m("CMT", "Album artwork walkthrough", 19, 14, 30, 30, reply: .needsReply, clash: true)
        m("FAM", "School trip check-in", 19, 16, 0, 30)
        m("ME", "Gym", 19, 18, 30, 60, place: "Basement B", link: false)
        m("ORB", "Team stand-up", 20, 9, 30, 15)
        m("CMT", "Mix notes with Milo", 20, 11, 0, 30)
        m("FAM", "Kickoff · Garden project", 20, 12, 0, 60)
        m("ORB", "Design crit", 20, 15, 0, 45, reply: .maybe)
        m("ME", "Dentist", 20, 17, 0, 45, place: "Suite 404", link: false)
        m("ORB", "Team stand-up", 21, 9, 30, 15)
        m("CMT", "Tour planning", 21, 10, 30, 90)
        m("FAM", "Video call with Grandma", 21, 13, 0, 45)
        m("ORB", "1:1 with Juniper", 21, 15, 30, 30)
        m("ORB", "Team stand-up", 22, 9, 30, 15)
        m("CMT", "Monthly budget review", 22, 11, 0, 60)
        m("FAM", "Homework club", 22, 14, 0, 60)
        m("ME", "Yoga", 22, 19, 0, 90, place: "Riverside studio", link: false)
        m("ORB", "Team stand-up", 23, 9, 30, 15)
        m("CMT", "Gear check", 23, 12, 0, 45)
        m("ME", "Family dinner", 23, 20, 0, 120, link: false)
        m("ORB", "Team stand-up", 26, 9, 30, 15)
        m("FAM", "Meal planning", 26, 10, 0, 60)
        m("CMT", "Call with Lantern Hall", 26, 13, 0, 30)
        m("ORB", "All hands", 26, 16, 0, 60)

        var mail: [WidgetMail] = []
        func e(_ acct: String, _ sender: String, _ subject: String, _ day: Int, _ h: Int, _ min: Int, unread: Bool = true) {
            mail.append(WidgetMail(id: mail.count + 1, account: a[acct]!, sender: sender, subject: subject,
                                   at: at(day, h, min), unread: unread))
        }
        e("CMT", "Milo Brightwater", "Re: mix notes before Tuesday", 19, 9, 41)
        e("ORB", "Orbital Pickle Co.", "Agenda for today's weekly", 19, 9, 12)
        e("FAM", "Photo Backup", "Your import finished: 2,318 photos", 19, 8, 55, unread: false)
        e("ME", "Rafa", "Still on for lunch? 🍕", 19, 8, 30)
        e("ORB", "Juniper Vale", "Can we move our 1:1 to Wednesday?", 19, 8, 2)
        e("CMT", "The Quiet Comets", "October gig report is ready", 19, 7, 15, unread: false)
        e("FAM", "Sasha", "Holiday plan, v3", 18, 22, 10)
        e("ME", "Paper Cup Mobile", "Your bill is ready", 18, 19, 0, unread: false)
        e("ORB", "Pickle Wiki", "Weekly digest: 14 updates", 18, 17, 45, unread: false)
        e("CMT", "Lantern Hall", "Thanks for the call!", 18, 16, 20)
        e("FAM", "Snail Parcel", "Your parcel is on its way", 18, 12, 5, unread: false)
        e("ME", "Mom", "Photos from Saturday 📸", 18, 11, 30)
        e("ORB", "Google Calendar", "Invitation: All hands, Mon 26 Oct", 18, 10, 0, unread: false)
        e("CMT", "Gig Board", "Your band appeared in 41 searches", 17, 9, 0, unread: false)

        // Only the meetings still ahead matter to a real widget, but the sample passes the whole week
        // (the Month grid dots and "x of y meetings left" use the past ones too).
        return WidgetData(now: now, meetings: meetings, mail: mail, selectedDay: anchor)
    }

    /// D-013 fixture: a quiet week where most days have one or two meetings (slim day banners).
    static func sparseWeek(now: Date, logos: URL?, calendar: Calendar = WidgetCalendar.current) -> WidgetData {
        var data = week(now: now, logos: logos, calendar: calendar)
        let a = accounts(logos: logos)
        let anchor = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            let d = calendar.date(byAdding: .day, value: dayOffset, to: anchor)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
        }
        var meetings: [WidgetMeeting] = []
        func m(_ acct: String, _ title: String, _ day: Int, _ h: Int, _ min: Int, _ length: Int, link: Bool = true) {
            let start = at(day, h, min)
            meetings.append(WidgetMeeting(id: meetings.count + 1, account: a[acct]!, title: title, start: start,
                                          end: start.addingTimeInterval(Double(length * 60)), place: nil, hasLink: link))
        }
        m("ORB", "Team stand-up", 0, 9, 30, 15)
        m("CMT", "The Comets weekly sync", 0, 10, 0, 45)
        m("FAM", "Holiday plan review", 0, 11, 30, 60)
        m("ORB", "Design crit", 0, 15, 0, 45)
        m("CMT", "Mix notes with Milo", 1, 11, 0, 30)
        m("ME", "Dentist", 1, 17, 0, 45, link: false)
        m("FAM", "Video call with Grandma", 2, 13, 0, 45)
        m("ORB", "1:1 with Juniper", 2, 15, 30, 30)
        m("CMT", "Monthly budget review", 3, 11, 0, 60)
        m("FAM", "Homework club", 4, 14, 0, 60)
        m("ME", "Yoga", 4, 19, 0, 90, link: false)
        m("CMT", "Gear check", 7, 12, 0, 45)
        m("ORB", "All hands", 7, 16, 0, 60)
        m("FAM", "Meal planning", 8, 10, 0, 60)
        data.meetings = meetings
        return data
    }
}
