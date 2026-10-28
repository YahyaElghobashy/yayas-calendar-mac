import Foundation

/// The router's decisions (RouteDecisions.swift): parameter validation, link keys, the join allowlist,
/// hide + front-app restore.
enum RouterTests {
    static let verify: (String, String) -> Bool = { FixtureLinkKeys.verify(r: $0, k: $1) }

    static func decide(_ url: String) -> RouteAction {
        guard let route = Route.parse(URL(string: url)!) else { return .ignore(route: "?", reason: "unparsed") }
        return RouteDecider.decide(route, verify: verify)
    }

    static func run() {
        widgetState()
        refresh()
        keyed()
        other()
        join()
        hideAndRestore()
    }

    static func widgetState() {
        T.section("router: page / day / month / range")
        T.equal(decide("yayacal://page?w=agenda.all&fam=L&to=2"), .page(kind: "agenda.all", family: "L", to: 2), "page")
        T.equal(decide("yayacal://page?w=custom.c&fam=XLP&to=3"), .page(kind: "custom.c", family: "XLP", to: 3), "custom slot page")
        T.equal(decide("yayacal://page?w=agenda.all&fam=XXL&to=2"), .ignore(route: "page", reason: "bad-family"), "unknown family")
        T.equal(decide("yayacal://page?w=upnext&fam=L&to=2"), .ignore(route: "page", reason: "bad-kind"), "family the kind lacks")
        T.equal(decide("yayacal://page?w=nope&fam=L&to=2"), .ignore(route: "page", reason: "bad-kind"), "unknown kind")
        T.equal(decide("yayacal://page?w=agenda.all&fam=L&to=0"), .ignore(route: "page", reason: "bad-page"), "page 0")
        T.equal(decide("yayacal://page?w=agenda.all&fam=L&to=100"), .ignore(route: "page", reason: "bad-page"), "page 100")
        T.equal(decide("yayacal://page?w=agenda.all&fam=L&to=two"), .ignore(route: "page", reason: "bad-page"), "page text")
        T.equal(decide("yayacal://page?fam=L&to=2"), .ignore(route: "page", reason: "bad-kind"), "missing kind")
        T.equal(decide("yayacal://day?w=month&d=2026-10-21"), .selectDay(kind: "month", day: "2026-10-21"), "day")
        T.equal(decide("yayacal://day?w=month&d=2026-02-30"), .ignore(route: "day", reason: "bad-day"), "impossible day")
        T.equal(decide("yayacal://day?w=month"), .ignore(route: "day", reason: "bad-day"), "missing day")
        T.equal(decide("yayacal://month?w=month&to=2026-11"), .showMonth(kind: "month", month: "2026-11"), "month")
        T.equal(decide("yayacal://month?w=month&to=2026-13"), .ignore(route: "month", reason: "bad-month"), "month 13")
        T.equal(decide("yayacal://range?w=agenda.all&v=2"), .setRange(kind: "agenda.all", days: 2), "range 2")
        T.equal(decide("yayacal://range?w=agenda.all&v=3"), .ignore(route: "range", reason: "bad-range"), "range 3")
        T.equal(decide("yayacal://sync"), .sync(kind: nil), "sync (every account)")
        T.equal(decide("yayacal://open/day?w=month&d=2026-10-21"), .openDay(kind: "month", day: "2026-10-21"), "open/day")
        T.equal(decide("yayacal://open/day?w=month&d=21-10-2026"), .ignore(route: "open/day", reason: "bad-day"), "open/day bad day")
    }

