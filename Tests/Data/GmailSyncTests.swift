import Foundation

/// Gmail client + MailSyncer against FakeGmail: quota bucket, full sync paging (150 first, up to
/// 500), ≤6 metadata GETs in flight, resync skips unchanged threads, history incremental, 404 → full,
/// Primary-only query and unread counts, mapper rules, errors.
enum GmailSyncTests {
    static func run() async {
        await quotaBucket()
        mapper()
        await fullSyncPaging()
        await incremental()
        await historyGone()
        await primaryOnly()
        await errors()
        store()
    }

    static func quotaBucket() async {
        let clock = TestClock(TestCal.labNow)
        let quota = GmailQuota(now: clock.closure, sleep: { clock.advance($0) })
        let start = clock.now
        for _ in 0..<10 { await quota.acquire(GmailCost.get) }
        check(await quota.waits == 0 && clock.now == start, "burst of 200 units: 10 GETs go at once")
        await quota.acquire(GmailCost.get)
        let waited = clock.now.timeIntervalSince(start)
        check(await quota.waits == 1 && abs(waited - 20.0 / 75.0) < 0.001, "the 11th waits for 20 units to refill (\(waited) s)")
        await quota.acquire(GmailCost.send)
        expect(abs(clock.now.timeIntervalSince(start) - (20.0 + 100.0) / 75.0) < 0.001, "a send waits for 100 units")
        check(await quota.spent == 10 * 20 + 20 + 100, "spent units counted")
        clock.advance(120)
        check(await quota.remaining == 200, "refill caps at the burst (Gmail: 250 units/s per user)")
        // Sustained rate never beats 75 units/s: 100 GETs (2,000 units) take ≥ (2,000 − 200) / 75 s.
        let sustained = GmailQuota(now: clock.closure, sleep: { clock.advance($0) })
        let t0 = clock.now
        for _ in 0..<100 { await sustained.acquire(GmailCost.get) }
        check(clock.now.timeIntervalSince(t0) >= (2_000.0 - 200.0) / 75.0 - 0.01, "sustained rate ≤ 75 units/s")
        let small = GmailQuota(perMinute: 60, now: clock.closure, sleep: { clock.advance($0) })
        let before = clock.now
        await small.acquire(100)   // bigger than the bucket: capped, waits for a full bucket at most
        expect(clock.now == before, "a cost above the capacity is capped (no endless wait)")
        expect(GmailCost.list == 5 && GmailCost.get == 20 && GmailCost.modify == 5 && GmailCost.send == 100, "Gmail cost table")
    }

    static func mapper() {
        let me = UUID()
        func message(_ id: String, _ labels: [String], _ ms: Int64, from: String, subject: String, snippet: String) -> GMessage {
            GMessage(id: id, threadId: "t", labelIds: labels, snippet: snippet, historyId: "9", internalDate: "\(ms)",
                     payload: GMessagePart(headers: [GHeader(name: "From", value: from), GHeader(name: "Subject", value: subject),
                                                     GHeader(name: "Message-ID", value: "<\(id)@x.example>")]))
        }
        let thread = GThread(id: "t", historyId: "77", snippet: nil, messages: [
            message("m2", ["SENT"], 2_000, from: "Me <me@orb.example>", subject: "Re: =?UTF-8?B?\(Data("Σχέδιο".utf8).base64EncodedString())?=", snippet: "my reply"),
            message("m1", ["INBOX", "UNREAD", "CATEGORY_UPDATES"], 1_000, from: "\"Ops, Team\" <ops@example.com>", subject: "Plan", snippet: "Tom &amp; Jerry"),
        ])
        guard let r = GmailThreadMapper.record(thread, accountId: me) else { expect(false, "mapper record"); return }
        expect(r.r == MailIds.threadR(accountId: me, threadId: "t") && r.r.count == 23 && Route.isSafeValue(r.r), "r: deterministic, short, link-safe")
        expect(r.messageIds == ["m1", "m2"] && r.messageCount == 2, "messages ordered by internalDate")
        expect(r.senderName == "Ops, Team" && r.senderEmail == "ops@example.com", "sender = newest message not sent by me")
        expect(r.subject == "Re: Σχέδιο" && r.snippet == "my reply", "subject + snippet from the newest message")
        expect(r.unread && !r.starred && r.inInbox && !r.categoryPrimary, "flags from labels; Updates is not Primary")
        expect(r.lastAt == Date(timeIntervalSince1970: 2) && r.historyId == "77" && r.lastMessageIdHeader == "<m2@x.example>", "time, history, Message-ID")
        let uncategorized = GThread(id: "u", historyId: "1", snippet: nil,
                                    messages: [message("x", ["INBOX"], 5, from: "a@b.example", subject: "", snippet: "&lt;hi&gt;")])
        let u = GmailThreadMapper.record(uncategorized, accountId: me)
        expect(u?.categoryPrimary == true && u?.subject == "" && u?.snippet == "<hi>" && u?.senderName == "", "no category = Primary; empty subject")
        expect(GmailThreadMapper.record(GThread(id: "e", historyId: nil, snippet: nil, messages: []), accountId: me) == nil, "empty thread → nil")
        check(MailIds.threadR(accountId: me, threadId: "t") != MailIds.threadR(accountId: UUID(), threadId: "t"), "r differs per account")
    }

