import AppKit
import Combine
import Foundation

/// UI layer: mail route decisions, the undo book and toast timing, composer draft building
/// (From default, quoting, signature, the "Ask before sending" approval card, D-023), widget mail row links + "Archived · Undo"
/// timeline entries, the reader's content-rule decision, the Inbox section and Settings → Mail models,
/// and Studio gating by the mail switch (`mailEnabled`). Fakes only: no Keychain, network, user defaults or real mail.
@MainActor
enum MailTests {
    static let cal = WidgetCalendar.fixed
    static let now = WidgetSample.fixedNow
    static let own = Set(FixtureMail.ownAddresses)

    static func run() async {
        routes()
        undoBook()
        await toastTiming()
        mailText()
        keys()
        composerText()
        await composerModel()
        await composerApproval()
        approvalText()
        widgetRows()
        timeline()
        contentPolicy()
        reader()
        await inboxSection()
        await mailPeek()
        settingsMail()
        studioGating()
        traceOverride()
    }

    // MARK: Router

    static func decide(_ url: String, mail: Bool = true) -> RouteAction {
        guard let route = Route.parse(URL(string: url)!) else { return .ignore(route: "?", reason: "unparsed") }
        return RouteDecider.decide(route, mailEnabled: mail) { FixtureLinkKeys.verify(r: $0, k: $1) }
    }

    static func routes() {
        T.section("router: mail routes")
        let r = "th-milo", k = FixtureLinkKeys.k("th-milo"), other = FixtureLinkKeys.k("th-rafa")
        T.equal(decide("yayacal://mail/read?r=\(r)&k=\(k)"), .mailRead(r: r), "mail/read")
        T.equal(decide("yayacal://mail/archive?r=\(r)&k=\(k)"), .mailArchive(r: r), "mail/archive")
        T.equal(decide("yayacal://mail/undo?r=\(r)&k=\(k)"), .mailUndo(r: r), "mail/undo")
        T.equal(decide("yayacal://mail/star?r=\(r)&k=\(k)"), .mailStar(r: r), "mail/star")
        T.equal(decide("yayacal://open/message?r=\(r)&k=\(k)"), .openMessage(r: r), "open/message")
        for route in ["mail/read", "mail/archive", "mail/undo", "mail/star", "open/message"] {
            T.equal(decide("yayacal://\(route)?r=\(r)&k=\(other)"), .ignore(route: route, reason: "bad-key"), "\(route): another row's key")
            T.equal(decide("yayacal://\(route)?r=\(r)"), .ignore(route: route, reason: "missing-param"), "\(route): no key")
            T.equal(decide("yayacal://\(route)?r=\(r)&k=\(k)", mail: false), .ignore(route: route, reason: "mail-off"),
                    "\(route): ignored while mail is off")
        }
        T.equal(decide("yayacal://mail/read?r=a%20b&k=\(k)"), .ignore(route: "mail/read", reason: "missing-param"), "unsafe r is dropped by the parser")
        var verified = 0
        _ = RouteDecider.decide(Route.parse(URL(string: "yayacal://mail/read?r=\(r)&k=\(k)")!)!, mailEnabled: false) { _, _ in verified += 1; return true }
        T.equal(verified, 0, "mail off: the key is never checked")
        T.equal(Route.parse(URL(string: "yayacal://mail/archive?r=\(r)&k=\(k)")!)?.quiet, true, "mail/archive is quiet")
        T.equal(Route.parse(URL(string: "yayacal://open/message?r=\(r)&k=\(k)")!)?.quiet, false, "open/message is not quiet (Mail Peek)")
        T.equal(RouteAction.mailUndo(r: r).name, "mail/undo", "trace name")
        for spec in RouteTable.all {
            let action = decide(YayaLink.url(spec.name, spec.params.map { ($0, "x") }).absoluteString)
            T.check(action.name != "later", "\(spec.name) is handled by this build (got \(action.name))")
        }
    }

    static func undoBook() {
        T.section("mail undo book (mail/undo within 30 s)")
        let book = MailUndoBook()
        book.record(r: "th1", token: UndoToken(id: "t1"), kind: .archive, at: now)
        T.equal(book.peek(r: "th1", now: now.addingTimeInterval(29.9))?.token.id, "t1", "live at 29.9 s")
        T.equal(book.take(r: "th1", now: now.addingTimeInterval(29.9))?.kind, .archive, "take within 30 s")
        T.equal(book.take(r: "th1", now: now.addingTimeInterval(1)), nil, "taken once only")
        book.record(r: "th2", token: UndoToken(id: "t2"), kind: .trash, at: now)
        T.equal(book.take(r: "th2", now: now.addingTimeInterval(30)), nil, "expired at 30 s")
        book.record(r: "th3", token: UndoToken(id: "a"), kind: .archive, at: now)
        book.record(r: "th3", token: UndoToken(id: "b"), kind: .trash, at: now.addingTimeInterval(5))
        T.equal(book.take(r: "th3", now: now.addingTimeInterval(6))?.token.id, "b", "the last archive/trash of the row wins")
        book.record(r: "old", token: UndoToken(id: "o"), kind: .archive, at: now)
        book.record(r: "new", token: UndoToken(id: "n"), kind: .archive, at: now.addingTimeInterval(40))
        T.equal(book.count, 1, "stale entries pruned on record")
        T.equal(MailUndo.window, 30, "undo window is 30 s (CONTRACTS)")
    }

    /// A clock tests move by hand, and a scheduler that records instead of waiting.
    final class Clock {
        var now: Date
        var scheduled: [(TimeInterval, () -> Void)] = []
        init(_ now: Date) { self.now = now }
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { scheduled.append((delay, work)) }
    }

    static func toastTiming() async {
        T.section("undo toast timing")
        let clock = Clock(now)
        let center = MailToastCenter(clock: { clock.now }, schedule: { clock.schedule($0, $1) })
        var undone = 0
        let toast = center.show("Archived") { undone += 1 }
        T.equal(toast.line, "Archived · Undo", "reads \u{201C}Archived · Undo\u{201D}")
        T.equal(toast.expiresAt, now.addingTimeInterval(30), "lives 30 s")
        T.equal(clock.scheduled.last?.0, 30, "expiry scheduled at 30 s")
        clock.now = now.addingTimeInterval(29.5)
        T.equal(center.isLive(at: clock.now), true, "live at 29.5 s")
        T.equal(await center.performUndo(), true, "Undo at 29.5 s works")
        T.equal(undone, 1, "…runs the undo once")
        T.equal(center.toast, nil, "…and the toast goes")
        T.equal(await center.performUndo(), false, "a second Undo does nothing")

        clock.now = now
        center.show("Moved to Trash") { undone += 1 }
        clock.now = now.addingTimeInterval(30)
        T.equal(await center.performUndo(), false, "Undo at 30 s is too late")
        T.equal(undone, 1, "…nothing undone")

        clock.now = now
        let first = center.show("Starred") { undone += 1 }
        let firstExpiry = clock.scheduled.last!.1
        let second = center.show("Archived") { undone += 1 }
        firstExpiry()
        T.equal(center.toast?.id, second.id, "an older toast's timer never clears a newer toast")
        T.check(first.id != second.id, "toasts get new ids")
        clock.scheduled.last!.1()
        T.equal(center.toast, nil, "its own timer clears it")

        let error = center.error("I couldn\u{2019}t archive that.")
        T.equal(error.action, nil, "errors have no Undo")
        T.equal(error.expiresAt, now.addingTimeInterval(5), "errors stay 5 s")
        T.equal(error.isError, true, "error look")
        let noUndo = center.show("Saved", undo: nil)
        T.equal(noUndo.line, "Saved", "no undo closure → no Undo button")
    }

    // MARK: Text + keys

    static func mailText() {
        T.section("mail text")
        let today = now.addingTimeInterval(-7 * 60)
        T.equal(MailText.listTime(today, now: now, calendar: cal), "9:41 AM", "today: the time")
        T.equal(MailText.listTime(now.addingTimeInterval(-86_400), now: now, calendar: cal), "Yesterday", "yesterday")
        T.equal(MailText.listTime(now.addingTimeInterval(-3 * 86_400), now: now, calendar: cal), "Friday", "this week: weekday")
        T.equal(MailText.listTime(now.addingTimeInterval(-20 * 86_400), now: now, calendar: cal), "29 Sep", "this year: day + month")
        T.equal(MailText.listTime(now.addingTimeInterval(-400 * 86_400), now: now, calendar: cal), "14 Sep 2025", "older: with the year")
        T.equal(MailText.size(186_420), "186 KB", "KB")
        T.equal(MailText.size(2_431_000), "2.4 MB", "MB with one decimal")
        T.equal(MailText.size(12_400_000), "12 MB", "big MB rounded")
        T.equal(MailText.size(512), "512 bytes", "bytes")
        T.equal(MailText.addresses("a@b.example, Milo <Milo@QUIETCOMETS.example>; c@d.example\n"), ["a@b.example", "milo@quietcomets.example", "c@d.example"],
                "plain comma entry: commas, semicolons, new lines, Name <address>")
        T.equal(MailText.addresses(" , ;"), [], "blank entries dropped")
        for good in ["a@b.example", "first.last+tag@sub.domain.example"] { T.check(MailText.isAddress(good), "valid: \(good)") }
        for bad in ["a@b", "@b.example", "a@.example", "a b@c.example", "a@b.example".appending("."), "ab.example", "a@b@c.example", "<a@b.example>"] {
            T.check(!MailText.isAddress(bad), "invalid: \(bad)")
        }
        T.equal(MailText.recipients(to: ["avery@quietcomets.example"], cc: ["wren@quietcomets.example"], own: own), "to me, wren@quietcomets.example", "to me + cc")
        T.equal(MailText.recipients(to: ["a@x.example", "b@x.example", "c@x.example"], cc: [], own: own), "to a@x.example, b@x.example and 1 more",
                "long lists fold")
        T.equal(MailText.firstName("Milo Brightwater"), "Milo", "first name")
    }

