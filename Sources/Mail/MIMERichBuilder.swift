import Foundation

// Rich outgoing mail (D-042, D-044): text/plain + text/html as multipart/alternative, inline
// images as multipart/related, files as multipart/mixed, written straight to a file. Attachments stream through
// base64 in 57 × 1024-byte chunks (whole 76-character lines each), so a 25 MB file never sits in memory three times.
// `OutgoingMail` and `build(_:)` stay for the plain path (MIMETests and MailActionTests pin them).
//
//   plain, no files              text/plain                         (legacy `build`)
//   plain + files                multipart/mixed: text/plain, files
//   rich                         multipart/alternative: text/plain, text/html
//   rich + inline images         multipart/alternative: text/plain, multipart/related; type="text/html" (html, images)
//   any + files                  multipart/mixed: (the above), files

/// One attachment or inline image for `buildRich`.
struct MIMEAttachment: Equatable {
    enum Source: Equatable {
        case data(Data)
        case file(URL)
    }
    var filename: String
    var mimeType: String
    /// Inline images (multipart/related): the Content-ID without <>. Nil = a file attachment.
    var contentId: String?
    var source: Source

    var byteCount: Int {
        switch source {
        case .data(let d): return d.count
        case .file(let url): return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        }
    }
}

/// A rich message: the envelope from `headers` (its `body` is ignored), the text/plain part, the text/html part (nil =
/// plain text), inline images the html draws with `cid:`, and files.
struct RichOutgoingMail {
    var headers: OutgoingMail
    var text: String
    var html: String?
    var related: [MIMEAttachment] = []
    var files: [MIMEAttachment] = []
}

enum MIMEBuildError: Error, Equatable {
    /// An attachment's file couldn't be read (moved, deleted, unreadable). The filename as given.
    case unreadable(String)
}

extension MIMEBuilder {
    static let base64Chunk = 57 * 1024

    static func newBoundary() -> String { "yc-" + UUID().uuidString }

    /// Writes the message to `url` (created 0600, replaced if present) and returns its size in bytes. Each multipart
    /// level gets its own boundary from `boundary`; one that occurs in any text part is drawn again.
    @discardableResult
    static func buildRich(_ mail: RichOutgoingMail, to url: URL, boundary: () -> String = MIMEBuilder.newBoundary) throws -> Int {
        let out = try MIMEFileWriter(url)
        defer { out.close() }
        try writeRich(mail, to: out, boundary: boundary)
        try out.flush()
        return out.count
    }

    /// The same bytes in memory (tests, goldens and small messages).
    static func buildRichData(_ mail: RichOutgoingMail, boundary: () -> String = MIMEBuilder.newBoundary) throws -> Data {
        let out = MIMEFileWriter()
        try writeRich(mail, to: out, boundary: boundary)
        return out.data
    }

    /// The composer's estimate for a message of these sizes (`MailSize.estimate`).
    static func estimatedSize(text: Int, html: Int, attachments: [Int], names: Int = 0, headers: Int = 0) -> Int {
        MailSize.estimate(text: text, html: html, attachments: attachments, names: names, headers: headers)
    }

    // MARK: Structure

    private indirect enum Entity {
        case text(subtype: String, encoding: String, body: String)
        case attachment(MIMEAttachment)
        case multipart(subtype: String, params: [(String, String)], boundary: String, parts: [Entity])
    }

    private static func writeRich(_ mail: RichOutgoingMail, to out: MIMEFileWriter, boundary: () -> String) throws {
        if mail.html == nil && mail.files.isEmpty && mail.related.isEmpty {
            var plain = mail.headers
            plain.body = mail.text
            try out.write(String(decoding: build(plain), as: UTF8.self))
            return
        }
        let text = textPart(mail.text)
        let html = mail.html.map { QuotedPrintable.encode(Data($0.utf8)) }
        var used: [String] = []
        func fresh() -> String {
            var candidate = boundary()
            var tries = 0
            while used.contains(candidate) || text.body.contains(candidate) || (html?.contains(candidate) ?? false) {
                tries += 1
                candidate = tries < 8 ? boundary() : "yc-\(UUID().uuidString)"
            }
            used.append(candidate)
            return candidate
        }
        var body: Entity = .text(subtype: "plain", encoding: text.encoding, body: text.body)
        if let html {
            var htmlPart: Entity = .text(subtype: "html", encoding: "quoted-printable", body: html)
            if !mail.related.isEmpty {
                htmlPart = .multipart(subtype: "related", params: [("type", "\"text/html\"")], boundary: "",
                                      parts: [htmlPart] + mail.related.map { .attachment($0) })
            }
            body = .multipart(subtype: "alternative", params: [], boundary: "", parts: [body, htmlPart])
        }
        if !mail.files.isEmpty {
            body = .multipart(subtype: "mixed", params: [], boundary: "", parts: [body] + mail.files.map { .attachment($0) })
        }
        // Boundaries outermost first (stable order for the goldens).
        func assign(_ e: Entity) -> Entity {
            guard case let .multipart(subtype, params, _, parts) = e else { return e }
            let b = fresh()
            return .multipart(subtype: subtype, params: params, boundary: b, parts: parts.map(assign))
        }
        body = assign(body)
        var lines = headerLines(mail.headers)
        lines.append("MIME-Version: 1.0")
        try out.write(lines.joined(separator: "\r\n") + "\r\n")
        try write(body, to: out)
    }

