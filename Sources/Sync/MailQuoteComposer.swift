import Foundation

/// The quoted original of a rich reply or forward (rich mail, D-041), composed by the data layer
/// from its own sanitized body cache at send time: surfaces never hand another sender's HTML back for sending.
///
/// - Reply, bar (Gmail): `div.gmail_quote` › `div.gmail_attr` "On …, Name <addr> wrote:" › `blockquote.gmail_quote`,
///   so Gmail (and our own `MailQuote`) collapse it. text/plain: the attribution and every line behind "> " (1 MB at most).
/// - Reply, header (Outlook): a rule, `#divRplyFwdMsg` with From, Sent, To, Cc, Subject, then the original, no bar.
/// - Forward: `div.gmail_quote` with "---------- Forwarded message ---------", From, Date, Subject, To, Cc.
///
/// The original's HTML loses its `<style>` elements (they would restyle the whole outgoing mail in recipients' clients),
/// every `id`, anything carrying the reader's reserved `yc-` prefix, and the inline styles that move or hide content
/// (position, offsets, z-index, transforms, opacity, clipping, negative margins, display:none, visibility), which a
/// sender could use to lay text over the reply in the recipient's client; other inline styles stay. Remote image URLs
/// stay (as in Gmail; they are never loaded here). The inline images it draws come back as parts to attach with their
/// original Content-IDs, or with a fresh one (the reference rewritten) when the sender's can't be sent as it is.
enum MailQuoteComposer {
    struct Image: Equatable {
        var contentId: String
        var partId: String
        var mimeType: String
        var filename: String
    }

    struct Output: Equatable {
        /// Appended after the reply's own HTML.
        var html: String
        /// Appended after the reply's own text/plain and a blank line.
        var text: String
        /// The original's inline images the quoted HTML draws (cid:), to send as multipart/related parts.
        var images: [Image]
    }

    static let maxPlainQuote = 1 << 20
    static let outlookRule = "________________________________"

    static func compose(_ m: CachedMessage, kind: MailQuoteRequest.Kind, style: MailQuoteRequest.Style) -> Output {
        let original = m.html.map(clean) ?? HTMLSanitizer.html(fromText: m.text)
        let e = MailHTMLWriter.escape
        let html: String
        let text: String
        switch (kind, style) {
        case (.forward, _):
            let lines = MailAttribution.forwardHeader(name: m.from, address: m.fromEmail, date: m.date, to: m.to, cc: m.cc, subject: m.subject)
            html = "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(e(MailAttribution.forwardLine))<br>"
                + lines.map { "\($0.0): \(headerHTML($0.0, $0.1))<br>" }.joined() + "</div><br><br>\(original)</div>"
            text = MailAttribution.forwardLine + "\n" + lines.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n"
                + clipped(m.text)
        case (.reply, .bar):
            let attribution = MailAttribution.line(name: m.from, address: m.fromEmail, date: m.date)
            html = "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(e(attribution))<br></div>"
                + "<blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\">"
                + original + "</blockquote></div>"
            text = attribution + "\n" + quoted(m.text)
        case (.reply, .header):
            let lines = MailAttribution.header(name: m.from, address: m.fromEmail, date: m.date, to: m.to, cc: m.cc, subject: m.subject)
            html = "<hr style=\"display:inline-block;width:98%\"><div id=\"divRplyFwdMsg\" dir=\"ltr\">"
                + lines.map { "<b>\(e($0.0)):</b> \(e($0.1))" }.joined(separator: "<br>") + "</div><br>" + original
            text = outlookRule + "\n" + lines.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n\n" + clipped(m.text)
        }
        let drawn = m.html == nil ? [] : CachedMessage.referencedCIDs(original)
        var images: [Image] = []
        var handled = Set<String>()
        var taken = drawn
        var out = html
        for a in m.attachments where a.isInline && !a.partId.isEmpty {
            // Matched as the sanitizer saw the sender's id (normalized, not cleaned).
            guard let raw = a.contentId, let id = MailCID.normalize(raw), drawn.contains(id), handled.insert(id).inserted else { continue }
            // The part keeps the sender's own Content-ID when it can be sent as it is. One that cleaning would change
            // (spaces, non-ASCII, too long) gets a fresh id, so the reference and the part still agree.
            var cid = MIMEBuilder.cleanContentId(raw)
            if cid.isEmpty || MailCID.normalize(cid) != id {
                var n = images.count + 1
                repeat {
                    cid = "quoted-\(n)@\(MIMEBuilder.domain)"
                    n += 1
                } while taken.contains(MailCID.normalize(cid) ?? cid)
            }
            taken.insert(MailCID.normalize(cid) ?? cid)
            images.append(Image(contentId: cid, partId: a.partId, mimeType: a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType,
                                filename: a.name.isEmpty ? CachedMessage.imageName(a.mimeType) : a.name))
            // The sanitizer wrote the id normalized (lowercased); the reference goes back to exactly the id the part is
            // sent with (clients compare Content-IDs as written).
            out = out.replacingOccurrences(of: "src=\"\(MailCID.src(id))\"", with: "src=\"\(MailCID.src(cid))\"")
        }
        return Output(html: out, text: text, images: images)
    }

    /// Gmail's forward header: the From value keeps the address as `<b>Name</b> <span>&lt;addr&gt;</span>`-free plain text.
    private static func headerHTML(_ name: String, _ value: String) -> String { MailHTMLWriter.escape(value) }