    static func keys() {
        T.section("Inbox keys (Gmail's)")
        let cases: [(String?, UInt16, InboxCommand?)] = [
            ("j", 38, .next), ("k", 40, .previous), ("e", 14, .archive), ("u", 32, .toggleUnread), ("s", 1, .toggleStar),
            ("#", 20, .trash), ("r", 15, .reply), ("\r", 36, .open), (nil, 76, .open), (nil, 125, .next), (nil, 126, .previous),
            ("x", 7, nil), ("J", 38, nil),
        ]
        for (chars, code, expected) in cases {
            T.equal(InboxCommand.from(characters: chars, keyCode: code, commandKeys: false), expected, "key \(chars ?? "code \(code)")")
        }
        T.equal(InboxCommand.from(characters: "e", keyCode: 14, commandKeys: true), nil, "⌘E belongs to menus, not archive")
        T.equal(InboxCommand.from(characters: "r", keyCode: 15, commandKeys: true), nil, "⌘R ignored")
    }

    // MARK: Composer

    static var accounts: [DirectoryAccount] { FixtureAccounts.directory().accounts }
    static func thread(_ r: String) -> FixtureThread { FixtureMail.threads(now: now, calendar: cal).first { $0.thread.r == r }! }
    static func latest(_ r: String) -> MailMessage { thread(r).messages.max { $0.date < $1.date }! }

    static func composerText() {
        T.section("composer: subject, quote, signature, recipients, From default")
        T.equal(ComposerText.replySubject("Mix notes"), "Re: Mix notes", "Re: added")
        T.equal(ComposerText.replySubject("RE: Mix notes"), "RE: Mix notes", "never Re: Re:")
        T.equal(ComposerText.replySubject("  "), "Re: (no subject)", "empty subject")
        let milo = latest("th-milo")
        let quote = ComposerText.quote(milo)
        let lines = quote.components(separatedBy: "\n")
        T.equal(lines.first, "On Monday 19 October 2026 at 9:41 AM, Milo Brightwater <milo@quietcomets.example> wrote:", "quote header")
        T.equal(lines[1], "> Hi Avery,", "quoted line")
        T.equal(lines[2], ">", "blank line quoted as >")
        T.check(lines.dropFirst().allSatisfy { $0.hasPrefix(">") }, "every line behind >")
        var long = milo; long.text = (1...300).map { "line \($0)" }.joined(separator: "\n")
        let clipped = ComposerText.quote(long).components(separatedBy: "\n")
        T.equal(clipped.count, 1 + ComposerText.quoteLineLimit + 1, "quote capped at 200 lines + …")
        let body = ComposerText.initialBody(signature: "Avery\nThe Quiet Comets", quote: quote)
        T.check(body.hasPrefix("\n\nAvery\nThe Quiet Comets\n\nOn Monday"), "room to type, then the signature, then the quote")
        T.equal(ComposerText.initialBody(signature: "  ", quote: nil), "\n\n", "no signature, no quote")

        let r1 = ComposerText.recipients(for: milo, all: false, own: own)
        T.equal(r1.to, ["milo@quietcomets.example"], "reply → the sender")
        T.equal(r1.cc, [], "reply: no Cc")
        let r2 = ComposerText.recipients(for: milo, all: true, own: own)
        T.equal(r2.to, ["milo@quietcomets.example"], "reply all: sender in To (I'm the only other To)")
        T.equal(r2.cc, ["wren@quietcomets.example"], "reply all keeps Cc, minus me")
        let mine = thread("th-milo").messages[1]
        T.equal(ComposerText.recipients(for: mine, all: false, own: own).to, ["milo@quietcomets.example"], "replying to my own message → its recipients")

        let t = thread("th-milo").thread
        T.equal(ComposerText.defaultFrom(.reply(t, milo), accounts: accounts, lastUsed: FixtureAccounts.orb), FixtureAccounts.cmt,
                "reply: From = the account that got the thread")
        T.equal(ComposerText.defaultFrom(.new(from: FixtureAccounts.fam), accounts: accounts, lastUsed: FixtureAccounts.orb), FixtureAccounts.fam,
                "new from a mailbox: that account")
        T.equal(ComposerText.defaultFrom(.new(), accounts: accounts, lastUsed: FixtureAccounts.home), FixtureAccounts.home,
                "new mail: the last used")
        T.equal(ComposerText.defaultFrom(.new(), accounts: accounts, lastUsed: UUID()), FixtureAccounts.orb, "last used gone → the first account")
        T.equal(ComposerText.defaultFrom(.new(), accounts: [], lastUsed: nil), nil, "no accounts → none")
    }

    static func composer(_ request: ComposerRequest, safeSend: Bool = true, local: MailLocalStore = MemoryMailLocalStore(),
                         clock: Clock = Clock(now)) -> (ComposerModel, FakeMailActions, FakeMailPreferences) {
        let store = FakeMailStore()
        let actions = FakeMailActions(store: store)
        let prefs = FakeMailPreferences()
        let model = ComposerModel(request: request, accounts: accounts, safeSend: safeSend, actions: { actions }, prefs: { prefs },
                                  local: local, clock: { clock.now }, schedule: { clock.schedule($0, $1) },
                                  toasts: MailToastCenter(clock: { clock.now }, schedule: { clock.schedule($0, $1) }))
        return (model, actions, prefs)
    }

