import Foundation

/// Yaya's Murmur and recording per account (D-046): event ids, presence, the marks file (valid, oversized, malformed,
/// missing, newer, capped), Murmur's links, the session (join, helper, notes), the "Record with" choice and how it
/// resolves per account and per install state, the Join menu, the popover card and the Event Peek with and without
/// Murmur, the snapshot's `recBy`. Fakes and memory bags only: no Murmur files, no user defaults, nothing opened.
@MainActor
enum MurmurTests {
    static let now = WidgetSample.fixedNow
    static let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
    static let directory = FixtureAccounts.directory()
    static let orb = FixtureAccounts.orb, cmt = FixtureAccounts.cmt, fam = FixtureAccounts.fam, home = FixtureAccounts.home

    static func run() {
        eventIDs()
        presence()
        marksValid()
        marksRefused()
        marksCapped()
        links()
        sessionJoin()
        sessionHelperAndNotes()
        choices()
        resolution()
        meetingRecorder()
        offeredKind()
        joinMenu()
        choicesModel()
        words()
        popoverWithoutMurmur()
        popoverWithMurmur()
        peekWithoutMurmur()
        peekWithMurmur()
        snapshot()
    }

    // MARK: Helpers

    final class Fake {
        var installed = true
        var marks: MurmurMarks.State = .missing
        var opened: [URL] = []
        var openOK = true
        var later: [@MainActor () -> Void] = []
    }

    static func session(_ f: Fake) -> MurmurSession {
        MurmurSession(env: MurmurSession.Environment(
            installed: { f.installed }, marks: { f.marks },
            open: { url in f.opened.append(url); return f.openOK || url.scheme == "https" },
            after: { _, work in f.later.append(work) }))
    }

    final class FathomFake {
        var installed = false
        var links: [UUID: FathomLink] = [:]
        var opened: [URL] = []
    }

    static func fathom(_ f: FathomFake) -> FathomSession {
        FathomSession(env: FathomSession.Environment(
            installed: { f.installed }, signIn: { .signedIn("avery@orbitalpickle.example") }, link: { f.links[$0] ?? .ownAddress },
            open: { f.opened.append($0); return true }, after: { _, work in work() }, every: { _, _ in {} }, clock: { now }))
    }

