import AppKit
import Foundation

/// Widget Studio (settings round trip with fakes), the Calendar section model, the Peek models and
/// placement. Fakes only: no Keychain, network or Application Support.
@MainActor
enum SurfaceTests {
    static let cal = WidgetCalendar.fixed
    static let now = WidgetSample.fixedNow

    static func run() async {
        studio()
        studioPreview()
        calendarSection()
        await calendarSync()
        placement()
        await eventPeek()
        dayPeek()
    }

    static func studio() {
        T.section("Studio: settings round trip")
        let store = FakeWidgetSettingsStore()
        var mailOn = false
        let m = WidgetStudioModel(kind: "agenda.all", store: { store }, mailEnabled: { mailOn })
        T.equal(m.draft, WidgetSettings(kind: "agenda.all"), "loads the stored (default) settings")
        T.equal(m.isDirty, false, "clean at first")
        m.setLook(.ink); m.setFont("rounded"); m.setTextSize("large"); m.setShowLogos(false); m.setUse24Hour(true); m.setRange(2)
        T.equal(m.isDirty, true, "edits make it dirty")
        T.equal(m.save(), true, "save")
        T.equal(store.saves.count, 1, "one save through Services.widgetSettings")
        let saved = store.settings(kind: "agenda.all")
        T.equal(saved.style, WidgetSnapshot.Style(look: .ink, typeface: "rounded", textSize: "large", showLogos: false, use24Hour: true), "style saved")
        T.equal(saved.rangeDays, 2, "range saved")
        T.equal(m.status, .saved, "says Saved")
        T.equal(m.isDirty, false, "clean after save")
        m.select("month")
        T.equal(m.draft, WidgetSettings(kind: "month"), "another kind loads its own settings")
        T.equal(m.status, .idle, "status resets on select")
        m.select("agenda.all")
        T.equal(m.draft, saved, "coming back loads what was saved (round trip)")
        m.setName("Nope")
        T.equal(m.draft.title, nil, "named kinds have no name")
        m.setLook(.paper); m.revert()
        T.equal(m.draft, saved, "undo changes")

        T.section("Studio: custom slots")
        m.select("custom.a")
        T.equal(m.isCustom, true, "custom.a is custom")
        T.equal(m.effectiveContent, nil, "not set up yet")
        m.setName("  Work  ")
        m.setContent(.inbox)
        T.equal(m.draft.customContent, nil, "Inbox greyed while mail is off")
        T.equal(m.isAvailable(.combo), false, "Agenda & Inbox greyed too")
        m.setContent(.month)
        T.equal(m.draft.customContent, .month, "Month allowed")
        m.setContent(.setup)
        T.equal(m.draft.customContent, .month, "setup is not a choice")
        T.equal(m.showsRange, false, "no range for Month")
        m.setContent(.agenda)
        T.equal(m.showsRange, true, "range for Agenda")
        let all = FixtureAccounts.all.map(\.id)
        m.pickOnly(all)
        T.equal(m.draft.accountIds, all, "pick: starts from every account")
        m.toggleAccount(FixtureAccounts.cmt, all: all)
        m.toggleAccount(FixtureAccounts.home, all: all)
        T.equal(m.draft.accountIds, [FixtureAccounts.orb, FixtureAccounts.fam], "unticked two")
        m.toggleAccount(FixtureAccounts.orb, all: all)
        m.toggleAccount(FixtureAccounts.fam, all: all)
        T.equal(m.draft.accountIds, [FixtureAccounts.fam], "the last account can't be unticked")
        m.toggleAccount(FixtureAccounts.orb, all: all)
        T.equal(m.draft.accountIds, [FixtureAccounts.orb, FixtureAccounts.fam], "re-ticked in the accounts' order")
        T.equal(m.save(), true, "save custom")
        let custom = store.settings(kind: "custom.a")
        T.equal(custom.title, "Work", "name trimmed on save")
        T.equal(custom.customContent, .agenda, "content saved")
        T.equal(custom.accountIds, [FixtureAccounts.orb, FixtureAccounts.fam], "accounts saved")
        T.equal(m.listName(WidgetKinds.custom[0]), "Custom A · Work", "list shows the name")
        T.equal(m.listName(WidgetKinds.custom[1]), "Custom Widget B", "unnamed slot keeps its gallery name")
        m.setAllAccounts()
        T.equal(m.draft.accountIds, nil, "All accounts (includes new ones) = nil")
        m.setName(String(repeating: "x", count: 40))
        T.equal(m.draft.title?.count, WidgetStudioModel.maxNameLength, "name capped")
        m.revert()
        mailOn = true
        m.setContent(.inbox)
        T.equal(m.draft.customContent, .inbox, "with mail on, Inbox is a choice")
        mailOn = false
        m.save()
        T.equal(store.settings(kind: "custom.a").customContent, nil, "a mail choice saved after mail went off again is dropped")

        T.section("Studio: save failure, reload")
        store.saveError = ServiceError(description: "disk full")
        m.select("upnext")
        m.setUse24Hour(true)
        T.equal(m.save(), false, "save fails")
        if case .failed = m.status { T.check(true, "") } else { T.check(false, "status says it failed") }
        T.equal(m.isDirty, true, "changes kept after a failed save")
        store.saveError = nil
        m.reload()
        T.equal(m.draft.style.use24Hour, true, "reload keeps unsaved changes")
        m.revert()
        try? store.save(WidgetSettings(kind: "upnext", style: WidgetSnapshot.Style(look: .paper)))
        m.reload()
        T.equal(m.draft.style.look, .paper, "reload picks up settings saved elsewhere")
        T.equal(m.families, [.small, .medium], "Up Next previews its own sizes")
        T.check(m.families.contains(m.previewFamily), "preview family valid for the kind")
    }

