import Foundation

/// Meeting heads-up rules and reschedule diff, snooze, pause, DST triggers, re-auth throttle,
/// new-mail batching, the Deck export (schema, window, isExternal, atomic 0600 write, change
/// detection) and the engine observers that drive them. Fakes only: no real notification is posted.
enum NotifyTests {
    static let meet = "https://meet.google.com/abc-defg-hij"

    static func run() async {
        joinGuard()
        eligibility()
        window()
        content()
        dedupe()
        diff()
        pause()
        cap()
        dst()
        await coordinatorPlans()
        await snooze()
        await reauth()
        await newMail()
        deckSchema()
        deckIdentity()
        deckWindowAndExternal()
        deckWrite()
        await deckThroughCoordinator()
        await engineObservers()
        await servicesObserve()
        await hardening()
        await lifecycle()
    }

    // MARK: - Join guard

    static func joinGuard() {
        // Exactly the sync-time rules (JoinLinks): every link the join corpus keeps passes, nothing looser.
        for c in JoinTests.corpus {
            if let kept = c.expected { expect(JoinGuard.isAllowed(URL(string: kept)), "join guard allows what sync keeps: \(c.name)") }
        }
        let allowed = [
            "https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/j/1234567890", "https://zoom.us/j/1",
            "https://teams.microsoft.com/l/meetup-join/x", "https://teams.live.com/meet/1", "https://acme.webex.com/meet/demo",
            "https://whereby.com/room", "https://app.slack.com/huddle/T1/C1", "https://meet.goto.com/123", "https://chime.aws/1234567890",
            "https://meet.jit.si/Room", "https://MEET.GOOGLE.COM/abc",
        ]
        for s in allowed { expect(JoinGuard.isAllowed(URL(string: s)), "join guard allows \(s)") }
        let blocked = [
            "http://meet.google.com/abc", "https://meet.google.com.evil.example/abc", "https://evilzoom.us/j/1",
            "https://user:pw!@meet.google.com/abc", "https://meet.google.com:8443/abc", "https://google.com/meet",
            "javascript:alert(1)", "file:///etc/hosts", "ftp://zoom.us/x", "https://zoom.us.example.com/j/1",
            "https://example.com/?u=https://meet.google.com", "https://meet.google.com%2eevil.example/x",
            "yayacal://join?r=x", "https://xn--zoom-xx.example/j/1",
            // Looser than sync would allow: suffix hosts, bare domains, paths off the per-host list.
            "https://meet.google.com./abc", "https://app.chime.aws/meetings/1", "https://evil.slack.com/huddle/x",
            "https://slack.com/huddle/x", "https://webex.com/meet/demo", "https://zoom.us/", "https://zoom.us/profile",
            "https://meet.google.com/", "https://teams.microsoft.com/settings", "https://x.meet.google.com/abc",
        ]
        for s in blocked { expect(!JoinGuard.isAllowed(URL(string: s)), "join guard blocks \(s)") }
        expect(!JoinGuard.isAllowed(nil), "join guard: no URL")
        expect(JoinGuard.providerName(URL(string: "https://us02web.zoom.us/j/1")) == "Zoom"
               && JoinGuard.providerName(URL(string: meet)) == "Google Meet"
               && JoinGuard.providerName(URL(string: "http://zoom.us/j/1")) == nil, "provider names only for allowed links")
    }

    // MARK: - Heads-up rules

    static func eligibility() {
        let at = TestCal.labNow.addingTimeInterval(3600)
        let me = N.person("y@orb.example", me: true)
        let guest = N.person("h@client.example")
        expect(HeadsUp.isEligible(N.event("a", start: at, join: meet)), "join link → heads-up")
        expect(HeadsUp.isEligible(N.event("b", start: at, people: [me, guest])), "two attendees, no link → heads-up")
        expect(!HeadsUp.isEligible(N.event("c", start: at)), "solo block, no link → skipped")
        expect(!HeadsUp.isEligible(N.event("d", start: at, people: [me])), "only me, no link → skipped")
        expect(!HeadsUp.isEligible(N.event("e", start: at, join: meet, people: [me, guest], response: .declined)), "declined → skipped")
        expect(!HeadsUp.isEligible(N.event("f", start: at, join: meet, allDay: true)), "all-day → skipped")
        expect(HeadsUp.isEligible(N.event("g", start: at, join: meet, response: .needsAction))
               && HeadsUp.isEligible(N.event("h", start: at, join: meet, response: .tentative)), "not answered / maybe → heads-up")
        expect(!HeadsUp.isEligible(N.event("i", start: at, join: "https://evil.example/j/1")), "a link off the allowlist is no link")
    }

    static func window() {
        let now = TestCal.labNow
        let events = [
            N.event("soon", start: now.addingTimeInterval(30), join: meet),            // its minute-before already passed
            N.event("next", start: now.addingTimeInterval(120), join: meet),
            N.event("edge", start: now.addingTimeInterval(HeadsUp.horizon), join: meet),
            N.event("late", start: now.addingTimeInterval(HeadsUp.horizon + 60), join: meet),
            N.event("past", start: now.addingTimeInterval(-600), minutes: 60, join: meet),
        ]
        let notes = HeadsUp.desired(events, N.context(now: now))
        expect(notes.map(\.id) == [HeadsUp.id(events[1]), HeadsUp.id(events[2])], "next 24 h only, and only while the minute-before is ahead")
        expect(notes.first?.fireAt == events[1].start.addingTimeInterval(-60), "fires 60 s before the start")
        expect(notes.first?.id == "meet-next-\(HeadsUp.epoch(events[1].start))", "id = meet-<r>-<epoch start>")
        expect(HeadsUp.desired(events, N.context(now: now, meetingsOn: false)).isEmpty, "setting off → nothing wanted")
    }

    static func content() {
        let orb = UUID(), cmt = UUID()
        let start = TestCal.local(2026, 10, 19, 10, 0)
        let e = N.event("gW", "Weekly sync with Milo", start: start, join: meet, accounts: [orb, cmt])
        let ctx = N.context(tags: [orb: "ORB", cmt: "CMT"])
        guard let note = HeadsUp.desired([e], ctx).first else { expect(false, "content: a note"); return }
        expect(note.title == "Weekly sync with Milo", "title = meeting title")
        expect(note.body.hasPrefix("In 1 minute \u{00B7} 10:00") && note.body.hasSuffix("\u{00B7} Google Meet \u{00B7} ORB+CMT"),
               "body: lead, local time, provider, merged tags (\(note.body))")
        expect(note.category == NoteIds.meetingCategory && note.thread == "meet-gW" && note.sound, "Join + Snooze category, default sound")
        expect(Set(note.userInfo.keys) == ["kind", "r", "start", "fire"], "userInfo: ids and epochs only")
        expect(!note.userInfo.values.contains { $0.contains("http") || $0.contains("Milo") || $0.contains("@") },
               "no URL, title or address in userInfo (Join re-reads the store)")
        let solo = HeadsUp.desired([N.event("gP", "  ", start: start, people: [N.person("a@orb.example", me: true), N.person("b@orb.example")])], ctx).first
        expect(solo?.category == NoteIds.meetingNoLinkCategory && solo?.title == "Meeting" && solo?.body.contains("Meet") == false,
               "no link: Snooze-only category, no provider; empty title → \u{201C}Meeting\u{201D}")
        expect(HeadsUp.lead(fire: start, start: start) == "Starting now"
               && HeadsUp.lead(fire: start.addingTimeInterval(180), start: start) == "Started 3 min ago"
               && HeadsUp.lead(fire: start.addingTimeInterval(-300), start: start) == "In 5 minutes", "lead text")
    }

