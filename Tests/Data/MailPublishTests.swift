import Foundation

/// Publisher mail rows (the mail switch, ≤96 newest first, accounts per widget, unread, archivedAt,
/// health), MailStore (threads, bodies on demand, sanitized, remote images, cache, prefs), and the
/// engine (Services wiring, mail loops behind the mail switch, diagnostics without PII).
enum MailPublishTests {
    static func run() async {
        await publisherRows()
        await bodies()
        await cache()
        await engineWiring()
    }

    static func publisherRows() async {
        let m = MailHarness("mail-publish")
        let (orb, orbToken) = m.account("y@orb.example", tag: "ORB", sort: 0)
        let (cmt, cmtToken) = m.account("y@cmt.example", tag: "CMT", sort: 1)
        let (me, meToken) = m.account(consumerAddress("avery"), tag: "Personal", sort: 2, includeInAll: false)
        m.fill(orbToken, threads: 60, prefix: "orb")
        m.fill(cmtToken, threads: 60, prefix: "cmt", start: m.clock.now.addingTimeInterval(-90))
        m.fill(meToken, threads: 5, prefix: "me")
        m.h.labsMail.value = false
        m.engine.publisher.publishAll(reason: .background)
        let off = m.h.snapshot("inbox.all")
        expect(off?.content == .mailComingSoon && off?.mail.isEmpty == true && off?.unreadCount == nil, "mail off → mailComingSoon, no rows")
        check(m.gmail.requests.isEmpty, "mail off → no Gmail requests from publishing")

        m.h.labsMail.value = true
        for a in [orb, cmt, me] { _ = await m.syncMail(a.id) }
        m.engine.publisher.publishAll(reason: .background)
        guard let inbox = m.h.snapshot("inbox.all") else { expect(false, "inbox snapshot"); return }
        expect(inbox.content == .inbox && inbox.mail.count == 96, "inbox: 96 rows max (\(inbox.mail.count))")
        expect(zip(inbox.mail, inbox.mail.dropFirst()).allSatisfy { $0.at >= $1.at }, "newest first across accounts")
        expect(Set(inbox.mail.map(\.accountId)) == [orb.id.uuidString, cmt.id.uuidString], "All = mail accounts marked Include in All")
        expect(inbox.mail.first?.sender == "Sender 0" && inbox.mail.first?.subject == "Subject 0" && inbox.mail.first?.unread == true
               && inbox.mail.first?.archivedAt == nil, "row fields")
        expect(inbox.unreadCount == 120, "unread = both accounts' INBOX threadsUnread")
        expect(inbox.mail.allSatisfy { m.engine.widgets.verify(r: $0.r, k: $0.k) }, "k verifies for every row")
        let json = (try? String(contentsOf: m.engine.publisher.url(kind: "inbox.all"), encoding: .utf8)) ?? ""
        expect(!json.contains("Snippet") && !json.contains("@example.com") && !json.contains("@orb.example"), "no snippets or addresses in the file")
        expect(inbox.health.state == .ok, "inbox health from mail syncs: ok")
        let combo = m.h.snapshot("combo.all")
        expect(combo?.content == .combo && combo?.mail.count == 96 && combo?.unreadCount == 120, "combo carries mail too")

        try? m.engine.widgets.save(WidgetSettings(kind: "custom.c", customContent: .inbox, accountIds: [me.id]))
        let custom = m.h.snapshot("custom.c")
        expect(custom?.content == .inbox && custom?.mail.count == 5 && custom?.unreadCount == 5
               && custom?.mail.allSatisfy { $0.accountId == me.id.uuidString } == true, "custom inbox: its own accounts (Primary-only cache count)")
        try? m.engine.widgets.save(WidgetSettings(kind: "custom.d", customContent: .combo, accountIds: [cmt.id]))
        expect(m.h.snapshot("custom.d")?.mail.count == 60 && m.h.snapshot("custom.d")?.unreadCount == 60, "custom combo: CMT only")

        var cmtOff = (try? AccountRepo(db: m.db).get(cmt.id)) ?? cmt
        cmtOff.mailEnabled = false
        _ = try? AccountRepo(db: m.db).update(cmtOff)
        m.engine.publisher.publishAll(reason: .background)
        expect(m.h.snapshot("inbox.all")?.mail.allSatisfy { $0.accountId == orb.id.uuidString } == true
               && m.h.snapshot("inbox.all")?.mail.count == 60 && m.h.snapshot("inbox.all")?.unreadCount == 60, "mail off → left out of Inbox")

        // Mail health: an account never mail-synced makes Inbox stale; calendar kinds don't care.
        let (_, fresh) = m.account("y@new.example", tag: "NEW", sort: 3)
        m.fill(fresh, threads: 1, prefix: "n")
        m.engine.publisher.publishAll(reason: .background)
        check(m.h.snapshot("inbox.all")?.health.state == .stale, "a mail account not synced yet → Inbox stale")

        // Archived rows keep their place for 30 s.
        let r = m.r(orb.id, "orb5")
        _ = try? await m.engine.mailActions.archive(r: r)
        let rows = m.h.snapshot("inbox.all")?.mail ?? []
        let index = rows.firstIndex { $0.r == r }
        // archivedAt is when the archive ran; with a 200-unit burst the modify may wait on the quota first,
        // and the test clock advances while it waits, so compare against "now", not equality.
        expect(index == 5 && (rows[index ?? 0].archivedAt.map { $0 <= m.clock.now && m.clock.now.timeIntervalSince($0) < 30 } ?? false),
               "archived row stays in place with archivedAt")
        m.clock.advance(31)
        m.engine.tick()
        expect(m.h.snapshot("inbox.all")?.mail.contains { $0.r == r } == false, "…and leaves after 30 s")

        // Size cap still holds with mail rows.
        let big = WidgetSnapshot.Mail(r: "m", k: "k", accountId: "a", sender: String(repeating: "s", count: 2_000),
                                      subject: String(repeating: "x", count: 2_000), at: m.clock.now, unread: true, starred: false)
        var snap = m.h.snapshot("inbox.all")!
        snap.mail = Array(repeating: big, count: 96)
        m.engine.publisher.write(snap, reason: .background)
        let size = (try? Data(contentsOf: m.engine.publisher.url(kind: "inbox.all")))?.count ?? 0
        check(size > 0 && size <= WidgetSnapshot.maxBytes && (m.h.snapshot("inbox.all")?.mail.count ?? 0) < 96, "192 KB cap trims mail rows")
    }

