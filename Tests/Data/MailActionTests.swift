import Foundation

/// MailActions: optimistic changes + rollback, star rules, archive/trash undo window, routes and the
/// r → token map, delayed send + cancel, rfc822msgid idempotency, SAFE_SEND + per-send approvals (D-023),
/// threading, recovery.
enum MailActionTests {
    static func run() async {
        await optimisticAndRollback()
        await starring()
        await archiveUndo()
        await trashUndo()
        await routes()
        await concurrentArchiveUndo()
        await sendDelayAndCancel()
        await sendAndReply()
        await signatureOnce()
        await idempotentRetry()
        await safeSend()
        await recovery()
    }

    /// ORB (whole inbox) with 3 unread threads, synced; mail on.
    static func seeded(_ name: String) async -> (MailHarness, AccountRecord, String) {
        let m = MailHarness(name)
        let (orb, token) = m.account("y@orb.example", tag: "ORB", sort: 0)
        m.fill(token, threads: 3)
        _ = await m.syncMail(orb.id)
        return (m, orb, token)
    }

    static func message(_ e: Error) -> String { (e as? ServiceError)?.description ?? "\(e)" }

    static func optimisticAndRollback() async {
        let (m, orb, token) = await seeded("mail-optimistic")
        let actions = m.engine.mailActions
        let r0 = m.r(orb.id, "t0")
        check((try? MailRepo(db: m.db).state(accountId: orb.id).unreadInbox) == 3, "unread from labels: 3")
        m.gmail.modifyDelay = 300_000_000
        m.h.reloader.reset()
        let task = Task { try await actions.markRead(r: r0, true) }
        let flipped = await eventually(2) { m.row(orb.id, "t0")?.unread == false }
        expect(flipped && m.gmail.labels(token: token, thread: "t0").contains("UNREAD"), "optimistic: the row reads as read before Gmail answers")
        expect((try? MailRepo(db: m.db).state(accountId: orb.id).unreadInbox) == 2, "optimistic unread count 3 → 2")
        // The republish follows the optimistic store write on the engine's queue; under a loaded machine (the
        // gate renders in parallel) it can land a few ms after the row flips, so wait for it like the flip.
        let republished = await eventually(2) {
            m.h.snapshot("inbox.all")?.mail.first { $0.r == r0 }?.unread == false && m.h.reloader.count("inbox.all") >= 1
        }
        check(republished, "inbox republished at once (interaction reload)")
        let ok: Void? = try? await task.value
        expect(ok != nil && !m.gmail.labels(token: token, thread: "t0").contains("UNREAD"), "Gmail: threads.modify −UNREAD")
        let modify = m.gmail.requests.last { $0.url.path.hasSuffix("/threads/t0/modify") }
        let body = modify?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check((body?["removeLabelIds"] as? [String]) == ["UNREAD"] && (body?["addLabelIds"] as? [String]) == [], "modify body")
        m.gmail.modifyDelay = 0

        let r1 = m.r(orb.id, "t1")
        m.gmail.inject("/threads/t1/modify", status: 500)
        var thrown = ""
        do { try await actions.markRead(r: r1, true) } catch { thrown = message(error) }
        expect(thrown == "Gmail didn\u{2019}t accept that. Nothing changed.", "failure surfaces a friendly error (\(thrown))")
        expect(m.row(orb.id, "t1")?.unread == true && (try? MailRepo(db: m.db).state(accountId: orb.id).unreadInbox) == 2,
               "rollback: row and unread count restored")
        expect(m.h.snapshot("inbox.all")?.mail.first { $0.r == r1 }?.unread == true, "rollback republished")
        let states = (try? m.db.query("SELECT kind, state FROM actions ORDER BY created_at, rowid") { "\($0.string(0)):\($0.string(1))" }) ?? []
        check(states == ["read:done", "read:failed"], "action rows: done, failed (\(states))")

        m.gmail.inject("/threads/t1/modify", timeout: true)
        thrown = ""
        do { try await actions.markRead(r: r1, true) } catch { thrown = message(error) }
        check(thrown == "You\u{2019}re offline. Nothing changed." && m.row(orb.id, "t1")?.unread == true, "offline → rolled back")
        thrown = ""
        do { try await actions.markRead(r: "mNOPE", true) } catch { thrown = message(error) }
        check(thrown == "That conversation isn\u{2019}t in your inbox anymore.", "unknown row")

        try? await actions.markRead(r: r0, false)
        let newest = m.row(orb.id, "t0")?.messageIds.last ?? "?"
        expect(m.gmail.requests.last?.url.path.hasSuffix("/messages/\(newest)/modify") == true
               && m.gmail.messageLabels(token: token, message: newest).contains("UNREAD"), "mark unread → +UNREAD on the newest message")
        check(m.row(orb.id, "t0")?.unread == true && (try? MailRepo(db: m.db).state(accountId: orb.id).unreadInbox) == 3, "count back to 3")
    }

