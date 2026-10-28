import Foundation

/// TimelinePlan: per placed family, only the moments that change what it draws (shown meetings' starts,
/// ends and Join countdown, the Up Next card's hand-over, "x of y left" and pager ends, midnight,
/// pageResetAt while on a later page, the stale boundary); ≤16 entries; reload at min(last, now + 6 h).
enum TimelineTests {
    static let cal = WidgetCalendar.fixed
    static let now = WidgetSample.fixedNow

    static func at(_ dayOffset: Int, _ h: Int, _ m: Int, from base: Date = now) -> Date {
        cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: base))!)!
    }

    static func model(_ fixture: String, _ kind: String, now: Date? = nil) -> SnapshotModel {
        SnapshotModel(SnapshotFixtures.named(fixture, kind: kind, now: now), logo: { _ in nil })
    }

    static func plan(_ m: SnapshotModel, _ spec: WidgetKindSpec, _ family: Family, now: Date = now) -> [Date] {
        TimelinePlan.entryDates(now: now, model: m, spec: spec, family: family, calendar: cal)
    }

    static func run() {
        shape()
        busyWeek()
        familyAware()
        cap()
        reload()
        afterTheReload()
        dst()
        justSynced()
        TimelineEquivalenceTests.run()
    }

    /// The ↻ glyph reads ✓ for `justSyncedWindow` after a healthy sync; one entry turns it back.
    static func justSynced() {
        T.section("timeline: refresh glyph ✓ (synced just now)")
        let window = WidgetHealthInfo.justSyncedWindow
        T.equal(window, 30, "✓ lasts 30 s")
        var snap = SnapshotFixtures.busy(kind: "month")
        snap.health.syncedAt = now.addingTimeInterval(-4)
        let fresh = SnapshotModel(snap, logo: { _ in nil })
        T.check(fresh.health.justSynced(at: now), "synced 4 s ago → ✓")
        T.check(!fresh.health.justSynced(at: now.addingTimeInterval(26)), "30 s after the sync → ↻ again")
        T.check(!fresh.health.justSynced(at: now.addingTimeInterval(-10)), "an entry before the sync → ↻")
        let end = snap.health.syncedAt!.addingTimeInterval(window)
        for family in WidgetKinds.month.families {
            let dates = plan(fresh, WidgetKinds.month, family)
            T.check(dates.contains(end), "Month \(family.short): an entry ends ✓")
            T.check(dates.count <= TimelinePlan.maxEntries, "Month \(family.short): still ≤ cap")
        }
        // The usual reload (fixtures synced 3 min before) pays nothing for the glyph.
        let usual = model("busy", "month")
        T.check(!usual.health.justSynced(at: now), "fixtures: ↻, not ✓")
        T.equal(TimelinePlan.justSyncedEnd(usual, now: now), nil, "fixtures: no extra entry")
        T.equal(plan(usual, WidgetKinds.month, .small).count, 3, "Month Small (picked day not today) stays at 3 entries")
        // Not while an account needs a sign-in, the data layer marked it stale, or the card is a state.
        var reauth = snap
        reauth.health.state = .reauth
        reauth.health.accountId = snap.accounts.first?.id
        T.check(!SnapshotModel(reauth, logo: { _ in nil }).health.justSynced(at: now), "re-auth → no ✓")
        var stale = snap
        stale.health.state = .stale
        T.check(!SnapshotModel(stale, logo: { _ in nil }).health.justSynced(at: now), "stale → no ✓")
        var setup = snap
        setup.content = .setup
        T.equal(TimelinePlan.justSyncedEnd(SnapshotModel(setup, logo: { _ in nil }), now: now), nil, "set-up card → no entry")
    }

    static func shape() {
        T.section("timeline: shape")
        let busy = model("busy", "agenda.all")
        let dates = plan(busy, WidgetKinds.agenda, .large)
        T.equal(dates.first, now, "first entry is now")
        T.check(dates.count <= TimelinePlan.maxEntries, "≤\(TimelinePlan.maxEntries) entries (got \(dates.count))")
        T.check(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 }, "strictly increasing, no duplicates")
        T.check(dates.dropFirst().allSatisfy { $0 > now && $0 <= at(1, 0, 0) }, "all up to the next midnight")
        T.check(dates.allSatisfy { $0.timeIntervalSinceReferenceDate == $0.timeIntervalSinceReferenceDate.rounded() }, "whole seconds")

        let empty = model("empty", "agenda.all")
        let quiet = plan(empty, WidgetKinds.agenda, .large)
        T.check(quiet.contains(at(1, 0, 0)), "an empty week still redraws at midnight")
        T.check(quiet.contains(empty.health.syncedAt.map { $0.addingTimeInterval(WidgetHealthInfo.staleAfter + 1) } ?? now),
                "…and when the snapshot turns stale")
        T.equal(quiet.count, 3, "empty week: now, stale boundary, midnight")
    }

    static func busyWeek() {
        T.section("timeline: busy week boundaries (Agenda Large)")
        var snap = SnapshotFixtures.busy(kind: "agenda.all")
        snap.pageResetAt = now.addingTimeInterval(5 * 60)
        let onPageOne = SnapshotModel(snap, logo: { _ in nil })
        let dates = Set(plan(onPageOne, WidgetKinds.agenda, .large))
        // Next meeting: The Comets weekly sync 10:00–10:45 (now 9:48).
        T.check(dates.contains(at(0, 10, 0)), "start of the next meeting")
        T.check(dates.contains(at(0, 10, 45)), "its end")
        for (h, m) in [(9, 50), (9, 55), (9, 59)] {
            T.check(dates.contains(at(0, h, m)), "countdown \(h):\(m) before the 10:00 start")
        }
        T.check(!dates.contains(at(0, 9, 40)), "no entries in the past")
        T.check(dates.contains(at(0, 11, 0)), "Join highlight begins 30 min before 11:30")
        T.check(!dates.contains(now.addingTimeInterval(5 * 60)), "pageResetAt is no entry while this family shows page 1")
        snap.pages = ["L": 2]
        let onPageTwo = SnapshotModel(snap, logo: { _ in nil })
        T.check(plan(onPageTwo, WidgetKinds.agenda, .large).contains(now.addingTimeInterval(5 * 60)), "…and is one on page 2")
        T.check(!plan(onPageTwo, WidgetKinds.agenda, .extraLarge).contains(now.addingTimeInterval(5 * 60)),
                "…for that family only")
        let reload = TimelinePlan.reloadDate(now: now, entries: plan(onPageOne, WidgetKinds.agenda, .large))
        T.check(reload < at(1, 0, 0), "a busy day reloads before midnight (the cap), so midnight comes with the next timeline")

        T.section("timeline: what each entry draws")
        let model = onPageOne
        let style = WidgetStyle()
        let before = model.data(at: at(0, 9, 48))
        let joinAt = model.data(at: at(0, 9, 50))
        let startAt = model.data(at: at(0, 10, 0))
        let endAt = model.data(at: at(0, 10, 45))
        func highlighted(_ d: WidgetData) -> Bool {
            guard let m = d.meetings.first(where: { $0.title == "The Comets weekly sync" }) else { return false }
            return (m.start <= d.now && m.end > d.now) || (m.start > d.now && m.start.timeIntervalSince(d.now) <= 30 * 60)
        }
        T.check(highlighted(before) && highlighted(joinAt), "highlighted (Join chip) inside the 30 min window")
        T.equal(WidgetClock.until(at(0, 10, 0), from: joinAt.now), "in 10 min", "countdown text from the entry date")
        T.check(highlighted(startAt), "Now at the start")
        let rowsBefore = KindView.meetingRows(spec: WidgetKinds.agenda, family: .large, data: before, style: style) ?? 0
        let firstAfter = AgendaWidget.pages(family: .large, meetings: endAt.agendaMeetings, now: endAt.now, style: style)
            .first?.first?.compactMap { line -> String? in if case .meeting(let m) = line { return m.title } else { return nil } }.first
        T.check(rowsBefore >= 10, "Large shows ≥10 at 9:48")
        T.equal(firstAfter, "Holiday plan review", "at 10:45 the finished meeting has left the list")
        T.equal(DaySummary.text(before.meetings, now: before.now, style: style), "7 of 8 meetings left · free after 7:30 PM",
                "\"x of y left · free after\" from the entry date")
    }

    static func familyAware() {
        T.section("timeline: per family, only what it draws")
        let busyMonth = model("busy", "month")
        let stale = busyMonth.health.syncedAt!.addingTimeInterval(WidgetHealthInfo.staleAfter + 1)
        T.equal(plan(busyMonth, WidgetKinds.month, .small), [now, stale, at(1, 0, 0)],
                "Month Small (grid only): now, stale boundary, midnight — no meeting moments")
        let picked = plan(busyMonth, WidgetKinds.month, .large)
        T.check(!picked.contains(at(0, 10, 0)) && !picked.contains(at(0, 9, 50)),
                "Month Large on a picked future day: today's meetings plan nothing")
        T.equal(picked, [now, stale, at(1, 0, 0)],
                "…only now, the stale boundary and midnight (the pick resets; the new day gets a fresh timeline)")
        T.equal(TimelinePlan.reloadDate(now: now, entries: picked), now.addingTimeInterval(TimelinePlan.maxWait),
                "…reloaded within six hours as before")
        let evening = plan(model("busy", "agenda.all"), WidgetKinds.agenda, .large, now: at(0, 21, 0))
        T.equal(evening.last, at(1, 0, 0), "an evening timeline ends at midnight")
        T.equal(TimelinePlan.reloadDate(now: at(0, 21, 0), entries: evening), at(1, 0, 0), "…and reloads there")
        var today = SnapshotFixtures.busy(kind: "month")
        today.selectedDay = DayName.linkDay(now)
        let todayPlan = plan(SnapshotModel(today, logo: { _ in nil }), WidgetKinds.month, .large)
        T.check(todayPlan.contains(at(0, 10, 0)) && todayPlan.contains(at(0, 9, 50)), "Month Large picked on today: today's moments")

        let inbox = plan(model("busy", "inbox.all"), WidgetKinds.inbox, .large)
        T.equal(inbox.count, 3, "Inbox: now, stale boundary, midnight")

        let upNext = Set(plan(model("busy", "upnext"), WidgetKinds.upNext, .small))
        T.check(upNext.contains(at(0, 10, 15).addingTimeInterval(1)), "Up Next Small: moves on 15 min after the start (+1 s)")
        T.check(upNext.contains(at(0, 10, 30)) && upNext.contains(at(0, 10, 45)),
                "…the next card's quarter-hour countdown (11:30 − 60 / − 45 min)")
        T.check(!upNext.contains(at(0, 13, 0)), "…and no moments for meetings the card doesn't show yet")

        let medium = Set(plan(model("busy", "agenda.all"), WidgetKinds.agenda, .medium))
        T.check(medium.contains(at(0, 9, 50)) && medium.contains(at(0, 10, 0)) && !medium.contains(at(0, 9, 45)),
                "Agenda Medium: the next meeting's moments, nothing in the past")

        T.section("timeline: Medium Join window matches the rows (−30 min)")
        let m = model("busy", "agenda.all")
        let joinWindow = m.data(at: at(0, 11, 0))
        let next = joinWindow.agendaMeetings.first { $0.end > joinWindow.now && !$0.allDay }
        T.equal(next?.title, "Holiday plan review", "next at 11:00 is the 11:30 meeting")
        T.check(next.map { $0.start.timeIntervalSince(joinWindow.now) <= 30 * 60 } ?? false, "inside the window at exactly −30 min")
    }

    static func cap() {
        T.section("timeline: cap at \(TimelinePlan.maxEntries), earliest kept")
        let rows = (0..<40).map { i -> FixtureMeeting in
            let start = now.addingTimeInterval(TimeInterval(15 + i * 30) * 60)
            return FixtureMeeting(r: "cap\(i)", accounts: [FixtureAccounts.orb], title: "M\(i)", start: start,
                                  end: start.addingTimeInterval(20 * 60), join: URL(string: "https://meet.google.com/x"))
        }
        let snap = SnapshotFixtures.base(kind: "agenda.all", meetings: rows, now: now, calendar: cal)
        let model = SnapshotModel(snap, logo: { _ in nil })
        let dates = plan(model, WidgetKinds.agenda, .large)
        T.equal(dates.count, TimelinePlan.maxEntries, "40 meetings in a day → exactly \(TimelinePlan.maxEntries) entries")
        T.check(dates.last! < rows[6].start, "the earliest boundaries win; later ones wait for the next timeline")
        let reload = TimelinePlan.reloadDate(now: now, entries: dates)
        T.equal(reload, dates.last!, "reload at the last entry when it is sooner than 6 h")
    }

    static func reload() {
        T.section("timeline: reload policy")
        let far = [now, now.addingTimeInterval(20 * 3600)]
        T.equal(TimelinePlan.reloadDate(now: now, entries: far), now.addingTimeInterval(6 * 3600), "never later than now + 6 h")
        let near = [now, now.addingTimeInterval(2 * 3600)]
        T.equal(TimelinePlan.reloadDate(now: now, entries: near), now.addingTimeInterval(2 * 3600), "the last entry when sooner")
        T.equal(TimelinePlan.reloadDate(now: now, entries: [now]), now.addingTimeInterval(15 * 60), "only now → 15 min, never a reload loop")
        T.equal(TimelinePlan.reloadDate(now: now, entries: [now, now.addingTimeInterval(30)]), now.addingTimeInterval(15 * 60),
                "a last entry seconds away → 15 min")
    }

    /// If WidgetKit doesn't reload at the last planned entry, the settle entries after it stop a "Now" or
    /// a countdown from outliving its meeting.
    static func afterTheReload() {
        T.section("timeline: after the reload moment (WidgetKit late), no stale \"Now\"")
        let join = URL(string: "https://meet.google.com/x")
        func live(_ m: SnapshotModel, _ spec: WidgetKindSpec, _ family: Family, at t: Date) -> Set<Int> {
            TimelineEquivalenceTests.drawnLive(spec, family, m, at: t)
        }

        // An overnight call: the timeline now ends at midnight, inside it.
        let night = FixtureMeeting(r: "night", accounts: [FixtureAccounts.orb], title: "Night call", start: at(0, 23, 15),
                                   end: at(1, 0, 45), join: join)
        let nightModel = SnapshotModel(SnapshotFixtures.base(kind: "agenda.all", meetings: [night], now: at(0, 22, 0), calendar: cal),
                                       logo: { _ in nil })
        let evening = TimelinePlan.timeline(now: at(0, 22, 0), model: nightModel, spec: WidgetKinds.agenda, family: .large, calendar: cal)
        let planned = plan(nightModel, WidgetKinds.agenda, .large, now: at(0, 22, 0))
        T.equal(planned.last, at(1, 0, 0), "the planned entries end at midnight…")
        T.check(!live(nightModel, WidgetKinds.agenda, .large, at: at(1, 0, 0)).isEmpty, "…where the overnight call is drawn as \"Now\"")
        T.equal(evening.reload, at(1, 0, 0), "the reload is still due at midnight")
        T.equal(Array(evening.entries.dropFirst(planned.count)), [at(1, 0, 45)], "one settle entry: the call's end, past midnight")
        T.check(live(nightModel, WidgetKinds.agenda, .large, at: evening.entries.last!).isEmpty,
                "the last entry draws no \"Now\" (without it: \"Now\" until WidgetKit reloads)")
        // Up Next Medium: the card hands the call over at 23:30, then "After that" lists it as "Now".
        let nightUpNext = SnapshotModel(SnapshotFixtures.base(kind: "upnext", meetings: [night], now: at(0, 23, 20), calendar: cal),
                                        logo: { _ in nil })
        let upNext = TimelinePlan.timeline(now: at(0, 23, 20), model: nightUpNext, spec: WidgetKinds.upNext, family: .medium, calendar: cal)
        T.equal(upNext.reload, at(1, 0, 0), "Up Next Medium: reload at midnight…")
        T.equal(upNext.entries.last, at(1, 0, 45), "…and the call's end after it, where \"After that\" stops drawing it")

        // A capped day: the 16th entry falls inside a countdown or a meeting.
        let rows = (0..<40).map { i -> FixtureMeeting in
            let start = now.addingTimeInterval(TimeInterval(15 + i * 30) * 60)
            return FixtureMeeting(r: "cap\(i)", accounts: [FixtureAccounts.orb], title: "M\(i)", start: start,
                                  end: start.addingTimeInterval(20 * 60), join: join)
        }
        let capped = SnapshotModel(SnapshotFixtures.base(kind: "agenda.all", meetings: rows, now: now, calendar: cal), logo: { _ in nil })
        let full = TimelinePlan.timeline(now: now, model: capped, spec: WidgetKinds.agenda, family: .large, calendar: cal)
        let cut = plan(capped, WidgetKinds.agenda, .large)
        let drawn = live(capped, WidgetKinds.agenda, .large, at: cut.last!)
        T.check(!drawn.isEmpty, "the capped timeline's last planned entry draws a meeting live or counting down")
        T.equal(full.reload, cut.last!, "the reload stays at the last planned entry")
        T.check(full.entries.count > cut.count && full.entries.count <= cut.count + TimelinePlan.maxSettleEntries,
                "1…\(TimelinePlan.maxSettleEntries) settle entries after it (\(full.entries.count - cut.count))")
        T.check(live(capped, WidgetKinds.agenda, .large, at: full.entries.last!).isDisjoint(with: drawn),
                "after the last entry, none of those meetings is still drawn live")

        // A quiet ending costs nothing: Month on a picked day ends at midnight with nothing live.
        let month = model("busy", "month")
        T.equal(TimelinePlan.timeline(now: now, model: month, spec: WidgetKinds.month, family: .large, calendar: cal).entries,
                plan(month, WidgetKinds.month, .large), "Month on a picked day: no settle entries")
    }

    static func dst() {
        T.section("timeline: London leaves summer time (Sun 25 Oct 2026, 02:00 BST → 01:00 GMT)")
        let sunday = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 10))!
        let snap = SnapshotFixtures.named("dst", kind: "agenda.all", now: sunday)
        let model = SnapshotModel(snap, logo: { _ in nil })
        let dates = plan(model, WidgetKinds.agenda, .large, now: sunday)
        let monday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: sunday))!
        T.check(!dates.contains(monday), "Monday's midnight is past the 24-hour horizon (Sunday lasts 25 h)")
        T.equal(monday.timeIntervalSince(sunday), 24 * 3600 + 50 * 60, "00:10 → midnight is 24 h 50 min real time (the hour repeats)")
        T.equal(cal.timeZone.secondsFromGMT(for: sunday) - cal.timeZone.secondsFromGMT(for: monday), 3600, "UTC+1 → UTC+0")
        T.check(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 }, "no duplicate entries across the repeated hour")
        let late = model.meetings.first { $0.title.hasPrefix("Late call") }!
        T.check(dates.contains(late.start) && dates.contains(late.end), "the late call's boundaries are entries (it ends inside the repeated hour)")
        T.check(cal.timeZone.isDaylightSavingTime(for: late.start) && !cal.timeZone.isDaylightSavingTime(for: late.end.addingTimeInterval(3600)),
                "the late call starts in summer time")
        T.check(dates.last.map { $0 <= sunday.addingTimeInterval(TimelinePlan.horizon) } ?? false, "the timeline stays inside 24 real hours")
        let saturday6pm = cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 18))!
        let eve = SnapshotModel(SnapshotFixtures.named("dst", kind: "agenda.all", now: saturday6pm), logo: { _ in nil })
        T.equal(plan(eve, WidgetKinds.agenda, .large, now: saturday6pm).last, cal.startOfDay(for: sunday),
                "the evening before, the timeline ends at Sunday's midnight (6 real hours: the hour repeats after it)")
        T.check(cal.isDate(late.start, inSameDayAs: sunday), "the 00:30 call is on Sunday")
        let pages = AgendaWidget.pages(family: .large, meetings: model.meetings, now: sunday, style: WidgetStyle())
        let firstColumn = pages.first?.first ?? []
        let days = firstColumn.compactMap { line -> String? in if case .day(let d, _, _, _, _) = line { return DayName.linkDay(d) } else { return nil } }
        T.equal(Array(days.prefix(2)), ["2026-10-25", "2026-10-26"], "Sunday then Monday banners")
        let sundayRows = model.data(at: sunday).meetings.filter { cal.isDate($0.start, inSameDayAs: sunday) && $0.start > late.end }
        T.equal(sundayRows.map { cal.component(.hour, from: $0.start) }, [10, 13, 16, 20], "after the change, Sunday's meetings keep their wall-clock hours")
        let mondayRows = model.data(at: monday.addingTimeInterval(60)).meetings.filter { cal.isDate($0.start, inSameDayAs: monday) }
        T.equal(mondayRows.map { cal.component(.hour, from: $0.start) }, [9, 11, 14], "Monday's meetings keep their wall-clock hours")
        T.note("DST: Monday midnight is \(Int(monday.timeIntervalSince(sunday) / 60)) min after Sunday 00:10; \(dates.count) entries")
    }
}

