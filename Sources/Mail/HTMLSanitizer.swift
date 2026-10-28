import Foundation

// Mail HTML → HTML that is safe to show in the reader's WKWebView (JS off there too: defence in
// depth). A tokenizer, not regular expressions. The output is re-serialized from our own tokens, so
// the browser only ever parses markup we wrote:
//
// - elements: an allowlist is kept; dangerous ones (script, iframe, object, embed, svg, form controls,
//   meta, base, link, media…) are dropped with their content; anything else (html, head, form,
//   unknown, Office `o:p`) is unwrapped and its content kept; `body` becomes a `div`.
// - attributes: an allowlist; every `on*`, `srcdoc`, `srcset`, `formaction`, `target` and namespaced
//   attribute is dropped. URLs: http(s)/mailto/tel/#anchor in links; http(s) and data:image (raster
//   types only) for images; `javascript:`, `vbscript:`, `data:` (non-image), `file:` and relative
//   URLs are dropped, after browser-style normalization (entities decoded, tabs/newlines removed).
// - CSS: inline `style` is kept declaration by declaration; `<style>` blocks are re-built rule by
//   rule; `expression()`, `behavior`, `-moz-binding`, script URLs, `@import` and escaped CSS go.
// - remote content: any http(s) image, background or CSS `url()` sets `hasRemoteImages`; in `.block`
//   mode it is removed (images keep their size and alt text). `cid:` images become a placeholder,
//   unless their Content-ID is one of this message's own inline parts (`cids`, rich mail D-040): those
//   stay as `<img src="cid:…">` for the reader's per-message scheme handler.
// - the `yc-` class and id prefix is reserved for the reader's own markers (quote collapse, plain-text
//   quote bars): sender HTML can't fake or restyle them by class.
//
// Sanitizing the output again in `.block` mode is how the reader goes from "images allowed" (what the
// body cache stores) to "images blocked" (what a sender not on the allow list gets).

enum HTMLToken: Equatable {
    case text(String)
    case start(name: String, attributes: [HTMLAttribute], selfClosing: Bool)
    case end(name: String)
    /// Content of a raw-text element (`script`, `style`, `textarea`, `title`…) right after its start tag.
    case rawText(name: String, content: String)
}

struct HTMLAttribute: Equatable {
    var name: String
    /// Character references already decoded.
    var value: String
}

enum HTMLTokenizer {
    /// Elements whose content is not markup.
    static let rawText: Set<String> = ["script", "style", "xmp", "iframe", "noembed", "noframes", "textarea", "title",
                                       "plaintext"]

    static func tokenize(_ html: String) -> [HTMLToken] {
        let s = Array(html.unicodeScalars)
        var tokens: [HTMLToken] = []
        var text = String.UnicodeScalarView()
        var i = 0
        func flushText() {
            if !text.isEmpty { tokens.append(.text(String(text))); text = String.UnicodeScalarView() }
        }
        func isLetter(_ c: Unicode.Scalar) -> Bool { c.isASCII && c.properties.isAlphabetic }
        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }
        func find(_ needle: String, from start: Int) -> Int? {
            let n = Array(needle.unicodeScalars)
            guard !n.isEmpty, start <= s.count - n.count else { return nil }
            var k = start
            while k <= s.count - n.count {
                var match = true
                for m in 0..<n.count where s[k + m] != n[m] { match = false; break }
                if match { return k }
                k += 1
            }
            return nil
        }