    static func composerModel() async {
        T.section("composer: draft building")
        let t = thread("th-milo")
        let (reply, _, _) = composer(.reply(t.thread, latest("th-milo")))
        T.equal(reply.from, FixtureAccounts.cmt, "From: CMT (got the thread)")
        T.equal(reply.to, "milo@quietcomets.example", "To: Milo")
        T.equal(reply.subject, "Re: Mix notes before Tuesday", "subject: the message's, Re: once")
        T.check(reply.body.hasPrefix("\n\nAvery\nThe Quiet Comets\n\nOn Monday 19 October 2026 at 9:41 AM, Milo Brightwater"),
                "body: CMT's signature, then the quote")
        T.equal(reply.title, "Reply to Milo Brightwater", "window title")
        guard case .success(let replyDraft) = reply.draft() else { T.check(false, "an outside recipient no longer stops the draft"); return }
        T.equal(replyDraft.approvedOutside, [], "a draft carries no approval by itself")
        T.equal(reply.approvalHint, "I\u{2019}ll check with you before this goes to Milo Brightwater.", "switch on + outsider: the quiet footer hint, by name")

        let (open, openActions, _) = composer(.reply(t.thread, latest("th-milo"), all: true), safeSend: false)
        T.equal(open.cc, "wren@quietcomets.example", "reply all: Cc Wren")
        T.equal(open.showCcBcc, true, "Cc row shown when there is a Cc")
        T.equal(open.approvalHint, nil, "no hint with the switch off")
        guard case .success(let draft) = open.draft() else { T.check(false, "switch off: the reply builds"); return }
        T.check(draft.signatureIncluded, "composer drafts carry their signature in the body (never appended again)")
        T.equal(draft.from, FixtureAccounts.cmt, "draft From")
        T.equal(draft.to, ["milo@quietcomets.example"], "draft To")
        T.equal(draft.cc, ["wren@quietcomets.example"], "draft Cc")
        T.equal(draft.replyTo, "th-milo", "draft answers the thread (In-Reply-To)")
        _ = openActions

        let local = MemoryMailLocalStore()
        let clock = Clock(now)
        let (new, actions, _) = composer(.new(), local: local, clock: clock)
        T.equal(new.from, FixtureAccounts.orb, "new mail, nothing used yet: the first account")
        T.check(new.body.hasPrefix("\n\nAvery Moonfield\nOrbital Pickle Co."), "new mail: ORB's signature")
        T.equal(new.subject, "", "no subject yet")
        if case .failure(let p) = new.draft() { T.equal(p, .noRecipients, "no recipients") } else { T.check(false, "no recipients") }
        new.to = "avery@quietcomets.example, not-an-address"
        if case .failure(let p) = new.draft() { T.equal(p, .badAddress("not-an-address"), "bad address named") } else { T.check(false, "bad address") }
        new.to = "Me <AVERY@quietcomets.example>"
        new.subject = "[YC-TEST] Note to self"
        guard case .success(let own) = new.draft() else { T.check(false, "own address passes SAFE_SEND"); return }
        T.equal(own.to, ["avery@quietcomets.example"], "Name <address> → address")
        T.equal(own.replyTo, nil, "new mail answers nothing")
        new.changeFrom(FixtureAccounts.cmt)
        T.check(new.body.contains("Avery\nThe Quiet Comets") && !new.body.contains("Orbital Pickle Co."), "switching From swaps the signature")

        await new.send()
        T.equal(new.approval, nil, "own address: no approval card")
        T.equal(actions.sent.count, 1, "send → MailActions.send")
        T.equal(actions.sent.first?.from, FixtureAccounts.cmt, "sent from CMT")
        T.equal(actions.sent.first?.approvedOutside, [], "…with nothing approved")
        T.equal(new.phase, .sending(until: now.addingTimeInterval(5)), "5 s of Sending…")
        T.equal(new.toasts.toast?.line, "Sending\u{2026} · Undo", "toast: Sending… · Undo")
        T.equal(new.toasts.toast?.expiresAt, now.addingTimeInterval(5), "toast lives 5 s")
        T.equal(local.string(ComposerModel.lastFromKey), FixtureAccounts.cmt.uuidString, "remembers the last From")
        await new.undoSend()
        T.equal(actions.cancelled.count, 1, "Undo → cancelSend")
        T.equal(new.phase, .editing, "back to editing with the draft intact")
        T.equal(new.subject, "[YC-TEST] Note to self", "draft kept")

        var closed = 0
        new.onClose = { closed += 1 }
        await new.send()
        let finish = clock.scheduled.last { $0.0 == 5 }
        T.check(finish != nil, "the end of the 5 s window is scheduled")
        clock.scheduled.forEach { if $0.0 == 5 { $0.1() } }
        T.equal(new.phase, .sent, "after 5 s it has gone")
        T.equal(closed, 1, "…and the window closes")

        let (refused, refusedActions, _) = composer(.new(from: FixtureAccounts.orb))
        refusedActions.sendError = ServiceError(description: "The safety switch stopped this one.")
        refused.to = "avery@orbitalpickle.example"
        refused.subject = "Hi"
        await refused.send()
        T.equal(refused.problem, "The safety switch stopped this one.", "the data layer's friendly refusal is shown as is")
        T.equal(refused.phase, .editing, "refused → still editing")
        T.equal(ComposerModel.friendly(URLError(.notConnectedToInternet)).contains("draft is still here"), true, "other errors: generic friendly line")
    }

