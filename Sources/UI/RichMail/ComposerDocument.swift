import AppKit

// The rich composer's document model (D-042): font and size choices, the default attributes
// (never a foreground colour: the sheet is white and recipients' clients pick their own black), the formatting
// operations as pure functions on an NSMutableAttributedString (each returns the new selection, and the editor wraps
// them in one undo group), paste normalization and the toolbar's formatting state. TextKit 2
// conventions: list markers are drawn by layout and never live in the text; lists that number together share one
// NSTextList instance; quote blocks are `ycQuoteBlock` paragraphs with a head indent, their bars drawn by the editor.
// Pure: Foundation and AppKit types only, compiled into the shell tests.

/// The writing font (Settings → Writing → Default font; the toolbar's font menu).
enum FontChoice: String, CaseIterable, Equatable {
    case sans, system, serif, times, verdana, trebuchet, mono

    var css: FontChoiceCSS { FontChoiceCSS.choice(key: rawValue) ?? .sans }
    var family: String { css.family }

    var title: String {
        switch self {
        case .sans: return "Sans Serif"
        case .system: return "System"
        case .serif: return "Serif"
        case .times: return "Times New Roman"
        case .verdana: return "Verdana"
        case .trebuchet: return "Trebuchet"
        case .mono: return "Monospace"
        }
    }

    static func from(family: String?) -> FontChoice? {
        guard let family, let css = FontChoiceCSS.choice(family: family) else { return nil }
        return FontChoice(rawValue: css.key)
    }

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        MailRichText.font(family: family, size: size, bold: bold, italic: italic)
    }
}

/// The four writing sizes. The editor's points equal CSS pixels.
enum SizeChoice: Int, CaseIterable, Equatable {
    case small = 12, normal = 14, large = 18, huge = 24

    var title: String {
        switch self {
        case .small: return "Small"
        case .normal: return "Normal"
        case .large: return "Large"
        case .huge: return "Huge"
        }
    }

    var points: CGFloat { CGFloat(rawValue) }

    /// Paste: clamp to 8…72, then snap to a choice within 1 pt (ties go to Normal).
    static func snap(_ size: CGFloat) -> CGFloat {
        let clamped = max(8, min(72, size.rounded()))
        let preference: [SizeChoice] = [.normal, .small, .large, .huge]
        if let near = preference.filter({ abs($0.points - clamped) <= 1 }).min(by: { abs($0.points - clamped) < abs($1.points - clamped) }) {
            return near.points
        }
        return clamped
    }

    /// Bigger / Smaller: the next choice above or below `size` (nil at the ends).
    static func step(from size: CGFloat, up: Bool) -> SizeChoice? {
        up ? allCases.first { $0.points > size + 0.5 } : allCases.last { $0.points < size - 0.5 }
    }

    static func exact(_ size: CGFloat) -> SizeChoice? { allCases.first { abs($0.points - size) < 0.5 } }
}

/// What the toolbar and the Format menu show for the selection (a mixed selection shows a dash).
struct FormattingState: Equatable {
    enum Tri: Equatable { case off, on, mixed }

    var bold: Tri = .off
    var italic: Tri = .off
    var underline: Tri = .off
    var strikethrough: Tri = .off
    /// One of the seven choices; nil = mixed or another family (`familyName` says which).
    var font: FontChoice? = .sans
    var familyName: String? = FontChoice.sans.family
    /// nil = mixed sizes.
    var size: Int? = SizeChoice.normal.rawValue
    var list: ComposerDocument.ListKind?
    var listMixed = false
    var listDepth = 0
    var quote: Tri = .off
    var indent = 0
    /// `#rrggbb` of an explicit colour; nil = the default colour (or mixed: `colorMixed`).
    var color: UInt32?
    var colorMixed = false
    var highlight: UInt32?
    var link: String?
    var selectionLength = 0

    var canOutdent: Bool { listDepth > 0 || indent > 0 }
    var fontLabel: String { font?.title ?? familyName ?? "\u{2014}" }
    var sizeLabel: String { size.flatMap { SizeChoice(rawValue: $0)?.title ?? "\($0) px" } ?? "\u{2014}" }
}

enum ComposerDocument {
    enum ListKind: Equatable { case bullet, number }

    /// Every toolbar and Format-menu operation.
    enum Op: Equatable {
        case bold, italic, underline, strikethrough
        case font(FontChoice)
        case size(SizeChoice)
        case bigger, smaller
        /// `#rrggbb`; nil = back to the default colour.
        case color(UInt32?)
        case highlight(UInt32?)
        case list(ListKind)
        case indent, outdent
        case quote
        /// nil removes the link; the text stays.
        case link(String?)
        /// Replaces the selection with linked text (the link popover with new text).
        case insertLink(text: String, url: String)
        case clearFormatting

