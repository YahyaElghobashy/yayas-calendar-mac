import Foundation

// Plain-text mail → the reader's own HTML (rich mail, D-040), so plain and HTML mail
// draw through the same locked web view. Every character of the input is escaped (HTMLEntities.escapeText):
// the only markup is ours. Lines become one <div> each (white-space: pre-wrap keeps their spaces); ">" runs
// become nested quote bars with the ">" characters removed; an "On … wrote:" line joins its run; trailing
// history collapses behind the same "•••" as HTML mail (MailQuote); the "-- " signature is dimmed;
// format=flowed is unflowed first (RFC 3676); tables, box drawing and code stay monospace; web links and
// addresses are linked (http, https, mailto only, through URLPolicy).

enum MailPlainText {
    static func html(_ text: String, flowed: Bool, delsp: Bool) -> String {
        let lines = parse(text, flowed: flowed, delsp: delsp)
        let layout = Layout(lines)
        var out = "<div class=\"yc-plain\" dir=\"auto\">"
        out.reserveCapacity(text.utf8.count * 5 / 4 + 256)
        var depth = 0
        var i = 0
        func close(to level: Int) {
            while depth > level { out += "</blockquote>"; depth -= 1 }
        }
        while i < lines.count {
            if layout.history?.lowerBound == i {
                close(to: 0)
                out += MailQuote.openTag + MailQuote.summary
            }
            if layout.signature?.lowerBound == i {
                close(to: 0)
                out += "<div class=\"yc-sig\">"
            }
            let line = lines[i]
            if depth < line.depth {
                while depth < line.depth { out += "<blockquote class=\"yc-q\">"; depth += 1 }
            } else {
                close(to: line.depth)
            }
            if let pre = layout.pre[i] {
                out += "<div class=\"yc-pre\">"
                out += lines[pre].map { linkify($0.text) }.joined(separator: "\n")
                out += "</div>"
                i = pre.upperBound
            } else {
                out += line.text.isEmpty ? "<div><br></div>" : "<div>" + linkify(line.text) + "</div>"
                i += 1
            }
            if layout.signature?.upperBound == i {
                close(to: 0)
                out += "</div>"
            }
            if layout.history?.upperBound == i {
                close(to: 0)
                out += MailQuote.closeTag
            }
        }
        close(to: 0)
        return out + "</div>"
    }

    // MARK: Lines

    struct Line: Equatable {
        var depth: Int
        var text: String
    }