    private static func write(_ e: Entity, to out: MIMEFileWriter) throws {
        switch e {
        case let .text(subtype, encoding, body):
            try out.write("Content-Type: text/\(subtype); charset=\"UTF-8\"\r\nContent-Transfer-Encoding: \(encoding)\r\n\r\n")
            try out.write(body)
            if !body.hasSuffix("\r\n") { try out.write("\r\n") }
        case let .attachment(a):
            try out.write(attachmentHeaders(a).joined(separator: "\r\n") + "\r\n\r\n")
            try writeBase64(a, to: out)
            try out.write("\r\n")
        case let .multipart(subtype, params, boundary, parts):
            var header = "Content-Type: multipart/\(subtype);"
            for (name, value) in params { header += " \(name)=\(value);" }
            header += "\r\n boundary=\"\(boundary)\"\r\n\r\n"
            try out.write(header)
            for part in parts {
                try out.write("--\(boundary)\r\n")
                try write(part, to: out)
            }
            try out.write("--\(boundary)--\r\n")
        }
    }

    /// Content-Type (with `name`, RFC 2047 for old Outlook), Content-Disposition (`filename`, RFC 2231 when needed),
    /// Content-ID for inline images (folded onto its own line when long), base64. No line passes 78 characters. A
    /// message/* or multipart/* file (an attached .eml) goes as application/octet-stream with its name: those types may
    /// only be 7bit, 8bit or binary (RFC 2045 §6.4, RFC 2046 §5.2.1), and every part here is base64.
    static func attachmentHeaders(_ a: MIMEAttachment) -> [String] {
        let name = cleanFilename(a.filename)
        let type = base64Type(cleanMimeType(a.mimeType))
        // A long type (the Office ones pass 70 characters) starts on its own folded line.
        let typeLine = "Content-Type: \(type);".utf8.count <= 78 ? "Content-Type: \(type);" : "Content-Type:\r\n \(type);"
        var lines = [typeLine + "\r\n" + nameParameter(name)]
        lines.append("Content-Disposition: \(a.contentId == nil ? "attachment" : "inline");\r\n" + filenameParameter(name))
        if let cid = a.contentId.map(cleanContentId), !cid.isEmpty {
            lines.append("Content-ID: <\(cid)>".utf8.count <= 78 ? "Content-ID: <\(cid)>" : "Content-ID:\r\n <\(cid)>")
        }
        lines.append("Content-Transfer-Encoding: base64")
        return lines
    }

    // MARK: Base64, streamed