    static func dedupe() {
        let orb = UUID(), cmt = UUID()
        let at = TestCal.labNow.addingTimeInterval(3600)
        let events = [
            N.event("g1", start: at, join: meet, accounts: [orb, cmt]),
            N.event("g1", start: at, join: meet, accounts: [cmt]),                           // same group id again
            N.event("g2", start: at, join: meet.uppercased().replacingOccurrences(of: "HTTPS", with: "https"), accounts: [cmt]), // separate invite, same call
            N.event("g3", start: at, join: "https://zoom.us/j/99", accounts: [cmt]),          // another call at the same time
            N.event("g4", start: at, people: [N.person("a@x.example"), N.person("b@x.example")]),   // no link: never call-deduped
        ]
        let ids = HeadsUp.desired(events, N.context()).map(\.id)
        let epoch = HeadsUp.epoch(at)
        expect(ids == ["meet-g1-\(epoch)", "meet-g3-\(epoch)", "meet-g4-\(epoch)"], "merged invites and same-call copies notify once (\(ids))")
    }

    static func diff() {
        let now = TestCal.labNow
        var e1 = N.event("d1", "One", start: now.addingTimeInterval(3600), join: meet)
        var e2 = N.event("d2", "Two", start: now.addingTimeInterval(7200), people: [N.person("a@x.example"), N.person("b@x.example")])
        let e3 = N.event("d3", "Three", start: now.addingTimeInterval(10800), join: meet)
        let ctx = N.context(now: now)
        func pending(_ notes: [LocalNote]) -> [PendingNote] { notes.map { PendingNote(id: $0.id, fingerprint: $0.fingerprint, fireAt: $0.fireAt) } }
        func plan(_ events: [CalendarEvent], _ held: [PendingNote]) -> HeadsUp.Plan {
            HeadsUp.plan(desired: HeadsUp.desired(events, ctx), pending: held, liveKeys: HeadsUp.liveKeys(events, ctx), pausedUntil: nil)
        }
        let first = HeadsUp.desired([e1, e2, e3], ctx)
        let p1 = plan([e1, e2, e3], [])
        expect(p1.add.count == 3 && p1.remove.isEmpty, "first plan adds every heads-up")
        var held = pending(first)
        let p2 = plan([e1, e2, e3], held)
        expect(p2.add.isEmpty && p2.remove.isEmpty && p2.unchanged == 3, "same data → nothing re-added (no duplicates)")

        e1.title = "One (renamed)"
        let p3 = plan([e1, e2, e3], held)
        expect(p3.add.map(\.id) == [HeadsUp.id(e1)] && p3.remove.isEmpty, "renamed → replaced under the same id")

        let oldId2 = HeadsUp.id(e2)
        e2.start = e2.start.addingTimeInterval(1800)
        e2.end = e2.end.addingTimeInterval(1800)
        let p4 = plan([e1, e2, e3], held)
        expect(p4.remove == [oldId2] && p4.add.map(\.id).contains(HeadsUp.id(e2)), "moved → old id removed, new id added")

        let p5 = plan([e1, e2], held)
        expect(p5.remove.contains(HeadsUp.id(e3)), "deleted meeting → its heads-up removed")
        var declined = e3
        declined.myResponse = .declined
        expect(plan([e1, e2, declined], held).remove.contains(HeadsUp.id(e3)), "declined later → removed")

        // Other notes and live snoozes are left alone; a snooze of a deleted meeting goes.
        held += [PendingNote(id: "reauth-x", fingerprint: nil, fireAt: nil), PendingNote(id: "mail-y", fingerprint: nil, fireAt: nil),
                 PendingNote(id: HeadsUp.snoozeId(key: HeadsUp.key(e1)), fingerprint: "s", fireAt: now.addingTimeInterval(60)),
                 PendingNote(id: HeadsUp.snoozeId(key: HeadsUp.key(e3)), fingerprint: "s", fireAt: now.addingTimeInterval(60))]
        let p6 = plan([e1, e2], held)
        expect(!p6.remove.contains("reauth-x") && !p6.remove.contains("mail-y"), "re-auth and mail notes are not the planner's")
        expect(!p6.remove.contains(HeadsUp.snoozeId(key: HeadsUp.key(e1))) && p6.remove.contains(HeadsUp.snoozeId(key: HeadsUp.key(e3))),
               "snooze kept while its meeting lives, removed when it is gone")
    }

    static func pause() {
        let now = TestCal.labNow
        let early = N.event("p1", start: now.addingTimeInterval(1800), join: meet)
        let later = N.event("p2", start: now.addingTimeInterval(7200), join: meet)
        let paused = now.addingTimeInterval(3600)
        let ctx = N.context(now: now, pausedUntil: paused)
        let notes = HeadsUp.desired([early, later], ctx)
        expect(notes.map(\.id) == [HeadsUp.id(later)], "paused 1 h: heads-ups inside the pause skipped, later ones kept")
        let held = [PendingNote(id: HeadsUp.id(early), fingerprint: "x", fireAt: early.start.addingTimeInterval(-60)),
                    PendingNote(id: HeadsUp.snoozeId(key: HeadsUp.key(later)), fingerprint: "s", fireAt: now.addingTimeInterval(60))]
        let plan = HeadsUp.plan(desired: notes, pending: held, liveKeys: HeadsUp.liveKeys([early, later], ctx), pausedUntil: paused)
        expect(plan.remove == [HeadsUp.id(early), HeadsUp.snoozeId(key: HeadsUp.key(later))].sorted(),
               "pausing removes pending heads-ups and snoozes due inside the pause")
        let off = N.context(now: now, meetingsOn: false)
        let offPlan = HeadsUp.plan(desired: HeadsUp.desired([early, later], off), pending: held,
                                   liveKeys: HeadsUp.liveKeys([early, later], off), pausedUntil: nil)
        expect(offPlan.remove.count == 2 && offPlan.add.isEmpty, "setting off removes every heads-up and snooze")
    }

    static func cap() {
        let now = TestCal.labNow
        let events = (0..<70).map { N.event("c\($0)", start: now.addingTimeInterval(300 + Double($0) * 600), join: meet) }
        let notes = HeadsUp.desired(events.reversed(), N.context(now: now))
        expect(HeadsUp.maxScheduled == 60 && notes.count == 60 && notes.first?.id == HeadsUp.id(events[0])
               && notes.last?.id == HeadsUp.id(events[59]), "at most 60 pending (4 slots left for snoozes), soonest first")
        expect(HeadsUp.nextWake(notes, now: now) == events[0].start.addingTimeInterval(-59), "wake just after the soonest fires")
        expect(HeadsUp.nextWake([], now: now) == nil, "nothing scheduled → no wake")
        expect(HeadsUp.isManaged("meet-g1-1") && HeadsUp.isManaged("snooze-g1-1") && !HeadsUp.isManaged("reauth-x")
               && !HeadsUp.isManaged("mail-x-1"), "quit withdraws heads-ups and snoozes only")
    }

