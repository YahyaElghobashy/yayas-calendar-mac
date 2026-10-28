import AppKit

// Sanitized HTML → the rich composer's subset (D-042). Used for pasted HTML (after
// `HTMLSanitizer.sanitize(remote: .block)`) and "Edit quoted text". Never AppKit's HTML import, which runs WebKit and
// can fetch remote resources: this walks our own tokenizer's tokens and keeps only what the writer can write
// back: paragraphs and line breaks, bold, italic, underline, strike, super/subscript, font family and size, colour
// and highlight, links (http, https, mailto, tel), bulleted and numbered lists, indents, quote blocks, the Gmail
// signature wrapper, right-to-left paragraphs and inline images the caller can resolve (cid:). Everything else
// becomes plain text; hidden elements (display:none) are skipped; tables become tab-separated rows.
//
// The writer's output read back and written again is a fixed point (a data test checks it).

enum MailHTMLReader {
    /// `font`/`size`: the composer's defaults (unstyled text gets them). `image`: resolves a `cid:` reference to an
    /// attachment (nil = the image's alt text).
    static func attributedString(_ html: String, font: FontChoiceCSS = .sans, size: CGFloat = 14,
                                 image: @escaping (String) -> NSTextAttachment? = { _ in nil }) -> NSAttributedString {
        var reader = Reader(font: font, size: size, image: image)
        reader.read(HTMLTokenizer.tokenize(html))
        return reader.out
    }

    static let blockElements: Set<String> = [
        "div", "p", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "table", "tbody", "thead",
        "tfoot", "tr", "section", "article", "header", "footer", "center", "address", "dl", "dt", "dd", "figure",
        "figcaption", "main", "nav", "aside", "details", "summary", "caption", "fieldset", "legend", "hgroup", "body", "html",
    ]
    static let voidElements: Set<String> = ["br", "hr", "img", "col", "wbr", "area", "input", "meta", "link", "base", "source", "track", "embed", "param"]
    /// Never shown (the sanitizer drops most of these already; belt and braces for unsanitized callers).
    static let hiddenElements: Set<String> = ["head", "title", "script", "style", "template", "noscript", "iframe", "object", "svg", "math",
                                              "select", "textarea", "button"]

    // MARK: Inline style

    struct Style: Hashable {
        var family: String
        var size: CGFloat
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var color: String?
        var background: String?
        var link: String?
        var script = 0
    }

    private struct Frame {
        var name: String
        var style: Style
        var quote = 0
        var indent = 0
        var lists: [NSTextList] = []
        var signature = false
        var rtl: Bool?
        var hidden = false
        var pre = false
        var cells = 0
    }

    private struct Context {
        var quote: Int
        var indent: Int
        var lists: [NSTextList]
        var signature: Bool
        var rtl: Bool?
    }

    private struct Reader {
        let font: FontChoiceCSS
        let size: CGFloat
        let image: (String) -> NSTextAttachment?
        let out = NSMutableAttributedString()
        private var stack: [Frame]
        private var line = NSMutableAttributedString()
        private var context: Context?
        /// The last thing on the line is a collapsible space (or the line is empty / just broke): skip more.
        private var collapse = true
        private var trailingSpace = false
        private var fonts: [Style: NSFont] = [:]
        private let defaultStyle: Style

        init(font: FontChoiceCSS, size: CGFloat, image: @escaping (String) -> NSTextAttachment?) {
            self.font = font
            self.size = size
            self.image = image
            defaultStyle = Style(family: font.family, size: size)
            stack = [Frame(name: "#root", style: defaultStyle)]
        }

        mutating func read(_ tokens: [HTMLToken]) {
            for token in tokens {
                switch token {
                case .text(let raw):
                    guard let top = stack.last, !top.hidden else { continue }
                    text(HTMLEntities.decode(raw), pre: top.pre)
                case .rawText:
                    continue
                case .start(let name, let attributes, let selfClosing):
                    start(name, attributes, selfClosing: selfClosing)
                case .end(let name):
                    end(name)
                }
            }
            endParagraph()
        }

        // MARK: Elements