    /// CRLF/CR → LF, quote depth and space-stuffing, then (flowed) soft breaks joined.
    static func parse(_ text: String, flowed: Bool, delsp: Bool) -> [Line] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var raw = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while raw.last?.isEmpty == true { raw.removeLast() }
        var out: [Line] = []
        var joining = false
        for rawLine in raw {
            var (depth, body) = quoteDepth(rawLine, strict: flowed)
            if flowed {
                let isSignature = body == "-- "
                let soft = body.hasSuffix(" ") && !isSignature
                if soft, delsp { body.removeLast() }
                if joining, let last = out.last, last.depth == depth {
                    out[out.count - 1].text += body
                } else {
                    out.append(Line(depth: depth, text: body))
                }
                joining = soft
            } else {
                while body.last == " " || body.last == "\t" { body.removeLast() }
                out.append(Line(depth: depth, text: body))
            }
        }
        if flowed {
            for i in out.indices where out[i].text != "-- " {
                while out[i].text.last == " " { out[i].text.removeLast() }
            }
        }
        return out
    }

    /// Leading ">" markers. Flowed (strict, RFC 3676): no spaces between them. Otherwise "> > x" counts 2.
    /// One space after the markers is removed, and flowed text's stuffed space; unquoted fixed text keeps its
    /// indentation.
    static func quoteDepth(_ line: String, strict: Bool) -> (Int, String) {
        var depth = 0
        var rest = Substring(line)
        while let first = rest.first {
            if first == ">" {
                depth += 1
                rest = rest.dropFirst()
            } else if !strict, depth > 0, first == " ", rest.dropFirst().first == ">" {
                rest = rest.dropFirst()
            } else {
                break
            }
        }
        if rest.first == " ", depth > 0 || strict { rest = rest.dropFirst() }
        return (depth, String(rest))
    }

    // MARK: Layout (signature, history, preformatted blocks)

    struct Layout {
        /// Lines of the "-- " signature (outside quotes).
        var signature: Range<Int>?
        /// Trailing quoted history (attribution + quote run, or Outlook's "-----Original Message-----" to the end).
        var history: Range<Int>?
        /// Preformatted groups by their first line.
        var pre: [Int: Range<Int>] = [:]

        init(_ lines: [Line]) {
            let n = lines.count
            func blank(_ i: Int) -> Bool { lines[i].text.trimmingCharacters(in: .whitespaces).isEmpty }
            let sigStart = lines.lastIndex { $0.depth == 0 && ($0.text == "-- " || $0.text == "--") }

            // History: Outlook's marker first, else the last ">" run with its attribution.
            var history: Range<Int>?
            for i in 0..<n where lines[i].depth == 0 && MailPlainText.isOutlookMarker(lines[i].text) {
                var j = i + 1
                while j < n, blank(j) { j += 1 }
                if j < n, lines[j].depth == 0, lines[j].text.hasPrefix("From:") { history = i..<n; break }
            }
            if history == nil, let end = lines.lastIndex(where: { $0.depth > 0 }) {
                var start = end
                while start > 0, lines[start - 1].depth > 0 { start -= 1 }
                // "On … wrote:" right before the run (one blank line allowed), possibly wrapped over two lines.
                var a = start - 1
                if a >= 0, blank(a), lines[a].depth == 0 { a -= 1 }
                if a >= 0, lines[a].depth == 0 {
                    if MailQuote.isAttribution(lines[a].text) {
                        start = a
                    } else if a >= 1, lines[a - 1].depth == 0, MailQuote.isAttribution(lines[a - 1].text + " " + lines[a].text) {
                        start = a - 1
                    }
                }
                // Trailing: after the run only blank lines and our signature; something visible before it.
                var trailing = true
                var k = end + 1
                while k < n {
                    if let sigStart, sigStart > end, k >= sigStart { break }
                    if !blank(k) { trailing = false; break }
                    k += 1
                }
                if trailing { history = start..<(end + 1) }
            }
            if let h = history, !(0..<h.lowerBound).contains(where: { !blank($0) }) { history = nil }
            self.history = history

            // Signature: from "-- " to the end, or to the history that follows it; never inside the history.
            if let s = sigStart {
                if let h = history, h.contains(s) {
                    signature = nil
                } else if let h = history, h.lowerBound > s {
                    signature = s..<h.lowerBound
                } else {
                    signature = s..<n
                }
            }

            // Preformatted: inside a paragraph (non-blank lines at one depth, not crossing the signature or
            // the history edges), the lines from the first to the last table/box/code-looking line, when that
            // span is 3+ lines with 2+ such lines.
            var i = 0
            while i < n {
                guard !blank(i) else { i += 1; continue }
                var j = i + 1
                while j < n, !blank(j), lines[j].depth == lines[i].depth,
                      j != signature?.lowerBound, j != history?.lowerBound, j != history?.upperBound, j != signature?.upperBound {
                    j += 1
                }
                let marked = (i..<j).filter { MailPlainText.looksPreformatted(lines[$0].text) }
                if marked.count >= 2, let a = marked.first, let b = marked.last, b - a >= 2 { pre[a] = a..<(b + 1) }
                i = j
            }
        }
    }

    static func isOutlookMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-----"), t.contains("Original Message") { return true }
        return t.count >= 10 && t.allSatisfy { $0 == "_" }
    }

    /// A line of a table, a box drawing, ASCII art or code: an interior gap of 2+ spaces that isn't the space
    /// after a sentence, a tab, box-drawing characters, a leading "|" or "+-", or code indentation.
    static func looksPreformatted(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: { (0x2500...0x257F).contains($0.value) }) { return true }
        if text.hasPrefix("|") || text.hasPrefix("+-") { return true }
        if text.hasPrefix("\t") || text.hasPrefix("    ") { return true }
        let chars = Array(text)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }   // leading spaces aren't interior
        var previous: Character = " "
        while i < chars.count {
            let c = chars[i]
            if c == "\t" { return true }
            if c == " ", i + 1 < chars.count, chars[i + 1] == " " {
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, !".!?:;,".contains(previous) { return true }
                i = j
                continue
            }
            previous = c
            i += 1
        }
        return false
    }

    // MARK: Links

    static let maxURL = 2048

    /// Escapes `text` and links http(s) URLs, `www.` hosts (linked as https) and email addresses.
    static func linkify(_ text: String) -> String {
        guard mayLink(text) else { return HTMLEntities.escapeText(text) }
        var out = ""
        let scalars = text.unicodeScalars
        var wordStart = scalars.startIndex
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == " " || c == "\t" || c == "\u{00A0}" {
                if wordStart < i { out += linkWord(String(scalars[wordStart..<i])) }
                out.unicodeScalars.append(c)
                wordStart = scalars.index(after: i)
            }
            i = scalars.index(after: i)
        }
        if wordStart < scalars.endIndex { out += linkWord(String(scalars[wordStart...])) }
        return out
    }

    /// Cheap byte check: an "@", a "://" or a "www." (any case) somewhere; most lines have none.
    static func mayLink(_ text: String) -> Bool {
        var found = false
        func run(_ b: UnsafeBufferPointer<UInt8>) {
            let n = b.count
            var i = 0
            while i < n {
                let c = b[i]
                if c == 0x40 { found = true; return }
                if c == 0x3A, i + 2 < n, b[i + 1] == 0x2F, b[i + 2] == 0x2F { found = true; return }
                if c | 0x20 == 0x77, i + 3 < n, b[i + 1] | 0x20 == 0x77, b[i + 2] | 0x20 == 0x77, b[i + 3] == 0x2E { found = true; return }
                i += 1
            }
        }
        if text.utf8.withContiguousStorageIfAvailable(run) == nil { return true }
        return found
    }

    private static func linkWord(_ word: String) -> String {
        guard mayLink(word) else { return HTMLEntities.escapeText(word) }
        var best: String.Index?
        for marker in ["https://", "http://", "www."] {
            var search = word.startIndex
            while let r = word.range(of: marker, options: .caseInsensitive, range: search..<word.endIndex) {
                let before = r.lowerBound == word.startIndex ? nil : word[word.index(before: r.lowerBound)]
                if !(before?.isLetter ?? false || before?.isNumber ?? false) {
                    if best.map({ r.lowerBound < $0 }) ?? true { best = r.lowerBound }
                    break
                }
                search = r.upperBound
            }
        }
        if let start = best {
            if let link = link(String(word[start...]), web: true) {
                return HTMLEntities.escapeText(String(word[..<start])) + link
            }
        }
        if word.contains("@") {
            var start = word.startIndex
            while start < word.endIndex, "(<[\"'".contains(word[start]) { start = word.index(after: start) }
            if let link = link(String(word[start...]), web: false) {
                return HTMLEntities.escapeText(String(word[..<start])) + link
            }
        }
        return HTMLEntities.escapeText(word)
    }

    /// `candidate` runs from the link's first character to the end of the word; returns the link and the
    /// escaped remainder, or nil when it isn't a link.
    private static func link(_ candidate: String, web: Bool) -> String? {
        var body = candidate
        var tail = ""
        if let stop = body.firstIndex(where: { "<>\"".contains($0) }) {
            tail = String(body[stop...])
            body = String(body[..<stop])
        }
        // Trailing punctuation and closing brackets that don't balance.
        while let last = body.last {
            if ".,;:!?'\"".contains(last) {
                tail = String(last) + tail
                body.removeLast()
                continue
            }
            let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
            if let open = pairs[last], body.filter({ $0 == last }).count > body.filter({ $0 == open }).count {
                tail = String(last) + tail
                body.removeLast()
                continue
            }
            break
        }
        guard !body.isEmpty, body.utf8.count <= maxURL else { return nil }
        let href: String
        if web {
            let lower = body.lowercased()
            if lower.hasPrefix("www.") {
                let host = body.dropFirst(4).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
                guard host.contains("."), !host.hasSuffix("."), host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
                else { return nil }
                href = "https://" + body
            } else {
                href = body
            }
            guard URLPolicy.classify(href).0 == .web, let url = URL(string: href), url.host?.isEmpty == false else { return nil }
        } else {
            var address = body
            if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
            guard isAddress(address) else { return nil }
            href = "mailto:" + address
            guard URLPolicy.classify(href).0 == .mailto else { return nil }
        }
        return "<a href=\"\(HTMLEntities.escapeAttribute(href))\">\(HTMLEntities.escapeText(body))</a>" + HTMLEntities.escapeText(tail)
    }

    /// One local part, "@" and a dotted domain, all plain ASCII.
    static func isAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last, !local.isEmpty, domain.contains("."),
              local.utf8.count <= 64, domain.utf8.count <= 253,
              local.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._%+-".contains($0)) }),
              domain.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(".."),
              let tld = domain.split(separator: ".").last, tld.count >= 2, tld.allSatisfy(\.isLetter)
        else { return false }
        return true
    }
}