    /// A widget's ↻: `sync?w=<kind>`, the 5 s debounce, and the hand-back cap.
    static func refresh() {
        T.section("router: sync?w (refresh glyph) + debounce")
        T.equal(decide("yayacal://sync?w=agenda.all"), .sync(kind: "agenda.all"), "sync?w=agenda.all")
        T.equal(decide("yayacal://sync?w=custom.f"), .sync(kind: "custom.f"), "custom slot refresh")
        T.equal(decide("yayacal://sync?w=month&w=inbox.all"), .sync(kind: "month"), "first w wins")
        T.equal(decide("yayacal://sync?w=nope"), .ignore(route: "sync", reason: "bad-kind"), "unknown kind ignored")
        T.equal(decide("yayacal://sync?w=a%20b"), .sync(kind: nil), "unsafe w dropped at parse → plain sync")
        T.equal(decide("yayacal://sync?k=x&w=upnext"), .sync(kind: "upnext"), "other params ignored")
        for spec in WidgetKinds.all {
            let url = YayaLink.sync(kind: spec.kind)
            T.equal(url.absoluteString, "yayacal://sync?w=\(spec.kind)", "builder: \(spec.kind)")
            T.equal(decide(url.absoluteString), .sync(kind: spec.kind), "round trip: \(spec.kind)")
            T.equal(Route.parse(url)?.quiet, true, "refresh is quiet: \(spec.kind)")
        }
        T.equal(YayaLink.sync().absoluteString, "yayacal://sync", "plain sync builder unchanged")
        T.equal(WidgetLinkContext(kind: "month", family: .small).refresh(), YayaLink.sync(kind: "month"),
                "the glyph links its own kind")

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var gate = RefreshDebounce()
        T.check(gate.admit("agenda.all", at: t0), "first tap runs")
        T.check(!gate.admit("agenda.all", at: t0.addingTimeInterval(0.3)), "double tap ignored")
        T.check(!gate.admit("agenda.all", at: t0.addingTimeInterval(4.9)), "still inside 5 s → ignored")
        T.check(gate.admit("month", at: t0.addingTimeInterval(1)), "another kind runs")
        T.check(gate.admit("agenda.all", at: t0.addingTimeInterval(5)), "5 s later it runs again")
        T.check(!gate.admit("agenda.all", at: t0.addingTimeInterval(6)), "…and the window restarts from that run")
        T.check(gate.admit("agenda.all", at: t0.addingTimeInterval(-60)), "clock moved back → runs (never stuck)")
        T.equal(RefreshDebounce.window, 5, "debounce window 5 s")
        T.check(RefreshPolicy.handBackCap <= 5, "a refresh holds the hand-back 5 s at most")
        T.equal(RouteAction.sync(kind: "month").name, "sync", "trace name")
    }

    static func keyed() {
        T.section("router: link keys (join / rsvp / open/event / reauth)")
        let r = "ev2", k = FixtureLinkKeys.k("ev2"), other = FixtureLinkKeys.k("ev3")
        T.equal(decide("yayacal://join?r=\(r)&k=\(k)"), .join(r: r), "join with a good key")
        T.equal(decide("yayacal://join?r=\(r)&k=\(other)"), .ignore(route: "join", reason: "bad-key"), "join with another row's key")
        T.equal(decide("yayacal://join?r=\(r)"), .ignore(route: "join", reason: "missing-param"), "join without a key")
        let tampered = String(k.dropLast()) + (k.last == "A" ? "B" : "A")
        T.equal(decide("yayacal://join?r=\(r)&k=\(tampered)"), .ignore(route: "join", reason: "bad-key"), "tampered key")
        T.equal(decide("yayacal://open/event?r=\(r)&k=\(k)"), .openEvent(r: r), "open/event")
        T.equal(decide("yayacal://open/event?r=\(r)&k=x"), .ignore(route: "open/event", reason: "bad-key"), "open/event forged")
        T.equal(decide("yayacal://rsvp?r=\(r)&k=\(k)&v=yes"), .rsvp(r: r, response: .accepted), "rsvp yes")
        T.equal(decide("yayacal://rsvp?r=\(r)&k=\(k)&v=maybe"), .rsvp(r: r, response: .tentative), "rsvp maybe")
        T.equal(decide("yayacal://rsvp?r=\(r)&k=\(k)&v=no"), .rsvp(r: r, response: .declined), "rsvp no")
        T.equal(decide("yayacal://rsvp?r=\(r)&k=\(k)&v=perhaps"), .ignore(route: "rsvp", reason: "bad-reply"), "rsvp unknown answer")
        T.equal(decide("yayacal://rsvp?r=\(r)&k=\(other)&v=yes"), .ignore(route: "rsvp", reason: "bad-key"), "rsvp forged")
        let a = FixtureAccounts.cmt.uuidString
        T.equal(decide("yayacal://reauth?a=\(a)&k=\(FixtureLinkKeys.k(a))"), .reauth(account: a), "reauth")
        T.equal(decide("yayacal://reauth?a=\(a)&k=\(k)"), .ignore(route: "reauth", reason: "bad-key"), "reauth forged")
        var verified: [String] = []
        _ = RouteDecider.decide(Route.parse(URL(string: "yayacal://page?w=agenda.all&fam=L&to=2")!)!) { r, _ in verified.append(r); return true }
        T.equal(verified, [], "unkeyed routes never consult the key")
        T.equal(RouteDecider.rsvpResponse("Accepted"), .accepted, "Google's own words work")
    }