    static func dst() {
        let cal = TestCal.lab
        guard let t = cal.timeZone.nextDaylightSavingTimeTransition(after: TestCal.local(2026, 10, 1)) else {
            expect(false, "London has a DST transition in October 2026")
            return
        }
        expect(cal.timeZone.isDaylightSavingTime(for: t.addingTimeInterval(-1)) && !cal.timeZone.isDaylightSavingTime(for: t.addingTimeInterval(1))
               && t < TestCal.local(2026, 10, 31), "London summer time ends 25 Oct 2026 (clocks go back)")
        let first = t.addingTimeInterval(-1800), second = t.addingTimeInterval(1800)
        let wall = { (d: Date) in cal.dateComponents([.day, .hour, .minute], from: d) }
        expect(wall(first) == wall(second), "the hour repeats: two instants, one wall time")
        let now = t.addingTimeInterval(-3 * 3600)
        if case .calendar(let c) = NoteTrigger.at(first, now: now, calendar: cal) {
            expect(cal.date(from: c) == first && c.timeZone == cal.timeZone && c.second == 0, "first pass: calendar trigger, zone attached")
        } else {
            expect(false, "first pass: calendar trigger")
        }
        if case .interval(let seconds) = NoteTrigger.at(second, now: now, calendar: cal) {
            expect(seconds == second.timeIntervalSince(now), "second pass of the repeated hour: interval trigger, right instant")
        } else {
            expect(false, "second pass: interval trigger")
        }
        let e = N.event("dst", start: second.addingTimeInterval(60), join: meet)
        let note = HeadsUp.desired([e], N.context(now: now)).first
        let minuteLater = HeadsUp.desired([e], N.context(now: now.addingTimeInterval(60))).first
        expect(note?.fireAt == second && note?.fingerprint == minuteLater?.fingerprint,
               "repeated-hour heads-up fires at the real instant and doesn't churn as time passes")
        // After the change: a 9:00 meeting on 26 Oct fires at 8:59 local, components in London time.
        let morning = N.event("am", start: TestCal.local(2026, 10, 26, 9, 0), join: meet)
        if case .calendar(let c)? = HeadsUp.desired([morning], N.context(now: TestCal.local(2026, 10, 25, 12, 0))).first?.trigger {
            expect(c.day == 26 && c.hour == 8 && c.minute == 59, "the day after DST: 08:59 local")
        } else {
            expect(false, "the day after DST: calendar trigger")
        }
        // A time-zone change keeps the instant but changes the trigger → the request is replaced.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let labNote = HeadsUp.desired([morning], N.context(now: TestCal.local(2026, 10, 25, 12, 0))).first
        let newYorkNote = HeadsUp.desired([morning], N.context(now: TestCal.local(2026, 10, 25, 12, 0), calendar: newYork)).first
        expect(labNote?.fireAt == newYorkNote?.fireAt && labNote?.fingerprint != newYorkNote?.fingerprint,
               "time zone change → same instant, new fingerprint (re-added)")
    }

    // MARK: - Coordinator

    static func coordinator(_ data: NotifyDataSource, _ center: FakeNoteCenter, _ prefs: NotifyPrefs, _ clock: TestClock,
                            deck: DeckExporter? = nil, trace: Locked<[String]>? = nil, debounce: TimeInterval = 0) -> NotifyCoordinator {
        NotifyCoordinator(data: data, center: center, prefs: prefs, deck: deck, now: clock.closure, calendar: { TestCal.lab },
                          locale: N.posix, debounce: debounce, trace: { event, detail in trace?.mutate { $0.append("\(event) \(detail)") } })
    }

    static func coordinatorPlans() async {
        let clock = TestClock(TestCal.labNow)
        let orb = N.account("avery@orb.example", tag: "ORB")
        let data = StubNotifyData()
        data.people.value = [orb]
        let e1 = N.event("k1", "Call with Milo", start: clock.now.addingTimeInterval(600), join: meet, accounts: [orb.id])
        let e2 = N.event("k2", "Standup", start: clock.now.addingTimeInterval(3600),
                         people: [N.person("avery@orb.example", me: true), N.person("rafa@orb.example")], accounts: [orb.id])
        data.rows.value = [e1, e2]
        let center = FakeNoteCenter()
        center.state = .notDetermined
        let prefs = MemoryNotifyPrefs()
        let traces = Locked<[String]>([])
        let c = coordinator(data, center, prefs, clock, trace: traces)
        await c.refresh()
        expect(center.added.isEmpty, "permission undecided: the pass adds nothing and doesn't wait on the prompt")
        let answered = await eventually(3) { center.pendingIds == [HeadsUp.id(e1), HeadsUp.id(e2)].sorted() }
        expect(answered && center.authorizations == 1, "the answer queues a pass: both scheduled, asked once")
        await c.refresh()
        expect(center.added.count == 2 && center.removedPending.isEmpty, "second refresh: no re-adds")

        // Restart: a new coordinator over the same system state adds nothing.
        let restarted = coordinator(data, center, prefs, clock)
        await restarted.refresh()
        expect(center.added.count == 2 && center.removedPending.isEmpty && center.pendingIds.count == 2,
               "after a restart: no duplicate heads-ups")

        // The system fires e1; later passes never bring it back.
        clock.advance(600 - 60)
        center.fire(until: clock.now)
        await restarted.refresh()
        expect(center.pendingIds == [HeadsUp.id(e2)] && center.added.count == 2 && center.delivered.count == 1,
               "a delivered heads-up isn't scheduled again")

        // Engine not ready, or a failed read: keep what's pending.
        data.rows.value = []
        data.ready.value = false
        await restarted.refresh()
        expect(center.pendingIds == [HeadsUp.id(e2)], "engine not running → nothing removed")
        data.ready.value = true
        data.failing.value = true
        await restarted.refresh()
        expect(center.pendingIds == [HeadsUp.id(e2)], "failed read → nothing removed")
        data.failing.value = false
        await restarted.refresh()
        expect(center.pendingIds.isEmpty, "meeting gone → its heads-up removed")

        // Queue: a burst of changes within the debounce is one pass.
        data.rows.value = [e2]
        let burst = coordinator(data, center, prefs, clock, debounce: 0.3)
        for _ in 0..<5 { burst.changed(.calendar) }
        burst.changed(.accounts)
        let done = await eventually(3) {
            let busy = await burst.isBusy
            let passes = await burst.passes
            return !busy && passes > 0 && center.pendingIds == [HeadsUp.id(e2)]
        }
        let passes = await burst.passes
        expect(done && passes == 1, "a burst of six changes is one pass (\(passes))")

        let lines = traces.value.joined(separator: "\n")
        expect(!lines.contains("Milo") && !lines.contains("@") && !lines.contains("http") && !lines.contains("Standup"),
               "traces carry counts only (no titles, addresses or links)")
    }

