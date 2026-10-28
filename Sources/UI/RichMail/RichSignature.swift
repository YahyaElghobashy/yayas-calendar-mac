import AppKit

// Rich signatures per account (D-042). Stored as flattened RTFD (`MailAccountPrefs.signatureRich`,
// at most 512 KB) next to the plain rendition (`signature`, 2,000 characters), which plain mode and older builds use.
// Lazy migration: an account without a rich signature gets its plain one in the default font, and nothing is
// rewritten until the user edits it in Settings. Pure (RTFD import is local: no WebKit).

enum RichSignature {
    static let maxBytes = 512 * 1024
    static let maxPlainCharacters = 2_000

    enum Problem: Error, Equatable {
        case tooLarge(bytes: Int)

        var message: String {
            switch self {
            case .tooLarge(let bytes):
                let kb = Int((Double(bytes) / 1024).rounded())
                return "That signature is \(kb) KB. Signatures can be up to 512 KB, so use a smaller logo or less text."
            }
        }
    }

    /// The signature to edit or insert: the rich one when it decodes, else the plain text in the defaults. Leading
    /// and trailing blank lines are trimmed (as the plain composer always did).
    static func load(rich: Data?, plain: String, defaults: ComposerDocument.Defaults = .init()) -> NSAttributedString {
        if let rich, rich.count <= maxBytes, let decoded = NSAttributedString(rtfd: rich, documentAttributes: nil), decoded.length > 0 {
            return trimmed(ComposerDocument.normalize(decoded, defaults: defaults, images: true))
        }
        return ComposerDocument.plain(plain.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n"),
                                      defaults: defaults)
    }

    static func load(_ prefs: MailAccountPrefs, defaults: ComposerDocument.Defaults = .init()) -> NSAttributedString {
        load(rich: prefs.signatureRich, plain: prefs.signature, defaults: defaults)
    }

    /// The plain rendition saved beside it (2,000 characters at most).
    static func plainText(_ rich: NSAttributedString) -> String {
        String(rich.string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxPlainCharacters))
    }

    /// What to store as `signatureRich`: nil when the plain text says it all (no formatting: stays lazy), RTFD
    /// otherwise, or `.tooLarge` past 512 KB.
    static func storable(_ rich: NSAttributedString, defaults: ComposerDocument.Defaults = .init()) -> Result<Data?, Problem> {
        let sig = trimmed(rich)
        guard sig.length > 0, ComposerDocument.hasFormatting(sig, defaults: defaults) else { return .success(nil) }
        guard let data = encode(sig) else { return .success(nil) }
        return data.count > maxBytes ? .failure(.tooLarge(bytes: data.count)) : .success(data)
    }

    static func encode(_ rich: NSAttributedString) -> Data? {
        guard rich.length > 0 else { return nil }
        let clean = NSMutableAttributedString(attributedString: rich)
        clean.removeAttribute(.ycSignature, range: NSRange(location: 0, length: clean.length))
        return clean.rtfd(from: NSRange(location: 0, length: clean.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    /// Without blank lines or spaces at either end.
    static func trimmed(_ rich: NSAttributedString) -> NSAttributedString {
        let ns = rich.string as NSString
        let skip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}\u{2029}"))
        var start = 0, end = ns.length
        while start < end, let s = Unicode.Scalar(ns.character(at: start)), skip.contains(s) { start += 1 }
        while end > start, let s = Unicode.Scalar(ns.character(at: end - 1)), skip.contains(s) { end -= 1 }
        return rich.attributedSubstring(from: NSRange(location: start, length: end - start))
    }

    /// Same text and attributes (Settings' dirty check; RTFD round trips make new but equal objects).
    static func same(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        a.string == b.string && MailHTMLWriter.render(a, font: .sans, size: 14, contentId: { "sig" }).html
            == MailHTMLWriter.render(b, font: .sans, size: 14, contentId: { "sig" }).html
    }
}