    static func composerApproval() async {
        T.section("composer: ask before sending to other people (D-023)")
        let t = thread("th-milo")
        let (reply, actions, _) = composer(.reply(t.thread, latest("th-milo")))
        T.equal(reply.outsiders, ["milo@quietcomets.example"], "Milo is outside your accounts")
        await reply.send()
        guard let card = reply.approval else { T.check(false, "outsider → approval card"); return }
        T.equal(card.title, "Send to Milo Brightwater?", "title: the name the composer knows")
        T.equal(card.outsiders, ["milo@quietcomets.example"], "lists Milo")
        T.equal(card.people.first?.name, "Milo Brightwater", "…by name")
        T.equal(card.fromTag, "CMT", "From tag")
        T.equal(card.fromAddress, "avery@quietcomets.example", "From address")
        T.equal(card.subject, "Re: Mix notes before Tuesday", "the subject")
        T.equal(card.people.first?.field, .to, "Milo is in To")
        T.equal(card.subtitle, "Milo isn\u{2019}t one of your own addresses, so I\u{2019}m checking first.", "subtitle: the first name")
        T.equal(card.spoken, "Send to Milo Brightwater? \("milo@quietcomets.example"). From CMT, subject Re: Mix notes before Tuesday. Return sends, Escape goes back.",
                "VoiceOver: the title names them, then their address (not the name twice)")
        T.equal(actions.sent.count, 0, "nothing sent while the card is up")
        T.equal(reply.phase, .editing, "still editing")
        T.equal(reply.problem, nil, "no problem line")
        T.equal(reply.approvalHint, nil, "the footer hint steps aside while the card is up")
        T.check(reply.isConfirming, "isConfirming")
        await reply.send()
        T.equal(actions.sent.count, 0, "Send again while the card is up: nothing (no double submit)")
        T.equal(reply.approval, card, "…the same card")

        let before = [reply.to, reply.cc, reply.bcc, reply.subject, reply.body]
        reply.cancelApproval()
        T.equal(reply.approval, nil, "Cancel closes the card")
        T.equal([reply.to, reply.cc, reply.bcc, reply.subject, reply.body], before, "Cancel keeps every field")
        T.equal(reply.from, FixtureAccounts.cmt, "…and the From")
        T.equal(reply.phase, .editing, "…still editing")
        T.equal(actions.sent.count, 0, "…nothing sent")
        await reply.approveSend()
        T.equal(actions.sent.count, 0, "approve with no card up: nothing")

        await reply.send()
        T.check(reply.approval != nil, "Send again: asks again (approvals aren't remembered)")
        await reply.approveSend()
        T.equal(actions.sent.count, 1, "approve → MailActions.send")
        T.equal(actions.sent.first?.approvedOutside, ["milo@quietcomets.example"], "approvedOutside = exactly the outsiders")
        T.equal(reply.approval, nil, "the card goes")
        T.equal(reply.phase, .sending(until: now.addingTimeInterval(5)), "then the usual 5 s of Sending…")
        T.equal(reply.toasts.toast?.line, "Sending\u{2026} · Undo", "…with Undo")
        await reply.approveSend()
        await reply.send()
        T.equal(actions.sent.count, 1, "a second approve or Send can't send twice")
        await reply.undoSend()
        T.equal(reply.phase, .editing, "Undo → editing")
        await reply.send()
        T.check(reply.approval != nil, "after Undo the next Send asks again")
        reply.cancelApproval()

        // Several outside: typed names, To → Cc → Bcc, any case, an own address and a repeat.
        let (multi, multiActions, _) = composer(.new(from: FixtureAccounts.orb))
        multi.to = "Theo Quill <Theo@MoonBase.example>, avery@QuietComets.example, ines@lanternhall.example"
        multi.cc = "\"Juniper Vale\" <juniper@orbitalpickle.example>, theo@moonbase.example"
        multi.bcc = "ops@moonbase.example, finance@moonbase.example, legal@moonbase.example, a.very.long.name.for.someone@a-long-domain.example"
        multi.subject = "[YC-TEST] Q4 plan"
        let seven = ["theo@moonbase.example", "ines@lanternhall.example", "juniper@orbitalpickle.example", "ops@moonbase.example",
                     "finance@moonbase.example", "legal@moonbase.example", "a.very.long.name.for.someone@a-long-domain.example"]
        T.equal(multi.outsiders, seven, "outsiders: To → Cc → Bcc, once each, lowercased, own address left out")
        T.equal(multi.approvalHint, "I\u{2019}ll check with you before this goes to Theo Quill and 6 others.", "the hint names the first, counts the others")
        await multi.send()
        guard let many = multi.approval else { T.check(false, "several outside → card"); return }
        T.equal(many.title, "Send to 7 people?", "several: a count in the title, one line")
        T.equal(many.subtitle, "None of these are your own addresses, so I\u{2019}m checking first.", "subtitle (several)")
        T.equal(many.outsiders, seven, "the card lists all seven (no \u{201C}+N more\u{201D}: a long list scrolls)")
        T.equal(many.people.map(\.field), [.to, .to, .cc, .bcc, .bcc, .bcc, .bcc], "Cc and Bcc tagged (Theo stays in To, his first field)")
        T.equal(many.people.map(\.name), ["Theo Quill", nil, "Juniper Vale", nil, nil, nil, nil], "typed names (quotes dropped), else the address")
        T.equal(many.fromTag, "ORB", "From ORB")
        T.check(many.spoken.hasPrefix("Send to 7 people? Theo Quill, ines@lanternhall.example, Juniper Vale in Cc, ops@moonbase.example in Bcc"),
                "VoiceOver line: \(many.spoken)")
        T.check(many.people.allSatisfy { many.spoken.contains($0.label) }, "VoiceOver hears every one of the seven")
        await multi.approveSend()
        T.equal(multiActions.sent.first?.approvedOutside, seven, "Cc and Bcc approved too, exactly the listed outsiders")
        T.check(Set(many.people.map(\.address)).isSuperset(of: multiActions.sent.first?.approvedOutside ?? ["(nothing sent)"]),
                "nothing approved that the card didn't list")
        T.equal(multiActions.sent.first?.to, ["theo@moonbase.example", "avery@quietcomets.example", "ines@lanternhall.example"], "the draft itself unchanged")

        // A wide send: three in To, four in Bcc (the last one unexpected). Every approved address is on the
        // card and in the VoiceOver line; nobody is approved unseen behind a count.
        let (probe, probeActions, _) = composer(.new(from: FixtureAccounts.orb))
        probe.to = "theo@moonbase.example, ines@lanternhall.example, juniper@orbitalpickle.example"
        probe.bcc = "ops@moonbase.example, finance@moonbase.example, legal@moonbase.example, attacker@evil.example"
        probe.subject = "[YC-TEST] Q4 plan"
        await probe.send()
        guard let probeCard = probe.approval else { T.check(false, "probe → card"); return }
        await probe.approveSend()
        let probeApproved = probeActions.sent.first?.approvedOutside ?? []
        T.equal(probeApproved.count, 7, "seven approved")
        T.check(Set(probeCard.people.map(\.address)).isSuperset(of: probeApproved), "…every one of them listed on the card")
        T.check(probeApproved.allSatisfy(probeCard.spoken.contains), "…and spoken")
        T.equal(probeCard.people.last, SendApproval.Person(address: "attacker@evil.example", name: nil, field: .bcc), "the last Bcc is on it, tagged Bcc")

        // Arming: the card's Send does nothing in its first 0.3 s (the second click of a double-click on Send).
        let armClock = Clock(now)
        let (armed, armedActions, _) = composer(.reply(t.thread, latest("th-milo")), clock: armClock)
        await armed.send()
        T.equal(armed.approval?.shownAt, now, "the card notes when it came up")
        await armed.approveIfArmed()
        T.equal(armedActions.sent.count, 0, "the card's Send at once: nothing")
        armClock.now = now.addingTimeInterval(0.2)
        T.check(abs(armed.sinceApprovalShown - 0.2) < 0.000_001, "the key monitor's clock: 0.2 s since the card came up")
        await armed.approveIfArmed()
        T.equal(armedActions.sent.count, 0, "…nor at 0.2 s")
        armClock.now = now.addingTimeInterval(SendApproval.armDelay)
        await armed.approveIfArmed()
        T.equal(armedActions.sent.first?.approvedOutside, ["milo@quietcomets.example"], "at 0.3 s it sends, approving Milo")
        T.equal(armed.sinceApprovalShown, .infinity, "no card: nothing to arm")

        // Your own addresses only (any case, any field): no card, nothing approved.
        let (mine, mineActions, _) = composer(.new(from: FixtureAccounts.cmt))
        mine.to = "AVERY@orbitalpickle.example"
        mine.bcc = "Me <avery@home.example>"
        mine.subject = "[YC-TEST] note"
        T.equal(mine.outsiders, [], "own addresses only")
        T.equal(mine.approvalHint, nil, "no hint")
        await mine.send()
        T.equal(mine.approval, nil, "no card")
        T.equal(mineActions.sent.count, 1, "straight to the queue")
        T.equal(mineActions.sent.first?.approvedOutside, [], "nothing approved")

        // Switch off: no hint, no card.
        let (off, offActions, _) = composer(.reply(t.thread, latest("th-milo")), safeSend: false)
        T.equal(off.approvalHint, nil, "switch off: no hint")
        await off.send()
        T.equal(off.approval, nil, "switch off: no card")
        T.equal(offActions.sent.count, 1, "…goes to the queue")
        T.equal(offActions.sent.first?.approvedOutside, [], "…with nothing approved")

        // The switch is read when it matters (Settings applies at once to open composers).
        var live = false
        let liveActions = FakeMailActions(store: FakeMailStore())
        let liveModel = ComposerModel(request: .reply(t.thread, latest("th-milo")), accounts: accounts, safeSend: live,
                                      actions: { liveActions }, prefs: { FakeMailPreferences() }, local: MemoryMailLocalStore(),
                                      clock: { now }, schedule: { _, _ in })
        T.equal(liveModel.approvalHint, nil, "opened with the switch off: no hint")
        live = true
        T.check(liveModel.approvalHint != nil, "switched on in Settings: the hint shows")
        // Settings → Mail posts the change, so an open composer redraws its footer at once (not on the next keystroke).
        var redraws = 0
        let watch = liveModel.objectWillChange.sink { _ in redraws += 1 }
        let settingsSwitch = SettingsMailModel(prefs: { FakeMailPreferences() }, directory: { FixtureAccounts.directory() },
                                               local: MemoryMailLocalStore(), safeSend: { live }, setSafeSend: { live = $0 })
        settingsSwitch.setAskBeforeSending(false)
        T.check(redraws > 0, "Settings switch off: the open composer redraws at once")
        T.equal(liveModel.approvalHint, nil, "…and the footer stops promising a check")
        redraws = 0
        settingsSwitch.setAskBeforeSending(true)
        T.check(redraws > 0 && liveModel.approvalHint != nil, "switch back on: redraws, the hint returns")
        watch.cancel()
        await liveModel.send()
        T.check(liveModel.approval != nil && liveActions.sent.isEmpty, "…and Send asks")

        // Replying from another account: your own addresses are still every account's.
        let (cross, crossActions, _) = composer(.reply(t.thread, latest("th-milo")))
        cross.changeFrom(FixtureAccounts.orb)
        cross.to = "avery@quietcomets.example"
        await cross.send()
        T.equal(cross.approval, nil, "From ORB to your CMT address: no card")
        T.equal(crossActions.sent.first?.from, FixtureAccounts.orb, "…sent from ORB")
        let (other, otherActions, _) = composer(.reply(t.thread, latest("th-milo")))
        other.changeFrom(FixtureAccounts.home)
        await other.send()
        T.equal(other.approval?.outsiders, ["milo@quietcomets.example"], "From Personal to Milo: asks")
        T.equal(other.approval?.fromTag, "Personal", "…showing the From in use")
        await other.approveSend()
        T.equal(otherActions.sent.first?.approvedOutside, ["milo@quietcomets.example"], "…and approves only Milo")
        T.equal(otherActions.sent.first?.from, FixtureAccounts.home, "…from Personal")

        // Approving A never lets B through: if the draft changed under the card, it asks about B.
        let (swap, swapActions, _) = composer(.reply(t.thread, latest("th-milo")))
        await swap.send()
        swap.to = "boss@example.com"
        await swap.approveSend()
        T.equal(swapActions.sent.count, 0, "an approval for Milo doesn't send to someone else")
        T.equal(swap.approval?.outsiders, ["boss@example.com"], "…the card asks about the new person")
        swap.to = "milo@quietcomets.example, boss@example.com"
        await swap.approveSend()
        T.equal(swapActions.sent.count, 0, "…nor to Milo plus someone else")
        T.equal(swap.approval?.outsiders, ["milo@quietcomets.example", "boss@example.com"], "…asks about both")
        await swap.approveSend()
        T.equal(swapActions.sent.first?.approvedOutside, ["milo@quietcomets.example", "boss@example.com"], "approved together → both")

        // The data layer's own refusal still shows as is (e.g. an approval it didn't accept).
        let (refused, refusedActions, _) = composer(.reply(t.thread, latest("th-milo")))
        refusedActions.sendError = ServiceError(description: "I held this one back.")
        await refused.send()
        await refused.approveSend()
        T.equal(refused.problem, "I held this one back.", "refusal shown")
        T.equal(refused.phase, .editing, "…back to editing")
        T.equal(refused.approval, nil, "…no card left behind")
    }