        while i < s.count {
            let c = s[i]
            guard c == "<", i + 1 < s.count else { text.append(c); i += 1; continue }
            let n = s[i + 1]
            if n == "!" {
                flushText()
                if i + 3 < s.count, s[i + 2] == "-", s[i + 3] == "-" {
                    // <!-- … -->, including the degenerate <!--> and <!--->.
                    if i + 4 < s.count, s[i + 4] == ">" { i += 5; continue }
                    if i + 5 < s.count, s[i + 4] == "-", s[i + 5] == ">" { i += 6; continue }
                    if let close = find("-->", from: i + 4) { i = close + 3 } else if let alt = find("--!>", from: i + 4) {
                        i = alt + 4
                    } else { i = s.count }
                    continue
                }
                // <!DOCTYPE …>, <![CDATA[ … ]]>, bogus comments: up to the next '>'.
                var k = i + 2
                while k < s.count, s[k] != ">" { k += 1 }
                i = k + 1
                continue
            }
            if n == "?" {
                flushText()
                var k = i + 2
                while k < s.count, s[k] != ">" { k += 1 }
                i = k + 1
                continue
            }
            if n == "/" {
                guard i + 2 < s.count else { text.append(c); i += 1; continue }
                if isLetter(s[i + 2]) {
                    flushText()
                    var k = i + 2
                    var name = String.UnicodeScalarView()
                    while k < s.count, !isSpace(s[k]), s[k] != "/", s[k] != ">" { name.append(s[k]); k += 1 }
                    while k < s.count, s[k] != ">" { k += 1 }
                    tokens.append(.end(name: String(name).lowercased()))
                    i = k + 1
                    continue
                }
                // "</>" is ignored; "</ …>" is a bogus comment.
                flushText()
                var k = i + 2
                while k < s.count, s[k] != ">" { k += 1 }
                i = k + 1
                continue
            }
            guard isLetter(n) else { text.append(c); i += 1; continue }

            flushText()
            var k = i + 1
            var name = String.UnicodeScalarView()
            while k < s.count, !isSpace(s[k]), s[k] != "/", s[k] != ">" { name.append(s[k]); k += 1 }
            var attributes: [HTMLAttribute] = []
            var seen = Set<String>()
            var selfClosing = false
            var closed = false
            while k < s.count {
                while k < s.count, isSpace(s[k]) { k += 1 }
                guard k < s.count else { break }
                if s[k] == ">" { closed = true; k += 1; break }
                if s[k] == "/" {
                    if k + 1 < s.count, s[k + 1] == ">" { selfClosing = true; closed = true; k += 2; break }
                    k += 1
                    continue
                }
                var attrName = String.UnicodeScalarView()
                attrName.append(s[k])   // the first character may be '=' (it is part of the name then)
                k += 1
                while k < s.count, !isSpace(s[k]), s[k] != "/", s[k] != ">", s[k] != "=" { attrName.append(s[k]); k += 1 }
                while k < s.count, isSpace(s[k]) { k += 1 }
                var value = String.UnicodeScalarView()
                if k < s.count, s[k] == "=" {
                    k += 1
                    while k < s.count, isSpace(s[k]) { k += 1 }
                    if k < s.count, s[k] == "\"" || s[k] == "'" {
                        let quote = s[k]
                        k += 1
                        while k < s.count, s[k] != quote { value.append(s[k]); k += 1 }
                        if k < s.count { k += 1 }
                    } else {
                        while k < s.count, !isSpace(s[k]), s[k] != ">" { value.append(s[k]); k += 1 }
                    }
                }
                let lower = String(attrName).lowercased()
                if seen.insert(lower).inserted {
                    attributes.append(HTMLAttribute(name: lower, value: HTMLEntities.decode(String(value))))
                }
            }
            guard closed else { i = s.count; break }   // EOF inside a tag: the tag is dropped
            let tag = String(name).lowercased()
            tokens.append(.start(name: tag, attributes: attributes, selfClosing: selfClosing))
            i = k
            if rawText.contains(tag) {
                // Content runs to "</tag" followed by a space, '/' or '>' (case-insensitive).
                var end = i
                var found = false
                while end < s.count {
                    if s[end] == "<", end + 1 < s.count, s[end + 1] == "/" {
                        let nameScalars = Array(tag.unicodeScalars)
                        var m = 0
                        while m < nameScalars.count, end + 2 + m < s.count,
                              Character(s[end + 2 + m]).lowercased() == String(nameScalars[m]) { m += 1 }
                        let after = end + 2 + m
                        if m == nameScalars.count, after >= s.count || isSpace(s[after]) || s[after] == "/" || s[after] == ">" {
                            found = true
                            break
                        }
                    }
                    end += 1
                }
                var content = String.UnicodeScalarView()
                content.append(contentsOf: s[i..<min(end, s.count)])
                tokens.append(.rawText(name: tag, content: String(content)))
                if found {
                    var e = end + 2
                    while e < s.count, s[e] != ">" { e += 1 }
                    tokens.append(.end(name: tag))
                    i = e + 1
                } else {
                    i = s.count
                }
            }
        }
        flushText()
        return tokens
    }
}

enum HTMLSanitizer {
    enum RemoteContent: Equatable { case allow, block }

    struct Result: Equatable {
        var html: String
        var hasRemoteImages: Bool
        var cidImages: Int
    }