        /// Undo menu: "Undo Bold", "Undo Numbered List"…
        var actionName: String {
            switch self {
            case .bold: return "Bold"
            case .italic: return "Italic"
            case .underline: return "Underline"
            case .strikethrough: return "Strikethrough"
            case .font: return "Font"
            case .size, .bigger, .smaller: return "Text Size"
            case .color: return "Text Colour"
            case .highlight: return "Highlight"
            case .list(.bullet): return "Bulleted List"
            case .list(.number): return "Numbered List"
            case .indent: return "Increase Indent"
            case .outdent: return "Decrease Indent"
            case .quote: return "Quote Block"
            case .link(let url): return url == nil ? "Remove Link" : "Add Link"
            case .insertLink: return "Add Link"
            case .clearFormatting: return "Clear Formatting"
            }
        }

        /// Acts on characters (with a caret: on the typing attributes) rather than whole paragraphs.
        var isCharacterOp: Bool {
            switch self {
            case .list, .indent, .outdent, .quote, .clearFormatting: return false
            default: return true
            }
        }
    }

    struct Defaults: Equatable {
        var font: FontChoice = .sans
        var size: SizeChoice = .normal

        var css: FontChoiceCSS { font.css }
        var baseFont: NSFont { font.font(size: size.points) }
    }

    /// The paragraph style every new paragraph gets: no spacing, line height 1.15.
    static func defaultParagraphStyle() -> NSParagraphStyle {
        MailRichText.paragraphStyle(base: nil, indent: 0, quote: 0, lists: [])
    }

    /// Font and paragraph style; never a foreground colour (the sheet draws default black, the writer emits none).
    static func defaultAttributes(font: FontChoice, size: SizeChoice) -> [NSAttributedString.Key: Any] {
        [.font: font.font(size: size.points), .paragraphStyle: defaultParagraphStyle()]
    }

    static func defaultAttributes(_ d: Defaults) -> [NSAttributedString.Key: Any] { defaultAttributes(font: d.font, size: d.size) }

    // MARK: Applying operations

    struct Result: Equatable {
        /// Where the selection goes.
        var selection: NSRange
        /// New typing attributes, when the caret's typing style changed (nil = keep what the text view derives).
        var typing: [NSAttributedString.Key: Any]?

        static func == (a: Result, b: Result) -> Bool {
            a.selection == b.selection && (a.typing == nil) == (b.typing == nil)
                && NSDictionary(dictionary: a.typing ?? [:]).isEqual(to: b.typing ?? [:])
        }
    }

    /// The range the editor registers for undo before applying `op` (whole paragraphs for paragraph ops).
    static func affectedRange(_ op: Op, in doc: NSAttributedString, selection: NSRange) -> NSRange {
        let sel = clamp(selection, doc.length)
        if op.isCharacterOp { return sel }
        return (doc.string as NSString).paragraphRange(for: sel)
    }

    /// The replacement text an op inserts (nil = attributes only).
    static func replacementString(_ op: Op) -> String? {
        if case .insertLink(let text, _) = op { return text }
        return nil
    }

    /// Applies `op` to `doc` for `selection`. Character ops with a caret only change the typing attributes.
    @discardableResult
    static func apply(_ op: Op, to doc: NSMutableAttributedString, selection: NSRange,
                      typing: [NSAttributedString.Key: Any] = [:], defaults: Defaults = Defaults()) -> Result {
        let sel = clamp(selection, doc.length)
        var typing = typing.isEmpty ? attributesAtCaret(doc, sel.location, defaults: defaults) : typing
        switch op {
        case .insertLink(let text, let url):
            guard let target = composerLink(url) else { return Result(selection: sel, typing: nil) }
            var attrs = sel.length > 0 ? doc.attributes(at: sel.location, effectiveRange: nil) : typing
            attrs[.link] = target
            attrs[.attachment] = nil
            let inserted = NSAttributedString(string: text, attributes: attrs)
            doc.replaceCharacters(in: sel, with: inserted)
            var after = attrs
            after[.link] = nil
            return Result(selection: NSRange(location: sel.location + inserted.length, length: 0), typing: after)
        case .clearFormatting:
            clear(doc, sel, defaults: defaults)
            typing = clearedTyping(typing, defaults: defaults)
            if sel.length == 0 { paragraphTyping(doc, sel.location, into: &typing, defaults: defaults) }
            return Result(selection: sel, typing: sel.length == 0 ? typing : nil)
        case .list, .indent, .outdent, .quote:
            paragraphOp(op, doc, sel, defaults: defaults)
            if sel.length == 0 {
                paragraphTyping(doc, sel.location, into: &typing, defaults: defaults, op: op)
                return Result(selection: sel, typing: typing)
            }
            return Result(selection: sel, typing: nil)
        default:
            if sel.length == 0 {
                return Result(selection: sel, typing: characterOp(op, typing: typing, defaults: defaults))
            }
            characterOp(op, doc, sel, defaults: defaults)
            return Result(selection: sel, typing: nil)
        }
    }

