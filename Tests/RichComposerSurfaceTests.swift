import AppKit
import Foundation

/// Rich mail, composer shell tests: document operations, `ComposerModel` compatibility
/// (the `body` bridge, the rich signature, drafts), Settings → Writing and rich signatures. Cast data only.
@MainActor
enum RichComposerSurfaceTests {
    static func run() async {
        documentOps()
        paragraphOps()
        normalize()
        formattingState()
        modelCompatibility()
        await modelDrafts()
        modelEditing()
        settings()
        correspondentsOff()
        richSignatures()
    }

    static let d = ComposerDocument.Defaults()
    static let now = Date(timeIntervalSince1970: 1_792_400_000)

    static func doc(_ text: String) -> NSMutableAttributedString {
        NSMutableAttributedString(attributedString: ComposerDocument.plain(text, defaults: d))
    }

    static func font(_ doc: NSAttributedString, _ at: Int) -> NSFont { doc.attribute(.font, at: at, effectiveRange: nil) as! NSFont }

    static func lists(_ doc: NSAttributedString, _ at: Int) -> [NSTextList] {
        (doc.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
    }

    /// Attributes outside `range` are untouched (the editor registers undo for `affectedRange` only).
    static func unchangedOutside(_ before: NSAttributedString, _ after: NSAttributedString, _ range: NSRange) -> Bool {
        guard before.length == after.length else { return false }
        for i in 0..<before.length where !NSLocationInRange(i, range) {
            let a = before.attributes(at: i, effectiveRange: nil), b = after.attributes(at: i, effectiveRange: nil)
            if !NSDictionary(dictionary: a).isEqual(to: b) { return false }
        }
        return true
    }

    // MARK: Document operations

    static func documentOps() {
        T.section("Rich mail: composer document operations")
        T.equal(ComposerDocument.defaultAttributes(font: .sans, size: .normal)[.foregroundColor] == nil, true, "defaults carry no foreground colour")
        T.equal(font(ComposerDocument.plain("a"), 0).familyName, "Helvetica", "default face: Helvetica (Sans Serif)")
        T.equal(font(ComposerDocument.plain("a"), 0).pointSize, 14, "default size 14")
        let ps = ComposerDocument.defaultParagraphStyle()
        T.check(ps.paragraphSpacing == 0 && abs(ps.lineHeightMultiple - 1.15) < 0.001, "paragraph spacing 0, line height 1.15")
        T.equal(FontChoice.allCases.map(\.css.stack).count, 7, "seven font choices")
        T.equal(FontChoice.allCases.map { $0.font(size: 14).familyName ?? "" },
                ["Helvetica", MailRichText.systemFamily, "Georgia", "Times New Roman", "Verdana", "Trebuchet MS", "Menlo"], "editor families")
        T.equal(SizeChoice.allCases.map(\.rawValue), [12, 14, 18, 24], "sizes")

        // Bold on a mixed selection: everything becomes bold; again: none.
        let m = doc("Hello pickle world")
        m.addAttribute(.font, value: FontChoice.sans.font(size: 14, bold: true), range: NSRange(location: 6, length: 6))
        let all = NSRange(location: 0, length: m.length)
        let before = NSAttributedString(attributedString: m)
        let r1 = ComposerDocument.apply(.bold, to: m, selection: all, defaults: d)
        T.check((0..<m.length).allSatisfy { MailRichText.isBold(font(m, $0)) }, "bold on a mixed selection: all bold")
        T.equal(r1.selection, all, "selection kept")
        T.check(unchangedOutside(before, m, ComposerDocument.affectedRange(.bold, in: before, selection: all)), "bold stays inside its range")
        ComposerDocument.apply(.bold, to: m, selection: all, defaults: d)
        T.check((0..<m.length).allSatisfy { !MailRichText.isBold(font(m, $0)) }, "bold again: none bold")

        // A caret only changes the typing attributes.
        let caret = doc("abc")
        let snapshot = NSAttributedString(attributedString: caret)
        let r2 = ComposerDocument.apply(.italic, to: caret, selection: NSRange(location: 1, length: 0), defaults: d)
        T.check(caret.isEqual(to: snapshot), "caret: the text is unchanged")
        T.check(MailRichText.isItalic(r2.typing?[.font] as? NSFont), "caret: typing attributes turn italic")
        let r3 = ComposerDocument.apply(.underline, to: caret, selection: NSRange(location: 3, length: 0), typing: r2.typing ?? [:], defaults: d)
        T.check(MailRichText.isItalic(r3.typing?[.font] as? NSFont) && (r3.typing?[.underlineStyle] as? Int) == 1, "typing ops stack")
        let empty = NSMutableAttributedString()
        let r4 = ComposerDocument.apply(.bold, to: empty, selection: NSRange(location: 0, length: 0), defaults: d)
        T.check(empty.length == 0 && MailRichText.isBold(r4.typing?[.font] as? NSFont), "empty document: typing attributes")

        // Underline / strike toggle, font, size, bigger/smaller, colour, highlight, link.
        let u = doc("underline me")
        let word = NSRange(location: 0, length: 9)
        ComposerDocument.apply(.underline, to: u, selection: word, defaults: d)
        T.equal(u.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue, "underline")
        T.check(u.attribute(.underlineStyle, at: 10, effectiveRange: nil) == nil, "underline stays in the selection")
        ComposerDocument.apply(.underline, to: u, selection: word, defaults: d)
        T.check(u.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil, "underline off again")
        ComposerDocument.apply(.strikethrough, to: u, selection: word, defaults: d)
        T.equal(u.attribute(.strikethroughStyle, at: 2, effectiveRange: nil) as? Int, 1, "strikethrough")
        ComposerDocument.apply(.bold, to: u, selection: word, defaults: d)
        ComposerDocument.apply(.font(.serif), to: u, selection: word, defaults: d)
        T.check(font(u, 0).familyName == "Georgia" && MailRichText.isBold(font(u, 0)), "font change keeps bold")
        ComposerDocument.apply(.size(.huge), to: u, selection: word, defaults: d)
        T.equal(font(u, 0).pointSize, 24, "size: huge")
        T.check(font(u, 0).familyName == "Georgia" && MailRichText.isBold(font(u, 0)), "size keeps face and bold")
        ComposerDocument.apply(.smaller, to: u, selection: word, defaults: d)
        T.equal(font(u, 0).pointSize, 18, "smaller: huge → large")
        ComposerDocument.apply(.bigger, to: u, selection: word, defaults: d)
        ComposerDocument.apply(.bigger, to: u, selection: word, defaults: d)
        T.equal(font(u, 0).pointSize, 24, "bigger stops at huge")
        T.equal(SizeChoice.step(from: 12, up: false), nil, "nothing smaller than small")
        ComposerDocument.apply(.color(0xC5221F), to: u, selection: word, defaults: d)
        T.equal(ComposerDocument.hex(u.attribute(.foregroundColor, at: 0, effectiveRange: nil)), 0xC5221F, "colour")
        ComposerDocument.apply(.color(nil), to: u, selection: word, defaults: d)
        T.check(u.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil, "default colour removes the attribute")
        ComposerDocument.apply(.highlight(0xFFF475), to: u, selection: word, defaults: d)
        T.equal(ComposerDocument.hex(u.attribute(.backgroundColor, at: 0, effectiveRange: nil)), 0xFFF475, "highlight")
        ComposerDocument.apply(.link("orbitalpickle.example"), to: u, selection: word, defaults: d)
        T.equal(u.attribute(.link, at: 0, effectiveRange: nil) as? String, "https://orbitalpickle.example", "a bare host gets https://")
        ComposerDocument.apply(.link("javascript:alert(1)"), to: u, selection: word, defaults: d)
        T.check(u.attribute(.link, at: 0, effectiveRange: nil) == nil, "javascript: is refused (the link goes)")
        T.equal(ComposerDocument.composerLink("juniper@vale.example"), "mailto:juniper@vale.example", "a bare address → mailto:")
        T.equal(ComposerDocument.composerLink("tel:+440000"), nil, "the composer offers http, https and mailto only")
        T.equal(ComposerDocument.composerLink("https://"), nil, "a link needs a host")

        // Insert a link with new text: replaces the selection, typing continues unlinked.
        let l = doc("See ")
        let r5 = ComposerDocument.apply(.insertLink(text: "the menu", url: "https://cafenowhere.example/menu"), to: l,
                                        selection: NSRange(location: 4, length: 0), defaults: d)
        T.equal(l.string, "See the menu", "insert link: text")
        T.equal(l.attribute(.link, at: 6, effectiveRange: nil) as? String, "https://cafenowhere.example/menu", "insert link: target")
        T.equal(r5.selection, NSRange(location: 12, length: 0), "caret after the link")
        T.check(r5.typing?[.link] == nil, "typing after a link isn't linked")
        T.equal(ComposerDocument.replacementString(.insertLink(text: "x", url: "https://a.example")), "x", "insert link replaces text (undo)")

        // Clear formatting keeps links and the signature mark.
        let c = doc("Bold link sig\n")
        ComposerDocument.apply(.bold, to: c, selection: NSRange(location: 0, length: 4), defaults: d)
        c.addAttribute(.link, value: "https://quietcomets.example", range: NSRange(location: 5, length: 4))
        c.addAttribute(.ycSignature, value: true, range: NSRange(location: 10, length: 3))
        c.addAttribute(.foregroundColor, value: ComposerDocument.color(0x1967D2), range: NSRange(location: 0, length: 13))
        ComposerDocument.apply(.list(.bullet), to: c, selection: NSRange(location: 0, length: 0), defaults: d)
        ComposerDocument.apply(.clearFormatting, to: c, selection: NSRange(location: 0, length: 13), defaults: d)
        T.check(!MailRichText.isBold(font(c, 0)) && c.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil, "clear: bold and colour gone")
        T.check(c.attribute(.link, at: 6, effectiveRange: nil) != nil, "clear keeps links")
        T.check((c.attribute(.ycSignature, at: 11, effectiveRange: nil) as? Bool) == true, "clear keeps the signature mark")
        T.check(lists(c, 0).isEmpty, "clear resets lists")
    }

    static func paragraphOps() {
        T.section("Rich mail: composer lists, indents and quotes")
        let m = doc("one\ntwo\nthree\nafter\n")
        let three = NSRange(location: 0, length: 13)
        let before = NSAttributedString(attributedString: m)
        let affected = ComposerDocument.affectedRange(.list(.bullet), in: m, selection: NSRange(location: 1, length: 9))
        T.equal(affected, NSRange(location: 0, length: 14), "paragraph ops register whole paragraphs")
        ComposerDocument.apply(.list(.bullet), to: m, selection: three, defaults: d)
        T.check(unchangedOutside(before, m, affected), "list op stays inside its paragraphs")
        let l0 = lists(m, 0), l1 = lists(m, 4), l2 = lists(m, 8)
        T.check(l0.count == 1 && l1.count == 1 && l2.count == 1, "three bullet items at level 1")
        T.check(l0[0] === l1[0] && l1[0] === l2[0], "one shared NSTextList (TextKit 2 numbers by identity)")
        T.equal(l0[0].markerFormat, .disc, "level 1: disc")
        T.check(lists(m, 15).isEmpty, "the next paragraph stays out")
        T.equal(m.string, "one\ntwo\nthree\nafter\n", "no marker text in storage (TextKit 2 draws markers)")

        // Indent the second item twice: levels 2 and 3, outer list kept.
        ComposerDocument.apply(.indent, to: m, selection: NSRange(location: 5, length: 0), defaults: d)
        T.equal(lists(m, 4).count, 2, "indent in a list → level 2")
        T.check(lists(m, 4)[0] === l0[0], "level 2 keeps its parent list")
        T.equal(lists(m, 4)[1].markerFormat, .circle, "level 2: circle")
        ComposerDocument.apply(.indent, to: m, selection: NSRange(location: 5, length: 0), defaults: d)
        T.equal(lists(m, 4).count, 3, "level 3")
        T.equal(lists(m, 4)[2].markerFormat, .square, "level 3: square")
        ComposerDocument.apply(.indent, to: m, selection: NSRange(location: 8, length: 0), defaults: d)
        T.check(lists(m, 8).count == 2 && lists(m, 8)[1] === lists(m, 4)[1], "indenting the next item joins the level-2 list above")
        ComposerDocument.apply(.outdent, to: m, selection: NSRange(location: 5, length: 0), defaults: d)
        ComposerDocument.apply(.outdent, to: m, selection: NSRange(location: 5, length: 0), defaults: d)
        T.equal(lists(m, 4).count, 1, "outdent twice → level 1")
        ComposerDocument.apply(.outdent, to: m, selection: NSRange(location: 5, length: 0), defaults: d)
        T.check(lists(m, 4).isEmpty, "outdent at level 1 leaves the list")

        // Switch kind, toggle off.
        ComposerDocument.apply(.list(.number), to: m, selection: NSRange(location: 0, length: 3), defaults: d)
        T.equal(lists(m, 0).first?.markerFormat.rawValue, "{decimal}.", "numbered lists draw \"1.\" ({decimal}.)")
        ComposerDocument.apply(.list(.number), to: m, selection: NSRange(location: 0, length: 3), defaults: d)
        T.check(lists(m, 0).isEmpty, "toggle the same kind off")
        let n = doc("a\nb\n")
        ComposerDocument.apply(.list(.number), to: n, selection: NSRange(location: 0, length: 1), defaults: d)
        ComposerDocument.apply(.list(.number), to: n, selection: NSRange(location: 2, length: 0), defaults: d)
        T.check(lists(n, 0).first === lists(n, 2).first, "a new item right after a numbered list continues it")

        // Indent outside lists, quotes.
        let q = doc("quote me\nplain\n")
        ComposerDocument.apply(.indent, to: q, selection: NSRange(location: 9, length: 0), defaults: d)
        ComposerDocument.apply(.indent, to: q, selection: NSRange(location: 9, length: 0), defaults: d)
        T.equal(MailRichText.indentLevel(q.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as? NSParagraphStyle, quote: 0), 2, "indent level 2")
        T.equal((q.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as? NSParagraphStyle)?.headIndent, 2 * MailRichText.indentStep, "indent: head indent")
        ComposerDocument.apply(.quote, to: q, selection: NSRange(location: 2, length: 0), defaults: d)
        T.equal(q.attribute(.ycQuoteBlock, at: 0, effectiveRange: nil) as? Int, 1, "quote block level 1")
        T.check(q.attribute(.ycQuoteBlock, at: 9, effectiveRange: nil) == nil, "the next paragraph isn't quoted")
        T.equal((q.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent, MailRichText.quoteStep, "quote indent")
        ComposerDocument.apply(.quote, to: q, selection: NSRange(location: 2, length: 0), defaults: d)
        T.check(q.attribute(.ycQuoteBlock, at: 0, effectiveRange: nil) == nil, "quote toggles off")

        // A caret on the empty last line: the paragraph style lives in the typing attributes.
        let tail = doc("text\n")
        let r = ComposerDocument.apply(.list(.bullet), to: tail, selection: NSRange(location: 5, length: 0), defaults: d)
        T.equal((r.typing?[.paragraphStyle] as? NSParagraphStyle)?.textLists.count, 1, "empty last line: the list goes to typing")
        T.equal(tail.string, "text\n", "…and the text is unchanged")
        let state = ComposerDocument.formatting(tail, selection: NSRange(location: 5, length: 0), typing: r.typing ?? [:], defaults: d)
        T.equal(state.list, .bullet, "toolbar shows the list on the empty line")

        // Marker runs from TextKit 1 sources are stripped (widened pattern).
        for (input, n) in [("\t\u{2022}\tItem", 3), ("\u{2022}\tItem", 2), ("\t12.\tItem", 5), ("3)\tItem", 3), ("\t\u{25E6}\tItem", 3),
                           ("Item", 0), ("\t-\tItem", 3), ("1.5 kg", 0)] {
            T.equal(MailRichText.markerLength(input), n, "marker run in \(input.debugDescription)")
        }
    }

    static func normalize() {
        T.section("Rich mail: composer paste normalization")
        // A two-cell table row, shadows, kerning, explicit black, a TextKit 1 list marker, a javascript link.
        let table = NSTextTable()
        table.numberOfColumns = 2
        func cell(_ text: String, _ column: Int) -> NSAttributedString {
            let block = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: column, columnSpan: 1)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            return NSAttributedString(string: text + "\n", attributes: [.font: NSFont(name: "Helvetica", size: 13)!, .paragraphStyle: style])
        }
        let input = NSMutableAttributedString()
        input.append(cell("Dill", 0))
        input.append(cell("Teal lid", 1))
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        input.append(NSAttributedString(string: "Shadowed black text\n", attributes: [
            .font: NSFont(name: "Georgia", size: 31)!, .shadow: shadow, .kern: 2, .foregroundColor: NSColor.black,
            .baselineOffset: 3, .link: "javascript:alert(1)",
        ]))
        let listStyle = NSMutableParagraphStyle()
        listStyle.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        input.append(NSAttributedString(string: "\t\u{2022}\tListed\n", attributes: [.font: NSFont(name: "Helvetica", size: 13)!, .paragraphStyle: listStyle]))
        input.append(NSAttributedString(string: "Teal\n", attributes: [.font: NSFont(name: "Verdana", size: 13)!,
                                                                     .foregroundColor: NSColor(calibratedRed: 0.07, green: 0.5, blue: 0.55, alpha: 1)]))
        let out = ComposerDocument.normalize(input, defaults: d)
        T.equal(out.string, "Dill\tTeal lid\nShadowed black text\nListed\nTeal\n", "table cells become tabs; marker text goes")
        var keys = Set<String>()
        out.enumerateAttributes(in: NSRange(location: 0, length: out.length)) { a, _, _ in a.keys.forEach { keys.insert($0.rawValue) } }
        T.check(!keys.contains(NSAttributedString.Key.shadow.rawValue) && !keys.contains(NSAttributedString.Key.kern.rawValue)
                && !keys.contains(NSAttributedString.Key.baselineOffset.rawValue), "shadows, kerning and baseline offsets dropped")
        T.check(out.attribute(.foregroundColor, at: 14, effectiveRange: nil) == nil, "explicit black dropped")
        T.check(out.attribute(.link, at: 14, effectiveRange: nil) == nil, "javascript: link dropped")
        T.check(out.attribute(.foregroundColor, at: out.length - 3, effectiveRange: nil) != nil, "a real colour stays")
        T.equal(font(out, 0).pointSize, 14, "13 pt snaps to Normal (14)")
        T.equal(font(out, 14).pointSize, 31, "31 pt is kept (not near a choice)")
        T.equal(font(out, 14).familyName, "Georgia", "the face is kept")
        T.check((out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == true, "no table blocks left")
        T.equal(lists(out, 34).count, 1, "lists are kept")
        T.equal([SizeChoice.snap(13), SizeChoice.snap(11), SizeChoice.snap(17), SizeChoice.snap(25), SizeChoice.snap(5), SizeChoice.snap(100),
                 SizeChoice.snap(30)], [14, 12, 18, 24, 8, 72, 30], "size snapping (clamp 8…72, within 1 pt, ties to Normal)")
        let spaced = NSMutableParagraphStyle()
        spaced.paragraphSpacing = 40
        let s2 = ComposerDocument.normalize(NSAttributedString(string: "x\n", attributes: [.paragraphStyle: spaced]), defaults: d)
        T.equal((s2.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing, 0, "spacing outside 0…24 dropped")
        let attachment = NSTextAttachment()
        let withImage = NSAttributedString(attachment: attachment)
        T.equal(ComposerDocument.normalize(withImage, defaults: d).length, 0, "attachments dropped unless images are allowed")
    }

    static func formattingState() {
        T.section("Rich mail: composer toolbar state")
        let m = doc("plain bold\nnext\n")
        ComposerDocument.apply(.bold, to: m, selection: NSRange(location: 6, length: 4), defaults: d)
        let mixed = ComposerDocument.formatting(m, selection: NSRange(location: 0, length: 10), typing: [:], defaults: d)
        T.equal(mixed.bold, .mixed, "mixed selection: bold shows a dash")
        T.equal(mixed.italic, .off, "italic off")
        T.equal(mixed.font, .sans, "one face: Sans Serif")
        T.equal(mixed.size, 14, "one size")
        let boldOnly = ComposerDocument.formatting(m, selection: NSRange(location: 6, length: 4), typing: [:], defaults: d)
        T.equal(boldOnly.bold, .on, "bold selection")
        ComposerDocument.apply(.size(.large), to: m, selection: NSRange(location: 0, length: 3), defaults: d)
        T.equal(ComposerDocument.formatting(m, selection: NSRange(location: 0, length: 10), typing: [:], defaults: d).size, nil, "mixed sizes")
        T.equal(ComposerDocument.formatting(m, selection: NSRange(location: 0, length: 10), typing: [:], defaults: d).sizeLabel, "\u{2014}", "…label dash")
        ComposerDocument.apply(.list(.number), to: m, selection: NSRange(location: 0, length: 12), defaults: d)
        let both = ComposerDocument.formatting(m, selection: NSRange(location: 0, length: 12), typing: [:], defaults: d)
        T.check(both.list == .number && both.listDepth == 1 && both.canOutdent, "numbered list state")
        T.check(!ComposerDocument.hasFormatting(ComposerDocument.plain("just text\n")), "plain text has no formatting")
        T.check(ComposerDocument.hasFormatting(m), "lists and bold count as formatting")
    }

    // MARK: ComposerModel compatibility

    static func composer(_ request: ComposerRequest, format: ComposerFormat? = nil, local: MailLocalStore = MemoryMailLocalStore(),
                         prefs: FakeMailPreferences = RichComposerFixtures.prefs()) -> (ComposerModel, FakeMailActions) {
        let actions = FakeMailActions(store: FakeMailStore())
        let model = ComposerModel(request: request, accounts: RichComposerFixtures.directory().accounts, safeSend: false,
                                  actions: { actions }, prefs: { prefs }, local: local, clock: { now }, schedule: { _, _ in },
                                  toasts: MailToastCenter(clock: { now }, schedule: { _, _ in }), format: format)
        return (model, actions)
    }

    static func modelCompatibility() {
        T.section("Rich mail: composer body bridge")
        let juniper = RichComposerFixtures.juniperMessage(now: now)
        let (reply, _) = composer(RichComposerFixtures.juniperReply(now: now))
        T.equal(reply.format, .rich, "rich by default")
        T.equal(reply.from, RichMailCast.orb.id, "reply from the account that got it")
        let expected = ComposerText.initialBody(signature: RichComposerFixtures.orbPlainSignature, quote: ComposerText.quote(juniper))
        T.equal(reply.body, expected, "reply: body byte-identical to initialBody (signature + > quote)")
        T.equal(reply.document.string, "\n\n" + RichComposerFixtures.orbPlainSignature + "\n", "the document holds the text and signature only")
        T.check(reply.quote?.message == juniper, "the original is shown read-only")
        T.equal(reply.quote?.attribution, ComposerText.quote(juniper).components(separatedBy: "\n").first, "one attribution formatter")
        T.equal(ComposerDocument.signatureRange(reply.document), NSRange(location: 2, length: RichComposerFixtures.orbPlainSignature.count),
                "the signature is marked")
        let sigFont = reply.document.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        T.check(MailRichText.isBold(sigFont), "Orbital Pickle Co.'s rich signature keeps its bold name")

        let (new, _) = composer(.new(from: RichMailCast.cmt.id))
        T.equal(new.body, ComposerText.initialBody(signature: RichComposerFixtures.cometsSignature, quote: nil), "new: body byte-identical")
        let (bare, _) = composer(.new(from: RichMailCast.home.id))
        T.equal(bare.body, "\n\n", "no signature, no quote")

        // The render harness's round trip: m.body = "x\n" + m.body.
        let old = reply.body
        reply.body = "Thanks Juniper, teal it is.\n" + reply.body
        T.equal(reply.body, "Thanks Juniper, teal it is.\n" + old, "setter round trip keeps the quote outside")
        T.check(reply.quote != nil, "…and the original stays shown")
        T.check(ComposerDocument.signatureRange(reply.document) != nil, "…and the signature is re-marked")
        T.check(MailRichText.isBold(reply.document.attribute(.font, at: (reply.document.string as NSString).range(of: "Avery").location,
                                                             effectiveRange: nil) as? NSFont), "…with its formatting")
        T.check(reply.documentRevision > 0, "setting body replaces the document (the editor reloads it)")

        // From switch: by mark, then by string once the marks are gone.
        reply.changeFrom(RichMailCast.cmt.id)
        T.check(reply.body.contains(RichComposerFixtures.cometsSignature) && !reply.body.contains("Orbital Pickle Co. \u{00B7}"),
                "switching From swaps the rich signature by its mark")
        let unmarked = NSMutableAttributedString(attributedString: reply.document)
        unmarked.removeAttribute(.ycSignature, range: NSRange(location: 0, length: unmarked.length))
        reply.editorChanged(unmarked)
        reply.changeFrom(RichMailCast.fam.id)
        T.check(reply.body.contains("\nAvery\n") && !reply.body.contains("The Quiet Comets"), "…and by string after the marks are deleted")
        reply.changeFrom(RichMailCast.home.id)
        T.check(!reply.body.contains("\nAvery\n"), "to an account with no signature: removed")
        reply.changeFrom(RichMailCast.cmt.id)
        T.check(reply.body.hasPrefix("Thanks Juniper, teal it is.\n"), "typed text survives every swap")

        // Plain mode is today's composer exactly.
        let (plain, _) = composer(RichComposerFixtures.juniperReply(now: now), format: .plain)
        T.equal(plain.body, expected, "plain: same body")
        T.equal(plain.quote, nil, "plain: the > quote is in the body")
        let local = MemoryMailLocalStore()
        local.setString("true", RichMailSettings.plainTextOnlyKey)
        let (setting, _) = composer(.new(from: RichMailCast.orb.id), local: local)
        T.equal(setting.format, .plain, "Settings → Send plain text only opens plain composers")
    }

    static func modelDrafts() async {
        T.section("Rich mail: composer drafts")
        let (reply, actions) = composer(RichComposerFixtures.juniperReply(now: now))
        reply.body = "Teal it is.\n" + reply.body
        guard case .success(let draft) = reply.draft() else { T.check(false, "rich reply builds"); return }
        T.equal(draft.from, RichMailCast.orb.id, "draft from")
        T.equal(draft.to, [RichMailCast.juniper.email], "draft to")
        T.equal(draft.subject, "Re: Pickle jar labels", "draft subject")
        T.equal(draft.replyTo, RichMailThreads.gmailReply.r, "draft answers the thread")
        T.check(draft.signatureIncluded, "signature included (never appended again)")
        T.equal(draft.quote, MailQuoteRequest(threadR: RichMailThreads.gmailReply.r, messageId: RichComposerFixtures.juniperMessage(now: now).id,
                                              kind: .reply, style: .bar), "quote request for the data layer")
        T.check(draft.html?.hasPrefix("<div dir=\"auto\" style=\"font-family:Helvetica, Arial, sans-serif;font-size:14px\">") == true, "html wrapper")
        T.check(draft.html?.contains("<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">") == true, "html signature wrapper")
        T.check(draft.html?.contains("<b>Avery Moonfield</b>") == true, "the signature's bold name")
        T.check(draft.html?.contains("wrote:") == false, "the original isn't in the html (the data layer adds it)")
        T.equal(draft.body, "Teal it is.\n\n\n-- \n" + RichComposerFixtures.orbPlainSignature + " <https://orbitalpickle.example>\n",
                "text/plain: your text, \"-- \", the signature (its link as text <url>)")
        T.check(draft.attachments.isEmpty, "no attachments")
        await reply.send()
        T.equal(actions.sent.first?.html, draft.html, "send hands the rich draft over")

        let (plain, _) = composer(RichComposerFixtures.juniperReply(now: now), format: .plain)
        guard case .success(let p) = plain.draft() else { T.check(false, "plain reply builds"); return }
        T.check(p.html == nil && p.quote == nil && p.signatureIncluded, "plain draft: no html, quote in the body")
        T.equal(p.body, plain.body, "plain draft body is the body")

        let (removed, _) = composer(RichComposerFixtures.juniperReply(now: now))
        removed.removeQuote()
        T.equal(removed.quote, nil, "Remove")
        guard case .success(let r) = removed.draft() else { T.check(false, "builds"); return }
        T.equal(r.quote, nil, "removed quote: no quote request")
        T.equal(removed.body, removed.document.string, "body without the original")
        removed.restoreQuote()
        T.check(removed.quote != nil, "Undo puts it back")

        let (new, _) = composer(.new(from: RichMailCast.cmt.id))
        new.to = RichMailCast.priya.display
        new.subject = "Tour poster"
        guard case .success(let n) = new.draft() else { T.check(false, "new builds"); return }
        T.check(n.quote == nil && n.replyTo == nil && n.html != nil, "new rich mail: html, no quote")
        let (empty, _) = composer(.new(from: RichMailCast.home.id))
        empty.to = RichMailCast.theo.email
        if case .failure(let problem) = empty.draft() { T.equal(problem, .empty, "an empty rich draft is still empty") } else { T.check(false, "empty") }
    }

    static func modelEditing() {
        T.section("Rich mail: composer editing without an editor")
        let (m, _) = composer(.new(from: RichMailCast.cmt.id))
        m.to = RichMailCast.priya.email
        m.body = "Tour dates\n" + m.body
        let sel = m.apply(.bold, range: NSRange(location: 0, length: 4))
        T.equal(sel, NSRange(location: 0, length: 4), "apply returns the selection")
        T.equal(m.formatting.bold, .on, "toolbar follows")
        guard case .success(let draft) = m.draft() else { T.check(false, "builds"); return }
        T.check(draft.html?.contains("<b>Tour</b> dates") == true, "bold reaches the html")
        T.check(m.plainSwitchLosesFormatting, "Make Plain Text would lose the bold (asks first)")
        m.togglePlainText()
        T.equal(m.format, .plain, "Make Plain Text")
        T.check(m.body.hasPrefix("Tour dates\n") && !m.body.contains("-- "), "flattened text, no -- line added")
        m.togglePlainText()
        T.equal(m.format, .rich, "Make Rich Text")
        T.check(ComposerDocument.signatureRange(m.document) != nil, "signature re-marked")

        let (r, _) = composer(RichComposerFixtures.juniperReply(now: now))
        r.togglePlainText()
        T.check(r.body.contains("> Hi Avery,") && r.quote == nil, "plain: the original joins the body as > lines")
        r.togglePlainText()
        T.check(r.quote != nil && !r.document.string.contains("> Hi Avery"), "rich again: the original goes back under the editor")

        // Edit quoted text: the converted original lands as a quote block under its attribution.
        let converted = NSMutableAttributedString(attributedString: ComposerDocument.plain("Hi Avery,\n\nProofs are due Thursday.\n"))
        r.makeQuoteEditable(converted)
        T.equal(r.quote, nil, "the read-only block goes")
        T.check(r.document.string.contains("wrote:\nHi Avery,"), "attribution, then the original")
        let at = (r.document.string as NSString).range(of: "Proofs").location
        T.equal(r.document.attribute(.ycQuoteBlock, at: at, effectiveRange: nil) as? Int, 1, "…as a quote block")
        guard case .success(let draft2) = r.draft() else { T.check(false, "builds"); return }
        T.check(draft2.quote == nil && draft2.html?.contains("<blockquote") == true, "edited quote travels in the html, no quote request")

        // Link popover.
        let (l, _) = composer(.new(from: RichMailCast.cmt.id))
        l.body = "Set list here\n" + l.body
        l.editorSelected(NSRange(location: 4, length: 4), typing: [:])
        l.beginLink()
        T.equal(l.linkDraft?.text, "list", "popover text = the selection")
        T.equal(l.popover, .link, "popover open")
        T.equal(l.commitLink(text: "list", url: "ftp://quietcomets.example"), ComposerLinkDraft.problem, "ftp refused")
        T.equal(l.commitLink(text: "list", url: "quietcomets.example/setlist"), nil, "added")
        T.equal(l.document.attribute(.link, at: 5, effectiveRange: nil) as? String, "https://quietcomets.example/setlist", "link on the selection")
        T.equal(l.popover, nil, "popover closed")
        T.equal(l.document.string.prefix(13), "Set list here", "text unchanged")
    }

    // MARK: Settings → Writing

    static func settings() {
        T.section("Rich mail: Settings → Writing")
        T.equal(RichMailSettings.defaults.map(\.key), ["mail.compose.fontFamily", "mail.compose.fontSize", "mail.compose.plainTextOnly",
                                                        "mail.compose.quoteStyle", "mail.attachments.saveFolder", "mail.images.fromCorrespondents"],
                "keys (none under labs.*)")
        T.equal(RichMailSettings.defaults.map(\.value), ["sans", "14", "false", "bar", "", "false"], "defaults")
        let local = MemoryMailLocalStore()
        let fresh = RichMailSettings(local: local)
        T.check(fresh == RichMailSettings(), "nothing stored: the defaults")
        T.equal(fresh.font.css.stack, "Helvetica, Arial, sans-serif", "Sans Serif = Helvetica → Arial")
        local.setString("wingdings", RichMailSettings.fontFamilyKey)
        local.setString("13", RichMailSettings.fontSizeKey)
        local.setString("maybe", RichMailSettings.plainTextOnlyKey)
        local.setString("fancy", RichMailSettings.quoteStyleKey)
        T.check(RichMailSettings(local: local) == RichMailSettings(), "garbage reads as the defaults")
        var s = RichMailSettings()
        s.font = .serif; s.size = .large; s.plainTextOnly = true; s.quoteStyle = .header; s.saveFolder = "~/Pickles"; s.imagesFromCorrespondents = true
        s.save(to: local)
        T.equal(RichMailSettings(local: local), s, "round trip")

        let downloads = URL(fileURLWithPath: "/Users/you/Downloads", isDirectory: true)
        T.equal(RichMailSettings().saveFolder(downloads: downloads, usable: { _ in true }).url, downloads, "save folder: Downloads by default")
        var chosen = RichMailSettings()
        chosen.saveFolder = "/Volumes/Lake house/Mail"
        T.equal(chosen.saveFolder(downloads: downloads, usable: { _ in true }).url.path, "/Volumes/Lake house/Mail", "the chosen folder")
        let gone = chosen.saveFolder(downloads: downloads, usable: { _ in false })
        T.check(gone.url == downloads && gone.note?.contains("Mail") == true, "missing folder → Downloads, with a note")

        let prefs = RichComposerFixtures.prefs()
        let m = SettingsMailModel(prefs: { prefs }, directory: { RichComposerFixtures.directory() }, local: local, safeSend: { true }, setSafeSend: { _ in })
        T.equal(m.writing, s, "Settings reads Writing")
        m.setWritingFont(.mono)
        m.setWritingSize(.small)
        m.setPlainTextOnly(false)
        m.setQuoteStyle(.bar)
        T.equal(RichMailSettings(local: local).font, .mono, "font saved")
        T.equal(local.string(RichMailSettings.fontSizeKey), "12", "size saved as px")
        T.equal(RichMailSettings(local: local).plainTextOnly, false, "plain only saved")
        T.equal(RichMailSettings.quoteStyleTitle(.header), "Header above the quote", "quote style title")
        let (composerAfter, _) = composer(.new(from: RichMailCast.cmt.id), local: local)
        T.equal(composerAfter.rendered().html.hasPrefix("<div dir=\"auto\" style=\"font-family:Menlo, Monaco, Consolas, &quot;Courier New&quot;, monospace;font-size:12px\">"),
                true, "new composers write in the new default")
    }

    /// "Images from people you've written to": off forgets everyone it recorded, after the key is saved off.
    static func correspondentsOff() {
        T.section("Rich mail: Settings → images from people you've written to, off clears the list")
        let prefs = RichComposerFixtures.prefs()
        let local = MemoryMailLocalStore()
        let m = SettingsMailModel(prefs: { prefs }, directory: { RichComposerFixtures.directory() }, local: local,
                                  safeSend: { true }, setSafeSend: { _ in })
        var keyWhenCleared: String?
        prefs.onForget = { keyWhenCleared = local.string(RichMailSettings.imagesFromCorrespondentsKey) }
        m.setImagesFromCorrespondents(true)
        T.check(m.writing.imagesFromCorrespondents && prefs.forgets == 0, "on: saved, nothing cleared")
        prefs.correspondents = ["kofi@ember.example", "ines@marlowe.example"]   // recorded while on
        m.setImagesFromCorrespondents(false)
        T.equal(prefs.forgets, 1, "off: the store is told to forget them")
        T.check(prefs.correspondents.isEmpty, "off: nobody left")
        T.equal(keyWhenCleared, "false", "the key is saved off before the clear")
        m.setImagesFromCorrespondents(true)
        T.check(m.writing.imagesFromCorrespondents && prefs.forgets == 1 && prefs.correspondents.isEmpty, "on again: starts empty")
        prefs.forgetError = ServiceError(description: "disk full")
        m.setImagesFromCorrespondents(false)
        T.check(m.failed && m.status?.contains("next time I start") == true, "a failed clear says it will retry")
        T.equal(local.string(RichMailSettings.imagesFromCorrespondentsKey), "false", "…and the setting still goes off")
    }

    static func richSignatures() {
        T.section("Rich mail: rich signatures")
        let prefs = RichComposerFixtures.prefs()
        let m = SettingsMailModel(prefs: { prefs }, directory: { RichComposerFixtures.directory() }, local: MemoryMailLocalStore(),
                                  safeSend: { true }, setSafeSend: { _ in })
        m.load()
        guard let orb = m.rows.first(where: { $0.id == RichMailCast.orb.id }), let cmt = m.rows.first(where: { $0.id == RichMailCast.cmt.id }) else {
            T.check(false, "rows"); return
        }
        T.check(MailRichText.isBold(orb.signatureRich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont), "a stored rich signature loads rich")
        T.equal(cmt.signatureRich.string, RichComposerFixtures.cometsSignature, "lazy migration: the plain one in the default font")
        T.check(!cmt.isDirty && !orb.isDirty, "clean after load")

        // Edit The Quiet Comets' signature in the rich editor: dirty, save writes both forms.
        let edited = NSMutableAttributedString(attributedString: cmt.signatureRich)
        edited.addAttribute(.foregroundColor, value: ComposerDocument.color(0xE8710A), range: NSRange(location: 16, length: 16))
        m.editRichSignature(cmt.id, edited)
        T.check(m.rows.first { $0.id == cmt.id }?.isDirty == true, "a colour change is dirty")
        m.saveSignature(cmt.id)
        let saved = prefs.stored[RichMailCast.cmt.id]
        T.equal(saved?.signature, RichComposerFixtures.cometsSignature, "plain rendition saved")
        T.check(saved?.signatureRich != nil, "rich form saved (it has formatting)")
        let back = RichSignature.load(saved!)
        T.equal(ComposerDocument.hex(back.attribute(.foregroundColor, at: 20, effectiveRange: nil)), 0xE8710A, "RTFD round trip keeps the colour")
        T.check(m.rows.first { $0.id == cmt.id }?.isDirty == false, "clean after save")

        // Revert.
        let again = NSMutableAttributedString(attributedString: edited)
        again.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Captain")
        m.editRichSignature(cmt.id, again)
        T.equal(m.rows.first { $0.id == cmt.id }?.signature.hasPrefix("Captain"), true, "plain form follows the rich editor")
        m.revertSignature(cmt.id)
        T.check(m.rows.first { $0.id == cmt.id }?.isDirty == false, "Undo changes reverts both")

        // A plain edit stays lazy (no rich data).
        m.editSignature(RichMailCast.fam.id, "Avery\nThe lake house")
        m.saveSignature(RichMailCast.fam.id)
        T.equal(prefs.stored[RichMailCast.fam.id]?.signature, "Avery\nThe lake house", "plain edit saved")
        T.equal(prefs.stored[RichMailCast.fam.id]?.signatureRich, nil, "no formatting: no rich data (stays lazy)")
        m.setPrimaryOnly(RichMailCast.orb.id, true)
        T.check(prefs.stored[RichMailCast.orb.id]?.signatureRich != nil, "Primary only keeps the rich signature")

        // 512 KB cap.
        var bytes = [UInt8](repeating: 0, count: 600 * 1024)
        var seed = SeededRandom(42)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: seed.next()) }
        let wrapper = FileWrapper(regularFileWithContents: Data([0x89, 0x50, 0x4E, 0x47] + bytes))
        wrapper.preferredFilename = "huge-logo.png"
        let huge = NSMutableAttributedString(attributedString: ComposerDocument.plain("Avery "))
        huge.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        if case .failure(.tooLarge(let n)) = RichSignature.storable(huge) {
            T.check(n > RichSignature.maxBytes, "over 512 KB is refused")
        } else {
            T.check(false, "over 512 KB is refused")
        }
        let savesBefore = prefs.saves.count
        m.editRichSignature(RichMailCast.home.id, huge)
        m.saveSignature(RichMailCast.home.id)
        T.check(m.failed && prefs.saves.count == savesBefore, "Settings says so and saves nothing")
        T.check(m.status?.contains("512 KB") == true, "…naming the limit")
    }
}
