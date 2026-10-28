import Foundation

/// Rich mail sending: the multipart builder against
/// golden files, its encodings and size, the quoted original, and the engine's send path (outbox file, upload URI,
/// undo, retry, restart recovery, the 25 MB refusal, correspondents), with the D-023 approval rules on sends that carry
/// attachments. Moonfield cast only; every file lives under the test data folder.
enum RichMailSendTests {
    static func run() async {
        mimeGoldens()
        labTimes()
        encodings()
        sizes()
        quoteComposer()
        await richSend()
        await approvalsWithAttachments()
        await replyWithQuote()
        await uploadPath()
        await undoDeletesFile()
        await retryOnce()
        await restartRecovery()
        await overLimit()
        await correspondents()
    }

    // MARK: Fixtures

    static let fixedDate = Date(timeIntervalSince1970: 1_793_000_000)

    static func envelope(_ subject: String = "Q4 pickle launch: the plan", inReplyTo: String? = nil) -> OutgoingMail {
        OutgoingMail(from: MailAddress(name: "Avery Moonfield", email: "avery@orbitalpickle.example"),
                     to: [MailAddress(name: "Priya Starling", email: "priya@starling.example")],
                     cc: [MailAddress(name: "Milo Brightwater", email: "milo@brightwater.example")],
                     subject: subject, body: "", messageID: "<golden-1@yayascalendar.local>", inReplyTo: inReplyTo,
                     references: inReplyTo.map { [$0] } ?? [], date: fixedDate)
    }

    /// "yc-golden-1", "yc-golden-2"… (deterministic boundaries for the goldens).
    static func counter(_ prefix: String = "yc-golden-") -> () -> String {
        var n = 0
        return { n += 1; return "\(prefix)\(n)" }
    }