    static func starring() async {
        let (m, orb, token) = await seeded("mail-star")
        m.gmail.add(token: token, thread: "t0", id: "second", date: m.clock.now, labels: ["INBOX"])
        _ = await m.syncMail(orb.id)
        let r0 = m.r(orb.id, "t0")
        check(m.row(orb.id, "t0")?.messageIds.last == "second", "thread has two messages, newest last")
        try? await m.engine.mailActions.star(r: r0, true)
        expect(m.gmail.messageLabels(token: token, message: "second").contains("STARRED")
               && !(m.gmail.mailbox(token)!.messages.values.contains { $0.threadId == "t0" && $0.id != "second" && $0.labels.contains("STARRED") }),
               "star → STARRED on the newest message only")
        check(m.row(orb.id, "t0")?.starred == true && m.h.snapshot("inbox.all")?.mail.first { $0.r == r0 }?.starred == true, "row + snapshot starred")
        m.gmail.relabel(token: token, message: m.row(orb.id, "t0")!.messageIds[0], add: ["STARRED"])
        try? await m.engine.mailActions.star(r: r0, false)
        check(!m.gmail.labels(token: token, thread: "t0").contains("STARRED") && m.gmail.requests.last?.url.path.hasSuffix("/threads/t0/modify") == true,
               "unstar → −STARRED on the whole thread")
    }

    static func archiveUndo() async {
        let (m, orb, token) = await seeded("mail-archive")
        let actions = m.engine.mailActions
        let r0 = m.r(orb.id, "t0")
        let at = m.clock.now
        guard let token0 = try? await actions.archive(r: r0) else { expect(false, "archive"); return }
        expect(m.row(orb.id, "t0")?.inInbox == false && !m.gmail.labels(token: token, thread: "t0").contains("INBOX"), "archive: −INBOX")
        expect((try? m.engine.mailStore.threads(accounts: nil, limit: 10))?.contains { $0.r == r0 } == false, "MailStore inbox no longer lists it")
        let archived = m.h.snapshot("inbox.all")?.mail.first { $0.r == r0 }
        expect(archived?.archivedAt == at, "widget row stays with archivedAt (Archived · Undo)")
        expect(m.h.snapshot("inbox.all")?.unreadCount == 2 && (try? MailRepo(db: m.db).state(accountId: orb.id).unreadInbox) == 2,
               "archiving an unread thread lowers the unread count")
        check(actions.lastUndoToken(r: r0) == token0, "r → last undo token")

        m.clock.advance(10)
        do { try await actions.undo(token0) } catch { expect(false, "undo within 30 s: \(error)") }
        expect(m.row(orb.id, "t0")?.inInbox == true && m.gmail.labels(token: token, thread: "t0").contains("INBOX"), "undo → +INBOX")
        expect(m.h.snapshot("inbox.all")?.mail.first { $0.r == r0 }?.archivedAt == nil && m.h.snapshot("inbox.all")?.unreadCount == 3,
               "row back to normal, count back")
        let state = (try? ActionRepo(db: m.db).get(token0.id))?.state
        check(state == .undone && actions.lastUndoToken(r: r0) == nil, "original marked undone; token forgotten")
        var again: String?
        do { try await actions.undo(token0) } catch { again = message(error) }
        check(again == nil, "a second undo of the same token is a no-op")

        guard let token1 = try? await actions.archive(r: r0) else { check(false, "archive again"); return }
        m.clock.advance(31)
        var late = ""
        do { try await actions.undo(token1) } catch { late = message(error) }
        expect(late == "Too late to undo." && m.row(orb.id, "t0")?.inInbox == false, "after 30 s: too late, stays archived")
        expect(m.h.snapshot("inbox.all")?.mail.contains { $0.r == r0 } == true, "row still in the file until the next publish")
        m.engine.tick()
        check(m.h.snapshot("inbox.all")?.mail.contains { $0.r == r0 } == false && m.row(orb.id, "t0") == nil,
               "the tick after the window drops the row (and prunes it)")
    }

