import Foundation

/// Rich mail hardening, data side: images
/// from correspondents follow the message's account and never your own addresses, and are recorded only while the
/// setting is on; message/* and multipart/* files go out as application/octet-stream; Content-ID and address header lines
/// stay short; a sender Content-ID that cleaning changes still draws its quoted image; quoted originals lose positioning
/// CSS; the outbox hash is mandatory and the raw To/Cc/Bcc must equal the checked recipients at delivery; a removed
/// account's outbox files go at once; the upload streams from a file with a timeout that grows with the size; the
/// attachment decoder. Moonfield cast only; every file lives under the test data folder.
enum RichMailReviewTests {
    static func run() async {
        rfc822Parts()
        headerLengths()
        quotedContentIds()
        quotedPositioning()
        attachmentDecoding()
        outboxHash()
        await deliveryRecipients()
        await correspondentsScope()
        await correspondentsForgotten()
        await outboxSweepOnRemoval()
        await streamedUpload()
    }

    typealias S = RichMailSendTests

    static func lines(_ raw: Data) -> [String] { String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n") }

    // MARK: message/rfc822 never goes out base64

    static func rfc822Parts() {
        let inner = Data("From: juniper@vale.example\r\nTo: avery@orbitalpickle.example\r\nSubject: Set list\r\n\r\nSee you there.\r\n".utf8)
        for type in ["message/rfc822", "Message/RFC822", "message/partial", "message/global", "multipart/mixed"] {
            let mail = RichOutgoingMail(headers: S.envelope(), text: "The earlier note.", html: nil,
                                        files: [MIMEAttachment(filename: "Set list.eml", mimeType: type, contentId: nil, source: .data(inner))])
            guard let raw = try? MIMEBuilder.buildRichData(mail, boundary: S.counter()) else { expect(false, "message/* files \(type): builds"); continue }
            let part = MIMEParser.parse(raw).parts.last
            expect(part?.contentType.value == "application/octet-stream" && part?.transferEncoding == "base64",
                   "message/* files \(type): sent as application/octet-stream, base64 (got \(part?.contentType.value ?? "nil"))")
            expect(part?.filename == "Set list.eml" && part?.body == inner, "message/* files \(type): the .eml name and bytes arrive")
            expect(!String(decoding: raw, as: UTF8.self).lowercased().contains("content-type: message/"),
                   "message/* files \(type): no message/* part with a base64 body")
        }
        let header = MIMEBuilder.attachmentHeaders(MIMEAttachment(filename: "a.eml", mimeType: "message/rfc822", contentId: nil, source: .data(inner)))
        expect(header.first?.hasPrefix("Content-Type: application/octet-stream;") == true, "message/* files: attachmentHeaders maps message/rfc822")
    }

    // MARK: Header lines

    static func headerLengths() {
        // (a) a long Content-ID (a forwarded original's inline image keeps the sender's).
        for length in [40, 63, 64, 65, 75, 76, 120, 300] {
            let id = String(repeating: "c", count: length) + "@quietcomets.example"
            let image = MIMEAttachment(filename: "logo.png", mimeType: "image/png", contentId: id, source: .data(S.png))
            let headers = MIMEBuilder.attachmentHeaders(image).joined(separator: "\r\n").components(separatedBy: "\r\n")
            expect(headers.allSatisfy { $0.utf8.count <= 78 }, "Content-ID folding Content-ID of \(length + 20): header lines ≤ 78 (\(headers.map(\.utf8.count).max() ?? 0))")
            let mail = RichOutgoingMail(headers: S.envelope(), text: "t", html: "<img src=\"cid:\(id)\">", related: [image])
            guard let raw = try? MIMEBuilder.buildRichData(mail, boundary: S.counter()) else { expect(false, "Content-ID folding: builds"); continue }
            let longest = lines(raw).map(\.utf8.count).max() ?? 0
            expect(longest <= 78, "Content-ID folding Content-ID of \(length + 20): no line over 78 (\(longest))")
            let inline = MIMEParser.extract(MIMEParser.parse(raw)).inline.first?.contentId ?? ""
            expect(!inline.isEmpty && inline == MIMEBuilder.cleanContentId(id) && inline.utf8.count <= 75,
                   "Content-ID folding Content-ID of \(length + 20): parses back as the cleaned id (\(inline.utf8.count))")
        }
        // (b) a 400-character non-ASCII display name (reply-all copies the sender's Cc names): the encoded words fold.
        let wide = String(repeating: "\u{00E9}", count: 400)
        var mail = S.envelope()
        mail.body = "Thursday at the lake house."
        mail.cc = [MailAddress(name: wide, email: "juniper@vale.example"), MailAddress(name: "Milo Brightwater", email: "milo@brightwater.example")]
        let plain = MIMEBuilder.build(mail)
        let plainLongest = lines(plain).map(\.utf8.count).max() ?? 0
        expect(plainLongest <= 78, "address folding: a 400-character name folds, no line over 78 (\(plainLongest))")
        let cc = MailAddress.parseList(MIMEParser.parse(plain).header("Cc") ?? "")
        expect(cc.map(\.email) == ["juniper@vale.example", "milo@brightwater.example"] && cc.first?.name == wide && cc.last?.name == "Milo Brightwater",
               "address folding: the folded Cc parses back (names and addresses)")
        if let rich = try? MIMEBuilder.buildRichData(RichOutgoingMail(headers: mail, text: "x", html: "<div>x</div>"), boundary: S.counter()) {
            expect((lines(rich).map(\.utf8.count).max() ?? 0) <= 78, "address folding: the rich builder's headers fold too")
        } else { expect(false, "address folding: rich builds") }
        // (c) a long ASCII name without a space (nothing to fold at): encoded words, still ≤ 78.
        let unbroken = String(repeating: "Q", count: 1_200)
        var ascii = S.envelope()
        ascii.body = "x"
        ascii.to = [MailAddress(name: unbroken, email: "theo@quill.example")]
        let asciiRaw = MIMEBuilder.build(ascii)
        let asciiLongest = lines(asciiRaw).map(\.utf8.count).max() ?? 0
        expect(asciiLongest <= 78, "unbroken name: a 1,200-character unbroken name never makes a line over 78 (\(asciiLongest))")
        expect(MailAddress.parseList(MIMEParser.parse(asciiRaw).header("To") ?? "") == [MailAddress(name: unbroken, email: "theo@quill.example")],
               "unbroken name: and parses back")
        // (d) a long quoted name with spaces folds between its words.
        let spaced = Array(repeating: "Orbital Pickle Co.", count: 12).joined(separator: " ")
        var quoted = S.envelope()
        quoted.body = "x"
        quoted.to = [MailAddress(name: spaced, email: "avery@orbitalpickle.example")]
        let quotedRaw = MIMEBuilder.build(quoted)
        expect((lines(quotedRaw).map(\.utf8.count).max() ?? 0) <= 78
               && MailAddress.parseList(MIMEParser.parse(quotedRaw).header("To") ?? "").first?.name == spaced,
               "quoted name: a long quoted name folds and parses back")
        // (e) control characters (a NUL in a quoted original's text) never go out as 7bit.
        for text in ["nul\u{0}here", "bell\u{7}", "del\u{7F}"] {
            let part = MIMEBuilder.textPart(text)
            var plainMail = S.envelope()
            plainMail.body = text
            let built = MIMEBuilder.build(plainMail)
            expect(part.encoding == "quoted-printable" && !built.contains(0) && !built.contains(0x07) && !built.contains(0x7F)
                   && MIMEParser.extract(MIMEParser.parse(built)).text.hasPrefix(text),
                   "control characters \(text.debugDescription): controls go quoted-printable and round-trip")
        }
        // Short lists are written exactly as before (the plain-mail goldens).
        expect(MIMEBuilder.addressHeader("To", [MailAddress(name: "Priya Starling", email: "priya@starling.example")]) == "To: Priya Starling <priya@starling.example>",
               "header folding: a short To is unchanged")
    }

    // MARK: A sender Content-ID that cleaning changes

    static func quotedContentIds() {
        let long = String(repeating: "b", count: 120) + "@starling.example"
        let raw = ["my logo@starling.example", "Caf\u{00E9}@starling.example", "\u{00F1}", long, "Logo@Starling.example"]
        let sources = raw.enumerated().map { "<img src=\"cid:\($0.element)\" alt=\"picture \($0.offset)\">" }.joined(separator: " ")
        let html = HTMLSanitizer.sanitize("<div>Hi Avery,</div><p>\(sources)</p>", remote: .allow,
                                          cids: Set(raw.compactMap(MailCID.normalize))).html
        let attachments = raw.enumerated().map { i, id in
            CachedMessage.Attachment(name: "picture \(i).png", bytes: S.png.count, partId: "1.\(i + 2)", attachmentId: "ANG\(i)",
                                     mimeType: "image/png", contentId: id, isInline: true)
        }
        let m = CachedMessage(id: "q9", from: "Priya Starling", fromEmail: "priya@starling.example", to: [], cc: [], date: S.fixedDate,
                              subject: "Pictures", html: html, text: "Hi Avery,", hasRemoteImages: false, attachments: attachments,
                              flowed: false, delsp: false)
        expect(CachedMessage.referencedCIDs(html).count == 5, "quoted images: the fixture draws five cid pictures")
        for (kind, style) in [(MailQuoteRequest.Kind.reply, MailQuoteRequest.Style.bar), (.reply, .header), (.forward, .bar)] {
            let q = MailQuoteComposer.compose(m, kind: kind, style: style)
            let sent = q.images.map(\.contentId)
            expect(sent.allSatisfy { !$0.isEmpty && MIMEBuilder.cleanContentId($0) == $0 } && Set(sent.compactMap(MailCID.normalize)).count == sent.count,
                   "quoted images \(kind)/\(style): every quoted image goes out with a clean, distinct Content-ID (\(sent))")
            let drawn = CachedMessage.referencedCIDs(q.html)
            let parts = Set(sent.compactMap(MailCID.normalize))
            expect(!drawn.isEmpty && drawn.isSubset(of: parts), "quoted images \(kind)/\(style): every cid the quote draws is a part that goes along")
            expect(q.images.count + q.html.components(separatedBy: "alt=\"picture").count - 1 >= 5 && q.images.count >= 4,
                   "quoted images \(kind)/\(style): pictures are kept (\(q.images.count) of 5), none silently broken")
            expect(q.images.contains { $0.contentId == "Logo@Starling.example" } && q.html.contains("src=\"cid:Logo@Starling.example\""),
                   "quoted images \(kind)/\(style): a clean sender id stays exactly as the sender wrote it")
            // Through the builder and back: each drawn id has its part.
            let related = q.images.map { MIMEAttachment(filename: $0.filename, mimeType: $0.mimeType, contentId: $0.contentId, source: .data(S.png)) }
            if let built = try? MIMEBuilder.buildRichData(RichOutgoingMail(headers: S.envelope(), text: q.text, html: q.html, related: related)) {
                let inline = Set(MIMEParser.extract(MIMEParser.parse(built)).inline.compactMap(\.contentId).compactMap(MailCID.normalize))
                expect(drawn.isSubset(of: inline), "quoted images \(kind)/\(style): the built message carries a part for every drawn cid")
            } else { expect(false, "quoted images: builds") }
        }
    }

    // MARK: Positioning CSS in quoted originals

    static func quotedPositioning() {
        let html = HTMLSanitizer.sanitize("""
            <div>Hi Avery,</div>\
            <p style="position:fixed;top:0;left:0;right:0;bottom:0;inset:0;width:100%;height:100%;background:#fff;z-index:9999;\
            transform:translateY(-200px);translate:0 -40px;rotate:2deg;scale:1.1;opacity:0.99;clip-path:inset(0);clip:rect(0,0,0,0);\
            color:#2A1B4A">Pay the new account</p>\
            <span style="display:none">hidden</span>\
            <span style="display:inline-block;margin:-300px 0 0 0;margin-top:-2em;visibility:hidden;font-family:&quot;Pickle;Sans&quot;, serif">kept</span>\
            <div style="margin:8px 0;padding:4px">fine</div>
            """, remote: .allow, cids: []).html
        expect(html.contains("position: fixed") && html.contains("display: none"), "quoted CSS: the sanitizer keeps them (the fixture is real)")
        let m = CachedMessage(id: "q5", from: "Priya Starling", fromEmail: "priya@starling.example", to: [], cc: [], date: S.fixedDate,
                              subject: "Invoice", html: html, text: "Hi Avery,", hasRemoteImages: false, attachments: [], flowed: false, delsp: false)
        for (kind, style) in [(MailQuoteRequest.Kind.reply, MailQuoteRequest.Style.bar), (.reply, .header), (.forward, .bar)] {
            let q = MailQuoteComposer.compose(m, kind: kind, style: style).html
            let gone = ["position", "z-index", "transform", "translate", "rotate:", "scale:", "opacity", "clip-path", "clip:", "inset:",
                        " top:", "\"top:", " bottom:", "\"bottom:", "; left:", "\"left:", "; right:", "\"right:", "display: none", "-300px",
                        "-2em", "visibility"]
            let left = gone.filter { q.contains($0) }
            expect(left.isEmpty, "quoted CSS \(kind)/\(style): positioning and hiding CSS dropped from the quoted original (left: \(left))")
            let kept = ["width: 100%", "height: 100%", "background: #fff", "color: #2A1B4A", "display: inline-block",
                        "font-family: &quot;Pickle;Sans&quot;, serif", "margin: 8px 0", "padding: 4px", "Pay the new account", ">hidden<", ">kept<"]
            let missing = kept.filter { !q.contains($0) }
            expect(missing.isEmpty, "quoted CSS \(kind)/\(style): everything else stays (missing: \(missing))")
        }
        expect(MailQuoteComposer.compose(m, kind: .reply, style: .bar).html.contains("margin:0px 0px 0px 0.8ex;border-left:1px solid"),
               "quoted CSS: our own quote bar keeps its style")
    }

    // MARK: The attachment decoder

    static func attachmentDecoding() {
        let raw = S.bytes(1_000_003, seed: 5)
        let url = raw.base64URLString
        let padded = raw.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let bodies: [(String, String)] = [
            ("size first", "{\"size\": \(raw.count), \"data\": \"\(url)\"}"),
            ("data first", "{\"data\":\"\(url)\",\"size\":\(raw.count)}"),
            ("padded", "{\"size\":\(raw.count),\"data\":\"\(padded)\"}"),
            ("extra fields", "{\"attachmentId\":\"ANG-x_y\\\"z\",\"meta\":{\"data\":\"AAAA\",\"list\":[1,\"]\"]},\"size\":\(raw.count),\n \"data\" : \"\(url)\" }"),
            ("no size", "{\"data\":\"\(url)\"}"),
        ]
        for (label, body) in bodies {
            expect((try? GmailClient.decodeAttachment(Data(body.utf8))) == raw, "attachment decoder: \(label)")
        }
        expect((try? GmailClient.decodeAttachment(Data("{\"size\":0,\"data\":\"\"}".utf8))) == Data(), "attachment decoder: empty")
        for (label, body) in [("size mismatch", "{\"size\":\(raw.count - 1),\"data\":\"\(url)\"}"), ("no data", "{\"size\":3}"),
                              ("bad character", "{\"data\":\"AAA*\"}"), ("one-character tail", "{\"data\":\"AAAAA\"}"),
                              ("not JSON", "AAAA"), ("data not a string", "{\"data\":12}")] {
            expect((try? GmailClient.decodeAttachment(Data(body.utf8))) == nil, "attachment decoder: \(label) is refused")
        }
        // JSON escapes in the value (Gmail never sends them) still decode, through the general path.
        expect((try? GmailClient.decodeAttachment(Data("{\"data\":\"aGk\\u003d\"}".utf8))) == Data("hi".utf8), "attachment decoder: an escaped value")
    }

    // MARK: The outbox hash and the recipients at delivery

    static func outboxHash() {
        let store = OutboxStore(directory: DataTests.folder("rich-review-outbox"))
        try? store.prepare()
        let name = OutboxStore.fileName(actionId: UUID().uuidString)
        let bytes = Data("To: avery@quietcomets.example\r\n\r\nhi\r\n".utf8)
        try? bytes.write(to: store.url(name)!)
        expect((try? store.read(name, sha256: OutboxStore.sha256(bytes))) == bytes, "outbox: an outbox file reads with its hash")
        expect((try? store.read(name, sha256: nil)) == nil, "outbox: without a recorded hash it is unreadable")
        expect((try? store.read(name, sha256: "")) == nil, "outbox: an empty hash is unreadable too")
        // The envelope the raw message carries.
        var mail = S.envelope()
        mail.body = "x"
        mail.cc = [MailAddress(name: String(repeating: "\u{00E9}", count: 300), email: "Juniper@Vale.example"),
                   MailAddress(name: "Milo Brightwater", email: "milo@brightwater.example")]
        mail.bcc = [MailAddress(name: "", email: "avery@quietcomets.example")]
        expect(MIMEParser.envelopeRecipients(MIMEBuilder.build(mail))
               == ["priya@starling.example", "juniper@vale.example", "milo@brightwater.example", "avery@quietcomets.example"],
               "outbox: To, Cc and Bcc read back from the raw headers (folded, encoded, any case)")
        expect(MIMEParser.envelopeRecipients(Data("Subject: x\r\n\r\nTo: priya@starling.example\r\n".utf8)) == [],
               "outbox: a To line in the body is not a recipient")
        expect(MIMEParser.envelopeRecipients(Data("To: priya@starling.example".utf8)) == nil, "outbox: no end of headers → unreadable")
    }

    static func deliveryRecipients() async {
        let s = await S.setup("rich-review-rcpt")
        let actions = s.m.engine.mailActions
        let repo = ActionRepo(db: s.m.db)
        func queued(_ draft: MailDraft, _ tamper: (inout [String: String]) -> Void) async -> UndoToken? {
            s.m.sleeper.gate()
            guard let token = try? await actions.send(draft), var payload = (try? repo.get(token.id))?.payload else {
                s.m.sleeper.release(); return nil
            }
            tamper(&payload)
            try? repo.setPayload(token.id, payload)
            _ = await eventually(2) { s.m.sleeper.waiting >= 1 }
            s.m.sleeper.release()
            await actions.drain()
            return token
        }
        // A send in the row whose raw To was swapped after the check (rcpt still says your own address).
        let small = MailDraft(from: s.orb.id, to: ["avery@quietcomets.example"], subject: "Set list", body: "Thursday.", signatureIncluded: true)
        let t1 = await queued(small) { p in
            let raw = p["raw"].flatMap { Data(base64URL: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            p["raw"] = Data(raw.replacingOccurrences(of: "To: avery@quietcomets.example", with: "To: juniper@vale.example").utf8).base64URLString
        }
        expect(t1.map { actions.sendStatus($0) } == .failed(OutboxStore.unreadable) && s.m.gmail.sentCount(token: s.token) == 0,
               "outbox: raw To ≠ the checked recipients → refused at delivery, nothing sent")
        // An outbox file rewritten with a new To and a matching hash (row and file both changed).
        let t2 = await queued(S.richDraft(s)) { p in
            guard let name = p["rawFile"] else { return }
            let file = S.outbox(s).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { return }
            let swapped = Data(String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "To: avery@quietcomets.example", with: "To: avery@quietcomets.example, juniper@vale.example").utf8)
            try? swapped.write(to: file)
            p["rawSHA256"] = OutboxStore.sha256(swapped)
            p["rawBytes"] = "\(swapped.count)"
        }
        expect(t2.map { actions.sendStatus($0) } == .failed(OutboxStore.unreadable) && s.m.gmail.sentCount(token: s.token) == 0,
               "outbox: an added recipient in the file → refused, nothing sent")
        // An outbox file without its hash.
        let t3 = await queued(S.richDraft(s)) { p in p["rawSHA256"] = nil }
        expect(t3.map { actions.sendStatus($0) } == .failed(OutboxStore.unreadable) && s.m.gmail.sentCount(token: s.token) == 0,
               "outbox: rawFile without rawSHA256 → unreadable, nothing sent")
        // Untouched sends with To, Cc and Bcc, names and an approval go as before.
        var d = S.richDraft(s, to: ["Avery Moonfield <avery@quietcomets.example>"])
        d.cc = ["Ines Marlowe <ines@marlowe.example>"]
        d.bcc = ["avery@orbitalpickle.example"]
        d.approvedOutside = ["ines@marlowe.example"]
        let t4 = await queued(d) { _ in }
        expect(t4.map { actions.sendStatus($0) } == .sent && s.m.gmail.sentCount(token: s.token) == 1,
               "outbox: an untouched send with To, Cc and Bcc is delivered")
    }

    // MARK: Correspondents

    static func correspondentsScope() async {
        let m = MailHarness("rich-review-correspondents")
        let setting = Locked(false)
        m.h.env.imagesFromCorrespondents = { setting.value }
        let (orb, token) = m.account("avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let (cmt, _) = m.account("avery@quietcomets.example", tag: "CMT", sort: 1)
        let repo = CorrespondentRepo(db: m.db)
        // Off: nothing is recorded, from sync or from sends.
        m.gmail.add(token: token, thread: "set", id: "s1", from: "Kofi Ember <kofi@ember.example>", subject: "Set list",
                    date: m.clock.now.addingTimeInterval(-900))
        m.gmail.add(token: token, thread: "set", id: "s2", from: "Avery Moonfield <avery@orbitalpickle.example>", subject: "Re: Set list",
                    date: m.clock.now.addingTimeInterval(-800), labels: ["SENT"])
        _ = await m.syncMail(orb.id)
        expect((try? repo.contains("kofi@ember.example")) == false, "correspondents: with the setting off, sync records no correspondents")
        let actions = m.engine.mailActions
        if let t = try? await actions.send(MailDraft(from: orb.id, to: ["avery@quietcomets.example"], cc: ["Ines Marlowe <ines@marlowe.example>"],
                                                     subject: "Rehearsal", body: "Thursday.", approvedOutside: ["ines@marlowe.example"],
                                                     signatureIncluded: true)) {
            await actions.drain()
            expect(actions.sendStatus(t) == .sent && (try? repo.contains("ines@marlowe.example")) == false,
                   "correspondents: with the setting off, a send records no correspondents")
        } else { expect(false, "correspondents: send") }
        // On: a thread with your SENT reply records the other senders, never your own addresses (any account).
        setting.value = true
        m.gmail.add(token: token, thread: "set", id: "s3", from: "Kofi Ember <kofi@ember.example>", subject: "Re: Set list",
                    date: m.clock.now.addingTimeInterval(-700))
        m.gmail.add(token: token, thread: "set", id: "s4", from: "Avery Moonfield <AVERY@quietcomets.example>", subject: "Re: Set list",
                    date: m.clock.now.addingTimeInterval(-600))
        _ = await m.syncMail(orb.id)
        expect((try? repo.contains("kofi@ember.example", accountId: orb.id)) == true, "correspondents: on → the other senders are recorded")
        expect((try? repo.contains("avery@quietcomets.example")) == false && (try? repo.contains("avery@orbitalpickle.example")) == false,
               "correspondents: your own addresses are never recorded")
        let added = (try? repo.add(accountId: orb.id, addresses: ["Avery@OrbitalPickle.example", "avery@quietcomets.example", "milo@brightwater.example"],
                                   at: m.clock.now)) ?? -1
        expect(added == 1 && (try? repo.contains("avery@orbitalpickle.example")) == false, "correspondents: CorrespondentRepo.add drops your own addresses")
        // Rows written before the fix (your own address) never let a spoofed self-sender load images.
        try? m.db.run("INSERT INTO mail_correspondents(account_id, address, last_at) VALUES (?, ?, ?)",
                      [orb.id.uuidString, "avery@orbitalpickle.example", 1.0])
        let store = m.engine.mailStore
        expect(!store.allowsImages(from: "Avery Moonfield <avery@orbitalpickle.example>", accountId: orb.id),
               "correspondents: a sender claiming your own address never counts as a correspondent")
        // Scoped to the message's account.
        expect(store.allowsImages(from: "Kofi Ember <kofi@ember.example>", accountId: orb.id), "correspondents: a correspondent of that account loads images")
        expect(!store.allowsImages(from: "Kofi Ember <kofi@ember.example>", accountId: cmt.id),
               "correspondents: …but not in another account's mail")
        expect(!store.allowsImages(from: "kofi@ember.example"), "correspondents: without an account only the allow list counts")
        try? store.setAllowsImages(from: "kofi@ember.example", true)
        expect(store.allowsImages(from: "kofi@ember.example") && store.allowsImages(from: "kofi@ember.example", accountId: cmt.id),
               "correspondents: the allow list still counts everywhere")
        try? store.setAllowsImages(from: "kofi@ember.example", false)
        setting.value = false
        expect(!store.allowsImages(from: "Kofi Ember <kofi@ember.example>", accountId: orb.id), "correspondents: setting off → blocked again")
        // The reader path: messages(threadR:) decides with the thread's account.
        setting.value = true
        let r = m.r(orb.id, "set")
        let shown = (try? await store.messages(threadR: r)) ?? []
        expect(!shown.isEmpty, "correspondents: the reader gets the thread")
    }

    // MARK: Turning the setting off forgets every correspondent

    static func correspondentsForgotten() async {
        let m = MailHarness("rich-review-correspondents-off")
        let setting = Locked(true)
        m.h.env.imagesFromCorrespondents = { setting.value }
        let (orb, token) = m.account("avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let (cmt, _) = m.account("avery@quietcomets.example", tag: "CMT", sort: 1)
        let repo = CorrespondentRepo(db: m.db)
        let store = m.engine.mailStore
        let kofi = "Kofi Ember <kofi@ember.example>"
        func count() -> Int { (try? repo.count()) ?? -1 }
        // On: a thread you replied in (ORB) and a send (CMT) record correspondents in both accounts.
        m.gmail.add(token: token, thread: "gig", id: "g1", from: kofi, subject: "Gig", date: m.clock.now.addingTimeInterval(-900))
        m.gmail.add(token: token, thread: "gig", id: "g2", from: "Avery Moonfield <avery@orbitalpickle.example>", subject: "Re: Gig",
                    date: m.clock.now.addingTimeInterval(-800), labels: ["SENT"])
        _ = await m.syncMail(orb.id)
        let actions = m.engine.mailActions
        if let t = try? await actions.send(MailDraft(from: cmt.id, to: ["Ines Marlowe <ines@marlowe.example>"], subject: "Rehearsal",
                                                     body: "Thursday.", approvedOutside: ["ines@marlowe.example"], signatureIncluded: true)) {
            await actions.drain()
            expect(actions.sendStatus(t) == .sent, "correspondents off: the send goes")
        } else { expect(false, "correspondents off: send") }
        expect((try? repo.contains("kofi@ember.example", accountId: orb.id)) == true
               && (try? repo.contains("ines@marlowe.example", accountId: cmt.id)) == true && count() == 2,
               "correspondents off: on → correspondents recorded in both accounts")
        expect(store.allowsImages(from: kofi, accountId: orb.id), "correspondents off: on → a correspondent's images load")
        // Off: Settings saves the key off, then clears. Every account's rows go.
        setting.value = false
        expect((try? store.forgetCorrespondents()) != nil, "correspondents off: the clear succeeds")
        expect(count() == 0, "correspondents off: off → every recorded address is gone, all accounts")
        // On again: it starts empty, so nobody's images load until they're recorded again.
        setting.value = true
        expect(count() == 0 && !store.allowsImages(from: kofi, accountId: orb.id), "correspondents off: on again → starts empty")
        m.gmail.add(token: token, thread: "gig", id: "g3", from: kofi, subject: "Re: Gig", date: m.clock.now.addingTimeInterval(-700))
        _ = await m.syncMail(orb.id)
        expect((try? repo.contains("kofi@ember.example", accountId: orb.id)) == true && count() == 1,
               "correspondents off: on again → records afresh from new mail")
        // A sync or send that read the setting just before it went off records nothing once the write runs.
        let late = (try? repo.add(accountId: orb.id, addresses: ["milo@brightwater.example"], at: m.clock.now, onlyIf: { false })) ?? -1
        expect(late == 0 && (try? repo.contains("milo@brightwater.example")) == false, "correspondents off: a write after the switch went off records nothing")
        // Turned off while the engine wasn't running (or a failed clear): the next start clears; on at start keeps them.
        m.engine.start()
        expect(count() == 1, "correspondents off: engine start with the setting on keeps the list")
        await m.engine.stop()
        setting.value = false
        m.engine.start()
        expect(count() == 0, "correspondents off: engine start with the setting off clears the list")
        await m.engine.stop()
    }

    // MARK: A removed account's outbox files

    static func outboxSweepOnRemoval() async {
        let s = await S.setup("rich-review-sweep")
        let actions = s.m.engine.mailActions
        s.m.sleeper.gate()
        var fromCmt = S.richDraft(s)
        fromCmt.from = s.cmt.id
        // The other send goes to an address that stays the user's own after the removal (D-023 holds anything else).
        guard let a = try? await actions.send(fromCmt), let b = try? await actions.send(S.richDraft(s, to: ["avery@orbitalpickle.example"])),
              let kept = (try? ActionRepo(db: s.m.db).get(b.id))?.payload["rawFile"] else {
            expect(false, "removed account: queued"); s.m.sleeper.release(); return
        }
        expect(S.outboxFiles(s).count == 2, "removed account: two queued sends, two outbox files")
        _ = try? AccountRepo(db: s.m.db).delete(s.cmt.id)
        s.m.engine.accountsChanged()
        expect(S.outboxFiles(s) == [kept], "removed account: removing an account deletes its queued sends' files at once, others stay")
        _ = await eventually(2) { s.m.sleeper.waiting >= 2 }
        s.m.sleeper.release()
        await actions.drain()
        expect(actions.sendStatus(b) == .sent && actions.sendStatus(a) == .unknown && S.outboxFiles(s).isEmpty,
               "removed account: the other account's send still goes; the removed one never does")
    }

    // MARK: The upload streams from a file

    static func streamedUpload() async {
        let s = await S.setup("rich-review-upload")
        let actions = s.m.engine.mailActions
        try? S.bytes(1_300_000, seed: 91).write(to: s.files.appendingPathComponent("Moodboard.zip"))
        var d = MailDraft(from: s.orb.id, to: ["avery@quietcomets.example"], subject: "Moodboard", body: "Attached.", signatureIncluded: true)
        d.attachments = [S.attachment(s, "Moodboard.zip", "application/zip")]
        guard let token = try? await actions.send(d) else { expect(false, "upload: queued"); return }
        await actions.drain()
        let up = s.rich.uploads.first
        expect(actions.sendStatus(token) == .sent && up?.fromFile == true, "upload: the multipart body streams from a file, not memory")
        expect(up?.bodyFile.map { $0.deletingLastPathComponent().standardizedFileURL.path == S.outbox(s).standardizedFileURL.path } == true
               && up?.bodyFile.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
               "upload: the body file sits in the outbox folder while it uploads and is deleted after")
        let wanted = HTTP.uploadResourceTimeout(bytes: up?.rawBytes ?? 0)
        expect(up?.resourceTimeout == wanted && wanted >= HTTP.longResourceTimeout, "upload: the upload's time limit comes from its size")
        expect(HTTP.uploadResourceTimeout(bytes: 1 << 20) == HTTP.longResourceTimeout
               && HTTP.uploadResourceTimeout(bytes: 25_000_000) >= 25_000_000 / 8_192,
               "upload: 15 min for small uploads; a 25 MB upload gets time for an 8 KB/s uplink")
        let parsed = MIMEParser.extract(MIMEParser.parse(s.m.gmail.sentRaw(token: s.token).last ?? Data()))
        expect(parsed.files.first?.bytes == 1_300_000, "upload: the file arrives whole")
    }
}