    static func bodies() async {
        let m = MailHarness("mail-bodies")
        let (orb, token) = m.account("y@orb.example", tag: "ORB", sort: 0)
        let html = "<html><body><p onclick=\"x()\">Hi <b>there</b></p><img src=\"https://track.example/p.gif\" width=\"1\"><script>alert(1)</script></body></html>"
        func b64(_ s: String) -> String { Data(s.utf8).base64URLString }
        let payload: [String: Any] = [
            "mimeType": "multipart/mixed",
            "headers": [["name": "Content-Type", "value": "multipart/mixed; boundary=x"]],
            "parts": [
                ["mimeType": "multipart/alternative", "parts": [
                    ["mimeType": "text/plain", "headers": [["name": "Content-Type", "value": "text/plain; charset=utf-8"]], "body": ["size": 8, "data": b64("Hi there")]],
                    ["mimeType": "text/html", "headers": [["name": "Content-Type", "value": "text/html; charset=utf-8"]], "body": ["size": html.utf8.count, "data": b64(html)]],
                ]],
                ["mimeType": "application/pdf", "filename": "Deck.pdf", "headers": [["name": "Content-Disposition", "value": "attachment; filename=\"Deck.pdf\""]],
                 "body": ["size": 1234, "attachmentId": "A1"]],
            ],
        ]
        let subject = "=?UTF-8?B?\(Data("こんにちは".utf8).base64EncodedString())?="
        m.gmail.add(token: token, thread: "html", id: "h1", from: "News <news@shop.example>", subject: subject,
                    date: m.clock.now.addingTimeInterval(-60), extraHeaders: [("Cc", "\"Doe, J\" <j@x.example>")], payload: payload)
        m.gmail.add(token: token, thread: "html", id: "h2", from: "Me <y@orb.example>", subject: "Re: hi", date: m.clock.now.addingTimeInterval(-30),
                    labels: ["SENT"], snippet: "plain reply")
        _ = await m.syncMail(orb.id)
        let r = m.r(orb.id, "html")
        let store = m.engine.mailStore
        m.gmail.clearLog()
        guard let messages = try? await store.messages(threadR: r) else { expect(false, "messages"); return }
        expect(m.gmail.count("format=full") == 1, "bodies fetched on demand with threads.get?format=full")
        expect(messages.map(\.id) == ["h1", "h2"], "messages oldest first")
        let first = messages[0]
        expect(first.from == "News" && first.fromEmail == "news@shop.example" && first.subject == "こんにちは" && first.cc == ["Doe, J <j@x.example>"]
               && first.to == ["y@orb.example"], "headers decoded")
        expect(first.text == "Hi there" && first.attachments.map { "\($0.name) \($0.bytes) \($0.mimeType)" } == ["Deck.pdf 1234 application/pdf"],
               "text + attachment list")
        expect(first.html?.contains("<b>there</b>") == true && first.html?.contains("onclick") == false && first.html?.contains("alert") == false,
               "HTML sanitized")
        expect(first.hasRemoteImages && first.html?.contains("track.example") == false && first.html?.contains("data-yc-blocked") == true,
               "remote images blocked by default")
        check(messages[1].isPlainText && messages[1].html?.contains("plain reply") == true && messages[1].text == "plain reply",
              "plain-text message (drawn from our own HTML, rich mail)")
        let loaded = try? await store.messages(threadR: r, loadImages: true)
        expect(loaded?.first?.html?.contains("https://track.example/p.gif") == true, "one-off Load images")
        try? store.setAllowsImages(from: "NEWS@shop.example", true)
        check(store.allowsImages(from: "News <news@shop.example>"), "allow list keyed by address, any case")
        let allowed = try? await store.messages(threadR: r)
        expect(allowed?.first?.html?.contains("https://track.example/p.gif") == true, "allowed sender → images load")
        expect(m.gmail.count("format=full") == 1, "…from the body cache (no second fetch)")
        try? store.setAllowsImages(from: "news@shop.example", false)
        expect(!store.allowsImages(from: "news@shop.example"), "allow list removal")
        var bad = ""
        do { try store.setAllowsImages(from: "nobody", true) } catch { bad = (error as? ServiceError)?.description ?? "" }
        check(bad == "That isn\u{2019}t an email address.", "allow list rejects non-addresses")
        var gone = ""
        do { _ = try await store.messages(threadR: "mMissing") } catch { gone = (error as? ServiceError)?.description ?? "" }
        expect(gone == "That conversation isn\u{2019}t in your inbox anymore.", "unknown thread")
        let t = try? store.thread(r: r)
        check(t?.messageCount == 2 && t?.sender == "News" && t?.senderEmail == "news@shop.example", "MailStore.thread(r:)")
    }