    static func trashUndo() async {
        let (m, orb, token) = await seeded("mail-trash")
        m.gmail.mailbox(token)!.untrashRestoresInbox = false
        let r1 = m.r(orb.id, "t1")
        guard let t = try? await m.engine.mailActions.trash(r: r1) else { expect(false, "trash"); return }
        let labels = m.gmail.labels(token: token, thread: "t1")
        expect(labels.contains("TRASH") && !labels.contains("INBOX") && m.row(orb.id, "t1")?.inInbox == false, "trash → threads.trash")
        check(m.h.snapshot("inbox.all")?.mail.first { $0.r == r1 }?.archivedAt != nil, "trashed row shows Archived · Undo too")
        m.gmail.clearLog()
        try? await m.engine.mailActions.undo(t)
        let paths = m.gmail.requests.map(\.url.path)
        expect(paths.count == 2 && paths[0].hasSuffix("/threads/t1/untrash") && paths[1].hasSuffix("/threads/t1/modify"),
               "undo trash → untrash, then +INBOX when untrash didn't restore it")
        check(m.gmail.labels(token: token, thread: "t1").contains("INBOX") && m.row(orb.id, "t1")?.inInbox == true, "back in the inbox")
    }

    static func routes() async {
        let (m, orb, _) = await seeded("mail-routes")
        let r2 = m.r(orb.id, "t2")
        m.h.reloader.reset()
        check(await m.engine.handleMailRoute(.archive, r: r2) && m.row(orb.id, "t2")?.inInbox == false, "mail/archive")
        expect(m.h.reloader.count("inbox.all") >= 1 && m.h.reloader.count("combo.all") >= 1, "mail kinds reloaded at once")
        expect(m.h.reloader.reloads.value.allSatisfy { ["inbox.all", "combo.all"].contains($0) }, "…and only mail kinds")
        check(await m.engine.handleMailRoute(.undo, r: r2) && m.row(orb.id, "t2")?.inInbox == true, "mail/undo uses the row's last token")
        check(await m.engine.handleMailRoute(.undo, r: r2) == false, "nothing left to undo → false")
        check(await m.engine.handleMailRoute(.star, r: r2) && m.row(orb.id, "t2")?.starred == true, "mail/star stars")
        check(await m.engine.handleMailRoute(.star, r: r2) && m.row(orb.id, "t2")?.starred == false, "…and toggles back")
        check(await m.engine.handleMailRoute(.read, r: r2) && m.row(orb.id, "t2")?.unread == false, "mail/read")
        check(await m.engine.handleMailRoute(.read, r: "mUNKNOWN") == false, "unknown row → false")
        expect(MailRoute(rawValue: "mail/archive") == .archive && MailRoute.allCases.allSatisfy { RouteTable.spec($0.rawValue)?.quiet == true },
               "every mail route is in the route table and quiet")
        check(await DataServices.handleMailRoute(named: "mail/archive", r: r2) == false, "no running engine → false")
        let snapshot = m.h.snapshot("inbox.all")
        check(snapshot?.mail.allSatisfy { m.engine.widgets.verify(r: $0.r, k: $0.k) } == true, "every mail row's k verifies")
    }

    static func concurrentArchiveUndo() async {
        let (m, orb, token) = await seeded("mail-race")
        let r0 = m.r(orb.id, "t0")
        m.gmail.modifyDelay = 150_000_000
        let archive = Task { await m.engine.handleMailRoute(.archive, r: r0) }
        let started = await eventually(2) { m.row(orb.id, "t0")?.inInbox == false }
        let undo = Task { await m.engine.handleMailRoute(.undo, r: r0) }
        let a = await archive.value
        let u = await undo.value
        expect(started && a && u, "archive then undo while the archive is still on the wire")
        let bodies = m.gmail.requests.filter { $0.url.path.hasSuffix("/threads/t0/modify") }
            .compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        expect(bodies.count == 2 && (bodies[0]["removeLabelIds"] as? [String]) == ["INBOX"] && (bodies[1]["addLabelIds"] as? [String]) == ["INBOX"],
               "Gmail saw −INBOX then +INBOX (undo never overtakes)")
        check(m.gmail.labels(token: token, thread: "t0").contains("INBOX") && m.row(orb.id, "t0")?.inInbox == true, "ends in the inbox")
    }

    // MARK: Sending

    static func sendSetup(_ name: String) async -> (MailHarness, AccountRecord, String, AccountRecord, String) {
        let (m, orb, token) = await seeded(name)
        let (me, meToken) = m.account("avery@home.example", tag: "Personal", sort: 1)
        return (m, orb, token, me, meToken)
    }

