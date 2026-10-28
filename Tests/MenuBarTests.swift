import AppKit
import Foundation

/// UI layer: the status title (countdown words, rounding, truncation, 24 h+, right-to-left scripts and bidi),
/// which meeting the menu bar talks about, what ⌃⌥J does, the popover model and placement, the welcome
/// guide's flow, notification pause, menu-bar settings and VoiceOver words. Fakes and memory bags only:
/// no user defaults, Keychain, network or Carbon.
@MainActor
enum MenuBarTests {
    static let cal = WidgetCalendar.fixed
    static let now = WidgetSample.fixedNow

    static func run() {
        durations()
        countdowns()
        truncation()
        rightToLeft()
        modes()
        focus()
        hotkey()
        pause()
        prefs()
        settingsModel()
        popover()
        popoverMail()
        placement()
        onboarding()
        accessibility()
    }

    // MARK: Helpers

    static func event(_ title: String = "Standup", r: String? = nil, startIn minutes: Double, length: Double = 15,
                      join: String? = "https://meet.google.com/abc-defg-hij", allDay: Bool = false,
                      reply: CalendarEvent.Response = .accepted, account: UUID = FixtureAccounts.orb) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(r: r ?? "ev-\(title)-\(minutes)", accountIds: [account], calendarName: "Work", title: title,
                             start: start, end: start.addingTimeInterval(length * 60), allDay: allDay, location: nil,
                             joinURL: join.flatMap(URL.init(string:)), webURL: nil, notes: nil, organizer: nil, attendees: [],
                             myResponse: reply, clashes: false)
    }

    static func title(_ e: CalendarEvent?, at t: Date = now) -> String? { StatusTitle.countdown(e, now: t) }

    // MARK: Status title

    static func durations() {
        T.section("Status title: durations round up like the widget")
        T.equal(StatusTitle.duration(30), "1m", "30 s → 1m")
        T.equal(StatusTitle.duration(7 * 60), "7m", "7 min")
        T.equal(StatusTitle.duration(6 * 60 + 1), "7m", "6 min 1 s rounds up to 7m")
        T.equal(StatusTitle.duration(59 * 60), "59m", "59 min")
        T.equal(StatusTitle.duration(60 * 60), "1h", "60 min → 1h")
        T.equal(StatusTitle.duration(65 * 60), "1h 5m", "65 min")
        T.equal(StatusTitle.duration(23 * 3600 + 59 * 60), "23h 59m", "23 h 59 min")
        T.equal(StatusTitle.duration(24 * 3600), "1d", "24 h → 1d")
        T.equal(StatusTitle.duration(25 * 3600), "1d 1h", "25 h")
        T.equal(StatusTitle.duration(33 * 3600 + 30 * 60), "1d 10h", "33 h 30 min rounds to whole hours past a day")
        T.equal(StatusTitle.duration(-5), "1m", "never zero or negative")
        T.equal(StatusTitle.spokenDuration(60), "1 minute", "spoken singular")
        T.equal(StatusTitle.spokenDuration(12 * 60), "12 minutes", "spoken plural")
        T.equal(StatusTitle.spokenDuration(90 * 60), "1 hour 30 minutes", "spoken hours")
        T.equal(StatusTitle.spokenDuration(48 * 3600), "2 days", "spoken days")
    }

    static func countdowns() {
        T.section("Status title: before, during, after")
        T.equal(title(event(startIn: 7)), "Standup · 7m", "7 minutes before")
        T.equal(title(event(startIn: 60)), "Standup · 1h", "exactly an hour before")
        T.equal(title(event(startIn: 61)), nil, "more than an hour away: icon only")
        T.equal(title(event(startIn: -3, length: 15)), "Standup · 12m left", "during: minutes left")
        T.equal(title(event(startIn: -15, length: 15)), nil, "over: nothing")
        T.equal(title(event(startIn: 0, length: 15)), "Standup · 15m left", "at its start it is on")
        T.equal(title(event(startIn: 5, allDay: true)), nil, "all-day events never count down")
        T.equal(title(nil), nil, "no meeting")
        T.equal(title(event("Offsite", startIn: -60, length: 33 * 60)), "Offsite · 1d 8h left", "a meeting running past 24 h")
        T.equal(title(event("Night shift", startIn: -60, length: 25 * 60)), "Night shift · 1d left", "exactly 24 h left")
        let busy = SnapshotFixtures.events()
        let focus = MeetingFocus.pick(busy, now: now)
        T.equal(focus?.title, "The Comets weekly sync", "the fixture's next meeting at 9:48")
        T.equal(title(focus), "The Comets weekly… · 12m", "fixture: 22-character title cut to 18 with …")
        let tenTen = cal.date(bySettingHour: 10, minute: 10, second: 0, of: now)!
        T.equal(title(MeetingFocus.pick(busy, now: tenTen), at: tenTen), "The Comets weekly… · 35m left", "fixture during")
    }

    static func truncation() {
        T.section("Status title: truncation and clean-up")
        T.equal(StatusTitle.titleLimit, 18, "titles cut at 18 characters")
        let eighteen = "Quarterly planning"   // 18
        T.equal(eighteen.count, 18, "fixture length")
        T.equal(StatusTitle.truncate(eighteen, limit: 18), eighteen, "18 characters fit untouched")
        let cut = StatusTitle.truncate("Quarterly planning!", limit: 18)
        T.equal(cut, "Quarterly plannin…", "19 → 17 + …")
        T.equal(cut.count, 18, "cut title is 18 characters")
        T.equal(StatusTitle.truncate("Design crit with the whole team", limit: 18), "Design crit with…", "trailing space trimmed before …")
        let family = "Family 👨‍👩‍👧‍👦 dinner at Café Nowhere"
        let familyCut = StatusTitle.truncate(family, limit: 18)
        T.check(familyCut.contains("👨‍👩‍👧‍👦"), "a ZWJ emoji family stays whole (grapheme clusters)")
        T.equal(familyCut.count, 18, "emoji count as one character")
        T.equal(StatusTitle.clean("  Stand\n  up\t now "), "Stand up now", "newlines, tabs and runs of spaces collapse")
        T.equal(StatusTitle.clean(""), "Meeting", "empty title says Meeting")
        T.equal(StatusTitle.clean("\u{202E}lanigiro"), "lanigiro", "a right-to-left override can't flip the menu bar")
        T.equal(StatusTitle.clean("A\u{2066}B\u{2069}C\u{200F}"), "ABC", "isolates and marks from the title are dropped")
        T.equal(StatusTitle.clean("👨‍👩‍👧"), "👨‍👩‍👧", "ZWJ is not a control character")
        T.equal(title(event("", startIn: 7)), "Meeting · 7m", "untitled meeting")
    }

    static func rightToLeft() {
        T.section("Status title: right-to-left and mixed titles keep the countdown after the title")
        // The same checks for every right-to-left script: "team meeting" (or "weekly meeting") and the cast's Milo
        // written in that script. The long title repeats the short one until it is well past 18 characters.
        let scripts: [(script: String, title: String, milo: String)] = [
            ("Arabic", "\u{0627}\u{062C}\u{062A}\u{0645}\u{0627}\u{0639} \u{0627}\u{0644}\u{0641}\u{0631}\u{064A}\u{0642}",
             "\u{0645}\u{064A}\u{0644}\u{0648}"),
            ("Hebrew", "\u{05E4}\u{05D2}\u{05D9}\u{05E9}\u{05EA} \u{05E6}\u{05D5}\u{05D5}\u{05EA}", "\u{05DE}\u{05D9}\u{05D9}\u{05DC}\u{05D5}"),
            ("Syriac", "\u{071F}\u{0722}\u{0718}\u{072B}\u{071D}\u{0710} \u{0715}\u{072B}\u{0712}\u{072C}\u{0710}",
             "\u{0721}\u{071D}\u{0720}\u{0718}"),
            ("Thaana", "\u{0780}\u{07A6}\u{078A}\u{07B0}\u{078C}\u{07A7}\u{078E}\u{07AC} \u{0784}\u{07A6}\u{0787}\u{07B0}\u{078B}\u{07A6}\u{078D}\u{07AA}\u{0788}\u{07AA}\u{0782}\u{07B0}",
             "\u{0789}\u{07A6}\u{0787}\u{07A8}\u{078D}\u{07AF}"),
        ]
        for (script, rtl, milo) in scripts {
            T.check(StatusTitle.containsRightToLeft(rtl), "\(script) counts as right-to-left")
            let t = title(event(rtl, startIn: 7)) ?? ""
            T.equal(t, "\u{2068}\(rtl)\u{2069} · 7m", "\(script) title inside a first-strong isolate, then · 7m")
            T.check(t.hasSuffix("\u{2069} · 7m"), "\(script): the digits sit outside the isolate")
            let during = title(event(rtl, startIn: -2, length: 30)) ?? ""
            T.equal(during, "\u{2068}\(rtl)\u{2069} · 28m left", "\(script) during")
            var long = rtl
            while long.count < 30 { long += " " + rtl }
            let cut = title(event(long, startIn: 7)) ?? ""
            let inner = cut.components(separatedBy: "\u{2069}").first?.replacingOccurrences(of: "\u{2068}", with: "") ?? ""
            T.check(inner.count <= 18 && inner.count >= 16, "\(script) titles are cut at 18 characters too (\(inner.count))")
            T.check(inner.hasSuffix("…"), "\(script): the ellipsis at the logical end")
            let mixed = title(event("Sync with \(milo)", startIn: 7)) ?? ""
            T.equal(mixed, "\u{2068}Sync with \(milo)\u{2069} · 7m", "a title ending in \(script) is isolated")
            let spoken = StatusTitle.spoken(mode: .next, focus: event(rtl, startIn: 7), unread: nil, mailEnabled: false, now: now)
            T.equal(spoken, "\(rtl) starts in 7 minutes", "VoiceOver reads the plain \(script) title")
        }
        let leftToRight = ["週次ミーティング", "Συνάντηση ομάδας", "Встреча команды", "टीम मीटिंग", "Standup"]
        for ltr in leftToRight {
            T.equal(title(event(ltr, startIn: 7)), "\(ltr) · 7m", "left-to-right titles get no isolate: \(ltr)")
        }
        T.check(!StatusTitle.containsRightToLeft("Café 🍕"), "Latin + emoji does not")
    }

    static func modes() {
        T.section("Status title: Menu bar shows")
        let e = event(startIn: 7)
        T.equal(StatusTitle.text(mode: .icon, focus: e, unread: 4, mailEnabled: true, now: now), "", "icon only")
        T.equal(StatusTitle.text(mode: .next, focus: e, unread: 4, mailEnabled: true, now: now), "Standup · 7m", "next meeting")
        T.equal(StatusTitle.text(mode: .next, focus: event(startIn: 90), unread: 4, mailEnabled: true, now: now), "", "next, too far: icon only")
        T.equal(StatusTitle.text(mode: .unread, focus: e, unread: 4, mailEnabled: true, now: now), "4", "unread count")
        T.equal(StatusTitle.text(mode: .unread, focus: e, unread: 0, mailEnabled: true, now: now), "", "zero unread: icon only")
        T.equal(StatusTitle.text(mode: .unread, focus: e, unread: 12_000, mailEnabled: true, now: now), "999+", "capped")
        T.equal(StatusTitle.text(mode: .unread, focus: e, unread: 4, mailEnabled: false, now: now), "", "mail off: icon only")
        T.equal(StatusTitle.spoken(mode: .unread, focus: nil, unread: 1, mailEnabled: true, now: now), "1 unread conversation", "spoken unread")
        T.equal(StatusTitle.spoken(mode: .next, focus: event(startIn: -3), unread: nil, mailEnabled: true, now: now),
                "Standup ends in 12 minutes", "spoken during")
    }

    // MARK: Focus

    static func focus() {
        T.section("Menu bar meeting: current, next, hand-over")
        let live = event("Design crit", startIn: -20, length: 60)
        let soon = event("Standup", startIn: 4)
        let later = event("Review", startIn: 25)
        T.equal(MeetingFocus.pick([live, later], now: now)?.title, "Design crit", "in progress beats one 25 min away")
        T.equal(MeetingFocus.pick([live, soon, later], now: now)?.title, "Standup", "one starting within 5 min takes over")
        T.equal(MeetingFocus.pick([later], now: now)?.title, "Review", "nothing on: the next one")
        T.equal(MeetingFocus.pick([event("Gone", startIn: -30, length: 10)], now: now)?.title, nil, "ended meetings don't count")
        T.equal(MeetingFocus.pick([event("All day", startIn: -60, length: 24 * 60, allDay: true), later], now: now)?.title, "Review",
                "all-day events never count")
        T.equal(MeetingFocus.pick([event("No", startIn: 3, reply: .declined), later], now: now)?.title, "Review", "declined meetings skipped")
        T.equal(MeetingFocus.pick([event("Zero", startIn: 2, length: 0), later], now: now)?.title, "Review", "zero-length skipped")
        let older = event("Long block", startIn: -120, length: 240)
        let newer = event("Ad hoc", startIn: -10, length: 30)
        T.equal(MeetingFocus.current([older, newer], now: now)?.title, "Ad hoc", "overlapping: the one that started last")
        T.check(MeetingFocus.isSoon(event(startIn: 30), now: now), "30 min ahead is soon")
        T.check(!MeetingFocus.isSoon(event(startIn: 31), now: now), "31 min ahead is not")
    }

    static func hotkey() {
        T.section("⌃⌥J: join or open the popover")
        func decide(_ events: [CalendarEvent]) -> HotkeyDecision { HotkeyDecision.decide(events, now: now) }
        let live = event("Design crit", startIn: -5, length: 30, join: "https://meet.google.com/abc-defg-hij")
        T.equal(decide([live]), .join(r: live.r, url: live.joinURL!), "the meeting on now")
        let soon = event("Standup", startIn: 20, join: "https://us02web.zoom.us/j/812345")
        T.equal(decide([soon]), .join(r: soon.r, url: soon.joinURL!), "the next one within 30 min")
        T.equal(decide([event(startIn: 31)]), .openPopover, "31 min away: the popover instead")
        T.equal(decide([]), .openPopover, "nothing at all: the popover")
        T.equal(decide([event(startIn: 5, join: "http://meet.google.com/abc")]), .openPopover, "plain http never joins")
        T.equal(decide([event(startIn: 5, join: "https://meet.google.com.evil.example/abc")]), .openPopover, "look-alike hosts never join")
        T.equal(decide([event(startIn: 5, join: "https://user!@meet.google.com/abc")]), .openPopover, "credentials in the link never join")
        T.equal(decide([event(startIn: 5, join: nil)]), .openPopover, "no link: the popover")
        T.equal(decide([event(startIn: 5, reply: .declined)]), .openPopover, "declined meetings are not joined")
        let roomOnly = event("In the room", startIn: -10, length: 60, join: nil)
        let callSoon = event("Call", startIn: 12, join: "https://teams.microsoft.com/l/meetup-join/x")
        T.equal(decide([roomOnly, callSoon]), .join(r: callSoon.r, url: callSoon.joinURL!),
                "the meeting on now has no link: the call starting soon")
        let liveCall = event("Live call", startIn: -30, length: 60, join: "https://meet.google.com/abc-defg-hij")
        let roomSoon = event("Room", startIn: 3, join: nil)
        T.equal(decide([liveCall, roomSoon]), .join(r: liveCall.r, url: liveCall.joinURL!),
                "the menu bar's meeting has no link: the live call")
        T.equal(JoinHotkey.keyCode, 0x26, "J's virtual key code")
        T.equal(JoinHotkey.display, "⌃⌥J", "shown as ⌃⌥J")
    }

    // MARK: Preferences

    static func pause() {
        T.section("Pause notifications for 1 hour")
        let bag = MemoryBag()
        T.equal(NotificationPause.pausedUntil(now: now, bag), nil, "not paused at first")
        NotificationPause.pause(now: now, bag)
        T.equal(NotificationPause.pausedUntil(now: now, bag), now.addingTimeInterval(3600), "paused for an hour")
        T.check(bag.object(NotificationPause.key) is Date, "stored as a Date under notifications.pausedUntil")
        T.equal(NotificationPause.key, "notifications.pausedUntil", "the key the heads-up notifier reads")
        T.equal(NotificationPause.pausedUntil(now: now.addingTimeInterval(3601), bag), nil, "over after the hour")
        NotificationPause.resume(bag)
        T.equal(bag.object(NotificationPause.key) == nil, true, "resume removes the key")
    }

    static func prefs() {
        T.section("Menu bar preferences")
        let bag = MemoryBag()
        T.equal(MenuBarPrefs.mode(bag), .next, "default: next meeting")
        T.equal(MenuBarPrefs.hotkeyEnabled(bag), true, "default: ⌃⌥J on")
        MenuBarPrefs.setMode(.unread, bag)
        T.equal(MenuBarPrefs.mode(bag), .unread, "mode saved")
        bag.set("bogus", MenuBarPrefs.modeKey)
        T.equal(MenuBarPrefs.mode(bag), .next, "unknown value: default")
        MenuBarPrefs.setHotkeyEnabled(false, bag)
        T.equal(MenuBarPrefs.hotkeyEnabled(bag), false, "hotkey off saved")
        T.equal(MenuBarMode.allCases.map(\.title), ["Icon only", "Next meeting", "Unread count"], "picker words")
    }

    static func settingsModel() {
        T.section("Settings → Menu bar")
        var posts = 0
        var state = HotkeyState.on
        var mail = false
        let bag = MemoryBag([MenuBarPrefs.modeKey: "unread"])
        let m = MenuBarSettingsModel(bag: bag, mailEnabled: { mail }, state: { state }, post: { posts += 1 })
        T.equal(m.modes, [.icon, .next], "no unread choice while mail is off")
        T.equal(m.shownMode, .icon, "a stored unread choice reads as icon only without mail")
        m.setMode(.unread)
        T.equal(posts, 0, "an unavailable choice is refused")
        mail = true
        T.equal(m.modes, MenuBarMode.allCases, "with mail: all three")
        m.setMode(.next)
        T.equal(posts, 1, "a change posts once")
        T.equal(MenuBarPrefs.mode(bag), .next, "and is saved")
        m.setMode(.next)
        T.equal(posts, 1, "the same choice again posts nothing")
        state = .taken
        m.setHotkey(true)
        T.equal(m.hotkeyState, .taken, "state read right after the post")
        T.check(m.hotkeyNeedsAttention, "taken needs attention")
        T.check(m.hotkeyDetail.contains("Another app"), "and says why")
        state = .pausedForVoiceOver
        m.setHotkey(true)
        T.check(m.hotkeyDetail.contains("VoiceOver"), "paused for VoiceOver says so")
        m.setHotkey(false)
        T.equal(MenuBarPrefs.hotkeyEnabled(bag), false, "off saved")
        T.check(m.hotkeyDetail.hasPrefix("Off."), "off says so")
        T.check(!m.hotkeyNeedsAttention, "off needs no attention")
    }

    // MARK: Popover

    static func popoverModel(events: [CalendarEvent] = SnapshotFixtures.events(), at time: Date = now, mail: Bool = true,
                             directory: AccountDirectory = FixtureAccounts.directory(), store: FakeCalendarStore? = nil,
                             mailStore: FakeMailStore = FakeMailStore(), clock24: Bool = false,
                             synced: Date? = nil) -> PopoverModel {
        let calendar = store ?? FakeCalendarStore(events: events)
        return PopoverModel(store: { calendar }, actions: { calendar }, mail: { mailStore }, directory: { directory },
                            clock: { time }, mailEnabled: { mail }, syncedAt: { synced }, use24Hour: { clock24 })
    }

    static func popover() {
        T.section("Popover: agenda and the next-meeting card")
        let m = popoverModel(synced: now.addingTimeInterval(-3 * 60))
        m.load()
        T.equal(m.phase, .ready, "ready")
        T.equal(m.card?.event.title, "The Comets weekly sync", "card: the next meeting")
        T.equal(m.card?.soon, true, "12 min away: highlighted")
        T.equal(m.card?.live, false, "not live yet")
        T.equal(m.card?.canJoin, true, "allowlisted link: Join")
        T.equal(m.card?.joinTitle, "Join Zoom", "named by provider")
        T.equal(m.card?.when, "Today · 10 – 10:45 AM", "when, in the widget's clock style")
        T.equal(m.card?.countdown, "Starts in 12 min", "headless countdown words")
        T.equal(m.days.first.map { DayName.title($0.day, now: now) }, "Today", "today first")
        T.check(!(m.days.first?.events.contains { $0.title == "Team stand-up" && $0.end <= now } ?? true), "the 9:30 stand-up that ended is gone")
        T.equal(m.days.count, 5, "a week ahead: Mon–Fri have meetings; Monday 26 is past the 7-day horizon")
        T.equal(m.syncedText, "Synced 3 min ago", "footer")
        T.equal(m.tab, .agenda, "Agenda first")

        let tenTen = cal.date(bySettingHour: 10, minute: 10, second: 0, of: now)!
        let live = popoverModel(at: tenTen)
        live.load()
        T.equal(live.card?.live, true, "10:10: live")
        T.equal(live.card?.countdown, "Ends in 35 min", "live countdown")
        let h24 = popoverModel(clock24: true)
        h24.load()
        T.equal(h24.card?.when, "Today · 10:00 – 10:45", "24-hour clock (from the Agenda widget's setting)")

        T.section("Popover: account chips")
        m.toggle(FixtureAccounts.cmt)
        T.equal(m.filter, [FixtureAccounts.cmt], "CMT only")
        T.check(m.days.allSatisfy { $0.events.allSatisfy { $0.accountIds.contains(FixtureAccounts.cmt) } }, "only CMT's meetings")
        T.check(m.card.map { $0.event.accountIds.contains(FixtureAccounts.cmt) } ?? false, "the card follows the chips")
        T.check(m.isOn(FixtureAccounts.cmt) && !m.isOn(FixtureAccounts.orb), "chip states")
        for account in m.chipAccounts where account.id != FixtureAccounts.cmt { m.toggle(account.id) }
        T.equal(m.filter, [], "every chip on = All")
        m.toggle(FixtureAccounts.orb); m.showAll()
        T.equal(m.filter, [], "All resets")

        T.section("Popover: states")
        let none = popoverModel(directory: AccountDirectory(accounts: []))
        none.load()
        T.equal(none.phase, .noAccounts, "no accounts")
        T.equal(none.card, nil, "no card")
        T.equal(none.syncedText, "No accounts yet", "footer without accounts")
        let empty = popoverModel(events: [])
        empty.load()
        T.equal(empty.phase, .ready, "empty week is ready")
        T.equal(empty.days.count, 0, "nothing listed")
        T.equal(empty.card, nil, "no card")
        T.equal(empty.syncedText, "Not synced yet", "never synced")
        let failing = FakeCalendarStore()
        failing.loadError = ServiceError(description: "offline")
        let failed = popoverModel(store: failing)
        failed.load()
        T.equal(failed.phase, .failed, "store error: failed")
        let wednesday = event("Far", startIn: 2 * 24 * 60 + 60)
        let far = popoverModel(events: [wednesday])
        far.load()
        T.equal(far.card?.countdown, "Starts Wednesday", "more than a day away: the day")
        T.equal(far.card?.soon, false, "not highlighted")
        let tomorrow = popoverModel(events: [event("Early", startIn: 24 * 60 - 30)])
        tomorrow.load()
        T.equal(tomorrow.card?.countdown, "Starts in 23 h 30 min", "under a day: hours and minutes")
    }

    static func popoverMail() {
        T.section("Popover: Inbox tab")
        let store = FakeMailStore()
        var mail = true
        let calendar = FakeCalendarStore()
        let directory = FixtureAccounts.directory()
        let m = PopoverModel(store: { calendar }, actions: { calendar }, mail: { store }, directory: { directory },
                             clock: { now }, mailEnabled: { mail }, syncedAt: { nil }, use24Hour: { false })
        m.load()
        m.select(.inbox)
        T.equal(m.tab, .inbox, "Inbox tab with mail on")
        T.equal(m.threads.count, 14, "the sample inbox")
        T.equal(m.unread, FixtureMail.unread, "unread count for the tab label")
        T.equal(m.threads.first?.sender, "Milo Brightwater", "newest first")
        m.toggle(FixtureAccounts.cmt)
        T.check(m.threads.allSatisfy { $0.accountId == FixtureAccounts.cmt }, "chips filter the inbox too")
        m.showAll()
        mail = false
        m.load()
        T.equal(m.tab, .agenda, "mail switched off: back to Agenda")
        m.select(.inbox)
        T.equal(m.tab, .agenda, "Inbox can't be picked while mail is off")
        T.equal(m.showsInbox, false, "no Inbox tab")
        mail = true
        let zero = PopoverModel(store: { calendar }, actions: { calendar }, mail: { FakeMailStore(threads: []) },
                                directory: { directory }, clock: { now }, mailEnabled: { true }, syncedAt: { nil }, use24Hour: { false })
        zero.load()
        T.equal(zero.mailPhase, .ready, "inbox zero is ready")
        T.equal(zero.threads.count, 0, "and empty")
        var noMail = FixtureAccounts.directory()
        for i in noMail.accounts.indices { noMail.accounts[i].mailEnabled = false }
        let off = PopoverModel(store: { calendar }, actions: { calendar }, mail: { store }, directory: { noMail },
                               clock: { now }, mailEnabled: { true }, syncedAt: { nil }, use24Hour: { false })
        off.load()
        T.equal(off.mailPhase, .noAccounts, "no account has mail on")
        off.select(.inbox)
        T.equal(off.chipAccounts.count, 0, "no mail chips")
    }

    static func placement() {
        T.section("Popover placement")
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let size = CGSize(width: 380, height: 560)
        let button = CGRect(x: 1200, y: 1000, width: 30, height: 24)
        let f = PopoverPlacement.frame(size: size, anchor: button, visible: visible)
        T.equal(f.midX, button.midX, "centred under the status item")
        T.equal(f.maxY, button.minY - PopoverPlacement.gap, "just below the menu bar")
        T.equal(f.size, size, "380 × 560")
        let edge = PopoverPlacement.frame(size: size, anchor: CGRect(x: 1578, y: 1000, width: 22, height: 24), visible: visible)
        T.equal(edge.maxX, visible.maxX - PopoverPlacement.margin, "clamped to the right edge")
        let none = PopoverPlacement.frame(size: size, anchor: nil, visible: visible)
        T.equal(none.maxX, visible.maxX - 8, "no status item: top right")
        T.equal(none.maxY, visible.maxY - 8, "… under the menu bar")
        let small = PopoverPlacement.frame(size: size, anchor: button, visible: CGRect(x: 0, y: 0, width: 1600, height: 500))
        T.check(small.height <= 484 && small.minY >= 8, "a short screen shrinks it inside the visible frame")

        let anchor = PopoverPlacement.peekAnchor(popover: f, pointer: CGPoint(x: f.midX, y: f.maxY - 200), visible: visible)
        let peek = PeekPlacement.frame(size: CGSize(width: 420, height: 400), anchor: anchor, visible: visible)
        T.equal(peek.maxX, f.minX - PopoverPlacement.margin, "the Peek sits left of the popover")
        T.check(peek.maxY <= f.maxY && peek.maxY >= f.maxY - 200, "level with the row clicked")
        let leftPopover = CGRect(x: 20, y: 380, width: 380, height: 560)
        let a2 = PopoverPlacement.peekAnchor(popover: leftPopover, pointer: CGPoint(x: 100, y: 800), visible: visible)
        let p2 = PeekPlacement.frame(size: CGSize(width: 420, height: 400), anchor: a2, visible: visible)
        T.equal(p2.minX, leftPopover.maxX + PopoverPlacement.margin, "no room on the left: it sits on the right")
        T.check(!p2.intersects(leftPopover), "never over the popover")
    }

    // MARK: Welcome guide

    static func onboarding() {
        T.section("Welcome guide: steps, resume, advance")
        var f = OnboardingFacts()
        T.equal(OnboardingFlow.resume(f, stored: nil), .google, "fresh: step 1")
        T.equal(OnboardingFlow.isAvailable(.accounts, f), false, "accounts wait for Google sign-in")
        T.equal(OnboardingFlow.resume(f, stored: OnboardingStep.accounts.rawValue), .google, "a stored step that can't be done yet is skipped")
        T.equal(OnboardingFlow.resume(f, stored: OnboardingStep.notifications.rawValue), .notifications, "a stored open step resumes")
        T.equal(OnboardingFlow.progress(f), "0 of 6 done", "progress")
        f.googleReady = true
        T.equal(OnboardingFlow.advance(from: .google, f), .accounts, "Google done → accounts")
        f.accounts = 2
        T.equal(OnboardingFlow.advance(from: .accounts, f), .looks, "accounts done → logos")
        T.equal(OnboardingFlow.advance(from: .looks, f), .looks, "an open step stays")
        f.looksConfirmed = true
        f.notifications = "denied"
        T.equal(OnboardingFlow.advance(from: .looks, f), .widget, "skips what's already done")
        T.equal(OnboardingFlow.resume(f, stored: OnboardingStep.google.rawValue), .widget, "a stored step that's done resumes at the first open one")
        T.equal(OnboardingFlow.isDone(.notifications, f), true, "a denied answer still counts as answered")
        T.equal(OnboardingFlow.progress(f), "4 of 6 done", "progress")
        f.widgetPlaced = true
        T.equal(OnboardingFlow.firstOpen(f), .running, "Keep me running is left")
        T.equal(OnboardingFlow.progress(f), "5 of 6 done", "progress")
        f.runningSettled = true
        T.equal(OnboardingFlow.firstOpen(f), nil, "all done")
        T.equal(OnboardingFlow.progress(f), "All set", "all set")
        T.equal(OnboardingFlow.resume(f, stored: nil), .running, "all done: the last step")
        T.equal(OnboardingStep.allCases.map(\.rawValue), [1, 2, 3, 4, 5, 6], "six numbered steps")
        T.equal(OnboardingFlow.countWord, "Six", "the subtitle counts them")
        T.check(OnboardingStep.allCases.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty }, "every step has words")
    }

    // MARK: VoiceOver

    static func accessibility() {
        T.section("VoiceOver words")
        let dir = FixtureAccounts.directory()
        let hub = SnapshotFixtures.events().first { $0.title == "The Comets weekly sync" }!
        let row = A11yText.meeting(hub.widgetMeeting(index: 1, directory: dir), now: now)
        T.equal(row.label, "The Comets weekly sync, CMT", "meeting label: title and account")
        T.check(row.value.hasPrefix("Today, 10 to 10:45 AM"), "meeting value: day and time (\(row.value))")
        T.check(row.value.contains("starts in 12 minutes"), "… and the countdown")
        T.check(row.value.contains("video link"), "… and that it has a call")
        let merged = SnapshotFixtures.events().first { $0.accountIds.count > 1 }!
        T.check(A11yText.meeting(merged.widgetMeeting(index: 1, directory: dir), now: now).label.hasSuffix("ORB and CMT"), "merged invite names both")
        let thread = FixtureMail.threads(now: now).first!.thread
        let t = A11yText.thread(thread, account: dir.account(thread.accountId), now: now)
        T.check(t.label.hasPrefix(thread.unread ? "Unread, " : thread.sender), "thread label leads with unread")
        T.check(t.label.contains(thread.subject), "and the subject")
        T.equal(A11yText.plainHelp("Mark read (U)"), "Mark read", "shortcut hints dropped")
        T.equal(A11yText.plainHelp("Move to Trash (#)"), "Move to Trash", "symbol hints dropped")
        T.equal(A11yText.plainHelp("Reply in a new window"), "Reply in a new window", "plain help kept")
        T.equal(A11yText.plainHelp("Archive (sends it to All Mail)"), "Archive (sends it to All Mail)", "long parentheses kept")
        let m = popoverModel()
        m.load()
        if let card = m.card {
            let c = A11yText.card(card)
            T.equal(c.label, "Next meeting: The Comets weekly sync", "card label")
            T.equal(c.value, "Today, 10 to 10:45 AM, starts in 12 min", "card value")
        } else {
            T.check(false, "card present")
        }
        T.equal(A11yText.chip("CMT", on: true).value, "shown", "chip on")
    }
}
