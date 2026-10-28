import AppKit
import Foundation

/// Rich mail, composer data tests: `MailHTMLWriter` goldens (html and text/plain per
/// case, in Tests/Data/Goldens/writer; regenerate after a deliberate change with YC_WRITE_GOLDENS=1), the writer's
/// link verdicts against `URLPolicy.classify`, and `MailHTMLReader`: writer → reader → writer is a fixed point, and
/// hostile input reads as text only. Cast names only.
enum RichComposerTests {
    static func run() {
        let cases = writerCases()
        goldens(cases)
        linkVerdicts()
        roundTrip(cases)
        hostileInput()
        pastedMarkup()
        budget()
    }

    // MARK: Document building (the composer's conventions, without the UI module)

    typealias Attrs = [NSAttributedString.Key: Any]

    static func f(_ family: String = "Helvetica", _ size: CGFloat = 14, bold: Bool = false, italic: Bool = false) -> NSFont {
        MailRichText.font(family: family, size: size, bold: bold, italic: italic)
    }

    static let b: Attrs = [.font: f(bold: true)]
    static let i: Attrs = [.font: f(italic: true)]
    static let bi: Attrs = [.font: f(bold: true, italic: true)]
    static let u: Attrs = [.underlineStyle: 1]
    static let s: Attrs = [.strikethroughStyle: 1]
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static func fg(_ hex: UInt32) -> Attrs { [.foregroundColor: color(hex)] }
    static func bg(_ hex: UInt32) -> Attrs { [.backgroundColor: color(hex)] }
    static func link(_ url: String) -> Attrs { [.link: url] }
    static func both(_ a: Attrs, _ b: Attrs) -> Attrs { a.merging(b) { _, new in new } }