    static func sendDelayAndCancel() async {
        let (m, orb, token, _, _) = await sendSetup("mail-send-cancel")
        let actions = m.engine.mailActions
        m.sleeper.gate()
        let draft = MailDraft(from: orb.id, to: ["avery@home.example"], subject: "[YC-TEST] hello", body: "Body")
        guard let t = try? await actions.send(draft) else { check(false, "send queued"); return }
        let queuedAt = m.clock.now
        _ = await eventually(2) { m.sleeper.waiting == 1 }
        expect(m.sleeper.requests.value.last == 5, "send waits 5 s before leaving")
        check(actions.sendStatus(t) == .queued(until: queuedAt.addingTimeInterval(5)) && m.gmail.sentCount(token: token) == 0, "queued, nothing sent")
        do { try await actions.cancelSend(t) } catch { expect(false, "cancel: \(error)") }
        check(actions.sendStatus(t) == .cancelled, "cancelled")
        m.sleeper.release()
        await actions.drain()
        check(m.gmail.sentCount(token: token) == 0 && m.gmail.count("/messages/send") == 0, "a cancelled send never reaches Gmail")
        do { try await actions.cancelSend(t) } catch { check(false, "second cancel throws") }
        do { try await actions.undo(t) } catch { check(false, "undo(token) of a send = cancelSend") }
    }

    /// The composer already put the signature in the body: it goes out once, not again after the quote.
    static func signatureOnce() async {
        let (m, orb, token, _, _) = await sendSetup("mail-send-signature")
        let actions = m.engine.mailActions
        let sig = "Avery\nOrbital Pickle Co."
        try? m.engine.mailStore.save(account: orb.id, MailAccountPrefs(primaryOnly: false, signature: sig))
        let reply = "Sounds good\n\n" + sig + "\n\nOn Tue, Juno wrote:\n> Lids?\n"
        guard (try? await actions.send(MailDraft(from: orb.id, to: ["y@orb.example"], subject: "s", body: reply,
                                                 signatureIncluded: true))) != nil else { check(false, "composer send"); return }
        let fresh = "\n\n" + sig + "\n"
        guard (try? await actions.send(MailDraft(from: orb.id, to: ["y@orb.example"], subject: "n", body: "Hi" + fresh,
                                                 signatureIncluded: true))) != nil else { check(false, "composer new"); return }
        guard (try? await actions.send(MailDraft(from: orb.id, to: ["y@orb.example"], subject: "b", body: "Bare"))) != nil else {
            check(false, "bare send"); return
        }
        await actions.drain()
        // The queue may deliver the three in any order: each is found by its subject, never by its position.
        let sent = m.gmail.sentRaw(token: token).map { MIMEParser.parse($0) }
        let texts = Dictionary(sent.map { ($0.header("Subject") ?? "", MIMEParser.extract($0).text.replacingOccurrences(of: "\r\n", with: "\n")) },
                               uniquingKeysWith: { first, _ in first })
        let count = { (t: String) in t.components(separatedBy: "Orbital Pickle Co.").count - 1 }
        expect(sent.count == 3 && Set(texts.keys) == ["s", "n", "b"], "three sends, one per subject")
        let replied = texts["s"] ?? "", newMail = texts["n"] ?? "", bare = texts["b"] ?? ""
        expect(count(replied) == 1 && replied.hasSuffix("> Lids?\n"), "reply: signature once, quote stays last")
        expect(count(newMail) == 1 && !newMail.contains("-- \n"), "new mail: signature once, no second '-- '")
        expect(count(bare) == 1 && bare.contains("-- \nAvery"), "bare body: signature appended once")
    }

