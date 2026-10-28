import Foundation

// Text-level MIME helpers shared by the parser, the builder and the sanitizer: charsets, transfer
// encodings (quoted-printable, base64, base64url), RFC 2047 encoded-words, address lists, RFC 5322
// dates and HTML character references. Pure functions, no I/O.

// MARK: - Charsets

enum Charset {
    /// IANA name → String.Encoding. Aliases cover what real mail declares; `iso-8859-1` is read as
    /// windows-1252 (WHATWG), because mail that says Latin-1 routinely carries 0x80–0x9F quotes.
    static func encoding(_ name: String?) -> String.Encoding? {
        guard var n = name?.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased(), !n.isEmpty
        else { return nil }
        if let star = n.firstIndex(of: "*") { n = String(n[..<star]) }   // RFC 2231 language suffix
        switch n {
        case "utf8", "utf-8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968": return .ascii
        case "latin1", "latin-1", "iso-8859-1", "iso8859-1", "iso_8859-1", "cp1252", "windows-1252", "x-cp1252":
            return .windowsCP1252
        // Windows code pages under their "x-" names, x-cp1250 to x-cp1258 (Central European, Cyrillic, Greek, Turkish,
        // Hebrew, Arabic, Baltic, Vietnamese).
        case _ where n.hasPrefix("x-cp125"): n = "windows-" + n.dropFirst(4)
        // IANA's script-name aliases are the ISO-8859 sets; CoreFoundation would read them as the old Mac encodings.
        case "cyrillic": n = "iso-8859-5"
        case "arabic": n = "iso-8859-6"
        case "greek": n = "iso-8859-7"
        case "hebrew": n = "iso-8859-8"
        case "ks_c_5601-1987": n = "euc-kr"
        case "gb2312", "gbk", "x-gbk": n = "gb18030"
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Bytes in the declared charset → text. Never fails: unknown or lying charsets fall back to UTF-8,
    /// then windows-1252 (every byte maps), then lossy UTF-8.
    static func decode(_ data: Data, charset: String?) -> String {
        if data.isEmpty { return "" }
        if let enc = encoding(charset) {
            // "us-ascii" mail with 8-bit bytes is nearly always UTF-8 in disguise.
            if enc == .ascii, let s = String(data: data, encoding: .utf8) { return s }
            if let s = String(data: data, encoding: enc) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Transfer encodings

enum QuotedPrintable {
    private static func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    /// RFC 2045 §6.7, tolerant: soft line breaks (with stray trailing blanks), lowercase hex, and a
    /// malformed `=` kept literally.
    static func decode(_ data: Data) -> Data {
        let b = [UInt8](data)
        var out = Data(capacity: b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            guard c == 0x3D else { out.append(c); i += 1; continue }
            var j = i + 1
            while j < b.count && (b[j] == 0x20 || b[j] == 0x09) { j += 1 }
            if j >= b.count { i = j; continue }
            if b[j] == 0x0A { i = j + 1; continue }
            if b[j] == 0x0D { i = (j + 1 < b.count && b[j + 1] == 0x0A) ? j + 2 : j + 1; continue }
            if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(h << 4 | l)
                i += 3
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Encodes for a text body: CRLF line breaks, lines ≤ 76 characters with soft breaks, `=`, controls,
    /// non-ASCII and blanks before a line break escaped.
    static func encode(_ data: Data) -> String {
        let hexDigits = Array("0123456789ABCDEF")
        var out = ""
        var line = ""
        func esc(_ b: UInt8) -> String { "=" + String(hexDigits[Int(b >> 4)]) + String(hexDigits[Int(b & 0xF)]) }
        func push(_ token: String) {
            if line.count + token.count > 75 {
                out += line + "=\r\n"
                line = ""
            }
            line += token
        }
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x0D && i + 1 < bytes.count && bytes[i + 1] == 0x0A { i += 1; continue }
            if b == 0x0A || b == 0x0D {
                out += line + "\r\n"
                line = ""
                i += 1
                continue
            }
            let nextIsBreak = i + 1 >= bytes.count || bytes[i + 1] == 0x0A || bytes[i + 1] == 0x0D
            if (b == 0x20 || b == 0x09) && nextIsBreak {
                push(esc(b))
            } else if b == 0x3D || b < 0x20 && b != 0x09 || b > 0x7E {
                push(esc(b))
            } else if b == 0x2E && line.isEmpty {
                push(esc(b))   // a lone "." line means end-of-data to some SMTP relays
            } else {
                push(String(UnicodeScalar(b)))
            }
            i += 1
        }
        out += line
        return out
    }
}

enum Base64MIME {
    /// Tolerant base64: ignores line breaks and junk, adds missing padding.
    static func decode(_ text: String) -> Data? {
        var cleaned = text.filter { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "+" || $0 == "/" }
        let rem = cleaned.count % 4
        if rem == 1 { cleaned.removeLast() } else if rem > 0 { cleaned += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: cleaned)
    }

    static func decode(_ data: Data) -> Data? {
        decode(String(decoding: data, as: UTF8.self))
    }

    /// 76-character lines, CRLF.
    static func encode(_ data: Data) -> String {
        let text = data.base64EncodedString()
        var lines: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 76, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(text[start..<end])
            start = end
        }
        return lines.joined(separator: "\r\n")
    }
}

extension Data {
    /// Gmail's `body.data` and `raw`: RFC 4648 §5, padding optional.
    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.filter { !$0.isWhitespace }
        let rem = s.count % 4
        if rem == 1 { return nil }
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: s)
    }

    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - RFC 2047 encoded-words

enum EncodedWord {
    /// Unfolds and decodes a header value. Adjacent encoded-words in the same charset are joined at
    /// the byte level first (a UTF-8 character may be split across two words), and the whitespace
    /// between encoded-words is dropped.
    static func decode(_ raw: String) -> String {
        let value = unfold(raw)
        guard value.contains("=?") else { return value }
        let scalars = Array(value.unicodeScalars)
        var result = String.UnicodeScalarView()
        var pendingBytes = Data()
        var pendingCharset: String?
        var pendingSpace = String.UnicodeScalarView()
        var lastWasWord = false
        func flush() {
            if let cs = pendingCharset { result.append(contentsOf: Charset.decode(pendingBytes, charset: cs).unicodeScalars) }
            pendingBytes = Data()
            pendingCharset = nil
        }
        var i = 0
        while i < scalars.count {
            if scalars[i] == "=", i + 1 < scalars.count, scalars[i + 1] == "?", let (charset, bytes, next) = word(scalars, i) {
                if !lastWasWord { result.append(contentsOf: pendingSpace) }
                pendingSpace = String.UnicodeScalarView()
                if let cs = pendingCharset, cs.lowercased() != charset.lowercased() {
                    flush()
                }
                pendingCharset = charset
                pendingBytes.append(bytes)
                lastWasWord = true
                i = next
            } else if scalars[i] == " " || scalars[i] == "\t" {
                pendingSpace.append(scalars[i])
                i += 1
            } else {
                flush()
                result.append(contentsOf: pendingSpace)
                pendingSpace = String.UnicodeScalarView()
                result.append(scalars[i])
                lastWasWord = false
                i += 1
            }
        }
        flush()
        result.append(contentsOf: pendingSpace)
        return String(result)
    }

    /// `=?charset?B|Q?text?=` at `i` → (charset, bytes, index after).
    private static func word(_ s: [Unicode.Scalar], _ i: Int) -> (String, Data, Int)? {
        var j = i + 2
        var charset = ""
        while j < s.count, s[j] != "?" {
            if s[j] == " " || s[j] == "\t" || charset.count > 40 { return nil }
            charset.unicodeScalars.append(s[j])
            j += 1
        }
        guard j + 2 < s.count, !charset.isEmpty else { return nil }
        let enc = Character(s[j + 1]).lowercased()
        guard s[j + 2] == "?", enc == "b" || enc == "q" else { return nil }
        var k = j + 3
        var text = ""
        while k + 1 < s.count, !(s[k] == "?" && s[k + 1] == "=") {
            if s[k] == " " || s[k] == "\t" { return nil }
            text.unicodeScalars.append(s[k])
            k += 1
        }
        guard k + 1 < s.count else { return nil }
        let bytes: Data?
        if enc == "b" {
            bytes = Base64MIME.decode(text)
        } else {
            bytes = QuotedPrintable.decode(Data(text.replacingOccurrences(of: "_", with: " ").utf8))
        }
        guard let bytes else { return nil }
        return (charset, bytes, k + 2)
    }

    /// RFC 5322 §2.2.3: CRLF followed by whitespace is removed.
    static func unfold(_ value: String) -> String {
        guard value.contains("\n") else { return value }
        var out = value.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
        return out.replacingOccurrences(of: "\n", with: "")
    }

    /// Plain printable ASCII stays as is; anything else becomes UTF-8 B-words (≤ 39 bytes each, so a
    /// word is 64 characters and the first fits after "Subject: " within 78), split on character
    /// boundaries and joined with folding whitespace.
    static func encodeIfNeeded(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if clean.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) && !clean.contains("=?") {
            return clean
        }
        var words: [String] = []
        var chunk = Data()
        for ch in clean {
            let bytes = Data(String(ch).utf8)
            if chunk.count + bytes.count > 39 && !chunk.isEmpty {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }
}

// MARK: - Addresses

struct MailAddress: Equatable, Sendable {
    var name: String
    var email: String

    /// "Name <a@b>" or "a@b" for display.
    var display: String { name.isEmpty ? email : "\(name) <\(email)>" }

    /// Header form: the name quoted or encoded as needed.
    var header: String {
        guard !name.isEmpty else { return email }
        let ascii = name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        if !ascii { return "\(EncodedWord.encodeIfNeeded(name)) <\(email)>" }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        if name.unicodeScalars.contains(where: specials.contains) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(email)>"
        }
        return "\(name) <\(email)>"
    }

    /// A deliberately plain check: one @, a non-empty local part and a dotted domain, no blanks,
    /// brackets, commas, quotes or line breaks (nothing that could smuggle a header).
    static func isValid(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."),
              !parts[1].hasSuffix("."), email.count <= 254 else { return false }
        let bad = CharacterSet(charactersIn: " \t\r\n<>(),;:\"[]\\").union(.controlCharacters)
        return !email.unicodeScalars.contains(where: bad.contains)
    }

    /// An address list header (`From`, `To`, `Cc`): commas inside quotes, angle brackets and comments
    /// don't split; groups (`Team: a@x, b@y;`) are flattened; names are unquoted and decoded.
    static func parseList(_ raw: String) -> [MailAddress] {
        let value = EncodedWord.unfold(raw)
        var pieces: [String] = []
        var current = ""
        var inQuote = false
        var escape = false
        var angle = 0
        var paren = 0
        for ch in value {
            if escape { current.append(ch); escape = false; continue }
            if ch == "\\" && (inQuote || paren > 0) { current.append(ch); escape = true; continue }
            if inQuote {
                if ch == "\"" { inQuote = false }
                current.append(ch)
                continue
            }
            switch ch {
            case "\"" where paren == 0: inQuote = true; current.append(ch)
            case "(": paren += 1; current.append(ch)
            case ")": paren = max(0, paren - 1); current.append(ch)
            case "<" where paren == 0: angle += 1; current.append(ch)
            case ">" where paren == 0: angle = max(0, angle - 1); current.append(ch)
            case ",", ";":
                if angle == 0 && paren == 0 { pieces.append(current); current = "" } else { current.append(ch) }
            case ":" where angle == 0 && paren == 0 && !current.contains("@"):
                current = ""   // "Group name:" — drop the label
            default:
                current.append(ch)
            }
        }
        pieces.append(current)
        return pieces.compactMap(parseOne)
    }

    static func parseOne(_ piece: String) -> MailAddress? {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") {
            let email = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            guard email.contains("@") else { return nil }
            let name = cleanName(String(trimmed[..<open]))
            return MailAddress(name: name, email: email)
        }
        // "a@b (Comment Name)"
        var comment = ""
        var bare = ""
        var depth = 0
        for ch in trimmed {
            if ch == "(" { depth += 1; if depth == 1 { continue } }
            if ch == ")" && depth > 0 { depth -= 1; if depth == 0 { continue } }
            if depth > 0 { comment.append(ch) } else { bare.append(ch) }
        }
        let email = bare.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard email.contains("@"), !email.contains(" ") else { return nil }
        return MailAddress(name: cleanName(comment), email: email)
    }

    private static func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop comments in the phrase.
        while let open = name.firstIndex(of: "("), let close = name[open...].firstIndex(of: ")") {
            name.removeSubrange(open...close)
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
            name = String(name.dropFirst().dropLast())
            var out = ""
            var escape = false
            for ch in name {
                if escape { out.append(ch); escape = false } else if ch == "\\" { escape = true } else { out.append(ch) }
            }
            name = out
        }
        name = EncodedWord.decode(name).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("'") && name.hasSuffix("'") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
        return name
    }
}

// MARK: - Dates

enum MailDate {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm zzz", "d MMM yyyy HH:mm zzz",
    ].map { pattern -> DateFormatter in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f
    }

    /// RFC 5322 `Date:` (comments like "(UTC)" removed), nil when unreadable.
    static func parse(_ raw: String) -> Date? {
        var text = raw
        while let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            text.removeSubrange(open...close)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        for f in formats { if let d = f.date(from: text) { return d } }
        return nil
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}

// MARK: - HTML character references

enum HTMLEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "sbquo": "\u{201A}",
        "bdquo": "\u{201E}", "bull": "\u{2022}", "middot": "\u{00B7}", "euro": "\u{20AC}", "pound": "\u{00A3}",
        "yen": "\u{00A5}", "cent": "\u{00A2}", "laquo": "\u{00AB}", "raquo": "\u{00BB}", "times": "\u{00D7}",
        "divide": "\u{00F7}", "deg": "\u{00B0}", "para": "\u{00B6}", "sect": "\u{00A7}", "zwnj": "\u{200C}",
        "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}", "shy": "\u{00AD}", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "thinsp": "\u{2009}", "iexcl": "\u{00A1}", "iquest": "\u{00BF}", "eacute": "\u{00E9}",
        "egrave": "\u{00E8}", "aacute": "\u{00E1}", "agrave": "\u{00E0}", "uuml": "\u{00FC}", "ouml": "\u{00F6}",
        "auml": "\u{00E4}", "szlig": "\u{00DF}", "ccedil": "\u{00E7}", "ntilde": "\u{00F1}", "rarr": "\u{2192}",
        "larr": "\u{2190}", "uarr": "\u{2191}", "darr": "\u{2193}", "hearts": "\u{2665}", "check": "\u{2713}",
        "colon": ":", "tab": "\t", "newline": "\n", "lpar": "(", "rpar": ")", "sol": "/", "bsol": "\\",
        "period": ".", "comma": ",", "excl": "!", "num": "#", "percnt": "%", "semi": ";", "equals": "=",
    ]
    /// Named references browsers also accept without the semicolon (legacy).
    static let legacy: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    /// Decodes `&name;`, `&#123;` and `&#x7B;` (numeric ones with or without `;`, as browsers do).
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            guard s[i] == "&" else { out.append(s[i]); i += 1; continue }
            var j = i + 1
            if j < s.count, s[j] == "#" {
                j += 1
                var hex = false
                if j < s.count, s[j] == "x" || s[j] == "X" { hex = true; j += 1 }
                var digits = ""
                while j < s.count, digits.count < 10,
                      hex ? s[j].properties.isASCIIHexDigit : ("0"..."9").contains(s[j]) {
                    digits.unicodeScalars.append(s[j])
                    j += 1
                }
                if !digits.isEmpty, let value = UInt32(digits, radix: hex ? 16 : 10) {
                    if j < s.count, s[j] == ";" { j += 1 }
                    let scalar = (value == 0 || value > 0x10FFFF || (0xD800...0xDFFF).contains(value))
                        ? Unicode.Scalar(0xFFFD)! : Unicode.Scalar(value) ?? Unicode.Scalar(0xFFFD)!
                    out.append(scalar)
                    i = j
                    continue
                }
                out.append(s[i])
                i += 1
                continue
            }
            var name = ""
            while j < s.count, name.count < 12, s[j].properties.isAlphabetic || ("0"..."9").contains(s[j]) {
                name.unicodeScalars.append(s[j])
                j += 1
            }
            if j < s.count, s[j] == ";", let value = named[name] ?? named[name.lowercased()] {
                out.append(contentsOf: value.unicodeScalars)
                i = j + 1
                continue
            }
            if legacy.contains(name), let value = named[name] {
                out.append(contentsOf: value.unicodeScalars)
                i = j
                continue
            }
            out.append(s[i])
            i += 1
        }
        return String(out)
    }

    static func escapeText(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func escapeAttribute(_ text: String) -> String {
        var out = ""
        for ch in text.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