    static func studioPreview() {
        T.section("Studio: live preview data")
        let store = FakeWidgetSettingsStore()
        let saveDirectory = AccountDirectory.current
        AccountDirectory.current = { AccountDirectory(accounts: []) }
        defer { AccountDirectory.current = saveDirectory }
        let m = WidgetStudioModel(kind: "custom.b", store: { store }, mailEnabled: { false })
        T.equal(m.preview(now: now, dark: false, calendar: cal).0.state, .setup, "custom not set up → setup card")
        m.setContent(.month); m.setName("Plans"); m.setLook(.auto)
        let (month, light) = m.preview(now: now, dark: false, calendar: cal)
        T.equal(month.content, .month, "custom → month")
        T.equal(month.title, "Plans", "name shows in the preview")
        T.equal(light.look, .paper, "Match Mac on a light Mac → Light")
        T.equal(m.preview(now: now, dark: true, calendar: cal).1.look, .ink, "Match Mac on a dark Mac → Dark")
        let inbox = WidgetStudioModel(kind: "inbox.all", store: { store }, mailEnabled: { false })
        T.equal(inbox.preview(now: now, dark: false, calendar: cal).0.state, .mailComingSoon, "Inbox kind with mail off → coming soon")
        let agenda = WidgetStudioModel(kind: "agenda.all", store: { store }, mailEnabled: { false })
        agenda.setRange(1); agenda.setTextSize("large")
        let (data, style) = agenda.preview(now: now, dark: false, calendar: cal)
        T.check(data.agendaMeetings.allSatisfy { cal.isDate($0.start, inSameDayAs: now) }, "range Today in the preview")
        T.equal(style.textSize, .large, "text size in the preview")

        AccountDirectory.current = { FixtureAccounts.directory() }
        let picked = WidgetStudioModel(kind: "custom.a", store: { store }, mailEnabled: { false })
        picked.setContent(.agenda)
        picked.pickOnly(FixtureAccounts.all.map(\.id))
        picked.toggleAccount(FixtureAccounts.orb, all: FixtureAccounts.all.map(\.id))
        let shown = picked.preview(now: now, dark: false, calendar: cal).0.meetings
        T.check(!shown.isEmpty && shown.allSatisfy { !$0.accountIds.contains(FixtureAccounts.orb.uuidString) || $0.isMerged },
                "unticked accounts leave the preview")
    }

