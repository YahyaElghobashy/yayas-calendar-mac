import Foundation

// One MIME tree for both inputs: Gmail's parsed `payload` (threads.get?format=full) and raw RFC 822
// bytes (tests, the builder round trip, forwarded messages). The walk picks the HTML and plain-text
// bodies (multipart/alternative: the richest; related: the root; mixed: every inline text part in
// order) and lists attachments by name and size — attachment bytes are never fetched here. Rich mail
// (D-040) also keeps each part's Gmail part id, attachment id, type and Content-ID, records inline
// (cid:) images instead of dropping them, and reads the text part's format=flowed / delsp=yes.

struct MIMEHeader: Equatable, Sendable {
    var name: String
    /// Unfolded, not decoded (encoded-words stay as they are).
    var value: String
}

/// A header value with parameters: `text/plain; charset="utf-8"`, `attachment; filename*=UTF-8''%E2…`.
struct ParamHeader: Equatable {
    var value: String
    var params: [String: String]

    /// RFC 2045 parameters with quoted strings, plus RFC 2231 extended (`name*=charset'lang'%XX`) and
    /// continued (`name*0*=…; name*1*=…`) values.
    static func parse(_ raw: String) -> ParamHeader {
        let pieces = CSSSanitizer.split(EncodedWord.unfold(raw), on: ";")
        let value = (pieces.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var plain: [String: String] = [:]
        var segments: [String: [(index: Int, encoded: Bool, text: String)]] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var v = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("\"") {
                v.removeFirst()
                if v.hasSuffix("\"") { v.removeLast() }
                var out = ""
                var escape = false
                for ch in v {
                    if escape { out.append(ch); escape = false } else if ch == "\\" { escape = true } else { out.append(ch) }
                }
                v = out
            }
            guard !name.isEmpty else { continue }
            if let star = name.firstIndex(of: "*") {
                let base = String(name[..<star])
                let rest = name[name.index(after: star)...]
                let encoded = rest.hasSuffix("*") || rest.isEmpty
                let number = Int(rest.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
                segments[base, default: []].append((number, encoded, v))
            } else if plain[name] == nil {
                plain[name] = v
            }
        }
        for (base, parts) in segments {
            var charset: String?
            var bytes = Data()
            for (i, part) in parts.sorted(by: { $0.index < $1.index }).enumerated() {
                var text = part.text
                if part.encoded {
                    if i == 0 {
                        let quote = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if quote.count == 3 {
                            charset = String(quote[0])
                            text = String(quote[2])
                        }
                    }
                    bytes.append(percentDecode(text))
                } else {
                    bytes.append(Data(text.utf8))
                }
            }
            plain[base] = Charset.decode(bytes, charset: charset ?? "utf-8")
        }
        return ParamHeader(value: value, params: plain)
    }

    private static func percentDecode(_ text: String) -> Data {
        let b = Array(text.utf8)
        var out = Data()
        var i = 0
        while i < b.count {
            if b[i] == 0x25, i + 2 < b.count, let v = UInt8(String(bytes: b[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return out
    }
}

struct MIMEPart: Equatable {
    var headers: [MIMEHeader] = []
    /// Leaf content with the transfer encoding removed (charset not applied yet).
    var body = Data()
    var parts: [MIMEPart] = []
    /// What Gmail reports for attachments (it sends their bytes only on request).
    var gmailFilename: String?
    var declaredSize: Int?
    /// Gmail's part id ("1", "1.2"): stable across fetches, the attachment cache's key.
    var gmailPartId: String?
    /// Gmail's attachment id: changes on every fetch, kept only to request the bytes.
    var gmailAttachmentId: String?

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.name.lowercased() == lower }?.value
    }

    var contentType: ParamHeader {
        let parsed = ParamHeader.parse(header("Content-Type") ?? "text/plain")
        return parsed.value.contains("/") ? parsed : ParamHeader(value: "text/plain", params: parsed.params)
    }

    var disposition: ParamHeader? { header("Content-Disposition").map(ParamHeader.parse) }

    var transferEncoding: String {
        (header("Content-Transfer-Encoding") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var contentID: String? {
        guard let raw = header("Content-ID") else { return nil }
        let id = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t<>"))
        return id.isEmpty ? nil : id
    }

    /// Filename from Gmail, Content-Disposition (RFC 2231) or the Content-Type `name`; encoded-words
    /// decoded; path components removed.
    var filename: String? {
        let candidates = [gmailFilename, disposition?.params["filename"], contentType.params["name"]]
        guard let raw = candidates.compactMap({ $0 }).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        let decoded = EncodedWord.decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let last = decoded.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? decoded
        return last.isEmpty ? nil : String(last.prefix(200))
    }

    var size: Int { declaredSize ?? body.count }

    var isMultipart: Bool { contentType.value.hasPrefix("multipart/") }
}

enum MIMEParser {
    static let maxDepth = 24

    // MARK: Raw RFC 822

    static func parse(_ data: Data, depth: Int = 0) -> MIMEPart {
        let bytes = [UInt8](data)
        var split = bytes.count
        var bodyStart = bytes.count
        if bytes.first == 0x0A {
            split = 0; bodyStart = 1
        } else if bytes.count >= 2, bytes[0] == 0x0D, bytes[1] == 0x0A {
            split = 0; bodyStart = 2
        } else {
            var i = 0
            while i + 1 < bytes.count {
                if bytes[i] == 0x0A && bytes[i + 1] == 0x0A { split = i + 1; bodyStart = i + 2; break }
                if bytes[i] == 0x0A && bytes[i + 1] == 0x0D && i + 2 < bytes.count && bytes[i + 2] == 0x0A {
                    split = i + 1; bodyStart = i + 3; break
                }
                i += 1
            }
        }
        if split == bytes.count, let firstLine = String(data: Data(bytes.prefix(200)), encoding: .utf8)?
            .split(separator: "\n").first, !firstLine.contains(":") {
            split = 0
            bodyStart = 0   // no header block at all: everything is body
        }
        var part = MIMEPart()
        part.headers = headers(Data(bytes[0..<split]))
        let body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()
        let type = part.contentType
        if type.value.hasPrefix("multipart/"), let boundary = type.params["boundary"], !boundary.isEmpty, depth < maxDepth {
            part.parts = multipart(body, boundary: boundary).map { parse($0, depth: depth + 1) }
            if part.parts.isEmpty { part.body = body }
        } else {
            part.body = decodeTransfer(body, part.transferEncoding)
        }
        return part
    }

    /// The addresses a raw message's own top-level To, Cc and Bcc headers name (lowercased, in order, duplicates
    /// dropped): what Gmail delivers to. Nil when the header block doesn't end within the first 1 MB (unreadable).
    static func envelopeRecipients(_ raw: Data) -> [String]? {
        let end: Int? = raw.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int? in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let limit = min(bytes.count, 1 << 20)
            var i = 0
            while i < limit {
                if bytes[i] == 0x0A {
                    if i + 1 < bytes.count, bytes[i + 1] == 0x0A { return i + 1 }
                    if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { return i + 1 }
                }
                i += 1
            }
            return nil
        }
        guard let end else { return nil }
        var out: [String] = []
        var seen = Set<String>()
        for header in headers(raw.prefix(end)) where ["to", "cc", "bcc"].contains(header.name.lowercased()) {
            for address in MailAddress.parseList(header.value) {
                let email = address.email.trimmingCharacters(in: .whitespaces).lowercased()
                if !email.isEmpty, seen.insert(email).inserted { out.append(email) }
            }
        }
        return out
    }

    static func headers(_ data: Data) -> [MIMEHeader] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        var out: [MIMEHeader] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                if !out.isEmpty { out[out.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            out.append(MIMEHeader(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    /// Body parts between `--boundary` lines; the preamble and epilogue are dropped; a missing closing
    /// delimiter ends the last part at the end of the data.
    static func multipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Array("--\(boundary)".utf8)
        let b = [UInt8](body)
        var parts: [Data] = []
        var current: Int?
        var lineStart = 0
        func lineMatches(_ start: Int, _ end: Int) -> (Bool, Bool) {
            var e = end
            while e > start, b[e - 1] == 0x0D || b[e - 1] == 0x20 || b[e - 1] == 0x09 { e -= 1 }
            guard e - start >= delimiter.count, Array(b[start..<(start + delimiter.count)]) == delimiter else { return (false, false) }
            let rest = b[(start + delimiter.count)..<e]
            if rest.isEmpty { return (true, false) }
            if rest.count == 2, rest.first == 0x2D, rest.last == 0x2D { return (true, true) }
            return (false, false)
        }
        while lineStart <= b.count {
            var lineEnd = lineStart
            while lineEnd < b.count, b[lineEnd] != 0x0A { lineEnd += 1 }
            let (isDelimiter, isClose) = lineStart < b.count ? lineMatches(lineStart, lineEnd) : (false, false)
            if isDelimiter {
                if let start = current {
                    var end = lineStart
                    if end > start, b[end - 1] == 0x0A { end -= 1 }
                    if end > start, b[end - 1] == 0x0D { end -= 1 }
                    parts.append(Data(b[start..<max(start, end)]))
                }
                if isClose { return parts }
                current = min(lineEnd + 1, b.count)
            }
            if lineEnd >= b.count { break }
            lineStart = lineEnd + 1
        }
        if let start = current, start < b.count { parts.append(Data(b[start...])) }
        return parts
    }

    static func decodeTransfer(_ data: Data, _ encoding: String) -> Data {
        switch encoding {
        case "base64": return Base64MIME.decode(data) ?? data
        case "quoted-printable": return QuotedPrintable.decode(data)
        default: return data
        }
    }

    // MARK: Gmail payload

    /// Gmail has already removed transfer encodings; parts that still plainly look encoded (soft line
    /// breaks, or pure base64 lines) are decoded anyway, so either behaviour reads correctly.
    static func fromGmail(_ payload: GMessagePart, depth: Int = 0) -> MIMEPart {
        var part = MIMEPart()
        part.headers = (payload.headers ?? []).map { MIMEHeader(name: $0.name ?? "", value: $0.value ?? "") }
        if part.header("Content-Type") == nil, let type = payload.mimeType {
            part.headers.append(MIMEHeader(name: "Content-Type", value: type))
        }
        if let name = payload.filename, !name.isEmpty { part.gmailFilename = name }
        part.declaredSize = payload.body?.size
        if let id = payload.partId, !id.isEmpty { part.gmailPartId = id }
        if let id = payload.body?.attachmentId, !id.isEmpty { part.gmailAttachmentId = id }
        if let children = payload.parts, !children.isEmpty, depth < maxDepth {
            part.parts = children.map { fromGmail($0, depth: depth + 1) }
        } else if let data = payload.body?.data.flatMap({ Data(base64URL: $0) }) {
            switch part.transferEncoding {
            case "quoted-printable" where looksQuotedPrintable(data): part.body = QuotedPrintable.decode(data)
            case "base64" where looksBase64(data): part.body = Base64MIME.decode(data) ?? data
            default: part.body = data
            }
            if part.declaredSize == nil { part.declaredSize = part.body.count }
        }
        return part
    }

    static func looksQuotedPrintable(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard !b.contains(where: { $0 >= 0x80 }) else { return false }
        var escapes = 0
        var i = 0
        func upperHex(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x41...0x46).contains(c) }
        while i < b.count {
            if b[i] == 0x3D {
                if i + 1 < b.count, b[i + 1] == 0x0A { return true }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { return true }
                if i + 2 < b.count, upperHex(b[i + 1]), upperHex(b[i + 2]) { escapes += 1 }
            }
            i += 1
        }
        return escapes >= 2
    }

    static func looksBase64(_ data: Data) -> Bool {
        guard data.count >= 20 else { return false }
        var lineLengths: [Int] = []
        var current = 0
        for c in data {
            switch c {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F, 0x3D: current += 1
            case 0x0D: continue
            case 0x0A: lineLengths.append(current); current = 0
            default: return false
            }
        }
        if current > 0 { lineLengths.append(current) }
        let full = lineLengths.dropLast().filter { $0 > 0 }
        if let first = full.first, full.contains(where: { $0 != first }) { return false }
        return Base64MIME.decode(data) != nil
    }

    // MARK: Bodies and attachments

    /// A non-text part as the reader and the attachment cache need it (rich mail, D-040/D-043).
    struct PartRef: Equatable {
        /// Filename, or "" when the part has none (inline images often don't).
        var name: String
        /// The Content-ID without <>; inline (cid:) parts always have one.
        var contentId: String?
        /// Gmail's part id; nil for raw parses (those can't be fetched again).
        var partId: String?
        /// Gmail's attachment id (changes per fetch; only for requesting the bytes).
        var attachmentId: String?
        var mimeType: String
        var bytes: Int
        /// The bytes, when Gmail sent them inline or the message was parsed raw.
        var data: Data?
    }

    /// Spec name for inline parts.
    typealias InlinePart = PartRef

    struct Extracted: Equatable {
        /// Unsanitized HTML from the message (nil for plain-text mail).
        var html: String?
        var text: String
        /// Files, by name and size (what the reader lists).
        var attachments: [MailMessage.Attachment]
        /// The same files with their part ids, types and Content-IDs, in the same order.
        var files: [PartRef] = []
        /// Image parts with a Content-ID that the HTML may draw with `cid:` (never in `attachments`).
        var inline: [PartRef] = []
        /// The text part is `format=flowed` (RFC 3676), and `delsp=yes`.
        var flowed = false
        var delsp = false
    }

    static func extract(_ root: MIMEPart) -> Extracted {
        var walk = Walk()
        let (html, text) = content(root, walk: &walk, depth: 0)
        let plain = text ?? html.map(HTMLSanitizer.text(fromHTML:)) ?? ""
        return Extracted(html: html, text: plain, attachments: walk.attachments, files: walk.files, inline: walk.inline,
                         flowed: walk.flowed ?? false, delsp: walk.delsp)
    }

    /// What the walk collects besides the bodies.
    private struct Walk {
        var attachments: [MailMessage.Attachment] = []
        var files: [PartRef] = []
        var inline: [PartRef] = []
        /// Set by the first text/plain part read.
        var flowed: Bool?
        var delsp = false
    }

    private static func isAttachment(_ part: MIMEPart) -> Bool {
        if part.isMultipart { return false }
        let type = part.contentType.value
        if part.disposition?.value == "attachment" { return true }
        if (type == "text/plain" || type == "text/html") && part.filename == nil { return false }
        if type.hasPrefix("image/"), part.contentID != nil { return false }   // inline image (cid:)
        return true
    }

    private static func ref(_ part: MIMEPart, name: String) -> PartRef {
        PartRef(name: name, contentId: part.contentID, partId: part.gmailPartId, attachmentId: part.gmailAttachmentId,
                mimeType: part.contentType.value, bytes: part.size, data: part.body.isEmpty ? nil : part.body)
    }

    private static func content(_ part: MIMEPart, walk: inout Walk, depth: Int) -> (String?, String?) {
        guard depth < maxDepth else { return (nil, nil) }
        let type = part.contentType.value
        if isAttachment(part) {
            let fallback = type == "message/rfc822" ? "Forwarded message.eml" : "Untitled"
            if type != "application/pgp-signature" && type != "application/pkcs7-signature" && type != "application/x-pkcs7-signature" {
                let name = part.filename ?? fallback
                walk.attachments.append(MailMessage.Attachment(name: name, bytes: part.size))
                walk.files.append(ref(part, name: name))
            }
            return (nil, nil)
        }
        if type == "text/html" {
            return (Charset.decode(part.body, charset: part.contentType.params["charset"]), nil)
        }
        if type == "text/plain" {
            if walk.flowed == nil {
                let params = part.contentType.params
                walk.flowed = params["format"]?.lowercased() == "flowed"
                walk.delsp = walk.flowed == true && params["delsp"]?.lowercased() == "yes"
            }
            return (nil, Charset.decode(part.body, charset: part.contentType.params["charset"]))
        }
        if type.hasPrefix("image/"), part.contentID != nil {
            walk.inline.append(ref(part, name: part.filename ?? ""))   // drawn through cid:, or a chip at cache time
            return (nil, nil)
        }
        guard type.hasPrefix("multipart/") else { return (nil, nil) }   // other inline parts
        let children = part.parts
        if children.isEmpty {
            // A multipart whose boundary never showed up: read it as text.
            return (nil, Charset.decode(part.body, charset: nil))
        }
        switch type {
        case "multipart/alternative":
            var html: String?
            var text: String?
            for child in children {
                let (h, t) = content(child, walk: &walk, depth: depth + 1)
                if let h { html = h }
                if text == nil, let t { text = t }
            }
            return (html, text)
        case "multipart/related":
            let start = part.contentType.params["start"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            let root = children.first { start != nil && $0.contentID == start } ?? children[0]
            for child in children where child != root {
                let inlineImage = child.contentType.value.hasPrefix("image/") && child.contentID != nil
                if child.disposition?.value == "attachment" || inlineImage {
                    _ = content(child, walk: &walk, depth: depth + 1)
                }
            }
            return content(root, walk: &walk, depth: depth + 1)
        default:
            var results: [(String?, String?)] = []
            for child in children {
                let r = content(child, walk: &walk, depth: depth + 1)
                if r.0 != nil || r.1 != nil { results.append(r) }
            }
            guard !results.isEmpty else { return (nil, nil) }
            let anyHTML = results.contains { $0.0 != nil }
            let html = anyHTML ? results.map { $0.0 ?? HTMLSanitizer.html(fromText: $0.1 ?? "") }.joined(separator: "<br>") : nil
            let text = results.map { $0.1 ?? HTMLSanitizer.text(fromHTML: $0.0 ?? "") }.joined(separator: "\n\n")
            return (html, text)
        }
    }
}