    static func approvalText() {
        T.section("composer: approval wording and keys")
        T.equal(ComposerText.approvalHint([]), nil, "no one outside: no hint")
        T.equal(ComposerText.approvalHint([.init(address: "a@b.example", name: nil), .init(address: "c@d.example", name: "Cee")]),
                "I\u{2019}ll check with you before this goes to a@b.example and 1 other.", "one other")
        T.equal(ComposerText.approvalHint([.init(address: "milo@quietcomets.example", name: "Milo Brightwater")]),
                "I\u{2019}ll check with you before this goes to Milo Brightwater.", "by name when known")
        T.equal(ComposerText.approvalHint([.init(address: "a.very.long.name.for.someone@a-long-domain.example", name: nil),
                                           .init(address: "x@y.example", name: nil), .init(address: "z@y.example", name: nil)]),
                "I\u{2019}ll check with you before this goes to a.very.long\u{2026}@a-long-domain.example and 2 others.", "two others, long address cut")
        T.equal(ComposerText.short("a.very.long.name.for.someone@a-long-domain.example"), "a.very.long\u{2026}@a-long-domain.example",
                "long address: the domain stays, the name part is cut")
        T.equal(ComposerText.short("theo.with.a.long.name@moonbase.example"), "theo.with.a.long\u{2026}@moonbase.example", "…to 34 characters")
        T.equal(ComposerText.short("quill.with.long.domain@moonbase-holdings-international.example"),
                "quill\u{2026}@moonbase-holdings-international.example", "very long domain: kept whole, a few letters of the name")
        T.equal(ComposerText.short("theo@moonbase.example"), "theo@moonbase.example", "short address as is")
        T.equal(ComposerText.shortName("Bartholomew Fernhollow-Copperpotsworth of Moon Base Holdings"),
                "Bartholomew Fernhollow-Copperpots\u{2026}", "long name cut to 34 characters with …")
        T.equal(ComposerText.list(["a", "b", "c"]), "a, b and c", "list")
        T.equal(MailText.displayName("\"Juniper Vale\" <juniper@x.example>").flatMap { MailText.cleanName($0, address: "juniper@x.example") }, "Juniper Vale", "display name, unquoted")
        T.equal(MailText.displayName("juniper@x.example"), nil, "a bare address has no name")
        T.equal(MailText.cleanName("juniper@x.example", address: "juniper@x.example"), nil, "an address isn't a name")
        T.equal(MailText.cleanName("  ", address: "juniper@x.example"), nil, "blank isn't a name")
        let one = SendApproval(people: [.init(address: "theo@moonbase.example", name: nil)], fromAccount: FixtureAccounts.orb,
                               fromTag: "ORB", fromAddress: "avery@orbitalpickle.example", subject: "")
        T.equal(one.title, "Send to theo@moonbase.example?", "no name known: the address")
        T.equal(one.subjectLine, "(no subject)", "empty subject")
        T.equal(one.subtitle, "This address isn\u{2019}t one of yours, so I\u{2019}m checking first.", "subtitle (one, no name)")
        T.equal(one.spoken, "Send to theo@moonbase.example? From ORB, subject (no subject). Return sends, Escape goes back.",
                "VoiceOver (one, no name): the address once")
        T.equal(SendApproval.firstName("Milo Brightwater"), "Milo", "first name")
        T.equal(SendApproval.firstName("Price, Milo"), "Milo", "first name from \u{201C}Last, First\u{201D}")
        T.equal(SendApproval.firstName("Cher"), "Cher", "one-word name")
        T.equal(SendApproval.Person(address: "ops@x.example", name: "Ops Team", field: .bcc).spokenRow, "Ops Team, ops@x.example, Bcc", "row: name, address, field")
        T.equal(SendApproval.Person(address: "ops@x.example", name: nil).spokenRow, "ops@x.example", "row in To: the address alone")
        var timed = one
        timed.shownAt = now
        T.check(timed.armed(at: now.addingTimeInterval(SendApproval.armDelay)) && !timed.armed(at: now.addingTimeInterval(0.25))
                && !timed.armed(at: now), "armed 0.3 s after it appears")

        T.equal(ApprovalKey.decide(keyCode: 36, command: false), .approve, "Return sends")
        T.equal(ApprovalKey.decide(keyCode: 36, command: false, isRepeat: true), .swallow, "a held ↩ (auto-repeat, ⌘ let go first) doesn't approve")
        T.equal(ApprovalKey.decide(keyCode: 36, command: false, sinceShown: 0.1), .swallow, "Return in the card's first 0.3 s: eaten")
        T.equal(ApprovalKey.decide(keyCode: 76, command: false, sinceShown: 0.29), .swallow, "Enter too")
        T.equal(ApprovalKey.decide(keyCode: 36, command: false, sinceShown: 0.3), .approve, "fresh Return after 0.3 s sends")
        T.equal(ApprovalKey.decide(keyCode: 53, command: false, isRepeat: true, sinceShown: 0), .cancel, "Esc goes back at once, held or not")
        T.equal(ApprovalKey.decide(keyCode: 76, command: false), .approve, "Enter sends")
        T.equal(ApprovalKey.decide(keyCode: 53, command: false), .cancel, "Esc goes back")
        T.equal(ApprovalKey.decide(keyCode: 47, command: true), .cancel, "⌘. goes back")
        T.equal(ApprovalKey.decide(keyCode: 36, command: true), .swallow, "⌘↩ can't send a second time")
        T.equal(ApprovalKey.decide(keyCode: 36, command: false, option: true), .swallow, "⌥↩ does nothing")
        T.equal(ApprovalKey.decide(keyCode: 0, command: false), .swallow, "typing doesn't reach the draft")
        T.equal(ApprovalKey.decide(keyCode: 9, command: true), .pass, "menu keys (⌘V, ⌘W…) pass")
        T.equal(ApprovalKey.decide(keyCode: 48, command: false), .pass, "Tab moves between the buttons")
        T.equal(ApprovalKey.decide(keyCode: 49, command: false), .pass, "Space presses the focused button")
    }

    // MARK: Widgets

    static func widgetRows() {
        T.section("widget: live mail rows (links)")
        let snap = SnapshotFixtures.roundTrip(SnapshotFixtures.busy(kind: "inbox.all"))!
        T.equal(snap.content, .inbox, "busy inbox → live content (mail on)")
        T.equal(snap.mail.count, 14, "the sample inbox: 14 threads")
        T.equal(snap.unreadCount, 7, "7 unread")
        let model = SnapshotModel(snap, logo: { _ in nil })
        let ctx = WidgetLinkContext(kind: "inbox.all", family: .large)
        var ok = true
        for m in model.mail {
            guard let r = m.r, let k = m.k else { ok = false; continue }
            let keyed = ["r": r, "k": k]
            if Route.parse(ctx.mail(m))?.name != "open/message" || Route.parse(ctx.mail(m))?.params != keyed { ok = false }
            if Route.parse(ctx.mailRead(m))?.name != "mail/read" || Route.parse(ctx.mailRead(m))?.params != keyed { ok = false }
            if Route.parse(ctx.mailArchive(m))?.name != "mail/archive" { ok = false }
            if Route.parse(ctx.mailUndo(m))?.name != "mail/undo" { ok = false }
            if !FixtureLinkKeys.verify(r: r, k: k) { ok = false }
            if ctx.mail(m).absoluteString.contains("@") { ok = false }
        }
        T.check(ok, "every row: open/message, mail/read, mail/archive, mail/undo with r + k; keys verify; no addresses in links")
        T.equal(model.mail.filter(\.starred).map(\.r), ["th-milo", "th-lantern"], "starred rows carried")
        let sample = WidgetSample.week(now: now, logos: nil, calendar: cal).mail[0]
        T.equal(Route.parse(ctx.mail(sample))?.name, "ping", "sample rows keep pinging")
        T.equal(Route.parse(ctx.mailArchive(sample))?.name, "ping", "…their archive glyph too")
        T.equal(Route.parse(YayaLink.mailStar(r: "th1", k: "k"))?.params, ["r": "th1", "k": "k"], "mail/star builder")

        T.section("widget: inbox capacity and paging")
        let data = model.data(at: now)
        let style = WidgetStyle()
        let large = KindView.mailRows(spec: WidgetKinds.inbox, family: .large, data: data, style: style) ?? 0
        T.check(large >= 10, "Inbox Large shows ≥10 mail rows on page 1 (\(large))")
        T.note("inbox mail rows page 1: Medium \(KindView.mailRows(spec: WidgetKinds.inbox, family: .medium, data: data, style: style) ?? 0), Large \(large), XL \(KindView.mailRows(spec: WidgetKinds.inbox, family: .extraLarge, data: data, style: style) ?? 0), XL Portrait \(KindView.mailRows(spec: WidgetKinds.inbox, family: .extraLargePortrait, data: data, style: style) ?? 0)")
        T.equal(KindView.mailRows(spec: WidgetKinds.inbox, family: .medium, data: data, style: style), 4, "Medium: 4 rows (approved)")
        let pages = KindView.inboxPages(family: .large, data: data, style: style)
        T.equal(pages.count, 2, "Large pages: 1 of 2 (the design's pager)")
        let ids = pages.flatMap { $0.flatMap { $0.flatMap { $0.mail.map(\.id) } } }
        T.equal(ids, data.mail.sorted(by: InboxLayout.newestFirst).map(\.id), "pages cover every row once, newest first")
        T.equal(KindView.mailRows(spec: WidgetKinds.inbox, family: .large, data: data, style: style, page: 2), 14 - large, "page 2: the rest")
        T.equal(KindView.pageCount(spec: WidgetKinds.inbox, family: .extraLarge, data: data, style: style), 1, "XL: everything on one page")
        var lots = data
        lots.mail = (0..<96).map { i in WidgetMail(id: i + 1, account: data.mail[0].account, sender: "S\(i)", subject: "Subject \(i)",
                                                   at: now.addingTimeInterval(Double(-i * 1_800)), unread: i % 3 == 0) }
        let lotsPages = KindView.inboxPages(family: .large, data: lots, style: style)
        T.equal(lotsPages.reduce(0) { $0 + InboxLayout.rowCount($1) }, 96, "96 rows (the cap) all reachable by paging")
        let combo = SnapshotModel(SnapshotFixtures.busy(kind: "combo.all"), logo: { _ in nil }).data(at: now)
        T.equal(combo.content, .combo, "busy combo → live")
        T.check(KindView.pageCount(spec: WidgetKinds.combo, family: .extraLarge, data: combo, style: style) >= 1, "combo pager counts real agenda pages")
        let zero = SnapshotModel(SnapshotFixtures.named("inboxZero", kind: "inbox.all"), logo: { _ in nil }).data(at: now)
        T.equal(KindView.mailRows(spec: WidgetKinds.inbox, family: .large, data: zero, style: style), 0, "inbox zero: no rows (the note shows)")
        T.equal(zero.unreadCount, 0, "inbox zero: 0 unread")
        let off = SnapshotModel(SnapshotFixtures.named("mailComingSoon", kind: "inbox.all"), logo: { _ in nil }).data(at: now)
        T.equal(off.state, .mailComingSoon, "mail off: the coming-soon card stays")
    }