    static func calendarSection() {
        T.section("Calendar section: agenda today → +60 days")
        let store = FakeCalendarStore()
        let m = CalendarSectionModel(store: { store }, actions: { store }, directory: { FixtureAccounts.directory() }, clock: { now })
        T.equal(m.phase, .loading, "loading before the first read")
        m.load()
        T.equal(m.phase, .ready, "ready")
        T.equal(m.days.first?.day, cal.startOfDay(for: now), "starts today")
        T.equal(m.eventCount, store.allEvents.count, "every fixture event in range")
        T.check(zip(m.days, m.days.dropFirst()).allSatisfy { $0.day < $1.day }, "days in order")
        let wednesday = m.days.first { cal.isDate($0.day, inSameDayAs: cal.date(byAdding: .day, value: 2, to: now)!) }
        T.equal(wednesday?.events.first?.title, "Family day out", "all-day first in its day")
        T.equal(m.accounts.map(\.tag), ["ORB", "CMT", "FAM", "Personal"], "chips in the user's order")

        m.toggle(FixtureAccounts.cmt)
        T.equal(m.filter, [FixtureAccounts.cmt], "filter CMT")
        T.check(m.days.allSatisfy { $0.events.allSatisfy { $0.accountIds.contains(FixtureAccounts.cmt) } }, "only CMT meetings")
        T.check(m.days.contains { $0.events.contains { $0.r == "grp-jingle" } }, "merged invite shows under CMT too")
        T.equal(m.isShown(FixtureAccounts.cmt), true, "CMT shown")
        T.equal(m.isShown(FixtureAccounts.orb), false, "ORB hidden")
        for id in [FixtureAccounts.orb, FixtureAccounts.fam, FixtureAccounts.home] { m.toggle(id) }
        T.equal(m.filter, [], "every chip on = All")
        m.toggle(FixtureAccounts.orb); m.showAll()
        T.equal(m.filter, [], "All resets the filter")

        let none = CalendarSectionModel(store: { store }, actions: { store }, directory: { AccountDirectory(accounts: []) }, clock: { now })
        none.load()
        T.equal(none.phase, .noAccounts, "no accounts")
        var off = FixtureAccounts.directory()
        for i in off.accounts.indices { off.accounts[i].calendarEnabled = false }
        let disabled = CalendarSectionModel(store: { store }, actions: { store }, directory: { off }, clock: { now })
        disabled.load()
        T.equal(disabled.phase, .noAccounts, "calendar off on every account = no accounts")
        let broken = FakeCalendarStore(); broken.loadError = ServiceError(description: "db")
        let failing = CalendarSectionModel(store: { broken }, actions: { broken }, directory: { FixtureAccounts.directory() }, clock: { now })
        failing.load()
        T.equal(failing.phase, .failed, "store error → friendly failure")
        let empty = FakeCalendarStore(events: [])
        let quiet = CalendarSectionModel(store: { empty }, actions: { empty }, directory: { FixtureAccounts.directory() }, clock: { now })
        quiet.load()
        T.equal(quiet.phase, .ready, "empty calendar is ready")
        T.equal(quiet.days, [], "…with no days")
    }

    static func calendarSync() async {
        T.section("Calendar section: Sync now")
        let store = FakeCalendarStore()
        let m = CalendarSectionModel(store: { store }, actions: { store }, directory: { FixtureAccounts.directory() }, clock: { now })
        await m.syncNow()
        T.equal(store.syncs, 1, "Sync now calls CalendarActions.syncNow")
        T.equal(m.phase, .ready, "and reloads")
        T.equal(m.syncing, false, "done syncing")
    }