    /// Kept as they are (with their allowed attributes).
    static let allowedElements: Set<String> = [
        "a", "abbr", "acronym", "address", "area", "article", "aside", "b", "bdi", "bdo", "big", "blockquote", "br",
        "caption", "center", "cite", "code", "col", "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt", "em",
        "fieldset", "figcaption", "figure", "font", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup",
        "hr", "i", "img", "ins", "kbd", "label", "legend", "li", "main", "map", "mark", "nav", "nobr", "ol", "p", "pre",
        "q", "rp", "rt", "ruby", "s", "samp", "section", "small", "span", "strike", "strong", "sub", "summary", "sup",
        "table", "tbody", "td", "tfoot", "th", "thead", "time", "tr", "tt", "u", "ul", "var", "wbr",
    ]
    /// Dropped together with everything inside them.
    static let droppedWithContent: Set<String> = [
        "script", "iframe", "frameset", "noframes", "object", "applet", "audio", "video", "canvas", "svg",
        "math", "template", "textarea", "select", "title", "xmp", "noembed", "plaintext", "xml", "portal", "datalist",
        "marquee",
    ]
    /// Void elements that are dropped (they have no content).
    static let droppedVoid: Set<String> = [
        "input", "meta", "link", "base", "basefont", "bgsound", "embed", "param", "source", "track", "keygen", "frame",
        "image", "isindex",
    ]
    static let voidElements: Set<String> = ["br", "hr", "img", "col", "wbr", "area"]

    static let allowedAttributes: Set<String> = [
        "align", "bgcolor", "border", "cellpadding", "cellspacing", "class", "color", "cols", "colspan", "dir", "face",
        "height", "hspace", "lang", "nowrap", "rowspan", "rules", "frame", "size", "span", "start", "style", "summary",
        "title", "type", "valign", "vspace", "width", "alt", "abbr", "axis", "headers", "scope", "datetime", "name",
        "shape", "coords", "reversed", "value", "open", "id", "role", "clear", "compact", "noshade", "char", "charoff",
        "label", "href", "src", "background", "usemap",
    ]

    static let maxAttributeLength = 4096
    static let maxDepth = 400
    static let maxDataImageLength = 2 << 20

    // MARK: Sanitizing

    /// `cids`: Content-IDs of this message's inline parts (any form: `<a@b>`, `a@b`, `cid:a%40b`); a `cid:`
    /// image survives only when its id is one of them.
    static func sanitize(_ html: String, remote: RemoteContent, cids: Set<String> = []) -> Result {
        let known = Set(cids.compactMap(MailCID.normalize))
        var out = ""
        out.reserveCapacity(html.utf8.count)
        var remoteFound = false
        var cids = 0
        var skip: [String] = []
        var open: [String] = []

        for token in HTMLTokenizer.tokenize(html) {
            if let top = skip.last {
                switch token {
                case .start(let name, _, let selfClosing) where name == top && !selfClosing: skip.append(name)
                case .end(let name) where name == top: skip.removeLast()
                default: break
                }
                continue
            }
            switch token {
            case .text(let raw):
                out += HTMLEntities.escapeText(HTMLEntities.decode(raw))
            case .rawText(let name, let content):
                // Only <style> survives as raw text; everything else here belongs to a dropped element.
                guard name == "style" else { continue }
                if let css = CSSSanitizer.block(content, remote: remote, found: &remoteFound), !css.isEmpty {
                    out += "<style>" + css + "</style>"
                }
            case .start(let name, let attributes, let selfClosing):
                if name == "style" { continue }   // its content arrives as .rawText
                if droppedWithContent.contains(name) {
                    if !selfClosing && !HTMLTokenizer.rawText.contains(name) { skip.append(name) }
                    continue
                }
                if droppedVoid.contains(name) { continue }
                let emitted = name == "body" ? "div" : name
                guard allowedElements.contains(emitted) else { continue }   // unwrap unknown elements
                if name == "img" {
                    switch image(attributes, remote: remote, cids: known, found: &remoteFound) {
                    case .drop: break
                    case .cid(let alt):
                        cids += 1
                        let label = alt.isEmpty ? "image" : "image: \(alt)"
                        out += "<span class=\"yc-inline-image\">[\(HTMLEntities.escapeText(label))]</span>"
                    case .keep(let attrs):
                        out += "<img" + serialize(attrs) + ">"
                    }
                    continue
                }
                let isVoid = voidElements.contains(emitted)
                if !isVoid && open.count >= maxDepth { continue }   // absurd nesting: unwrap the rest
                let attrs = clean(attributes, element: emitted, remote: remote, found: &remoteFound)
                out += "<\(emitted)" + serialize(attrs) + ">"
                if !isVoid { open.append(emitted) }
            case .end(let name):
                let emitted = name == "body" ? "div" : name
                guard allowedElements.contains(emitted), !voidElements.contains(emitted),
                      let index = open.lastIndex(of: emitted) else { continue }
                for closing in open[index...].reversed() { out += "</\(closing)>" }
                open.removeSubrange(index...)
            }
        }
        for closing in open.reversed() { out += "</\(closing)>" }
        return Result(html: out, hasRemoteImages: remoteFound, cidImages: cids)
    }