    static func other() {
        T.section("router: ping / open/app / every route handled / unknown")
        T.equal(decide("yayacal://ping?probe=p1"), .ping("p1"), "ping")
        T.equal(decide("yayacal://ping"), .ping("-"), "ping without probe")
        T.equal(decide("yayacal://open/app?section=widgets"), .openApp(.widgets), "open/app widgets")
        T.equal(decide("yayacal://open/app?section=moon"), .openApp(nil), "open/app unknown section → main window")
        T.equal(decide("yayacal://mail/read?r=t&k=k"), .ignore(route: "mail/read", reason: "bad-key"), "mail routes check the key")
        T.equal(decide("yayacal://open/message?r=t&k=k"), .ignore(route: "open/message", reason: "bad-key"), "open/message checks the key")
        T.equal(decide("yayacal://launch/missiles"), .ignore(route: "launch/missiles", reason: "unknown-route"), "unknown route")
        for spec in RouteTable.all {
            let action = decide(YayaLink.url(spec.name, spec.params.map { ($0, "x") }).absoluteString)
            T.check(action.name == spec.name || action.name == "ignore", "\(spec.name) is handled (got \(action.name))")
        }
    }

    static func join() {
        T.section("router: join allowlist (re-checked before opening)")
        let allowed = [
            "https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/j/1234567890", "https://zoom.us/j/1",
            "https://teams.microsoft.com/l/meetup-join/x", "https://teams.live.com/meet/1", "https://acme.webex.com/meet/demo",
            "https://whereby.com/room", "https://app.slack.com/huddle/T1/C1", "https://meet.goto.com/123", "https://app.chime.aws/meetings/1",
            "https://meet.jit.si/Room", "https://MEET.GOOGLE.COM/abc", "https://meet.google.com./abc",
        ]
        for s in allowed { T.check(JoinPolicy.isAllowed(URL(string: s)), "allowed: \(s)") }
        let blocked = [
            "http://meet.google.com/abc", "https://meet.google.com.evil.example/abc", "https://evilzoom.us/j/1",
            "https://user:pw!@meet.google.com/abc", "https://meet.google.com:8443/abc", "https://google.com/meet",
            "javascript:alert(1)", "file:///etc/hosts", "ftp://zoom.us/x", "https://zoom.us.example.com/j/1", "https://example.com/?u=https://meet.google.com",
        ]
        for s in blocked { T.check(!JoinPolicy.isAllowed(URL(string: s)), "blocked: \(s)") }
        T.check(!JoinPolicy.isAllowed(nil), "no URL")
        T.equal(JoinPolicy.providerName(URL(string: "https://meet.google.com/x")), "Google Meet", "Meet name")
        T.equal(JoinPolicy.providerName(URL(string: "https://us02web.zoom.us/j/1")), "Zoom", "Zoom name")
        T.equal(JoinPolicy.providerName(URL(string: "http://zoom.us/j/1")), nil, "no name for blocked links")
        for e in SnapshotFixtures.events() where e.joinURL != nil {
            T.check(JoinPolicy.isAllowed(e.joinURL), "fixture join link allowed: \(e.title)")
        }
    }