    static func placement() {
        T.section("Peek placement: at the pointer, clamped to the screen")
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)     // a screen's visible frame
        let size = CGSize(width: 420, height: 500)
        let middle = PeekPlacement.frame(size: size, anchor: CGPoint(x: 600, y: 700), visible: screen)
        T.equal(middle, CGRect(x: 610, y: 190, width: 420, height: 500), "right of and below the pointer")
        let right = PeekPlacement.frame(size: size, anchor: CGPoint(x: 1400, y: 700), visible: screen)
        T.equal(right.maxX, 1390, "flips to the left near the right edge")
        let low = PeekPlacement.frame(size: size, anchor: CGPoint(x: 600, y: 200), visible: screen)
        T.check(low.minY >= screen.minY + 8 && low.maxY <= screen.maxY - 8, "near the bottom: still fully on screen")
        let tall = PeekPlacement.frame(size: CGSize(width: 420, height: 2000), anchor: CGPoint(x: 600, y: 900), visible: screen)
        T.equal(tall.height, 560, "never taller than 560")
        let small = CGRect(x: 0, y: 0, width: 800, height: 400)
        let squeezed = PeekPlacement.frame(size: size, anchor: CGPoint(x: 400, y: 200), visible: small)
        T.check(small.insetBy(dx: 7.9, dy: 7.9).contains(squeezed), "a small screen squeezes it inside")
        let second = CGRect(x: 1600, y: -200, width: 1920, height: 1080)
        let other = PeekPlacement.frame(size: size, anchor: CGPoint(x: 2000, y: 600), visible: second)
        T.check(second.contains(other), "second screen: stays on that screen")
        let outside = PeekPlacement.frame(size: size, anchor: CGPoint(x: -50, y: 2000), visible: screen)
        T.check(screen.contains(outside), "an off-screen pointer still lands on screen")
    }

    static func eventPeek() async {
        T.section("Event Peek: content")
        let directory = FixtureAccounts.directory()
        let events = SnapshotFixtures.events()
        func event(_ title: String) -> CalendarEvent { events.first { $0.title == title }! }
        let store = FakeCalendarStore()
        var opened: [URL] = []
        var closed = 0
        func model(_ e: CalendarEvent) -> EventPeekModel {
            let m = EventPeekModel(event: e, directory: directory, actions: store, open: { opened.append($0); return true })
            m.onClose = { closed += 1 }
            return m
        }
        let merged = model(event("Pickle × Comets jingle weekly"))
        T.equal(merged.alsoOn, "Also on: CMT", "merged invite says Also on: CMT")
        T.equal(merged.guests.count, 12, "12 guests")
        T.equal(merged.guestsShown.count, 8, "first 8 shown")
        T.equal(merged.moreGuests, 4, "and 4 more")
        T.equal(merged.canReply, true, "an invitation can be answered")
        T.equal(merged.joinProvider, "Google Meet", "Join names the provider")
        T.equal(PeekText.when(merged.event), "Monday 19 October · 2 – 3 PM", "time line")
        T.equal(PeekText.when(event("Family day out")), "Wednesday 21 October · All day", "all-day line")
        let lunch = model(event("Lunch with Rafa"))
        T.equal(lunch.canReply, false, "your own event: no Yes/Maybe/No")
        T.equal(lunch.canJoin, false, "no link, no Join")
        T.equal(lunch.alsoOn, nil, "single account: no Also on")
        T.equal(PeekText.notesPreview("a\n\nb\nc\nd\ne\nf\ng"), "a\nb\nc\nd\ne\nf\n…", "notes: first six lines")
        T.equal(PeekText.notesPreview("  \n "), nil, "blank notes hidden")
        T.equal(PeekText.responseWord(.needsAction), "Not answered yet", "response words")

        T.section("Event Peek: RSVP (optimistic, reverts on error)")
        let reply = model(event("Album artwork walkthrough"))
        T.equal(reply.response, .needsAction, "starts unanswered")
        await reply.rsvp(.accepted)
        T.equal(reply.response, .accepted, "Yes sticks")
        T.equal(store.rsvps.last?.r, reply.event.r, "RSVP sent for this row")
        T.equal(store.rsvps.last?.response, .accepted, "…as accepted")
        T.equal(reply.toast, nil, "no toast on success")
        await reply.rsvp(.accepted)
        T.equal(store.rsvps.count, 1, "the same answer twice sends once")
        store.rsvpError = ServiceError(description: "offline")
        await reply.rsvp(.declined)
        T.equal(reply.response, .accepted, "failure reverts to the last answer")
        T.check(reply.toast?.contains("couldn\u{2019}t send") == true, "failure shows a friendly toast")
        T.equal(reply.sending, nil, "not stuck sending")
        store.rsvpError = nil
        await lunch.rsvp(.declined)
        T.equal(lunch.response, .accepted, "no RSVP on your own event")

        T.section("Event Peek: Join + Open in Google Calendar")
        T.equal(merged.join(), true, "Join opens the allowlisted link")
        T.equal(opened.last?.host, "meet.google.com", "…the meeting's own link")
        T.equal(closed, 1, "and closes the Peek")
        var bad = event("The Comets weekly sync")
        bad.joinURL = URL(string: "http://us02web.zoom.us/j/1")
        let blocked = model(bad)
        T.equal(blocked.join(), false, "an http link is refused")
        T.check(blocked.toast != nil, "…with a toast")
        T.equal(opened.count, 1, "…and nothing opened")
        T.equal(merged.openInGoogle(), true, "Open in Google Calendar")
        T.equal(opened.last?.host, "calendar.google.com", "…opens the event's page")
    }

    static func dayPeek() {
        T.section("Day Peek")
        let store = FakeCalendarStore()
        let settings = FakeWidgetSettingsStore()
        let tuesday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let day = DayPeekModel(kind: "month", day: tuesday, directory: FixtureAccounts.directory(), store: store, settings: settings, now: now)
        T.equal(day.events.map(\.title), ["Team stand-up", "Mix notes with Milo", "Kickoff · Garden project", "Design crit", "Dentist"],
                "Tuesday's meetings in order")
        T.equal(day.title, "Tuesday", "title")
        T.equal(day.countText, "5 meetings", "count")
        T.equal(day.rows().first?.r, day.events.first?.r, "rows keep r (they open the Event Peek)")
        try? settings.save(WidgetSettings(kind: "custom.d", accountIds: [FixtureAccounts.cmt]))
        let cmt = DayPeekModel(kind: "custom.d", day: tuesday, directory: FixtureAccounts.directory(), store: store, settings: settings, now: now)
        T.equal(cmt.events.map(\.title), ["Mix notes with Milo"], "a widget's own accounts only")
        let saturday = cal.date(byAdding: .day, value: 5, to: cal.startOfDay(for: now))!
        let empty = DayPeekModel(kind: "month", day: saturday, directory: FixtureAccounts.directory(), store: store, settings: settings, now: now)
        T.equal(empty.countText, "Nothing booked", "empty day")
        let today = DayPeekModel(kind: "month", day: cal.startOfDay(for: now), directory: FixtureAccounts.directory(), store: store, settings: settings, now: now)
        T.equal(today.title, "Today", "today says Today")
    }
}
