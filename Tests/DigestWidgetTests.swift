import Foundation

/// The Daily Digest widget (D-053): the helper's digest distilled per mailbox, the read state, the snapshot seam, the
/// whole-card states, the layout's fit for any number of mailboxes, the taps and their route, and the words.
enum DigestWidgetTests {
    static let home = FixtureAccounts.home.uuidString
    static let orb = FixtureAccounts.orb.uuidString
    static let cmt = FixtureAccounts.cmt.uuidString

    static func run() {
        distil()
        readState()
        seam()
        states()
        layout()
        taps()
        words()
        timeline()
        atlas()
    }

    static func atlas() {
        T.section("Model Atlas box (D-054): the feed")
        let file = #"""
        {"version": 1, "updated_at": 1793392915, "source": "model-atlas", "title": "Model Atlas", "report": "2026-10-17",
         "scan": "2026-10-17_1008", "lines": [{"text": "New: Pickle-7B\u0007 runs on a 16 GB Mac.", "kind": "New"},
         {"text": "", "kind": "try"}, {"text": 5}], "alerts": ["Backups growing", 7],
         "counts": {"models": 24}, "open": {"atlas": "/Users/a/Notes/Model Atlas/ATLAS.md",
         "report": "/Users/a/Notes/Model Atlas/landscape/2026-10-17.md"}}
        """#
        guard let d = ModelAtlasParse.digest(Data(file.utf8)).value else { return T.check(false, "the feed parses") }
        T.equal(d.report, "2026-10-17", "report day")
        T.equal(d.lines.map(\.text), ["New: Pickle-7B runs on a 16 GB Mac."], "lines: cleaned, empty and wrong-typed ones skipped")
        T.equal(d.lines.first?.kind, "new", "kind lower-cased")
        T.equal(d.alerts, ["Backups growing"], "alerts: strings only")
        T.equal(d.models, 24, "models")
        T.equal(d.seenKey, "2026-10-17", "opened-once key = the report")
        T.check(ModelAtlasParse.digest(nil) == .missing, "no file = no box")
        T.check(ModelAtlasParse.digest(Data(#"{"version": 2}"#.utf8)) == .newer, "a newer version is ignored")
        T.check(ModelAtlasParse.digest(Data(#"{"version": "1"}"#.utf8)) == .unreadable, "version must be the integer 1")
        T.check(ModelAtlasParse.digest(Data(repeating: 32, count: ModelAtlasFiles.fileLimit + 1)) == .unreadable, "over 64 KiB is refused")
        var bad = d; bad.report = nil
        T.equal(bad.seenKey, "2026-10-17_1008", "no report: the scan is the key")
        T.equal(ModelAtlasParse.snapshot(d, seen: nil).fresh, true, "new until opened")
        T.equal(ModelAtlasParse.snapshot(d, seen: "2026-10-17").fresh, nil, "opened: not new")
        T.equal(ModelAtlasParse.snapshot(d, seen: "2026-10-10").fresh, true, "a newer report is new again")
        T.equal(ModelAtlasFiles.changedNotification, Profile.modelAtlasId + ".changed", "ping name")

        T.section("Model Atlas box (D-054): what a tap may open")
        let home = "/Users/a"
        T.equal(ModelAtlasOpen.target(d, home: home), "/Users/a/Notes/Model Atlas/landscape/2026-10-17.md", "the week's report first")
        var noReport = d; noReport.reportPath = nil
        T.equal(ModelAtlasOpen.target(noReport, home: home), "/Users/a/Notes/Model Atlas/ATLAS.md", "else the atlas")
        for path in ["/Users/b/Model Atlas/ATLAS.md", "/Users/a/Model Atlas/../.ssh/ATLAS.md", "/Users/a/Model Atlas/run.sh",
                     "/Users/a/Elsewhere/ATLAS.md", "/Users/a/Model Atlas/landscape/notes.md", "relative/Model Atlas/ATLAS.md",
                     "/Users/a/Model Atlas/landscape/2026-02-30.md", "/Users/a/Model Atlas//ATLAS.md"] {
            T.equal(ModelAtlasOpen.allowed(path, home: home), nil, "refused: \(path)")
        }

        T.section("Model Atlas box (D-054): on the widget")
        guard let m = model("digestAtlas"), var digest = m.digest else { return T.check(false, "digestAtlas model") }
        T.equal(digest.unread, 12, "not mail: the badge is unchanged")
        T.equal(digest.items.count, digest.boxes.count + 1, "one box after the mailboxes")
        T.equal(digest.items.last?.atlas?.fresh, true, "new")
        T.check(!digest.headlines(3).contains { $0.section == WidgetDigest.atlasSection }, "not in the mail summary")
        T.equal(digest.atlasWeek, "Week of 17 Oct", "week label")
        T.check(!digest.atlasStale, "two days old: not dim")
        digest.now = SnapshotFixtures.now.addingTimeInterval(6 * 86_400)
        T.check(digest.atlasStale, "eight days on: dim")
        T.check(digest.isRead(WidgetDigest.atlasSection), "its lines dim with it")
        T.equal(YayaLink.openAtlas().absoluteString, "\(RouteTable.scheme)://open/atlas", "tap link")
        T.equal(RouteDecider.decide(Route.parse(YayaLink.openAtlas())!) { _, _ in true }, .openAtlas, "route decides")
        guard let old = model("digestAtlasOld")?.digest else { return T.check(false, "digestAtlasOld model") }
        T.equal(old.items.last?.top.first?.section, WidgetDigest.atlasAlert, "alerts first")
        T.equal(old.items.last?.atlas?.fresh, false, "opened already")
        let style = WidgetStyle()
        for family in Family.allCases where family != .small {
            let shown = DigestWidget.shownBoxes(family: family, digest: old, style: style)
            let vis = old.visible(shown)
            T.check(vis.items.last?.atlas != nil, "\(family.short): the atlas keeps its place when mailboxes spill")
            T.equal(vis.items.count + vis.hidden, old.items.count, "\(family.short): shown + more = all")
        }
        T.check(model("busy")?.digest?.atlas == nil, "no file: no box")
        T.check(WidgetSample.digest(now: SnapshotFixtures.now, accounts: WidgetSample.accounts(logos: nil)).atlas == nil,
                "never in the public preview")
        T.equal(WidgetA11y.digestAtlas("Week of 17 Oct", fresh: true, line: "New: x"), "Model Atlas, week of 17 Oct, new, New: x", "words")
    }

    static func model(_ name: String) -> SnapshotModel? {
        SnapshotFixtures.roundTrip(SnapshotFixtures.named(name, kind: WidgetKinds.digest.kind)).map { SnapshotModel($0, logo: { _ in nil }) }
    }

    static func distil() {
        T.section("digest widget: one box per mailbox, in the calendar's order")
        let d = FixtureDigest.snapshot()
        T.equal(d.id, 42, "the digest's id")
        T.equal(d.day, "2026-10-19", "its day")
        // The helper has Personal, ORB and CMT (FAM isn't handed over); the calendar orders ORB, CMT, FAM, Personal.
        T.equal(d.boxes.map(\.account), [orb, cmt, home], "mailboxes: the helper's, in the calendar's order")
        T.check(d.boxes.allSatisfy { $0.label == nil }, "mailboxes the calendar knows carry no label")
        let byId = Dictionary(uniqueKeysWithValues: d.boxes.map { ($0.account, $0) })
        T.equal(byId[orb]?.counts ?? ["x": 1], [:], "ORB: a quiet day keeps its box")
        T.equal(byId[orb]?.top.count, 0, "ORB has no lines")
        T.equal(byId[home]?.counts, ["newsletters": 2, "updates": 5, "promotions": 1, "orders": 2, "security": 1],
                "Personal's counts (an update group counts its threads)")
        T.equal(byId[cmt]?.counts, ["newsletters": 1, "promotions": 1], "CMT's counts")
        for s in d.sections {
            let sum = d.boxes.reduce(0) { $0 + ($1.counts[s.key] ?? 0) }
            T.equal(sum, s.count, "\(s.key): the mailboxes add up to the section")
        }
        T.equal(byId[home]?.top.first?.text, "A pickle-sized satellite arm passes its first vacuum test", "Personal leads with its pick")
        T.equal(byId[home]?.top.first?.pick, true, "the pick is marked")
        T.equal(byId[cmt]?.top.first?.text, "Members get the Friday show at half price", "CMT leads with its pick")
        T.check(byId[home]?.top.contains { $0.section == "security" } == false, "a read section's lines rank last")
        T.check(d.boxes.allSatisfy { $0.top.count <= WidgetSnapshot.Digest.maxLines }, "at most 3 lines a box")
        T.equal(d.sections.map(\.read), [false, false, false, false, true], "read state per section (codes and security read)")

        T.section("digest widget: mailboxes the calendar doesn't know, caps")
        var digest = MailHelperParse.digest(Data(MailHelperFixtures.digest.utf8)).value!!
        digest.sections[0].items[0].account = "00000000-0000-4000-8000-0000000000c9"
        digest.sections[0].items[0].accountEmail = "avery@lanternhall.example"
        digest.sections[0].items[0].headline = String(repeating: "Long headline ", count: 20)
        let mailboxes = (0..<20).map { MailHelperDigestWidget.Mailbox(id: String(format: "00000000-0000-4000-8000-0000000001%02d", $0),
                                                                      email: "box\($0)@example.example") }
        let many = MailHelperDigestWidget.snapshot(digest, mailboxes: mailboxes, known: [FixtureAccounts.home])
        T.equal(many.boxes.count, WidgetSnapshot.Digest.maxBoxes, "at most 12 mailboxes")
        T.equal(many.boxes.first?.account, home, "the calendar's accounts first")
        let few = MailHelperDigestWidget.snapshot(digest, mailboxes: [], known: FixtureAccounts.all.map(\.id))
        let stranger = few.boxes.first { $0.account == "00000000-0000-4000-8000-0000000000C9" }
        T.equal(stranger?.label, "avery@lanternhall.example", "an unknown mailbox is named by the helper's address (id normalised)")
        T.check((stranger?.top.first?.text.count ?? 999) <= WidgetSnapshot.Digest.maxText, "lines capped at 140 characters")
        T.check(stranger?.top.first?.text.hasSuffix("\u{2026}") == true, "a capped line ends with …")
        T.equal(few.boxes.last?.account, "00000000-0000-4000-8000-0000000000C9", "unknown mailboxes after the calendar's")
    }

    static func readState() {
        T.section("digest widget: unread falls as sections are read")
        guard let m = model("busy"), let digest = m.digest else { return T.check(false, "busy digest model") }
        T.equal(digest.unread, 12, "badge: every section not read yet (3 + 5 + 2 + 2)")
        T.equal(digest.unreadSections, 4, "four sections to read")
        let personal = digest.boxes.first { $0.account.id == home }
        T.equal(personal?.unread, 10, "Personal: 10 unread (its code is read)")
        T.equal(personal?.total, 11, "Personal: 11 in all")
        T.equal(personal?.part, "newsletters", "Personal's tap: its first unread section")
        let quiet = digest.boxes.first { $0.account.id == orb }
        T.equal(quiet?.part, nil, "a quiet mailbox opens the digest's top")
        T.equal(quiet?.total, 0, "ORB: nothing today")
        T.equal(digest.firstUnread, "newsletters", "the badge opens the first unread section")

        var snapshot = SnapshotFixtures.named("busy", kind: WidgetKinds.digest.kind)
        snapshot.digest?.sections[0].read = true
        let after = WidgetDigest(snapshot.digest!, account: { WidgetAccount(id: $0, short: "", name: "", logo: nil) })
        T.equal(after.unread, 9, "newsletters read: 9 left")
        T.equal(after.firstUnread, "updates", "the next section comes first")
        guard let all = model("digestAllRead")?.digest else { return T.check(false, "all-read model") }
        T.check(all.allRead && all.unread == 0, "all read: the badge clears")
        T.check(all.boxes.allSatisfy { $0.unread == 0 }, "every mailbox clears")
        T.equal(all.firstUnread, nil, "all read: taps open the top")
    }

    static func seam() {
        T.section("digest widget: snapshot seam (version 1, additive)")
        let busy = SnapshotFixtures.named("busy", kind: WidgetKinds.agenda.kind)
        let json = String(data: SnapshotFixtures.json(busy), encoding: .utf8) ?? ""
        T.check(!json.contains("\"digest\""), "other kinds' files carry no digest key (unchanged hashes)")
        let digest = SnapshotFixtures.named("busy", kind: WidgetKinds.digest.kind)
        T.equal(digest.v, 1, "the version stays 1")
        T.equal(SnapshotFixtures.roundTrip(digest), digest, "the digest survives the widget's read path")
        T.check(SnapshotFixtures.json(digest).count < WidgetSnapshot.maxBytes, "well under 192 KB")
        T.equal(digest.meetings.count + digest.mail.count, 0, "no meetings or mail of its own")
        T.equal(Set(digest.accounts.map(\.id)), Set([orb, cmt, home]), "accounts = the mailboxes (their logos)")
        T.equal(digest.health.syncedAt, nil, "no sync time: the calendar's strip never shows on it")
        T.equal(WidgetKinds.digest.families, Family.allCases, "every family")
        T.equal(WidgetKinds.spec("digest")?.galleryName, "Daily Digest", "gallery name")
    }

    static func states() {
        T.section("digest widget: states")
        let spec = WidgetKinds.digest
        let cases: [(String, WidgetCardState)] = [("busy", .content), ("digestAllRead", .content), ("digestMany", .content),
                                                  ("digestNone", .noDigest), ("mailHelperOff", .mailHelperOff)]
        for (name, state) in cases {
            guard let m = model(name) else { T.check(false, "\(name) model"); continue }
            T.equal(m.cardState, state, "\(name) card state")
            let data = m.data(at: SnapshotFixtures.now)
            for family in Family.allCases {
                let resolved = KindView.resolve(spec: spec, family: family, data: data)
                T.equal(resolved, state == .content ? .design(.digest) : .card(state), "\(name) \(family.short) resolves")
            }
        }
        T.check(DigestCopy.all.allSatisfy { !$0.isEmpty && !$0.lowercased().contains("coming soon") && !$0.lowercased().contains("later version") },
                "honest empty-state copy: no promises")
        T.check(DigestCopy.offTitle.contains("isn\u{2019}t on this Mac"), "no helper: says so")
    }

    static func layout() {
        T.section("digest widget: any number of mailboxes fits")
        guard let many = model("digestMany"), let busy = model("busy") else { return T.check(false, "models") }
        var style = WidgetStyle()
        let manyDigest = many.digest!, busyDigest = busy.digest!
        T.equal(manyDigest.boxes.count, 7, "digestMany: three known mailboxes and four the calendar doesn't know")
        for family in Family.allCases {
            let shownBusy = DigestWidget.shownBoxes(family: family, digest: busyDigest, style: style)
            T.equal(shownBusy, 3, "busy \(family.short): all three mailboxes drawn")
            let shown = DigestWidget.shownBoxes(family: family, digest: manyDigest, style: style)
            T.check(shown >= 1 && shown <= 7, "many \(family.short): \(shown) drawn, the rest in +N")
        }
        T.equal(DigestLayout.medium(4, style: style).hidden, 0, "Medium fits four mailboxes")
        T.check(DigestLayout.medium(6, style: style).hidden > 0, "Medium: six spill into +N more")
        T.equal(DigestLayout.extraLarge(6, style: style).hidden, 0, "Extra Large fits six")
        style.textSize = .large
        let big = DigestLayout.medium(4, style: style)
        T.equal(big.shown + big.hidden, 4, "Large text: shown + more = all")
        T.equal(DigestLayout.fit(0, height: 100, item: 20, more: 10).shown, 0, "no mailboxes, nothing drawn")
        T.equal(DigestLayout.fit(5, height: 100, item: 20, more: 10).hidden, 0, "exact fit, no +N")
        let tight = DigestLayout.fit(6, height: 100, item: 20, more: 10)
        T.equal(tight.shown, 4, "one short: room for +N")
        T.equal(tight.hidden, 2, "the rest counted")

        T.section("digest widget: summary of the summary")
        let lines = busyDigest.headlines(3)
        T.equal(lines.count, 3, "three lines on XL")
        T.check(lines.first?.pick == true, "picks lead")
        T.equal(Set(lines.map(\.text)).count, lines.count, "no line twice")
        T.check(!lines.contains { busyDigest.isRead($0.section) }, "unread sections first")
        T.equal(busyDigest.countsLine(limit: 3), "Newsletters 3 \u{00B7} Updates 5 \u{00B7} Deals 2 \u{00B7} +2",
                "counts: unread sections in order, then +N")
        T.equal(busyDigest.dayLabel(now: SnapshotFixtures.now), "Today", "Monday's digest on Monday")
        let tuesday = SnapshotFixtures.now.addingTimeInterval(86_400)
        T.equal(busyDigest.dayLabel(now: tuesday), "Yesterday", "on Tuesday")
        T.equal(busyDigest.dayLabel(now: tuesday.addingTimeInterval(86_400)), "Mon 19 Oct", "later: the date")
        let sample = WidgetSample.digest(now: SnapshotFixtures.now, accounts: WidgetSample.accounts(logos: nil))
        T.equal(sample.boxes.count, 4, "the gallery sample has four mailboxes")
        T.equal(sample.unread, 10, "the sample's badge")
    }

    static func taps() {
        T.section("digest widget: taps and their route")
        T.equal(YayaLink.openDigest().absoluteString, "\(RouteTable.scheme)://open/app?section=mailhelper&tab=digest", "badge / header")
        T.equal(YayaLink.openDigest(part: "social").absoluteString,
                "\(RouteTable.scheme)://open/app?section=mailhelper&tab=digest&part=social", "a section")
        T.check(!YayaLink.openDigest(part: "bad value!").absoluteString.contains("part"), "an unsafe part is left out")
        func decide(_ s: String) -> RouteAction { RouteDecider.decide(Route.parse(URL(string: s)!)!) { _, _ in true } }
        let scheme = RouteTable.scheme
        T.equal(decide("\(scheme)://open/app?section=mailhelper&tab=digest&part=social"), .openDigest(part: "social"), "Digest tab at a section")
        T.equal(decide("\(scheme)://open/app?section=mailhelper&tab=digest"), .openDigest(part: nil), "Digest tab")
        T.equal(decide("\(scheme)://open/app?section=mailhelper"), .openApp(.mailHelper), "no tab: the section as before")
        T.equal(decide("\(scheme)://open/app?section=mailhelper&tab=overview"), .openApp(.mailHelper), "another tab: the section")
        T.equal(decide("\(scheme)://open/app?section=inbox&tab=digest"), .openApp(.inbox), "tab only with the Mail helper")
        T.equal(decide("\(scheme)://sync?w=digest"), .sync(kind: "digest"), "↻ = sync?w=digest")
        T.check(Route.parse(URL(string: "\(scheme)://open/app?section=mailhelper&tab=digest")!)?.quiet == false, "opens the window")
    }

    static func words() {
        T.section("digest widget: VoiceOver words")
        T.equal(WidgetA11y.digestBadge(unread: 0), "Digest, all read", "all read")
        T.equal(WidgetA11y.digestBadge(unread: 1), "1 unread in the digest", "one")
        T.equal(WidgetA11y.digestBadge(unread: 12), "12 unread in the digest", "many")
        T.equal(WidgetA11y.digestBox("Orbital Pickle Co.", unread: 0, total: 0, line: nil),
                "Orbital Pickle Co., nothing in today\u{2019}s digest", "a quiet mailbox")
        T.equal(WidgetA11y.digestBox("Personal", unread: 3, total: 5, line: "Brine, explained"), "Personal, 3 unread, Brine, explained", "a mailbox")
        T.equal(WidgetA11y.digestSection("Social", count: 5, read: false), "Social, 5, not read yet", "a section")
        T.equal(WidgetA11y.digestSection("Updates", count: 5, read: true), "Updates, read", "a read section")
        T.equal(WidgetA11y.digestLine("Half price", pick: true), "Worth opening: Half price", "a pick")
    }

    static func timeline() {
        T.section("digest widget: timeline (D-019)")
        guard let m = model("busy") else { return T.check(false, "model") }
        for family in Family.allCases {
            let plan = TimelinePlan.timeline(now: SnapshotFixtures.now, model: m, spec: WidgetKinds.digest, family: family)
            T.check(plan.entries.count >= 1 && plan.entries.count <= TimelinePlan.maxEntries + TimelinePlan.maxSettleEntries,
                    "\(family.short): \(plan.entries.count) entries")
            let midnight = WidgetCalendar.current.date(byAdding: .day, value: 1, to: WidgetCalendar.current.startOfDay(for: SnapshotFixtures.now))!
            T.check(plan.entries.contains(midnight), "\(family.short): midnight (Today becomes Yesterday)")
        }
    }
}