    static func hideAndRestore() {
        T.section("router: hide after quiet links")
        T.equal(HidePolicy.shouldHide(isActive: true, cold: true, activeAtReceipt: true, sinceActivation: 99), true, "cold launch by the link")
        T.equal(HidePolicy.shouldHide(isActive: true, cold: false, activeAtReceipt: false, sinceActivation: 99), true, "link activated us")
        T.equal(HidePolicy.shouldHide(isActive: true, cold: false, activeAtReceipt: true, sinceActivation: 0.3), true, "activated just now")
        T.equal(HidePolicy.shouldHide(isActive: true, cold: false, activeAtReceipt: true, sinceActivation: 30), false, "user was already in our window")
        T.equal(HidePolicy.shouldHide(isActive: false, cold: true, activeAtReceipt: false, sinceActivation: 0), false, "open -g: never active")

        T.section("router: front-app restore (an early build restored only 3 of 8 times)")
        let own: Int32 = 500
        var memory = FrontAppMemory(ownPid: own)
        memory.didActivate(pid: 100, bundleId: "com.apple.Safari")
        T.equal(memory.lastPid, 100, "remembers the user's app")
        memory.didActivate(pid: own, bundleId: "com.yahyaelghobashy.yayascalendar")
        T.equal(memory.lastPid, 100, "a widget tap activating us is ignored")
        T.equal(memory.lastBundleId, "com.apple.Safari", "…bundle id too")
        memory.didActivate(pid: 0, bundleId: nil)
        T.equal(memory.lastPid, 100, "pid 0 ignored")
        let running: (Int32) -> Bool = { $0 == 100 || $0 == 200 }
        T.equal(memory.target(isRunning: running), 100, "target = the user's app")
        T.equal(FrontRestorePolicy.shouldRestore(agentWasActivated: true, target: 100, frontmost: own), true, "we're in front → give it back")
        T.equal(FrontRestorePolicy.shouldRestore(agentWasActivated: true, target: 100, frontmost: 100), false, "already back → nothing")
        T.equal(FrontRestorePolicy.shouldRestore(agentWasActivated: false, target: 100, frontmost: own), false, "not activated by the link")
        T.equal(FrontRestorePolicy.shouldRestore(agentWasActivated: true, target: nil, frontmost: own), false, "nobody to restore")
        memory.didActivate(pid: 200, bundleId: "com.apple.finder")
        T.equal(memory.target(isRunning: running), 200, "follows the latest other app")
        memory.didTerminate(pid: 200)
        T.equal(memory.target(isRunning: running), nil, "a quit app is forgotten")
        memory.didActivate(pid: 300, bundleId: "x")
        T.equal(memory.target(isRunning: running), nil, "not running → no target")

        // Eight taps: whatever order activations arrive in, the target is the user's app.
        var taps = FrontAppMemory(ownPid: own)
        taps.didActivate(pid: 100, bundleId: "user.app")
        var restored = 0
        for i in 0..<8 {
            taps.didActivate(pid: own, bundleId: "us")          // the Link activates the agent
            if i % 2 == 0 { taps.didActivate(pid: own, bundleId: "us") }
            let target = taps.target(isRunning: running)
            if FrontRestorePolicy.shouldRestore(agentWasActivated: true, target: target, frontmost: own), target == 100 {
                restored += 1
                taps.didActivate(pid: 100, bundleId: "user.app")  // the restore lands
            }
        }
        T.equal(restored, 8, "8 of 8 taps hand the front back to the user's app")

        T.section("router: what follows a batch")
        T.equal(FrontRestorePolicy.follow([.quiet]), .hideAndRestore, "quiet → hide + restore")
        T.equal(FrontRestorePolicy.follow([.nothing]), .hideAndRestore, "ignored link → hide + restore")
        T.equal(FrontRestorePolicy.follow([.peek]), .restoreKeepPeek, "Peek → restore, keep the panel")
        T.equal(FrontRestorePolicy.follow([.quiet, .peek]), .restoreKeepPeek, "Peek wins over quiet")
        T.equal(FrontRestorePolicy.follow([.peek, .window]), .stay, "a window wins: stay in front")
        T.equal(FrontRestorePolicy.follow([]), .stay, "empty batch → nothing")
        T.equal(FrontRestorePolicy.follow([.handedOff]), .stay, "Join opened the meeting: its app takes the front, no restore")
        T.equal(FrontRestorePolicy.follow([.quiet, .handedOff]), .stay, "…even batched with a quiet link")

        T.section("router: hand the front back right after the work")
        func when(_ active: Bool, cold: Bool = false, recv: Bool = true, since: TimeInterval = 0.2, on: Bool = true) -> HandBackPolicy.When {
            HandBackPolicy.when(isActive: active, cold: cold, activeAtReceipt: recv, sinceActivation: since, immediate: on)
        }
        T.equal(when(true), .now, "a real click on a warm agent: now (was 250 ms later)")
        T.equal(when(true, cold: true), .later, "cold launch: the 250 ms check (windows may still be coming up)")
        T.equal(when(true, recv: false), .later, "link arrived before the activation: the 250 ms check")
        T.equal(when(false, recv: false), .later, "open -g: never active, the check decides (no hide)")
        T.equal(when(true, since: 30), .later, "already in our window: the check keeps us in front")
        T.equal(when(true, on: false), .later, "the switch off restores the old timing")
        T.check(HandBackPolicy.immediate, "on by default")

        MainActor.assumeIsolated { deferredFlush() }
    }

    /// The flush after a batch waits 1.5 s; a quit inside that delay runs it instead of dropping it.
    @MainActor
    static func deferredFlush() {
        T.section("router: the deferred flush survives a quit")
        var flushes = 0
        let flush = DeferredFlush(delay: 60) { flushes += 1 }
        T.check(!flush.runPending() && flushes == 0, "nothing pending: a quit flushes nothing")
        flush.schedule()
        flush.schedule()
        T.check(flush.isPending && flushes == 0, "two batches: one flush pending, not run yet")
        T.check(flush.runPending() && flushes == 1 && !flush.isPending, "a quit inside the delay runs it at once, once")
        T.check(!flush.runPending() && flushes == 1, "…and never twice (the timer is cancelled)")
    }
}