    static func timeline() {
        T.section("widget: Archived · Undo rows and their timeline entry")
        let snap = SnapshotFixtures.roundTrip(SnapshotFixtures.named("mailArchived", kind: "inbox.all"))!
        let archived = snap.mail.first { $0.r == "th-jingle" }!
        T.equal(archived.archivedAt, now.addingTimeInterval(-8), "archivedAt survives JSON")
        let model = SnapshotModel(snap, logo: { _ in nil })
        let atNow = model.data(at: now).mail
        T.check(atNow.contains { $0.r == "th-jingle" && $0.archivedAt != nil }, "at +8 s the row is there, as Archived · Undo")
        T.equal(atNow.count, 14, "…in its place (no row lost)")
        let later = model.data(at: archived.archivedAt!.addingTimeInterval(30)).mail
        T.check(!later.contains { $0.r == "th-jingle" }, "at archivedAt + 30 s the row is gone")
        T.equal(later.count, 13, "…and only that row")
        T.equal(model.undoEnds, [archived.archivedAt!.addingTimeInterval(30)], "undo ends at archivedAt + 30 s")
        let dates = TimelinePlan.entryDates(now: now, model: model, spec: WidgetKinds.inbox, family: .large, calendar: cal)
        T.check(dates.contains(now.addingTimeInterval(22)), "a timeline entry at archivedAt + 30 s (now + 22 s)")
        T.equal(dates.first, now, "first entry is now")
        let plain = TimelinePlan.entryDates(now: now, model: SnapshotModel(SnapshotFixtures.busy(kind: "inbox.all"), logo: { _ in nil }), spec: WidgetKinds.inbox, family: .large, calendar: cal)
        T.check(!plain.contains(now.addingTimeInterval(22)), "no undo entry without an archived row")
        var stale = snap
        stale.mail[stale.mail.firstIndex { $0.r == "th-jingle" }!].archivedAt = now.addingTimeInterval(-60)
        let staleModel = SnapshotModel(stale, logo: { _ in nil })
        T.check(!staleModel.data(at: now).mail.contains { $0.r == "th-jingle" }, "an archive older than 30 s never shows")
        T.check(!TimelinePlan.entryDates(now: now, model: staleModel, spec: WidgetKinds.inbox, family: .large, calendar: cal).contains(now.addingTimeInterval(-30)), "…and adds no past entry")
        let banner = model.data(at: now).mail.filter { $0.unread && $0.archivedAt == nil }.count
        T.equal(banner, 6, "the archived row no longer counts as unread")
    }

    // MARK: Reader