    static func clamp(_ range: NSRange, _ length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: max(0, min(range.length, length - location)))
    }

    /// The attributes a caret at `location` types with: the character before it (as NSTextView does), else after,
    /// else the defaults.
    static func attributesAtCaret(_ doc: NSAttributedString, _ location: Int, defaults: Defaults) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any]
        if location > 0, location - 1 < doc.length, (doc.string as NSString).character(at: location - 1) != 0x0A {
            attrs = doc.attributes(at: location - 1, effectiveRange: nil)
        } else if location < doc.length {
            attrs = doc.attributes(at: location, effectiveRange: nil)
        } else if location > 0, location - 1 < doc.length {
            attrs = doc.attributes(at: location - 1, effectiveRange: nil)
        } else {
            attrs = defaultAttributes(defaults)
        }
        attrs[.attachment] = nil
        attrs[.ycInlineImage] = nil
        attrs[.link] = nil
        return attrs
    }

    // MARK: Character operations

    private static func font(_ value: Any?, _ defaults: Defaults) -> NSFont { (value as? NSFont) ?? defaults.baseFont }

    private static func all(_ doc: NSAttributedString, _ range: NSRange, _ test: ([NSAttributedString.Key: Any]) -> Bool) -> Bool {
        var result = true
        doc.enumerateAttributes(in: range) { attrs, _, stop in
            if attrs[.attachment] != nil { return }
            if !test(attrs) { result = false; stop.pointee = true }
        }
        return result
    }

    private static func isOn(_ value: Any?) -> Bool {
        ((value as? Int) ?? (value as? NSNumber)?.intValue ?? 0) != 0
    }

    private static func characterOp(_ op: Op, _ doc: NSMutableAttributedString, _ range: NSRange, defaults: Defaults) {
        doc.beginEditing()
        defer { doc.endEditing() }
        switch op {
        case .bold, .italic:
            let bold = op == .bold
            let on = !all(doc, range) { bold ? MailRichText.isBold(font($0[.font], defaults)) : MailRichText.isItalic(font($0[.font], defaults)) }
            mapFonts(doc, range, defaults) { f in
                MailRichText.font(family: f.familyName ?? defaults.font.family, size: f.pointSize,
                                  bold: bold ? on : MailRichText.isBold(f), italic: bold ? MailRichText.isItalic(f) : on)
            }
        case .underline, .strikethrough:
            let key: NSAttributedString.Key = op == .underline ? .underlineStyle : .strikethroughStyle
            if all(doc, range, { isOn($0[key]) }) {
                doc.removeAttribute(key, range: range)
            } else {
                doc.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        case .font(let choice):
            mapFonts(doc, range, defaults) { f in
                choice.font(size: f.pointSize, bold: MailRichText.isBold(f), italic: MailRichText.isItalic(f))
            }
        case .size(let size):
            mapFonts(doc, range, defaults) { f in resized(f, size.points, defaults) }
        case .bigger, .smaller:
            let current = font(doc.attribute(.font, at: range.location, effectiveRange: nil), defaults).pointSize
            guard let next = SizeChoice.step(from: current, up: op == .bigger) else { return }
            mapFonts(doc, range, defaults) { f in resized(f, next.points, defaults) }
        case .color(let hex):
            if let hex { doc.addAttribute(.foregroundColor, value: color(hex), range: range) } else { doc.removeAttribute(.foregroundColor, range: range) }
        case .highlight(let hex):
            if let hex { doc.addAttribute(.backgroundColor, value: color(hex), range: range) } else { doc.removeAttribute(.backgroundColor, range: range) }
        case .link(let url):
            if let url, let target = composerLink(url) {
                doc.addAttribute(.link, value: target, range: range)
            } else {
                doc.removeAttribute(.link, range: range)
            }
        default:
            break
        }
    }

    /// The same operation on typing attributes (a caret: what you type next).
    private static func characterOp(_ op: Op, typing: [NSAttributedString.Key: Any], defaults: Defaults) -> [NSAttributedString.Key: Any] {
        var t = typing
        let f = font(t[.font], defaults)
        switch op {
        case .bold:
            t[.font] = MailRichText.font(family: f.familyName ?? defaults.font.family, size: f.pointSize, bold: !MailRichText.isBold(f), italic: MailRichText.isItalic(f))
        case .italic:
            t[.font] = MailRichText.font(family: f.familyName ?? defaults.font.family, size: f.pointSize, bold: MailRichText.isBold(f), italic: !MailRichText.isItalic(f))
        case .underline:
            t[.underlineStyle] = isOn(t[.underlineStyle]) ? nil : NSUnderlineStyle.single.rawValue
        case .strikethrough:
            t[.strikethroughStyle] = isOn(t[.strikethroughStyle]) ? nil : NSUnderlineStyle.single.rawValue
        case .font(let choice):
            t[.font] = choice.font(size: f.pointSize, bold: MailRichText.isBold(f), italic: MailRichText.isItalic(f))
        case .size(let size):
            t[.font] = resized(f, size.points, defaults)
        case .bigger, .smaller:
            if let next = SizeChoice.step(from: f.pointSize, up: op == .bigger) { t[.font] = resized(f, next.points, defaults) }
        case .color(let hex):
            t[.foregroundColor] = hex.map(color)
        case .highlight(let hex):
            t[.backgroundColor] = hex.map(color)
        case .link(let url):
            t[.link] = url.flatMap(composerLink)
        default:
            break
        }
        return t
    }

    private static func mapFonts(_ doc: NSMutableAttributedString, _ range: NSRange, _ defaults: Defaults, _ transform: (NSFont) -> NSFont) {
        var changes: [(NSRange, NSFont)] = []
        doc.enumerateAttribute(.font, in: range) { value, run, _ in
            changes.append((run, transform(font(value, defaults))))
        }
        for (run, f) in changes { doc.addAttribute(.font, value: f, range: run) }
    }

    private static func resized(_ f: NSFont, _ size: CGFloat, _ defaults: Defaults) -> NSFont {
        MailRichText.font(family: f.familyName ?? defaults.font.family, size: size, bold: MailRichText.isBold(f), italic: MailRichText.isItalic(f))
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: Any?) -> UInt32? {
        guard let rgb = MailHTMLWriter.rgb(color) else { return nil }
        return UInt32(rgb.0) << 16 | UInt32(rgb.1) << 8 | UInt32(rgb.2)
    }

    /// A link the composer accepts: http, https and mailto (a bare address becomes mailto:, a bare host https://).
    static func composerLink(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if !candidate.contains(":") {
            if candidate.contains("@"), !candidate.contains("/") { candidate = "mailto:" + candidate } else { candidate = "https://" + candidate }
        }
        guard let target = MailHTMLWriter.linkVerdict(candidate) else { return nil }
        let scheme = target.prefix { $0 != ":" }.lowercased()
        guard ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "mailto" { return target.count > 7 ? target : nil }
        // http(s) needs a host.
        guard let host = URL(string: target)?.host, !host.isEmpty else { return nil }
        return target
    }

    // MARK: Paragraph operations

    struct ParagraphInfo {
        var range: NSRange
        var enclosing: NSRange
        var style: NSParagraphStyle?
        var quote: Int
        var lists: [NSTextList] { style?.textLists ?? [] }
    }

    static func paragraphs(_ doc: NSAttributedString, in range: NSRange) -> [ParagraphInfo] {
        let ns = doc.string as NSString
        let extended = ns.paragraphRange(for: clamp(range, doc.length))
        var out: [ParagraphInfo] = []
        ns.enumerateSubstrings(in: extended, options: [.byParagraphs, .substringNotRequired]) { _, r, e, _ in
            let at = r.length > 0 ? r.location : e.location
            let attrs = at < doc.length ? doc.attributes(at: at, effectiveRange: nil) : [:]
            out.append(ParagraphInfo(range: r, enclosing: e, style: attrs[.paragraphStyle] as? NSParagraphStyle,
                                     quote: MailRichText.quoteLevel(attrs[.ycQuoteBlock])))
        }
        return out
    }

    private static func kind(_ list: NSTextList?) -> ListKind? {
        guard let list else { return nil }
        return MailRichText.isOrdered(list) ? .number : .bullet
    }

    private static func setParagraph(_ doc: NSMutableAttributedString, _ p: ParagraphInfo, indent: Int, quote: Int, lists: [NSTextList]) {
        guard p.enclosing.length > 0 else { return }
        let style = MailRichText.paragraphStyle(base: p.style, indent: indent, quote: quote, lists: lists)
        doc.addAttribute(.paragraphStyle, value: style, range: p.enclosing)
        if quote > 0 { doc.addAttribute(.ycQuoteBlock, value: quote, range: p.enclosing) } else { doc.removeAttribute(.ycQuoteBlock, range: p.enclosing) }
    }

    /// The lists of the paragraph just before `location` (lists continue across an op when the kind matches).
    private static func listsBefore(_ doc: NSAttributedString, _ location: Int) -> [NSTextList] {
        guard location > 0 else { return [] }
        let style = doc.attribute(.paragraphStyle, at: location - 1, effectiveRange: nil) as? NSParagraphStyle
        return style?.textLists ?? []
    }

    private static func paragraphOp(_ op: Op, _ doc: NSMutableAttributedString, _ range: NSRange, defaults: Defaults) {
        let ps = paragraphs(doc, in: range)
        guard !ps.isEmpty, ps.contains(where: { $0.enclosing.length > 0 }) else { return }
        doc.beginEditing()
        defer { doc.endEditing() }
        let before = listsBefore(doc, ps[0].enclosing.location)
        switch op {
        case .list(let kind):
            if ps.allSatisfy({ self.kind($0.lists.last) == kind }) {
                for p in ps { setParagraph(doc, p, indent: 0, quote: p.quote, lists: []) }
                return
            }
            // One shared list per depth, so the items number together; continue the list just above when it matches.
            var shared: [Int: NSTextList] = [:]
            for p in ps {
                var lists = p.lists
                let depth = max(1, lists.count)
                let list: NSTextList
                if let existing = shared[depth] {
                    list = existing
                } else if before.count >= depth, self.kind(before[depth - 1]) == kind, Array(before.prefix(depth - 1)) == Array(lists.prefix(depth - 1)) {
                    list = before[depth - 1]
                } else {
                    list = MailRichText.newList(ordered: kind == .number, depth: depth)
                }
                shared[depth] = list
                if lists.isEmpty { lists = [list] } else { lists[lists.count - 1] = list }
                setParagraph(doc, p, indent: 0, quote: p.quote, lists: lists)
            }
        case .indent:
            var shared: [Int: NSTextList] = [:]
            for p in ps {
                var lists = p.lists
                if lists.isEmpty {
                    let level = MailRichText.indentLevel(p.style, quote: p.quote)
                    setParagraph(doc, p, indent: min(MailRichText.maxIndent, level + 1), quote: p.quote, lists: [])
                    continue
                }
                guard lists.count < MailRichText.maxListDepth else { continue }
                let depth = lists.count + 1
                let ordered = MailRichText.isOrdered(lists[lists.count - 1])
                let list: NSTextList
                if let existing = shared[depth] {
                    list = existing
                } else if before.count >= depth, MailRichText.isOrdered(before[depth - 1]) == ordered, Array(before.prefix(depth - 1)) == lists {
                    list = before[depth - 1]
                } else {
                    list = MailRichText.newList(ordered: ordered, depth: depth)
                }
                shared[depth] = list
                lists.append(list)
                setParagraph(doc, p, indent: 0, quote: p.quote, lists: lists)
            }
        case .outdent:
            for p in ps {
                var lists = p.lists
                if lists.isEmpty {
                    let level = MailRichText.indentLevel(p.style, quote: p.quote)
                    setParagraph(doc, p, indent: max(0, level - 1), quote: p.quote, lists: [])
                } else {
                    lists.removeLast()
                    setParagraph(doc, p, indent: 0, quote: p.quote, lists: lists)
                }
            }
        case .quote:
            let on = !ps.allSatisfy { $0.quote > 0 }
            for p in ps {
                let indent = MailRichText.indentLevel(p.style, quote: p.quote)
                setParagraph(doc, p, indent: indent, quote: on ? max(1, p.quote) : 0, lists: p.lists)
            }
        default:
            break
        }
    }

    /// After a paragraph op with a caret: the typing attributes follow the caret's paragraph (an empty last line has
    /// no characters to carry the style, so the typing attributes are where it lives).
    private static func paragraphTyping(_ doc: NSAttributedString, _ location: Int, into typing: inout [NSAttributedString.Key: Any],
                                        defaults: Defaults, op: Op? = nil) {
        let ps = paragraphs(doc, in: NSRange(location: location, length: 0))
        if let p = ps.first, p.enclosing.length > 0 {
            let attrs = doc.attributes(at: p.enclosing.location, effectiveRange: nil)
            typing[.paragraphStyle] = attrs[.paragraphStyle]
            typing[.ycQuoteBlock] = attrs[.ycQuoteBlock]
            return
        }
        // Nothing to hold the style: apply the op to the typing attributes' own paragraph style.
        guard let op else { return }
        let scratch = NSMutableAttributedString(string: "\n", attributes: typing)
        paragraphOp(op, scratch, NSRange(location: 0, length: 0), defaults: defaults)
        let attrs = scratch.attributes(at: 0, effectiveRange: nil)
        typing[.paragraphStyle] = attrs[.paragraphStyle]
        typing[.ycQuoteBlock] = attrs[.ycQuoteBlock]
    }

    // MARK: Clear formatting

    /// Default font and size, no colour, highlight, underline, strike or script; links, signature marks and images
    /// stay. The paragraphs touched lose lists, quote and indent (their writing direction stays).
    private static func clear(_ doc: NSMutableAttributedString, _ range: NSRange, defaults: Defaults) {
        doc.beginEditing()
        defer { doc.endEditing() }
        if range.length > 0 {
            for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .superscript, .baselineOffset] {
                doc.removeAttribute(key, range: range)
            }
            mapFonts(doc, range, defaults) { _ in defaults.baseFont }
        }
        for p in paragraphs(doc, in: range) where p.enclosing.length > 0 {
            let style = MailRichText.paragraphStyle(base: p.style, indent: 0, quote: 0, lists: [])
            doc.addAttribute(.paragraphStyle, value: style, range: p.enclosing)
            doc.removeAttribute(.ycQuoteBlock, range: p.enclosing)
        }
    }

    private static func clearedTyping(_ typing: [NSAttributedString.Key: Any], defaults: Defaults) -> [NSAttributedString.Key: Any] {
        var t = typing
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle, .superscript, .baselineOffset, .link] {
            t[key] = nil
        }
        t[.font] = defaults.baseFont
        return t
    }

    // MARK: Normalize (paste, RTF/RTFD, signatures)

    /// Keeps bold, italic, underline, strike, super/subscript, font family, size (clamped 8…72 and snapped), colours
    /// the writer would write, http/https/mailto links, lists and indents; drops tables (cells become tab-separated),
    /// shadows, kerning, baseline offsets, text effects, explicit black and catalog colours, paragraph spacing outside
    /// 0…24, list-marker text left by TextKit 1 sources, and (unless `images`) attachments.
    static func normalize(_ input: NSAttributedString, defaults: Defaults = Defaults(), images: Bool = false) -> NSAttributedString {
        let work = NSMutableAttributedString(attributedString: input)
        joinTableCells(work)
        stripMarkers(work)

        struct StyleKey: Hashable { var source: ObjectIdentifier?; var quote: Int }
        let out = NSMutableAttributedString()
        var styles: [StyleKey: NSParagraphStyle] = [:]
        work.enumerateAttributes(in: NSRange(location: 0, length: work.length)) { attrs, run, _ in
            var kept: [NSAttributedString.Key: Any] = [:]
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                guard images else { return }
                kept[.attachment] = attachment
                if let cid = attrs[.ycInlineImage] as? String { kept[.ycInlineImage] = cid }
            }
            let f = attrs[.font] as? NSFont
            let family = f?.familyName ?? defaults.font.family
            let size = SizeChoice.snap(f?.pointSize ?? defaults.size.points)
            kept[.font] = MailRichText.font(family: family, size: size, bold: MailRichText.isBold(f), italic: MailRichText.isItalic(f))
            if let css = MailHTMLWriter.cssColor(attrs[.foregroundColor]), let hex = UInt32(css.dropFirst(), radix: 16) { kept[.foregroundColor] = color(hex) }
            if let css = MailHTMLWriter.cssBackground(attrs[.backgroundColor]), let hex = UInt32(css.dropFirst(), radix: 16) { kept[.backgroundColor] = color(hex) }
            if isOn(attrs[.underlineStyle]) { kept[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if isOn(attrs[.strikethroughStyle]) { kept[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let script = (attrs[.superscript] as? Int) ?? (attrs[.superscript] as? NSNumber)?.intValue ?? 0
            if script != 0 { kept[.superscript] = script > 0 ? 1 : -1 }
            if attrs[.attachment] == nil, let link = attrs[.link] {
                let raw = (link as? URL)?.absoluteString ?? (link as? NSURL)?.absoluteString ?? (link as? String)
                if let raw, let target = MailHTMLWriter.linkVerdict(raw), ["http", "https", "mailto"].contains(target.prefix { $0 != ":" }.lowercased()) {
                    kept[.link] = target
                }
            }
            if (attrs[.ycSignature] as? Bool) == true { kept[.ycSignature] = true }
            let quote = MailRichText.quoteLevel(attrs[.ycQuoteBlock])
            if quote > 0 { kept[.ycQuoteBlock] = quote }
            let source = attrs[.paragraphStyle] as? NSParagraphStyle
            let key = StyleKey(source: source.map(ObjectIdentifier.init), quote: quote)
            if let cached = styles[key] {
                kept[.paragraphStyle] = cached
            } else {
                let made = normalizedStyle(source, quote: quote)
                styles[key] = made
                kept[.paragraphStyle] = made
            }
            out.append(NSAttributedString(string: (work.string as NSString).substring(with: run), attributes: kept))
        }
        // A paragraph takes its first character's paragraph style throughout.
        let ns = out.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, e, _ in
            guard e.length > 0 else { return }
            let at = r.length > 0 ? r.location : e.location
            if let style = out.attribute(.paragraphStyle, at: at, effectiveRange: nil) { out.addAttribute(.paragraphStyle, value: style, range: e) }
        }
        return out
    }

    private static func normalizedStyle(_ source: NSParagraphStyle?, quote: Int) -> NSParagraphStyle {
        let lists = Array((source?.textLists ?? []).prefix(MailRichText.maxListDepth))
        let indent: Int
        if let source, lists.isEmpty {
            let rest = max(source.headIndent, source.firstLineHeadIndent) - CGFloat(quote) * MailRichText.quoteStep
            indent = max(0, min(MailRichText.maxIndent, Int((rest / MailRichText.indentStep).rounded())))
        } else {
            indent = 0
        }
        let base = NSMutableParagraphStyle()
        base.lineHeightMultiple = MailRichText.lineHeightMultiple
        if let source {
            if (0...24).contains(source.paragraphSpacing) { base.paragraphSpacing = source.paragraphSpacing }
            if (0...24).contains(source.paragraphSpacingBefore) { base.paragraphSpacingBefore = source.paragraphSpacingBefore }
            base.baseWritingDirection = source.baseWritingDirection
        }
        return MailRichText.paragraphStyle(base: base, indent: indent, quote: quote, lists: lists)
    }

    /// Table cells from RTF (NSTextTableBlock paragraphs) become one line per row, cells separated by tabs.
    private static func joinTableCells(_ doc: NSMutableAttributedString) {
        let ns = doc.string as NSString
        var cells: [(enclosing: NSRange, content: NSRange, block: NSTextTableBlock?)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, e, _ in
            let at = r.length > 0 ? r.location : e.location
            let style = at < doc.length ? doc.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle : nil
            cells.append((e, r, style?.textBlocks.last as? NSTextTableBlock))
        }
        guard cells.contains(where: { $0.block != nil }) else { return }
        for i in stride(from: cells.count - 2, through: 0, by: -1) {
            guard let a = cells[i].block, let b = cells[i + 1].block, a.table === b.table, a.startingRow == b.startingRow else { continue }
            let terminator = NSRange(location: cells[i].content.location + cells[i].content.length,
                                     length: cells[i].enclosing.length - cells[i].content.length)
            if terminator.length > 0 { doc.replaceCharacters(in: terminator, with: "\t") }
        }
    }

    /// Removes leading marker runs ("\t•\t", "1.\t"…) from list paragraphs: TextKit 2 draws its own.
    static func stripMarkers(_ doc: NSMutableAttributedString) {
        let ns = doc.string as NSString
        var cuts: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { sub, r, _, _ in
            guard let sub, r.length > 0, let style = doc.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle,
                  !style.textLists.isEmpty else { return }
            let n = MailRichText.markerLength(sub)
            if n > 0 { cuts.append(NSRange(location: r.location, length: n)) }
        }
        for cut in cuts.reversed() { doc.deleteCharacters(in: cut) }
    }

    // MARK: Formatting state

    /// The toolbar's state for `selection` (a caret reads the typing attributes).
    static func formatting(_ doc: NSAttributedString, selection: NSRange, typing: [NSAttributedString.Key: Any],
                           defaults: Defaults = Defaults()) -> FormattingState {
        let sel = clamp(selection, doc.length)
        var state = FormattingState()
        state.selectionLength = sel.length
        func tri(_ on: Int, _ total: Int) -> FormattingState.Tri { on == 0 ? .off : on == total ? .on : .mixed }

        if sel.length == 0 {
            let t = typing.isEmpty ? attributesAtCaret(doc, sel.location, defaults: defaults) : typing
            let f = font(t[.font], defaults)
            state.bold = MailRichText.isBold(f) ? .on : .off
            state.italic = MailRichText.isItalic(f) ? .on : .off
            state.underline = isOn(t[.underlineStyle]) ? .on : .off
            state.strikethrough = isOn(t[.strikethroughStyle]) ? .on : .off
            state.familyName = f.familyName
            state.font = FontChoice.from(family: f.familyName)
            state.size = Int(f.pointSize.rounded())
            state.color = hex(t[.foregroundColor])
            state.highlight = hex(t[.backgroundColor])
            if sel.location > 0, sel.location <= doc.length, let link = doc.attribute(.link, at: sel.location - 1, effectiveRange: nil) {
                state.link = MailHTMLWriter.linkTarget(link)
            }
        } else {
            var total = 0, bold = 0, italic = 0, underline = 0, strike = 0
            var families = Set<String>(), sizes = Set<Int>(), colors = Set<UInt32>(), highlights = Set<UInt32>()
            var uncolored = false, linkFound: String?
            doc.enumerateAttributes(in: sel) { attrs, run, _ in
                if attrs[.attachment] != nil { return }
                let n = run.length
                total += n
                let f = font(attrs[.font], defaults)
                if MailRichText.isBold(f) { bold += n }
                if MailRichText.isItalic(f) { italic += n }
                if isOn(attrs[.underlineStyle]) { underline += n }
                if isOn(attrs[.strikethroughStyle]) { strike += n }
                families.insert(f.familyName ?? defaults.font.family)
                sizes.insert(Int(f.pointSize.rounded()))
                if let c = hex(attrs[.foregroundColor]) { colors.insert(c) } else { uncolored = true }
                if let h = hex(attrs[.backgroundColor]) { highlights.insert(h) }
                if linkFound == nil, let l = MailHTMLWriter.linkTarget(attrs[.link]) { linkFound = l }
            }
            state.bold = tri(bold, total)
            state.italic = tri(italic, total)
            state.underline = tri(underline, total)
            state.strikethrough = tri(strike, total)
            state.familyName = families.count == 1 ? families.first : nil
            state.font = families.count == 1 ? FontChoice.from(family: families.first) : nil
            state.size = sizes.count == 1 ? sizes.first : nil
            state.colorMixed = colors.count > 1 || (!colors.isEmpty && uncolored)
            state.color = colors.count == 1 && !uncolored ? colors.first : nil
            state.highlight = highlights.count == 1 ? highlights.first : nil
            state.link = linkFound
        }

        // Paragraph state: every paragraph touched (a caret on an empty last line reads the typing attributes).
        var ps = paragraphs(doc, in: sel).filter { $0.enclosing.length > 0 || $0.range.length > 0 }
        if ps.isEmpty || (sel.length == 0 && sel.location == doc.length && (doc.length == 0 || (doc.string as NSString).character(at: doc.length - 1) == 0x0A)) {
            let style = typing[.paragraphStyle] as? NSParagraphStyle
            ps = [ParagraphInfo(range: NSRange(location: sel.location, length: 0), enclosing: NSRange(location: sel.location, length: 0),
                                style: style, quote: MailRichText.quoteLevel(typing[.ycQuoteBlock]))]
        }
        let kinds = ps.map { kind($0.lists.last) }
        state.list = kinds.first ?? nil
        state.listMixed = Set(kinds.map { $0.map { "\($0)" } ?? "none" }).count > 1
        if state.listMixed { state.list = nil }
        state.listDepth = ps.map { $0.lists.count }.max() ?? 0
        state.quote = tri(ps.filter { $0.quote > 0 }.count, ps.count)
        state.indent = ps.map { MailRichText.indentLevel($0.style, quote: $0.quote) }.max() ?? 0
        return state
    }

    /// Anything beyond the defaults (asks before Make Plain Text; decides whether a signature needs rich storage).
    static func hasFormatting(_ doc: NSAttributedString, defaults: Defaults = Defaults()) -> Bool {
        var found = false
        doc.enumerateAttributes(in: NSRange(location: 0, length: doc.length)) { attrs, _, stop in
            let f = font(attrs[.font], defaults)
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            if attrs[.attachment] != nil || MailRichText.isBold(f) || MailRichText.isItalic(f) || isOn(attrs[.underlineStyle])
                || isOn(attrs[.strikethroughStyle]) || MailHTMLWriter.cssColor(attrs[.foregroundColor]) != nil
                || MailHTMLWriter.cssBackground(attrs[.backgroundColor]) != nil || MailHTMLWriter.linkTarget(attrs[.link]) != nil
                || (attrs[.superscript] as? Int ?? 0) != 0 || (f.familyName ?? defaults.font.family) != defaults.font.family
                || Int(f.pointSize.rounded()) != defaults.size.rawValue || MailRichText.quoteLevel(attrs[.ycQuoteBlock]) > 0
                || !(style?.textLists.isEmpty ?? true) || MailRichText.indentLevel(style, quote: 0) > 0 {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The plain text in the default attributes (body bridge, lazy signature migration).
    static func plain(_ text: String, defaults: Defaults = Defaults()) -> NSAttributedString {
        NSAttributedString(string: text, attributes: defaultAttributes(defaults))
    }

    /// The same document with every range carrying `.ycSignature` (the composer inserts signatures this way).
    static func marked(_ signature: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: signature)
        if out.length > 0 { out.addAttribute(.ycSignature, value: true, range: NSRange(location: 0, length: out.length)) }
        return out
    }

    /// Where the signature sits: the union of `.ycSignature` ranges (nil = no marks left).
    static func signatureRange(_ doc: NSAttributedString) -> NSRange? {
        var first: Int?, last = 0
        doc.enumerateAttribute(.ycSignature, in: NSRange(location: 0, length: doc.length)) { value, run, _ in
            guard (value as? Bool) == true || (value as? NSNumber)?.boolValue == true else { return }
            if first == nil { first = run.location }
            last = run.location + run.length
        }
        guard let first else { return nil }
        return NSRange(location: first, length: last - first)
    }
}
