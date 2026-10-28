import Foundation

/// MIME corpus (raw RFC 822 and Gmail payloads), encoded-words, charsets, addresses, and the builder
/// round trip with threading headers.
enum MIMETests {
    static var corpusCount = 0

    static func run() {
        corpusCount = 0
        textBodies()
        multiparts()
        headersAndNames()
        malformed()
        gmailPayloads()
        expect(corpusCount >= 25, "MIME corpus has ≥ 25 messages (\(corpusCount))")
        helpers()
        builder()
    }

    /// LF → CRLF (real mail), unless `lf` keeps bare LF line ends.
    static func raw(_ text: String, lf: Bool = false) -> Data {
        Data((lf ? text : text.replacingOccurrences(of: "\n", with: "\r\n")).utf8)
    }

    static func parse(_ data: Data) -> (MIMEPart, MIMEParser.Extracted) {
        corpusCount += 1
        let part = MIMEParser.parse(data)
        return (part, MIMEParser.extract(part))
    }

    /// A legacy code page by its IANA name ("windows-1256", "koi8-r"…).
    static func codePage(_ name: String) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(name as CFString)))
    }

    // MARK: Text bodies, transfer encodings, charsets

    static func textBodies() {
        do {
            let (part, x) = parse(raw("""
                From: Sender <s@example.com>
                To: me@example.com
                Subject: Plain
                Content-Type: text/plain; charset=us-ascii
                Content-Transfer-Encoding: 7bit

                Hello there.
                Second line.
                """))
            expect(x.html == nil && x.text == "Hello there.\r\nSecond line.", "1 plain 7bit body")
            expect(part.header("subject") == "Plain", "1 header lookup is case-insensitive")
        }
        // "Hello, world" in scripts of both directions, as an 8bit UTF-8 body.
        let helloWorld = [("Arabic", "مرحبا بالعالم"), ("Hebrew", "שלום עולם"), ("Syriac", "ܫܠܡܐ ܠܥܠܡܐ"), ("Greek", "Γεια σου κόσμε"),
                          ("Cyrillic", "Привет, мир"), ("Devanagari", "नमस्ते दुनिया"), ("Japanese", "こんにちは世界")]
        for (script, hello) in helloWorld {
            let (_, x) = parse(raw("""
                Subject: 8bit
                Content-Type: text/plain; charset="utf-8"
                Content-Transfer-Encoding: 8bit

                \(hello)
                """))
            expect(x.text == hello, "2 UTF-8 8bit \(script) body")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: text/plain; charset=UTF-8
                Content-Transfer-Encoding: quoted-printable

                Caf=C3=A9 au lait, a long line that wraps with a soft break right here =
                and continues. 1 + 1 =3D 2
                """))
            expect(x.text == "Café au lait, a long line that wraps with a soft break right here and continues. 1 + 1 = 2",
                   "3 quoted-printable UTF-8 with a soft break and =3D")
        }
        do {
            let body = Data("Base64 body ✓ ok".utf8).base64EncodedString()
            let (_, x) = parse(raw("""
                Content-Type: text/plain; charset=utf-8
                Content-Transfer-Encoding: base64

                \(body.prefix(12))
                \(body.dropFirst(12))
                """))
            expect(x.text == "Base64 body ✓ ok", "4 base64 across lines")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: text/plain; charset=iso-8859-1
                Content-Transfer-Encoding: quoted-printable

                R=E9sum=E9 =93quoted=94
                """))
            expect(x.text == "Résumé \u{201C}quoted\u{201D}", "5 ISO-8859-1 QP (0x93/0x94 read as windows-1252)")
        }
        // Each script in its own legacy charset: Greek, Cyrillic, Japanese (both of its mail charsets), Hebrew and Arabic.
        let eightBit: [(String, [UInt8], String)] = [
            ("iso-8859-7", [0xD3, 0xF5, 0xED, 0xDC, 0xED, 0xF4, 0xE7, 0xF3, 0xE7], "Συνάντηση"),
            ("koi8-r", [0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4], "Привет"),
            ("Shift_JIS", [0x89, 0xEF, 0x8B, 0x63, 0x82, 0xCC, 0x8C, 0x8F], "会議の件"),
            ("ISO-2022-JP", [0x1B, 0x24, 0x42, 0x32, 0x71, 0x35, 0x44, 0x24, 0x4E, 0x37, 0x6F, 0x1B, 0x28, 0x42], "会議の件"),
            ("windows-1255", [0xF9, 0xEC, 0xE5, 0xED], "שלום"),
            ("windows-1256", [0xE3, 0xD1, 0xCD, 0xC8, 0xC7], "مرحبا"),
        ]
        for (charset, bytes, expected) in eightBit where !charset.hasPrefix("ISO-2022") {
            expect(expected.data(using: codePage(charset)) == Data(bytes), "6 \(charset) bytes for the fixture")
        }
        for (charset, bytes, expected) in eightBit {
            let (_, x) = parse(raw("""
                Content-Type: text/plain; charset="\(charset)"
                Content-Transfer-Encoding: base64

                \(Data(bytes).base64EncodedString())
                """))
            expect(x.text == expected, "6 \(charset) base64 body (\(x.text))")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: text/html; charset=utf-8

                <html><head><title>T</title><style>p{color:red}</style></head><body><p>Hi <b>you</b></p><ul><li>one</li><li>two</li></ul></body></html>
                """))
            expect(x.html?.contains("<b>you</b>") == true, "7 HTML-only body kept as HTML")
            expect(x.text == "Hi you\n\n\u{2022} one\n\u{2022} two", "7 plain text derived from HTML (\(x.text.debugDescription))")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: text/plain; charset=us-ascii

                Caf\u{00E9} (UTF-8 under an ASCII label)
                """))
            expect(x.text == "Café (UTF-8 under an ASCII label)", "8 us-ascii label with UTF-8 bytes")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: text/plain; charset=x-unknown-charset

                Plain words
                """))
            expect(x.text == "Plain words", "9 unknown charset falls back")
        }
    }

    // MARK: Multipart structures

    static func multiparts() {
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/alternative; boundary="b1"

                preamble is ignored
                --b1
                Content-Type: text/plain; charset=utf-8

                Plain version
                --b1
                Content-Type: text/html; charset=utf-8

                <p>HTML version</p>
                --b1--
                epilogue
                """))
            expect(x.text == "Plain version" && x.html == "<p>HTML version</p>", "10 alternative: plain + HTML")
        }
        do {
            let text = Data("Grüße".utf8).base64EncodedString()
            let (_, x) = parse(raw("""
                Content-Type: multipart/alternative; boundary=alt

                --alt
                Content-Type: text/plain; charset=utf-8
                Content-Transfer-Encoding: base64

                \(text)
                --alt
                Content-Type: text/html; charset=utf-8
                Content-Transfer-Encoding: quoted-printable

                <p style=3D"color:red">Gr=C3=BC=C3=9Fe</p>
                --alt--
                """))
            expect(x.text == "Grüße" && x.html == "<p style=\"color:red\">Grüße</p>", "11 alternative with base64 text and QP HTML")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/mixed; boundary="mix"

                --mix
                Content-Type: multipart/alternative; boundary="alt"

                --alt
                Content-Type: text/plain

                See attached.
                --alt
                Content-Type: text/html

                <p>See attached.</p>
                --alt--
                --mix
                Content-Type: application/pdf; name="report.pdf"
                Content-Disposition: attachment; filename="report.pdf"
                Content-Transfer-Encoding: base64

                \(Data(repeating: 0x25, count: 300).base64EncodedString())
                --mix--
                """))
            expect(x.text == "See attached." && x.html == "<p>See attached.</p>", "12 mixed: body from the alternative")
            expect(x.attachments == [MailMessage.Attachment(name: "report.pdf", bytes: 300)], "12 attachment name + decoded size")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/related; boundary="rel"; type="text/html"

                --rel
                Content-Type: text/html; charset=utf-8

                <p>Logo: <img src="cid:logo@x" alt="Logo"></p>
                --rel
                Content-Type: image/png
                Content-ID: <logo@x>
                Content-Transfer-Encoding: base64

                iVBORw0KGgo=
                --rel--
                """))
            expect(x.html?.contains("cid:logo@x") == true && x.attachments.isEmpty, "13 related: HTML root, inline image not an attachment")
            let clean = HTMLSanitizer.sanitize(x.html ?? "", remote: .block)
            expect(clean.cidImages == 1 && clean.html.contains("[image: Logo]") && !clean.html.contains("cid:"), "13 cid image → placeholder")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/mixed; boundary="m"

                --m
                Content-Type: multipart/alternative; boundary="a"

                --a
                Content-Type: text/plain; charset=utf-8

                Apple style
                --a
                Content-Type: multipart/related; boundary="r"

                --r
                Content-Type: text/html; charset=utf-8

                <div>Apple <img src="cid:i1"></div>
                --r
                Content-Type: image/jpeg; name="photo.jpg"
                Content-ID: <i1>
                Content-Disposition: inline; filename="photo.jpg"

                xyz
                --r--
                --a--
                --m
                Content-Type: text/plain; name="notes.txt"
                Content-Disposition: attachment; filename="notes.txt"

                attached text
                --m--
                """))
            expect(x.text == "Apple style" && x.html?.contains("Apple <img") == true, "14 mixed[alternative[text, related[html, image]]]")
            expect(x.attachments.map(\.name) == ["notes.txt"], "14 only the real attachment is listed")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/mixed; boundary=outer

                --outer
                Content-Type: multipart/mixed; boundary=middle

                --middle
                Content-Type: multipart/mixed; boundary=inner

                --inner
                Content-Type: text/plain

                Part one
                --inner--
                --middle
                Content-Type: text/plain

                Part two
                --middle--
                --outer
                Content-Type: text/plain

                Footer added by the list
                --outer--
                """))
            expect(x.text == "Part one\n\nPart two\n\nFooter added by the list" && x.html == nil, "15 three nested levels, inline text parts joined")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/mixed; boundary=fw

                --fw
                Content-Type: text/plain

                Forwarding this.
                --fw
                Content-Type: message/rfc822

                From: someone@example.com
                Subject: Inner

                Inner body
                --fw--
                """))
            expect(x.text == "Forwarding this." && x.attachments.first?.name == "Forwarded message.eml", "16 message/rfc822 listed as an attachment")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/signed; protocol="application/pgp-signature"; boundary=sig

                --sig
                Content-Type: text/plain

                Signed text
                --sig
                Content-Type: application/pgp-signature; name="signature.asc"

                -----BEGIN PGP SIGNATURE-----
                --sig--
                """))
            expect(x.text == "Signed text" && x.attachments.isEmpty, "17 multipart/signed: signature not listed")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/mixed; boundary=mx

                --mx
                Content-Type: text/html

                <p>First</p>
                --mx
                Content-Type: text/plain

                Second <plain>
                --mx--
                """))
            expect(x.html == "<p>First</p><br><div style=\"white-space: pre-wrap\">Second &lt;plain&gt;</div>", "18 mixed HTML + text → one HTML")
            expect(x.text == "First\n\nSecond <plain>", "18 …and one text")
        }
    }

    // MARK: Headers: encoded-words, addresses, RFC 2231 names

    static func headersAndNames() {
        for subject in ["Συνάντηση αύριο", "Встреча завтра", "明日の会議", "明天的会议", "פגישה מחר", "اجتماع الغد", "ܟܢܘܫܝܐ ܕܫܒܬܐ",
                        "ހަފްތާގެ ބައްދަލުވުން"] {
            let (part, _) = parse(raw("""
                Subject: =?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?=
                Content-Type: text/plain

                x
                """))
            expect(EncodedWord.decode(part.header("Subject") ?? "") == subject, "19 B-encoded subject: \(subject)")
        }
        // Encoded-words in each script's own charset, the way older clients write them.
        let ownCharset: [(String, String)] = [
            ("=?iso-8859-7?B?\(Data([0xD3, 0xF5, 0xED, 0xDC, 0xED, 0xF4, 0xE7, 0xF3, 0xE7]).base64EncodedString())?=", "Συνάντηση"),
            ("=?KOI8-R?Q?=F0=D2=C9=D7=C5=D4?=", "Привет"),
            ("=?ISO-2022-JP?B?\(Data([0x1B, 0x24, 0x42, 0x32, 0x71, 0x35, 0x44, 0x24, 0x4E, 0x37, 0x6F, 0x1B, 0x28, 0x42]).base64EncodedString())?=", "会議の件"),
            ("=?windows-1255?Q?=F9=EC=E5=ED?=", "שלום"),
        ]
        for (word, expected) in ownCharset {
            expect(EncodedWord.decode(word) == expected, "19 encoded-word in its own charset: \(expected) (\(EncodedWord.decode(word)))")
        }
        do {
            let (part, _) = parse(raw("""
                Subject: =?iso-8859-1?q?Caf=E9_cr=E8me?= and =?ISO-8859-1?Q?more?=
                Content-Type: text/plain

                x
                """))
            expect(EncodedWord.decode(part.header("Subject") ?? "") == "Café crème and more", "20 Q-encoded Latin-1 with underscores")
        }
        // Two-byte UTF-8 scripts, cut after the third byte: inside the second character.
        for word in ["שלום", "مرحبا", "ܫܠܡܐ", "Привет"] {
            let bytes = Data(word.utf8)
            let first = bytes.prefix(3).base64EncodedString()
            let second = bytes.dropFirst(3).base64EncodedString()
            let (part, _) = parse(raw("""
                Subject: =?UTF-8?B?\(first)?=
                 =?UTF-8?B?\(second)?= !
                Content-Type: text/plain

                x
                """))
            expect(EncodedWord.decode(part.header("Subject") ?? "") == "\(word) !", "21 a character split across two words, folded: \(word)")
        }
        do {
            let bytes = Data("会議".utf8)   // three bytes a character: the cut lands inside the second
            let (part, _) = parse(raw("""
                Subject: =?UTF-8?B?\(bytes.prefix(4).base64EncodedString())?=
                 =?UTF-8?B?\(bytes.dropFirst(4).base64EncodedString())?=
                Content-Type: text/plain

                x
                """))
            expect(EncodedWord.decode(part.header("Subject") ?? "") == "会議", "21 a CJK character split across two words")
        }
        do {
            let name = "=?UTF-8?B?\(Data("Лунный офис".utf8).base64EncodedString())?="
            let (part, _) = parse(raw("""
                From: \(name) <avery@home.example>
                To: "Doe, John" <john@example.com>, plain@example.com, Team: a@x.example, b@y.example;, (comment) c@z.example
                Cc: d@w.example (Dee Name)
                Content-Type: text/plain

                x
                """))
            let from = MailAddress.parseList(part.header("From") ?? "")
            expect(from == [MailAddress(name: "Лунный офис", email: "avery@home.example")], "22 encoded display name")
            let to = MailAddress.parseList(part.header("To") ?? "").map(\.email)
            expect(to == ["john@example.com", "plain@example.com", "a@x.example", "b@y.example", "c@z.example"], "22 list with quotes, group, comment (\(to))")
            expect(MailAddress.parseList(part.header("To") ?? "").first?.name == "Doe, John", "22 quoted comma stays in the name")
            expect(MailAddress.parseList(part.header("Cc") ?? "") == [MailAddress(name: "Dee Name", email: "d@w.example")], "22 comment as name")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/mixed; boundary=f

                --f
                Content-Type: text/plain

                body
                --f
                Content-Type: application/octet-stream
                Content-Disposition: attachment; filename*=UTF-8''%D8%AA%D9%82%D8%B1%D9%8A%D8%B1.pdf

                data
                --f
                Content-Type: application/octet-stream
                Content-Disposition: attachment;
                 filename*0*=UTF-8''long%20name%20;
                 filename*1="part two.txt"

                data
                --f
                Content-Type: application/octet-stream; name="=?UTF-8?B?\(Data("請求書.xlsx".utf8).base64EncodedString())?="
                Content-Disposition: attachment

                data
                --f
                Content-Type: application/zip
                Content-Disposition: attachment; filename="..\\\\..\\\\evil/path/archive.zip"

                data
                --f--
                """))
            expect(x.attachments.map(\.name) == ["تقرير.pdf", "long name part two.txt", "請求書.xlsx", "archive.zip"],
                   "23 RFC 2231 name, continuations, encoded-word name, path stripped (\(x.attachments.map(\.name)))")
        }
        do {
            let (part, x) = parse(raw("""
                Subject: A long subject that was folded
                  across two lines
                Content-Type: text/plain;
                \tcharset=utf-8

                LF only body
                """, lf: true))
            expect(EncodedWord.decode(part.header("Subject") ?? "") == "A long subject that was folded across two lines", "24 folded header, LF line ends")
            expect(part.contentType.params["charset"] == "utf-8" && x.text == "LF only body", "24 folded parameter")
        }
    }

    // MARK: Malformed input

    static func malformed() {
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/alternative; boundary=open

                --open
                Content-Type: text/plain

                No closing delimiter follows
                """))
            expect(x.text == "No closing delimiter follows", "25 missing closing boundary")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: multipart/mixed; boundary=never

                The boundary never appears.
                """))
            expect(x.text == "The boundary never appears.", "26 boundary never present → read as text")
        }
        do {
            let (part, x) = parse(raw("""
                Subject: no type

                Just text
                """))
            expect(part.contentType.value == "text/plain" && x.text == "Just text", "27 no Content-Type → text/plain")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: text/plain; charset=utf-8
                Content-Transfer-Encoding: base64

                SGVsbG8g!!d29y
                bGQ
                """))
            expect(x.text == "Hello world", "28 base64 with junk characters and missing padding")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: text/plain
                Content-Transfer-Encoding: quoted-printable

                Bad =ZZ escape and trailing =
                """))
            expect(x.text == "Bad =ZZ escape and trailing ", "29 malformed QP kept literally")
        }
        do {
            let (_, x) = parse(raw("""
                Content-Type: text/html

                <p>unterminated <b>bold
                """))
            let clean = HTMLSanitizer.sanitize(x.html ?? "", remote: .block).html
            expect(clean == "<p>unterminated <b>bold</b></p>", "30 unterminated HTML closed by the sanitizer (\(clean.debugDescription))")
        }
        expect(MIMEParser.parse(Data()).body.isEmpty, "empty input parses")
    }

    // MARK: Gmail payloads (format=full)

    static func gmailPayloads() {
        func decodePart(_ json: [String: Any]) -> GMessagePart {
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(GMessagePart.self, from: data)
        }
        func body(_ text: String) -> [String: Any] { ["size": text.utf8.count, "data": Data(text.utf8).base64URLString] }
        do {
            corpusCount += 1
            let payload = decodePart([
                "mimeType": "multipart/alternative",
                "headers": [["name": "Content-Type", "value": "multipart/alternative; boundary=x"]],
                "parts": [
                    ["mimeType": "text/plain", "headers": [["name": "Content-Type", "value": "text/plain; charset=UTF-8"]], "body": body("Hi ✓")],
                    ["mimeType": "text/html", "headers": [["name": "Content-Type", "value": "text/html; charset=UTF-8"]],
                     "body": body("<p>Hi ✓ <img src=\"https://t.example/p.gif\"></p>")],
                ],
            ])
            let x = MIMEParser.extract(MIMEParser.fromGmail(payload))
            expect(x.text == "Hi ✓" && x.html?.contains("Hi ✓") == true, "31 Gmail payload: alternative, base64url bodies")
        }
        do {
            corpusCount += 1
            let qp = "Line one is long enough that it got a soft =\r\nbreak; caf=C3=A9 =E2=9C=93"
            let payload = decodePart([
                "mimeType": "text/plain",
                "headers": [["name": "Content-Type", "value": "text/plain; charset=utf-8"],
                            ["name": "Content-Transfer-Encoding", "value": "quoted-printable"]],
                "body": body(qp),
            ])
            let x = MIMEParser.extract(MIMEParser.fromGmail(payload))
            expect(x.text == "Line one is long enough that it got a soft break; café ✓", "32 Gmail part still QP-encoded is decoded")
            let already = decodePart([
                "mimeType": "text/plain",
                "headers": [["name": "Content-Type", "value": "text/plain; charset=utf-8"],
                            ["name": "Content-Transfer-Encoding", "value": "quoted-printable"]],
                "body": body("2 + 2 = 4, and a=b is fine"),
            ])
            expect(MIMEParser.extract(MIMEParser.fromGmail(already)).text == "2 + 2 = 4, and a=b is fine", "32 already-decoded QP part untouched")
        }
        // Gmail hands back a legacy code page's bytes as they were sent.
        for (charset, html) in [("windows-1251", "<p>Привет</p>"), ("windows-1253", "<p>Γεια σου</p>"), ("windows-1255", "<p>שלום</p>"),
                                ("windows-1256", "<p>مرحبا</p>")] {
            corpusCount += 1
            let bytes = html.data(using: codePage(charset))!
            let payload = decodePart([
                "mimeType": "multipart/mixed",
                "parts": [
                    ["mimeType": "text/html", "headers": [["name": "Content-Type", "value": "text/html; charset=\"\(charset)\""]],
                     "body": ["size": bytes.count, "data": bytes.base64URLString]],
                    ["mimeType": "application/pdf", "filename": "Contract.pdf",
                     "headers": [["name": "Content-Type", "value": "application/pdf; name=\"Contract.pdf\""],
                                 ["name": "Content-Disposition", "value": "attachment; filename=\"Contract.pdf\""]],
                     "body": ["size": 48213, "attachmentId": "ANGjdJ8"]],
                ],
            ])
            let x = MIMEParser.extract(MIMEParser.fromGmail(payload))
            expect(x.html == html, "33 Gmail \(charset) HTML part")
            expect(x.attachments == [MailMessage.Attachment(name: "Contract.pdf", bytes: 48213)], "33 Gmail attachment: name + reported size, no bytes")
        }
    }

    // MARK: Helpers

    static func helpers() {
        expect(QuotedPrintable.decode(Data("a=\nb=0D=0Ac".utf8)) == Data("ab\r\nc".utf8), "QP: LF soft break, encoded CRLF")
        expect(Data(base64URL: "_-8") == Data([0xFF, 0xEF]), "base64url without padding")
        expect(Data([0xFB, 0xFF]).base64URLString == "-_8", "base64url encoding")
        expect(EncodedWord.decode("=?utf-8?q?=E2=9C=93?= done") == "✓ done", "Q word then literal keeps the space")
        expect(EncodedWord.decode("=?broken") == "=?broken", "broken word stays literal")
        expect(EncodedWord.decode("plain") == "plain", "plain header untouched")
        expect(HTMLEntities.decode("&amp;&lt;&#39;&#x27;&nbsp;&hellip;&bogus;&amp") == "&<''\u{00A0}\u{2026}&bogus;&", "entities")
        expect(MailDate.parse("Mon, 19 Oct 2026 09:48:00 +0100 (BST)") == TestCal.iso("2026-10-19T09:48:00+01:00"), "RFC 5322 date with comment")
        expect(MailDate.parse("19 Oct 2026 06:48 GMT") == TestCal.iso("2026-10-19T06:48:00Z"), "date without weekday or seconds")
        expect(Charset.encoding("UTF-8") == .utf8 && Charset.encoding(nil) == nil, "charset names")
        for name in ["windows-1251", "windows-1253", "windows-1255", "windows-1256", "koi8-r"] {
            expect(Charset.encoding(name) == codePage(name), "charset name \(name)")
        }
        let aliases = [("cyrillic", "iso-8859-5"), ("arabic", "iso-8859-6"), ("greek", "iso-8859-7"), ("hebrew", "iso-8859-8"),
                       ("x-cp1251", "windows-1251"), ("x-cp1253", "windows-1253"), ("x-cp1255", "windows-1255"), ("x-cp1256", "windows-1256"),
                       ("csShiftJIS", "x-sjis"), ("csISO2022JP", "iso-2022-jp"), ("KOI8-R", "koi8-r")]
        for (alias, name) in aliases {
            expect(Charset.encoding(alias) != nil && Charset.encoding(alias) == Charset.encoding(name), "charset alias \(alias) = \(name)")
        }
        let p = ParamHeader.parse("Attachment; FileName=\"a \\\"b\\\".txt\"; size=10")
        expect(p.value == "attachment" && p.params["filename"] == "a \"b\".txt" && p.params["size"] == "10", "parameter parsing with escapes")
        expect(MailAddress.isValid("a.b+c@example.test") && !MailAddress.isValid("a@b") && !MailAddress.isValid("a b@c.example")
               && !MailAddress.isValid("x@y.example\r\nBcc: z@w.example"), "address validation")
    }

    // MARK: Builder

    static func trimEnd(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\r\n") { out.removeLast() }   // "\r\n" is one Character
        return out
    }

    static func builder() {
        let at = TestCal.iso("2026-10-19T09:48:00+01:00")
        do {
            let id = MIMEBuilder.newMessageID()
            expect(id.hasPrefix("<") && id.hasSuffix("@yayascalendar.local>") && MIMEBuilder.isMessageID(id) && id.count == 58,
                   "our Message-ID: a UUID at yayascalendar.local")
            let mail = OutgoingMail(from: MailAddress(name: "Avery Moonfield", email: "y@orb.example"),
                                    to: [MailAddress(name: "", email: "a@example.com")], subject: "Plain subject",
                                    body: "Hello,\nshort ASCII body.\n", messageID: id, date: at)
            let data = MIMEBuilder.build(mail)
            let text = String(decoding: data, as: UTF8.self)
            expect(text.contains("\r\n\r\n") && !text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF everywhere")
            expect(text.contains("Content-Transfer-Encoding: 7bit") && text.contains("MIME-Version: 1.0"), "ASCII body as 7bit")
            let back = MIMEParser.parse(data)
            expect(back.header("From") == "Avery Moonfield <y@orb.example>" && back.header("To") == "a@example.com", "From/To round trip")
            expect(back.header("Message-ID") == id && back.header("In-Reply-To") == nil, "Message-ID; no In-Reply-To on new mail")
            expect(MIMEParser.extract(back).text == "Hello,\r\nshort ASCII body.\r\n", "body round trip")
        }
        // A mostly non-Latin message per script: 7-bit clean, every line ≤ 78, the body in base64, and the encoded
        // subject, From name, quoted To name, Cc/Bcc and body back as written.
        let tail = " — Re: plan ✓ with a long tail of words to force several encoded words in the header"
        let scripts: [(String, String, String, String)] = [
            ("Greek", "Συνάντηση αύριο" + tail, "Γεια σας,\nένα δοκιμαστικό μήνυμα.\n", "Σελήνη"),
            ("Cyrillic", "Встреча завтра" + tail, "Привет, команда!\nЭто тестовое письмо.\n", "Луна"),
            ("Japanese", "明日の会議" + tail, "皆さん、こんにちは。\nテストのメールです。\n", "月"),
            ("Hebrew", "פגישה מחר" + tail, "שלום צוות,\nזו הודעת בדיקה.\n", "ירח"),
            ("Arabic", "اجتماع الغد" + tail, "مرحبا يا فريق،\nهذه رسالة تجريبية.\n", "قمر"),
            ("Syriac", "ܟܢܘܫܝܐ ܕܫܒܬܐ" + tail, "ܫܠܡܐ ܠܟܠܟܘܢ\nܐܓܪܬܐ ܕܢܣܝܘܢܐ.\n", "ܣܗܪܐ"),
        ]
        for (script, subject, body, name) in scripts {
            let mail = OutgoingMail(from: MailAddress(name: name, email: "y@home.example"),
                                    to: [MailAddress(name: "Doe, John", email: "john@example.com")],
                                    cc: [MailAddress(name: "", email: "c@example.com")], bcc: [MailAddress(name: "", email: "b@example.com")],
                                    subject: subject, body: body, messageID: MIMEBuilder.newMessageID(), date: at)
            let data = MIMEBuilder.build(mail)
            let text = String(decoding: data, as: UTF8.self)
            let back = MIMEParser.parse(data)
            expect(text.unicodeScalars.allSatisfy { $0.isASCII } && (text.components(separatedBy: "\r\n").map(\.count).max() ?? 0) <= 78,
                   "\(script): 7-bit clean, lines ≤ 78")
            expect(text.contains("Content-Transfer-Encoding: base64"), "\(script): mostly non-ASCII body → base64")
            expect(EncodedWord.decode(back.header("Subject") ?? "") == subject
                   && MailAddress.parseList(back.header("From") ?? "") == [MailAddress(name: name, email: "y@home.example")]
                   && MIMEParser.extract(back).text == body.replacingOccurrences(of: "\n", with: "\r\n"),
                   "\(script): subject, From name and body round trip")
            expect(MailAddress.parseList(back.header("To") ?? "").first?.name == "Doe, John", "\(script): quoted To name")
            expect(back.header("Bcc") == "b@example.com" && back.header("Cc") == "c@example.com", "\(script): Cc/Bcc headers")
        }
        do {
            let body = "Mostly ASCII, with one café, a trailing space \nand a long line " + String(repeating: "word ", count: 30) + "\n.\nend = done"
            let mail = OutgoingMail(from: MailAddress(name: "", email: "y@orb.example"), to: [MailAddress(name: "", email: "a@example.com")],
                                    subject: "QP", body: body, messageID: MIMEBuilder.newMessageID(), date: at)
            let data = MIMEBuilder.build(mail)
            let text = String(decoding: data, as: UTF8.self)
            expect(text.contains("quoted-printable"), "mostly-ASCII body with é → quoted-printable")
            expect((text.components(separatedBy: "\r\n").map(\.count).max() ?? 0) <= 78, "QP lines ≤ 78")
            expect(!text.contains("\r\n.\r\n"), "no bare dot line")
            expect(trimEnd(MIMEParser.extract(MIMEParser.parse(data)).text) == body.replacingOccurrences(of: "\n", with: "\r\n"), "QP body round trip")
        }
        do {
            let recipients = (0..<9).map { MailAddress(name: "Person \($0)", email: "person\($0)@example.com") }
            let mail = OutgoingMail(from: MailAddress(name: "", email: "y@orb.example"), to: recipients, subject: "Hi\r\nBcc: evil@x.example",
                                    body: "x", messageID: MIMEBuilder.newMessageID(), date: at)
            let data = MIMEBuilder.build(mail)
            let text = String(decoding: data, as: UTF8.self)
            let back = MIMEParser.parse(data)
            expect(MailAddress.parseList(back.header("To") ?? "").count == 9, "folded To list parses back to 9")
            expect((text.components(separatedBy: "\r\n").map(\.count).max() ?? 0) <= 78, "To folded under 78")
            expect(back.header("Bcc") == nil && !text.contains("\r\nBcc:"), "a line break in the subject can't inject a header")
        }
        do {
            let parentRefs = "<a@x.example> <b@x.example>\r\n <c@x.example>"
            let refs = MIMEBuilder.references(parentReferences: parentRefs, parentInReplyTo: "<b@x.example>", parentMessageID: "<d@x.example>")
            expect(refs == ["<a@x.example>", "<b@x.example>", "<c@x.example>", "<d@x.example>"], "References = parent's References + parent id")
            let fallback = MIMEBuilder.references(parentReferences: nil, parentInReplyTo: "<p@x.example>", parentMessageID: "<d@x.example>")
            expect(fallback == ["<p@x.example>", "<d@x.example>"], "no References → parent's In-Reply-To + parent id")
            let long = (0..<30).map { "<m\($0)@x.example>" }.joined(separator: " ")
            let trimmed = MIMEBuilder.references(parentReferences: long, parentInReplyTo: nil, parentMessageID: "<last@x.example>")
            expect(trimmed.count == 20 && trimmed.first == "<m0@x.example>" && trimmed.last == "<last@x.example>", "long chains keep the root and the newest")
            expect(MIMEBuilder.messageIDs(in: "<ok@x.example> <bad id@x> <also@ok.example>") == ["<ok@x.example>", "<also@ok.example>"], "invalid ids dropped")
            let mail = OutgoingMail(from: MailAddress(name: "", email: "y@orb.example"), to: [MailAddress(name: "", email: "a@x.example")],
                                    subject: MIMEBuilder.replySubject("Plan"), body: "Reply", messageID: MIMEBuilder.newMessageID(),
                                    inReplyTo: "<d@x.example>", references: refs, date: at)
            let back = MIMEParser.parse(MIMEBuilder.build(mail))
            expect(back.header("In-Reply-To") == "<d@x.example>", "In-Reply-To written")
            expect(MIMEBuilder.messageIDs(in: back.header("References")) == refs, "References written (folded) and read back")
            expect(back.header("Subject") == "Re: Plan", "reply subject")
            expect(MIMEBuilder.replySubject("RE: Plan") == "RE: Plan" && MIMEBuilder.replySubject("") == "Re:", "no double Re:")
            for subject in ["AW: Plan", "SV: Plan", "Antw: Plan", "Odp: Plan", "ΑΠ: Σχέδιο", "ΣΧΕΤ: Σχέδιο", "השב: תוכנית", "رد: خطة", "回复：计划",
                            "回覆: 計劃"] {
                expect(MIMEBuilder.replySubject(subject) == subject, "other clients' reply prefix: \(subject)")
            }
            expect(MIMEBuilder.replySubject("Απάντηση") == "Re: Απάντηση" && MIMEBuilder.replySubject("Отчёт") == "Re: Отчёт",
                   "a subject that only starts with the same letters still gets Re:")
        }
        do {
            expect(MIMEBuilder.appendSignature("Hi\n\n", "Avery\nOrbital Pickle Co.") == "Hi\n\n-- \nAvery\nOrbital Pickle Co.", "signature after '-- '")
            expect(MIMEBuilder.appendSignature("Hi", "  ") == "Hi", "empty signature adds nothing")
            expect(MIMEBuilder.appendSignature("Hi\n\nAvery\nOrbital\n\n", "Avery\nOrbital") == "Hi\n\nAvery\nOrbital\n\n",
                   "body already ending with the signature (blank lines after it) gets no second copy")
            expect(MailAddress(name: "Smith, J. (Ops)", email: "j@x.example").header == "\"Smith, J. (Ops)\" <j@x.example>", "specials quoted")
            expect(MailAddress(name: "Ana \"Q\"", email: "a@x.example").header == "\"Ana \\\"Q\\\"\" <a@x.example>", "quotes escaped")
        }
    }
}