    static func contentPolicy() {
        T.section("reader: content rule decision (allowed vs blocked sender)")
        let milo = latest("th-milo")
        let blocked = MailContentPolicy.decide(milo, senderAllowed: false, loadedOnce: false)
        T.equal(blocked, .init(html: true, allowRemote: false, showImagesBar: true), "unknown sender: remote blocked, the bar shows")
        T.equal(MailContentPolicy.decide(milo, senderAllowed: true, loadedOnce: false),
                .init(html: true, allowRemote: true, showImagesBar: false), "allowed sender: images load, no bar")
        T.equal(MailContentPolicy.decide(milo, senderAllowed: false, loadedOnce: true),
                .init(html: true, allowRemote: true, showImagesBar: false), "Load images: this message only")
        let rafa = latest("th-rafa")
        T.equal(MailContentPolicy.decide(rafa, senderAllowed: true, loadedOnce: true),
                .init(html: false, allowRemote: false, showImagesBar: false), "plain text: text, never a web view")
        let report = latest("th-gig-report")
        T.equal(MailContentPolicy.decide(report, senderAllowed: false, loadedOnce: false).showImagesBar, false, "HTML without remote images: no bar")

        func rules(_ allow: Bool) -> [[String: Any]] {
            (try? JSONSerialization.jsonObject(with: Data(MailContentPolicy.rules(allowRemote: allow).utf8))) as? [[String: Any]] ?? []
        }
        let b = rules(false), a = rules(true)
        func filter(_ r: [String: Any]) -> String? { (r["trigger"] as? [String: Any])?["url-filter"] as? String }
        func type(_ r: [String: Any]) -> String? { (r["action"] as? [String: Any])?["type"] as? String }
        T.equal(b.count, 4, "blocked list: 4 rules (valid JSON)")
        T.check(b.allSatisfy { type($0) == "block" }, "blocked list only blocks")
        T.equal(b.compactMap(filter), ["^https?:", "^wss?:", "^ftp:", "^file:"], "http(s), ws(s), ftp, file all blocked")
        T.equal(a.count, 5, "allowed list: the same blocks + one exception")
        T.equal(type(a.last ?? [:]), "ignore-previous-rules", "the exception comes last")
        T.equal((a.last?["trigger"] as? [String: Any])?["resource-type"] as? [String], ["image"], "…for images only")
        T.check(MailContentPolicy.ruleListIdentifier(allowRemote: false) != MailContentPolicy.ruleListIdentifier(allowRemote: true), "two compiled lists")
        T.check(!MailContentPolicy.csp(allowRemote: false).contains("https:"), "CSP (blocked): no remote images")
        T.check(MailContentPolicy.csp(allowRemote: true).contains("img-src data: cid: https: http:"), "CSP (allowed): remote images")
        T.check(MailContentPolicy.csp(allowRemote: true).contains("script-src 'none'"), "CSP never allows script")
        let doc = MailContentPolicy.document("<p>Hi</p>", allowRemote: false)
        T.check(doc.contains("Content-Security-Policy") && doc.contains("#F8F5F0") && doc.contains("<p>Hi</p>"), "document: CSP + paper + the fragment")
        T.check(doc.contains("img[src^=\"http\" i]{display:none"), "blocked: remote images take no space")
        T.check(!MailContentPolicy.document("x", allowRemote: true).contains("display:none"), "allowed: images show")

        T.section("reader: links never navigate the reader")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "about:blank"), isUserAction: false), .allowInitialLoad, "our own document loads")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "https://www.quietcomets.example/x"), isUserAction: true),
                .openInBrowser(URL(string: "https://www.quietcomets.example/x")!), "a clicked link → default browser")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "https://evil.example/refresh"), isUserAction: false), .ignore, "meta refresh / redirects: ignored")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "mailto:milo@quietcomets.example?subject=Hi"), isUserAction: true),
                .compose(to: "milo@quietcomets.example"), "mailto: → our composer")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "mailto:not-an-address"), isUserAction: true), .ignore, "bad mailto ignored")
        for bad in ["javascript:alert(1)", "file:///etc/hosts", "yayacal://mail/archive?r=x&k=y", "data:text/html,hi", "https://user:pw@x.example/"] {
            T.equal(MailContentPolicy.linkAction(url: URL(string: bad), isUserAction: true), .ignore, "ignored: \(bad)")
        }
        T.equal(MailContentPolicy.linkAction(url: nil, isUserAction: true), .ignore, "no URL")
    }

    static func reader() {
        T.section("reader: thread model, Load images, Always for this sender")
        let fixture = thread("th-milo")
        let prefs = FakeMailPreferences()
        let local = MemoryMailLocalStore()
        let r = ThreadReaderModel(thread: fixture.thread, messages: fixture.messages.reversed(), prefs: { prefs }, local: local)
        T.equal(r.messages.map(\.id), ["m-milo-1", "m-milo-2", "m-milo-3"], "oldest first")
        T.equal(r.expanded, ["m-milo-3"], "the latest is open, older ones folded")
        r.toggle(r.messages[0])
        T.equal(r.isExpanded(r.messages[0]), true, "an older one opens on click")
        r.toggle(r.messages[2])
        T.equal(r.isExpanded(r.messages[2]), true, "the latest can't be folded")
        let latest = r.latest!
        T.equal(r.decision(for: latest).showImagesBar, true, "bar before any choice")
        r.loadImages(latest)
        T.equal(r.decision(for: latest).allowRemote, true, "Load images: this message")
        T.equal(prefs.allowed, [], "…remembers nothing")
        let r2 = ThreadReaderModel(thread: fixture.thread, messages: fixture.messages, prefs: { prefs }, local: local)
        T.equal(r2.decision(for: r2.latest!).allowRemote, false, "a fresh reader asks again")
        r2.alwaysAllow(r2.latest!)
        T.equal(prefs.allowed, ["milo@quietcomets.example"], "Always for this sender → MailPreferencesStore")
        T.equal(local.strings(MailImageSenders.mirrorKey), ["milo@quietcomets.example"], "…and the local mirror")
        T.equal(r2.decision(for: r2.latest!).allowRemote, true, "images load now")
        let r3 = ThreadReaderModel(thread: fixture.thread, messages: fixture.messages, prefs: { prefs }, local: local)
        T.equal(r3.decision(for: r3.latest!), .init(html: true, allowRemote: true, showImagesBar: false), "next time: allowed sender, no bar")

        T.section("image allow list for Settings (seam has no list: mirror fallback)")
        final class PlainPrefs: MailPreferencesStore {
            var allowed: Set<String> = []
            func prefs(account: UUID) -> MailAccountPrefs { MailAccountPrefs(primaryOnly: false, signature: "") }
            func save(account: UUID, _ prefs: MailAccountPrefs) throws {}
            func allowsImages(from sender: String) -> Bool { allowed.contains(sender) }
            func setAllowsImages(from sender: String, _ on: Bool) throws { if on { allowed.insert(sender) } else { allowed.remove(sender) } }
        }
        let plain = PlainPrefs()
        let mirror = MemoryMailLocalStore()
        try? MailImageSenders.allow("A@x.example", prefs: plain, local: mirror)
        try? MailImageSenders.allow("b@x.example", prefs: plain, local: mirror)
        plain.allowed.remove("b@x.example")   // changed elsewhere
        T.equal(MailImageSenders.list(prefs: plain, local: mirror), ["a@x.example"], "mirror ∩ what the store still allows")
        try? MailImageSenders.remove("a@x.example", prefs: plain, local: mirror)
        T.equal(MailImageSenders.list(prefs: plain, local: mirror), [], "remove → store + mirror")
        T.equal(MailImageSenders.list(prefs: prefs, local: MemoryMailLocalStore()), ["milo@quietcomets.example"], "a store that lists wins over the mirror")
    }

    // MARK: Inbox section

    static func inbox(_ store: FakeMailStore = FakeMailStore(), directory: AccountDirectory = FixtureAccounts.directory(),
                      clock: Clock = Clock(now)) -> (InboxSectionModel, FakeMailActions, MailUndoBook, Clock) {
        let actions = FakeMailActions(store: store)
        let prefs = FakeMailPreferences()
        let book = MailUndoBook()
        var requests: [ComposerRequest] = []
        let model = InboxSectionModel(store: { store }, actions: { actions }, prefs: { prefs }, directory: { directory },
                                      clock: { clock.now }, undoBook: book, local: MemoryMailLocalStore(),
                                      toasts: MailToastCenter(clock: { clock.now }, schedule: { clock.schedule($0, $1) }),
                                      compose: { requests.append($0); lastRequest = $0 })
        _ = requests
        return (model, actions, book, clock)
    }

    static var lastRequest: ComposerRequest?

    static func inboxSection() async {
        T.section("Inbox section: mailboxes, counts, states")
        let (m, actions, book, clock) = inbox()
        T.equal(m.phase, .loading, "loading before the first read")
        m.load()
        T.equal(m.phase, .ready, "ready")
        T.equal(m.threads.count, 14, "unified: every thread")
        T.equal(m.threads.first?.r, "th-milo", "newest first")
        T.equal(m.unread[.unified], 7, "unified unread 7")
        T.equal(m.unread[.account(FixtureAccounts.cmt)], 2, "CMT unread 2")
        T.equal(m.subtitle, "7 unread across 4 accounts", "subtitle")
        T.equal(m.title, "Unified Inbox", "title")
        T.equal(m.starredCount, 2, "2 starred")
        m.select(mailbox: .account(FixtureAccounts.cmt))
        T.check(!m.threads.isEmpty && m.threads.allSatisfy { $0.accountId == FixtureAccounts.cmt }, "CMT mailbox: CMT threads only")
        T.equal(m.title, "The Quiet Comets", "account mailbox title")
        m.select(mailbox: .starred)
        T.equal(m.threads.map(\.r), ["th-milo", "th-lantern"], "Starred: the starred threads")
        T.equal(m.emptyNote.title, "Nothing starred yet", "starred empty copy")
        m.select(mailbox: .unified)

        let (zero, _, _, _) = inbox(FakeMailStore(threads: []))
        zero.load()
        T.equal(zero.phase, .ready, "empty inbox is ready")
        T.equal(zero.emptyNote.line, "Inbox zero across 4 accounts. Screenshot it.", "inbox zero, persona voice")
        T.equal(zero.subtitle, "All read across 4 accounts", "all read subtitle")
        let (none, _, _, _) = inbox(directory: AccountDirectory(accounts: []))
        none.load()
        T.equal(none.phase, .noAccounts, "no accounts")
        var off = FixtureAccounts.directory()
        for i in off.accounts.indices { off.accounts[i].mailEnabled = false }
        let (mailOff, _, _, _) = inbox(directory: off)
        mailOff.load()
        T.equal(mailOff.phase, .noAccounts, "mail off on every account = no inboxes")
        let broken = FakeMailStore(); broken.loadError = ServiceError(description: "db")
        let (failing, _, _, _) = inbox(broken)
        failing.load()
        T.equal(failing.phase, .failed, "store error → friendly failure")

        T.section("Inbox section: keys, read on open, undo toasts")
        await m.perform(.next)
        T.equal(m.selection, "th-milo", "J with nothing selected → the first thread")
        T.equal(m.threads.first { $0.r == "th-milo" }?.unread, false, "opening marks it read")
        T.check(actions.calls.contains("read th-milo true"), "…through MailActions.markRead")
        T.equal(m.unread[.unified], 6, "unread count follows")
        T.equal(m.reader?.phase, .ready, "the reader loads the thread")
        T.equal(m.reader?.messages.count, 3, "…its three messages")
        await m.perform(.next)
        T.equal(m.selection, "th-jingle", "J → next")
        await m.perform(.previous)
        T.equal(m.selection, "th-milo", "K → previous")
        await m.perform(.previous)
        T.equal(m.selection, "th-milo", "K at the top stays")

        await m.perform(.toggleUnread)
        T.equal(m.selectedThread?.unread, true, "U → unread again")
        T.equal(m.toasts.toast?.line, "Marked unread · Undo", "toast: Marked unread · Undo")
        T.equal(await m.toasts.performUndo(), true, "Undo")
        T.equal(m.selectedThread?.unread, false, "…read again")

        await m.perform(.toggleStar)
        T.equal(m.selectedThread?.starred, false, "S on a starred thread → unstar")
        T.equal(m.toasts.toast?.line, "Unstarred · Undo", "toast: Unstarred · Undo")
        await m.toasts.performUndo()
        T.equal(m.selectedThread?.starred, true, "Undo stars it again")

        await m.perform(.reply)
        T.equal(lastRequest?.kind, .reply, "R → reply composer")
        T.equal(lastRequest?.thread?.r, "th-milo", "…for the selected thread")
        T.equal(lastRequest?.message?.id, "m-milo-3", "…quoting the latest message")
        m.newMessage()
        T.equal(lastRequest?.kind, .new, "New message")

        await m.perform(.archive)
        T.check(!m.threads.contains { $0.r == "th-milo" }, "E → archived out of the list")
        T.equal(m.selection, "th-jingle", "the next thread is selected")
        T.check(actions.calls.contains("archive th-milo"), "MailActions.archive")
        T.equal(m.toasts.toast?.line, "Archived · Undo", "toast: Archived · Undo")
        T.equal(m.toasts.toast?.expiresAt, now.addingTimeInterval(30), "…for 30 s")
        T.check(book.peek(r: "th-milo", now: now) != nil, "token kept for 30 s (also for mail/undo)")
        clock.now = now.addingTimeInterval(12)
        T.equal(await m.toasts.performUndo(), true, "Undo at 12 s")
        T.check(actions.calls.contains { $0.hasPrefix("undo archive-th-milo") }, "→ MailActions.undo(token)")
        T.check(m.threads.contains { $0.r == "th-milo" }, "the thread is back")
        T.equal(m.selection, "th-milo", "…and selected again")

        clock.now = now
        await m.perform(.trash)
        T.equal(m.toasts.toast?.line, "Moved to Trash · Undo", "# → Moved to Trash · Undo")
        T.check(actions.calls.contains("trash th-milo"), "MailActions.trash")
        clock.now = now.addingTimeInterval(31)
        T.equal(await m.toasts.performUndo(), false, "Undo after 30 s does nothing")
        T.check(!m.threads.contains { $0.r == "th-milo" }, "…it stays in the Trash")

        actions.error = ServiceError(description: "offline")
        let before = m.threads.count
        if let r = m.selection { await m.archive(r) }
        T.equal(m.threads.count, before, "a failed archive puts the thread back")
        T.equal(m.selection, "th-jingle", "…still selected")
        T.equal(m.toasts.toast?.isError, true, "…with a friendly error toast")
        actions.error = nil
    }

    static func mailPeek() async {
        T.section("Mail Peek model")
        let store = FakeMailStore()
        let actions = FakeMailActions(store: store)
        let clock = Clock(now)
        let book = MailUndoBook()
        let fixture = thread("th-milo")
        let reader = ThreadReaderModel(thread: fixture.thread, store: { store }, prefs: { FakeMailPreferences() }, local: MemoryMailLocalStore())
        let peek = MailPeekModel(thread: fixture.thread, directory: FixtureAccounts.directory(), reader: reader, actions: { actions },
                                 clock: { clock.now }, undoBook: book,
                                 toasts: MailToastCenter(clock: { clock.now }, schedule: { clock.schedule($0, $1) }))
        var closed = 0, replies: [ComposerRequest] = []
        peek.onClose = { closed += 1 }
        peek.onReply = { replies.append($0) }
        T.equal(peek.account?.tag, "CMT", "account chip")
        await peek.open()
        T.equal(reader.phase, .ready, "opening loads the thread")
        T.equal(peek.thread.unread, false, "…and marks it read")
        T.check(actions.calls.contains("read th-milo true"), "MailActions.markRead")
        peek.reply()
        T.equal(replies.first?.kind, .reply, "Reply → composer request")
        T.equal(replies.first?.message?.id, "m-milo-3", "…answering the latest")
        T.equal(closed, 1, "…and the Peek closes")
        await peek.toggleStar()
        T.equal(peek.thread.starred, false, "Star toggles")
        await peek.markUnread()
        T.equal(peek.thread.unread, true, "Mark unread")
        T.equal(peek.toasts.toast?.line, "Marked unread · Undo", "toast")
        await peek.archive()
        T.equal(peek.gone, .archive, "Archive")
        T.equal(peek.toasts.toast?.line, "Archived · Undo", "toast: Archived · Undo")
        T.check(book.peek(r: "th-milo", now: now) != nil, "undo token kept (mail/undo can use it)")
        await peek.toasts.performUndo()
        T.equal(peek.gone, nil, "Undo brings it back")
        T.check(actions.calls.contains { $0.hasPrefix("undo archive-th-milo") }, "MailActions.undo")
    }

    static func settingsMail() {
        T.section("Settings → Mail")
        let prefs = FakeMailPreferences()
        prefs.allowed = ["team@orbitalpickle.example"]
        let m = SettingsMailModel(prefs: { prefs }, directory: { FixtureAccounts.directory() }, local: MemoryMailLocalStore(), safeSend: { true })
        m.load()
        T.equal(m.rows.map(\.account.tag), ["ORB", "CMT", "FAM", "Personal"], "one row per mail account")
        T.equal(m.rows.first { $0.account.tag == "Personal" }?.primaryOnly, true, "Personal: Primary only (as stored)")
        T.equal(m.senders, ["team@orbitalpickle.example"], "allowed senders listed")
        m.setPrimaryOnly(FixtureAccounts.orb, true)
        T.equal(prefs.stored[FixtureAccounts.orb]?.primaryOnly, true, "Primary only saved")
        T.equal(prefs.stored[FixtureAccounts.orb]?.signature, "Avery Moonfield\nOrbital Pickle Co.", "…signature untouched")
        m.editSignature(FixtureAccounts.fam, "Avery\nMoonfield Family")
        T.equal(m.rows.first { $0.id == FixtureAccounts.fam }?.isDirty, true, "edited signature is dirty")
        m.saveSignature(FixtureAccounts.fam)
        T.equal(prefs.stored[FixtureAccounts.fam]?.signature, "Avery\nMoonfield Family", "signature saved")
        T.equal(m.rows.first { $0.id == FixtureAccounts.fam }?.isDirty, false, "clean after save")
        m.removeSender("team@orbitalpickle.example")
        T.equal(m.senders, [], "sender removed")
        T.equal(prefs.allowsImages(from: "team@orbitalpickle.example"), false, "…images hidden again")
        prefs.saveError = ServiceError(description: "db")
        m.setPrimaryOnly(FixtureAccounts.cmt, true)
        T.equal(m.rows.first { $0.id == FixtureAccounts.cmt }?.primaryOnly, false, "failed save reverts the switch")
        T.equal(m.failed, true, "…and says so")
        T.equal(m.safeSendLine, "I\u{2019}ll check with you before anything goes to someone other than you.", "Ask before sending shown as on")

        var stored = true
        let ask = SettingsMailModel(prefs: { prefs }, directory: { FixtureAccounts.directory() }, local: MemoryMailLocalStore(),
                                    safeSend: { stored }, setSafeSend: { stored = $0 })
        T.equal(SettingsMailModel.askTitle, "Ask before sending to other people", "row title")
        T.equal(ask.askBeforeSending, true, "on by default")
        T.equal(ask.safeSendLine, "I\u{2019}ll check with you before anything goes to someone other than you.", "line when on (no \u{201C}On:\u{201D}: the switch says it)")
        var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: .ycAskBeforeSendingChanged, object: nil, queue: nil) { _ in posted += 1 }
        ask.setAskBeforeSending(false)
        T.equal(stored, false, "turning it off writes the switch")
        T.equal(ask.askBeforeSending, false, "…and the row follows")
        T.equal(posted, 1, "…and tells open composers")
        T.equal(ask.safeSendLine, "Mail goes straight out. You still get 5 seconds to undo.", "line when off")
        ask.setAskBeforeSending(true)
        NotificationCenter.default.removeObserver(observer)
        T.equal(stored, true, "back on")
        T.equal(posted, 2, "…told again")
        T.check(!ask.safeSendLine.contains("check-in"), "no more \u{201C}switches off after the mail check-in\u{201D}")
    }

    static func studioGating() {
        T.section("Studio: Inbox types gated by the mail switch")
        let store = FakeWidgetSettingsStore()
        let saveDirectory = AccountDirectory.current
        AccountDirectory.current = { AccountDirectory(accounts: []) }
        defer { AccountDirectory.current = saveDirectory }
        var mailOn = false
        let custom = WidgetStudioModel(kind: "custom.a", store: { store }, mailEnabled: { mailOn })
        T.equal(custom.isAvailable(.inbox), false, "mail off: Inbox greyed")
        T.equal(custom.isAvailable(.combo), false, "mail off: Agenda & Inbox greyed")
        custom.setContent(.inbox)
        T.equal(custom.draft.customContent, nil, "mail off: can't pick Inbox")
        let inboxKind = WidgetStudioModel(kind: "inbox.all", store: { store }, mailEnabled: { mailOn })
        T.equal(inboxKind.preview(now: now, dark: false, calendar: cal).0.state, .mailComingSoon, "mail off: Inbox preview says next update")
        mailOn = true
        T.equal(custom.isAvailable(.inbox), true, "mail on: Inbox available")
        T.equal(custom.isAvailable(.combo), true, "mail on: Agenda & Inbox available")
        custom.setContent(.inbox)
        T.equal(custom.draft.customContent, .inbox, "mail on: Inbox picked")
        let (data, _) = inboxKind.preview(now: now, dark: false, calendar: cal)
        T.equal(data.state, .content, "mail on: Inbox preview draws the design")
        T.equal(data.content, .inbox, "…the inbox")
        T.equal(data.mail.count, 14, "…with the sample inbox")
        T.equal(data.unreadCount, 7, "…and its unread count")
        let combo = WidgetStudioModel(kind: "combo.all", store: { store }, mailEnabled: { mailOn })
        T.equal(combo.preview(now: now, dark: false, calendar: cal).0.content, .combo, "mail on: Agenda & Inbox preview")
    }

    static func traceOverride() {
        T.section("trace: headless runs never touch the real app log")
        let saved = Trace.folderOverride
        defer { Trace.folderOverride = saved }
        Trace.folderOverride = nil
        T.equal(Trace.appLogURL, Paths.appLog, "no override: the real app log")
        let folder = URL(fileURLWithPath: "/render/out/trace", isDirectory: true)
        Trace.folderOverride = folder
        T.equal(Trace.appLogURL.path, "/render/out/trace/app.log", "override: <dir>/app.log")
        T.equal(Trace.widgetTraceURL.path, "/render/out/trace/trace.log", "override: <dir>/trace.log")
    }
}