/// The trimmed timeline draws what the widget would draw at every moment until its reload: at each
/// moment anything could change (every meeting's start, end, countdown marks and card hand-over,
/// midnights, page reset, stale boundary, undo ends) the entry in force must describe the same widget
/// as the moment itself — same rows and banners, highlights, "Now", the countdown at its D-017 step
/// (and the Up Next card's quarter hour), "x of y left", pager, picked day, footer, mail rows.
enum TimelineEquivalenceTests {
    static let cal = WidgetCalendar.fixed

    static func run() {
        T.section("timeline: trimmed entries draw the same widget at every moment until the reload")
        let base = WidgetSample.fixedNow
        let times = [base, TimelineTests.at(0, 13, 50), TimelineTests.at(0, 23, 40), TimelineTests.at(1, 9, 31)]
        let everyKind = WidgetKinds.all
        let cases: [(String, [WidgetKindSpec], [Date])] = [
            ("busy", everyKind, times),
            ("sparse", [WidgetKinds.agenda, WidgetKinds.month, WidgetKinds.upNext], times),
            ("busyPage2", [WidgetKinds.agenda], [base]),
            ("stale", [WidgetKinds.agenda, WidgetKinds.month], [base]),
            ("reauth", [WidgetKinds.agenda, WidgetKinds.upNext], [base]),
            ("mailArchived", [WidgetKinds.inbox, WidgetKinds.combo], [base]),
            ("dst", [WidgetKinds.agenda, WidgetKinds.month, WidgetKinds.day],
             [SnapshotFixtures.dstNow, cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 10))!]),
            // Day (D-022): the 20-meeting day, another day picked, a custom slot set to Day, a stale strip.
            ("busyDay", [WidgetKinds.day], times + [TimelineTests.at(0, 7, 5), TimelineTests.at(0, 10, 20)]),
            ("dayPicked", [WidgetKinds.day], times),
            ("customDay", [WidgetKinds.spec("custom.f")!], [base]),
            ("stale", [WidgetKinds.day], [base]),
        ]
        var checked = 0, failures = 0, entries: [Int] = [], settles: [Int] = []
        var endingInside = 0, staleAfter = 0, timelines = 0
        for (fixture, specs, nows) in cases + [("overlap", [WidgetKinds.agenda, WidgetKinds.combo], [base])] {
            for spec in specs {
                let snapshotNow = fixture == "dst" ? SnapshotFixtures.dstNow : base
                let snapshot = fixture == "overlap" ? overlap(kind: spec.kind, now: base)
                    : SnapshotFixtures.named(fixture, kind: spec.kind, now: snapshotNow)
                let model = SnapshotModel(snapshot, logo: { _ in nil })
                for family in spec.families {
                    for now in nows {
                        let full = TimelinePlan.timeline(now: now, model: model, spec: spec, family: family, calendar: cal)
                        let dates = full.entries, reload = full.reload
                        let planned = TimelinePlan.entryDates(now: now, model: model, spec: spec, family: family, calendar: cal)
                        entries.append(planned.count)
                        settles.append(dates.count - planned.count)
                        timelines += 1
                        // No reload at all: once the meetings the last planned entry draws live are over,
                        // the entry in force draws none of them.
                        let last = planned.last ?? now
                        let drawn = drawnLive(spec, family, model, at: last)
                        if !drawn.isEmpty {
                            endingInside += 1
                            let over = model.meetings.filter { drawn.contains($0.id) }.map(\.end).max() ?? last
                            let inForce = dates.last { $0 <= over } ?? now
                            if !drawnLive(spec, family, model, at: inForce).isDisjoint(with: drawn) {
                                staleAfter += 1
                                T.note("\(fixture) \(spec.kind) \(family.short) now \(DayName.format("EEE HH:mm", now)): still drawn live at \(DayName.format("HH:mm", over))")
                            }
                        }
                        var check = moments(model, now: now, until: reload)
                        if KindView.resolve(spec: spec, family: family, data: model.data(at: now)) == .design(.day) {
                            // The Day redraws on its own moments (windows, now-line steps): look every 5 min too.
                            var t = now
                            while t < reload { check.append(t); t = t.addingTimeInterval(300) }
                            check = Array(Set(check)).sorted()
                        }
                        for u in check {
                            let active = dates.last { $0 <= u } ?? now
                            checked += 1
                            let want = signature(spec, family, model, at: u), got = signature(spec, family, model, at: active)
                            if want != got {
                                failures += 1
                                if failures <= 5 {
                                    T.note("\(fixture) \(spec.kind) \(family.short) now \(DayName.format("EEE HH:mm", now)): at \(DayName.format("EEE HH:mm:ss", u)) the entry \(DayName.format("HH:mm:ss", active)) differs\n      want \(want.replacingOccurrences(of: "\n", with: " ; "))\n      got  \(got.replacingOccurrences(of: "\n", with: " ; "))")
                                }
                            }
                        }
                    }
                }
            }
        }
        T.check(failures == 0, "\(failures) of \(checked) moments draw differently from their entry")
        T.check(staleAfter == 0, "with no reload, \(staleAfter) of \(endingInside) timelines that end their planned entries inside a \"Now\" or countdown (of \(timelines)) still draw it after those meetings end")
        T.note("\(endingInside) of \(timelines) timelines end their planned entries inside a \"Now\" or countdown; settle entries: \(settles.filter { $0 > 0 }.count) timelines get any, max \(settles.max() ?? 0)")
        let sorted = entries.sorted()
        T.note("\(entries.count) timelines, \(checked) moments checked; entries per timeline: median \(sorted[sorted.count / 2]), max \(sorted.last ?? 0)")
    }

    /// Meetings the widget draws as "Now" or counting down at `t`: its rows (with the Medium panel's next
    /// meeting) and the Up Next card, inside the 30-minute Join window or under way.
    static func drawnLive(_ spec: WidgetKindSpec, _ family: Family, _ model: SnapshotModel, at t: Date) -> Set<Int> {
        let shown = KindView.shownMeetings(spec: spec, family: family, data: model.data(at: t), style: model.style(dark: false),
                                           page: model.page(family: family, at: t))
        let drawn = shown.rows + (shown.card.map { [$0] } ?? [])
        return Set(drawn.filter { !$0.allDay && $0.end > t && $0.start.timeIntervalSince(t) <= 30 * 60 }.map(\.id))
    }

    /// Fourteen meetings at 10:00: eleven fill Large's page 1 and run to 11:00, the last three (off page
    /// 1) end at 10:20–10:30. Their ends move "1 of 2" to no pager and "x of y left" although no shown
    /// row changes.
    static func overlap(kind: String, now: Date) -> WidgetSnapshot {
        let start = TimelineTests.at(0, 10, 0)
        let rows = (0..<14).map { i -> FixtureMeeting in
            FixtureMeeting(r: String(format: "ov%02d", i), accounts: [FixtureAccounts.orb], title: "Overlap \(i)", start: start,
                           end: start.addingTimeInterval(i < 11 ? 3600 : TimeInterval(20 + (i - 11) * 5) * 60),
                           join: URL(string: "https://meet.google.com/x"))
        }
        return SnapshotFixtures.base(kind: kind, meetings: rows, now: now, calendar: cal)
    }

    /// Every moment at which anything on any widget could change, from `now` until `reload`.
    static func moments(_ model: SnapshotModel, now: Date, until reload: Date) -> [Date] {
        var out = Set<Date>([now])
        for m in model.meetings {
            out.formUnion(TimelinePlan.boundaries(m))
            out.insert(m.start.addingTimeInterval(UpNextSmall.grace + 1))
            for mark in TimelinePlan.cardMarks { out.insert(m.start.addingTimeInterval(-mark)) }
        }
        var day = cal.startOfDay(for: now)
        while let next = cal.date(byAdding: .day, value: 1, to: day), next < reload { out.insert(next); day = next }
        if let reset = model.snapshot.pageResetAt { out.insert(reset) }
        if let stale = TimelinePlan.staleAt(model) { out.insert(stale) }
        out.formUnion(model.undoEnds)
        return out.filter { $0 >= now && $0 < reload }.sorted()
    }

    /// Countdown minutes at the step the timeline draws them (D-017 marks; the card's quarter hours).
    static func step(_ seconds: TimeInterval, _ marks: [TimeInterval]) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return marks.map { Int($0 / 60) }.sorted().first { $0 >= minutes }.map { "\($0)" } ?? "far"
    }

    /// What the widget shows at `t`, with countdowns at their planned step.
    static func signature(_ spec: WidgetKindSpec, _ family: Family, _ model: SnapshotModel, at t: Date) -> String {
        let data = model.data(at: t)
        let style = model.style(dark: false)
        let page = model.page(family: family, at: t)
        var out: [String] = []
        let footer = data.state == .content ? data.health.footer(at: t) : .none
        switch footer {
        case .none: out.append("footer=none")
        case .stale: out.append("footer=stale")
        case .reauth(let tag, _): out.append("footer=reauth:\(tag)")
        }
        let resolved = KindView.resolve(spec: spec, family: family, data: data)
        out.append("resolved=\(resolved)")
        func row(_ m: WidgetMeeting) -> String {
            let live = !m.allDay && m.start <= t && m.end > t
            let soon = !m.allDay && !live && m.start > t && m.start.timeIntervalSince(t) <= 30 * 60
            if live { return "\(m.id):now" }
            if soon { return "\(m.id):in\(step(m.start.timeIntervalSince(t), TimelinePlan.countdownMarks))" }
            return "\(m.id):\(m.allDay ? "allday" : "at")"
        }
        func lines(_ list: [AgendaLine]) -> String {
            list.map { line -> String in
                switch line {
                case .day(let d, let continued, let count, let first, let slim):
                    return "[\(DayName.title(d, now: t))|\(DayName.subtitle(d, now: t))|\(count)|\(continued)|\(first)|\(slim)]"
                case .meeting(let m): return row(m)
                }
            }.joined(separator: " ")
        }
        func card(_ meetings: [WidgetMeeting]) -> String {
            guard let m = UpNextSmall.next(meetings, now: t) else { return "card=none" }
            if m.start <= t { return "card=\(m.id):now" }
            return "card=\(m.id):in\(step(m.start.timeIntervalSince(t), TimelinePlan.countdownMarks + TimelinePlan.cardMarks))"
        }
        func summary(_ meetings: [WidgetMeeting]) -> String { "summary=" + DaySummary.text(meetings, now: t, style: style) }
        func mail(_ rows: [WidgetMail]) -> String {
            "mail=" + rows.map { m -> String in
                let day = cal.isDate(m.at, inSameDayAs: t) ? "today"
                    : cal.isDate(m.at, inSameDayAs: cal.date(byAdding: .day, value: -1, to: t)!) ? "yesterday" : "older"
                return "\(m.id):\(m.archivedAt != nil):\(day)"
            }.joined(separator: ",")
        }
        out.append("header=\(DayName.format("EEEE d MMMM", t))")
        switch resolved {
        case .design(.agenda):
            let meetings = data.agendaMeetings
            switch family {
            case .small:
                out.append(card(meetings))
            case .medium:
                let next = meetings.first { $0.end > t && !$0.allDay }
                let join = next.map { $0.hasLink && $0.start.timeIntervalSince(t) <= 30 * 60 } ?? false
                out.append("panel=\(next?.id ?? 0):\(join)")
                if !join { out.append(summary(meetings)) }
                out.append(lines(AgendaWidget.mediumLines(meetings: meetings, now: t, style: style)))
            case .large, .extraLarge, .extraLargePortrait:
                let reserve = footer != .none ? WidgetFooterView.reserve : 0
                let pages = AgendaWidget.pages(family: family, meetings: meetings, now: t, style: style, reserve: reserve)
                let current = pages.isEmpty ? [] : pages[max(1, min(page, pages.count)) - 1]
                out.append("pages=\(pages.count) page=\(page)")
                out.append(current.map(lines).joined(separator: " | "))
                if family != .large { out.append(summary(meetings)) }
            }
        case .design(.upNext):
            out.append(card(data.meetings))
            if family == .medium { out.append(lines(UpNextWidget.laterLines(meetings: data.meetings, now: t, style: style))) }
        case .design(.month):
            out.append("today=\(DayName.linkDay(t)) picked=\(DayName.linkDay(data.selectedDay)) month=\(DayName.linkMonth(data.monthShown ?? t))")
            if let height = MonthWidget.listHeight(family) {
                out.append(lines(DayList.lines(day: data.selectedDay, now: t, meetings: data.meetings, style: style, height: height)))
            }
        case .design(.combo):
            let pages = ComboWidget.agendaPages(data.agendaMeetings, now: t, style: style, height: ComboWidget.agendaHeight(family))
            let shown = pages.isEmpty ? 1 : min(max(page, 1), pages.count)
            out.append("pages=\(pages.count) page=\(shown)")
            if !pages.isEmpty { out.append(lines(pages[shown - 1])) }
            out.append(mail(data.mail))
        case .design(.inbox):
            out.append("page=\(page)")
            out.append(mail(data.mail))
        case .design(.day):
            // Everything the Day draws but the now line's exact height (DayWidgetTests checks its steps).
            let reserve = footer != .none && !KindView.compactFooter(family) ? WidgetFooterView.reserve : 0
            let d = DayTimelineWidget.drawing(family: family, meetings: data.meetings, day: data.selectedDay, now: t,
                                              style: style, reserve: reserve)
            let windows = d.windows.map { "\(DayName.format("HH:mm", $0.start))-\(DayName.format("HH:mm", $0.end))" }
            out.append("day=\(DayName.linkDay(data.selectedDay)) focus=\(d.focus ?? 0) past=\(d.past) windows=\(windows) text=\(d.text)")
        default:
            break
        }
        return out.joined(separator: "\n")
    }
}

