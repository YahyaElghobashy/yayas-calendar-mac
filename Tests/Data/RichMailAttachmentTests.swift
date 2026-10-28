import Foundation

/// Rich mail attachments, data side with the engine: the attachment
/// cache (`LocalAttachmentStore`) over `GmailClient.attachment`, served by `RichGmailTransport`. Moonfield cast only.
enum RichMailAttachmentTests {
    static func run() async {
        await cache()
        await prefetchOnOpen()
        decoding()
    }

    // MARK: Fixtures

    /// Deterministic bytes (no binary assets).
    static func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    struct File {
        var partId: String
        var name: String
        var mime: String
        var size: Int
        var attachmentId: String
    }

    struct Inline {
        var partId: String
        var cid: String
        var size: Int
        var attachmentId: String?
        var data: Data?
    }

    static func header(_ name: String, _ value: String) -> [String: String] { ["name": name, "value": value] }

    /// mixed[ related[ html, inline images… ], files… ] with Gmail part ids, as `format=full` sends it.
    static func payload(html: String, inline: [Inline] = [], files: [File] = []) -> [String: Any] {
        let text: [String: Any] = ["partId": "0.0", "mimeType": "text/html", "headers": [header("Content-Type", "text/html; charset=utf-8")],
                                   "body": ["size": html.utf8.count, "data": Data(html.utf8).base64URLString]]
        let images: [[String: Any]] = inline.map { i in
            var body: [String: Any] = ["size": i.size]
            if let aid = i.attachmentId { body["attachmentId"] = aid }
            if let data = i.data { body["data"] = data.base64URLString }
            return ["partId": i.partId, "mimeType": "image/png", "filename": "",
                    "headers": [header("Content-Type", "image/png"), header("Content-ID", "<\(i.cid)>"), header("Content-Disposition", "inline")],
                    "body": body]
        }
        let related: [String: Any] = ["partId": "0", "mimeType": "multipart/related",
                                      "headers": [header("Content-Type", "multipart/related; boundary=r")], "parts": [text] + images]
        let parts: [[String: Any]] = files.map { f in
            ["partId": f.partId, "mimeType": f.mime, "filename": f.name,
             "headers": [header("Content-Type", f.mime), header("Content-Disposition", "attachment; filename=\"\(f.name)\"")],
             "body": ["size": f.size, "attachmentId": f.attachmentId]]
        }
        return ["partId": "", "mimeType": "multipart/mixed", "headers": [header("Content-Type", "multipart/mixed; boundary=m")],
                "parts": [related] + parts]
    }

    static func files(menuId: String) -> [File] {
        [File(partId: "2", name: "Launch plan.pdf", mime: "application/pdf", size: 30_000, attachmentId: "ANGplan"),
         File(partId: "3", name: "Budget Q4.xlsx", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", size: 25_000,
              attachmentId: "ANGbudget"),
         File(partId: "4", name: "Moodboard.zip", mime: "application/zip", size: 60_000_000, attachmentId: "ANGbig"),
         File(partId: "5", name: "Caf\u{00E9} Nowhere menu.jpg", mime: "image/jpeg", size: 20_000, attachmentId: menuId),
         File(partId: "6", name: "Rehearsal.ics", mime: "text/calendar", size: 2_100, attachmentId: "ANGgone"),
         File(partId: "7", name: "Installer.dmg", mime: "application/x-apple-diskimage", size: 12_000, attachmentId: "ANGdmg")]
    }