        private mutating func start(_ name: String, _ attributes: [HTMLAttribute], selfClosing: Bool) {
            let parent = stack.last ?? Frame(name: "#root", style: defaultStyle)
            if parent.hidden {
                if !MailHTMLReader.voidElements.contains(name) && !selfClosing { stack.append(Frame(name: name, style: parent.style, hidden: true)) }
                return
            }
            func attr(_ key: String) -> String? { attributes.first { $0.name == key }?.value }
            let css = CSS.parse(attr("style") ?? "")
            let block = MailHTMLReader.blockElements.contains(name)

            switch name {
            case "br":
                appendBreak()
                return
            case "hr":
                endParagraph()
                return
            case "img":
                let src = attr("src") ?? ""
                if src.lowercased().hasPrefix("cid:"), let attachment = image(String(src.dropFirst(4))) {
                    appendAttachment(attachment, cid: String(src.dropFirst(4)))
                } else if let alt = attr("alt")?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty {
                    text(alt, pre: false)
                }
                return
            default:
                break
            }
            if MailHTMLReader.voidElements.contains(name) { return }

            var frame = Frame(name: name, style: parent.style, quote: parent.quote, indent: parent.indent, lists: parent.lists,
                              signature: parent.signature, rtl: parent.rtl, pre: parent.pre)
            if MailHTMLReader.hiddenElements.contains(name) || css["display"] == "none" || css["visibility"] == "hidden" {
                frame.hidden = true
                if !selfClosing { stack.append(frame) }
                return
            }
            if block { endParagraph() }

            var style = frame.style
            switch name {
            case "b", "strong": style.bold = true
            case "i", "em", "cite", "var", "dfn": style.italic = true
            case "u", "ins": style.underline = true
            case "s", "strike", "del": style.strike = true
            case "sup": style.script = 1
            case "sub": style.script = -1
            case "code", "tt", "kbd", "samp": style.family = FontChoiceCSS.mono.family
            case "pre":
                style.family = FontChoiceCSS.mono.family
                frame.pre = true
            case "h1": style.bold = true; style.size = 24
            case "h2": style.bold = true; style.size = 18
            case "h3", "h4", "h5", "h6": style.bold = true
            case "a":
                if let href = attr("href"), let target = MailHTMLWriter.linkVerdict(href) { style.link = target }
            case "font":
                if let face = attr("face"), let family = CSS.family(face) { style.family = family }
                if let s = attr("size"), let n = Int(s.trimmingCharacters(in: .whitespaces)) {
                    style.size = [1: 10, 2: 13, 3: 16, 4: 18, 5: 24, 6: 32, 7: 48][max(1, min(7, n))] ?? style.size
                }
                if let c = attr("color"), let hex = CSS.color(c) { style.color = hex }
            case "ul", "ol":
                let list = MailRichText.newList(ordered: name == "ol", depth: frame.lists.count + 1)
                if name == "ol", let s = attr("start"), let n = Int(s), n > 1 { list.startingItemNumber = n }
                if frame.lists.count < MailRichText.maxListDepth { frame.lists.append(list) }
            case "blockquote":
                if CSS.isIndentBlock(css) {
                    frame.indent = min(MailRichText.maxIndent, frame.indent + max(1, CSS.marginLeftLevels(css)))
                } else {
                    frame.quote = min(MailRichText.maxQuote, frame.quote + 1)
                }
            case "td", "th":
                if let row = stack.lastIndex(where: { $0.name == "tr" }) {
                    if stack[row].cells > 0 { appendText("\t", hard: true) }
                    stack[row].cells += 1
                }
            default:
                break
            }
            if (name == "div" || name == "p"), CSS.marginLeftLevels(css) > 0 {
                frame.indent = min(MailRichText.maxIndent, frame.indent + CSS.marginLeftLevels(css))
            }
            if attr("class")?.split(separator: " ").contains("gmail_signature") == true { frame.signature = true }
            if let dir = attr("dir")?.lowercased() ?? css["direction"] {
                if dir == "rtl" { frame.rtl = true } else if dir == "ltr" { frame.rtl = false }
            }
            CSS.apply(css, to: &style, parentSize: frame.style.size)
            if let ws = css["white-space"], ws.hasPrefix("pre") { frame.pre = true }
            frame.style = style
            if !selfClosing { stack.append(frame) }
        }

        private mutating func end(_ name: String) {
            guard let index = stack.lastIndex(where: { $0.name == name }), index > 0 else { return }
            let closing = stack[index...]
            if closing.contains(where: { MailHTMLReader.blockElements.contains($0.name) && !$0.hidden }) { endParagraph() }
            stack.removeSubrange(index...)
        }

        // MARK: Text