    static func snooze() async {
        let clock = TestClock(TestCal.labNow)
        let data = StubNotifyData()
        let e = N.event("gS", "Demo", start: clock.now.addingTimeInterval(60), join: meet)
        data.rows.value = [e]
        let center = FakeNoteCenter()
        let prefs = MemoryNotifyPrefs()
        let c = coordinator(data, center, prefs, clock)
        let info = ["kind": "meeting", "r": "gS", "start": String(HeadsUp.epoch(e.start))]
        let ok = await c.snooze(userInfo: info)
        let id = HeadsUp.snoozeId(key: HeadsUp.key(e))
        let note = center.pendingNote(id)
        expect(ok && note?.fireAt == clock.now.addingTimeInterval(60) && note?.trigger == .interval(60), "snooze: same meeting in 60 s")
        expect(note?.body.hasPrefix("Starting now") == true && note?.category == NoteIds.meetingCategory && note?.userInfo["kind"] == "snooze",
               "snoozed note says it's starting, keeps Join")
        _ = await c.snooze(userInfo: info)
        expect(center.pendingIds == [id], "snoozing again replaces, never stacks")
        let refused = [
            ["r": "https://evil.example/x", "start": info["start"]!],
            ["r": "gS"],
            ["r": "gS", "start": String(HeadsUp.epoch(e.start) + 600)],
            ["r": "nope", "start": info["start"]!],
        ]
        var anyAccepted = false
        for bad in refused {
            if await c.snooze(userInfo: bad) { anyAccepted = true }
        }
        expect(!anyAccepted, "unsafe id, missing or stale start, unknown meeting → ignored")
        var declined = e
        declined.myResponse = .declined
        data.rows.value = [declined]
        let afterDecline = await c.snooze(userInfo: info)
        expect(!afterDecline, "declined meanwhile → no snooze")
        data.rows.value = [e]
        prefs.pausedUntil = clock.now.addingTimeInterval(3600)
        let whilePaused = await c.snooze(userInfo: info)
        expect(!whilePaused, "paused → no snooze")
        prefs.pausedUntil = nil

        // The meeting is deleted: the next pass removes the snooze.
        data.rows.value = []
        await c.refresh()
        expect(center.pendingIds.isEmpty, "snooze of a deleted meeting removed")

        // Join: the link comes from the store and is re-checked.
        data.rows.value = [e, N.event("gX", start: e.start, join: "https://evil.example/j/1"), N.event("gN", start: e.start)]
        let url = await c.joinURL(userInfo: ["r": "gS"])
        let evil = await c.joinURL(userInfo: ["r": "gX"])
        let none = await c.joinURL(userInfo: ["r": "gN"])
        let forged = await c.joinURL(userInfo: ["r": "gS/../x"])
        expect(url?.absoluteString == meet && evil == nil && none == nil && forged == nil,
               "Join opens only the store's allowlisted link")
    }

    static func reauth() async {
        let clock = TestClock(TestCal.labNow)
        let data = StubNotifyData()
        var cmt = N.account("y@cmt.example", tag: "CMT", sort: 1, health: .reauthNeeded)
        let orb = N.account("y@orb.example", tag: "ORB", sort: 0)
        data.people.value = [orb, cmt]
        let center = FakeNoteCenter()
        let prefs = MemoryNotifyPrefs()
        let c = coordinator(data, center, prefs, clock)
        await c.refresh()
        let notes = center.delivered.filter { $0.id.hasPrefix(NoteIds.reauthPrefix) }
        expect(notes.count == 1 && notes.first?.id == "reauth-\(cmt.id.uuidString)", "one notice for the signed-out account")
        expect(notes.first?.title == "CMT signed me out." && notes.first?.body == "One click to fix."
               && notes.first?.category == NoteIds.reauthCategory && notes.first?.trigger == nil
               && notes.first?.userInfo == ["kind": "reauth", "a": cmt.id.uuidString], "text, category (opens Accounts), shown now")
        func reauthCount() -> Int { center.added.filter { $0.id.hasPrefix(NoteIds.reauthPrefix) }.count }
        await c.refresh()
        clock.advance(23 * 3600)
        await c.refresh()
        expect(reauthCount() == 1, "at most once per day")
        let restarted = coordinator(data, center, prefs, clock)
        await restarted.refresh()
        expect(reauthCount() == 1, "a restart doesn't repeat it")
        clock.advance(3600 + 1)
        await restarted.refresh()
        expect(reauthCount() == 2, "still signed out a day later → one reminder")

        // Pause holds it back; it comes once the pause is over.
        var orb2 = orb
        orb2.health = .reauthNeeded
        data.people.value = [orb2, cmt]
        prefs.pausedUntil = clock.now.addingTimeInterval(3600)
        await restarted.refresh()
        expect(reauthCount() == 2, "paused → no notice")
        clock.advance(3601)
        await restarted.refresh()
        expect(reauthCount() == 3 && center.added.last?.title == "ORB signed me out.", "after the pause → sent")

        // Signed back in: the stale notice leaves Notification Center.
        cmt.health = .ok
        data.people.value = [orb2, cmt]
        await restarted.refresh()
        expect(center.removedDelivered.contains("reauth-\(cmt.id.uuidString)") && reauthCount() == 3, "fixed → notice removed")
        let removals = center.removedDelivered.count
        await restarted.refresh()
        expect(center.removedDelivered.count == removals, "withdrawn once, not on every pass")

        // Fixed while the app was quit: the next launch withdraws it from the persisted stamps alone.
        orb2.health = .ok
        data.people.value = [orb2]                       // and CMT's account was removed meanwhile
        let relaunched = coordinator(data, center, prefs, clock)
        await relaunched.refresh()
        expect(center.removedDelivered.suffix(2).sorted() == ["reauth-\(orb.id.uuidString)", "reauth-\(cmt.id.uuidString)"].sorted(),
               "after a restart: notices of fixed or removed accounts withdrawn")
    }

