import Foundation

/// Join with Fathom (D-045): the links and their stored form, reading which account Fathom is signed into, which
/// Fathom account a meeting records to, Fathom's capture link, the session (record now, wait for the switch,
/// time out, record anyway, join only), the words, the popover card, the `record` route and the snapshot's `rec`.
/// Fakes and memory bags only: no Fathom files, no user defaults, nothing opened.
@MainActor
enum FathomTests {
    static let now = WidgetSample.fixedNow
    static let orbMail = "avery@orbitalpickle.example"
    static let cmtMail = "avery@quietcomets.example"
    static let homeMail = "avery@home.example"
    static let meet = URL(string: "https://meet.google.com/abc-defg-hij")!

    static func run() {
        links()
        signIn()
        routing()
        captureURL()
        sessionRecordsNow()
        sessionWaitsForSwitch()
        sessionTimesOut()
        sessionUnknownAndJoinOnly()
        sessionRefuses()
        words()
        linksModel()
        popoverCard()
        route()
        snapshot()
    }

    // MARK: Helpers

    final class Fake {
        var installed = true
        var signIn: FathomSignIn = .signedIn(FathomTests.orbMail)
        var links: [UUID: FathomLink] = [:]
        var opened: [URL] = []
        var clock = FathomTests.now
        var tick: (@MainActor () -> Void)?
        var stops = 0
    }

    static func session(_ f: Fake) -> FathomSession {
        FathomSession(env: FathomSession.Environment(
            installed: { f.installed }, signIn: { f.signIn }, link: { f.links[$0] ?? .ownAddress },
            open: { f.opened.append($0); return true }, after: { _, work in work() },
            every: { _, work in f.tick = work; return { f.stops += 1 } }, clock: { f.clock }))
    }

    static func event(_ accounts: [UUID] = [FixtureAccounts.orb], join: URL? = FathomTests.meet, r: String = "g-fathom") -> CalendarEvent {
        CalendarEvent(r: r, accountIds: accounts, calendarName: "Work", title: "Weekly sync", start: now.addingTimeInterval(240),
                      end: now.addingTimeInterval(2040), allDay: false, location: nil, joinURL: join, webURL: nil, notes: nil,
                      organizer: nil, attendees: [], myResponse: .accepted, clashes: false)
    }

    static let directory = FixtureAccounts.directory()