    static func event(_ accounts: [UUID] = [FixtureAccounts.orb], join: URL? = MurmurTests.meet, r: String = "gMurmurWeekly01",
                      allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(r: r, accountIds: accounts, calendarName: "Work", title: "Weekly sync", start: now.addingTimeInterval(240),
                      end: now.addingTimeInterval(2040), allDay: allDay, location: nil, joinURL: join, webURL: nil, notes: nil,
                      organizer: nil, attendees: [], myResponse: .accepted, clashes: false)
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    /// The contract's own example (Murmur's docs/CONTRACTS.md, "Murmur → Calendar: marks"), plus status.
    static let contractExample = """
    {
      "v": 1,
      "updatedAt": "2026-10-19T09:00:00Z",
      "marks": {
        "evtKickoff03": {
          "liveHelperKind": "clientMeeting",
          "mode": "macbook",
          "consentTier": "explicit",
          "updatedAt": "2026-10-19T09:00:00Z"
        }
      }
    }
    """

    // MARK: Event ids and presence

    static func eventIDs() {
        T.section("murmur: event ids")
        for good in ["e", "gK3vAbCdEfGhIjKlMnOpQr", "evtKickoff03", "a_b-C9", String(repeating: "x", count: 128)] {
            T.check(MurmurEventID.isValid(good), "valid: \(good.prefix(24))")
        }
        for bad in ["", String(repeating: "x", count: 129), "a b", "a/b", "a&mode=x", "a=b", "é", "a.b", "a%26", "a\u{0}b", "a\nb"] {
            T.check(!MurmurEventID.isValid(bad), "refused: \(bad.debugDescription)")
        }
        let r = EventIdsProbe.sample
        T.check(MurmurEventID.isValid(r), "the calendar's own row ids pass (\(r.count) characters)")
    }

    static func presence() {
        T.section("murmur: installed means its own bundle id handles its scheme")
        let id = Profile.murmurBundleId
        T.check(MurmurPresence.isInstalled(handlers: [id]), "Murmur's id")
        T.check(MurmurPresence.isInstalled(handlers: [nil, "org.example.other", id]), "among other handlers")
        T.check(MurmurPresence.isInstalled(handlers: [id.uppercased()]), "bundle ids compare without case")
        T.check(!MurmurPresence.isInstalled(handlers: []), "no handler: not installed")
        T.check(!MurmurPresence.isInstalled(handlers: [nil, ""]), "handlers without an id")
        T.check(!MurmurPresence.isInstalled(handlers: ["org.example.lookalike"]), "a look-alike claiming the scheme")
        T.check(!MurmurPresence.isInstalled(handlers: [id + ".fork"]), "a fork under a longer id")
        T.check(!MurmurPresence.isInstalled(handlers: [" " + id]), "a padded id")
        #if YC_PROFILE_DEV
        T.check(Profile.murmurScheme.hasSuffix("-dev"), "a dev calendar looks only for a dev Murmur")
        #else
        T.check(!MurmurPresence.isInstalled(handlers: [id + ".dev"]), "a release calendar ignores a dev Murmur")
        #endif
    }

    // MARK: Marks

    static func marksValid() {
        T.section("murmur: marks file, valid")
        guard case .ready(let marks, let skipped) = MurmurMarks.parse(json(contractExample)) else {
            T.check(false, "the contract's example parses")
            return
        }
        T.equal(skipped, 0, "nothing skipped")
        let m = marks["evtKickoff03"]
        T.equal(m?.helper, .clientMeeting, "liveHelperKind")
        T.equal(m?.mode, .macbook, "mode")
        T.equal(m?.consent, .explicit, "consentTier")
        T.equal(m?.status, nil, "a file without status reads as null")
        T.equal(m?.updatedAt, Date(timeIntervalSince1970: 1_792_400_400), "updatedAt")
        T.equal(m?.badges ?? [], [.liveHelper, .explicitConsent], "badges: Live Helper, Explicit consent")

        let full = """
        {"v":1,"updatedAt":"2026-10-19T09:00:00.250Z","future":{"x":1},"marks":{
          "gA":{"liveHelperKind":"interview","mode":"homelab","consentTier":"notice","status":"notesReady","updatedAt":"2026-10-19T09:00:00.5Z","extra":true},
          "gB":{"liveHelperKind":null,"mode":"macbook","consentTier":"notice","status":"meOnly","updatedAt":"2026-10-19T08:00:00Z"},
          "gC":{"liveHelperKind":"standup","mode":"cloud","consentTier":"loud","status":"archived","updatedAt":"yesterday"},
          "gD":{"liveHelperKind":42,"mode":7,"consentTier":false,"status":[],"updatedAt":3},
          "gE":{"liveHelperKind":"discussion","status":null},
          "gF":{"liveHelperKind":"not a kind!"},
          "bad id!":{"liveHelperKind":"interview"},
          "gG":"not an object",
          "gH":{}
        }}
        """
        let state = MurmurMarks.parse(json(full))
        let all = state.marks
        if case .ready(_, let skipped) = state { T.equal(skipped, 2, "a bad id and a non-object mark are skipped") }
        T.equal(Set(all.keys), ["gA", "gB", "gC", "gD", "gE", "gF", "gH"], "every other mark is kept")
        T.equal(all["gA"]?.badges ?? [], [.liveHelper, .notesReady], "interview + notes ready")
        T.equal(all["gA"]?.updatedAt, Date(timeIntervalSince1970: 1_792_400_400.5), "fractional seconds")
        T.equal(all["gB"]?.badges ?? [], [.meOnly], "no Live Helper, me only")
        T.equal(all["gC"]?.helper, .other, "a newer helper kind (letters only) is still on")
        T.equal(all["gC"]?.mode, nil, "an unknown mode reads as absent")
        T.equal(all["gC"]?.consent, nil, "an unknown tier reads as absent")
        T.equal(all["gC"]?.status, nil, "an unknown status reads as absent")
        T.equal(all["gC"]?.updatedAt, nil, "a date that isn't ISO 8601")
        T.equal(all["gD"], MurmurMark(), "wrong types read as absent")
        T.equal(all["gE"]?.badges ?? [], [.liveHelper], "status null")
        T.equal(all["gF"]?.helper, nil, "a kind with spaces and punctuation is no kind")
        T.equal(all["gH"]?.badges ?? [.meOnly], [], "an empty mark: no badges")
        T.equal(MurmurMarks.parse(json(#"{"v":1,"marks":{}}"#)), .ready([:], skipped: 0), "no marks yet")
    }

    static func marksRefused() {
        T.section("murmur: marks file, missing, oversized, malformed, newer")
        T.equal(MurmurMarks.parse(nil), .missing, "no file")
        var big = Data(#"{"v":1,"marks":{},"pad":""#.utf8)
        big.append(Data(repeating: 0x61, count: MurmurMarks.fileLimit))
        big.append(Data(#""}"#.utf8))
        T.equal(MurmurMarks.parse(big), .unreadable, "over \(MurmurMarks.fileLimit / 1024) KB is refused before it is read")
        let atLimit = Data(#"{"v":1,"marks":{}}"#.utf8) + Data(repeating: 0x20, count: MurmurMarks.fileLimit - 18)
        T.equal(atLimit.count, MurmurMarks.fileLimit, "a file of exactly the limit")
        T.equal(MurmurMarks.parse(atLimit), .ready([:], skipped: 0), "is read")
        for (text, what) in [("", "empty"), ("not json", "not JSON"), ("[1,2]", "an array"), (#"{"marks":{}}"#, "no v"),
                             (#"{"v":"1","marks":{}}"#, "v as text"), (#"{"v":true,"marks":{}}"#, "v as a boolean"),
                             (#"{"v":1.5,"marks":{}}"#, "v a fraction"), (#"{"v":0,"marks":{}}"#, "v 0"),
                             (#"{"v":1}"#, "no marks"), (#"{"v":1,"marks":[]}"#, "marks a list"),
                             (#"{"v":1,"marks":{"gA":{}}"#, "cut off"), ("{\"v\":1,\"marks\":{}}\u{0}", "a stray byte")] {
            T.equal(MurmurMarks.parse(json(text)), .unreadable, "malformed: \(what)")
        }
        T.equal(MurmurMarks.parse(json(#"{"v":2,"marks":"anything"}"#)), .newer, "a newer version is ignored, not misread")
        T.equal(MurmurMarks.parse(json(#"{"v":2}"#)), .newer, "a newer version needs nothing else")
        T.equal(MurmurMarks.State.unreadable.marks, [:], "unreadable: no marks")
        T.equal(MurmurMarks.State.newer.marks, [:], "newer: no marks")
    }

    static func marksCapped() {
        T.section("murmur: marks file, at most 500 marks")
        var parts: [String] = []
        for i in 0..<520 {
            let minute = String(format: "%02d", i % 60), hour = String(format: "%02d", i / 60)
            parts.append(#""m\#(i)":{"liveHelperKind":"interview","updatedAt":"2026-10-19T\#(hour):\#(minute):00Z"}"#)
        }
        let state = MurmurMarks.parse(json(#"{"v":1,"marks":{"# + parts.joined(separator: ",") + "}}"))
        guard case .ready(let marks, let skipped) = state else { T.check(false, "a 520-mark file parses"); return }
        T.equal(marks.count, MurmurMarks.markLimit, "500 kept")
        T.equal(skipped, 20, "20 dropped")
        T.check(marks["m519"] != nil && marks["m20"] != nil, "the newest are kept")
        T.check(marks["m0"] == nil && marks["m19"] == nil, "the oldest go")
    }

    // MARK: Links

    static func links() {
        T.section("murmur: links")
        let s = Profile.murmurScheme
        T.equal(MurmurLinks.join(event: "gA1", mode: nil)?.absoluteString, "\(s)://join?event=gA1", "join, Murmur's own mode")
        T.equal(MurmurLinks.join(event: "gA1", mode: .homelab)?.absoluteString, "\(s)://join?event=gA1&mode=homelab", "join on the home lab")
        T.equal(MurmurLinks.join(event: "gA1", mode: .macbook)?.absoluteString, "\(s)://join?event=gA1&mode=macbook", "join on this MacBook")
        T.equal(MurmurLinks.helper(event: "g-_9")?.absoluteString, "\(s)://helper?event=g-_9", "helper")
        T.equal(MurmurLinks.open(event: "g-_9")?.absoluteString, "\(s)://open?event=g-_9", "open")
        T.equal(MurmurLinks.join(event: "yayamurmur", mode: nil, scheme: "yayamurmur-dev")?.scheme, "yayamurmur-dev", "the scheme is the profile's")
        for bad in ["", "a&mode=macbook", "a b", "a#x", String(repeating: "x", count: 129)] {
            T.equal(MurmurLinks.join(event: bad, mode: .homelab), nil, "no link for \(bad.prefix(20).debugDescription)")
            T.equal(MurmurLinks.helper(event: bad), nil, "no helper link for \(bad.prefix(20).debugDescription)")
        }
        let longest = MurmurLinks.join(event: String(repeating: "x", count: 128), mode: .homelab)
        T.check((longest?.absoluteString.utf8.count ?? 999) <= MurmurLinks.maxBytes, "the longest link fits Murmur's 512 bytes")
        if let url = MurmurLinks.join(event: "gA1", mode: .homelab) {
            T.check(url.user == nil && url.password == nil && url.port == nil && url.fragment == nil && url.path.isEmpty,
                    "no user, password, port, fragment or path (Murmur refuses those)")
        }
    }

    // MARK: Session

    static func sessionJoin() {
        T.section("murmur: Join with Yaya's Murmur")
        let f = Fake()
        let s = session(f)
        let e = event()
        T.equal(s.join(e, mode: .homelab, via: "test"), .started, "started")
        T.equal(f.opened.map(\.absoluteString), ["\(Profile.murmurScheme)://join?event=\(e.r)&mode=homelab"], "Murmur first")
        T.equal(f.later.count, 1, "the meeting waits a moment")
        f.later.forEach { $0() }
        T.equal(f.opened.last, meet, "then the meeting")
        T.equal(MurmurSession.meetingDelay, 0.6, "0.6 s between them")

        let g = Fake()
        g.openOK = false
        let gs = session(g)
        T.equal(gs.join(e, mode: nil, via: "test"), .joinedOnly, "Murmur's link failed: joined only")
        g.later.forEach { $0() }
        T.equal(g.opened.last, meet, "the call still opens")

        let h = Fake()
        h.installed = false
        let hs = session(h)
        T.equal(hs.join(e, mode: nil, via: "test"), .notInstalled, "not installed")
        T.equal(h.opened, [], "nothing opened")
        let i = Fake()
        let iss = session(i)
        T.equal(iss.join(event(join: URL(string: "https://evil.example/meet")), mode: nil, via: "test"), .blocked, "a link off the allowlist")
        T.equal(iss.join(event(join: nil), mode: nil, via: "test"), .blocked, "no link")
        T.equal(iss.join(event(r: "bad id"), mode: nil, via: "test"), .blocked, "an id outside the rule")
        T.equal(i.opened, [], "nothing opened when blocked")
    }

    static func sessionHelperAndNotes() {
        T.section("murmur: Live Helper, notes and badges")
        let f = Fake()
        f.marks = MurmurMarks.parse(json(#"{"v":1,"marks":{"gMurmurWeekly01":{"liveHelperKind":"interview","status":"notesReady","consentTier":"explicit"}}}"#))
        let s = session(f)
        s.refresh()
        let e = event()
        T.equal(s.badges(e.r), [.liveHelper, .notesReady, .explicitConsent], "badges from the mark")
        T.equal(s.mark(e.r)?.helper, .interview, "the mark")
        T.check(s.openHelper(e, via: "test"), "helper opened")
        T.check(s.openNotes(e, via: "test"), "notes opened")
        T.equal(f.opened.map { $0.host ?? "" }, ["helper", "open"], "helper, then open")
        T.check(f.opened.allSatisfy { $0.query == "event=\(e.r)" }, "for this event only")
        T.check(!s.openHelper(event(r: "x y"), via: "test"), "no helper link for a bad id")
        f.installed = false
        s.refresh()
        T.equal(s.badges(e.r), [], "Murmur gone: no badges")
        T.equal(s.mark(e.r), nil, "and no mark")
        T.check(!s.openHelper(e, via: "test"), "and no helper")
        T.equal(s.statusLine, "Yaya\u{2019}s Murmur isn\u{2019}t on this Mac.", "Settings says so")
        f.installed = true
        f.marks = .unreadable
        s.refresh()
        T.check(s.statusLine.contains("can\u{2019}t read"), "Settings: unreadable marks")
        f.marks = .newer
        s.refresh()
        T.check(s.statusLine.contains("newer"), "Settings: newer format")
        T.equal(MurmurBadge.lime, 0xC6F36B, "lime is Murmur's")
        T.equal(MurmurBadge.pink, 0xFF9EEA, "pink is Murmur's")
        T.equal(MurmurBadge.allCases.filter(\.isLime), [.liveHelper, .notesReady], "lime for what Murmur does")
    }

    // MARK: The choice and its resolution

    static func choices() {
        T.section("recorder: the stored choice")
        for c in RecorderChoice.allCases { T.equal(RecorderChoice(stored: c.stored), c, "round trip \(c)") }
        T.equal(RecorderChoice(stored: "zoom"), .automatic, "unknown reads as automatic")
        T.equal(RecorderChoice.automatic.stored, nil, "automatic stores nothing")
        let bag = MemoryBag()
        T.equal(RecorderPrefs.choice(orb, bag), .automatic, "default")
        RecorderPrefs.setChoice(.ask, for: orb, bag)
        T.equal(bag.values[RecorderPrefs.key(orb)] as? String, "ask", "stored under recorder.<uuid>")
        T.equal(RecorderPrefs.key(orb), "recorder." + orb.uuidString, "key")
        RecorderPrefs.setChoice(.automatic, for: orb, bag)
        T.check(bag.values[RecorderPrefs.key(orb)] == nil, "back to automatic removes it")
    }

    static func resolution() {
        T.section("recorder: per account")
        func r(_ c: RecorderChoice, _ installed: Bool, _ link: FathomLink) -> Recorder {
            RecorderRouting.resolve(c, fathomInstalled: installed, fathomLink: link)
        }
        T.equal(r(.automatic, true, .ownAddress), .fathom, "automatic + linked to Fathom: Fathom, as today")
        T.equal(r(.automatic, true, .address("x@y.example")), .fathom, "automatic + another Fathom address: Fathom")
        T.equal(r(.automatic, true, .off), .murmur, "automatic + Fathom off: Yaya's Murmur")
        T.equal(r(.automatic, false, .ownAddress), .murmur, "automatic + no Fathom: Yaya's Murmur")
        T.equal(r(.fathom, true, .ownAddress), .fathom, "Fathom")
        T.equal(r(.fathom, false, .ownAddress), .off, "Fathom gone from this Mac: nothing records")
        T.equal(r(.fathom, true, .off), .off, "Fathom with its link off: nothing records")
        for installed in [true, false] {
            T.equal(r(.murmur, installed, .ownAddress), .murmur, "Yaya's Murmur (Fathom installed: \(installed))")
            T.equal(r(.ask, installed, .ownAddress), .ask, "ask each time")
            T.equal(r(.off, installed, .ownAddress), .off, "off")
        }
    }

    static func meetingRecorder() {
        T.section("recorder: per meeting and install state")
        var choices: [UUID: RecorderChoice] = [cmt: .ask, fam: .off]
        func m(_ ids: [UUID], murmur: Bool, fathom: Bool) -> Recorder? {
            RecorderRouting.meeting(accountIds: ids, murmurInstalled: murmur, fathomInstalled: fathom,
                                    link: { _ in .ownAddress }, choice: { choices[$0] ?? .automatic })
        }
        for fathom in [true, false] {
            T.equal(m([orb], murmur: false, fathom: fathom), nil, "no Murmur: the routing is off (Fathom \(fathom))")
            T.equal(m([cmt, orb], murmur: false, fathom: fathom), nil, "no Murmur: even an account that asks")
        }
        T.equal(m([orb], murmur: true, fathom: true), .fathom, "Murmur + Fathom, automatic: Fathom")
        T.equal(m([orb], murmur: true, fathom: false), .murmur, "Murmur only, automatic: Murmur")
        T.equal(m([cmt, orb], murmur: true, fathom: true), .ask, "a merged invite follows its primary copy")
        T.equal(m([fam, cmt], murmur: true, fathom: true), .off, "a primary that is off wins")
        T.equal(m([], murmur: true, fathom: true), .off, "no account: off")
        choices[orb] = .murmur
        T.equal(m([orb], murmur: true, fathom: true), .murmur, "an explicit choice wins over automatic")
    }

    static func offeredKind() {
        T.section("recorder: widget button and heads-up action")
        var choices: [UUID: RecorderChoice] = [:]
        var links: [UUID: FathomLink] = [:]
        func k(_ ids: [UUID], join: Bool = true, murmur: Bool, fathom: Bool) -> String? {
            RecorderRouting.offeredKind(accountIds: ids, hasJoin: join, murmurInstalled: murmur, fathomInstalled: fathom,
                                        link: { links[$0] ?? .ownAddress }, choice: { choices[$0] ?? .automatic })
        }
        // Without Murmur: exactly D-045 (Fathom's button when one of the accounts records with Fathom).
        T.equal(k([orb], murmur: false, fathom: true), "fathom", "no Murmur: Fathom's button as before")
        T.equal(k([orb], murmur: false, fathom: false), nil, "no Murmur, no Fathom: nothing")
        links[orb] = .off
        T.equal(k([orb, cmt], murmur: false, fathom: true), "fathom", "no Murmur: any linked account, as before")
        links[cmt] = .off
        T.equal(k([orb, cmt], murmur: false, fathom: true), nil, "no Murmur, every link off: nothing")
        choices[orb] = .ask
        T.equal(k([orb], murmur: false, fathom: true), nil, "no Murmur: the choice is ignored")
        // With Murmur: the primary account's recorder.
        links = [:]
        choices = [:]
        T.equal(k([orb], murmur: true, fathom: true), "fathom", "Murmur + Fathom, automatic: Fathom")
        T.equal(k([orb], murmur: true, fathom: false), "murmur", "Murmur only: Murmur")
        choices[orb] = .ask
        T.equal(k([orb], murmur: true, fathom: true), "ask", "ask")
        choices[orb] = .off
        T.equal(k([orb], murmur: true, fathom: true), nil, "off: no button")
        choices[orb] = .murmur
        T.equal(k([orb], join: false, murmur: true, fathom: true), nil, "no join link: no button")
    }

    // MARK: The Join menu

    static func joinMenu() {
        T.section("recorder: the Join menu")
        let orbT = FathomTarget(accountId: orb, tag: "ORB", email: "avery@orbitalpickle.example")
        let cmtT = FathomTarget(accountId: cmt, tag: "CMT", email: "avery@quietcomets.example")
        let full = JoinMenu.items(fathomTargets: [orbT], murmurInstalled: true)
        T.equal(full.map(\.title), ["Join with Fathom", "Join with Yaya\u{2019}s Murmur", "-", "Just join"], "Fathom, Murmur ▸, Just join")
        T.equal(full[0].entry, .fathom(orbT), "Join with Fathom joins with the linked account")
        T.equal(full[1].entry, nil, "Murmur is a submenu")
        T.equal(full[1].children.map(\.title), ["Home lab", "MacBook"], "Home lab / MacBook")
        T.equal(full[1].children.map(\.entry), [.murmur(.homelab), .murmur(.macbook)], "each with its mode")
        T.check(full[2].isSeparator, "a separator before Just join")
        T.equal(full.last?.entry, .justJoin, "Just join last")
        let merged = JoinMenu.items(fathomTargets: [orbT, cmtT], murmurInstalled: true)
        T.equal(merged.prefix(2).map(\.title), ["Join with Fathom \u{00B7} ORB", "Join with Fathom \u{00B7} CMT"], "one per Fathom account")
        let unlinked = JoinMenu.items(fathomTargets: [], murmurInstalled: true)
        T.equal(unlinked.map(\.title), ["Join with Yaya\u{2019}s Murmur", "-", "Just join"], "no Fathom link: no Join with Fathom")
        let noMurmur = JoinMenu.items(fathomTargets: [orbT], murmurInstalled: false)
        T.check(!noMurmur.contains { $0.title.contains("Murmur") }, "no Murmur: no Murmur entry")
        T.equal(JoinMenu.items(fathomTargets: [], murmurInstalled: false).map(\.title), ["Just join"], "nothing else: Just join alone")
    }

    static func choicesModel() {
        T.section("recorder: the account card's Record with")
        let bag = MemoryBag()
        let ff = FathomFake()
        ff.installed = true
        let fs = FathomSession(env: FathomSession.Environment(
            installed: { ff.installed }, signIn: { .unknown }, link: { FathomPrefs.link($0, bag) },
            open: { _ in true }, after: { _, w in w() }, every: { _, _ in {} }, clock: { now }))
        fs.refresh()
        let mf = Fake()
        let ms = session(mf)
        ms.refresh()
        var posts = 0
        let model = RecorderChoicesModel(bag: bag, fathom: fs, murmur: ms, post: { posts += 1 })
        let links = FathomLinksModel(bag: bag, session: fs, post: { posts += 1 })
        T.check(model.active, "shown while Murmur is installed")
        T.equal(model.resolved(orb), .fathom, "automatic, linked: Fathom")
        T.check(model.detail(orb).hasPrefix("Automatic: "), "the line says it's automatic")
        links.set(.off, for: orb)
        T.equal(model.resolved(orb), .murmur, "Fathom link off: Murmur")
        model.set(.fathom, for: orb, links: links)
        T.equal(links.link(orb), .ownAddress, "choosing Fathom turns its link back on")
        T.equal(model.resolved(orb), .fathom, "and it records with Fathom")
        model.set(.off, for: orb)
        T.equal(model.resolved(orb), .off, "off")
        T.equal(posts, 4, "every change posts (link off, Fathom choice, its link, off)")
        ff.installed = false
        model.refresh()
        model.set(.fathom, for: orb)
        T.equal(model.resolved(orb), .off, "Fathom chosen but gone: off")
        T.check(model.detail(orb).contains("Fathom isn\u{2019}t on this Mac"), "the card says why")
        mf.installed = false
        model.refresh()
        T.check(!model.active, "hidden without Murmur")
    }

    static func words() {
        T.section("recorder: words")
        T.equal(RecorderText.joinTitle(.murmur), "Join with Yaya\u{2019}s Murmur", "Murmur's button")
        T.equal(RecorderText.joinTitle(.ask), "Join and record\u{2026}", "ask's button")
        T.equal(RecorderText.murmurStatus(nil), "Yaya\u{2019}s Murmur listens when the call starts", "no mark")
        T.equal(RecorderText.murmurStatus(MurmurMark(mode: .homelab)), "Yaya\u{2019}s Murmur records it on the home lab", "home lab")
        T.equal(RecorderText.murmurStatus(MurmurMark(mode: .macbook)), "Yaya\u{2019}s Murmur records it on this MacBook", "MacBook")
        T.equal(Recorder.allCases.map(\.title), ["Fathom", "Yaya\u{2019}s Murmur", "Ask each time", "Off"], "Record with: the four choices")
    }

    // MARK: Surfaces

    static func popover(murmur: MurmurSession, fathom: FathomSession, events: [CalendarEvent],
                        choice: @escaping (UUID) -> RecorderChoice = { _ in .automatic }) -> PopoverModel {
        let store = FakeCalendarStore(events: events)
        let model = PopoverModel(store: { store }, actions: { store }, mail: { FakeMailStore() }, directory: { directory },
                                 clock: { now }, syncedAt: { nil }, use24Hour: { false }, fathom: fathom, murmur: murmur,
                                 recorderChoice: choice)
        model.load()
        return model
    }

    static func popoverWithoutMurmur() {
        T.section("murmur: hidden without it (the popover as before)")
        let mf = Fake()
        mf.installed = false
        mf.marks = MurmurMarks.parse(json(#"{"v":1,"marks":{"gMurmurWeekly01":{"liveHelperKind":"interview","status":"notesReady"}}}"#))
        let ff = FathomFake()
        ff.installed = true
        let model = popover(murmur: session(mf), fathom: fathom(ff), events: [event()], choice: { _ in .ask })
        T.equal(model.card?.recorder, nil, "no recorder: the card is Join + Join with Fathom, as before")
        T.equal(model.card?.fathom.map(\.tag), ["ORB"], "Join with Fathom stays")
        T.equal(model.card?.badges ?? [.liveHelper], [], "no badges, even with a marks file on disk")
        T.equal(model.badges("gMurmurWeekly01"), [], "no row badges")
        let plain = PopoverModel(store: { FakeCalendarStore(events: [event()]) }, actions: { FakeCalendarStore() },
                                 mail: { FakeMailStore() }, directory: { directory }, clock: { now }, syncedAt: { nil },
                                 use24Hour: { false })
        plain.load()
        T.equal(plain.card?.recorder, nil, "the shared session (no Murmur in tests): nothing")
    }

    static func popoverWithMurmur() {
        T.section("murmur: the popover card with it")
        let mf = Fake()
        mf.marks = MurmurMarks.parse(json(#"{"v":1,"marks":{"gMurmurWeekly01":{"liveHelperKind":"interview","mode":"homelab","status":"meOnly"}}}"#))
        let ms = session(mf)
        let ff = FathomFake()
        let fs = fathom(ff)
        var choices: [UUID: RecorderChoice] = [:]
        let model = popover(murmur: ms, fathom: fs, events: [event()], choice: { choices[$0] ?? .automatic })
        T.equal(model.card?.recorder, .murmur, "no Fathom on this Mac: Yaya's Murmur")
        T.equal(model.card?.badges ?? [], [.liveHelper, .meOnly], "badges on the card")
        T.equal(model.card?.murmurMark?.mode, .homelab, "the mark's mode for the line")
        T.equal(model.badges("gMurmurWeekly01"), [.liveHelper, .meOnly], "and on its row")
        if let card = model.card {
            T.equal(model.joinMenu(card).map(\.title), ["Join with Yaya\u{2019}s Murmur", "-", "Just join"], "the menu without Fathom")
        }
        ff.installed = true
        model.load()
        T.equal(model.card?.recorder, .fathom, "Fathom installed, automatic: Fathom, as today")
        if let card = model.card {
            T.equal(model.joinMenu(card).first?.title, "Join with Fathom", "the menu leads with Fathom")
        }
        choices[orb] = .ask
        model.load()
        T.equal(model.card?.recorder, .ask, "ask each time")
        choices[orb] = .off
        model.load()
        T.equal(model.card?.recorder, .off, "off")
        mf.installed = false
        model.load()
        T.equal(model.card?.recorder, nil, "Murmur removed: back to as before")
    }

    static func peekWithoutMurmur() {
        T.section("murmur: hidden without it (the Event Peek as before)")
        let mf = Fake()
        mf.installed = false
        let model = EventPeekModel(event: event(), directory: directory, actions: FakeCalendarStore(), open: { _ in true },
                                   fathom: fathom(FathomFake()), murmur: session(mf), recorderChoice: { _ in .murmur })
        T.equal(model.recorder, nil, "no recorder")
        T.check(!model.showsLiveHelper, "no Live Helper row")
        T.equal(model.badges, [], "no badges")
    }

    static func peekWithMurmur() {
        T.section("murmur: the Event Peek with it")
        let mf = Fake()
        mf.marks = MurmurMarks.parse(json(#"{"v":1,"marks":{"gMurmurWeekly01":{"liveHelperKind":"discussion","consentTier":"explicit","status":"notesReady"}}}"#))
        let ms = session(mf)
        var closed = 0
        let model = EventPeekModel(event: event(), directory: directory, actions: FakeCalendarStore(), open: { _ in true },
                                   fathom: fathom(FathomFake()), murmur: ms, recorderChoice: { _ in .automatic })
        model.onClose = { closed += 1 }
        T.equal(model.recorder, .murmur, "Murmur")
        T.check(model.showsLiveHelper, "the Live Helper row")
        T.equal(model.badges, [.liveHelper, .notesReady, .explicitConsent], "badges")
        T.equal(model.joinMenu.map(\.title), ["Join with Yaya\u{2019}s Murmur", "-", "Just join"], "its menu")
        model.perform(.murmur(.macbook))
        T.equal(mf.opened.first?.absoluteString, "\(Profile.murmurScheme)://join?event=gMurmurWeekly01&mode=macbook", "the menu's MacBook")
        T.equal(closed, 1, "the Peek closes")
        mf.opened = []
        model.openHelper()
        T.equal(mf.opened.first?.host, "helper", "the switch opens Murmur's helper setup")
        model.openNotes()
        T.equal(mf.opened.last?.host, "open", "Open the notes")
        let allDay = EventPeekModel(event: event(allDay: true), directory: directory, actions: FakeCalendarStore(),
                                    open: { _ in true }, fathom: fathom(FathomFake()), murmur: ms)
        T.check(!allDay.showsLiveHelper, "no Live Helper for an all-day event")
    }

    // MARK: Snapshot

    static func snapshot() {
        T.section("murmur: snapshot recBy")
        let base = WidgetSnapshot.Meeting(r: "g1", k: "k1", accountIds: ["a"], title: "T", start: now, end: now, allDay: false,
                                          place: nil, hasJoin: true, reply: .accepted, clashes: false, rec: true)
        let fathomJSON = String(data: (try? WidgetSnapshot.encoder.encode(base)) ?? Data(), encoding: .utf8) ?? ""
        T.check(!fathomJSON.contains("recBy"), "Fathom (nil) is left out: D-045 files hash the same")
        var murmur = base
        murmur.recBy = "murmur"
        let data = (try? WidgetSnapshot.encoder.encode(murmur)) ?? Data()
        T.check(String(data: data, encoding: .utf8)?.contains(#""recBy":"murmur""#) ?? false, "recBy is written")
        T.equal((try? WidgetSnapshot.decoder.decode(WidgetSnapshot.Meeting.self, from: data))?.recBy, "murmur", "and read back")
        T.equal((try? WidgetSnapshot.decoder.decode(WidgetSnapshot.Meeting.self, from: Data(fathomJSON.utf8)))?.recBy, nil,
                "an older meeting decodes with recBy nil")
    }
}

/// A row id the calendar makes (Sources/Store/EventRepo.swift is not in this binary): "e"/"g" + 22 base64url characters.
enum EventIdsProbe {
    static let sample = "gK3vZ-_q09AbCdEfGhIjKl"
}