    private static func writeBase64(_ a: MIMEAttachment, to out: MIMEFileWriter) throws {
        let options: Data.Base64EncodingOptions = [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        switch a.source {
        case .data(let data):
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + base64Chunk)
                if offset > 0 { try out.write("\r\n") }
                try out.write(data.subdata(in: offset..<end).base64EncodedData(options: options))
                offset = end
            }
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw MIMEBuildError.unreadable(a.filename) }
            defer { try? handle.close() }
            var first = true
            while true {
                let chunk: Data
                do {
                    chunk = try autoreleasepool { try handle.read(upToCount: base64Chunk) } ?? Data()
                } catch {
                    throw MIMEBuildError.unreadable(a.filename)
                }
                if chunk.isEmpty { break }
                if !first { try out.write("\r\n") }
                first = false
                try out.write(chunk.base64EncodedData(options: options))
                if chunk.count < base64Chunk { break }
            }
        }
    }

    /// One-shot base64 in 76-character CRLF lines (the streamed path must equal it; a data test checks).
    static func base64Lines(_ data: Data) -> Data {
        data.base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    // MARK: Filenames (RFC 2231 + RFC 2047)

    /// Controls (C0, DEL, C1), line and paragraph separators and bidi controls go; an empty result is "attachment".
    static func cleanFilename(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            switch s.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: continue
            default: out.append(s)
            }
        }
        let name = String(out).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "attachment" : name
    }

    /// `type/subtype` with nothing that could break the header; anything odd is application/octet-stream.
    static func cleanMimeType(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let ok = t.split(separator: "/").count == 2 && t.unicodeScalars.allSatisfy {
            ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || "/.+-_".unicodeScalars.contains($0)
        }
        return ok && t.count <= 100 ? t : "application/octet-stream"
    }

    /// A type that may be sent base64: composite types (message/*, multipart/*) become application/octet-stream.
    static func base64Type(_ type: String) -> String {
        type.hasPrefix("message/") || type.hasPrefix("multipart/") ? "application/octet-stream" : type
    }

    /// Longest Content-ID kept: `<id>` on its own folded line stays within 78 characters.
    static let maxContentId = 75

    /// Printable ASCII without `<` or `>`, at most `maxContentId` characters. A sender's id that this changes is given
    /// a new one by the quote composer (with the reference rewritten), so no quoted image is left without its part.
    static func cleanContentId(_ raw: String) -> String {
        String(String(raw.unicodeScalars.filter { $0.value > 0x20 && $0.value < 0x7F && $0 != "<" && $0 != ">" }.map(Character.init))
            .prefix(maxContentId))
    }

    /// Printable ASCII without `"` or `\` can be quoted as is.
    static func isPlainQuotable(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "\\" }
    }

    /// ` name="Launch plan.pdf"`, or RFC 2047 B-words folded over lines for anything else (old Outlook reads these).
    static func nameParameter(_ name: String) -> String {
        if isPlainQuotable(name), (" name=\"\(name)\"").utf8.count <= 78 { return " name=\"\(name)\"" }
        return " name=\"" + encodedWords(name).joined(separator: "\r\n ") + "\""
    }

    /// RFC 2047 UTF-8 B-words of at most 39 bytes each (64 characters a word), split on character boundaries.
    static func encodedWords(_ text: String) -> [String] {
        var words: [String] = []
        var chunk = Data()
        for ch in text {
            let bytes = Data(String(ch).utf8)
            if chunk.count + bytes.count > 39 && !chunk.isEmpty {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words
    }

    /// ` filename="Launch plan.pdf"`; a long ASCII name as `filename*0="…"; filename*1="…"`; anything else as
    /// `filename*0*=UTF-8''%…; filename*1*=%…` (RFC 2231), every segment on its own line within 78 characters.
    static func filenameParameter(_ name: String) -> String {
        if isPlainQuotable(name) {
            if (" filename=\"\(name)\"").utf8.count <= 78 { return " filename=\"\(name)\"" }
            var segments: [String] = []
            var current = ""
            for ch in name {
                if current.utf8.count + String(ch).utf8.count > 56 { segments.append(current); current = "" }
                current.append(ch)
            }
            if !current.isEmpty { segments.append(current) }
            return segments.enumerated().map { " filename*\($0.offset)=\"\($0.element)\"" }.joined(separator: ";\r\n")
        }
        var encoded: [String] = []
        for b in name.utf8 {
            let c = Character(UnicodeScalar(b))
            if b < 0x80, (c.isLetter || c.isNumber || "!#$&+-.^_`|~".contains(c)) {
                encoded.append(String(c))
            } else {
                encoded.append(String(format: "%%%02X", b))
            }
        }
        var segments: [String] = []
        var current = "UTF-8''"
        for token in encoded {
            if current.utf8.count + token.utf8.count > 60 { segments.append(current); current = "" }
            current += token
        }
        if !current.isEmpty { segments.append(current) }
        return segments.enumerated().map { " filename*\($0.offset)*=\($0.element)" }.joined(separator: ";\r\n")
    }
}

/// Buffered output for the builder: to a file (created 0600) or to memory. Counts every byte written.
final class MIMEFileWriter {
    private let handle: FileHandle?
    private var buffer = Data()
    private(set) var count = 0
    private(set) var data = Data()
    private static let flushAt = 1 << 20

    /// In memory.
    init() { handle = nil }

    /// To `url`, replacing any file there; 0600.
    init(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ text: String) throws { try write(Data(text.utf8)) }

    func write(_ bytes: Data) throws {
        count += bytes.count
        guard handle != nil else { data.append(bytes); return }
        buffer.append(bytes)
        if buffer.count >= Self.flushAt { try flush() }
    }

    func flush() throws {
        guard let handle, !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() { try? handle?.close() }
}