    private enum ImageDecision { case drop, cid(alt: String), keep([HTMLAttribute]) }

    private static func image(_ attributes: [HTMLAttribute], remote: RemoteContent, cids: Set<String>,
                              found: inout Bool) -> ImageDecision {
        let alt = attributes.first { $0.name == "alt" }?.value ?? ""
        if let srcset = attributes.first(where: { $0.name == "srcset" })?.value, srcset.lowercased().contains("http") {
            found = true
        }
        guard let src = attributes.first(where: { $0.name == "src" }) else {
            return .keep(clean(attributes, element: "img", remote: remote, found: &found))
        }
        let (kind, normalized) = URLPolicy.classify(src.value)
        switch kind {
        case .cid:
            guard let id = MailCID.normalize(normalized), cids.contains(id) else { return .cid(alt: String(alt.prefix(80))) }
            var attrs = clean(attributes.filter { $0.name != "src" }, element: "img", remote: remote, found: &found)
            attrs.insert(HTMLAttribute(name: "src", value: MailCID.src(id)), at: 0)
            return .keep(attrs)
        case .web, .dataImage:
            var attrs = clean(attributes.filter { $0.name != "src" }, element: "img", remote: remote, found: &found)
            if kind == .web {
                found = true
                if remote == .block {
                    attrs.append(HTMLAttribute(name: "data-yc-blocked", value: "1"))
                    return .keep(attrs)
                }
            } else if normalized.count > maxDataImageLength {
                return .drop
            }
            attrs.insert(HTMLAttribute(name: "src", value: normalized), at: 0)
            return .keep(attrs)
        default:
            return .drop
        }
    }