    static func sendAndReply() async {
        let (m, orb, token, me, _) = await sendSetup("mail-send")
        let actions = m.engine.mailActions
        try? m.engine.mailStore.save(account: orb.id, MailAccountPrefs(primaryOnly: false, signature: "Avery\nOrbital Pickle Co."))
        guard let t = try? await actions.send(MailDraft(from: orb.id, to: ["Avery <avery@home.example>"], cc: ["y@orb.example"],
                                                        subject: "[YC-TEST] new", body: "Hello\nthere")) else {
            check(false, "send"); return
        }
        await actions.drain()
        expect(actions.sendStatus(t) == .sent && m.gmail.sentCount(token: token) == 1, "sent after the delay")
        let raw = m.gmail.sentRaw(token: token).first ?? Data()
        let part = MIMEParser.parse(raw)
        let action = try? ActionRepo(db: m.db).get(t.id)
        expect(part.header("From") == "Avery Moonfield <y@orb.example>", "From = account address with the send-as name")
        expect(part.header("To") == "Avery <avery@home.example>" && part.header("Cc") == "y@orb.example", "To/Cc")
        expect(part.header("Message-ID") == action?.payload["messageId"] && part.header("Message-ID")?.hasSuffix("@yayascalendar.local>") == true,
               "our own Message-ID")
        expect(MIMEParser.extract(part).text == "Hello\r\nthere\r\n\r\n-- \r\nAvery\r\nOrbital Pickle Co.\r\n", "signature appended")
        let sendBody = m.gmail.requests.last { $0.url.path.hasSuffix("/messages/send") }?.body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check(sendBody?["threadId"] == nil && (sendBody?["raw"] as? String)?.contains("=") == false, "new mail: no threadId; raw is base64url")
        var gone = ""
        do { try await actions.cancelSend(t) } catch { gone = message(error) }
        check(gone == "That message has already gone.", "cancel after sending")

        // Reply: threading headers from the thread's newest message.
        m.gmail.add(token: token, thread: "conv", id: "c1", subject: "Plan", date: m.clock.now.addingTimeInterval(-100),
                    messageIdHeader: "<c1@x.example>")
        m.gmail.add(token: token, thread: "conv", id: "c2", subject: "Re: Plan", date: m.clock.now.addingTimeInterval(-50),
                    messageIdHeader: "<c2@x.example>", extraHeaders: [("References", "<c1@x.example>"), ("In-Reply-To", "<c1@x.example>")])
        _ = await m.syncMail(orb.id)
        let conv = m.r(orb.id, "conv")
        guard let reply = try? await actions.send(MailDraft(from: orb.id, to: ["y@orb.example"], subject: "", body: "Agreed", replyTo: conv)) else {
            check(false, "reply"); return
        }
        await actions.drain()
        let replyPart = MIMEParser.parse(m.gmail.sentRaw(token: token).last ?? Data())
        expect(actions.sendStatus(reply) == .sent && replyPart.header("In-Reply-To") == "<c2@x.example>", "In-Reply-To = newest message")
        expect(MIMEBuilder.messageIDs(in: replyPart.header("References")) == ["<c1@x.example>", "<c2@x.example>"], "References chain")
        expect(replyPart.header("Subject") == "Re: Plan", "reply subject from the thread")
        let replyBody = m.gmail.requests.last { $0.url.path.hasSuffix("/messages/send") }?.body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check(replyBody?["threadId"] as? String == "conv", "messages.send carries the threadId")

        // Replying from another account: headers yes, threadId no (it belongs to the other mailbox).
        guard (try? await actions.send(MailDraft(from: me.id, to: ["y@orb.example"], subject: "", body: "From personal", replyTo: conv))) != nil else {
            check(false, "cross-account reply"); return
        }
        await actions.drain()
        let crossBody = m.gmail.requests.last { $0.url.path.hasSuffix("/messages/send") }?.body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check(crossBody?["threadId"] == nil, "cross-account reply: no foreign threadId")
    }

    static func idempotentRetry() async {
        let (m, orb, token, _, _) = await sendSetup("mail-idempotent")
        let actions = m.engine.mailActions
        m.gmail.inject("/messages/send", timeout: true, afterWork: true)
        guard let t = try? await actions.send(MailDraft(from: orb.id, to: ["avery@home.example"], subject: "Timed out", body: "x")) else {
            check(false, "send"); return
        }
        await actions.drain()
        let search = m.gmail.requests.filter { $0.url.path.hasSuffix("/messages") && $0.method == .get }
        let id = (try? ActionRepo(db: m.db).get(t.id))?.payload["messageId"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) ?? "?"
        expect(m.gmail.sentCount(token: token) == 1 && m.gmail.count("/messages/send") == 1, "timed out after reaching Gmail → sent exactly once")
        expect(search.count == 1 && search[0].url.query?.contains("labelIds=SENT") == true
               && search[0].url.query?.contains("q=rfc822msgid%3A\(FormURLEncoding.escape(id))") == true,
               "before the retry: Sent searched for rfc822msgid:<our id>")
        check(actions.sendStatus(t) == .sent && (try? ActionRepo(db: m.db).get(t.id))?.attempts == 1, "done after one attempt")

        m.gmail.clearLog()
        m.gmail.inject("/messages/send", status: 503)
        guard let t2 = try? await actions.send(MailDraft(from: orb.id, to: ["avery@home.example"], subject: "503 first", body: "x")) else { return }
        await actions.drain()
        expect(m.gmail.count("/messages/send") == 2 && m.gmail.count("rfc822msgid") == 1 && m.gmail.sentCount(token: token) == 2,
               "503 before Gmail took it → search (not there) → second send")
        check(actions.sendStatus(t2) == .sent && m.sleeper.requests.value.contains(2), "retried after a 2 s backoff")

        let failed = Locked<String?>(nil)
        let observer = NotificationCenter.default.addObserver(forName: .ycMailSendFailed, object: nil, queue: nil) { note in
            failed.value = note.userInfo?["message"] as? String
        }
        m.gmail.inject("/messages/send", status: 400, body: "{\"error\":{\"code\":400,\"errors\":[{\"reason\":\"invalidArgument\"}]}}")
        guard let t3 = try? await actions.send(MailDraft(from: orb.id, to: ["avery@home.example"], subject: "Bad", body: "x")) else { return }
        await actions.drain()
        NotificationCenter.default.removeObserver(observer)
        expect(actions.sendStatus(t3) == .failed("Couldn\u{2019}t send: Gmail refused the message.") && failed.value == "Couldn\u{2019}t send: Gmail refused the message.",
               "a refused send fails once (no retry) and is announced")
        check(m.gmail.sentCount(token: token) == 2, "nothing extra sent")
    }

