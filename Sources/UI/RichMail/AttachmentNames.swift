import Foundation
import UniformTypeIdentifiers

/// What the reader says about an attachment (rich mail, D-043): the sanitized display
/// name (also the name every saved, opened or dragged copy gets), its type badge and kind, whether it can run code
/// (Open asks first), whether Quick Look may draw it, and the VoiceOver label. Pure: no AppKit, no files.
enum AttachmentNames {
    /// Gmail accepts messages up to 50 MB; nothing bigger is fetched (`LocalAttachmentStore.maxBytes`).
    static let maxFetchBytes = 50 << 20

    // MARK: Display name

    /// Controls, bidi overrides and invisible characters a sender can use to disguise a name.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true                       // C0, DEL, C1 (NUL included)
        case 0x202A...0x202E, 0x2066...0x2069: return true               // bidi embeddings, overrides, isolates
        case 0x200E, 0x200F, 0x061C: return true                         // LRM, RLM, ALM
        case 0x200B...0x200D, 0xFEFF: return true                        // zero-width space, joiners, BOM
        default: return false
        }
    }

    /// The name shown, saved and dragged: hidden characters removed, `/ \ :` → `-`, dots and spaces trimmed at both
    /// ends, never empty ("Attachment.pdf" from the type), at most 255 UTF-8 bytes with the extension kept.
    static func display(_ raw: String, mimeType: String = "") -> String {
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !isHidden($0) }))
        name = String(name.map { "/\\:".contains($0) ? "-" : $0 })
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if name.hasPrefix(".") { name = "_" + name }
        if name.isEmpty || name == "." || name == ".." {
            let ext = fileExtension(forMIME: mimeType)
            name = ext.isEmpty ? "Attachment" : "Attachment.\(ext)"
        }
        return capped(name, bytes: 255)
    }

    /// Cut to `bytes` UTF-8 bytes, keeping ".ext" (when it is a short, sensible extension).
    static func capped(_ name: String, bytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let keep = !ext.isEmpty && ext.utf8.count <= 16 ? "." + ext : ""
        var base = keep.isEmpty ? name : String(name.dropLast(keep.count))
        while !base.isEmpty, base.utf8.count + keep.utf8.count > limit { base.removeLast() }
        return base.trimmingCharacters(in: .whitespaces) + keep
    }

    /// Lowercased extension of a display name ("" for none).
    static func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// The extension for a MIME type ("application/pdf" → "pdf"), "" when unknown.
    static func fileExtension(forMIME mime: String) -> String {
        let m = mime.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if let known = mimeExtensions[m] { return known }
        return UTType(mimeType: m)?.preferredFilenameExtension ?? ""
    }

    private static let mimeExtensions: [String: String] = [
        "application/pdf": "pdf", "image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png", "image/gif": "gif",
        "image/heic": "heic", "image/webp": "webp", "image/tiff": "tiff", "text/plain": "txt", "text/calendar": "ics",
        "text/html": "html", "application/zip": "zip", "message/rfc822": "eml",
    ]

    /// The type badge on the chip ("PDF"): the real extension, so "invoice‮fdp.exe" reads as EXE.
    static func badge(_ name: String, mimeType: String = "") -> String {
        var ext = fileExtension(name)
        if ext.isEmpty { ext = fileExtension(forMIME: mimeType) }
        return String(ext.uppercased().prefix(5))
    }

    /// The type, from the extension first (what Finder will use), else the MIME type.
    static func type(_ name: String, mimeType: String = "") -> UTType {
        let ext = fileExtension(name)
        if !ext.isEmpty, let t = UTType(filenameExtension: ext) { return t }
        let m = mimeType.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return UTType(mimeType: m) ?? .data
    }

    // MARK: Kind ("PDF document · 2.4 MB")

    private static let kinds: [String: String] = [
        "pdf": "PDF document", "doc": "Word document", "docx": "Word document", "pages": "Pages document",
        "rtf": "Rich text document", "txt": "Plain text", "md": "Plain text",
        "xls": "Excel spreadsheet", "xlsx": "Excel spreadsheet", "numbers": "Numbers spreadsheet", "csv": "CSV spreadsheet",
        "ppt": "PowerPoint presentation", "pptx": "PowerPoint presentation", "key": "Keynote presentation",
        "zip": "ZIP archive", "gz": "Archive", "tgz": "Archive", "tar": "Archive", "7z": "Archive", "rar": "Archive",
        "jpg": "JPEG image", "jpeg": "JPEG image", "png": "PNG image", "gif": "GIF image", "heic": "HEIC image",
        "heif": "HEIC image", "webp": "WebP image", "tif": "TIFF image", "tiff": "TIFF image", "svg": "SVG image",
        "ics": "Calendar invite", "vcf": "Contact card", "eml": "Email message",
        "dmg": "Disk image", "iso": "Disk image", "pkg": "Installer package", "mpkg": "Installer package",
        "app": "Application", "exe": "Windows program", "msi": "Windows installer",
        "mp3": "Audio", "m4a": "Audio", "wav": "Audio", "aac": "Audio", "mp4": "Video", "mov": "Video", "m4v": "Video",
        "html": "Web page", "htm": "Web page", "json": "JSON file", "xml": "XML file", "mobileconfig": "Configuration profile",
    ]

    static func kindName(_ name: String, mimeType: String = "") -> String {
        var ext = fileExtension(name)
        if ext.isEmpty { ext = fileExtension(forMIME: mimeType) }
        if let kind = kinds[ext] { return kind }
        let top = mimeType.lowercased().split(separator: "/").first.map(String.init) ?? ""
        switch top {
        case "image": return "Image"
        case "audio": return "Audio"
        case "video": return "Video"
        case "text": return "Text document"
        default: return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
        }
    }

    // MARK: Risky types

    static let riskyExtensions: Set<String> = [
        "app", "command", "tool", "sh", "zsh", "bash", "csh", "ksh", "pl", "py", "rb", "js", "scpt", "scptd", "applescript",
        "workflow", "action", "pkg", "mpkg", "dmg", "iso", "jar", "exe", "msi", "bat", "cmd", "ps1", "vbs", "terminal",
        "webloc", "inetloc", "fileloc", "url", "desktop", "html", "htm", "xhtml", "shtml", "svg", "mobileconfig", "kext",
        "plugin", "prefpane", "saver", "qlgenerator", "dylib", "so", "bundle",
    ]

    private static let riskyTypes: [UTType] = [
        .executable, .application, .script, UTType("com.apple.installer-package-archive") ?? .executable,
    ]

    /// Apps, scripts, installers, disk images, configuration profiles, web pages: anything that can run code or
    /// change the Mac. Checked on the extension and on the type from the extension and the MIME type.
    static func isRisky(_ name: String, mimeType: String = "") -> Bool {
        let ext = fileExtension(name)
        if riskyExtensions.contains(ext) { return true }
        if ext.isEmpty, riskyExtensions.contains(fileExtension(forMIME: mimeType)) { return true }   // "driver" sent as a disk image
        var types: [UTType] = []
        if !ext.isEmpty, let t = UTType(filenameExtension: ext) { types.append(t) }
        let m = mimeType.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !m.isEmpty, m != "application/octet-stream", let t = UTType(mimeType: m) { types.append(t) }
        return types.contains { t in riskyTypes.contains { t.conforms(to: $0) } }
    }

    /// HTML-family files open in the browser, never in our web view.
    static func opensInBrowser(_ name: String) -> Bool {
        ["html", "htm", "xhtml", "shtml", "svg"].contains(fileExtension(name))
    }

    // MARK: Quick Look: types whose generators render web content are Open/Save only

    static let quickLookExcluded: Set<String> = [
        "html", "htm", "xhtml", "shtml", "svg", "webarchive", "eml", "emlx", "mht", "mhtml", "webloc", "inetloc", "fileloc",
        "xml", "mobileconfig",
    ]

    static func canQuickLook(_ name: String, mimeType: String = "") -> Bool {
        var ext = fileExtension(name)
        if ext.isEmpty { ext = fileExtension(forMIME: mimeType) }
        if quickLookExcluded.contains(ext) { return false }
        let m = mimeType.lowercased()
        return !(m.hasPrefix("text/html") || m.hasPrefix("image/svg") || m.hasPrefix("message/"))
    }

    // MARK: Inline previews: raster images, 10 MB each, 6 and 20 MB per message

    static let previewExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff"]
    static let previewMaxBytes = 10_000_000
    static let previewMaxCount = 6
    static let previewMaxTotal = 20_000_000

    static func isPreviewableImage(_ name: String, mimeType: String = "") -> Bool {
        var ext = fileExtension(name)
        if ext.isEmpty { ext = fileExtension(forMIME: mimeType) }
        return previewExtensions.contains(ext)
    }

    /// Which images preview when the card appears (in order, within the caps), and how many wait for
    /// "Show image previews".
    static func previewPlan(_ files: [MailMessage.Attachment]) -> (auto: [MailMessage.Attachment], deferred: [MailMessage.Attachment]) {
        var auto: [MailMessage.Attachment] = []
        var deferred: [MailMessage.Attachment] = []
        var total = 0
        for a in files where isPreviewableImage(a.name, mimeType: a.mimeType) && !a.id.isEmpty && a.bytes <= maxFetchBytes {
            if a.bytes <= previewMaxBytes, auto.count < previewMaxCount, total + a.bytes <= previewMaxTotal {
                auto.append(a)
                total += a.bytes
            } else {
                deferred.append(a)
            }
        }
        return (auto, deferred)
    }

    // MARK: Words

    /// "3 attachments · 14.7 MB"
    static func summary(_ files: [MailMessage.Attachment]) -> String {
        let total = files.reduce(0) { $0 + max(0, $1.bytes) }
        return (files.count == 1 ? "1 attachment" : "\(files.count) attachments") + " \u{00B7} " + MailText.size(total)
    }

    /// "PDF document · 2.4 MB"
    static func detail(_ a: MailMessage.Attachment) -> String {
        kindName(display(a.name, mimeType: a.mimeType), mimeType: a.mimeType) + " \u{00B7} " + MailText.size(a.bytes)
    }

    /// VoiceOver: "Attachment, Installer.dmg, Disk image, 3.1 MB, can run code or change your Mac".
    static func accessibilityLabel(_ a: MailMessage.Attachment) -> String {
        let name = display(a.name, mimeType: a.mimeType)
        var parts = ["Attachment", name, kindName(name, mimeType: a.mimeType), MailText.size(a.bytes)]
        if isRisky(name, mimeType: a.mimeType) { parts.append("can run code or change your Mac") }
        if a.bytes > maxFetchBytes { parts.append("too big to open here") }
        return parts.joined(separator: ", ")
    }

    /// The risky-Open question. `sender` is the display name the reader shows.
    static func riskyTitle(_ name: String) -> String {
        "\u{201C}\(name)\u{201D} can run code or change your Mac."
    }

    static func riskyMessage(sender: String) -> String {
        let who = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        return who.isEmpty ? "Open it only if you expected it." : "Open it only if you expected it from \(who)."
    }
}