        /// HTML whitespace rules: runs of spaces, tabs and newlines collapse to one space, none at the start of a
        /// line; `&nbsp;` is a space that never collapses (the writer's " &nbsp;" pairs read back exactly). In
        /// <pre>, spaces stay and a newline ends the paragraph.
        private mutating func text(_ decoded: String, pre: Bool) {
            var run = String.UnicodeScalarView()
            for scalar in decoded.unicodeScalars {
                if pre {
                    switch scalar {
                    case "\n":
                        appendRaw(String(run))
                        run = String.UnicodeScalarView()
                        endParagraph(force: true)
                    case "\r":
                        continue
                    default:
                        run.append(scalar == "\u{00A0}" ? " " : scalar)
                        collapse = false
                        trailingSpace = false
                    }
                    continue
                }
                switch scalar {
                case " ", "\t", "\n", "\r", "\u{0C}":
                    if collapse { continue }
                    run.append(" ")
                    collapse = true
                    trailingSpace = true
                case "\u{00A0}":
                    run.append(" ")
                    collapse = false
                    trailingSpace = false
                default:
                    run.append(scalar)
                    collapse = false
                    trailingSpace = false
                }
            }
            appendRaw(String(run))
        }

        /// Appends a string that never collapses (a table cell's tab).
        private mutating func appendText(_ string: String, hard: Bool) {
            appendRaw(string)
            if hard {
                collapse = false
                trailingSpace = false
            }
        }

        /// Appends text in the current inline style; whitespace state is the caller's.
        private mutating func appendRaw(_ string: String) {
            guard !string.isEmpty else { return }
            beginLineIfNeeded()
            line.append(NSAttributedString(string: string, attributes: attributes(stack.last?.style ?? defaultStyle)))
        }

        private mutating func appendBreak() {
            beginLineIfNeeded()
            trimTrailingSpace()
            line.append(NSAttributedString(string: "\u{2028}", attributes: attributes(stack.last?.style ?? defaultStyle)))
            collapse = true
            trailingSpace = false
        }

        private mutating func appendAttachment(_ attachment: NSTextAttachment, cid: String) {
            beginLineIfNeeded()
            var attrs = attributes(stack.last?.style ?? defaultStyle)
            attrs[.attachment] = attachment
            attrs[.ycInlineImage] = cid
            attrs[.link] = nil
            line.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            collapse = false
            trailingSpace = false
        }

        private mutating func beginLineIfNeeded() {
            guard context == nil, let top = stack.last else { return }
            context = Context(quote: top.quote, indent: top.indent, lists: top.lists, signature: top.signature, rtl: top.rtl)
        }

