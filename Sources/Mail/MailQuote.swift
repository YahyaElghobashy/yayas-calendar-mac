import Foundation

// Quoted history in HTML mail (rich mail, D-040). Runs at read time on the
// sanitizer's output, never before it: the sanitizer reserves the `yc-` prefix, so these markers can only
// come from here. Finds the FIRST quote start in document order (Gmail, Outlook on the web and desktop,
// Apple Mail / iOS / Fastmail, Thunderbird, Yahoo, Proton, "-----Original Message-----"), checks that it
// is trailing (nothing visible after it, something visible before it, not a forward) and wraps it in a
// native <details> behind "•••", which toggles with page JavaScript off. Anything else is left as it was,
// byte for byte: inline answers, forwards, quote-only bodies and newsletter pull-quotes keep their bars.

enum MailQuote {
    /// Our markers. The reader's CSS styles them; renders open them by adding `open`.
    static let openTag = "<details class=\"yc-quote\">"
    static let summary = "<summary class=\"yc-more\" aria-label=\"Show quoted text\">\u{2022}\u{2022}\u{2022}</summary>"
    static let closeTag = "</details>"

    /// Wraps trailing quoted history in `<details class="yc-quote">`. `collapsed` = something was wrapped.
    static func mark(_ sanitizedHTML: String) -> (html: String, collapsed: Bool) {
        let found = scan(sanitizedHTML)
        guard found.any else { return (sanitizedHTML, false) }
        let root = Tree.build(sanitizedHTML)
        guard let range = collapseRange(root, original: found.original) else { return (sanitizedHTML, false) }
        let parent = range.first.parent!
        let start = range.first.index, end = range.last.index
        let details = Node(name: "details", attrs: [HTMLAttribute(name: "class", value: "yc-quote")])
        let summary = Node(name: "summary", attrs: [HTMLAttribute(name: "class", value: "yc-more"),
                                                     HTMLAttribute(name: "aria-label", value: "Show quoted text")])
        summary.append(Node(text: "\u{2022}\u{2022}\u{2022}"))
        details.append(summary)
        for node in parent.children[start...end] { details.append(node) }
        parent.children.replaceSubrange(start...end, with: [details])
        details.parent = parent
        parent.reindex()
        var out = ""
        out.reserveCapacity(sanitizedHTML.utf8.count + 160)
        root.serialize(into: &out)
        return (out, true)
    }

    // MARK: Attribution lines

    /// How the line ends in other scripts, before its colon: Greek "έγραψε", Russian "пишет" / "написал(а)" / "написал" /
    /// "написала", Hebrew "כתב" / "כתב/ה", Arabic "كتب", Chinese "写道" / "寫道" (often with a full-width colon), Japanese
    /// "書きました".
    static let attributionVerbs = ["\u{03AD}\u{03B3}\u{03C1}\u{03B1}\u{03C8}\u{03B5}",
                                   "\u{043F}\u{0438}\u{0448}\u{0435}\u{0442}", "\u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043B}(\u{0430})",
                                   "\u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043B}", "\u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043B}\u{0430}",
                                   "\u{05DB}\u{05EA}\u{05D1}", "\u{05DB}\u{05EA}\u{05D1}/\u{05D4}", "\u{0643}\u{062A}\u{0628}",
                                   "\u{5199}\u{9053}", "\u{5BEB}\u{9053}", "\u{66F8}\u{304D}\u{307E}\u{3057}\u{305F}"]