    static func newMail() async {
        let h = Harness("notify-mail")
        let now = h.clock.now
        let cmt = Seed.account(h.db, email: "y@cmt.example", tag: "CMT", sort: 0)
        let orb = Seed.account(h.db, email: "y@orb.example", tag: "ORB", sort: 1)
        h.engine.start()
        let repo = MailRepo(db: h.db)
        try? repo.upsert(N.thread(cmt.id, "old", sender: "Old Sender", at: now.addingTimeInterval(-3600)))
        let center = FakeNoteCenter()
        let prefs = MemoryNotifyPrefs()
        let c = coordinator(EngineNotifyData(engine: { h.engine }), center, prefs, h.clock)
        expect(!prefs.newMailOn, "new-mail notices are off by default")
        await c.mailSynced(cmt.id)
        expect(center.added.isEmpty && prefs.mailSeen(cmt.id) == now.addingTimeInterval(-3600), "first pass sets the watermark, no flood")
        try? repo.upsert(N.thread(cmt.id, "t1", sender: "Milo Smith", at: now.addingTimeInterval(-60)))
        await c.mailSynced(cmt.id)
        expect(center.added.isEmpty && prefs.mailSeen(cmt.id) == now.addingTimeInterval(-60), "setting off → no note, watermark still moves")

        prefs.newMailOn = true
        try? repo.upsert(N.thread(cmt.id, "t2", sender: "Rafa", at: now.addingTimeInterval(-30)))
        try? repo.upsert(N.thread(cmt.id, "t3", sender: "\"Priya K\"", at: now.addingTimeInterval(-20)))
        try? repo.upsert(N.thread(cmt.id, "t4", sender: "Milo Smith", subject: "Re: Proposal", at: now.addingTimeInterval(-10)))
        try? repo.upsert(N.thread(cmt.id, "t5", sender: "Zed", at: now.addingTimeInterval(-5), unread: false))
        await c.mailSynced(cmt.id)
        let note = center.added.last
        expect(center.added.count == 1 && note?.title == "CMT \u{00B7} 3 new: Milo, Priya, \u{2026}" && note?.body == "Re: Proposal",
               "one batched note per account per sync (\(note?.title ?? "-"))")
        expect(note?.thread == "mail-\(cmt.id.uuidString)" && note?.trigger == nil && note?.category == NoteIds.mailCategory
               && note?.userInfo == ["kind": "mail", "a": cmt.id.uuidString], "grouped per account, shown now, opens Inbox")
        await c.mailSynced(cmt.id)
        expect(center.added.count == 1, "nothing new → no note")

        try? repo.upsert(N.thread(cmt.id, "t6", sender: "Rafa", at: now.addingTimeInterval(1)))
        try? repo.upsert(N.thread(cmt.id, "t7", sender: "Rafa", email: "rafa@client.example", at: now.addingTimeInterval(2)))
        await c.mailSynced(cmt.id)
        expect(center.added.last?.title == "CMT \u{00B7} 2 new: Rafa", "one sender → no ellipsis")

        try? repo.upsert(N.thread(orb.id, "m0", sender: "Base", at: now.addingTimeInterval(-100)))
        await c.mailSynced(orb.id)
        try? repo.upsert(N.thread(orb.id, "m1", sender: "nadia@client.example", at: now.addingTimeInterval(3)))
        await c.mailSynced(orb.id)
        expect(center.added.last?.title == "ORB \u{00B7} 1 new: nadia" && center.added.last?.thread == "mail-\(orb.id.uuidString)",
               "per account, address → its name part")

        prefs.pausedUntil = now.addingTimeInterval(3600)
        try? repo.upsert(N.thread(cmt.id, "t8", sender: "Paused Person", at: now.addingTimeInterval(10)))
        let count = center.added.count
        let mark = prefs.mailSeen(cmt.id)
        await c.mailSynced(cmt.id)
        expect(center.added.count == count && prefs.mailSeen(cmt.id) == mark, "paused → no note, watermark held")
        prefs.pausedUntil = nil
        try? repo.upsert(N.thread(cmt.id, "t9", sender: "Theo", at: now.addingTimeInterval(11)))
        await c.mailSynced(cmt.id)
        expect(center.added.count == count + 1 && center.added.last?.title == "CMT \u{00B7} 2 new: Theo, Paused"
               && prefs.mailSeen(cmt.id) == now.addingTimeInterval(11), "after the pause the held mail comes in the next batch")

        // Not permitted, or the add fails: held the same way.
        center.state = .denied
        try? repo.upsert(N.thread(cmt.id, "t10", sender: "Held", at: now.addingTimeInterval(12)))
        await c.mailSynced(cmt.id)
        expect(center.added.count == count + 1 && prefs.mailSeen(cmt.id) == now.addingTimeInterval(11), "denied → held")
        center.state = .authorized
        center.failAdds = true
        await c.mailSynced(cmt.id)
        expect(prefs.mailSeen(cmt.id) == now.addingTimeInterval(11), "add failed → held")
        center.failAdds = false
        await c.mailSynced(cmt.id)
        expect(center.added.last?.title == "CMT \u{00B7} 1 new: Held" && prefs.mailSeen(cmt.id) == now.addingTimeInterval(12),
               "sent on the next pass, then the watermark moves")

        // Through the engine observer: a mail pass posts .mail(id).
        let observed = Locked<[DataChange]>([])
        h.engine.observers.add { change in observed.mutate { $0.append(change) } }
        _ = await h.engine.syncMail(cmt.id)
        expect(observed.value.contains(.mail(cmt.id)), "a mail pass tells the observers")
        await h.engine.stop()
    }

    // MARK: - Deck export

    static func deckAccounts() -> (orb: AccountRecord, cmt: AccountRecord, personal: AccountRecord) {
        (N.account("Avery@OrbitalPickle.Example", tag: "ORB", sort: 0), N.account("avery@quietcomets.example", tag: "CMT", sort: 1),
         N.account(consumerAddress("avery.moonfield"), tag: "Personal", sort: 2))
    }

    static func deckSchema() {
        let now = TestCal.labNow
        let a = deckAccounts()
        let e1 = N.event("g1", "Kickoff", start: now.addingTimeInterval(3600), join: meet,
                         people: [N.person("avery@orbitalpickle.example", me: true), N.person("Milo@Client.example", .needsAction, name: "Milo")],
                         organizer: N.person("milo@client.example", organizer: true, name: "Milo"), accounts: [a.orb.id, a.cmt.id])
        let e2 = N.event("g2", "Focus", start: now.addingTimeInterval(7200), accounts: [a.personal.id])
        let export = DeckExportBuilder.build(events: [e2, e1], accounts: [a.orb, a.cmt, a.personal], now: now)
        guard let data = try? DeckExport.encoder.encode(export),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meetings = json["meetings"] as? [[String: Any]], meetings.count == 2 else {
            expect(false, "deck export encodes")
            return
        }
        expect(Set(json.keys) == ["v", "generatedAt", "myDomains", "meetings"] && json["v"] as? Int == 1, "top-level keys, v = 1")
        expect(json["myDomains"] as? [String] == ["gmail.com", "orbitalpickle.example", "quietcomets.example"], "myDomains: lowercased, sorted")
        let m = meetings[0]
        expect(Set(m.keys) == ["id", "accounts", "provider", "start", "end", "title", "joinURL", "organizer", "attendees", "isExternal"],
               "meeting keys")
        expect(m["id"] as? String == "g1" && m["accounts"] as? [String] == ["ORB", "CMT"] && m["provider"] as? String == "google"
               && m["title"] as? String == "Kickoff" && m["joinURL"] as? String == meet && m["isExternal"] as? Bool == true,
               "id = r, account tags, provider, title, link, external")
        expect(m["start"] as? String == ISO8601DateFormatter().string(from: e1.start), "ISO 8601 UTC times")
        let organizer = m["organizer"] as? [String: Any]
        let attendees = m["attendees"] as? [[String: Any]]
        expect(organizer?["name"] as? String == "Milo" && organizer?["email"] as? String == "milo@client.example", "organizer {name, email}")
        expect(attendees?.count == 2 && attendees?[0]["name"] is NSNull && attendees?[1]["email"] as? String == "milo@client.example"
               && attendees?[1]["response"] as? String == "needsAction" && Set(attendees?.first?.keys.map { $0 } ?? []) == ["name", "email", "response"],
               "attendees {name|null, email (lowercased), response}")
        let solo = meetings[1]
        expect(solo["joinURL"] is NSNull && solo["organizer"] is NSNull && (solo["attendees"] as? [Any])?.isEmpty == true
               && solo["isExternal"] as? Bool == false, "absent values are explicit nulls")
        expect(!(String(data: data, encoding: .utf8) ?? "").contains("\\/"), "links written without escaped slashes")
        expect((try? DeckExport.decoder.decode(DeckExport.self, from: data)) == export, "decodes back to the same export")
    }