    static func fullSyncPaging() async {
        let m = MailHarness("gmail-full")
        let (orb, token) = m.account("y@orb.example", tag: "ORB", sort: 0)
        m.fill(token, threads: 520)
        m.gmail.getDelay = 2_000_000
        let engine = m.engine
        guard let client = await engine.gmailClient(for: orb.id) else { check(false, "client"); return }
        let firstBatch = Locked(-1)
        let db = m.db
        let report = try? await engine.mailSyncer.sync(accountId: orb.id, client: client) {
            firstBatch.value = (try? MailRepo(db: db).counts(accountId: orb.id).inbox) ?? -2
        }
        expect(report?.full == true && report?.listed == 500 && report?.fetched == 500, "full: 500 listed and fetched")
        let lists = m.gmail.requests.filter { $0.url.path.hasSuffix("/threads") }
        let sizes = lists.compactMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "maxResults" }?.value }
        expect(sizes == ["150", "150", "150", "50"], "pages: newest 150 first, then up to 500 (\(sizes))")
        expect(lists.allSatisfy { $0.url.query?.contains("labelIds=INBOX") == true && $0.url.query?.contains("q=") == false },
               "threads.list INBOX, no q for a whole-inbox account")
        expect(firstBatch.value == 150, "the first 150 are stored (and published) before the next page (\(firstBatch.value))")
        expect(m.gmail.count("format=metadata") == 500, "one metadata GET per thread")
        expect(m.gmail.maxInFlight <= 6 && m.gmail.maxInFlight >= 4, "≤ 6 metadata GETs in flight (\(m.gmail.maxInFlight))")
        let meta = m.gmail.requests.first { $0.url.query?.contains("format=metadata") == true }?.url.query ?? ""
        expect(["metadataHeaders=From", "metadataHeaders=Subject", "metadataHeaders=Date", "metadataHeaders=Message-ID"].allSatisfy(meta.contains),
               "metadata headers: From, Subject, Date, Message-ID")
        let counts = try? MailRepo(db: m.db).counts(accountId: orb.id)
        expect(counts?.inbox == 500 && counts?.threads == 500, "500 rows stored")
        let state = try? MailRepo(db: m.db).state(accountId: orb.id)
        expect(state?.historyId == "\(m.gmail.mailbox(token)!.historyId)" && state?.lastFullAt != nil && state?.lastSyncAt != nil,
               "history baseline from profile; full + sync times")
        expect(state?.unreadInbox == 520, "unread from labels.get INBOX threadsUnread (whole inbox, not just the cache)")
        check(state?.sendAsName == "Avery Moonfield", "send-as display name stored for From")
        let quota = engine.quota(for: orb.id)
        let spent = await quota?.spent
        expect(spent == 1 + 4 * 5 + 500 * 20 + 1 + 1, "quota units: profile + 4 lists + 500 gets + labels + sendAs (\(spent ?? -1))")
        check((await quota?.waits ?? 0) > 0, "10,000 units in one pass → the bucket made it wait")
        let row = m.row(orb.id, "t0")
        expect(row?.subject == "Subject 0" && row?.senderName == "Sender 0" && row?.senderEmail == "s0@example.com"
               && row?.snippet == "Snippet 0 & more" && row?.unread == true && row?.messageIds.count == 1
               && row?.lastMessageIdHeader?.hasSuffix("@mail.example.com>") == true, "row fields")
        let newest = try? Services.mail.threads(accounts: nil, limit: 3)
        expect(newest?.isEmpty == true, "Services.mail is empty until DataServices installs it")
        let store = engine.mailStore
        let top = (try? store.threads(accounts: nil, limit: 3)) ?? []
        expect(top.map(\.subject) == ["Subject 0", "Subject 1", "Subject 2"], "MailStore: newest first")
        check((try? store.unreadCount(accounts: nil)) == 520, "MailStore unread (whole inbox) = labels count")

        // A second full pass: nothing changed → no metadata GETs.
        try? MailRepo(db: m.db).setHistory(accountId: orb.id, historyId: nil)
        m.gmail.clearLog()
        let again = try? await engine.mailSyncer.sync(accountId: orb.id, client: client)
        check(again?.skipped == 500 && m.gmail.count("format=metadata") == 0, "resync: unchanged threads skipped (historyId)")
    }

    static func incremental() async {
        let m = MailHarness("gmail-history")
        let (orb, token) = m.account("y@orb.example", tag: "ORB", sort: 0)
        m.fill(token, threads: 6)
        _ = await m.syncMail(orb.id)
        let before = try? MailRepo(db: m.db).state(accountId: orb.id).historyId
        m.gmail.clearLog()

        m.gmail.add(token: token, thread: "t1", from: "Sender 1 <s1@example.com>", subject: "Re: Subject 1", date: m.clock.now,
                    labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], snippet: "A reply")
        let t2 = m.gmail.mailbox(token)!.messages.values.first { $0.threadId == "t2" }!.id
        m.gmail.relabel(token: token, message: t2, remove: ["INBOX"])
        m.gmail.deleteThread(token: token, thread: "t3")
        m.gmail.add(token: token, thread: "t9", subject: "Brand new", date: m.clock.now.addingTimeInterval(10))
        let t4 = m.gmail.mailbox(token)!.messages.values.first { $0.threadId == "t4" }!.id
        m.gmail.relabel(token: token, message: t4, add: ["STARRED"], remove: ["UNREAD"])

        let outcome = await m.syncMail(orb.id)
        expect(outcome == .ok, "incremental pass ok")
        let history = m.gmail.requests.filter { $0.url.path.hasSuffix("/history") }
        let q = history.first?.url.query ?? ""
        expect(history.count == 1 && q.contains("startHistoryId=\(before ?? "?")")
               && ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"].allSatisfy { q.contains("historyTypes=\($0)") },
               "history.list from the stored id with the four history types")
        expect(m.gmail.count("/threads?") == 0 && m.gmail.count("/profile") == 0, "no full list during an incremental pass")
        expect(m.gmail.count("format=metadata") == 5, "only the 5 touched threads refetched")
        expect(m.row(orb.id, "t1")?.messageCount == 2 && m.row(orb.id, "t1")?.snippet == "A reply" && m.row(orb.id, "t1")?.subject == "Re: Subject 1",
               "reply → thread updated")
        expect(m.row(orb.id, "t2") == nil, "archived elsewhere → out of the inbox (and pruned)")
        expect(m.row(orb.id, "t3") == nil, "deleted thread → gone")
        expect(m.row(orb.id, "t9")?.subject == "Brand new", "new thread added")
        expect(m.row(orb.id, "t4")?.starred == true && m.row(orb.id, "t4")?.unread == false, "label changes applied")
        expect((try? MailRepo(db: m.db).state(accountId: orb.id).historyId) == "\(m.gmail.mailbox(token)!.historyId)", "history id advanced")
        let top = (try? m.engine.mailStore.threads(accounts: nil, limit: 2))?.map(\.subject)
        check(top == ["Brand new", "Re: Subject 1"], "newest first after the pass")

        // History pages.
        m.gmail.historyPageSize = 1
        m.gmail.add(token: token, thread: "t10", date: m.clock.now)
        m.gmail.add(token: token, thread: "t11", date: m.clock.now)
        m.gmail.clearLog()
        _ = await m.syncMail(orb.id)
        check(m.gmail.count("/history") == 2 && m.row(orb.id, "t10") != nil && m.row(orb.id, "t11") != nil, "history pages followed")
    }

    static func historyGone() async {
        let m = MailHarness("gmail-404")
        let (orb, token) = m.account("y@orb.example", tag: "ORB", sort: 0)
        m.fill(token, threads: 3)
        _ = await m.syncMail(orb.id)
        m.gmail.mailbox(token)!.oldestHistory = 1_000_000
        m.gmail.add(token: token, thread: "late", date: m.clock.now)
        m.gmail.clearLog()
        guard let client = await m.engine.gmailClient(for: orb.id) else { check(false, "client"); return }
        let report = try? await m.engine.mailSyncer.sync(accountId: orb.id, client: client)
        expect(report?.resets == 1 && report?.full == true, "history 404 → full resync")
        expect(m.gmail.count("/profile") == 1 && m.gmail.count("/threads?") >= 1, "the full pass ran")
        check(m.row(orb.id, "late") != nil && (try? MailRepo(db: m.db).counts(accountId: orb.id).inbox) == 4, "and picked up the change")
        // Once a day a full pass runs anyway.
        m.gmail.mailbox(token)!.oldestHistory = 0
        m.clock.advance(25 * 3600)
        m.gmail.clearLog()
        let daily = try? await m.engine.mailSyncer.sync(accountId: orb.id, client: client)
        expect(daily?.full == true && daily?.skipped == 4, "daily full pass (cheap: unchanged threads skipped)")
    }

    static func primaryOnly() async {
        let m = MailHarness("gmail-primary")
        let (me, token) = m.account(consumerAddress("avery"), tag: "Personal", sort: 0)
        expect(m.engine.mailStore.prefs(account: me.id) == MailAccountPrefs(primaryOnly: true, signature: ""), "gmail.com → Primary only by default")
        let (orb, _) = m.account("y@orb.example", tag: "ORB", sort: 1)
        check(m.engine.mailStore.prefs(account: orb.id).primaryOnly == false, "Workspace → whole inbox by default")
        m.fill(token, threads: 3, prefix: "p")
        m.fill(token, threads: 2, prefix: "promo", labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"])
        m.gmail.add(token: token, thread: "plain", date: m.clock.now.addingTimeInterval(-30), labels: ["INBOX", "UNREAD"])
        _ = await m.syncMail(me.id)
        let list = m.gmail.requests.first { $0.url.path.hasSuffix("/threads") }?.url.query ?? ""
        expect(list.contains("q=category%3Aprimary"), "threads.list q=category:primary (\(list))")
        expect((try? MailRepo(db: m.db).counts(accountId: me.id).inbox) == 4, "Primary + uncategorized threads only")
        expect(m.gmail.count("/labels/INBOX") == 0, "no labels.get for a Primary-only account")
        expect((try? MailRepo(db: m.db).state(accountId: me.id).unreadInbox) == nil, "unread comes from the cache")
        check((try? m.engine.mailStore.unreadCount(accounts: [me.id])) == 4, "unread = cached unread Primary threads")

        m.gmail.add(token: token, thread: "promo-new", date: m.clock.now, labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"])
        _ = await m.syncMail(me.id)
        expect(m.row(me.id, "promo-new") == nil, "incremental: a new promotion stays out")

        try? m.engine.mailStore.save(account: me.id, MailAccountPrefs(primaryOnly: false, signature: "Avery"))
        check((try? MailRepo(db: m.db).state(accountId: me.id).historyId) == nil, "turning Primary only off forgets the history id")
        m.gmail.clearLog()
        _ = await m.syncMail(me.id)
        expect(m.gmail.count("/profile") == 1 && (try? MailRepo(db: m.db).counts(accountId: me.id).inbox) == 7, "→ full resync with every inbox thread")
        expect(m.gmail.requests.first { $0.url.path.hasSuffix("/threads") }?.url.query?.contains("q=") == false, "…without q")
        expect((try? MailRepo(db: m.db).state(accountId: me.id).unreadInbox) == 7, "…and labels.get for the unread count")
        expect(m.engine.mailStore.prefs(account: me.id) == MailAccountPrefs(primaryOnly: false, signature: "Avery"), "prefs round trip")
    }

    static func errors() async {
        let m = MailHarness("gmail-errors")
        let (orb, token) = m.account("y@orb.example", tag: "ORB", sort: 0)
        m.fill(token, threads: 2)
        m.gmail.inject("/profile", status: 401, times: 1)
        let tokens = m.h.source.tokens.value[orb.id]
        check(await m.syncMail(orb.id) == .ok && tokens?.forced.value == 1 && tokens?.invalidations.value == 1, "401 → token refreshed, one retry")

        m.gmail.add(token: token, thread: "x", date: m.clock.now)
        m.gmail.inject("/history", status: 429, times: 1)
        let limited = await m.syncMail(orb.id)
        expect({ if case .rateLimited = limited { return true }; return false }(), "429 → rate limited (the loop backs off)")
        expect((try? MailRepo(db: m.db).state(accountId: orb.id).lastError) == "rate_limited", "error code stored for diagnostics")
        check(await m.syncMail(orb.id) == .ok && (try? MailRepo(db: m.db).state(accountId: orb.id).lastError) == nil, "next pass clears it")

        m.gmail.inject("/threads/", status: 500, times: 1)
        m.gmail.add(token: token, thread: "y", date: m.clock.now)
        let server = await m.syncMail(orb.id)
        expect({ if case .serverError = server { return true }; return false }(), "5xx on a GET → server error, history id kept for the retry")
        check(await m.syncMail(orb.id) == .ok && m.row(orb.id, "y") != nil, "retry picks the change up")

        tokens?.error.value = AuthError.reauthNeeded(code: "invalid_grant")
        check(await m.syncMail(orb.id) == .reauthNeeded && m.h.source.reauthMarked.value == [orb.id], "invalid_grant → Sign in again")
        check(await m.syncMail(orb.id) == .waitingForUser, "then it waits for the user")
        _ = try? AccountRepo(db: m.db).setHealth(orb.id, .ok, detail: nil)
        tokens?.error.value = KeychainError.locked(-25308)
        check(await m.syncMail(orb.id) == .keychainLocked, "locked keychain → retry later, never reauth")
        tokens?.error.value = nil

        var off = (try? AccountRepo(db: m.db).get(orb.id)) ?? orb
        off.mailEnabled = false
        _ = try? AccountRepo(db: m.db).update(off)
        m.gmail.clearLog()
        check(await m.syncMail(orb.id) == .skipped && m.gmail.requests.isEmpty, "mail off → skipped, no requests")
        off.mailEnabled = true
        _ = try? AccountRepo(db: m.db).update(off)
        m.h.labsMail.value = false
        check(await m.syncMail(orb.id) == .skipped && m.gmail.requests.isEmpty, "Labs.mail off → no Gmail traffic at all")
    }

    static func store() {
        let (db, _) = Seed.database("mail-store")
        let a = Seed.account(db, email: "a@orb.example", tag: "ORB", sort: 0)
        let repo = MailRepo(db: db)
        func columns(_ table: String) -> [String] { (try? db.query("PRAGMA table_info(\(table))") { $0.string(1) }) ?? [] }
        expect(columns("mail_threads") == ["r", "account_id", "thread_id", "history_id", "subject", "sender_name", "sender_email", "snippet",
                                           "last_at", "unread", "starred", "in_inbox", "category_primary", "message_count",
                                           "last_message_id_header", "labels_json", "message_ids_json"], "mail_threads columns")
        expect(columns("actions") == ["id", "kind", "r", "account_id", "payload_json", "state", "created_at", "attempts", "undo_until"],
               "actions columns (v5)")
        expect(columns("mail_prefs") == ["account_id", "primary_only", "signature", "signature_rich"] && columns("image_allow") == ["sender"], "prefs + allow list")
        var t = MailThreadRecord(r: MailIds.threadR(accountId: a.id, threadId: "th"), accountId: a.id, threadId: "th", historyId: "1",
                                 subject: "S", senderName: "N", senderEmail: "n@x.example", snippet: "sn", lastAt: TestCal.labNow, unread: true,
                                 starred: false, inInbox: true, categoryPrimary: true, messageCount: 1, lastMessageIdHeader: "<a@x>",
                                 labels: ["INBOX"], messageIds: ["m1"])
        try? repo.upsert(t)
        t.subject = "S2"
        t.r = "ignored-on-conflict"
        try? repo.upsert(t)
        expect((try? repo.counts(accountId: a.id).threads) == 1 && (try? repo.thread(accountId: a.id, threadId: "th"))?.subject == "S2"
               && (try? repo.thread(accountId: a.id, threadId: "th"))?.r == MailIds.threadR(accountId: a.id, threadId: "th"),
               "upsert on (account, thread): one row, r kept")
        try? repo.savePrefs(accountId: a.id, MailPrefsRecord(primaryOnly: true, signature: "sig"))
        try? repo.setHistory(accountId: a.id, historyId: "5")
        try? repo.putCache(MailRepo.CacheEntry(accountId: a.id, messageId: "m1", file: "f.json", bytes: 10), threadR: t.r, at: TestCal.labNow)
        try? ActionRepo(db: db).insert(MailActionRecord(id: "act", kind: .read, r: t.r, accountId: a.id, payload: [:], state: .pending,
                                                        createdAt: TestCal.labNow))
        _ = try? AccountRepo(db: db).delete(a.id)
        let left = ["mail_threads", "mail_state", "mail_prefs", "body_cache", "actions"].map { table in
            (try? db.query("SELECT count(*) FROM \(table)") { $0.int(0) }.first) ?? -1
        }
        expect(left == [0, 0, 0, 0, 0], "removing the account cascades to threads, state, prefs, cache index, actions")
    }
}