    /// "On … wrote:" and its usual translations (at most 400 characters after collapsing whitespace).
    static func isAttribution(_ raw: String) -> Bool {
        let s = collapse(raw)
        guard s.count >= 6, s.count <= 400 else { return false }
        if s.hasPrefix("On "), s.hasSuffix("wrote:") { return (3...300).contains(s.count - 9) }
        if s.hasPrefix("Am "), s.contains(" schrieb "), s.hasSuffix(":") { return true }
        if s.hasPrefix("Le "), s.hasSuffix(" a \u{00E9}crit:") || s.hasSuffix(" a \u{00E9}crit :") { return true }
        if s.hasPrefix("El "), s.hasSuffix(" escribi\u{00F3}:") { return true }
        if s.hasPrefix("Op "), s.contains(" schreef "), s.hasSuffix(":") { return true }
        if s.hasPrefix("Il "), s.hasSuffix(" ha scritto:") { return true }
        for verb in attributionVerbs where s.hasSuffix(verb + ":") || s.hasSuffix(verb + " :") || s.hasSuffix(verb + "\u{FF1A}") { return true }
        return false
    }

    /// Whitespace runs → one space, bidi and zero-width marks dropped, trimmed.
    static func collapse(_ raw: String) -> String {
        var out = ""
        var space = false
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue
            case 0x20, 0x09, 0x0A, 0x0D, 0x0C, 0xA0:
                space = true
            default:
                if space, !out.isEmpty { out.append(" ") }
                space = false
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Forward headers ("---------- Forwarded message ---------", Apple's "Begin forwarded message:", Outlook's
    /// "Subject: FW:"): a forward is the message itself, never collapsed (Gmail and Apple Mail show it open).
    static func looksForwarded(_ text: String) -> Bool {
        let s = collapse(text).lowercased()
        return s.contains("- forwarded message -") || s.hasPrefix("begin forwarded message") || s.contains("subject: fw:")
            || s.contains("subject: fwd:")
    }

    // MARK: Finding the range

    /// Outlook desktop's header is found by its rule colours (#E1E1E1, #B5C4DF), not "border-top", which half of all
    /// newsletters use.
    private static let needles = ["gmail_quote", "divrplyfwdmsg", "appendonsend", "outlookmessageheader", "#e1e1e1", "#b5c4df",
                                  "type=\"cite\"", "moz-cite-prefix", "yahoo_quoted", "protonmail_quote", "original message"]
    private static let needleBytes: [[UInt8]] = needles.map { Array($0.utf8) }

    /// One case-insensitive pass over the bytes: any quote marker at all (else nothing to parse), and whether
    /// "original message" occurs (only then are block texts checked for it).
    static func scan(_ html: String) -> (any: Bool, original: Bool) {
        let originalIndex = needleBytes.count - 1
        var any = false
        var original = false
        func run(_ b: UnsafeBufferPointer<UInt8>) {
            let n = b.count
            var i = 0
            while i < n {
                let c = b[i] | 0x20   // needles start with a letter
                for (k, needle) in needleBytes.enumerated() where needle[0] == c && i + needle.count <= n {
                    var j = 1
                    while j < needle.count {
                        let x = b[i + j]
                        if ((0x41...0x5A).contains(x) ? x | 0x20 : x) != needle[j] { break }
                        j += 1
                    }
                    guard j == needle.count else { continue }
                    any = true
                    if k == originalIndex { original = true }
                }
                if original { return }   // implies `any`
                i += 1
            }
        }
        if html.utf8.withContiguousStorageIfAvailable(run) == nil {
            var copy = html
            copy.makeContiguousUTF8()
            copy.utf8.withContiguousStorageIfAvailable(run)
        }
        return (any, original)
    }

    private enum Kind { case element, toEndOfParent }

    private struct Start {
        var node: Node
        var kind: Kind
        var outlookWeb = false
        var apple = false
    }

    struct Range { var first: Node; var last: Node }

    private static func classes(_ node: Node) -> [Substring] {
        guard let value = node.attr("class") else { return [] }
        return value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
    }

    private static let classMarkers = ["gmail_quote", "outlookmessageheader", "moz-cite-prefix", "yahoo_quoted", "protonmail_quote"]

    private static func start(_ node: Node, original: Bool = false) -> Start? {
        guard node.isElement else { return nil }
        var names: [String] = []
        if let value = node.attr("class") {
            let lower = value.lowercased()
            if classMarkers.contains(where: lower.contains) { names = classes(node).map { $0.lowercased() } }
        }
        let id = node.attr("id")?.lowercased() ?? ""
        if names.contains("gmail_quote") || names.contains("gmail_quote_container") { return Start(node: node, kind: .element) }
        if node.name == "div", id == "divrplyfwdmsg" || id == "appendonsend" {
            return Start(node: node, kind: .toEndOfParent, outlookWeb: true)
        }
        if names.contains("outlookmessageheader") { return Start(node: node, kind: .toEndOfParent) }
        if node.name == "div", let style = node.attr("style"), style.range(of: "border-top", options: .caseInsensitive) != nil {
            let squashed = style.lowercased().filter { !$0.isWhitespace }
            if squashed.contains("border-top:solid#e1e1e1") || squashed.contains("border-top:solid#b5c4df") {
                let head = node.text(limit: 300)
                if ["From:", "Von:", "De:", "De :", "Da:", "Van:"].contains(where: head.contains) {
                    return Start(node: node, kind: .toEndOfParent)
                }
            }
        }
        if node.name == "blockquote", node.attr("type")?.lowercased() == "cite" { return Start(node: node, kind: .element, apple: true) }
        if names.contains("moz-cite-prefix") { return Start(node: node, kind: .element) }
        if names.contains("yahoo_quoted") || id.hasPrefix("yahoo_quoted_") { return Start(node: node, kind: .element) }
        if names.contains("protonmail_quote") { return Start(node: node, kind: .element) }
        if original, node.name == "div" || node.name == "p" {
            let head = collapse(node.text(limit: 80))
            if head.hasPrefix("-----"), head.prefix(40).contains("Original Message") { return Start(node: node, kind: .toEndOfParent) }
        }
        return nil
    }

    private static func firstStart(_ root: Node, original: Bool) -> Start? {
        var stack: [Node] = root.children.reversed()
        while let node = stack.popLast() {
            if let found = start(node, original: original) { return found }
            if node.name == "style" { continue }
            stack.append(contentsOf: node.children.reversed())
        }
        return nil
    }

    /// Where a collapse may not be inserted (the HTML parser would move or split it).
    private static let badParents: Set<String> = ["table", "tbody", "thead", "tfoot", "tr", "colgroup", "ul", "ol", "dl", "p"]

    static func collapseRange(_ root: Node, original: Bool) -> Range? {
        guard var s = firstStart(root, original: original) else { return nil }
        // Outlook's header often sits alone in a wrapper div: the history follows the wrapper.
        if s.kind == .toEndOfParent {
            while let parent = s.node.parent, parent.parent != nil, parent.name == "div",
                  parent.children.allSatisfy({ $0 === s.node || !$0.visible }) {
                s.node = parent
            }
        }
        var first = s.node
        var last = s.node
        switch s.kind {
        case .element:
            if s.apple, let attribution = attributionBefore(s.node) { first = attribution }
        case .toEndOfParent:
            if s.outlookWeb, s.node.attr("id")?.lowercased() == "divrplyfwdmsg", let hr = previousSignificant(s.node), hr.name == "hr" {
                first = hr
            }
            last = s.node.parent!.children.last!
        }
        // Trailing (a): after `last`, only invisible content or more quoted history (iOS sends the
        // attribution and the quote as two sibling blockquotes).
        var node = last
        while true {
            if let next = node.nextSibling {
                node = next
                if !next.visible { continue }
                if start(next) != nil || (next.name == "div" && next.children.allSatisfy({ !$0.visible || start($0) != nil })) {
                    last = next
                    continue
                }
                return nil
            }
            guard let parent = node.parent, parent.parent != nil else { break }
            node = parent
        }
        // One parent for the whole range: both ends become children of their lowest common ancestor.
        var (f, l) = (first, last)
        if first !== last {
            let chainF = first.lineage, chainL = last.lineage
            guard let lca = chainF.first(where: { a in chainL.contains { $0 === a } }) else { return nil }
            if lca === first || lca === last {
                f = lca; l = lca
            } else {
                guard let fi = chainF.firstIndex(where: { $0.parent === lca }),
                      let li = chainL.firstIndex(where: { $0.parent === lca }) else { return nil }
                f = chainF[fi]; l = chainL[li]
                guard f.index <= l.index else { return nil }
            }
            // Nothing visible may sit inside the hoisted start before the real start.
            if f !== first, f.visibleBefore(first) { return nil }
        }
        guard let parent = f.parent, !badParents.contains(parent.name) else { return nil }
        // Trailing (b): something visible precedes it.
        guard root.visibleBefore(f) else { return nil }
        // Forwards stay open.
        var head = ""
        for n in parent.children[f.index...l.index] where head.utf16.count < 400 { head += " " + n.text(limit: 400) }
        if looksForwarded(head) { return nil }
        if let before = previousSignificant(f), collapse(before.text(limit: 120)).lowercased().hasPrefix("begin forwarded message") {
            return nil
        }
        return Range(first: f, last: l)
    }

    /// The sibling before `node`, skipping whitespace, `<br>` and empty elements.
    private static func previousSignificant(_ node: Node) -> Node? {
        var n = node.previousSibling
        while let cur = n {
            if cur.name == "hr" || cur.visible { return cur }
            n = cur.previousSibling
        }
        return nil
    }

    /// Apple: the "On … wrote:" line right before the blockquote, as one block or a run of inline nodes.
    private static func attributionBefore(_ node: Node) -> Node? {
        guard let prev = previousSignificant(node) else { return nil }
        if prev.isBlock { return isAttribution(prev.text(limit: 420)) ? prev : nil }
        // Inline run back to a <br> or a block: "On …, Mom <" <a>mom@…</a> "> wrote:"
        var run: [Node] = []
        var n: Node? = prev
        while let cur = n, !(cur.name == "br" || cur.isBlock) {
            run.insert(cur, at: 0)
            n = cur.previousSibling
        }
        let text = run.map { $0.text(limit: 420) }.joined()
        return isAttribution(text) ? run.first : nil
    }

    // MARK: Tree

    /// A minimal DOM of the sanitizer's (well-formed) output.
    final class Node {
        let name: String           // "#root", "#text", "#raw" (style content), or an element name
        var attrs: [HTMLAttribute]
        var text: String           // #text: decoded text; #raw: content as is
        var children: [Node] = []
        weak var parent: Node?
        var index = 0
        var visible = false

        init(name: String, attrs: [HTMLAttribute] = []) {
            self.name = name
            self.attrs = attrs
            self.text = ""
        }

        init(text: String, raw: Bool = false) {
            name = raw ? "#raw" : "#text"
            attrs = []
            self.text = text
        }

        var isText: Bool { name == "#text" }
        var isElement: Bool { !name.hasPrefix("#") }
        var isBlock: Bool { MailQuote.blocks.contains(name) }

        func attr(_ key: String) -> String? { attrs.first { $0.name == key }?.value }

        func append(_ child: Node) {
            child.parent = self
            child.index = children.count
            children.append(child)
        }

        func reindex() { for (i, c) in children.enumerated() { c.index = i } }

        var nextSibling: Node? {
            guard let parent, index + 1 < parent.children.count else { return nil }
            return parent.children[index + 1]
        }

        var previousSibling: Node? {
            guard let parent, index > 0 else { return nil }
            return parent.children[index - 1]
        }

        /// Self first, then each parent, up to and including the root.
        var lineage: [Node] {
            var out: [Node] = []
            var n: Node? = self
            while let cur = n { out.append(cur); n = cur.parent }
            return out
        }

        /// Text content (decoded), `<br>` as a line break, up to about `limit` UTF-16 units.
        func text(limit: Int) -> String {
            var out = ""
            var count = 0
            collect(&out, &count, limit)
            return out
        }

        private func collect(_ out: inout String, _ count: inout Int, _ limit: Int) {
            guard count < limit else { return }
            switch name {
            case "#text": out += text; count += text.utf16.count
            case "br": out += "\n"; count += 1
            case "img": if let alt = attr("alt") { out += alt; count += alt.utf16.count }
            case "#raw", "style": return
            default: for c in children where count < limit { c.collect(&out, &count, limit) }
            }
        }

        /// Any visible content (text, images) in document order before `target`, inside this subtree.
        func visibleBefore(_ target: Node) -> Bool {
            var stack: [Node] = [self]
            while let n = stack.popLast() {
                if n === target { return false }
                if n.isText || n.name == "img" { if n.visible { return true } else { continue } }
                if !n.visible && !n.contains(target) { continue }
                stack.append(contentsOf: n.children.reversed())
            }
            return false
        }

        /// Nothing to escape (most text and attribute values): appended as they are.
        static func plain(_ s: String, attribute: Bool) -> Bool {
            !s.utf8.contains { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || (attribute && ($0 == 0x22 || $0 == 0x27)) }
        }

        func contains(_ target: Node) -> Bool {
            var n: Node? = target
            while let cur = n { if cur === self { return true }; n = cur.parent }
            return false
        }

        func serialize(into out: inout String) {
            switch name {
            case "#root": for c in children { c.serialize(into: &out) }
            case "#text": out.append(Self.plain(text, attribute: false) ? text : HTMLEntities.escapeText(text))
            case "#raw": out.append(text)
            default:
                out.append("<")
                out.append(name)
                for a in attrs {
                    out.append(" ")
                    out.append(a.name)
                    out.append("=\"")
                    out.append(Self.plain(a.value, attribute: true) ? a.value : HTMLEntities.escapeAttribute(a.value))
                    out.append("\"")
                }
                out.append(">")
                guard !HTMLSanitizer.voidElements.contains(name) else { return }
                for c in children { c.serialize(into: &out) }
                out.append("</")
                out.append(name)
                out.append(">")
            }
        }
    }

    static let blocks: Set<String> = ["div", "p", "blockquote", "table", "tbody", "tr", "td", "th", "ul", "ol", "li", "h1", "h2",
                                      "h3", "h4", "h5", "h6", "pre", "hr", "section", "article", "header", "footer", "center",
                                      "address", "dl", "dt", "dd", "figure", "main", "nav", "aside", "details", "summary"]

    enum Tree {
        static func build(_ html: String) -> Node {
            let root = Node(name: "#root")
            var stack: [Node] = [root]
            for token in HTMLTokenizer.tokenize(html) {
                let current = stack[stack.count - 1]
                switch token {
                case .text(let raw):
                    current.append(Node(text: HTMLEntities.decode(raw)))
                case .rawText(_, let content):
                    current.append(Node(text: content, raw: true))
                case .start(let name, let attributes, let selfClosing):
                    let node = Node(name: name, attrs: attributes)
                    current.append(node)
                    if !selfClosing && !HTMLSanitizer.voidElements.contains(name) { stack.append(node) }
                case .end(let name):
                    guard let i = stack.lastIndex(where: { $0.name == name }), i > 0 else { continue }
                    stack.removeSubrange(i...)
                }
            }
            markVisible(root)
            return root
        }

        /// Bottom-up: text with anything but whitespace, images, and elements holding either.
        @discardableResult
        static func markVisible(_ node: Node) -> Bool {
            switch node.name {
            case "#text":
                node.visible = node.text.unicodeScalars.contains {
                    !($0.properties.isWhitespace || $0.value == 0xA0 || (0x200B...0x200F).contains($0.value) || $0.value == 0xFEFF)
                }
            case "#raw", "style":
                node.visible = false
            case "img":
                // A 1×1 tracking pixel at the end of a reply doesn't count as content.
                func side(_ key: String) -> Int? { node.attr(key).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: " px"))) } }
                node.visible = !((side("width") ?? 99) <= 2 && (side("height") ?? 99) <= 2)
            default:
                var any = false
                for c in node.children where markVisible(c) { any = true }
                node.visible = any
            }
            return node.visible
        }
    }
}
