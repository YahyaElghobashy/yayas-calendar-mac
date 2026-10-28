import Foundation

// How big a message gets once it is MIME (rich mail, D-044): the composer's estimate (shown in
// the tray, a warning over 10 MB, a problem over 25 MB) and the data layer's exact limit share these numbers. Pure
// Foundation, compiled into the app, the data tests (Mail glob) and the shell tests (the composer's model uses it).

enum MailSize {
    /// Gmail's outgoing limit counts the encoded message: 25,000,000 bytes of raw MIME (equal is allowed).
    static let limit = 25_000_000
    /// Over this the composer says quietly that some servers refuse it.
    static let warning = 10_000_000
    /// Room for the message headers (From, To, Subject, Date, Message-ID, threading, MIME-Version, Content-Type).
    static let headerAllowance = 4_096
    /// Room for each part's headers and boundary lines.
    static let partAllowance = 400

    /// Within Gmail's limit (25,000,000 bytes is allowed; one more is not).
    static func fits(_ bytes: Int) -> Bool { bytes <= limit }

    /// "27.4 MB" (decimal megabytes, as Gmail counts them), rounded up to the tenth so a message just over the limit
    /// never reads "25.0 MB".
    static func megabytes(_ bytes: Int) -> String {
        let tenths = (max(0, bytes) + 99_999) / 100_000
        return "\(tenths / 10).\(tenths % 10) MB"
    }

    /// Bytes of a base64 body in 76-character lines with CRLF: every 57 input bytes become 78.
    static func base64(_ bytes: Int) -> Int { (max(0, bytes) + 56) / 57 * 78 }

    /// A text part's size as quoted-printable before soft line breaks: bytes that QP escapes (non-ASCII, "=",
    /// controls, a blank before a line break, a "." starting a line) count 3, a line break counts 2 (CRLF). The
    /// builder picks 7bit, QP or base64, whichever is smallest, so this never under-counts the part.
    static func qpWeight(_ text: String) -> Int {
        let bytes = Array(text.utf8)
        var total = 0
        var lineStart = true
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x0D && i + 1 < bytes.count && bytes[i + 1] == 0x0A { i += 1; continue }
            if b == 0x0A || b == 0x0D {
                total += 2
                lineStart = true
                i += 1
                continue
            }
            let nextIsBreak = i + 1 >= bytes.count || bytes[i + 1] == 0x0A || bytes[i + 1] == 0x0D
            if b > 0x7E || b == 0x3D || (b < 0x20 && b != 0x09) || ((b == 0x20 || b == 0x09) && nextIsBreak) || (b == 0x2E && lineStart) {
                total += 3
            } else {
                total += 1
            }
            lineStart = false
            i += 1
        }
        return total
    }

    /// The composer's estimate of the raw MIME: headers + text × 1.05 + html × 1.1 (soft line breaks) + each
    /// attachment as base64 lines + `partAllowance` per part. `text` and `html` are `qpWeight`s; `names` is the UTF-8
    /// byte count of every attachment's filename (encoded twice per part, RFC 2231 and 2047); `headers` the bytes of
    /// To, Cc, Bcc and Subject. Never under the built size (a data test checks it against `buildRich`).
    static func estimate(text: Int, html: Int, attachments: [Int], names: Int = 0, headers: Int = 0) -> Int {
        let textPart = (text * 105 + 99) / 100
        let htmlPart = (html * 110 + 99) / 100
        let files = attachments.reduce(0) { $0 + base64($1) }
        let parts = 1 + (html > 0 ? 1 : 0) + attachments.count + 3
        return headerAllowance + headers * 3 + textPart + htmlPart + files + parts * partAllowance + names * 6
    }

    /// The data layer's refusal: "This is 27.4 MB with attachments. Gmail takes up to 25 MB."
    static func tooLargeMessage(_ bytes: Int) -> String {
        "This is \(megabytes(bytes)) with attachments. Gmail takes up to 25 MB."
    }
}