        private mutating func trimTrailingSpace() {
            guard trailingSpace, line.length > 0, (line.string as NSString).character(at: line.length - 1) == 0x20 else { return }
            line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1))
            trailingSpace = false
        }

        /// Ends the current paragraph. A trailing collapsible space and one trailing line break are dropped (as
        /// browsers do), so `<div><br></div>` is an empty paragraph and `<div>a<br></div>` is "a".
        private mutating func endParagraph(force: Bool = false) {
            if line.length == 0 && !force { return }
            beginLineIfNeeded()
            trimTrailingSpace()
            if line.length > 0, (line.string as NSString).character(at: line.length - 1) == 0x2028 {
                line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1))
            }
            let ctx = context ?? Context(quote: 0, indent: 0, lists: [], signature: false, rtl: nil)
            let start = out.length
            out.append(line)
            out.append(NSAttributedString(string: "\n", attributes: [.font: font(defaultStyle)]))
            let range = NSRange(location: start, length: out.length - start)
            let style = MailRichText.paragraphStyle(base: nil, indent: ctx.indent, quote: ctx.quote, lists: ctx.lists,
                                                    direction: ctx.rtl == true ? .rightToLeft : nil)
            out.addAttribute(.paragraphStyle, value: style, range: range)
            if ctx.quote > 0 { out.addAttribute(.ycQuoteBlock, value: ctx.quote, range: range) }
            if ctx.signature { out.addAttribute(.ycSignature, value: true, range: range) }
            line = NSMutableAttributedString()
            context = nil
            collapse = true
            trailingSpace = false
        }

        private mutating func font(_ style: Style) -> NSFont {
            var key = style
            key.color = nil; key.background = nil; key.link = nil; key.underline = false; key.strike = false; key.script = 0
            if let cached = fonts[key] { return cached }
            let made = MailRichText.font(family: style.family, size: style.size, bold: style.bold, italic: style.italic)
            fonts[key] = made
            return made
        }

        private mutating func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [.font: font(style)]
            if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let c = style.color.flatMap(CSS.nsColor) { attrs[.foregroundColor] = c }
            if let c = style.background.flatMap(CSS.nsColor) { attrs[.backgroundColor] = c }
            if let link = style.link { attrs[.link] = link }
            if style.script != 0 { attrs[.superscript] = style.script }
            return attrs
        }
    }

    // MARK: - CSS (the subset the composer keeps)

    enum CSS {
        /// `prop: value; …` → lowercased property → trimmed value (later declarations win; `!important` dropped).
        static func parse(_ css: String) -> [String: String] {
            var out: [String: String] = [:]
            for declaration in split(css, on: ";") {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if let bang = value.range(of: "!important", options: .caseInsensitive) { value = String(value[..<bang.lowerBound]).trimmingCharacters(in: .whitespaces) }
                guard !property.isEmpty, !value.isEmpty else { continue }
                out[property] = value
            }
            return out
        }

        static func split(_ text: String, on separator: Character) -> [String] {
            var parts: [String] = []
            var current = ""
            var quote: Character?
            var depth = 0
            for ch in text {
                if let q = quote {
                    current.append(ch)
                    if ch == q { quote = nil }
                    continue
                }
                switch ch {
                case "\"", "'": quote = ch; current.append(ch)
                case "(": depth += 1; current.append(ch)
                case ")": depth = max(0, depth - 1); current.append(ch)
                case separator where depth == 0: parts.append(current); current = ""
                default: current.append(ch)
                }
            }
            parts.append(current)
            return parts
        }

        static func apply(_ css: [String: String], to style: inout Style, parentSize: CGFloat) {
            if let families = css["font-family"], let family = family(families) { style.family = family }
            if let s = css["font-size"], let px = size(s, parent: parentSize) { style.size = px }
            if let w = css["font-weight"]?.lowercased() {
                if ["bold", "bolder", "600", "700", "800", "900"].contains(w) { style.bold = true }
                if ["normal", "lighter", "100", "200", "300", "400", "500"].contains(w) { style.bold = false }
            }
            if let s = css["font-style"]?.lowercased() { style.italic = s.hasPrefix("italic") || s.hasPrefix("oblique") }
            if let d = (css["text-decoration-line"] ?? css["text-decoration"])?.lowercased() {
                if d.contains("none") { style.underline = false; style.strike = false }
                if d.contains("underline") { style.underline = true }
                if d.contains("line-through") { style.strike = true }
            }
            if let c = css["color"], let hex = color(c) { style.color = hex }
            if let b = css["background-color"] ?? css["background"] {
                if let hex = split(b, on: " ").lazy.compactMap({ color($0.trimmingCharacters(in: .whitespaces)) }).first {
                    style.background = hex
                } else if b.lowercased().contains("transparent") || b.lowercased() == "none" {
                    style.background = nil
                }
            }
            if let v = css["vertical-align"]?.lowercased() {
                if v == "super" { style.script = 1 } else if v == "sub" { style.script = -1 } else if v == "baseline" { style.script = 0 }
            }
        }

        /// The first family in a CSS list this Mac has (generic names map to Helvetica, Times New Roman, Menlo;
        /// the system stack to the system font).
        static func family(_ list: String) -> String? {
            for raw in split(list, on: ",") {
                let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'"))
                guard !name.isEmpty else { continue }
                switch name.lowercased() {
                case "-apple-system", "system-ui", "blinkmacsystemfont", "ui-sans-serif": return MailRichText.systemFamily
                case "sans-serif", "arial": return "Helvetica"
                case "serif": return "Times New Roman"
                case "monospace", "ui-monospace": return "Menlo"
                case "cursive", "fantasy", "inherit", "initial": continue
                default:
                    if let known = FontChoiceCSS.choice(family: name) { return known.family }
                    if installed(name) { return canonical(name) }
                }
            }
            return nil
        }

        nonisolated(unsafe) private static var installedCache: [String: String?] = [:]
        private static let cacheLock = NSLock()

        static func installed(_ family: String) -> Bool { canonicalName(family) != nil }
        static func canonical(_ family: String) -> String { canonicalName(family) ?? family }

        private static func canonicalName(_ family: String) -> String? {
            cacheLock.lock()
            if let hit = installedCache[family.lowercased()] { cacheLock.unlock(); return hit }
            cacheLock.unlock()
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            let found = NSFont(descriptor: descriptor, size: 12).flatMap { font -> String? in
                guard let name = font.familyName, name.caseInsensitiveCompare(family) == .orderedSame else { return nil }
                return name
            }
            cacheLock.lock()
            installedCache[family.lowercased()] = found
            cacheLock.unlock()
            return found
        }

        /// px (the editor's pt equals CSS px); pt × 4/3; em, rem and % of the parent; the keyword table.
        static func size(_ raw: String, parent: CGFloat) -> CGFloat? {
            let v = raw.lowercased().trimmingCharacters(in: .whitespaces)
            let keywords: [String: CGFloat] = ["xx-small": 9, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24,
                                               "xx-large": 32, "xxx-large": 48]
            if let k = keywords[v] { return k }
            if v == "smaller" { return (parent * 0.83).rounded() }
            if v == "larger" { return (parent * 1.2).rounded() }
            let units = ["px", "pt", "rem", "em", "%"]
            guard let unit = units.first(where: { v.hasSuffix($0) }), let n = Double(v.dropLast(unit.count).trimmingCharacters(in: .whitespaces)),
                  n > 0 else { return nil }
            let px: Double
            switch unit {
            case "px": px = n
            case "pt": px = n * 4 / 3
            case "em", "rem": px = n * Double(parent)
            default: px = n / 100 * Double(parent)
            }
            return CGFloat(max(1, min(400, px.rounded())))
        }

        /// A blockquote that only indents (Gmail's indent: margin 40px, no border) rather than quoting.
        static func isIndentBlock(_ css: [String: String]) -> Bool {
            if let border = css["border-left"] ?? css["border"] {
                let b = border.lowercased()
                if !(b.contains("none") || b.hasPrefix("0")) { return false }
                return marginLeftLevels(css) > 0
            }
            return false
        }

        /// Indent levels from `margin-left` (or the `margin` shorthand's left value): 40 px per level.
        static func marginLeftLevels(_ css: [String: String]) -> Int {
            var left: String?
            if let m = css["margin"] {
                let parts = m.split(whereSeparator: { $0 == " " }).map(String.init)
                switch parts.count {
                case 4: left = parts[3]
                case 2, 3: left = parts[1]
                case 1: left = parts[0]
                default: break
                }
            }
            if let m = css["margin-left"] { left = m }
            guard let value = left, value.lowercased().hasSuffix("px"), let px = Double(value.dropLast(2)), px >= 20 else { return 0 }
            return max(1, min(MailRichText.maxIndent, Int((px / 40).rounded())))
        }

        static let named: [String: String] = [
            "black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000", "blue": "#0000ff", "gray": "#808080",
            "grey": "#808080", "silver": "#c0c0c0", "maroon": "#800000", "purple": "#800080", "fuchsia": "#ff00ff", "lime": "#00ff00",
            "olive": "#808000", "yellow": "#ffff00", "navy": "#000080", "teal": "#008080", "aqua": "#00ffff", "orange": "#ffa500",
        ]

        /// `#rrggbb` for #rgb, #rrggbb, rgb(), rgba() (fully transparent = none) and the basic named colours.
        static func color(_ raw: String) -> String? {
            let v = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if let n = named[v] { return n }
            if v.hasPrefix("#") {
                let hex = v.dropFirst()
                guard hex.allSatisfy(\.isHexDigit) else { return nil }
                if hex.count == 3 { return "#" + hex.map { "\($0)\($0)" }.joined() }
                if hex.count == 6 { return "#" + hex }
                return nil
            }
            if v.hasPrefix("rgb"), let open = v.firstIndex(of: "("), let close = v.lastIndex(of: ")") {
                let parts = v[v.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3 else { return nil }
                func channel(_ s: String) -> Int? {
                    if s.hasSuffix("%"), let p = Double(s.dropLast()) { return Int((p * 2.55).rounded()) }
                    return Double(s).map { Int($0.rounded()) }
                }
                guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
                if parts.count >= 4, let a = Double(parts[3].hasSuffix("%") ? String(parts[3].dropLast()) : parts[3]), a <= 0 { return nil }
                return MailHTMLWriter.hex((max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b))))
            }
            return nil
        }

        static func nsColor(_ hex: String) -> NSColor? {
            guard hex.hasPrefix("#"), hex.count == 7, let n = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((n >> 16) & 0xFF) / 255, green: CGFloat((n >> 8) & 0xFF) / 255, blue: CGFloat(n & 0xFF) / 255, alpha: 1)
        }
    }
}