/// Link building with r/k from snapshot rows (CONTRACTS routes) and the Month window clamp.
enum LinkTests {
    static let now = WidgetSample.fixedNow
    static let cal = WidgetCalendar.fixed

    static func run() {
        T.section("links: snapshot rows carry r + k")
        let model = SnapshotModel(SnapshotFixtures.busy(kind: "agenda.all"), logo: { _ in nil })
        let ctx = WidgetLinkContext(kind: "agenda.all", family: .large)
        var allOk = true
        for m in model.meetings {
            guard let r = m.r, let k = m.k else { allOk = false; continue }
            let open = Route.parse(ctx.event(m)), join = Route.parse(ctx.join(m)), reply = Route.parse(ctx.reply(m))
            if open?.name != "open/event" || open?.params != ["r": r, "k": k] { allOk = false }
            if join?.name != "join" || join?.params != ["r": r, "k": k] { allOk = false }
            if reply?.name != "open/event" { allOk = false }
            if k.count != 16 || !Route.isSafeValue(k) || !FixtureLinkKeys.verify(r: r, k: k) { allOk = false }
        }
        T.check(allOk, "every row: open/event?r&k, join?r&k, Reply? → open/event; k is 16 base64url chars and verifies")
        T.equal(Route.parse(ctx.event(model.meetings[0]))?.quiet, false, "open/event is not quiet")
        T.equal(Route.parse(ctx.join(model.meetings[0]))?.quiet, true, "join is quiet")
        T.check(!ctx.event(model.meetings[0]).absoluteString.contains("@") && !ctx.join(model.meetings[0]).absoluteString.contains("http"),
                "no addresses or URLs in links")

        T.section("links: sample rows and unsafe ids ping")
        let sample = WidgetSample.week(now: now, logos: nil, calendar: cal).meetings[1]
        T.equal(Route.parse(ctx.event(sample))?.name, "ping", "sample row → ping")
        T.equal(Route.parse(ctx.join(sample))?.params["probe"], "agenda.all.L.join.2", "sample join → ping probe")
        var unsafe = model.meetings[0]; unsafe.r = "a b"
        T.equal(Route.parse(ctx.event(unsafe))?.name, "ping", "unsafe r → ping, never a broken route")
        var noKey = model.meetings[0]; noKey.k = nil
        T.equal(Route.parse(ctx.join(noKey))?.name, "ping", "missing k → ping")

        T.section("links: Month (Small → Day Peek; arrows clamped to the window)")
        let data = model.data(at: now)
        let small = WidgetLinkContext(kind: "month", family: .small, windowStart: data.windowStart, windowEnd: data.windowEnd)
        let large = WidgetLinkContext(kind: "month", family: .large, windowStart: data.windowStart, windowEnd: data.windowEnd)
        let wed = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!
        T.equal(Route.parse(small.day(wed))?.name, "open/day", "Small day → open/day")
        T.equal(Route.parse(large.day(wed))?.name, "day", "Large day → day (pick in place)")
        func month(_ y: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: 10))! }
        T.equal(large.month(month(2026, 11)).flatMap(Route.parse)?.params["to"], "2026-11", "next month inside the window")
        T.equal(large.month(month(2026, 12)).flatMap(Route.parse)?.params["to"], "2026-12", "the window's last month")
        T.check(large.month(month(2027, 1)) == nil, "past windowEnd → no link (arrow disabled)")
        T.check(large.month(month(2026, 9)) != nil, "the month the grid starts in (26 Sep) is reachable")
        T.check(large.month(month(2026, 8)) == nil, "before windowStart → no link")
        T.check(WidgetLinkContext(kind: "month", family: .large).month(month(2030, 1)) != nil, "no window (sample) → unbounded")

        T.section("links: builders round-trip to CONTRACTS routes")
        T.equal(Route.parse(YayaLink.rsvp(r: "ev2", k: "k", v: "yes"))?.params, ["r": "ev2", "k": "k", "v": "yes"], "rsvp")
        T.equal(Route.parse(YayaLink.reauth(a: "A", k: "k"))?.params, ["a": "A", "k": "k"], "reauth")
        T.equal(Route.parse(YayaLink.range(kind: "agenda.all", days: 2))?.params, ["w": "agenda.all", "v": "2"], "range")
        T.equal(Route.parse(YayaLink.sync())?.name, "sync", "sync")
        T.equal(Route.parse(YayaLink.openEvent(r: "ev2", k: "k"))?.name, "open/event", "open/event")
        T.equal(Route.parse(YayaLink.join(r: "ev2", k: "k"))?.name, "join", "join")
    }
}