    static func deckWindowAndExternal() {
        let now = TestCal.labNow
        let a = deckAccounts()
        let accounts = [a.orb, a.cmt, a.personal]
        let me = N.person("avery@orbitalpickle.example", me: true)
        func ev(_ r: String, _ offset: Double, _ minutes: Double = 30, people: [CalendarEvent.Attendee] = [],
                organizer: CalendarEvent.Attendee? = nil, response: CalendarEvent.Response = .accepted, allDay: Bool = false) -> CalendarEvent {
            N.event(r, start: now.addingTimeInterval(offset * 60), minutes: minutes, join: meet, people: people, organizer: organizer,
                    response: response, allDay: allDay, accounts: [a.orb.id])
        }
        let events = [
            ev("ended10", -40, 30), ev("ended20", -50, 30), ev("ongoing", -60, 90), ev("in47h", 47 * 60), ev("in49h", 49 * 60),
            ev("allday", 60, 24 * 60, allDay: true), ev("declined", 90, response: .declined), ev("ongoing", -60, 90),
        ]
        let ids = DeckExportBuilder.build(events: events, accounts: accounts, now: now).meetings.map(\.id)
        expect(ids == ["ongoing", "ended10", "in47h"], "window [now − 15 min, now + 48 h), timed, not declined, once (\(ids))")

        func external(_ people: [CalendarEvent.Attendee], organizer: CalendarEvent.Attendee? = nil) -> Bool {
            DeckExportBuilder.build(events: [ev("x", 60, people: people, organizer: organizer)], accounts: accounts, now: now)
                .meetings.first?.isExternal ?? false
        }
        expect(!external([me, N.person("juniper@orbitalpickle.example"), N.person("MILO@QUIETCOMETS.EXAMPLE")]), "colleagues only → internal")
        expect(external([me, N.person("milo@client.example")]), "a client → external")
        expect(external([me, N.person(consumerAddress("stranger"))]), "a Gmail stranger isn't a colleague of a Gmail account")
        expect(!external([me, N.person(consumerAddress("avery.moonfield"))]), "my own Gmail address → internal")
        expect(!external([me, N.person("juniper@orbitalpickle.example")], organizer: N.person(googleCalendarID("team"))),
               "group calendar organizer is not a person")
        expect(external([me], organizer: N.person("boss@client.example")), "an outside organizer → external")
        expect(!external([N.person("milo@client.example", me: true)]), "the user's own entry never counts")
    }

    /// Only Deck's own bundle id turns sharing on by default. Fake ids only: the real one is never spelled out.
    static func deckIdentity() {
        expect(DeckIdentity.digest("ABC") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               "deck identity: SHA-256 of the lowercased id, lowercase hex")
        let stored = DeckIdentity.bundleIdDigest
        expect(stored.count == 64 && stored.allSatisfy { "0123456789abcdef".contains($0) }, "deck identity: the stored digest is 64 hex digits")
        let lookalikes: [String?] = [nil, "", "com.example.deck", "com.example.Deck", "org.example.deck.dev", "deck", ".deck",
                                     "com.example.notdeck", "com.example.deck.helper"]
        for id in lookalikes {
            expect(!DeckIdentity.isDeck(bundleId: id), "deck identity: \(id ?? "nil") is not Deck")
        }
        let fake = "org.example.recorder"
        let fakeDigest = DeckIdentity.digest(fake)
        expect(DeckIdentity.isDeck(bundleId: fake, expected: fakeDigest), "deck identity: the id whose digest is stored counts")
        expect(DeckIdentity.isDeck(bundleId: "Org.Example.Recorder", expected: fakeDigest), "deck identity: bundle ids compare without case")
        expect(!DeckIdentity.isDeck(bundleId: " org.example.recorder", expected: fakeDigest), "deck identity: padded ids don't")
        expect(!DeckIdentity.isDeck(bundleId: "org.example.recorder.dev", expected: fakeDigest), "deck identity: a suffix doesn't")
        expect(DeckExportSetting.isOn(stored: nil, deckInstalled: DeckIdentity.isDeck(bundleId: "com.example.deck")) == false,
               "deck identity: a look-alike handler leaves sharing off")
    }

