import Foundation

/// One outgoing plain-text message (the composer is an NSTextView).
struct OutgoingMail: Equatable {
    var from: MailAddress
    var to: [MailAddress]
    var cc: [MailAddress] = []
    var bcc: [MailAddress] = []
    var subject: String
    var body: String
    /// Ours: a random UUID at `MIMEBuilder.domain`, in angle brackets. The Sent search before any retry
    /// looks for it.
    var messageID: String
    /// Replies: the parent's Message-ID, and the parent's References + its Message-ID.
    var inReplyTo: String?
    var references: [String] = []
    var date: Date
}

/// RFC 5322 + MIME for `messages.send` (`raw` = base64url of these bytes): CRLF everywhere, UTF-8,
/// non-ASCII names and subjects as encoded-words, the body as 7bit, quoted-printable or base64
/// (whichever fits), lines ≤ 78 characters. Bcc stays in the header: Gmail delivers to it and removes it.
enum MIMEBuilder {
    static let domain = "yayascalendar.local"

    static func newMessageID() -> String { "<\(UUID().uuidString.lowercased())@\(domain)>" }

    /// `<local@domain>` with nothing that could break a header.
    static func isMessageID(_ value: String) -> Bool {
        value.hasPrefix("<") && value.hasSuffix(">") && value.contains("@") && value.count <= 250
            && !value.unicodeScalars.contains { $0.value <= 0x20 || $0.value >= 0x7F || $0 == "," }
            && value.dropFirst().dropLast().allSatisfy { $0 != "<" && $0 != ">" }
    }

    /// Message-IDs from a References / In-Reply-To header value.
    static func messageIDs(in header: String?) -> [String] {
        guard let header else { return [] }
        var out: [String] = []
        var current = ""
        var inside = false
        for ch in EncodedWord.unfold(header) {
            if ch == "<" { inside = true; current = "<"; continue }
            if ch == ">" && inside { current.append(">"); if isMessageID(current) { out.append(current) }; inside = false; continue }
            if inside { current.append(ch) }
        }
        return out
    }

    /// RFC 5322 §3.6.4: the parent's References (or its In-Reply-To) followed by its Message-ID.
    /// Long chains keep the first id and the most recent ones.
    static func references(parentReferences: String?, parentInReplyTo: String?, parentMessageID: String?) -> [String] {
        var ids = messageIDs(in: parentReferences)
        if ids.isEmpty { ids = messageIDs(in: parentInReplyTo) }
        if let parent = parentMessageID, isMessageID(parent), !ids.contains(parent) { ids.append(parent) }
        if ids.count > 20 { ids = [ids[0]] + ids.suffix(19) }
        return ids
    }

    /// What other mail clients write for "Re:", lowercased: German, Nordic, Dutch, Polish, Greek, Hebrew, Arabic and
    /// Chinese (with an ASCII or a full-width colon).
    static let replyPrefixes = ["re:", "aw:", "sv:", "antw:", "odp:", "\u{03B1}\u{03C0}:", "\u{03C3}\u{03C7}\u{03B5}\u{03C4}:",
                                "\u{05D4}\u{05E9}\u{05D1}:", "\u{0631}\u{062F}:", "\u{56DE}\u{590D}:", "\u{56DE}\u{8986}:", "\u{7B54}\u{590D}:",
                                "\u{56DE}\u{590D}\u{FF1A}", "\u{56DE}\u{8986}\u{FF1A}", "\u{7B54}\u{590D}\u{FF1A}"]