    /// Allowed attributes with checked values, in input order.
    private static func clean(_ attributes: [HTMLAttribute], element: String, remote: RemoteContent,
                              found: inout Bool) -> [HTMLAttribute] {
        var out: [HTMLAttribute] = []
        for attr in attributes {
            let name = attr.name
            guard allowedAttributes.contains(name) || (name.hasPrefix("aria-") && name.count < 32
                                                       && name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0 == "-") })
            else { continue }
            guard attr.value.count <= maxAttributeLength else { continue }
            switch name {
            case "href":
                guard element == "a" || element == "area" else { continue }
                let (kind, normalized) = URLPolicy.classify(attr.value)
                switch kind {
                case .web, .mailto, .tel, .anchor: out.append(HTMLAttribute(name: "href", value: normalized))
                default: continue
                }
            case "src":
                continue   // only <img>, handled by image()
            case "background":
                let (kind, normalized) = URLPolicy.classify(attr.value)
                switch kind {
                case .web:
                    found = true
                    if remote == .allow { out.append(HTMLAttribute(name: name, value: normalized)) }
                case .dataImage:
                    out.append(HTMLAttribute(name: name, value: normalized))
                default:
                    continue
                }
            case "usemap":
                guard attr.value.hasPrefix("#") else { continue }
                out.append(attr)
            case "style":
                let css = CSSSanitizer.declarations(attr.value, remote: remote, found: &found)
                if !css.isEmpty { out.append(HTMLAttribute(name: "style", value: css)) }
            case "class":
                // The `yc-` prefix is the reader's (MailQuote, MailPlainText): never from a sender.
                let tokens = attr.value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" })
                let kept = tokens.filter { !MailCID.isReserved($0) }
                if !kept.isEmpty { out.append(HTMLAttribute(name: "class", value: kept.joined(separator: " "))) }
            case "id":
                if !MailCID.isReserved(Substring(attr.value).drop(while: { $0 == " " || $0 == "\t" })) { out.append(attr) }
            default:
                out.append(attr)
            }
        }
        if element == "a", out.contains(where: { $0.name == "href" }) {
            out.append(HTMLAttribute(name: "rel", value: "noopener noreferrer"))
        }
        return out
    }

    private static func serialize(_ attributes: [HTMLAttribute]) -> String {
        var out = ""
        for a in attributes { out += " \(a.name)=\"\(HTMLEntities.escapeAttribute(a.value))\"" }
        return out
    }

    // MARK: Plain text

    /// Readable text from HTML: block elements become line breaks, list items get bullets, whitespace
    /// collapses (except in <pre>), hidden content (script, style, title, head-only) is left out.
    static func text(fromHTML html: String) -> String {
        let blocks: Set<String> = ["p", "div", "br", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "hr",
                                   "ul", "ol", "section", "article", "header", "footer", "pre", "address", "dl", "dt", "dd",
                                   "center", "form", "fieldset", "body", "li", "figure", "main", "nav", "aside", "caption"]
        var out = ""
        var skip: [String] = []
        var pre = 0
        for token in HTMLTokenizer.tokenize(html) {
            if let top = skip.last {
                switch token {
                case .start(let name, _, let selfClosing) where name == top && !selfClosing: skip.append(name)
                case .end(let name) where name == top: skip.removeLast()
                default: break
                }
                continue
            }
            switch token {
            case .text(let raw):
                let decoded = HTMLEntities.decode(raw)
                if pre > 0 {
                    out += decoded
                } else {
                    var collapsed = ""
                    var lastSpace = out.last.map { $0 == " " || $0 == "\n" } ?? true
                    for ch in decoded {
                        if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{0C}" {
                            if !lastSpace { collapsed.append(" ") }
                            lastSpace = true
                        } else {
                            collapsed.append(ch == "\u{00A0}" ? " " : ch)
                            lastSpace = false
                        }
                    }
                    out += collapsed
                }
            case .rawText:
                continue
            case .start(let name, _, let selfClosing):
                if droppedWithContent.contains(name) {
                    if !selfClosing && !HTMLTokenizer.rawText.contains(name) { skip.append(name) }
                    continue
                }
                if name == "pre" { pre += 1 }
                if name == "li" {
                    trimTrailingSpaces(&out)
                    if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                    out += "\u{2022} "
                } else if name == "td" || name == "th" {
                    if let last = out.last, last != "\n", last != " ", last != "\t" { out += " " }
                } else if name == "img", case .start(_, let attrs, _) = token,
                          let alt = attrs.first(where: { $0.name == "alt" })?.value, !alt.isEmpty, alt.count < 80 {
                    out += alt
                } else if blocks.contains(name) {
                    trimTrailingSpaces(&out)
                    if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                    if name == "p" && !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
                }
            case .end(let name):
                if name == "pre" { pre = max(0, pre - 1) }
                if blocks.contains(name) {
                    trimTrailingSpaces(&out)
                    if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                    if name == "p" && !out.hasSuffix("\n\n") { out += "\n" }
                }
            }
        }
        return tidyText(out)
    }

    private static func trimTrailingSpaces(_ s: inout String) {
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
    }

    /// Trailing blanks off every line, at most one empty line in a row, no leading/trailing blank lines.
    static func tidyText(_ text: String) -> String {
        var lines: [String] = []
        var blank = 0
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            if line.isEmpty {
                blank += 1
                if blank > 1 || lines.isEmpty { continue }
            } else {
                blank = 0
            }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Plain text → HTML that keeps its line breaks (for multipart/mixed bodies that mix both).
    static func html(fromText text: String) -> String {
        "<div style=\"white-space: pre-wrap\">" + HTMLEntities.escapeText(text) + "</div>"
    }
}

// MARK: - Inline parts (cid:)

/// Content-IDs as the sanitizer, the cache and the reader's `cid` scheme handler compare them (rich mail, D-040).
enum MailCID {
    /// `cid:` (any case) dropped, percent-decoded, angle brackets and spaces stripped, lowercased. Nil when empty.
    static func normalize(_ raw: String) -> String? {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.count >= 4, s.prefix(4).lowercased() == "cid:" { s = s.dropFirst(4) }
        let decoded = String(s).removingPercentEncoding ?? String(s)
        let id = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
        return id.isEmpty ? nil : id
    }