    static func posix(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: The cache

    static func cache() async {
        let m = MailHarness("rich-attachments")
        let rich = RichGmailTransport(inner: m.h.env.transport)
        m.h.env.transport = rich
        let (orb, token) = m.account("avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let html = "<div>Plan, budget, moodboard and the menu attached.</div>"
        m.gmail.add(token: token, thread: "plan", id: "q1", from: "Priya Starling <priya@starling.example>", subject: "Q4 pickle launch plan",
                    date: m.clock.now.addingTimeInterval(-300), payload: payload(html: html, files: files(menuId: "ANGmenu-old")))
        let plan = bytes(30_000, seed: 1), budget = bytes(25_000, seed: 2), menu = bytes(20_000, seed: 3), dmg = bytes(12_000, seed: 4)
        rich.serve("q1", "ANGplan", plan)
        rich.serve("q1", "ANGbudget", budget)
        rich.serve("q1", "ANGmenu-new", menu)
        rich.serve("q1", "ANGdmg", dmg)
        _ = await m.syncMail(orb.id)
        let r = m.r(orb.id, "plan")
        let store = m.engine.attachmentStore
        guard (try? await m.engine.mailStore.messages(threadR: r))?.count == 1 else { expect(false, "attachments: thread opens"); return }
        expect(store.directory.path.hasPrefix(m.h.dir.path), "attachments: the cache lives under the test data root")

        // Fetch: the bytes, 0600 in a 0700 folder, a row, the long session.
        let generations = m.db.generations
        m.h.reloader.reset()
        let url = try? await store.file(threadR: r, messageId: "q1", partId: "2")
        expect(url.flatMap { try? Data(contentsOf: $0) } == plan, "attachments: fetch returns the bytes")
        if let url {
            expect(posix(url) == 0o600, "attachments: the file is 0600 (\(String(posix(url), radix: 8)))")
            expect(posix(url.deletingLastPathComponent()) == 0o700, "attachments: the folder is 0700")
            expect(url.lastPathComponent.count == 68 && url.pathExtension == "bin" && !url.lastPathComponent.contains("plan"),
                   "attachments: a hashed name, never the sender's filename (\(url.lastPathComponent))")
        }
        let row = try? AttachmentCacheRepo(db: m.db).get(accountId: orb.id, messageId: "q1", partId: "2")
        expect(row?.bytes == 30_000 && row?.mimeType == "application/pdf" && row?.sha256.count == 64, "attachments: the row is written")
        expect(rich.requests("ANGplan") == 1 && rich.allLong, "attachments: one request, on the long-timeout session")
        expect(m.db.generations == generations && m.h.reloader.reloads.value.isEmpty,
               "attachments: a fetch moves no write generation and republishes no widget (quiet table)")

        // A second call: no request.
        let again = try? await store.file(threadR: r, messageId: "q1", partId: "2")
        expect(again == url && rich.requests("ANGplan") == 1, "attachments: a second call makes no request")
        expect(store.cachedFile(threadR: r, messageId: "q1", partId: "2") == url && store.cachedFile(threadR: r, messageId: "q1", partId: "3") == nil,
               "attachments: cachedFile answers without the network")

        // 10 concurrent calls: one request.
        rich.delay = 40_000_000
        let urls = await withTaskGroup(of: URL?.self) { group -> [URL?] in
            for _ in 0..<10 { group.addTask { try? await store.file(threadR: r, messageId: "q1", partId: "3") } }
            var out: [URL?] = []
            for await u in group { out.append(u) }
            return out
        }
        rich.delay = 0
        expect(rich.requests("ANGbudget") == 1 && urls.count == 10 && Set(urls.compactMap { $0 }).count == 1 && !urls.contains(nil),
               "attachments: 10 concurrent calls share 1 request (\(rich.requests("ANGbudget")))")

        // Over 50 MB: refused, no request.
        do {
            _ = try await store.file(threadR: r, messageId: "q1", partId: "4")
            expect(false, "attachments: over the cap is refused")
        } catch {
            expect((error as? ServiceError) == LocalAttachmentStore.tooBig && rich.requests("ANGbig") == 0,
                   "attachments: over 50 MB is refused with no request")
        }

        // Stale id (404) → the thread is fetched again → retried once with the new id.
        if let box = m.gmail.mailbox(token) { box.messages["q1"]?.payload = payload(html: html, files: files(menuId: "ANGmenu-new")) }
        let fullBefore = m.gmail.count("format=full")
        let menuURL = try? await store.file(threadR: r, messageId: "q1", partId: "5")
        expect(menuURL.flatMap { try? Data(contentsOf: $0) } == menu, "attachments: a stale id is refreshed and retried")
        expect(rich.requests("ANGmenu-old") == 1 && rich.requests("ANGmenu-new") == 1 && m.gmail.count("format=full") == fullBefore + 1,
               "attachments: one 404, one thread refresh, one retry")
        // Still 404 after the refresh: a friendly error, no loop.
        do {
            _ = try await store.file(threadR: r, messageId: "q1", partId: "6")
            expect(false, "attachments: a vanished attachment fails")
        } catch {
            expect((error as? ServiceError) == LocalAttachmentStore.gone && rich.requests("ANGgone") == 2 && m.gmail.count("format=full") == fullBefore + 2,
                   "attachments: still missing after one refresh → \u{201C}Gmail no longer has that attachment.\u{201D}")
        }
        do {
            _ = try await store.file(threadR: r, messageId: "q1", partId: "")
            expect(false, "attachments: a part without an id fails")
        } catch {
            expect((error as? ServiceError) == LocalAttachmentStore.notFetchable, "attachments: partId \"\" can't be fetched")
        }
        let usage = store.usage()
        expect(usage.files == 3 && usage.bytes == 75_000, "attachments: usage counts files and bytes (\(usage))")

        // LRU: past the limit the least recently opened go, never the file just written.
        m.clock.advance(10)
        _ = store.cachedFile(threadR: r, messageId: "q1", partId: "3")   // budget opened again
        m.clock.advance(10)
        _ = store.cachedFile(threadR: r, messageId: "q1", partId: "5")   // menu opened again
        m.clock.advance(10)
        store.limit = 60_000
        let dmgURL = try? await store.file(threadR: r, messageId: "q1", partId: "7")
        let after = store.usage()
        expect(dmgURL != nil && after.bytes <= 60_000 && after.files == 3, "attachments: the cache trims to its limit (\(after))")
        expect(store.cachedFile(threadR: r, messageId: "q1", partId: "2") == nil && url.map { FileManager.default.fileExists(atPath: $0.path) } == false,
               "attachments: the least recently opened file went (row and file)")
        expect(store.cachedFile(threadR: r, messageId: "q1", partId: "7") != nil, "attachments: the newest file stays")
        store.limit = 300 << 20

        // Clear (Settings).
        try? store.clear()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? ["?"]
        expect(store.usage() == (0, 0) && names.isEmpty, "attachments: Clear empties the index and the folder")

        // Account removal: the rows cascade, the engine sweeps the files.
        let refetched = try? await store.file(threadR: r, messageId: "q1", partId: "2")
        expect(refetched != nil && rich.requests("ANGplan") == 2, "attachments: fetched again after Clear")
        _ = try? AccountRepo(db: m.db).delete(orb.id)
        expect((try? AttachmentCacheRepo(db: m.db).files())?.isEmpty == true, "attachments: account removal cascades the rows")
        m.engine.accountsChanged()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? ["?"]
        expect(left.isEmpty, "attachments: account removal sweeps the files (\(left.count) left)")
    }

    // MARK: Inline prefetch on open

    static func prefetchOnOpen() async {
        let m = MailHarness("rich-prefetch")
        let rich = RichGmailTransport(inner: m.h.env.transport)
        m.h.env.transport = rich
        let (fam, token) = m.account("avery@moonfield-family.example", tag: "FAM", sort: 0)
        var inline: [Inline] = []
        var html = "<div>Photos from the lake house:</div>"
        for i in 1...10 {
            let cid = "dock-\(i)@moonfield-family.example"
            html += "<img src=\"cid:\(cid)\" width=\"48\" height=\"32\" alt=\"Dock \(i)\">"
            // Part 2 lists 7.5 MB (Gmail's listed size drives the 8 MB plan; the served bytes stay small).
            inline.append(Inline(partId: "0.\(i)", cid: cid, size: i == 2 ? 7_500_000 : 60_000, attachmentId: "ANGdock\(i)", data: nil))
            rich.serve("k1", "ANGdock\(i)", bytes(2_000, seed: UInt8(i)))
        }
        // One more image arrives with its bytes: stored without a request.
        let small = bytes(600, seed: 42)
        html += "<img src=\"cid:sun@moonfield-family.example\" alt=\"Sun\">"
        inline.append(Inline(partId: "0.11", cid: "sun@moonfield-family.example", size: 600, attachmentId: nil, data: small))
        m.gmail.add(token: token, thread: "photos", id: "k1", from: "Kofi Ember <kofi@ember.example>", subject: "Photos from the lake house",
                    date: m.clock.now.addingTimeInterval(-60), payload: payload(html: html, inline: inline))
        _ = await m.syncMail(fam.id)
        let r = m.r(fam.id, "photos")
        let quota = m.engine.quota(for: fam.id)
        let spentBefore = await quota?.spent ?? 0
        rich.delay = 30_000_000
        let messages = try? await m.engine.mailStore.messages(threadR: r)
        rich.delay = 0
        let spent = (await m.engine.quota(for: fam.id)?.spent ?? 0) - spentBefore
        let fetched = rich.attachmentCount
        expect(messages?.first?.attachments.filter(\.isInline).count == 11, "prefetch: 11 inline images in the message")
        // 60 KB + 7.5 MB + 6 × 60 KB = 7.92 MB: 8 parts, under 8 MB (part 9 would be the 9th).
        expect(fetched == 8, "prefetch: at most 8 parts and 8 MB on open (\(fetched))")
        expect(rich.maxInFlight <= 4 && rich.maxInFlight >= 2, "prefetch: at most 4 at once (\(rich.maxInFlight))")
        expect(spent == GmailCost.get + GmailCost.attachment * fetched,
               "prefetch: quota spent = the thread + 20 × fetched (\(spent))")
        let store = m.engine.attachmentStore
        expect(store.cachedFile(threadR: r, messageId: "k1", partId: "0.11").flatMap { try? Data(contentsOf: $0) } == small,
               "prefetch: bytes that came with the message are cached with no request")
        expect(store.cachedFile(threadR: r, messageId: "k1", partId: "0.1") != nil && store.cachedFile(threadR: r, messageId: "k1", partId: "0.9") == nil,
               "prefetch: the first parts in order; the rest load on demand")
        let lazy = try? await store.file(threadR: r, messageId: "k1", partId: "0.9")
        expect(lazy != nil && rich.attachmentCount == 9, "prefetch: a later part loads on demand (the cid handler's path)")
    }

    // MARK: Decoding

    static func decoding() {
        let raw = bytes(70_001, seed: 9)
        let body = try? JSONSerialization.data(withJSONObject: ["size": raw.count, "data": raw.base64URLString])
        expect(body.flatMap { try? GmailClient.decodeAttachment($0) } == raw, "attachments: base64url JSON decodes")
        let wrong = try? JSONSerialization.data(withJSONObject: ["size": raw.count + 1, "data": raw.base64URLString])
        expect(wrong.flatMap { try? GmailClient.decodeAttachment($0) } == nil, "attachments: a size mismatch is refused")
        for n in [0, 1, 2, 3, 56, 57, 58] {
            let d = bytes(n, seed: UInt8(n))
            expect(GmailClient.base64URL(d.base64URLString) == d && GmailClient.base64URL(d.base64URLString + "\n") == d,
                   "attachments: base64url of \(n) bytes round-trips")
        }
        expect(GmailClient.base64URL("A") == nil, "attachments: a 1-char tail is invalid")
        let fileName = LocalAttachmentStore.fileName(.init(accountId: UUID(), messageId: "../../etc", partId: "passwd"))
        expect(fileName.count == 68 && !fileName.contains("/") && !fileName.contains("."+"."), "attachments: cache names are hashes")
    }
}