    static func deckWrite() {
        let dir = DataTests.folder("deck-write").appendingPathComponent("share", isDirectory: true)
        let poster = FakeDeckPoster()
        let exporter = DeckExporter(directory: dir, poster: poster)
        let now = TestCal.labNow
        let a = deckAccounts()
        var event = N.event("w1", "Kickoff", start: now.addingTimeInterval(3600), join: meet, accounts: [a.orb.id])
        let first = DeckExportBuilder.build(events: [event], accounts: [a.orb], now: now)
        let wrote = (try? exporter.publish(first)) ?? false
        func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? 0) & 0o777 }
        expect(wrote && poster.posts.value == 1, "first export written and pinged")
        expect(mode(exporter.fileURL) == 0o600 && mode(dir) == 0o700, "file 0600 in a 0700 folder")
        expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == [DeckExport.fileName], "no temp files left behind")
        let read = (try? Data(contentsOf: exporter.fileURL)).flatMap { try? DeckExport.decoder.decode(DeckExport.self, from: $0) }
        expect(read == first, "the file holds the export")

        let later = DeckExportBuilder.build(events: [event], accounts: [a.orb], now: now.addingTimeInterval(60))
        expect((try? exporter.publish(later)) == false && poster.posts.value == 1, "same content, new generatedAt → no write, no ping")
        event.title = "Kickoff (moved)"
        let changed = DeckExportBuilder.build(events: [event], accounts: [a.orb], now: now.addingTimeInterval(120))
        expect((try? exporter.publish(changed)) == true && poster.posts.value == 2, "content changed → write + ping")

        let restarted = DeckExporter(directory: dir, poster: poster)
        expect((try? restarted.publish(changed)) == false && poster.posts.value == 2, "after a restart, unchanged content isn't rewritten")
        chmod(exporter.fileURL.path, 0o644)
        expect((try? restarted.publish(changed)) == true && mode(exporter.fileURL) == 0o600, "loose permissions → rewritten 0600")
        try? FileManager.default.removeItem(at: exporter.fileURL)
        expect((try? restarted.publish(changed)) == true && FileManager.default.fileExists(atPath: exporter.fileURL.path),
               "missing file → rewritten")
        expect(poster.posts.value == 4, "one ping per write")
    }

    static func deckThroughCoordinator() async {
        let clock = TestClock(TestCal.labNow)
        let data = StubNotifyData()
        let orb = N.account("avery@orb.example", tag: "ORB")
        data.people.value = [orb]
        data.rows.value = [N.event("c1", "Old", start: clock.now.addingTimeInterval(-25 * 60), minutes: 15, join: meet, accounts: [orb.id]),
                           N.event("c2", "Next", start: clock.now.addingTimeInterval(3600), join: meet, accounts: [orb.id])]
        let poster = FakeDeckPoster()
        let deck = DeckExporter(directory: DataTests.folder("deck-coordinator"), poster: poster)
        let c = coordinator(data, FakeNoteCenter(), MemoryNotifyPrefs(), clock, deck: deck)
        await c.refresh()
        await c.refresh()
        let first = (try? Data(contentsOf: deck.fileURL)).flatMap { try? DeckExport.decoder.decode(DeckExport.self, from: $0) }
        expect(poster.posts.value == 1 && first?.meetings.map(\.id) == ["c1", "c2"], "refresh exports once, then only on change")
        clock.advance(6 * 60)   // c1 ended 16 min ago now
        await c.refresh()
        let second = (try? Data(contentsOf: deck.fileURL)).flatMap { try? DeckExport.decoder.decode(DeckExport.self, from: $0) }
        expect(poster.posts.value == 2 && second?.meetings.map(\.id) == ["c2"], "the window slides with time")
    }

    // MARK: - Engine observers

    static func engineObservers() async {
        let h = Harness("notify-engine")
        let (orb, token) = h.account("avery@orb.example", tag: "ORB", sort: 0)
        h.google.put(token: token, calendar: "avery@orb.example",
                     G.timed("n1", "Planning call", "2026-10-19T12:00:00+01:00", "2026-10-19T12:30:00+01:00",
                             attendees: [G.me("avery@orb.example", "needsAction"), G.guest("milo@client.example", organizer: true)],
                             organizer: G.organizer("milo@client.example"), video: [meet]))
        h.engine.start()
        let center = FakeNoteCenter()
        let poster = FakeDeckPoster()
        let deck = DeckExporter(directory: h.dir.appendingPathComponent("share", isDirectory: true), poster: poster)
        let c = coordinator(EngineNotifyData(engine: { h.engine }), center, MemoryNotifyPrefs(), h.clock, deck: deck)
        h.engine.observers.add { change in c.changed(change) }
        _ = await h.engine.syncAccount(orb.id, force: true)
        let scheduled = await eventually(3) { center.pendingIds.count == 1 && poster.posts.value == 1 }
        let id = center.pendingIds.first ?? ""
        expect(scheduled && id.hasPrefix("meet-g") && id.hasSuffix("-\(HeadsUp.epoch(TestCal.iso("2026-10-19T12:00:00+01:00")))"),
               "a calendar pass → heads-up scheduled and Deck export written (\(id))")
        let export = (try? Data(contentsOf: deck.fileURL)).flatMap { try? DeckExport.decoder.decode(DeckExport.self, from: $0) }
        expect(export?.meetings.first?.isExternal == true && export?.meetings.first?.accounts == ["ORB"]
               && export?.myDomains == ["orb.example"], "export from the real store")

        // RSVP "no" through the engine: the heads-up goes and the export drops the meeting.
        let key = id.dropFirst(NoteIds.meetingPrefix.count)
        let r = key.lastIndex(of: "-").map { String(key[..<$0]) } ?? ""
        let joined = await c.joinURL(userInfo: ["r": r])
        expect(joined?.absoluteString == meet, "Join resolves the link from the store")
        do { try await h.engine.rsvp(r: r, response: .declined) } catch { expect(false, "rsvp declined: \(error)") }
        let removed = await eventually(3) {
            let left = (try? Data(contentsOf: deck.fileURL)).flatMap { try? DeckExport.decoder.decode(DeckExport.self, from: $0) }
            return center.pendingIds.isEmpty && poster.posts.value >= 2 && left?.meetings.isEmpty == true
        }
        expect(removed, "declined → heads-up removed, export updated")

        // Signed out: the pass marks the account, the next refresh sends the notice.
        h.source.tokens.value[orb.id]?.error.value = AuthError.reauthNeeded(code: "invalid_grant")
        _ = await h.engine.syncAccount(orb.id, force: true)
        let notified = await eventually(3) { center.delivered.contains { $0.id == "reauth-\(orb.id.uuidString)" } }
        expect(notified, "invalid_grant → \u{201C}ORB signed me out.\u{201D}")
        await h.engine.stop()
    }

    static func servicesObserve() async {
        let heard = Locked<[DataChange]>([])
        DataServices.observe { change in heard.mutate { $0.append(change) } }
        let h = Harness("notify-services")
        let engine = DataServices.start(environment: h.env)
        expect(engine.observers.count >= 1, "observers registered before start are attached to the engine")
        engine.accountsChanged()
        expect(heard.value.contains(.accounts), "account edits reach DataServices observers")
        await DataServices.stop()
    }

    // MARK: - Hardening

    static func hardening() async {
        let clock = TestClock(TestCal.labNow)
        let data = StubNotifyData()
        let cmt = N.account("y@cmt.example", tag: "CMT", health: .reauthNeeded)
        data.people.value = [cmt]
        data.rows.value = [N.event("h1", start: clock.now.addingTimeInterval(3600), join: meet, accounts: [cmt.id])]

        // Permission denied: nothing is added, the prompt isn't repeated, turning it on later takes effect.
        let center = FakeNoteCenter()
        center.state = .notDetermined
        center.answer = false
        let prefs = MemoryNotifyPrefs()
        let c = coordinator(data, center, prefs, clock)
        await c.refresh()
        _ = await eventually(3) { center.authorizations == 1 && center.state == .denied }
        await c.refresh()
        clock.advance(NotifyCoordinator.authRecheck - 1)
        await c.refresh()
        expect(center.added.isEmpty && center.authorizations == 1 && prefs.reauthSentAt(cmt.id) == nil,
               "denied: no adds, prompted once, re-auth not marked as sent")
        center.state = .authorized   // switched on in System Settings
        await c.refresh()
        expect(center.authorizations == 1 && center.pendingIds.count == 1 && center.delivered.count == 1,
               "switched on in System Settings → the next pass sends (no new prompt)")

        // An ignored prompt never freezes the passes: the Deck export still updates.
        let ignoring = FakeNoteCenter()
        ignoring.state = .notDetermined
        ignoring.promptIgnored = true
        let poster = FakeDeckPoster()
        let deck = DeckExporter(directory: DataTests.folder("deck-ignored-prompt"), poster: poster)
        let c3 = coordinator(data, ignoring, MemoryNotifyPrefs(), clock, deck: deck)
        await c3.refresh()
        await c3.refresh()
        expect(poster.posts.value == 1 && ignoring.authorizations == 1 && ignoring.added.isEmpty,
               "prompt unanswered: passes finish, export written, no second prompt")

        // The system doesn't answer the pending read: no plan this pass (nothing removed or doubled).
        center.pendingUnavailable = true
        data.rows.value = []
        await c.refresh()
        expect(center.pendingIds.count == 1 && center.removedPending.isEmpty, "pending unknown → heads-ups left alone")
        center.pendingUnavailable = false

        // A failed re-auth add leaves no stamp, so the next pass retries.
        let failing = FakeNoteCenter()
        failing.failAdds = true
        let prefs2 = MemoryNotifyPrefs()
        let c2 = coordinator(data, failing, prefs2, clock)
        await c2.refresh()
        expect(prefs2.reauthSentAt(cmt.id) == nil, "failed notice → not marked as sent")
        failing.failAdds = false
        await c2.refresh()
        expect(failing.delivered.count == 1 && prefs2.reauthSentAt(cmt.id) == clock.now, "retried on the next pass")

        // Stored moments: Date or epoch number (another surface may write either).
        let at = Date(timeIntervalSince1970: 1_792_404_301)
        expect(DefaultsNotifyPrefs.date(at) == at && DefaultsNotifyPrefs.date(NSNumber(value: 1_792_404_301.0)) == at
               && DefaultsNotifyPrefs.date(1_792_404_301) == at && DefaultsNotifyPrefs.date("soon") == nil && DefaultsNotifyPrefs.date(nil) == nil,
               "pausedUntil reads a Date or epoch seconds")

        // Deck: separate invites to one call are one meeting with both tags; untagged accounts show their name.
        let orb = N.account("y@orb.example", tag: "ORB")
        var personal = N.account(consumerAddress("y"), tag: "  ", sort: 2)
        personal.displayName = "Personal"
        let start = clock.now.addingTimeInterval(3600)
        let export = DeckExportBuilder.build(events: [N.event("a1", start: start, join: meet, accounts: [orb.id]),
                                                      N.event("b1", start: start, join: meet, accounts: [personal.id]),
                                                      N.event("c1", start: start, join: "https://zoom.us/j/7", accounts: [personal.id])],
                                             accounts: [orb, personal], now: clock.now)
        expect(export.meetings.map(\.id) == ["a1", "c1"] && export.meetings.first?.accounts == ["ORB", "Personal"]
               && export.meetings.last?.accounts == ["Personal"], "same call once (tags merged); empty tag → account name")

        // Deck: a temp file a crash left behind is swept on the first write of a run.
        let dir = DataTests.folder("deck-sweep")
        let stale = dir.appendingPathComponent(".\(DeckExport.fileName).123.abcd1234.tmp")
        FileManager.default.createFile(atPath: stale.path, contents: Data("x".utf8))
        let exporter = DeckExporter(directory: dir, poster: FakeDeckPoster())
        _ = try? exporter.publish(export)
        expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == [DeckExport.fileName], "stale temp files swept")

        // Deck: a symlink planted at the export path is replaced by a real 0600 file, never followed.
        let target = dir.appendingPathComponent("elsewhere.json")
        FileManager.default.createFile(atPath: target.path, contents: Data("keep".utf8))
        try? FileManager.default.removeItem(at: exporter.fileURL)
        try? FileManager.default.createSymbolicLink(at: exporter.fileURL, withDestinationURL: target)
        let rewrote = (try? DeckExporter(directory: dir, poster: FakeDeckPoster()).publish(export)) ?? false
        var info = stat()
        lstat(exporter.fileURL.path, &info)
        expect(rewrote && (info.st_mode & S_IFMT) == S_IFREG && (try? String(contentsOf: target, encoding: .utf8)) == "keep",
               "symlink replaced, its target untouched")
    }

    // MARK: - Permission never latched, cap wake, quit and uninstall

    static func lifecycle() async {
        let clock = TestClock(TestCal.labNow)
        let data = StubNotifyData()
        let e = N.event("rv", start: clock.now.addingTimeInterval(3600), join: meet)
        data.rows.value = [e]

        // Permission read every pass: revoked in System Settings → nothing added; back on → added.
        let center = FakeNoteCenter()
        let c = coordinator(data, center, MemoryNotifyPrefs(), clock)
        center.state = .denied
        await c.refresh()
        expect(center.added.isEmpty, "denied → nothing added")
        center.state = .authorized
        await c.refresh()
        expect(center.pendingIds == [HeadsUp.id(e)], "allowed again → added at once")
        center.state = .denied
        data.rows.value = [e, N.event("rv2", start: clock.now.addingTimeInterval(7200), join: meet)]
        await c.refresh()
        expect(center.pendingIds == [HeadsUp.id(e)] && center.authorizations == 0, "revoked later → no more adds, never prompted")

        // A snooze arriving while a pass waits on the status read is not lost.
        center.state = .authorized
        center.statusDelay = 0.3
        data.rows.value = [e, N.event("rv3", start: clock.now.addingTimeInterval(9000), join: meet)]
        let pass = Task { await c.refresh() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let snoozed = await c.snooze(userInfo: ["r": "rv", "start": String(HeadsUp.epoch(e.start))])
        await pass.value
        center.statusDelay = 0
        expect(snoozed && center.pendingIds.contains(HeadsUp.snoozeId(key: HeadsUp.key(e))), "snooze during a status read still lands")

        // Undecided and the prompt dismissed without a choice: asked again only after 10 minutes.
        let undecided = FakeNoteCenter()
        undecided.state = .notDetermined
        undecided.answerDecides = false
        let u = coordinator(data, undecided, MemoryNotifyPrefs(), clock)
        await u.refresh()
        _ = await eventually(3) { undecided.authorizations == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await u.refresh()
        expect(undecided.authorizations == 1 && undecided.added.isEmpty, "no second prompt within 10 minutes")
        clock.advance(NotifyCoordinator.authRecheck + 1)
        await u.refresh()
        let again = await eventually(3) { undecided.authorizations == 2 }
        expect(again, "asked again after 10 minutes")

        // Cap: 61 meetings → 60 pending; after the soonest fires, the wake pass schedules the 61st.
        let capClock = TestClock(TestCal.labNow)
        let many = (0..<61).map { N.event("m\($0)", start: capClock.now.addingTimeInterval(300 + Double($0) * 600), join: meet) }
        data.rows.value = many
        let capCenter = FakeNoteCenter()
        let capped = coordinator(data, capCenter, MemoryNotifyPrefs(), capClock)
        await capped.refresh()
        let wake = await capped.nextWake
        expect(capCenter.pendingIds.count == 60 && !capCenter.pendingIds.contains(HeadsUp.id(many[60]))
               && wake == many[0].start.addingTimeInterval(-59), "60 scheduled, wake armed just after the first fires")
        capClock.set(wake ?? capClock.now)
        capCenter.fire(until: capClock.now)
        await capped.refresh()
        let nextWake = await capped.nextWake
        expect(capCenter.pendingIds.count == 60 && capCenter.pendingIds.contains(HeadsUp.id(many[60]))
               && nextWake == many[1].start.addingTimeInterval(-59), "the 61st meeting gets the freed slot; wake moves on")

        // Uninstall: the Deck export is withdrawn (file gone, then the ping).
        let poster = FakeDeckPoster()
        let deck = DeckExporter(directory: DataTests.folder("deck-withdraw"), poster: poster)
        _ = try? deck.publish(DeckExportBuilder.build(events: [e], accounts: [], now: clock.now))
        let removed = deck.withdraw()
        expect(removed && !FileManager.default.fileExists(atPath: deck.fileURL.path) && poster.posts.value == 2,
               "withdraw deletes the file and pings")
        expect(!deck.withdraw() && poster.posts.value == 3, "withdrawing again is harmless (still pings)")
        expect((try? deck.publish(DeckExportBuilder.build(events: [e], accounts: [], now: clock.now))) == true,
               "a later export writes again")
    }
}