    /// The `src` the sanitizer emits for a known inline part (the id normalized, then percent-encoded).
    static func src(_ id: String) -> String {
        "cid:" + (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)
    }

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(0x7F)))
        set.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return set
    }()

    /// Raster images and HEIC/HEIF: the only types the reader's `cid` handler serves (and the prefetch fetches).
    static func isImageType(_ mimeType: String) -> Bool {
        let t = mimeType.lowercased().trimmingCharacters(in: .whitespaces)
        return URLPolicy.rasterImages.contains(t) || t == "image/heic" || t == "image/heif"
    }

    /// What the bytes really are, by their magic numbers: a raster type, or nil (HTML, SVG, PDF, anything else).
    /// The `cid` handler answers with this type, never with the one the sender declared.
    static func rasterType(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        func at(_ i: Int, _ bytes: [UInt8]) -> Bool { b.count >= i + bytes.count && Array(b[i..<(i + bytes.count)]) == bytes }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if at(0, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if at(0, Array("GIF87a".utf8)) || at(0, Array("GIF89a".utf8)) { return "image/gif" }
        if at(0, Array("RIFF".utf8)), at(8, Array("WEBP".utf8)) { return "image/webp" }
        if at(0, Array("BM".utf8)), b.count >= 14 { return "image/bmp" }
        if at(0, [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if at(4, Array("ftyp".utf8)), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return "image/heic" }
            if ["avif", "avis"].contains(brand) { return "image/avif" }
        }
        return nil
    }

    /// `yc-…` (any case): reserved for the reader's own markers.
    static func isReserved<S: StringProtocol>(_ token: S) -> Bool {
        token.count >= 3 && token.prefix(3).lowercased() == "yc-"
    }
}

// MARK: - URLs

enum URLPolicy {
    enum Kind: Equatable { case web, mailto, tel, anchor, dataImage, cid, bad }

    static let rasterImages: Set<String> = ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp", "image/bmp",
                                            "image/x-icon", "image/avif"]

    /// Browser-style normalization (C0 controls and spaces trimmed, tab/LF/CR removed anywhere), then
    /// the scheme decides. Returns the normalized URL to emit.
    static func classify(_ raw: String) -> (Kind, String) {
        var scalars = String.UnicodeScalarView()
        for c in raw.unicodeScalars where !(c == "\t" || c == "\n" || c == "\r") { scalars.append(c) }
        var value = String(scalars)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: Unicode.Scalar(UInt8(0))...Unicode.Scalar(UInt8(0x20))))
        guard !value.isEmpty else { return (.bad, value) }
        if value.hasPrefix("#") { return (.anchor, value) }
        var scheme = ""
        for c in value.unicodeScalars {
            if c == ":" { break }
            if c == "/" || c == "?" || c == "#" { return (.bad, value) }   // relative: nothing to resolve against
            scheme.unicodeScalars.append(c)
        }
        guard scheme.count < value.count, !scheme.isEmpty,
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return (.bad, value) }
        switch scheme.lowercased() {
        case "http", "https":
            return (.web, value)
        case "mailto":
            return (.mailto, value)
        case "tel":
            return (.tel, value)
        case "cid":
            return (.cid, value)
        case "data":
            let rest = value.dropFirst(5)
            guard let comma = rest.firstIndex(of: ",") else { return (.bad, value) }
            let meta = rest[..<comma].lowercased().split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = meta.first, rasterImages.contains(type), meta.contains("base64") else { return (.bad, value) }
            return (.dataImage, value)
        default:
            return (.bad, value)
        }
    }
}

// MARK: - CSS

enum CSSSanitizer {
    /// Fragments that never survive, checked on a lowercased, comment-free, whitespace-free copy.
    static let forbidden = ["expression(", "javascript:", "vbscript:", "-moz-binding", "behavior:", "behaviour:",
                            "binding:", "image-set(", "-o-link", "@import", "</", "<!--", "mocha:", "livescript:"]