    /// Every line behind "> " (empty lines become ">"), at most 1 MB.
    static func quoted(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        var out = ""
        for line in lines {
            let next = line.isEmpty ? ">\n" : "> \(line)\n"
            if out.utf8.count + next.utf8.count > maxPlainQuote { out += "> \u{2026}\n"; break }
            out += next
        }
        return out
    }

    private static func clipped(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard t.utf8.count > maxPlainQuote else { return t.hasSuffix("\n") ? t : t + "\n" }
        var out = ""
        for ch in t {
            if out.utf8.count >= maxPlainQuote { break }
            out.append(ch)
        }
        return out + "\n\u{2026}\n"
    }

    // MARK: Cleaning

    /// Drops `<style>` elements, `id` attributes, `data-yc-*` attributes, `yc-` classes and the inline styles that move or
    /// hide content (`movesOrHides`). The input is our sanitizer's output, so every tag is `<name attr="value" …>` with
    /// `"`, `<` and `>` escaped inside values and text, and every style is `prop: value; …` with checked properties.
    static func clean(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<style\b[^>]*>[\s\S]*?</style\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<style\b[^>]*/?>"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard let tag = try? NSRegularExpression(pattern: #"<[A-Za-z][^<>]*>"#) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for match in tag.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += cleanTag(ns.substring(with: match.range))
            last = NSMaxRange(match.range)
        }
        out += ns.substring(from: last)
        return out
    }

    private static func cleanTag(_ tag: String) -> String {
        var t = tag.replacingOccurrences(of: #"\s+id\s*=\s*"[^"]*""#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+data-yc-[A-Za-z0-9_-]*\s*=\s*"[^"]*""#, with: "", options: [.regularExpression, .caseInsensitive])
        t = cleanStyle(t)
        guard let r = t.range(of: #"\s+class\s*=\s*"[^"]*""#, options: [.regularExpression, .caseInsensitive]) else { return t }
        let attr = String(t[r])
        guard let q1 = attr.firstIndex(of: "\""), let q2 = attr.lastIndex(of: "\""), q1 < q2 else { return t }
        let tokens = attr[attr.index(after: q1)..<q2].split(whereSeparator: { $0.isWhitespace })
        let kept = tokens.filter { !$0.lowercased().hasPrefix("yc-") }
        if kept.count == tokens.count { return t }
        t.replaceSubrange(r, with: kept.isEmpty ? "" : " class=\"\(kept.joined(separator: " "))\"")
        return t
    }

    /// The tag's `style` without declarations that move or hide content; the attribute goes when nothing is left.
    private static func cleanStyle(_ tag: String) -> String {
        guard let r = tag.range(of: #"\s+style\s*=\s*"[^"]*""#, options: [.regularExpression, .caseInsensitive]) else { return tag }
        let attr = String(tag[r])
        guard let q1 = attr.firstIndex(of: "\""), let q2 = attr.lastIndex(of: "\""), q1 < q2 else { return tag }
        let declarations = splitDeclarations(HTMLEntities.decode(String(attr[attr.index(after: q1)..<q2])))
        let kept = declarations.filter { !movesOrHides($0) }
        guard kept.count != declarations.count else { return tag }
        var t = tag
        t.replaceSubrange(r, with: kept.isEmpty ? "" : " style=\"\(HTMLEntities.escapeAttribute(kept.joined(separator: "; ")))\"")
        return t
    }

    /// `prop: value` pieces of a style, split on `;` outside quotes and parentheses, trimmed, empty ones dropped.
    static func splitDeclarations(_ css: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for ch in css {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth = max(0, depth - 1)
            } else if ch == ";" && depth == 0 {
                out.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Properties that place content anywhere but where it flows, or hide it (review: overlay spoofing in replies).
    static let positioning: Set<String> = ["position", "z-index", "top", "left", "right", "bottom", "inset", "inset-block",
                                           "inset-block-start", "inset-block-end", "inset-inline", "inset-inline-start",
                                           "inset-inline-end", "transform", "translate", "rotate", "scale", "opacity", "clip",
                                           "clip-path", "visibility", "mask", "mask-image", "filter", "offset", "offset-path"]

    /// A declaration that moves or hides content: a positioning property, `display: none`, or a negative margin.
    static func movesOrHides(_ declaration: String) -> Bool {
        guard let colon = declaration.firstIndex(of: ":") else { return false }
        let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        if positioning.contains(property) || property.hasPrefix("-webkit-transform") || property.hasPrefix("-webkit-mask") { return true }
        if property == "display" { return value.hasPrefix("none") }
        if property.hasPrefix("margin") { return value.range(of: #"(^|[\s(,])-\s*[0-9.]"#, options: .regularExpression) != nil }
        return false
    }

    /// `<img … src="cid:x" …>` for an image that couldn't be attached → its alt text (escaped; empty when none).
    static func replaceImage(_ html: String, cid: String) -> String {
        guard let target = MailCID.normalize(cid), let tag = try? NSRegularExpression(pattern: #"<img\b[^<>]*>"#, options: .caseInsensitive)
        else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for match in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let img = ns.substring(with: match.range)
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = NSMaxRange(match.range)
            guard let src = attribute("src", in: img), src.lowercased().hasPrefix("cid:"), MailCID.normalize(src) == target else {
                out += img
                continue
            }
            out += attribute("alt", in: img) ?? ""
        }
        out += ns.substring(from: last)
        return out
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: "\\s\(name)\\s*=\\s*\"([^\"]*)\"", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let attr = tag[r]
        guard let q1 = attr.firstIndex(of: "\""), let q2 = attr.lastIndex(of: "\""), q1 < q2 else { return nil }
        return String(attr[attr.index(after: q1)..<q2])
    }
}