    static func safeSend() async {
        let (m, orb, token, _, _) = await sendSetup("mail-safe-send")
        let actions = m.engine.mailActions
        let blocked = MailActionService.safeSendMessage
        let held = MailActionService.safeSendHeldMessage
        check(blocked == "I didn\u{2019}t send this: you hadn\u{2019}t confirmed who it goes to. Press Send to check and send it.",
              "the refusal at Send reads in the app's voice and says what to do (\(blocked))")
        check(held == "I didn\u{2019}t send this: you hadn\u{2019}t confirmed who it goes to. Nothing was sent.",
              "the refusal at delivery (composer closed) says nothing went (\(held))")
        func queuedSends() -> Int { ((try? m.db.query("SELECT id FROM actions WHERE kind = 'send'") { $0.string(0) }) ?? []).count }
        for (label, draft) in [
            ("to", MailDraft(from: orb.id, to: ["boss@example.com"], subject: "s", body: "b")),
            ("cc", MailDraft(from: orb.id, to: ["y@orb.example"], cc: ["boss@example.com"], subject: "s", body: "b")),
            ("bcc", MailDraft(from: orb.id, to: ["y@orb.example"], bcc: ["boss@example.com"], subject: "s", body: "b")),
            ("one of several", MailDraft(from: orb.id, to: ["y@orb.example, boss@example.com"], subject: "s", body: "b")),
            // D-023: an approval clears exactly the addresses it names, nothing else.
            ("approval for a different address", MailDraft(from: orb.id, to: ["boss@example.com"], subject: "s", body: "b",
                                                           approvedOutside: ["peer@example.com"])),
            ("approval for A, not B (Cc)", MailDraft(from: orb.id, to: ["boss@example.com"], cc: ["peer@example.com"], subject: "s",
                                                     body: "b", approvedOutside: ["boss@example.com"])),
            ("approval for A, not B (Bcc)", MailDraft(from: orb.id, to: ["boss@example.com"], bcc: ["peer@example.com"], subject: "s",
                                                      body: "b", approvedOutside: ["boss@example.com"])),
            ("approval naming only an own address", MailDraft(from: orb.id, to: ["boss@example.com"], subject: "s", body: "b",
                                                              approvedOutside: ["y@orb.example"])),
            ("look-alike approvals", MailDraft(from: orb.id, to: ["boss@example.com"], subject: "s", body: "b",
                                              approvedOutside: ["boss@example.com.invalid", "oss@example.com", "boss@example.c"])),
        ] {
            var thrown = ""
            do { _ = try await actions.send(draft) } catch { thrown = message(error) }
            check(thrown == blocked, "SAFE_SEND refuses an unapproved outside recipient: \(label)")
        }
        check(queuedSends() == 0 && m.gmail.count("/messages/send") == 0, "refused sends are never queued")
        let own = try? await actions.send(MailDraft(from: orb.id, to: ["Avery <AVERY@home.example>", "y@orb.example"], subject: "own", body: "b"))
        check(own != nil, "SAFE_SEND allows the connected accounts' own addresses (any case), no approval needed")
        await actions.drain()
        check(m.gmail.sentCount(token: token) == 1, "…and sends")

        // Input refusals (restored from before D-023; all run before the SAFE_SEND check). Line breaks are
        // refused per Unicode scalar: "\r\n" is ONE Swift Character, so `contains("\r")` alone missed a CRLF pair.
        let notAnAddress = "isn\u{2019}t an email address."
        for (label, draft, expected) in [
            ("no recipients", MailDraft(from: orb.id, to: ["  "], subject: "s", body: "b"), "Add at least one recipient."),
            ("bad address", MailDraft(from: orb.id, to: ["not-an-address"], subject: "s", body: "b"), "\u{201C}not-an-address\u{201D} " + notAnAddress),
            ("header injection", MailDraft(from: orb.id, to: ["y@orb.example\r\nBcc: x@evil.example"], subject: "s", body: "b"), notAnAddress),
            ("header injection approved for the injected address",
             MailDraft(from: orb.id, to: ["y@orb.example\r\nBcc: x@evil.example"], subject: "s", body: "b", approvedOutside: ["x@evil.example"]), notAnAddress),
            ("CR LF in a quoted display name on an own address",
             MailDraft(from: orb.id, to: ["\"Evil\r\nBcc: x@evil.example\" <y@orb.example>"], subject: "s", body: "b"), notAnAddress),
            ("lone LF", MailDraft(from: orb.id, to: ["y@orb.example\nBcc: x@evil.example"], subject: "s", body: "b"), notAnAddress),
            ("lone CR in Cc", MailDraft(from: orb.id, to: ["y@orb.example"], cc: ["Me\r <avery@home.example>"], subject: "s", body: "b"), notAnAddress),
            ("unknown account", MailDraft(from: UUID(), to: ["y@orb.example"], subject: "s", body: "b"), "Pick an account to send from."),
        ] as [(String, MailDraft, String)] {
            var thrown: String?
            do { _ = try await actions.send(draft) } catch { thrown = message(error) }
            check(thrown?.hasSuffix(expected) == true, "refused: \(label) (\(thrown ?? "nil"))")
        }
        check(queuedSends() == 1 && m.gmail.sentCount(token: token) == 1, "…none of them queued or sent")
        // Below the guard, a display name carrying CR LF is flattened, never a header line of its own.
        let smuggled = MIMEBuilder.build(OutgoingMail(from: MailAddress(name: "", email: "y@orb.example"),
                                                      to: [MailAddress(name: "Evil\r\nBcc: x@evil.example", email: "y@orb.example")],
                                                      subject: "s", body: "b", messageID: MIMEBuilder.newMessageID(), date: m.clock.now))
        check(MIMEParser.parse(smuggled).header("Bcc") == nil && !String(decoding: smuggled, as: UTF8.self).contains("\r\nBcc:"),
              "no Bcc header reaches the built MIME from a display name")

        // Approved for this send: exactly the outside addresses, any case, in To, Cc or Bcc.
        guard let approvedTo = try? await actions.send(MailDraft(from: orb.id, to: ["Boss <BOSS@Example.com>"], subject: "[YC-TEST] approved",
                                                                 body: "b", approvedOutside: ["boss@example.COM"])) else {
            check(false, "an approved outside To queues (case-insensitive)"); return
        }
        check((try? ActionRepo(db: m.db).get(approvedTo.id))?.payload["approved"] == "boss@example.com",
              "the approval travels with the queued send, normalized")
        check((try? ActionRepo(db: m.db).get(approvedTo.id))?.payload["ask"] == "1", "…with the switch as it was at Send (on)")
        let approvedCopies = try? await actions.send(MailDraft(from: orb.id, to: ["y@orb.example"], cc: ["peer@example.com"], bcc: ["Boss@example.com"],
                                                               subject: "[YC-TEST] copies", body: "b",
                                                               approvedOutside: ["PEER@example.com", "boss@example.com", "stranger@example.com",
                                                                                 "y@orb.example", "boss@example.com"]))
        check(approvedCopies != nil, "approved Cc + Bcc queue")
        check(approvedCopies.flatMap { try? ActionRepo(db: m.db).get($0.id) }?.payload["approved"] == "peer@example.com,boss@example.com",
              "only approvals for outside addresses on this send are stored (own, strangers and repeats dropped)")
        let plain = try? await actions.send(MailDraft(from: orb.id, to: ["avery@home.example"], subject: "own again", body: "b"))
        check(plain != nil && plain.flatMap { try? ActionRepo(db: m.db).get($0.id) }?.payload["approved"] == nil, "own-only sends store no approval")
        await actions.drain()
        check(actions.sendStatus(approvedTo) == .sent && approvedCopies.map { actions.sendStatus($0) } == .sent && m.gmail.sentCount(token: token) == 4,
              "approved sends pass the delivery-time check and leave")
        let sentTo = m.gmail.sentRaw(token: token).count > 1 ? MIMEParser.parse(m.gmail.sentRaw(token: token)[1]).header("To") : nil
        check(sentTo == "Boss <BOSS@Example.com>", "the approval doesn't change what is sent (\(sentTo ?? "nil"))")

        m.safeSend.value = false
        m.sleeper.gate()
        let outside = try? await actions.send(MailDraft(from: orb.id, to: ["boss@example.com"], subject: "s", body: "b"))
        check(outside != nil, "SAFE_SEND off → outside recipients allowed without approval")
        check(outside.flatMap { try? ActionRepo(db: m.db).get($0.id) }?.payload["ask"] == "0", "the queued send remembers the switch was off")
        m.safeSend.value = true
        m.sleeper.release()
        await actions.drain()
        check(outside.map { actions.sendStatus($0) } == .sent && m.gmail.sentCount(token: token) == 5,
               "switched on within the 5 s → it still leaves: the rule when Send was pressed (no silent drop after the composer closed)")

        // Queued sends left by a previous run. Stored `ask` decides; without it (queued before `ask` existed) the switch
        // now does: approved → leaves; approved for someone else → refused; asked with nothing approved → refused;
        // sent with the switch off → leaves.
        for (id, extra) in [("left-approved", ["approved": "boss@example.com"]), ("left-other", ["approved": "peer@example.com"]),
                            ("left-asked", ["ask": "1"]), ("left-unasked", ["ask": "0"])] as [(String, [String: String])] {
            let messageID = MIMEBuilder.newMessageID()
            let raw = MIMEBuilder.build(OutgoingMail(from: MailAddress(name: "", email: "y@orb.example"), to: [MailAddress(name: "", email: "boss@example.com")],
                                                     subject: "[YC-TEST] \(id)", body: "x", messageID: messageID, date: m.clock.now))
            try? ActionRepo(db: m.db).insert(MailActionRecord(id: id, kind: .send, r: "", accountId: orb.id,
                                                              payload: ["raw": raw.base64URLString, "messageId": messageID,
                                                                        "rcpt": "boss@example.com"].merging(extra) { $1 },
                                                              state: .pending, createdAt: m.clock.now.addingTimeInterval(-60),
                                                              undoUntil: m.clock.now.addingTimeInterval(-55)))
        }
        actions.recover()
        await actions.drain()
        check(actions.sendStatus(UndoToken(id: "left-approved")) == .sent, "recovered send with its approval leaves")
        check(actions.sendStatus(UndoToken(id: "left-other")) == .failed(held), "recovered send approved for another address is refused")
        check(actions.sendStatus(UndoToken(id: "left-asked")) == .failed(held), "recovered send asked about but not approved is refused")
        check(actions.sendStatus(UndoToken(id: "left-unasked")) == .sent && m.gmail.sentCount(token: token) == 7,
              "recovered send made with the switch off leaves")
    }