    /// A `style` attribute: `prop: value` pairs, each checked; unsafe ones are dropped.
    static func declarations(_ css: String, remote: HTMLSanitizer.RemoteContent, found: inout Bool) -> String {
        let text = stripComments(css)
        // Newsletters carry thousands of inline styles (the rich mail budget): plain ASCII ones without escapes take
        // a byte-level path with exactly the same rules; anything else the general one below.
        if text.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x5C }) { return asciiDeclarations(text, remote: remote, found: &found) }
        var kept: [String] = []
        for decl in split(text, on: ";") {
            guard let colon = decl.firstIndex(of: ":") else { continue }
            let prop = decl[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prop.isEmpty, !value.isEmpty, prop.count < 64,
                  prop.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || $0 == "-" || ("0"..."9").contains($0)) }),
                  !["behavior", "behaviour", "-moz-binding", "binding"].contains(prop),
                  !value.contains("\\"), !value.contains("<"), !value.contains(">"), !value.contains("{"), !value.contains("}")
            else { continue }
            let squashed = squash(value)
            guard !forbidden.contains(where: squashed.contains) else { continue }
            if squashed.contains("url(") {
                guard let rewritten = rewriteURLs(value, remote: remote, found: &found) else { continue }
                value = rewritten
            }
            kept.append("\(prop): \(value)")
        }
        return kept.joined(separator: "; ")
    }

    private static let forbiddenBytes: [[UInt8]] = forbidden.map { Array($0.utf8) }
    private static let bannedProperties: Set<String> = ["behavior", "behaviour", "-moz-binding", "binding"]

    /// `declarations` for ASCII text without backslashes: the same split (outside quotes and parentheses), trim,
    /// property and value checks, squash (lowercased, whitespace removed) and forbidden list, over bytes.
    private static func asciiDeclarations(_ text: String, remote: HTMLSanitizer.RemoteContent, found: inout Bool) -> String {
        let b = Array(text.utf8)
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || (0x09...0x0D).contains(c) }
        func trimmed(_ lo: Int, _ hi: Int) -> (Int, Int) {
            var (l, h) = (lo, hi)
            while l < h, isSpace(b[l]) { l += 1 }
            while h > l, isSpace(b[h - 1]) { h -= 1 }
            return (l, h)
        }
        var kept: [String] = []
        func declaration(_ lo: Int, _ hi: Int) {
            guard let colon = b[lo..<hi].firstIndex(of: 0x3A) else { return }
            let (pl, ph) = trimmed(lo, colon)
            let (vl, vh) = trimmed(colon + 1, hi)
            guard ph > pl, vh > vl, ph - pl < 64 else { return }
            var prop = [UInt8]()
            prop.reserveCapacity(ph - pl)
            for c in b[pl..<ph] {
                let lower = (0x41...0x5A).contains(c) ? c + 0x20 : c
                guard (0x61...0x7A).contains(lower) || (0x30...0x39).contains(lower) || lower == 0x2D else { return }
                prop.append(lower)
            }
            let property = String(decoding: prop, as: UTF8.self)
            guard !bannedProperties.contains(property) else { return }
            var squashed = [UInt8]()
            squashed.reserveCapacity(vh - vl)
            for c in b[vl..<vh] {
                if c == 0x3C || c == 0x3E || c == 0x7B || c == 0x7D { return }   // < > { }
                if !isSpace(c) { squashed.append((0x41...0x5A).contains(c) ? c + 0x20 : c) }
            }
            for needle in forbiddenBytes where contains(squashed, needle) { return }
            var value = String(decoding: b[vl..<vh], as: UTF8.self)
            if contains(squashed, Array("url(".utf8)) {
                guard let rewritten = rewriteURLs(value, remote: remote, found: &found) else { return }
                value = rewritten
            }
            kept.append(property + ": " + value)
        }
        var start = 0
        var quote: UInt8?
        var depth = 0
        for (i, c) in b.enumerated() {
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            switch c {
            case 0x22, 0x27: quote = c
            case 0x28: depth += 1
            case 0x29: depth = max(0, depth - 1)
            case 0x3B where depth == 0:
                declaration(start, i)
                start = i + 1
            default: break
            }
        }
        declaration(start, b.count)
        return kept.joined(separator: "; ")
    }

    /// `needle` occurs in `haystack` (bytes).
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return needle.isEmpty }
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// A `<style>` element. Nil when it must go entirely (expression(), bindings, script URLs anywhere).
    static func block(_ css: String, remote: HTMLSanitizer.RemoteContent, found: inout Bool) -> String? {
        let text = stripComments(css)
        let squashed = squash(unescape(text))
        for bad in ["expression(", "-moz-binding", "behavior:", "behaviour:", "javascript:", "vbscript:"] where squashed.contains(bad) {
            return nil
        }
        return rules(text, remote: remote, found: &found, depth: 0)
    }

    private static func rules(_ css: String, remote: HTMLSanitizer.RemoteContent, found: inout Bool, depth: Int) -> String {
        guard depth < 4 else { return "" }
        let s = Array(css)
        var out = ""
        var i = 0
        while i < s.count {
            while i < s.count, s[i].isWhitespace { i += 1 }
            guard i < s.count else { break }
            // Prelude: up to '{' (a rule) or ';' (a statement at-rule, dropped).
            var j = i
            var quote: Character?
            while j < s.count {
                if let q = quote { if s[j] == q { quote = nil } } else if s[j] == "\"" || s[j] == "'" { quote = s[j] } else if s[j] == "{" || s[j] == ";" || s[j] == "}" { break }
                j += 1
            }
            let prelude = String(s[i..<min(j, s.count)]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard j < s.count, s[j] == "{" else { i = j + 1; continue }
            // Body: to the matching '}'.
            var k = j + 1
            var level = 1
            quote = nil
            while k < s.count {
                if let q = quote { if s[k] == q { quote = nil } } else if s[k] == "\"" || s[k] == "'" { quote = s[k] } else if s[k] == "{" { level += 1 } else if s[k] == "}" {
                    level -= 1
                    if level == 0 { break }
                }
                k += 1
            }
            let body = String(s[(j + 1)..<min(k, s.count)])
            i = k + 1
            guard !prelude.isEmpty, !prelude.contains("<"), !prelude.contains("\\"), !squash(prelude).contains("url(")
            else { continue }
            let lower = prelude.lowercased()
            if lower.hasPrefix("@") {
                if lower.hasPrefix("@media") || lower.hasPrefix("@supports") {
                    let inner = rules(body, remote: remote, found: &found, depth: depth + 1)
                    if !inner.isEmpty { out += "\(prelude){\(inner)}" }
                } else if lower.hasPrefix("@font-face") || lower.hasPrefix("@page") {
                    let decls = declarations(body, remote: remote, found: &found)
                    if !decls.isEmpty { out += "\(prelude){\(decls)}" }
                } else if lower.hasPrefix("@keyframes") || lower.hasPrefix("@-webkit-keyframes") {
                    let inner = rules(body, remote: remote, found: &found, depth: depth + 1)
                    if !inner.isEmpty { out += "\(prelude){\(inner)}" }
                }
                continue
            }
            let decls = declarations(body, remote: remote, found: &found)
            if !decls.isEmpty { out += "\(prelude){\(decls)}" }
        }
        return out
    }

    /// Rewrites every `url(…)`: http(s) marks remote content (kept when allowed, `none` when blocked),
    /// raster data: images stay, anything else rejects the declaration (nil).
    private static func rewriteURLs(_ value: String, remote: HTMLSanitizer.RemoteContent, found: inout Bool) -> String? {
        let s = Array(value)
        var out = ""
        var i = 0
        while i < s.count {
            if i + 3 < s.count, String(s[i...(i + 3)]).lowercased() == "url(" {
                var j = i + 4
                while j < s.count, s[j].isWhitespace { j += 1 }
                var arg = ""
                if j < s.count, s[j] == "\"" || s[j] == "'" {
                    let q = s[j]
                    j += 1
                    while j < s.count, s[j] != q { arg.append(s[j]); j += 1 }
                    j += 1
                    while j < s.count, s[j].isWhitespace { j += 1 }
                } else {
                    while j < s.count, s[j] != ")" { arg.append(s[j]); j += 1 }
                    arg = arg.trimmingCharacters(in: .whitespaces)
                }
                guard j < s.count, s[j] == ")" else { return nil }
                let (kind, normalized) = URLPolicy.classify(arg)
                switch kind {
                case .web:
                    found = true
                    out += remote == .allow ? "url(\"\(normalized.replacingOccurrences(of: "\"", with: "%22"))\")" : "none"
                case .dataImage:
                    out += "url(\"\(normalized.replacingOccurrences(of: "\"", with: "%22"))\")"
                default:
                    return nil
                }
                i = j + 1
                continue
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    static func stripComments(_ css: String) -> String {
        guard css.contains("/*") else { return css }
        var out = ""
        var rest = Substring(css)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "*/") else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// Lowercased, CSS escapes resolved, whitespace removed: what detection runs on.
    static func squash(_ css: String) -> String {
        unescape(css).lowercased().filter { !$0.isWhitespace }
    }

    /// `\65 xpression` → `expression` (1–6 hex digits + one optional space, or an escaped character).
    static func unescape(_ css: String) -> String {
        guard css.contains("\\") else { return css }
        let s = Array(css.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            guard s[i] == "\\", i + 1 < s.count else { out.append(s[i]); i += 1; continue }
            var hex = ""
            var j = i + 1
            while j < s.count, hex.count < 6, s[j].properties.isASCIIHexDigit { hex.unicodeScalars.append(s[j]); j += 1 }
            if !hex.isEmpty {
                if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) { out.append(scalar) }
                if j < s.count, s[j] == " " || s[j] == "\t" || s[j] == "\n" { j += 1 }
                i = j
            } else {
                out.append(s[i + 1])
                i += 2
            }
        }
        return String(out)
    }

    /// Splits on `separator` outside quotes and parentheses.
    static func split(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            switch ch {
            case "\"", "'": quote = ch; current.append(ch)
            case "(": depth += 1; current.append(ch)
            case ")": depth = max(0, depth - 1); current.append(ch)
            default:
                if ch == separator && depth == 0 { parts.append(current); current = "" } else { current.append(ch) }
            }
        }
        parts.append(current)
        return parts
    }
}