    static func bytes(_ count: Int, seed: UInt32) -> Data {
        var x = seed &* 2_654_435_761 | 1
        var out = Data(count: count)
        out.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<count {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                p[i] = UInt8(truncatingIfNeeded: x)
            }
        }
        return out
    }

    static let png = RichMailSendTests.bytes(3_000, seed: 7)
    static let pdf = RichMailSendTests.bytes(9_000, seed: 8)
    static let sheet = RichMailSendTests.bytes(4_100, seed: 9)

    static let text = "Hi Priya,\n\nHere is the plan for the pickle launch at Caf\u{00E9} Nowhere.\n\n-- \nAvery Moonfield\nOrbital Pickle Co."
    static let html = "<div dir=\"auto\" style=\"font-family:Helvetica, Arial, sans-serif;font-size:14px\"><div>Hi <b>Priya</b>,</div>"
        + "<div><br></div><div>Here is the plan for the pickle launch at Caf\u{00E9} Nowhere.</div>"
        + "<div><img src=\"cid:img-1@yayascalendar.local\" width=\"60\" height=\"40\" alt=\"\" style=\"max-width:100%\"></div>"
        + "<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\"><div>-- </div><div>Avery Moonfield</div></div></div>"

    static func image() -> MIMEAttachment {
        MIMEAttachment(filename: "label proof.png", mimeType: "image/png", contentId: "img-1@yayascalendar.local", source: .data(png))
    }

    static func files() -> [MIMEAttachment] {
        [MIMEAttachment(filename: "Launch plan.pdf", mimeType: "application/pdf", contentId: nil, source: .data(pdf)),
         MIMEAttachment(filename: "Budget Q4.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                        contentId: nil, source: .data(sheet))]
    }

    /// Priya's message as the body cache keeps it: sanitized HTML (with a `<style>`, ids, a faked reader marker and a
    /// cid logo drawn with a mixed-case Content-ID) and its text.
    static func original() -> CachedMessage {
        let html = HTMLSanitizer.sanitize("""
            <html><head><style>p { color: #c00 }</style></head><body><div id="main" class="yc-quote intro">Hi Avery,</div>\
            <p id="p2">The labels look great. <img src="cid:Logo@Starling.example" alt="Starling logo"></p>\
            <p>See you at Suite 404.<img src="cid:gone@starling.example" alt="old badge"></p></body></html>
            """, remote: .allow, cids: ["logo@starling.example"]).html
        return CachedMessage(id: "q1", from: "Priya Starling", fromEmail: "priya@starling.example", to: ["Avery Moonfield <avery@orbitalpickle.example>"],
                             cc: [], date: fixedDate.addingTimeInterval(-3_600), subject: "Q4 pickle launch plan", html: html,
                             text: "Hi Avery,\n\nThe labels look great.\n\nSee you at Suite 404.", hasRemoteImages: false,
                             attachments: [.init(name: "", bytes: png.count, partId: "1.2", attachmentId: "ANGlogo", mimeType: "image/png",
                                                 contentId: "Logo@Starling.example", isInline: true)],
                             flowed: false, delsp: false)
    }

    /// The five MIME structures plus a reply with its quote and a forward with the original's images.
    static func goldenCases() -> [(String, RichOutgoingMail)] {
        var cases: [(String, RichOutgoingMail)] = []
        var plain = envelope()
        plain.body = text
        cases.append(("01-plain", RichOutgoingMail(headers: plain, text: text, html: nil)))
        cases.append(("02-plain-files", RichOutgoingMail(headers: envelope(), text: text, html: nil, files: files())))
        cases.append(("03-rich", RichOutgoingMail(headers: envelope(), text: text, html: html)))
        cases.append(("04-rich-inline", RichOutgoingMail(headers: envelope(), text: text, html: html, related: [image()])))
        cases.append(("05-rich-inline-files", RichOutgoingMail(headers: envelope(), text: text, html: html, related: [image()], files: files())))
        let reply = MailQuoteComposer.compose(original(), kind: .reply, style: .bar)
        cases.append(("06-reply-quote", RichOutgoingMail(headers: envelope("Re: Q4 pickle launch plan", inReplyTo: "<q1@starling.example>"),
                                                         text: text + reply.text, html: html + "<br>" + reply.html,
                                                         related: [image()] + reply.images.map {
                                                             MIMEAttachment(filename: $0.filename, mimeType: $0.mimeType, contentId: $0.contentId, source: .data(png))
                                                         })))
        let forward = MailQuoteComposer.compose(original(), kind: .forward, style: .bar)
        cases.append(("07-forward-images", RichOutgoingMail(headers: envelope("Fwd: Q4 pickle launch plan"), text: text + forward.text,
                                                            html: html + "<br>" + forward.html,
                                                            related: [image()] + forward.images.map {
                                                                MIMEAttachment(filename: $0.filename, mimeType: $0.mimeType, contentId: $0.contentId, source: .data(png))
                                                            }, files: [files()[0]])))
        return cases
    }

    static var goldenFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens/mime", isDirectory: true)
    }

    /// The message's own `Date:` header is written in the zone of the Mac that builds it (RFC 5322 local time with its
    /// offset), so the goldens mask that one line. Only the top-level header block is touched: the "On … wrote:" line
    /// and a forward's "Date: …" line in the body come from the widget calendar, which the data tests pin to the fixed
    /// London calendar, so they are compared byte for byte.
    static func normalized(_ raw: String) -> String {
        var inHeader = true
        return raw.components(separatedBy: "\r\n").map { line -> String in
            if line.isEmpty { inHeader = false }
            return inHeader && line.hasPrefix("Date: ") ? "Date: <date>" : line
        }.joined(separator: "\r\n")
    }

    /// Every time of day a golden shows, in London time: quoted-printable soft breaks undone, then each "h:mm AM/PM"
    /// must be the original's date read in London (`fixedDate - 1 h`), whatever zone the test Mac is in.
    static func labTimes() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let f = DateFormatter()
        f.calendar = london
        f.timeZone = london.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM yyyy 'at' h:mm a"
        let lab = f.string(from: original().date)
        expect(lab == "Monday 26 October 2026 at 6:33 AM", "rich mail goldens: the original is dated 6:33 AM London (\(lab))")
        let time = try! NSRegularExpression(pattern: "\\b[0-9]{1,2}:[0-9]{2}\\s?(AM|PM)")
        var seen = 0
        for (name, _) in goldenCases() {
            guard let data = try? Data(contentsOf: goldenFolder.appendingPathComponent(name + ".eml")) else { continue }
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "=\r\n", with: "")
            let ns = text as NSString
            for match in time.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let found = ns.substring(with: match.range)
                seen += 1
                expect(lab.hasSuffix(found), "rich mail golden \(name): \(found) is London time (\(lab.suffix(7)))")
            }
            if name == "06-reply-quote" || name == "07-forward-images" {
                expect(text.contains(lab), "rich mail golden \(name): carries \"\(lab)\"")
            }
        }
        expect(seen >= 4, "rich mail goldens: the quote and forward lines were checked (\(seen) times of day)")
    }

    // MARK: Builder goldens and structure

    static func mimeGoldens() {
        let write = ProcessInfo.processInfo.environment["YC_WRITE_GOLDENS"] == "1"
        if write { try? FileManager.default.createDirectory(at: goldenFolder, withIntermediateDirectories: true) }
        for (name, mail) in goldenCases() {
            guard let data = try? MIMEBuilder.buildRichData(mail, boundary: counter()) else { expect(false, "rich mail builder \(name): builds"); continue }
            let raw = String(decoding: data, as: UTF8.self)
            let url = goldenFolder.appendingPathComponent(name + ".eml")
            if write {
                try? Data(normalized(raw).utf8).write(to: url)
            } else {
                let want = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
                expect(want == normalized(raw), "rich mail builder \(name): golden")
                if want != normalized(raw) { print("    \(name): built \(data.count) bytes, golden \(want?.utf8.count ?? -1)") }
            }
            structure(name, raw: data, mail: mail)
        }
        // The file path writes what the memory path builds, and reports its size.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yc-mime-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, mixed) = goldenCases()[4]
        let file = dir.appendingPathComponent("out.eml")
        let size = try? MIMEBuilder.buildRich(mixed, to: file, boundary: counter())
        let memory = try? MIMEBuilder.buildRichData(mixed, boundary: counter())
        expect(size != nil && size == memory?.count && (try? Data(contentsOf: file)) == memory, "rich mail builder: file output = memory output, size returned")
        let perms = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue
        expect(perms == 0o600, "rich mail builder: the built file is 0600")
    }

    /// CRLF only; lines ≤ 78; base64 lines exactly 76 (the last of a part ≤ 76); every boundary distinct and absent from
    /// content; parse → extract round trip.
    static func structure(_ name: String, raw: Data, mail: RichOutgoingMail) {
        let bytes = [UInt8](raw)
        var bare = false
        for (i, b) in bytes.enumerated() {
            if b == 0x0A && (i == 0 || bytes[i - 1] != 0x0D) { bare = true; break }
            if b == 0x0D && (i + 1 >= bytes.count || bytes[i + 1] != 0x0A) { bare = true; break }
        }
        expect(!bare, "rich mail builder \(name): CRLF only")
        let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n")
        let long = lines.filter { $0.utf8.count > 78 }
        expect(long.isEmpty, "rich mail builder \(name): no line over 78 octets (\(long.first?.prefix(40) ?? ""))")
        // Boundaries: declared once each, used only as delimiter lines.
        let declared = lines.compactMap { line -> String? in
            guard let r = line.range(of: "boundary=\"") else { return nil }
            return String(line[r.upperBound...].dropLast())
        }
        expect(Set(declared).count == declared.count, "rich mail builder \(name): boundaries unique")
        for b in declared {
            let uses = lines.filter { $0.contains(b) }
            expect(uses.allSatisfy { $0 == "--\(b)" || $0 == "--\(b)--" || $0.contains("boundary=\"\(b)\"") },
                   "rich mail builder \(name): boundary \(b) only on delimiter lines")
        }
        // base64 bodies: whole 76-character lines.
        var inBase64 = false, afterHeaders = false, run: [String] = []
        var base64OK = true
        for line in lines {
            if line.hasPrefix("Content-Transfer-Encoding: base64") { inBase64 = true; afterHeaders = false; run = []; continue }
            if inBase64 && !afterHeaders { if line.isEmpty { afterHeaders = true }; continue }
            if inBase64 && afterHeaders {
                if line.hasPrefix("--") || line.isEmpty {
                    if run.dropLast().contains(where: { $0.count != 76 }) || (run.last?.count ?? 0) > 76 { base64OK = false }
                    inBase64 = false
                } else { run.append(line) }
            }
        }
        expect(base64OK, "rich mail builder \(name): base64 lines are exactly 76 characters")
        // Round trip.
        let parsed = MIMEParser.extract(MIMEParser.parse(raw))
        expect(parsed.text.replacingOccurrences(of: "\r\n", with: "\n").hasPrefix(String(mail.text.prefix(40))), "rich mail builder \(name): text/plain round trip")
        if let html = mail.html {
            expect(parsed.html == html, "rich mail builder \(name): text/html round trip")
        } else {
            expect(parsed.html == nil, "rich mail builder \(name): no html part")
        }
        expect(parsed.attachments.map(\.name) == mail.files.map(\.filename), "rich mail builder \(name): attachment names decoded")
        expect(parsed.files.map(\.bytes) == mail.files.map(\.byteCount), "rich mail builder \(name): attachment sizes")
        expect(Set(parsed.inline.compactMap(\.contentId)) == Set(mail.html == nil ? [] : mail.related.compactMap(\.contentId)),
               "rich mail builder \(name): inline images keep their Content-IDs")
        let top = MIMEParser.parse(raw).contentType.value
        let want = !mail.files.isEmpty ? "multipart/mixed" : mail.html != nil ? "multipart/alternative" : "text/plain"
        expect(top == want, "rich mail builder \(name): \(want) at the top")
    }

    // MARK: Encodings

    static func encodings() {
        // base64, streamed (data and file sources) vs one shot.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yc-b64-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for count in [0, 1, 2, 3, 56, 57, 58, 57 * 1024, 57 * 1024 + 1, 1 << 20] {
            let data = bytes(count, seed: UInt32(count + 3))
            let file = dir.appendingPathComponent("\(count).bin")
            try? data.write(to: file)
            var outs: [Data] = []
            for source in [MIMEAttachment.Source.data(data), .file(file)] {
                let mail = RichOutgoingMail(headers: envelope(), text: "x", html: nil,
                                            files: [MIMEAttachment(filename: "f.bin", mimeType: "application/octet-stream", contentId: nil, source: source)])
                guard let raw = try? MIMEBuilder.buildRichData(mail, boundary: counter()) else { continue }
                let text = String(decoding: raw, as: UTF8.self)
                guard let start = text.range(of: "Content-Transfer-Encoding: base64\r\n\r\n"), let end = text.range(of: "\r\n--yc-golden-1--") else { continue }
                outs.append(Data(text[start.upperBound..<end.lowerBound].utf8))
                let part = MIMEParser.parse(raw).parts.last
                expect(part?.body == data, "rich mail encoding base64 \(count) bytes: decodes back")
            }
            let oneShot = MIMEBuilder.base64Lines(data)
            expect(outs.count == 2 && outs.allSatisfy { $0 == oneShot }, "rich mail encoding base64 \(count) bytes: streamed = one shot")
        }
        // Filenames: RFC 2231 (filename*) + RFC 2047 (name=) round trip through ParamHeader.
        let long = String(repeating: "Pickle jar label proofs ", count: 13).prefix(300) + ".pdf"
        let names: [(String, String)] = [
            ("Launch plan.pdf", "Launch plan.pdf"),
            ("Caf\u{00E9} Nowhere menu.jpg", "Caf\u{00E9} Nowhere menu.jpg"),
            ("\u{0645}\u{0644}\u{0641} \u{0627}\u{0644}\u{062E}\u{0637}\u{0629}.pdf", "\u{0645}\u{0644}\u{0641} \u{0627}\u{0644}\u{062E}\u{0637}\u{0629}.pdf"),
            ("Σχέδιο εκτόξευσης.pdf", "Σχέδιο εκτόξευσης.pdf"),
            ("План запуска.docx", "План запуска.docx"),
            ("発売計画 第2版.pdf", "発売計画 第2版.pdf"),
            ("发布计划.xlsx", "发布计划.xlsx"),
            ("תוכנית ההשקה.pdf", "תוכנית ההשקה.pdf"),
            (String(long), String(String(long).prefix(200))),
            ("the \"final\" plan.txt", "the \"final\" plan.txt"),
            ("budget; draft.xlsx", "budget; draft.xlsx"),
            ("\u{1F952} pickles.png", "\u{1F952} pickles.png"),
            // The parser keeps only the last path component (a "/" or "\\" in a name never reaches a path).
            ("evil\r\nContent-Type: text/html.txt", "html.txt"),
            ("back\\slash.txt", "slash.txt"),
        ]
        for (given, expected) in names {
            let mail = RichOutgoingMail(headers: envelope(), text: "x", html: nil,
                                        files: [MIMEAttachment(filename: given, mimeType: "text/plain", contentId: nil, source: .data(Data("hi".utf8)))])
            guard let raw = try? MIMEBuilder.buildRichData(mail, boundary: counter()) else { expect(false, "rich mail encoding \(given.prefix(20)): builds"); continue }
            let lines = String(decoding: raw, as: UTF8.self).components(separatedBy: "\r\n")
            let part = MIMEParser.parse(raw).parts.last
            expect(part?.filename == expected, "rich mail encoding filename \(expected.prefix(24)): round trip (got \(part?.filename?.prefix(24) ?? "nil"))")
            let name = part.map { EncodedWord.decode($0.contentType.params["name"] ?? "") }
            expect(name == MIMEBuilder.cleanFilename(given), "rich mail encoding filename \(expected.prefix(24)): name= (RFC 2047) round trip")
            expect(lines.allSatisfy { $0.utf8.count <= 78 }, "rich mail encoding filename \(expected.prefix(24)): header lines ≤ 78")
            expect(!lines.contains { $0.hasPrefix("Content-Type: text/html") }, "rich mail encoding filename \(expected.prefix(24)): no header injection")
        }
        expect(MIMEBuilder.cleanMimeType("application/pdf\r\nX-Evil: 1") == "application/octet-stream" && MIMEBuilder.cleanMimeType("IMAGE/PNG") == "image/png",
               "rich mail encoding: MIME types are cleaned")
        expect(MIMEBuilder.cleanContentId("<a b>\r\n@x") == "ab@x", "rich mail encoding: Content-IDs are cleaned")
    }

    // MARK: Size

    static func sizes() {
        var seed: UInt32 = 41
        func next(_ n: Int) -> Int {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Int(seed % UInt32(max(1, n)))
        }
        let words = ["pickle", "Caf\u{00E9}", "\u{0627}\u{0644}\u{062E}\u{0637}\u{0629}", "σχέδιο", "план", "計画", "תוכנית", "lake house", "=", ".", "Suite 404", "\u{1F952}", "\n", "  \n", "tour"]
        var under = 0
        for k in 0..<20 {
            var text = ""
            for _ in 0..<next(900) { text += words[next(words.count)] + (next(4) == 0 ? "\n" : " ") }
            let html: String? = next(3) == 0 ? nil : "<div>" + MailHTMLWriter.escape(text).replacingOccurrences(of: "\n", with: "<br>") + "</div>"
            var files: [MIMEAttachment] = []
            for f in 0..<next(4) {
                let name = f % 2 == 0 ? "file \(k)-\(f) \u{00E9}t\u{00E9}.bin" : String(repeating: "long name ", count: next(20) + 1) + ".pdf"
                files.append(MIMEAttachment(filename: name, mimeType: "application/octet-stream", contentId: nil, source: .data(bytes(next(200_000), seed: UInt32(k * 10 + f)))))
            }
            var related: [MIMEAttachment] = []
            if html != nil, next(2) == 0 { related.append(MIMEAttachment(filename: "inline.png", mimeType: "image/png", contentId: "i\(k)@yayascalendar.local", source: .data(bytes(next(80_000), seed: UInt32(k))))) }
            let mail = RichOutgoingMail(headers: envelope(), text: text, html: html, related: related, files: files)
            guard let built = try? MIMEBuilder.buildRichData(mail).count else { continue }
            let all = files + related
            let estimate = MIMEBuilder.estimatedSize(text: MailSize.qpWeight(text), html: MailSize.qpWeight(html ?? ""), attachments: all.map(\.byteCount),
                                                     names: all.reduce(0) { $0 + $1.filename.utf8.count },
                                                     headers: "Priya Starling <priya@starling.example>Milo Brightwater <milo@brightwater.example>Q4 pickle launch: the plan".utf8.count)
            if estimate < built { under += 1; print("    size mix \(k): estimate \(estimate) < built \(built)") }
        }
        expect(under == 0, "rich mail size: the estimate never under-counts (20 random mixes)")
        expect(MailSize.fits(25_000_000) && !MailSize.fits(25_000_001), "rich mail size: 25,000,000 bytes allowed, one more refused")
        expect(MailSize.megabytes(27_400_000) == "27.4 MB" && MailSize.megabytes(25_000_001) == "25.1 MB" && MailSize.megabytes(0) == "0.0 MB",
               "rich mail size: sizes read in decimal MB, rounded up")
        expect(MailSize.tooLargeMessage(27_400_000) == "This is 27.4 MB with attachments. Gmail takes up to 25 MB.", "rich mail size: the refusal text")
        expect(MailSize.base64(0) == 0 && MailSize.base64(1) == 78 && MailSize.base64(57) == 78 && MailSize.base64(58) == 156, "rich mail size: base64 line math")
    }

    // MARK: Quoted originals

    static func quoteComposer() {
        let m = original()
        let reply = MailQuoteComposer.compose(m, kind: .reply, style: .bar)
        expect(reply.html.hasPrefix("<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On ")
               && reply.html.contains("Priya Starling &lt;priya@starling.example&gt; wrote:<br></div><blockquote class=\"gmail_quote\""),
               "quote: reply = Gmail's gmail_quote structure")
        expect(!reply.html.contains("<style") && !reply.html.contains(" id=") && !reply.html.contains("yc-"),
               "quote: <style>, ids and yc- markers are gone")
        expect(reply.html.contains("class=\"intro\""), "quote: the sender's other classes stay")
        expect(reply.html.contains("src=\"cid:Logo@Starling.example\"") && reply.images.map(\.contentId) == ["Logo@Starling.example"]
               && reply.images.first?.partId == "1.2", "quote: the drawn inline image keeps its original Content-ID")
        expect(reply.text.contains("wrote:\n> Hi Avery,\n>\n> The labels look great.\n"), "quote: text/plain behind \"> \"")
        let header = MailQuoteComposer.compose(m, kind: .reply, style: .header)
        expect(header.html.hasPrefix("<hr style=\"display:inline-block;width:98%\"><div id=\"divRplyFwdMsg\" dir=\"ltr\"><b>From:</b> Priya Starling &lt;priya@starling.example&gt;<br><b>Sent:</b>")
               && !header.html.contains("blockquote"), "quote: Outlook header style")
        expect(header.text.hasPrefix("________________________________\nFrom: Priya Starling <priya@starling.example>\nSent: "), "quote: Outlook header text")
        let forward = MailQuoteComposer.compose(m, kind: .forward, style: .bar)
        expect(forward.html.hasPrefix("<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">---------- Forwarded message ---------<br>From: Priya Starling &lt;priya@starling.example&gt;<br>Date: ")
               && forward.html.contains("Subject: Q4 pickle launch plan<br>To: Avery Moonfield &lt;avery@orbitalpickle.example&gt;<br></div><br><br>"),
               "quote: forward header, Gmail's shape")
        expect(forward.text.contains("---------- Forwarded message ---------\nFrom: Priya Starling <priya@starling.example>\n") && forward.text.hasSuffix("See you at Suite 404.\n"),
               "quote: forward text")
        // Marked by our own reader as a quote (collapses), forwards never.
        expect(MailQuote.mark("<div>Thanks!</div><br>" + reply.html).collapsed, "quote: our reader collapses the reply's quote")
        let plainOnly = CachedMessage(id: "p", from: "Theo Quill", fromEmail: "theo@quill.example", to: [], cc: [], date: fixedDate, subject: "s",
                                      html: nil, text: "a < b & c", hasRemoteImages: false, attachments: [], flowed: false, delsp: false)
        let escaped = MailQuoteComposer.compose(plainOnly, kind: .reply, style: .bar)
        expect(escaped.html.contains("a &lt; b &amp; c") && escaped.images.isEmpty, "quote: a plain-text original is escaped")
        expect(MailQuoteComposer.replaceImage("<p>x<img src=\"cid:Logo@Starling.example\" alt=\"Starling logo\">y</p>", cid: "logo@starling.example")
               == "<p>xStarling logoy</p>", "quote: an image that can't be attached becomes its alt text")
        let big = String(repeating: "line of the plan\n", count: 80_000)
        expect(MailQuoteComposer.quoted(big).utf8.count <= MailQuoteComposer.maxPlainQuote + 8, "quote: the > text stops at 1 MB")
    }

    // MARK: Engine fixtures

    struct Setup {
        let m: MailHarness
        let rich: RichGmailTransport
        let orb: AccountRecord
        let token: String
        let cmt: AccountRecord
        let files: URL
    }

    static func setup(_ name: String) async -> Setup {
        let m = MailHarness(name)
        let rich = RichGmailTransport(inner: m.h.env.transport)
        m.h.env.transport = rich
        let (orb, token) = m.account("avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let (cmt, _) = m.account("avery@quietcomets.example", tag: "CMT", sort: 1)
        let html = "<html><head><style>p { color: #c00 }</style></head><body><div id=\"main\" class=\"yc-quote intro\">Hi Avery,</div>"
            + "<p id=\"p2\">The labels look great. <img src=\"cid:Logo@Starling.example\" alt=\"Starling logo\"></p><p>See you at Suite 404.</p></body></html>"
        let payload = RichMailAttachmentTests.payload(html: html, inline: [.init(partId: "0.1", cid: "Logo@Starling.example", size: png.count,
                                                                                 attachmentId: "ANGlogo", data: nil)],
                                                      files: [.init(partId: "2", name: "Launch plan.pdf", mime: "application/pdf", size: pdf.count, attachmentId: "ANGplan")])
        m.gmail.add(token: token, thread: "plan", id: "q1", from: "Priya Starling <priya@starling.example>", subject: "Q4 pickle launch plan",
                    date: m.clock.now.addingTimeInterval(-600), messageIdHeader: "<q1@starling.example>", payload: payload)
        rich.serve("q1", "ANGlogo", png)
        rich.serve("q1", "ANGplan", pdf)
        _ = await m.syncMail(orb.id)
        let files = m.h.dir.appendingPathComponent("composer-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try? pdf.write(to: files.appendingPathComponent("Launch plan.pdf"))
        try? sheet.write(to: files.appendingPathComponent("Budget Q4.xlsx"))
        try? png.write(to: files.appendingPathComponent("label proof.png"))
        return Setup(m: m, rich: rich, orb: orb, token: token, cmt: cmt, files: files)
    }

    static func attachment(_ s: Setup, _ name: String, _ mime: String, contentId: String? = nil) -> MailDraftAttachment {
        let url = s.files.appendingPathComponent(name)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        return MailDraftAttachment(filename: name, mimeType: mime, file: url, bytes: size, contentId: contentId)
    }

    static func richDraft(_ s: Setup, to: [String] = ["avery@quietcomets.example"]) -> MailDraft {
        var d = MailDraft(from: s.orb.id, to: to, subject: "Q4 pickle launch: the plan", body: text, signatureIncluded: true)
        d.html = html
        d.attachments = [attachment(s, "label proof.png", "image/png", contentId: "img-1@yayascalendar.local"),
                         attachment(s, "Launch plan.pdf", "application/pdf"),
                         attachment(s, "Budget Q4.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")]
        return d
    }

    static func outbox(_ s: Setup) -> URL { s.m.engine.mailActions.outbox?.directory ?? s.m.h.dir }

    static func outboxFiles(_ s: Setup) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: outbox(s).path).filter { $0.hasSuffix(".eml") }) ?? []
    }

    static func posix(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// The decoded text/html and text/plain of a sent message, and its MIME tree as "type[children]".
    static func tree(_ part: MIMEPart) -> String {
        part.parts.isEmpty ? part.contentType.value : part.contentType.value + "[" + part.parts.map(tree).joined(separator: ",") + "]"
    }

    // MARK: A rich send

    static func richSend() async {
        let s = await setup("rich-send")
        let actions = s.m.engine.mailActions
        try? s.m.engine.mailStore.save(account: s.orb.id, MailAccountPrefs(primaryOnly: false, signature: "Avery Moonfield\nOrbital Pickle Co."))
        s.m.sleeper.gate()
        guard let token = try? await actions.send(richDraft(s)) else { expect(false, "rich send 1: queued"); s.m.sleeper.release(); return }
        let row = try? ActionRepo(db: s.m.db).get(token.id)
        let name = row?.payload["rawFile"] ?? ""
        let file = outbox(s).appendingPathComponent(name)
        expect(OutboxStore.isValidName(name) && row?.payload["raw"] == nil && row?.payload["rawSHA256"]?.count == 64
               && Int(row?.payload["rawBytes"] ?? "") == ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue,
               "rich send 1: the raw MIME is an outbox file (name, size, SHA-256 in the row)")
        expect(posix(file) == 0o600 && posix(outbox(s)) == 0o700 && outbox(s).path.hasPrefix(s.m.h.dir.path),
               "rich send 1: the file is 0600 in a 0700 folder under the data root")
        _ = await eventually(2) { s.m.sleeper.waiting >= 1 }
        s.m.sleeper.release()
        await actions.drain()
        let raw = s.m.gmail.sentRaw(token: s.token).last ?? Data()
        let top = MIMEParser.parse(raw)
        expect(tree(top) == "multipart/mixed[multipart/alternative[text/plain,multipart/related[text/html,image/png]],application/pdf,"
               + "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet]", "rich send 1: the MIME tree (\(tree(top)))")
        let parsed = MIMEParser.extract(top)
        expect(top.header("From")?.contains("avery@orbitalpickle.example") == true && top.header("To") == "avery@quietcomets.example"
               && MIMEBuilder.isMessageID(top.header("Message-ID") ?? ""), "rich send 1: From, To and Message-ID as today")
        expect(parsed.attachments.map(\.name) == ["Launch plan.pdf", "Budget Q4.xlsx"] && parsed.files.map(\.bytes) == [pdf.count, sheet.count]
               && parsed.inline.first?.contentId == "img-1@yayascalendar.local", "rich send 1: files and the inline image arrive")
        let sigs = parsed.text.components(separatedBy: "Orbital Pickle Co.").count - 1
        expect(sigs == 1 && parsed.html?.components(separatedBy: "class=\"gmail_signature\"").count == 2, "rich send 1: exactly one signature")
        expect(!(parsed.html ?? "").contains("yc-"), "rich send 1: no yc- classes or ids in the outgoing HTML")
        expect(actions.sendStatus(token) == .sent && !FileManager.default.fileExists(atPath: file.path), "rich send 1: sent, and the outbox file is gone")
        expect(s.rich.uploads.isEmpty, "rich send 1: under 1 MB → JSON raw")
        // A small rich send without files stays in the row (as plain sends do).
        var small = MailDraft(from: s.orb.id, to: ["avery@quietcomets.example"], subject: "Short", body: "Teal it is.", signatureIncluded: true)
        small.html = "<div>Teal it is.</div>"
        if let t = try? await actions.send(small) {
            let p = (try? ActionRepo(db: s.m.db).get(t.id))?.payload
            expect(p?["raw"] != nil && p?["rawFile"] == nil, "rich send 1: a small rich send without files keeps payload raw")
            await actions.drain()
            let alt = MIMEParser.parse(s.m.gmail.sentRaw(token: s.token).last ?? Data())
            expect(tree(alt) == "multipart/alternative[text/plain,text/html]", "rich send 1: html only → multipart/alternative")
        } else { expect(false, "rich send 1: small rich send") }
        expect(outboxFiles(s).isEmpty, "rich send 1: nothing left in the outbox")
    }

    // MARK: D-023 with attachments

    static func approvalsWithAttachments() async {
        let s = await setup("rich-send-approval")
        let actions = s.m.engine.mailActions
        let before = (try? ActionRepo(db: s.m.db).count(state: .pending)) ?? -1
        do {
            _ = try await actions.send(richDraft(s, to: ["juniper@vale.example"]))
            expect(false, "D-023 with attachments: an unapproved outside address is refused")
        } catch {
            expect((error as? ServiceError)?.description == MailActionService.safeSendMessage && outboxFiles(s).isEmpty
                   && (try? ActionRepo(db: s.m.db).count(state: .pending)) == before,
                   "D-023 with attachments: refused before anything is built (no row, no outbox file)")
        }
        var approved = richDraft(s, to: ["juniper@vale.example"])
        approved.approvedOutside = ["Juniper@Vale.example"]
        s.m.sleeper.gate()
        guard let token = try? await actions.send(approved) else { expect(false, "D-023 with attachments: approved send queued"); s.m.sleeper.release(); return }
        let row = try? ActionRepo(db: s.m.db).get(token.id)
        expect(row?.payload["ask"] == "1" && row?.payload["approved"] == "juniper@vale.example" && row?.payload["rawFile"] != nil,
               "D-023 with attachments: the queued send stores ask and the approval next to its outbox file")
        // Approval gone from the row (a tampered or older row): the delivery-time guard holds it back.
        var tampered = row?.payload ?? [:]
        tampered["approved"] = nil
        try? ActionRepo(db: s.m.db).setPayload(token.id, tampered)
        _ = await eventually(2) { s.m.sleeper.waiting >= 1 }
        s.m.sleeper.release()
        await actions.drain()
        expect(actions.sendStatus(token) == .failed(MailActionService.safeSendHeldMessage) && s.m.gmail.sentCount(token: s.token) == 0,
               "D-023 with attachments: the data-layer guard refuses at delivery, nothing sent")
        expect(outboxFiles(s).count == 1, "D-023 with attachments: the held send's file is kept (failed sends stay 7 days)")
        // Approved and untouched: it goes, with its files.
        guard let ok = try? await actions.send(approved) else { expect(false, "D-023 with attachments: second send"); return }
        await actions.drain()
        let parsed = MIMEParser.extract(MIMEParser.parse(s.m.gmail.sentRaw(token: s.token).last ?? Data()))
        expect(actions.sendStatus(ok) == .sent && parsed.attachments.count == 2, "D-023 with attachments: an approved send leaves with its files")
        // Switch off when Send was pressed: delivery follows the stored answer.
        s.m.safeSend.value = false
        guard let free = try? await actions.send(richDraft(s, to: ["kofi@ember.example"])) else { expect(false, "D-023 off: queued"); return }
        s.m.safeSend.value = true
        await actions.drain()
        expect(actions.sendStatus(free) == .sent && (try? ActionRepo(db: s.m.db).get(free.id))?.payload["ask"] == "0",
               "D-023 with attachments: a send queued with the switch off still leaves after it is turned on")
    }

    // MARK: Replies and forwards quote the original

    static func replyWithQuote() async {
        let s = await setup("rich-send-quote")
        let actions = s.m.engine.mailActions
        let r = s.m.r(s.orb.id, "plan")
        _ = try? await s.m.engine.mailStore.messages(threadR: r)   // the reader opened it: cached
        func send(_ kind: MailQuoteRequest.Kind, _ style: MailQuoteRequest.Style, subject: String) async -> (MIMEParser.Extracted, MIMEPart)? {
            var d = MailDraft(from: s.orb.id, to: ["avery@quietcomets.example"], subject: subject, body: "Teal it is.\n", replyTo: r, signatureIncluded: true)
            d.html = "<div dir=\"auto\"><div>Teal it is.</div></div>"
            d.quote = MailQuoteRequest(threadR: r, messageId: "q1", kind: kind, style: style)
            guard (try? await actions.send(d)) != nil else { return nil }
            await actions.drain()
            let top = MIMEParser.parse(s.m.gmail.sentRaw(token: s.token).last ?? Data())
            var parsed = MIMEParser.extract(top)
            parsed.text = parsed.text.replacingOccurrences(of: "\r\n", with: "\n")
            return (parsed, top)
        }
        guard let (bar, barTop) = await send(.reply, .bar, subject: "Re: Q4 pickle launch plan") else { expect(false, "quote reply: sent"); return }
        let html = bar.html ?? ""
        expect(html.hasPrefix("<div dir=\"auto\"><div>Teal it is.</div></div><br><div class=\"gmail_quote\">")
               && html.contains("<blockquote class=\"gmail_quote\"") && html.contains("The labels look great."),
               "quote reply: the original's sanitized HTML in blockquote.gmail_quote")
        expect(!html.contains("<style") && !html.contains(" id=") && !html.contains("yc-"), "quote reply: <style>, ids and yc- markers removed")
        expect(bar.text.contains("Teal it is.\n\nOn ") && bar.text.contains("wrote:\n> Hi Avery,\n"), "quote reply: text/plain has the > lines")
        expect(tree(barTop) == "multipart/alternative[text/plain,multipart/related[text/html,image/png]]"
               && bar.inline.first?.contentId == "Logo@Starling.example" && html.contains("src=\"cid:Logo@Starling.example\""),
               "quote reply: the original's inline image re-attached with its original Content-ID")
        expect(barTop.header("In-Reply-To") == "<q1@starling.example>", "quote reply: threading as today")
        guard let (header, _) = await send(.reply, .header, subject: "Re: Q4 pickle launch plan") else { expect(false, "quote header: sent"); return }
        expect((header.html ?? "").contains("<div id=\"divRplyFwdMsg\" dir=\"ltr\"><b>From:</b> Priya Starling") && !(header.html ?? "").contains("blockquote")
               && header.text.contains("________________________________\nFrom: Priya Starling <priya@starling.example>"), "quote reply: the Outlook header variant")
        // A forward of a thread whose body isn't cached yet: fetched first.
        if let row = try? MailRepo(db: s.m.db).thread(r: r) {
            for id in row.messageIds { try? MailRepo(db: s.m.db).deleteCache(accountId: s.orb.id, messageId: id) }
        }
        let fulls = s.m.gmail.count("format=full")
        guard let (forward, forwardTop) = await send(.forward, .bar, subject: "Fwd: Q4 pickle launch plan") else { expect(false, "quote forward: sent"); return }
        expect((forward.html ?? "").contains("---------- Forwarded message ---------<br>From: Priya Starling &lt;priya@starling.example&gt;")
               && forward.text.contains("---------- Forwarded message ---------\nFrom: Priya Starling"), "quote forward: Gmail's forward header")
        expect(s.m.gmail.count("format=full") == fulls + 1, "quote forward: a missing original is fetched before composing")
        expect(MIMEParser.extract(forwardTop).inline.first?.contentId == "Logo@Starling.example", "quote forward: the original's images go along")
    }

    // MARK: The upload path over 1 MB

    static func uploadPath() async {
        let s = await setup("rich-send-upload")
        let actions = s.m.engine.mailActions
        let big = s.files.appendingPathComponent("Moodboard.zip")
        try? bytes(1_200_000, seed: 77).write(to: big)
        let r = s.m.r(s.orb.id, "plan")
        var d = MailDraft(from: s.orb.id, to: ["avery@quietcomets.example"], subject: "Re: Q4 pickle launch plan", body: "Moodboard attached.",
                          replyTo: r, signatureIncluded: true)
        d.attachments = [attachment(s, "Moodboard.zip", "application/zip")]
        guard let token = try? await actions.send(d) else { expect(false, "upload: queued"); return }
        await actions.drain()
        let up = s.rich.uploads.first
        expect(actions.sendStatus(token) == .sent && s.rich.uploads.count == 1 && up?.metadata == ["threadId": "plan"] && up?.long == true
               && (up?.rawBytes ?? 0) > 1 << 20 && s.rich.jsonSendCount == 0,
               "upload: over 1 MB → uploadType=multipart with the threadId JSON part, on the long session")
        let parsed = MIMEParser.extract(MIMEParser.parse(s.m.gmail.sentRaw(token: s.token).last ?? Data()))
        expect(parsed.attachments.first?.name == "Moodboard.zip" && parsed.files.first?.bytes == 1_200_000, "upload: the file arrives whole")
        expect(s.m.gmail.requests.contains { $0.url.path == "/gmail/v1/users/me/messages/send" }, "upload: Gmail saw messages.send (rewritten by the fake)")
        var small = MailDraft(from: s.orb.id, to: ["avery@quietcomets.example"], subject: "Small", body: "Proofs attached.", signatureIncluded: true)
        small.attachments = [attachment(s, "Launch plan.pdf", "application/pdf")]
        guard let t2 = try? await actions.send(small) else { expect(false, "upload: small send"); return }
        await actions.drain()
        expect(actions.sendStatus(t2) == .sent && s.rich.uploads.count == 1 && s.rich.jsonSendCount == 1, "upload: under 1 MB → JSON raw, as today")
        expect(GmailClient.uploadSendURL.hasPrefix("https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart"),
               "upload: same host as every other Gmail call")
    }

    // MARK: Undo within 5 s

    static func undoDeletesFile() async {
        let s = await setup("rich-send-undo")
        let actions = s.m.engine.mailActions
        s.m.sleeper.gate()
        guard let token = try? await actions.send(richDraft(s)) else { expect(false, "undo: queued"); s.m.sleeper.release(); return }
        expect(outboxFiles(s).count == 1, "undo: queued with its outbox file")
        do { try await actions.cancelSend(token) } catch { expect(false, "undo: cancel \(error)") }
        expect(outboxFiles(s).isEmpty, "undo: the outbox file is deleted at once")
        s.m.sleeper.release()
        await actions.drain()
        expect(s.m.gmail.count("/messages/send") == 0 && s.rich.uploads.isEmpty && actions.sendStatus(token) == .cancelled,
               "undo: no request reaches Gmail")
    }

    // MARK: A timeout after Gmail accepted → Sent searched, sent once

    static func retryOnce() async {
        let s = await setup("rich-send-retry")
        let actions = s.m.engine.mailActions
        let big = s.files.appendingPathComponent("Moodboard.zip")
        try? bytes(1_100_000, seed: 78).write(to: big)
        var d = richDraft(s)
        d.attachments.append(attachment(s, "Moodboard.zip", "application/zip"))
        s.m.gmail.inject("/messages/send", timeout: true, afterWork: true)
        guard let token = try? await actions.send(d) else { expect(false, "retry: queued"); return }
        await actions.drain()
        expect(s.m.gmail.sentCount(token: s.token) == 1 && s.m.gmail.count("rfc822msgid") == 1 && actions.sendStatus(token) == .sent,
               "retry: timed out after reaching Gmail → round 2 searches Sent, finds it, exactly one send")
        expect(s.rich.uploads.count == 1 && outboxFiles(s).isEmpty, "retry: one upload, and the outbox file is deleted")
    }

    // MARK: Restart recovery

    static func restartRecovery() async {
        let s = await setup("rich-send-restart")
        let engine = s.m.engine
        let stuck = TestSleeper(clock: s.m.clock)
        stuck.gate()   // the "previous run": it queues and never gets to deliver
        func service(_ sleep: @escaping @Sendable (TimeInterval) async -> Void) -> MailActionService {
            let svc = MailActionService(db: s.m.db, now: { s.m.clock.now }, sleep: sleep)
            svc.outbox = engine.mailActions.outbox
            svc.client = { id in await engine.gmailClient(for: id) }
            svc.quoteSource = engine.mailActions.quoteSource
            svc.quoteImage = engine.mailActions.quoteImage
            svc.safeSend = { true }
            return svc
        }
        let before = service(stuck.closure)
        guard let a = try? await before.send(richDraft(s)) else { expect(false, "restart: queued"); return }
        let after = service(s.m.sleeper.closure)
        after.recover()
        await after.drain()
        expect(after.sendStatus(a) == .sent && s.m.gmail.sentCount(token: s.token) == 1 && outboxFiles(s).isEmpty,
               "restart: a new engine on the same data recovers the send and delivers it from its file")
        // A missing file → failed, "couldn't be read back".
        guard let b = try? await before.send(richDraft(s)) else { expect(false, "restart: second queued"); return }
        for name in outboxFiles(s) { try? FileManager.default.removeItem(at: outbox(s).appendingPathComponent(name)) }
        after.recover()
        await after.drain()
        expect(after.sendStatus(b) == .failed("That message couldn\u{2019}t be read back.") && s.m.gmail.sentCount(token: s.token) == 1,
               "restart: a missing outbox file → failed, nothing sent")
        // A checksum mismatch → failed; the file stays (failed sends are kept 7 days).
        guard let c = try? await before.send(richDraft(s)), let name = (try? ActionRepo(db: s.m.db).get(c.id))?.payload["rawFile"] else {
            expect(false, "restart: third queued"); return
        }
        let file = outbox(s).appendingPathComponent(name)
        if var data = try? Data(contentsOf: file) { data[data.count / 2] ^= 0xFF; try? data.write(to: file) }
        // A stray file nobody points at.
        try? Data("stray".utf8).write(to: outbox(s).appendingPathComponent(OutboxStore.fileName(actionId: UUID().uuidString)))
        try? Data("odd".utf8).write(to: outbox(s).appendingPathComponent("notes.txt"))
        after.recover()
        await after.drain()
        expect(after.sendStatus(c) == .failed("That message couldn\u{2019}t be read back.") && s.m.gmail.sentCount(token: s.token) == 1,
               "restart: a checksum mismatch → failed, nothing sent")
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: outbox(s).path)) ?? [])
        expect(left == [name], "restart: strays swept at launch, the failed send's file kept (\(left.count) left)")
        // Seven days on: the failed row is purged, and its file goes with it.
        s.m.clock.advance(8 * 86_400)
        after.recover()
        expect(outboxFiles(s).isEmpty, "restart: a failed send's file goes with its row after 7 days")
        // A name that isn't ours is never read as a path.
        expect(OutboxStore(directory: outbox(s)).url("../store.sqlite") == nil && !OutboxStore.isValidName("a.eml")
               && OutboxStore.isValidName(OutboxStore.fileName(actionId: UUID().uuidString)), "restart: rawFile is a checked file name, never a path")
    }

    // MARK: 25 MB

    static func overLimit() async {
        let s = await setup("rich-send-limit")
        let actions = s.m.engine.mailActions
        let huge = s.files.appendingPathComponent("Tour footage.mov")
        try? bytes(18_800_000, seed: 79).write(to: huge)
        var d = MailDraft(from: s.orb.id, to: ["avery@quietcomets.example"], subject: "Footage", body: "All of it.", signatureIncluded: true)
        d.attachments = [attachment(s, "Tour footage.mov", "video/quicktime")]
        let rows = (try? ActionRepo(db: s.m.db).count(state: .pending)) ?? -1
        do {
            _ = try await actions.send(d)
            expect(false, "25 MB: refused")
        } catch {
            let text = (error as? ServiceError)?.description ?? ""
            expect(text.hasPrefix("This is 25.") && text.hasSuffix("MB with attachments. Gmail takes up to 25 MB."), "25 MB: a friendly refusal (\(text))")
        }
        expect((try? ActionRepo(db: s.m.db).count(state: .pending)) == rows && outboxFiles(s).isEmpty && s.m.gmail.count("/messages/send") == 0,
               "25 MB: refused before queueing (no row, no file, no request)")
        // A staged file that vanished: refused with the file's name.
        try? FileManager.default.removeItem(at: huge)
        do {
            _ = try await actions.send(d)
            expect(false, "unreadable attachment: refused")
        } catch {
            expect((error as? ServiceError)?.description == "I couldn\u{2019}t read \u{201C}Tour footage.mov\u{201D}. Remove it or attach it again."
                   && outboxFiles(s).isEmpty, "unreadable attachment: refused with its name, nothing queued")
        }
    }

    // MARK: Correspondents

    static func correspondents() async {
        let m = MailHarness("rich-send-correspondents")
        // Recorded only while "Images from people you've written to" is on (RichMailReviewTests covers off).
        let setting = Locked(true)
        m.h.env.imagesFromCorrespondents = { setting.value }
        let (orb, token) = m.account("avery@orbitalpickle.example", tag: "ORB", sort: 0)
        _ = m.account("avery@quietcomets.example", tag: "CMT", sort: 1)
        m.gmail.add(token: token, thread: "corr", id: "c1", from: "Kofi Ember <kofi@ember.example>", subject: "Set list",
                    date: m.clock.now.addingTimeInterval(-900))
        m.gmail.add(token: token, thread: "corr", id: "c2", from: "Avery Moonfield <avery@orbitalpickle.example>", subject: "Re: Set list",
                    date: m.clock.now.addingTimeInterval(-600), labels: ["SENT"])
        m.gmail.add(token: token, thread: "corr", id: "c3", from: "Kofi Ember <kofi@ember.example>", subject: "Re: Set list",
                    date: m.clock.now.addingTimeInterval(-300))
        m.gmail.add(token: token, thread: "news", id: "n1", from: "The Quiet Comets <news@quietcomets.example>", subject: "Tour dates",
                    date: m.clock.now.addingTimeInterval(-200))
        _ = await m.syncMail(orb.id)
        let repo = CorrespondentRepo(db: m.db)
        expect((try? repo.contains("kofi@ember.example", accountId: orb.id)) == true && (try? repo.contains("news@quietcomets.example")) == false,
               "correspondents: a thread with a SENT message records its other senders (metadata only)")
        let store = m.engine.mailStore
        setting.value = false
        expect(!store.allowsImages(from: "Kofi Ember <kofi@ember.example>", accountId: orb.id), "correspondents: off, images stay blocked")
        setting.value = true
        expect(store.allowsImages(from: "Kofi Ember <kofi@ember.example>", accountId: orb.id)
               && !store.allowsImages(from: "news@quietcomets.example", accountId: orb.id),
               "correspondents: on → people you've written to load images, others don't")
        let actions = m.engine.mailActions
        guard let t = try? await actions.send(MailDraft(from: orb.id, to: ["avery@quietcomets.example"], cc: ["Ines Marlowe <ines@marlowe.example>"],
                                                        subject: "Rehearsal", body: "Thursday at the lake house.", approvedOutside: ["ines@marlowe.example"],
                                                        signatureIncluded: true)) else { expect(false, "correspondents: send"); return }
        await actions.drain()
        expect(actions.sendStatus(t) == .sent && (try? repo.contains("ines@marlowe.example", accountId: orb.id)) == true,
               "correspondents: sending records the recipients")
        setting.value = false
        expect(!store.allowsImages(from: "ines@marlowe.example", accountId: orb.id), "correspondents: the setting off again → blocked")
    }
}