    static func recovery() async {
        let (m, orb, token, _, _) = await sendSetup("mail-recovery")
        let actions = m.engine.mailActions
        // A send that reached Gmail just before the app quit: running, one attempt made.
        let id = MIMEBuilder.newMessageID()
        let raw = MIMEBuilder.build(OutgoingMail(from: MailAddress(name: "", email: "y@orb.example"), to: [MailAddress(name: "", email: "avery@home.example")],
                                                 subject: "Crashed", body: "x", messageID: id, date: m.clock.now))
        guard let client = await m.engine.gmailClient(for: orb.id) else { check(false, "client"); return }
        _ = try? await client.send(raw: raw, threadId: nil)
        try? ActionRepo(db: m.db).insert(MailActionRecord(id: "crashed-send", kind: .send, r: "", accountId: orb.id,
                                                          payload: ["raw": raw.base64URLString, "messageId": id, "rcpt": "avery@home.example"],
                                                          state: .running, createdAt: m.clock.now.addingTimeInterval(-60), attempts: 1,
                                                          undoUntil: m.clock.now.addingTimeInterval(-55)))
        // A label change the previous run never sent (its optimistic change is already on the row).
        let r1 = m.r(orb.id, "t1")
        try? MailRepo(db: m.db).setFlags(r: r1, unread: false)
        try? ActionRepo(db: m.db).insert(MailActionRecord(id: "crashed-read", kind: .read, r: r1, accountId: orb.id,
                                                          payload: ["threadId": "t1", "unread": "1", "starred": "0", "inInbox": "1"],
                                                          state: .pending, createdAt: m.clock.now.addingTimeInterval(-60)))
        m.gmail.clearLog()
        actions.recover()
        await actions.drain()
        let sent = await eventually(2) { (try? ActionRepo(db: m.db).get("crashed-read"))?.state == .done }
        expect((try? ActionRepo(db: m.db).get("crashed-send"))?.state == .done && m.gmail.sentCount(token: token) == 1
               && m.gmail.count("/messages/send") == 0 && m.gmail.count("rfc822msgid") == 1,
               "recovered send found in Sent → never sent twice")
        expect(sent && !m.gmail.labels(token: token, thread: "t1").contains("UNREAD"), "recovered label change re-sent")
    }
}