    /// One paragraph (ending in "\n") with paragraph-level attributes on every character.
    static func p(_ runs: [(String, Attrs)], lists: [NSTextList] = [], quote: Int = 0, indent: Int = 0, sig: Bool = false,
                  dir: NSWritingDirection? = nil, terminate: Bool = true) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (text, attrs) in runs { out.append(NSAttributedString(string: text, attributes: [.font: f()].merging(attrs) { _, new in new })) }
        if terminate { out.append(NSAttributedString(string: "\n", attributes: [.font: f()])) }
        let all = NSRange(location: 0, length: out.length)
        out.addAttribute(.paragraphStyle, value: MailRichText.paragraphStyle(base: nil, indent: indent, quote: quote, lists: lists, direction: dir), range: all)
        if quote > 0 { out.addAttribute(.ycQuoteBlock, value: quote, range: all) }
        if sig { out.addAttribute(.ycSignature, value: true, range: all) }
        return out
    }

    static func p(_ text: String, _ attrs: Attrs = [:], lists: [NSTextList] = [], quote: Int = 0, indent: Int = 0, sig: Bool = false,
                  dir: NSWritingDirection? = nil) -> NSAttributedString {
        p([(text, attrs)], lists: lists, quote: quote, indent: indent, sig: sig, dir: dir)
    }

    static func docs(_ parts: NSAttributedString...) -> NSAttributedString {
        let out = NSMutableAttributedString()
        parts.forEach(out.append)
        return out
    }

    static func png(_ w: Int, _ h: Int, rgb: UInt32) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color(rgb).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func image(_ name: String, width: CGFloat, height: CGFloat, rgb: UInt32) -> NSAttributedString {
        let wrapper = FileWrapper(regularFileWithContents: png(4, 3, rgb: rgb))
        wrapper.preferredFilename = name
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttribute(.font, value: f(), range: NSRange(location: 0, length: out.length))
        return out
    }

    static func list(_ ordered: Bool, depth: Int = 1) -> NSTextList { MailRichText.newList(ordered: ordered, depth: depth) }

    // MARK: Writer cases

    static func writerCases() -> [(String, NSAttributedString)] {
        var cases: [(String, NSAttributedString)] = []
        func add(_ name: String, _ doc: NSAttributedString) { cases.append((name, doc)) }

        add("01-plain-paragraph", p("Hi Juniper, the labels look great."))
        add("02-empty-paragraphs", docs(p(""), p("Between blank lines"), p(""), p(""), p("End")))
        add("03-bold-across-italic", p([("plain ", [:]), ("bold ", b), ("both", bi), (" italic", i), (" plain", [:])]))
        add("04-every-font", docs(p("Sans", [.font: f("Helvetica")]), p("System", [.font: f(MailRichText.systemFamily)]),
                                  p("Serif", [.font: f("Georgia")]), p("Times", [.font: f("Times New Roman")]),
                                  p("Verdana", [.font: f("Verdana")]), p("Trebuchet", [.font: f("Trebuchet MS")]),
                                  p("Mono", [.font: f("Menlo")])))
        add("05-sizes", p([("small ", [.font: f("Helvetica", 12)]), ("normal ", [:]), ("large ", [.font: f("Helvetica", 18)]), ("huge", [.font: f("Helvetica", 24)])]))
        let calibrated = NSColor(calibratedRed: 0.77, green: 0.13, blue: 0.12, alpha: 1)
        add("06-colours", p([("red ", fg(0xC5221F)), ("calibrated ", [.foregroundColor: calibrated]), ("catalog ", [.foregroundColor: NSColor.textColor]),
                             ("near-black ", fg(0x020202)), ("sheet-ink ", fg(0x1D1B20)), ("label", [.foregroundColor: NSColor.labelColor])]))
        add("07-highlight", p([("marked", bg(0xFFF475)), (" and ", [:]), ("white is no highlight", bg(0xFFFFFF))]))
        add("08-link-escaping", p([("menu", link("https://cafenowhere.example/menu?a=1&b=\"2\"")), (" & <more>", [:])]))
        add("09-javascript-dropped", p([("click", link("javascript:alert(1)")), (" here", [:])]))
        add("10-mailto-tel", p([("Juniper", link("mailto:juniper@vale.example")), (" or ", [:]), ("call", link("tel:+440000000000"))]))
        add("11-link-is-url", p([("https://quietcomets.example", link("https://quietcomets.example")), (" and ", [:]),
                                 ("juniper@vale.example", link("mailto:juniper@vale.example"))]))
        let l1 = list(false), l2 = list(false, depth: 2), l3 = list(false, depth: 3)
        add("12-bullets-nested", docs(p("Dill", lists: [l1]), p("Garlic", lists: [l1, l2]), p("Black garlic", lists: [l1, l2, l3]),
                                      p("Chili", lists: [l1]), p("After the list")))
        let n1 = list(true), m2 = list(false, depth: 2), n1b = list(true)
        add("13-numbers-mixed", docs(p("First", lists: [n1]), p("Detail", lists: [n1, m2]), p("Second", lists: [n1]),
                                     p("Gap"), p("Restart", lists: [n1b])))
        let tk1 = list(false)
        add("14-marker-in-storage", docs(p("\t\u{2022}\tTextKit 1 bullet", lists: [tk1]), p("\u{2022}\tno leading tab", lists: [tk1])))
        let n3 = list(true)
        n3.startingItemNumber = 3
        add("15-ordered-start", docs(p("Third", lists: [n3]), p("Fourth", lists: [n3])))
        add("16-indents", docs(p("Level 0"), p("Level 1", indent: 1), p("Level 2", indent: 2), p("Level 1 again", indent: 1)))
        add("17-quotes", docs(p("Quoted"), p("Level 1", quote: 1), p("Level 2", quote: 2), p("Back to 1", quote: 1), p("Out")))
        let ql = list(true)
        add("18-quote-with-list", docs(p("Steps:", quote: 1), p("Boil jars", lists: [ql], quote: 1), p("Fill", lists: [ql], quote: 1)))
        add("19-line-breaks", docs(p("Line one\u{2028}line two"), p("Ends with a break\u{2028}")))
        add("20-spaces-and-tabs", docs(p("two  spaces and   three"), p(" leading"), p("trailing "), p("tab\there")))
        add("21-rtl", docs(p("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627} \u{0628}\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645}"),
                           p("123 \u{05E9}\u{05DC}\u{05D5}\u{05DD}"), p("Hello")))
        add("22-emoji-escaping", p("Pickles \u{1F952} & jars <3 \"quoted\" 'single'"))
        add("23-inline-image", docs(p([("Logo: ", [:])], terminate: false), image("logo.png", width: 120, height: 80, rgb: 0x12808C), p("")))
        add("24-wide-image", docs(image("panorama.png", width: 1200, height: 300, rgb: 0x9CC5A1), p("")))
        add("25-signature", docs(p("Thanks!"), p(""), p("Avery Moonfield", sig: true), p("The Quiet Comets", sig: true)))
        add("26-rich-signature", docs(p("See you Sunday."), p(""), p("Avery Moonfield", [.font: f(bold: true)], sig: true),
                                      p([("Orbital Pickle Co.", fg(0x12808C)), (" \u{00B7} ", [:]), ("orbitalpickle.example", link("https://orbitalpickle.example"))], sig: true)))
        add("27-underline-strike-scripts", p([("under", u), (" ", [:]), ("struck", s), (" H", [:]), ("2", [.superscript: -1]), ("O E=mc", [:]),
                                              ("2", [.superscript: 1])]))
        add("28-composer-start", docs(p(""), p(""), p("Avery", sig: true)))
        let tl = list(false)
        add("29-formatted-mail", docs(p([("Hi ", [:]), ("Priya", b), (",", [:])]), p(""),
                                      p([("The ", [:]), ("Q4 pickle launch", both(fg(0x1967D2), b)), (" plan:", [:])]),
                                      p("Labels by Thursday", lists: [tl]), p([("Tasting at ", [:]), ("Café Nowhere", link("https://cafenowhere.example"))], lists: [tl]),
                                      p("Budget in Suite 404", lists: [tl]), p(""),
                                      p([("Shout if anything looks ", [:]), ("off", i), (".", [:])], quote: 1), p(""),
                                      p("Avery", sig: true)))
        add("30-custom-family", p([("Futura here", [.font: f("Futura")]), (" and Courier", [.font: f("Courier")])]))
        add("31-link-across-runs", p([("the ", link("https://quietcomets.example/tour")), ("tour", both(link("https://quietcomets.example/tour"), b)),
                                      (" page", link("https://quietcomets.example/tour")), (" today", [:])]))
        add("32-controls-dropped", p("bell\u{0007} null\u{0000} esc\u{001B} ok"))
        add("33-explicit-rtl", p("Latin text in a right-to-left paragraph", dir: .rightToLeft))
        add("34-no-final-newline", p([("Last line without a newline", [:])], terminate: false))
        add("35-empty", NSAttributedString())
        return cases
    }

    static var goldenFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens/writer", isDirectory: true)
    }

    static func render(_ doc: NSAttributedString) -> MailHTMLWriter.Output {
        var n = 0
        return MailHTMLWriter.render(doc, font: .sans, size: 14, contentId: {
            n += 1
            return "img-\(n)@yayascalendar.local"
        })
    }

    static func goldens(_ cases: [(String, NSAttributedString)]) {
        expect(cases.count >= 30, "rich mail writer: at least 30 writer cases")
        let write = ProcessInfo.processInfo.environment["YC_WRITE_GOLDENS"] == "1"
        if write { try? FileManager.default.createDirectory(at: goldenFolder, withIntermediateDirectories: true) }
        for (name, doc) in cases {
            let out = render(doc)
            let html = goldenFolder.appendingPathComponent(name + ".html"), text = goldenFolder.appendingPathComponent(name + ".txt")
            if write {
                try? out.html.write(to: html, atomically: true, encoding: .utf8)
                try? out.text.write(to: text, atomically: true, encoding: .utf8)
                continue
            }
            let wantHTML = try? String(contentsOf: html, encoding: .utf8)
            let wantText = try? String(contentsOf: text, encoding: .utf8)
            expect(wantHTML == out.html, "rich mail writer \(name): html golden")
            expect(wantText == out.text, "rich mail writer \(name): text/plain golden")
            if wantHTML != out.html { print("    \(name) html:\n    got  \(out.html)\n    want \(wantHTML ?? "(missing)")") }
            if wantText != out.text { print("    \(name) text:\n    got  \(out.text.debugDescription)\n    want \((wantText ?? "(missing)").debugDescription)") }
        }
        // Invariants every output keeps.
        for (name, doc) in cases {
            let out = render(doc)
            expect(!out.html.contains("<style") && !out.html.contains("class=\"p1\"") && !out.html.contains("Cocoa"), "rich mail writer \(name): inline styles only")
            expect(!out.html.contains("\u{2022}\t") && !out.html.contains("javascript:"), "rich mail writer \(name): no marker text, no script links")
            expect(out.html == render(doc).html, "rich mail writer \(name): deterministic")
        }
        let images = render(cases.first { $0.0 == "23-inline-image" }!.1).inlineImages
        expect(images.count == 1 && images[0].contentId == "img-1@yayascalendar.local" && images[0].mimeType == "image/png"
               && images[0].filename == "logo.png" && !images[0].data.isEmpty, "rich mail writer: inline image part (cid, PNG, name)")
    }

    // MARK: Links: the writer's own check agrees with the sanitizer's URLPolicy

    static func linkVerdicts() {
        let table = [
            "https://a.example", "http://a.example/x?y=1&z=2", "HTTPS://A.EXAMPLE", " https://a.example ", "ht\ttps://a.example",
            "java\nscript:alert(1)", "javascript:alert(1)", "JAVASCRIPT:alert(1)", "vbscript:msgbox", "data:text/html,<b>x</b>",
            "data:image/png;base64,AAAA", "mailto:juniper@vale.example", "MAILTO:theo@quill.example", "tel:+44 20 0000 0000",
            "cid:logo@quietcomets.example", "#top", "/relative/path", "relative.html", "//cdn.quietcomets.example/x.png",
            "file:///etc/passwd", "ftp://files.example", "about:blank", "\u{0000}https://a.example", "https:", "mailto:",
            "x-apple-data-detectors://1", "sms:+440000", "https://a.example/a b", "https://\u{00FC}n\u{00EF}.example/",
            "\u{0001}\u{0002}javascript:alert(1)",
        ]
        expect(table.count == 30, "rich mail writer: 30-URL link table")
        for raw in table {
            let writer = MailHTMLWriter.linkVerdict(raw)
            let (kind, normalized) = URLPolicy.classify(raw)
            let allowed = kind == .web || kind == .mailto || kind == .tel
            expect((writer != nil) == allowed, "rich mail writer: link verdict matches URLPolicy for \(raw.debugDescription)")
            if let writer { expect(writer == normalized, "rich mail writer: same normalization for \(raw.debugDescription)") }
        }
    }

    // MARK: Round trip

    static func roundTrip(_ cases: [(String, NSAttributedString)]) {
        // Tabs become &nbsp; runs (a documented simplification); every other case is a fixed point at once.
        let lossy: Set<String> = ["20-spaces-and-tabs"]
        for (name, doc) in cases {
            let first = render(doc)
            var attachments: [String: NSTextAttachment] = [:]
            doc.enumerateAttribute(.attachment, in: NSRange(location: 0, length: doc.length)) { value, _, _ in
                if let a = value as? NSTextAttachment { attachments["img-\(attachments.count + 1)@yayascalendar.local"] = a }
            }
            let read = MailHTMLReader.attributedString(first.html, font: .sans, size: 14, image: { attachments[$0] })
            let second = render(read)
            if lossy.contains(name) {
                let third = render(MailHTMLReader.attributedString(second.html, font: .sans, size: 14))
                expect(third.html == second.html, "rich mail round trip \(name): stable after one pass")
                continue
            }
            expect(second.html == first.html, "rich mail round trip \(name): writer → reader → writer is a fixed point (html)")
            expect(second.text == first.text, "rich mail round trip \(name): … and text/plain")
            if second.html != first.html { print("    \(name) round trip:\n    1st \(first.html)\n    2nd \(second.html)") }
            if second.text != first.text { print("    \(name) round trip text:\n    1st \(first.text.debugDescription)\n    2nd \(second.text.debugDescription)") }
        }
    }

    static func hostileInput() {
        let hostile = """
        <html><head><title>Win</title><style>p{color:red}</style><script>alert(1)</script><meta http-equiv="refresh" content="0;url=https://evil.example"></head>
        <body onload="steal()"><p onclick="x()">Hi <img src="https://track.example/p.gif" alt="logo" width="1"> \
        <a href="javascript:alert(1)">click</a> <a href="https://ok.example" target="_blank">ok</a></p>\
        <iframe src="https://evil.example"></iframe><object data="x.swf"></object><svg><script>alert(2)</script></svg>\
        <div style="display:none">hidden preheader</div><form action="https://evil.example"><input value="pw"></form>\
        <div style="background:url(https://track.example/bg.png)">bg</div></body></html>
        """
        let clean = HTMLSanitizer.sanitize(hostile, remote: .block).html
        let read = MailHTMLReader.attributedString(clean)
        expect(read.string == "Hi logo click ok\nbg\n", "rich mail round trip: hostile input reads as its visible text (got \(read.string.debugDescription))")
        var links: [String] = [], attachments = 0, keys = Set<String>()
        read.enumerateAttributes(in: NSRange(location: 0, length: read.length)) { a, _, _ in
            if let l = a[.link] as? String { links.append(l) }
            if a[.attachment] != nil { attachments += 1 }
            a.keys.forEach { keys.insert($0.rawValue) }
        }
        expect(links == ["https://ok.example"], "rich mail round trip: only the http link survives")
        expect(attachments == 0, "rich mail round trip: no images from hostile input")
        expect(keys.isSubset(of: [NSAttributedString.Key.font.rawValue, NSAttributedString.Key.paragraphStyle.rawValue, NSAttributedString.Key.link.rawValue]),
               "rich mail round trip: hostile input brings no colours or other attributes")
        // Unsanitized markup straight into the reader still yields text only (belt and braces).
        let raw = MailHTMLReader.attributedString("<script>alert(1)</script><style>b{}</style><p>Text</p><img src=\"https://x.example/a.png\">")
        expect(raw.string == "Text\n", "rich mail round trip: script and style content never become text")
    }

    static func pastedMarkup() {
        // Gmail web (13 px Arial, a list, a bold word, a link, an indent blockquote).
        let gmail = """
        <div dir="ltr"><div style="font-family:arial,sans-serif;font-size:small">Hello <b>Theo</b>,</div><div><br></div>\
        <ul><li style="margin-left:15px">one</li><li style="margin-left:15px">two <a href="https://quill.example">link</a></li></ul>\
        <blockquote style="margin:0px 0px 0px 40px;border:none;padding:0px"><div>indented</div></blockquote></div>
        """
        let g = MailHTMLReader.attributedString(HTMLSanitizer.sanitize(gmail, remote: .block).html)
        expect(g.string == "Hello Theo,\n\none\ntwo link\nindented\n", "rich mail round trip: Gmail paste text (got \(g.string.debugDescription))")
        let at = (g.string as NSString).range(of: "Theo").location
        expect(MailRichText.isBold(g.attribute(.font, at: at, effectiveRange: nil) as? NSFont), "rich mail round trip: Gmail bold")
        let one = (g.string as NSString).range(of: "one").location, two = (g.string as NSString).range(of: "two").location
        let l1 = (g.attribute(.paragraphStyle, at: one, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first
        let l2 = (g.attribute(.paragraphStyle, at: two, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first
        expect(l1 != nil && l1 === l2, "rich mail round trip: one list, shared by its items")
        let ind = (g.string as NSString).range(of: "indented").location
        expect(MailRichText.indentLevel(g.attribute(.paragraphStyle, at: ind, effectiveRange: nil) as? NSParagraphStyle, quote: 0) == 1
               && g.attribute(.ycQuoteBlock, at: ind, effectiveRange: nil) == nil, "rich mail round trip: Gmail's indent blockquote is an indent, not a quote")
        expect((g.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 13, "rich mail round trip: small = 13 px (normalize snaps it to Normal)")

        // Outlook / Word: pt sizes, a font the Mac may not have, mso junk.
        let word = """
        <p class=MsoNormal><span style='font-size:11.0pt;font-family:"Calibri Light",sans-serif;mso-fareast-language:EN-US'>Dear Milo,<o:p></o:p></span></p>\
        <p class=MsoNormal><span style='color:#1F4E79'>Blue words</span> and <i>more</i></p>
        """
        let w = MailHTMLReader.attributedString(HTMLSanitizer.sanitize(word, remote: .block).html)
        expect(w.string == "Dear Milo,\nBlue words and more\n", "rich mail round trip: Word paste text (got \(w.string.debugDescription))")
        expect((w.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 15, "rich mail round trip: 11 pt = 15 px")
        expect(MailHTMLWriter.cssColor(w.attribute(.foregroundColor, at: 11, effectiveRange: nil)) == "#1f4e79", "rich mail round trip: Word colour")

        // A quote with an attribution and a table.
        let mixed = """
        <div>On Monday, Mom wrote:</div><blockquote type="cite"><div>Bring the <u>big</u> blanket.</div>\
        <table><tr><td>Lemon cake</td><td>2</td></tr><tr><td>Tea</td><td>1</td></tr></table></blockquote>
        """
        let m = MailHTMLReader.attributedString(HTMLSanitizer.sanitize(mixed, remote: .block).html)
        expect(m.string == "On Monday, Mom wrote:\nBring the big blanket.\nLemon cake\t2\nTea\t1\n", "rich mail round trip: quote and table (got \(m.string.debugDescription))")
        let q = (m.string as NSString).range(of: "Tea").location
        expect(MailRichText.quoteLevel(m.attribute(.ycQuoteBlock, at: q, effectiveRange: nil)) == 1, "rich mail round trip: blockquote type=cite is a quote block")
    }

    /// MailHTMLWriter.render on 10 pages, 200 runs, 3 images ≤ 30 ms (debug build here: reported, budget ×4).
    static func budget() {
        let doc = NSMutableAttributedString()
        for k in 0..<300 {
            var runs: [(String, Attrs)] = [("Paragraph \(k) about the pickle launch and the tour, ", [:])]
            if k % 3 == 0 { runs.append(("with a bold part", b)) }
            if k % 5 == 0 { runs.append((" and a link", link("https://orbitalpickle.example/\(k)"))) }
            runs.append((" that runs on to wrap a couple of lines in the editor at its usual width.", [:]))
            doc.append(p(runs, lists: k % 10 == 4 ? [list(false)] : []))
            if k % 100 == 50 { doc.append(docs(image("photo-\(k).png", width: 480, height: 320, rgb: 0x7FA7D9), p(""))) }
        }
        let started = Date()
        let out = render(doc)
        let ms = Date().timeIntervalSince(started) * 1000
        print(String(format: "    RICHMAIL-BENCH writer-data-tests %.1f ms (%d chars, %d images, debug build)", ms, doc.length, out.inlineImages.count))
        expect(out.inlineImages.count == 3, "rich mail: budget document has 3 images")
        expect(ms < 120, "rich mail: writer under 4 × its 30 ms budget in a debug build (\(Int(ms)) ms)")
    }
}