    static func replySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in replyPrefixes where lower.hasPrefix(prefix) { return trimmed }
        return trimmed.isEmpty ? "Re:" : "Re: \(trimmed)"
    }

    /// The signature after the RFC 3676 separator line, unless the body already ends with it (trailing
    /// blank lines ignored).
    static func appendSignature(_ body: String, _ signature: String) -> String {
        let sig = signature.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n")
        guard !sig.isEmpty else { return body }
        var end = body.replacingOccurrences(of: "\r\n", with: "\n")
        while let last = end.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { end.unicodeScalars.removeLast() }
        guard !end.hasSuffix(sig) else { return body }
        return end + "\n\n-- \n" + sig
    }

    static func build(_ mail: OutgoingMail) -> Data {
        var lines = headerLines(mail)
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        let part = textPart(mail.body)
        lines.append("Content-Transfer-Encoding: " + part.encoding)
        let body = part.body
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n" + body + (body.hasSuffix("\r\n") ? "" : "\r\n")
        return Data(text.utf8)
    }

    /// The message headers up to (not including) MIME-Version: From, To, Cc, Bcc, Subject, Date, Message-ID and the
    /// threading headers. Shared by the plain and the rich builder.
    static func headerLines(_ mail: OutgoingMail) -> [String] {
        var lines: [String] = []
        lines.append("From: " + mail.from.header)
        if !mail.to.isEmpty { lines.append(addressHeader("To", mail.to)) }
        if !mail.cc.isEmpty { lines.append(addressHeader("Cc", mail.cc)) }
        if !mail.bcc.isEmpty { lines.append(addressHeader("Bcc", mail.bcc)) }
        lines.append("Subject: " + EncodedWord.encodeIfNeeded(mail.subject))
        lines.append("Date: " + MailDate.format(mail.date))
        lines.append("Message-ID: " + mail.messageID)
        if let parent = mail.inReplyTo, isMessageID(parent) { lines.append("In-Reply-To: " + parent) }
        let refs = mail.references.filter(isMessageID)
        if !refs.isEmpty { lines.append("References: " + refs.joined(separator: "\r\n ")) }
        return lines
    }

    /// A text/plain body as 7bit, quoted-printable or base64, whichever fits (CRLF line breaks). 7bit only for printable
    /// ASCII, tabs and line breaks (RFC 2045 §2.7: no NUL; other controls are escaped too).
    static func textPart(_ text: String) -> (encoding: String, body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let bytes = Data(normalized.utf8)
        let nonASCII = bytes.filter { $0 >= 0x80 }.count
        let controls = bytes.contains { ($0 < 0x20 && $0 != 0x09 && $0 != 0x0A) || $0 == 0x7F }
        let longest = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { $0.utf8.count }.max() ?? 0
        if nonASCII == 0 && !controls && longest <= 76 && !normalized.split(separator: "\n").contains(where: { $0 == "." }) {
            return ("7bit", normalized.replacingOccurrences(of: "\n", with: "\r\n"))
        } else if nonASCII * 3 > bytes.count {
            return ("base64", Base64MIME.encode(Data(normalized.replacingOccurrences(of: "\n", with: "\r\n").utf8)))
        } else {
            return ("quoted-printable", QuotedPrintable.encode(bytes))
        }
    }

    /// `To: a@x, "B" <b@y>` folded so no line passes 78 characters. An address that doesn't fit on a line of its own
    /// folds inside: between its encoded words, or between the words of its name; a name with nothing to fold at becomes
    /// encoded words. Lists that fit are written exactly as before.
    static func addressHeader(_ name: String, _ list: [MailAddress]) -> String {
        var out = "\(name): "
        var lineLength = out.count
        for (i, address) in list.enumerated() {
            var pieces = addressPieces(address)
            if i < list.count - 1 { pieces[pieces.count - 1] += "," }
            let item = pieces.joined(separator: " ")
            if lineLength + item.count + 1 > 78 && i > 0 {
                out += "\r\n "
                lineLength = 1
            } else if i > 0 {
                out += " "
                lineLength += 1
            }
            if lineLength + item.count <= 78 || pieces.count == 1 {
                out += item
                lineLength += item.count
                continue
            }
            for (j, piece) in pieces.enumerated() {
                if j > 0 {
                    if lineLength + 1 + piece.count > 78 {
                        out += "\r\n "
                        lineLength = 1
                    } else {
                        out += " "
                        lineLength += 1
                    }
                }
                out += piece
                lineLength += piece.count
            }
        }
        return out
    }

    /// An address's header form in the pieces it may fold between (joined with one space it is `address.header` with
    /// its folds undone): encoded words, or a name's words, then `<addr>`. A name piece too long for a line makes the
    /// whole name encoded words (RFC 2047 allows them for ASCII too).
    static func addressPieces(_ address: MailAddress) -> [String] {
        let header = address.header.replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        guard !address.name.isEmpty, header.hasSuffix(" <\(address.email)>") else { return [header] }
        let phrase = String(header.dropLast(address.email.count + 3))
        let mailbox = "<\(address.email)>"
        var words: [String] = []
        for word in phrase.components(separatedBy: " ") {
            // Keep runs of spaces inside a quoted name: an empty piece joins the one before it.
            if word.isEmpty, !words.isEmpty { words[words.count - 1] += " " } else { words.append(word) }
        }
        if words.contains(where: { $0.count > 76 }) {
            let name = address.name.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            words = encodedWords(name)
        }
        return words + [mailbox]
    }
}