    static func cache() async {
        let m = MailHarness("mail-cache")
        let (orb, token) = m.account("y@orb.example", tag: "ORB", sort: 0)
        m.fill(token, threads: 6)
        _ = await m.syncMail(orb.id)
        let store = m.engine.mailStore
        for i in 0..<3 {
            m.clock.advance(1)
            _ = try? await store.messages(threadR: m.r(orb.id, "t\(i)"))
        }
        let folder = store.cacheDirectory
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
        let folderMode = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = files.first.flatMap { (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.posixPermissions] as? NSNumber)?.intValue }
        expect(files.count == 3 && folderMode == 0o700 && fileMode == 0o600, "body cache: one file per message, folder 0700, files 0600")
        expect(folder.path.hasPrefix(m.h.dir.path), "cache lives next to the test database (never in Application Support)")
        let summary = store.cacheSummary()
        check(summary.files == 3 && summary.bytes > 0, "cache index")
        // Read t0 again (most recent), then shrink the limit to two entries: t1 (least recently read) goes.
        m.clock.advance(1)
        _ = try? await store.messages(threadR: m.r(orb.id, "t0"))
        let each = summary.bytes / 3
        store.cacheLimit = each * 2 + each / 2
        let removed = store.trimCache()
        let left = (try? MailRepo(db: m.db).cacheFiles()) ?? []
        let t1File = LocalMailStore.fileName(accountId: orb.id, messageId: m.row(orb.id, "t1")?.messageIds.first ?? "?")
        expect(removed == 1 && left.count == 2 && !left.contains(t1File) && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(t1File).path),
               "LRU trim drops the least recently read entry (file and index)")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("stray.json").path, contents: Data("{}".utf8))
        expect(store.sweepOrphans() == 1, "orphan files swept")
        _ = try? AccountRepo(db: m.db).delete(orb.id)
        _ = store.sweepOrphans()
        let after = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
        expect(after.isEmpty && store.cacheSummary().files == 0, "account removed → its cached bodies are deleted")
    }

    static func engineWiring() async {
        var timing = SyncTiming()
        timing.interval = 3600
        timing.mailInterval = 3600
        timing.tick = 0.05
        let m = MailHarness("mail-engine", runLoops: true, timing: timing)
        let (orb, token) = m.account("secret.person@orb.example", tag: "ORB", sort: 0)
        m.gmail.add(token: token, thread: "s", from: "Secret Sender <hidden@example.com>", subject: "Top secret subject", date: m.clock.now)
        m.h.labsMail.value = false
        expect(Services.mail is EmptyStores && Services.mailActions is EmptyStores && Services.mailPreferences is EmptyStores, "empty mail stores before start")
        let engine = DataServices.start(environment: m.h.env)
        check(Services.mail is LocalMailStore && Services.mailActions is MailActionService && Services.mailPreferences is LocalMailStore,
               "DataServices installs mail, mailActions, mailPreferences")
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(engine.mailLoop(orb.id) == nil && m.gmail.requests.isEmpty, "mail off → no mail loop, no Gmail traffic")
        m.h.labsMail.value = true
        let started = await eventually(3) { engine.mailLoop(orb.id) != nil }
        check(started, "mail turned on → the next tick starts mail loops")
        let synced = await eventually(3) { (try? Services.mail.threads(accounts: nil, limit: 5))?.count == 1 }
        expect(synced && m.h.snapshot("inbox.all")?.content == .inbox && m.h.snapshot("inbox.all")?.mail.count == 1,
               "first mail pass syncs and publishes")
        check(await DataServices.handleMailRoute(.read, r: m.r(orb.id, "s")) && (try? Services.mail.thread(r: m.r(orb.id, "s")))?.unread == false,
               "DataServices.handleMailRoute reaches the running engine")
        let line = await DataServices.diagnose()
        let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        let mail = ((json?["accounts"] as? [[String: Any]])?.first)?["mail"] as? [String: Any]
        expect(mail?["threads"] as? Int == 1 && mail?["inbox"] as? Int == 1 && mail?["unreadCached"] as? Int == 0
               && mail?["unreadInbox"] as? Int == 0 && mail?["lastMailSync"] is String && mail?["mailError"] is NSNull
               && mail?["history"] as? Bool == true && mail?["loop"] as? String == "ok", "diagnose: per-account mail counts (\(mail ?? [:]))")
        expect(json?["labsMail"] as? Bool == true && (json?["mailActions"] as? [String: Int])?["failed"] == 0, "diagnose: mail switch + action queue")
        check(!line.contains("secret.person") && !line.contains("hidden@") && !line.contains("Top secret") && !line.contains("Secret Sender"),
               "diagnose carries no subjects or addresses")
        m.h.labsMail.value = false
        let stopped = await eventually(3) { engine.mailLoop(orb.id) == nil }
        check(stopped, "mail off again → mail loops stop")
        await DataServices.stop()
        expect(Services.mail is EmptyStores && Services.mailActions is EmptyStores && Services.mailPreferences is EmptyStores,
               "stop puts the empty mail stores back")
        expect(SyncTiming().mailInterval == 60 && SyncTiming().mailVisibleInterval == 30 && SyncTiming().forMail.interval == 60
               && SyncTiming().forMail.visibleInterval == 30, "mail polls every 60 s, 30 s while a surface is visible")
    }
}