    static func config(_ account: String) -> Data { Data(#"{"protocolVersion":1,"hostName":"video.fathom.chrome_extension_bridge.42","account":\#(account)}"#.utf8) }
    static let manifests = ["video.fathom.chrome_extension_bridge.json", "video.fathom.chrome_extension_bridge.42.json"]

    // MARK: Links

    static func links() {
        T.section("fathom: links and their stored form")
        T.equal(FathomLink(stored: nil), .ownAddress, "absent = the account's own address")
        T.equal(FathomLink(stored: "off"), .off, "off")
        T.equal(FathomLink(stored: "addr:Avery@Orbitalpickle.Example "), .address(orbMail), "another address, normalized")
        T.equal(FathomLink(stored: "addr:not an address"), .ownAddress, "a broken address falls back to the account's own")
        T.equal(FathomLink.ownAddress.stored, nil, "own address stores nothing")
        T.equal(FathomLink.address(orbMail).stored, "addr:" + orbMail, "address round trip")
        T.equal(FathomLink.ownAddress.email(account: "Avery@Home.Example"), homeMail, "own address lowercased")
        T.equal(FathomLink.off.email(account: homeMail), nil, "off has no address")
        for bad in ["", "avery", "a@b", "a@@b.example", "a b@c.example", "@c.example", "a@.example", "a@c.example.", "a@c\u{0007}.example"] {
            T.equal(FathomAddress.normalized(bad), nil, "not one address: \(bad.debugDescription)")
        }
        T.equal(FathomAddress.normalized(String(repeating: "a", count: 250) + "@c.example"), nil, "longer than 254")
        let bag = MemoryBag()
        T.equal(FathomPrefs.link(FixtureAccounts.cmt, bag), .ownAddress, "default link")
        FathomPrefs.setLink(.off, for: FixtureAccounts.cmt, bag)
        T.equal(FathomPrefs.link(FixtureAccounts.cmt, bag), .off, "stored off")
        T.equal(bag.object(FathomPrefs.linkKey(FixtureAccounts.cmt)) as? String, "off", "key holds the account's UUID")
        FathomPrefs.setLink(.ownAddress, for: FixtureAccounts.cmt, bag)
        T.check(bag.object(FathomPrefs.linkKey(FixtureAccounts.cmt)) == nil, "own address removes the key")
        T.check(!FathomPrefs.hotkeyRecords(bag), "⌃⌥J records: off by default")
        FathomPrefs.setHotkeyRecords(true, bag)
        T.check(FathomPrefs.hotkeyRecords(bag), "⌃⌥J records: on")
        FathomPrefs.setHotkeyRecords(false, bag)
        T.check(bag.object(FathomPrefs.hotkeyKey) == nil, "off removes the key")
    }

    // MARK: Which account Fathom is on

    static func signIn() {
        T.section("fathom: which account the Fathom app is signed into")
        let account = #"{"userId":42,"email":"Avery@OrbitalPickle.example"}"#
        T.equal(FathomSignIn.parse(config: config(account), manifests: manifests), .signedIn(orbMail), "signed in, manifest present")
        T.equal(FathomSignIn.parse(config: config(account), manifests: ["video.fathom.chrome_extension_bridge.json"]), .unknown,
                "no manifest for that user: maybe stale, so unknown")
        T.equal(FathomSignIn.parse(config: config(account), manifests: nil), .unknown, "manifests unreadable → unknown")
        T.equal(FathomSignIn.parse(config: config("null"), manifests: manifests), .signedOut, "account null = signed out")
        T.equal(FathomSignIn.parse(config: nil, manifests: manifests), .unknown, "no file → unknown")
        T.equal(FathomSignIn.parse(config: Data("[]".utf8), manifests: manifests), .unknown, "not an object")
        T.equal(FathomSignIn.parse(config: Data("{oops".utf8), manifests: manifests), .unknown, "not JSON")
        T.equal(FathomSignIn.parse(config: Data(#"{"protocolVersion":2}"#.utf8), manifests: manifests), .unknown,
                "no account key (a newer format) → unknown")
        T.equal(FathomSignIn.parse(config: config(#"{"userId":42}"#), manifests: manifests), .unknown, "no address")
        T.equal(FathomSignIn.parse(config: config(#"{"userId":"42","email":"avery@orbitalpickle.example"}"#), manifests: manifests),
                .unknown, "id that isn't a number")
        T.equal(FathomSignIn.parse(config: config(#"{"userId":42,"email":"nobody"}"#), manifests: manifests), .unknown, "not an address")
        let mismatch = Data(#"{"hostName":"video.fathom.chrome_extension_bridge.7","account":{"userId":42,"email":"avery@orbitalpickle.example"}}"#.utf8)
        T.equal(FathomSignIn.parse(config: mismatch, manifests: manifests + ["video.fathom.chrome_extension_bridge.7.json"]), .unknown,
                "host name for another user → unknown")
        let noHost = Data(#"{"account":{"userId":42,"email":"avery@orbitalpickle.example"}}"#.utf8)
        T.equal(FathomSignIn.parse(config: noHost, manifests: manifests), .signedIn(orbMail), "no hostName key: the manifest decides")
        var big = config(account)
        big.append(Data(repeating: 0x20, count: FathomSignIn.configLimit))
        T.equal(FathomSignIn.parse(config: big, manifests: manifests), .unknown, "over 64 KB → unknown")
        let target = FathomTarget(accountId: FixtureAccounts.orb, tag: "ORB", email: orbMail)
        T.equal(FathomCheck.of(target, .signedIn(orbMail)), .ready, "same account → ready")
        T.equal(FathomCheck.of(target, .signedIn(homeMail)), .otherAccount(homeMail), "another account")
        T.equal(FathomCheck.of(target, .signedOut), .signedOut, "signed out")
        T.equal(FathomCheck.of(target, .unknown), .unknown, "unknown")
    }

    // MARK: Which Fathom account a meeting records to

    static func routing() {
        T.section("fathom: which Fathom account a meeting records to")
        let merged = event([FixtureAccounts.orb, FixtureAccounts.cmt])
        let own = FathomRouting.targets(merged, directory: directory) { _ in .ownAddress }
        T.equal(own.map(\.tag), ["ORB", "CMT"], "primary copy first")
        T.equal(own.map(\.email), [orbMail, cmtMail], "each account's own address")
        let offFirst = FathomRouting.targets(merged, directory: directory) { $0 == FixtureAccounts.orb ? .off : .ownAddress }
        T.equal(offFirst.map(\.tag), ["CMT"], "an account set to off is skipped")
        let shared = FathomRouting.targets(merged, directory: directory) { _ in .address(orbMail) }
        T.equal(shared.map(\.tag), ["ORB"], "two accounts linked to one Fathom account: once")
        let stranger = event([UUID(), FixtureAccounts.home])
        T.equal(FathomRouting.targets(stranger, directory: directory) { _ in .ownAddress }.map(\.tag), ["Personal"],
                "an account the directory doesn't know is skipped")
        T.check(FathomRouting.offered(accountIds: [FixtureAccounts.orb], hasJoin: true) { _ in .ownAddress }, "offered with a join link")
        T.check(!FathomRouting.offered(accountIds: [FixtureAccounts.orb], hasJoin: false) { _ in .ownAddress }, "no join link → not offered")
        T.check(!FathomRouting.offered(accountIds: [FixtureAccounts.orb], hasJoin: true) { _ in .off }, "every account off → not offered")
        T.check(FathomRouting.offered(accountIds: [FixtureAccounts.orb, FixtureAccounts.cmt], hasJoin: true) {
            $0 == FixtureAccounts.orb ? .off : .ownAddress
        }, "one linked account is enough")
        T.equal(FathomRouting.label(homeMail, directory: directory) { _ in .ownAddress }, "Personal", "an address that is a link → its tag")
        T.equal(FathomRouting.label("someone@else.example", directory: directory) { _ in .ownAddress }, "someone@else.example",
                "any other address as it is")
    }

    static func captureURL() {
        T.section("fathom: the capture link")
        let link = FathomURLs.startCapture(meeting: URL(string: "https://meet.google.com/abc-defg-hij?authuser=1&hs=2")!)
        T.equal(link?.scheme, "fathom", "fathom scheme")
        T.equal(link?.host, "start-capture", "start-capture route")
        let value = link.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "url" }?.value
        T.equal(value, "https://meet.google.com/abc-defg-hij?authuser=1&hs=2", "the meeting link survives, & and = included")
        T.check(!(link?.absoluteString.dropFirst(30).contains("&") ?? true), "no bare & in the query")
        T.equal(FathomURLs.startCapture(meeting: URL(string: "https://evil.example/meet")!), nil, "only allowlisted join links")
        T.equal(FathomURLs.startCapture(meeting: URL(string: "http://meet.google.com/abc")!), nil, "https only")
        T.equal(FathomURLs.openApp.absoluteString, "fathom://open-app", "Open Fathom")
    }

    // MARK: The session

    static func sessionRecordsNow() {
        T.section("fathom: Fathom on the right account records at once")
        let f = Fake()
        let s = session(f)
        T.equal(s.join(event(), directory: directory, via: "test"), .started, "started")
        T.equal(f.opened.map(\.scheme), ["fathom", "https"], "capture link first, then the meeting")
        T.equal(f.opened.last, meet, "the meeting's own link")
        T.equal(s.pending, nil, "nothing waits")
        T.check(f.tick == nil, "no ticker")
    }

    static func sessionWaitsForSwitch() {
        T.section("fathom: another account waits, then records when Fathom switches")
        let f = Fake()
        f.signIn = .signedIn(homeMail)
        let s = session(f)
        let e = event()
        T.equal(s.join(e, directory: directory, via: "test"), .waiting, "waits")
        T.equal(f.opened, [], "nothing opened while Fathom is on the wrong account")
        T.equal(s.pending?.check, .otherAccount(homeMail), "says which account Fathom is on")
        T.equal(s.pending?.target.tag, "ORB", "and which one it should be")
        T.check(s.isPending(e.r), "pending for this meeting")
        T.equal(s.pending?.deadline, now.addingTimeInterval(FathomSession.waitLimit), "3 minutes")
        f.clock = now.addingTimeInterval(10)
        f.tick?()
        T.equal(s.pending?.phase, .waiting, "still waiting after 10 s")
        f.signIn = .signedOut
        f.tick?()
        T.equal(s.pending?.check, .signedOut, "signed out on the way: the panel follows")
        f.signIn = .signedIn(orbMail)
        f.clock = now.addingTimeInterval(40)
        f.tick?()
        T.equal(s.pending, nil, "switched: the wait ends")
        T.equal(f.opened.map(\.scheme), ["fathom", "https"], "and records without asking again")
        T.check(f.stops >= 1, "the ticker stops")

        let merged = event([FixtureAccounts.orb, FixtureAccounts.cmt])
        let cmt = FathomTarget(accountId: FixtureAccounts.cmt, tag: "CMT", email: cmtMail)
        f.opened = []
        T.equal(s.join(merged, target: cmt, directory: directory, via: "test"), .waiting, "the Peek's choice: CMT, Fathom on ORB")
        T.equal(s.pending?.target, cmt, "waits for CMT")
        s.cancelWait()
        T.equal(s.pending, nil, "cancel clears")
        f.signIn = .signedIn(cmtMail)
        T.equal(s.join(merged, target: cmt, directory: directory, via: "test"), .started, "Fathom on CMT: records to CMT")
    }

    static func sessionTimesOut() {
        T.section("fathom: the wait times out; Try again waits again")
        let f = Fake()
        f.signIn = .signedIn(homeMail)
        let s = session(f)
        _ = s.join(event(), directory: directory, via: "test")
        f.clock = now.addingTimeInterval(FathomSession.waitLimit)
        f.tick?()
        T.equal(s.pending?.phase, .timedOut, "timed out at 3 minutes")
        T.equal(f.opened, [], "nothing opened")
        T.check(f.stops >= 1, "the ticker stops at the timeout")
        f.tick?()
        T.equal(s.pending?.phase, .timedOut, "a late tick changes nothing")
        f.clock = now.addingTimeInterval(200)
        s.retry()
        T.equal(s.pending?.phase, .waiting, "Try again")
        T.equal(s.pending?.deadline, now.addingTimeInterval(200 + FathomSession.waitLimit), "a full new wait")
        f.signIn = .signedIn(orbMail)
        s.retry()
        T.equal(s.pending, nil, "Try again once Fathom switched records at once")
        T.equal(f.opened.count, 2, "capture and meeting")
    }

    static func sessionUnknownAndJoinOnly() {
        T.section("fathom: can't tell → Record anyway; Join without recording")
        let f = Fake()
        f.signIn = .unknown
        let s = session(f)
        T.equal(s.join(event(), directory: directory, via: "test"), .waiting, "unknown asks first")
        T.equal(s.pending?.check, .unknown, "unknown")
        T.check(s.recordAnyway(), "Record anyway")
        T.equal(f.opened.map(\.scheme), ["fathom", "https"], "records with whatever Fathom has")
        T.equal(s.pending, nil, "done")
        f.opened = []
        f.signIn = .signedIn(homeMail)
        _ = s.join(event(), directory: directory, via: "test")
        T.check(s.joinWithoutRecording(), "Join without recording")
        T.equal(f.opened, [meet], "the meeting only")
        T.equal(s.pending, nil, "done")
        f.opened = []
        _ = s.join(event(), directory: directory, via: "test")
        s.openFathom()
        T.equal(f.opened, [FathomURLs.openApp], "Open Fathom opens Fathom only")
        T.check(s.pending != nil, "and the wait goes on")
    }

    static func sessionRefuses() {
        T.section("fathom: not installed, not linked, no link")
        let f = Fake()
        f.installed = false
        let s = session(f)
        T.equal(s.join(event(), directory: directory, via: "test"), .notLinked, "Fathom not on this Mac")
        T.equal(s.targets(event(), directory: directory), [], "no targets either")
        f.installed = true
        f.links[FixtureAccounts.orb] = .off
        T.equal(s.join(event(), directory: directory, via: "test"), .notLinked, "account set to off")
        f.links = [:]
        T.equal(s.join(event(join: nil), directory: directory, via: "test"), .blocked, "no join link")
        T.equal(s.join(event(join: URL(string: "https://evil.example/x")), directory: directory, via: "test"), .blocked, "not allowlisted")
        T.equal(f.opened, [], "nothing opened")
        T.equal(FathomSession.traceName(.otherAccount(homeMail)), "other-account", "trace names carry no address")
    }

    // MARK: Words

    static func words() {
        T.section("fathom: words")
        let orb = FathomTarget(accountId: FixtureAccounts.orb, tag: "ORB", email: orbMail)
        let label: (String) -> String = { $0 == homeMail ? "Personal" : $0 }
        T.equal(FathomText.status(orb, .ready, label: label).text, "Records to avery@orbitalpickle.example", "ready")
        T.equal(FathomText.status(orb, .ready, label: label).tone, .ok, "ready tone")
        T.equal(FathomText.status(orb, .otherAccount(homeMail), label: label).text, "Fathom is signed in as Personal, not ORB", "other")
        T.equal(FathomText.status(orb, .otherAccount(homeMail), label: label).tone, .warn, "other tone")
        T.equal(FathomText.status(orb, .signedOut, label: label).text, "Fathom isn\u{2019}t signed in", "signed out")
        T.equal(FathomText.status(orb, .unknown, label: label).tone, .quiet, "unknown is quiet")
        T.equal(FathomText.left(171), "2:51 left", "2:51")
        T.equal(FathomText.left(0.2), "0:01 left", "rounds up")
        T.equal(FathomText.left(-5), "0:00 left", "never negative")
        var p = FathomSession.Pending(event: event(), target: orb, check: .otherAccount(homeMail), deadline: now, phase: .waiting)
        let w = FathomText.wait(p, current: label)
        T.equal(w.title, "Switch Fathom to ORB", "switch title")
        T.check(w.body.contains("signed in as Personal") && w.body.contains(orbMail), "names both accounts")
        T.equal(w.primary, "Open Fathom", "Open Fathom")
        p.check = .signedOut
        T.equal(FathomText.wait(p, current: label).title, "Sign Fathom in as ORB", "signed out")
        p.check = .unknown
        T.equal(FathomText.wait(p, current: label).primary, "Record anyway", "unknown")
        p.phase = .timedOut
        T.equal(FathomText.wait(p, current: label).primary, "Try again", "timed out")
        for text in [w.title, w.body] { T.check(!text.contains("!"), "no exclamation marks: \(text)") }
    }

    static func linksModel() {
        T.section("fathom: account card and Settings model")
        let f = Fake()
        f.signIn = .signedIn(cmtMail)
        let bag = MemoryBag()
        var posts = 0
        let s = FathomSession(env: FathomSession.Environment(installed: { f.installed }, signIn: { f.signIn },
                                                             link: { FathomPrefs.link($0, bag) }))
        let m = FathomLinksModel(bag: bag, session: s, post: { posts += 1 })
        m.refresh()
        T.check(m.installed, "installed")
        T.check(m.isSignedIn(FixtureAccounts.cmt, email: cmtMail), "CMT is the account Fathom is on")
        T.check(!m.isSignedIn(FixtureAccounts.orb, email: orbMail), "ORB isn't")
        T.check(m.detail(FixtureAccounts.orb, email: orbMail).contains(orbMail), "own address named")
        T.check(!m.setAddress("not one", for: FixtureAccounts.orb, own: orbMail), "a broken address is refused")
        T.equal(posts, 0, "…and changes nothing")
        T.check(m.setAddress("Fathom@Orbitalpickle.example", for: FixtureAccounts.orb, own: orbMail), "another address")
        T.equal(m.link(FixtureAccounts.orb), .address("fathom@orbitalpickle.example"), "stored")
        T.equal(posts, 1, "posted, so the widgets republish")
        T.check(m.setAddress(orbMail.uppercased(), for: FixtureAccounts.orb, own: orbMail), "typing the account's own address")
        T.equal(m.link(FixtureAccounts.orb), .ownAddress, "…is the default again")
        m.set(.off, for: FixtureAccounts.orb)
        T.check(m.detail(FixtureAccounts.orb, email: orbMail).hasPrefix("Off"), "off detail")
        m.setHotkeyRecords(true)
        T.check(m.hotkeyRecords, "⌃⌥J records")
        T.equal(posts, 4, "every change posts")
        T.equal(m.appStatus(directory: directory), "Signed in as \(cmtMail) (CMT).", "Settings names the account")
        f.signIn = .unknown
        m.refresh()
        T.check(m.appStatus(directory: directory).hasPrefix("I can\u{2019}t tell"), "unknown")
        f.installed = false
        m.refresh()
        T.equal(m.appStatus(directory: directory), "Fathom isn\u{2019}t on this Mac.", "not installed")
    }

    static func popoverCard() {
        T.section("fathom: the popover card")
        let store = FakeCalendarStore(events: [event([FixtureAccounts.orb, FixtureAccounts.home])])
        let f = Fake()
        let model = PopoverModel(store: { store }, actions: { store }, mail: { FakeMailStore() }, directory: { directory },
                                 clock: { now }, syncedAt: { nil }, use24Hour: { false }, fathom: session(f))
        model.load()
        T.equal(model.card?.fathom.map(\.tag), ["ORB", "Personal"], "the card knows both Fathom accounts, primary first")
        f.installed = false
        model.load()
        T.equal(model.card?.fathom ?? [], [], "Fathom not on this Mac: no button")
        let plain = PopoverModel(store: { store }, actions: { store }, mail: { FakeMailStore() }, directory: { directory },
                                 clock: { now }, syncedAt: { nil }, use24Hour: { false })
        plain.load()
        T.equal(plain.card?.fathom ?? [], [], "the shared session (no Fathom in tests): no button")
    }

    // MARK: Route and snapshot

    static func route() {
        T.section("fathom: the record route")
        let r = "ev2", k = FixtureLinkKeys.k("ev2")
        func decide(_ s: String) -> RouteAction {
            RouteDecider.decide(Route.parse(URL(string: s)!)!) { r, k in FixtureLinkKeys.k(r) == k }
        }
        T.equal(decide("yayacal://record?r=\(r)&k=\(k)"), .record(r: r), "record with a good key")
        T.equal(decide("yayacal://record?r=\(r)&k=\(FixtureLinkKeys.k("ev3"))"), .ignore(route: "record", reason: "bad-key"), "forged")
        T.equal(decide("yayacal://record?r=\(r)"), .ignore(route: "record", reason: "missing-param"), "no key")
        T.equal(RouteAction.record(r: r).name, "record", "trace name")
        T.equal(RouteTable.spec("record")?.quiet, true, "quiet")
        var m = WidgetMeeting(id: 1, account: WidgetAccount(id: "a", short: "ORB", name: "", logo: nil), title: "T",
                              start: now, end: now, place: nil, hasLink: true)
        m.r = r
        m.k = k
        T.equal(WidgetLinkContext(kind: "upnext", family: .medium).record(m), YayaLink.record(r: r, k: k), "Up Next's Fathom button")
        m.k = nil
        T.equal(Route.parse(WidgetLinkContext(kind: "upnext", family: .medium).record(m))?.name, "ping", "sample rows only ping")
    }

    static func snapshot() {
        T.section("fathom: snapshot rec")
        let base = WidgetSnapshot.Meeting(r: "g1", k: "k1", accountIds: ["a"], title: "T", start: now, end: now, allDay: false,
                                          place: nil, hasJoin: true, reply: .accepted, clashes: false)
        let plain = String(data: (try? WidgetSnapshot.encoder.encode(base)) ?? Data(), encoding: .utf8) ?? ""
        T.check(!plain.contains("rec"), "nil rec is left out (version-1 files and hashes unchanged)")
        var offered = base
        offered.rec = true
        let data = (try? WidgetSnapshot.encoder.encode(offered)) ?? Data()
        T.check(String(data: data, encoding: .utf8)?.contains(#""rec":true"#) ?? false, "rec true is written")
        T.equal((try? WidgetSnapshot.decoder.decode(WidgetSnapshot.Meeting.self, from: data))?.rec, true, "and read back")
        T.equal((try? WidgetSnapshot.decoder.decode(WidgetSnapshot.Meeting.self, from: Data(plain.utf8)))?.rec, nil,
                "an older meeting decodes with rec nil")
    }
}
