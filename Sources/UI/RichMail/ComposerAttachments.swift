import AppKit
import Foundation
import UniformTypeIdentifiers

// The composer's attachments (rich mail, D-043/D-044): the tray's files, the staging
// folder that holds stable copies of them, the size estimate behind the 10 MB warning and the 25 MB problem, and the
// inline-image preparation (photos re-encoded as JPEG 85 at most 2560 px; images with alpha stay PNG; metadata goes).

/// One file in the composer's tray.
struct ComposerAttachment: Equatable, Identifiable {
    enum State: Equatable {
        case ready
        /// A forwarded original still downloading.
        case loading
        case failed(String)
    }

    var id = UUID()
    var filename: String
    var mimeType: String
    var bytes: Int
    /// The staged copy (production), or the user's own file when there is no staging (tests, renders).
    var file: URL?
    /// Without staging: the bytes in memory (pasted images, renders).
    var data: Data?
    var state: State = .ready
    /// A forwarded original's file: its Gmail part id (nil for files the user attached).
    var forwardedPart: String?

    var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
    var isLoading: Bool { state == .loading }
    /// While loading: a file of the user's being copied into staging ("Copying…"), or a forwarded original downloading.
    var isCopying: Bool { isLoading && forwardedPart == nil }
    var failure: String? { if case .failed(let why) = state { return why } else { return nil } }

    /// "PDF document · 2.4 MB"
    var detail: String { AttachmentNames.kindName(filename, mimeType: mimeType) + " \u{00B7} " + MailText.size(bytes) }

    /// VoiceOver: "Launch plan.pdf, PDF document, 2.4 megabytes".
    var spoken: String {
        let size = MailText.size(bytes).replacingOccurrences(of: " MB", with: " megabytes").replacingOccurrences(of: " KB", with: " kilobytes")
            .replacingOccurrences(of: " bytes", with: " bytes")
        var line = "\(filename), \(AttachmentNames.kindName(filename, mimeType: mimeType)), \(size)"
        if isLoading { line += isCopying ? ", still copying" : ", still downloading" }
        if let failure { line += ", " + failure }
        return line
    }

    /// What the draft hands the data layer.
    func draftAttachment(contentId: String? = nil) -> MailDraftAttachment? {
        guard state == .ready, file != nil || data != nil else { return nil }
        return MailDraftAttachment(filename: filename, mimeType: mimeType, file: file ?? URL(fileURLWithPath: "/dev/null"), bytes: bytes,
                                   contentId: contentId, data: data)
    }
}

/// Stable copies of everything attached, so the draft survives the original being moved or deleted and the send builds
/// from bytes nobody else changes: `<data root>/compose/<composer id>/<uuid>` (folders 0700, files 0600). Deleted when
/// the composer window closes (the queued send's outbox file holds the bytes by then) and swept at launch. `stage(_:)`
/// runs off the main actor (the composer copies in the background); a copy that finishes after the window closed is
/// not kept.
final class ComposeStaging: @unchecked Sendable {
    static let folderName = "compose"

    let folder: URL
    private let lock = NSLock()
    private var closed = false

    init(root: URL = Paths.root, id: UUID = UUID()) {
        folder = root.appendingPathComponent(Self.folderName, isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func prepare() throws {
        guard !isClosed else { throw CocoaError(.userCancelled) }
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    }

    /// A copy of `source` (0600) under a fresh name. A symlink is resolved and its target copied: the staged item is a
    /// regular file holding the bytes of now, never a link to the user's live file, and nothing is ever chmodded through a
    /// link. Anything that isn't a regular file once resolved (a folder, a package, a link to nothing) is refused.
    func stage(_ source: URL) throws -> URL {
        let file = try ComposerAttachRules.regularFile(source)
        try prepare()
        let fm = FileManager.default
        let target = folder.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try fm.copyItem(at: file, to: target)
        guard ComposerAttachRules.isRegularFile(target) else {
            try? fm.removeItem(at: target)
            throw CocoaError(.fileReadUnknown)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        if isClosed {
            // The window closed while this copy ran: nothing of it stays.
            try? fm.removeItem(at: folder)
            throw CocoaError(.userCancelled)
        }
        return target
    }

    /// Bytes from memory (pasted images, inline images at send time), 0600.
    func stage(data: Data) throws -> URL {
        try prepare()
        let target = folder.appendingPathComponent(UUID().uuidString, isDirectory: false)
        guard FileManager.default.createFile(atPath: target.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return target
    }

    func remove(_ url: URL?) {
        guard let url, url.path.hasPrefix(folder.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The window closed: everything staged goes, and copies still running are dropped when they finish.
    func removeAll() {
        lock.lock(); closed = true; lock.unlock()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Launch: no composer is open yet, so every staging folder is left over.
    @discardableResult
    static func sweep(root: URL = Paths.root) -> Int {
        let parent = root.appendingPathComponent(folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names { try? FileManager.default.removeItem(at: parent.appendingPathComponent(name)) }
        return names.count
    }
}

/// Size rules the composer shows.
enum ComposerSize {
    static let problemPrefix = "This comes to "

    /// Over 10 MB: "Some mail servers refuse messages over 10 MB." (quietly, in the footer).
    static func warning(_ estimate: Int) -> String? {
        estimate > MailSize.warning ? "Some mail servers refuse messages over 10 MB." : nil
    }

    /// "This comes to 27.4 MB with attachments. Gmail takes up to 25 MB, so remove something."
    static func tooLarge(_ estimate: Int) -> String {
        "This comes to \(MailSize.megabytes(estimate)) with attachments. Gmail takes up to 25 MB, so remove something."
    }

    /// The tray's total line: "3 attachments · 14.7 MB".
    static func total(count: Int, estimate: Int) -> String {
        "\(count) attachment\(count == 1 ? "" : "s") \u{00B7} \(MailSize.megabytes(estimate))"
    }
}

/// What can't be attached, and why.
enum ComposerAttachRules {
    static let folderRefused = "Folders and apps can\u{2019}t be attached. Zip them first."

    /// The path with every symlink resolved (realpath), or nil when it names nothing (a link to nothing included).
    static func resolved(_ url: URL) -> URL? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    /// A folder or a package (an app, a bundle) can't be attached, and neither can a symlink to one.
    static func isFolderOrPackage(_ url: URL) -> Bool {
        guard let target = resolved(url) else { return false }
        let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true || values?.isPackage == true
    }

    /// The item itself (not what a link points at) is a regular file.
    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// The file `url` names with symlinks resolved, when that is a regular file; throws for anything else.
    static func regularFile(_ url: URL) throws -> URL {
        guard let target = resolved(url), isRegularFile(target) else { throw CocoaError(.fileReadNoSuchFile) }
        return target
    }

    /// A file this big can go in a message at all: its base64 alone stays within Gmail's 25 MB (about 18.3 MB). Bigger
    /// files are refused before anything is copied.
    static func fitsAlone(_ bytes: Int) -> Bool {
        MailSize.estimate(text: 0, html: 0, attachments: [bytes]) <= MailSize.limit
    }

    /// "“Tour footage.mov” is 30.0 MB. Gmail takes up to 25 MB with attachments, so it can’t be sent."
    static func tooLargeAlone(_ name: String, bytes: Int) -> String {
        "\u{201C}\(name)\u{201D} is \(MailSize.megabytes(bytes)). Gmail takes up to 25 MB with attachments, so it can\u{2019}t be sent."
    }

    static func mimeType(_ url: URL) -> String { mimeType(name: url.lastPathComponent) }

    static func mimeType(name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The size of the file `url` names (a symlink's target, so a link can't pass a size check for a big file).
    static func size(_ url: URL) -> Int {
        ((try? (resolved(url) ?? url).resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
    }
}

/// A signature logo (D-042): a PNG or JPEG of at most 200 KB, kept as picked (its pixels and transparency) without its
/// metadata (a phone photo's location, camera and dates never go into the signature; `MailHTMLWriter.stripMetadata`),
/// and sent inline with every message from that account.
enum SignatureLogo {
    static let maxBytes = 200 * 1024

    static func attachment(_ url: URL) -> Result<NSAttributedString, ServiceError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(ServiceError(description: "I couldn\u{2019}t read that picture.")) }
        return attachment(data, name: url.lastPathComponent)
    }

    static func attachment(_ picked: Data, name: String) -> Result<NSAttributedString, ServiceError> {
        guard let mime = MailHTMLWriter.sniffImage(picked), mime != "image/gif", NSBitmapImageRep(data: picked) != nil else {
            return .failure(ServiceError(description: "Logos can be PNG or JPEG pictures."))
        }
        guard let data = MailHTMLWriter.stripMetadata(picked), let rep = NSBitmapImageRep(data: data) else {
            return .failure(ServiceError(description: "I couldn\u{2019}t take that picture\u{2019}s details (location, camera, dates) out. Save it again as PNG and pick that copy."))
        }
        guard data.count <= maxBytes else {
            return .failure(ServiceError(description: "That logo is \((data.count + 1023) / 1024) KB. Logos can be up to 200 KB."))
        }
        // Retina pictures (144 dpi) show at half their pixel size, as in other apps.
        let points = rep.size.width > 0 ? rep.size : CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let image = ComposerImages.Prepared(data: data, mimeType: mime, pixels: points, filename: AttachmentNames.display(name, mimeType: mime))
        return .success(ComposerImages.attachment(image, contentId: MailHTMLWriter.newContentId()))
    }
}

/// Inline images: pasted or dropped images up to 5 MB go in the body. Photos are re-encoded as JPEG 85 at most
/// 2560 px on the long edge; images with alpha (screenshots) stay PNG. Re-encoding drops EXIF and GPS.
enum ComposerImages {
    static let inlineLimit = 5 << 20
    static let maxEdge: CGFloat = 2560
    static let jpegQuality: CGFloat = 0.85

    struct Prepared: Equatable {
        var data: Data
        var mimeType: String
        /// Pixels after scaling.
        var pixels: CGSize
        var filename: String
    }

    /// Image data ready to send inline, or nil when it isn't an image AppKit can read.
    static func prepare(_ data: Data, name: String? = nil) -> Prepared? {
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data).flatMap({ $0.tiffRepresentation }).flatMap(NSBitmapImageRep.init(data:)),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let scale = min(1, maxEdge / max(w, h))
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        let alpha = rep.hasAlpha && hasTransparency(rep)
        // Always RGBA (AppKit draws only into formats it supports); opaque photos get a white ground, then JPEG.
        guard let fresh = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: fresh) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGraphicsContext.current?.imageInterpolation = .high
        if !alpha {
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        // The picture's point size is its display size in the message (600 pt wide at most), so the editor draws it at
        // the size recipients see; the pixels stay as many as above.
        var display = size
        if display.width > MailHTMLWriter.maxImageWidth {
            display = CGSize(width: MailHTMLWriter.maxImageWidth, height: max(1, (display.height * MailHTMLWriter.maxImageWidth / display.width).rounded()))
        }
        fresh.size = display
        let base = ((name ?? "") as NSString).deletingPathExtension
        if alpha {
            guard let png = fresh.representation(using: .png, properties: [:]) else { return nil }
            return Prepared(data: png, mimeType: "image/png", pixels: size, filename: (base.isEmpty ? "image" : base) + ".png")
        }
        guard let jpeg = fresh.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else { return nil }
        return Prepared(data: jpeg, mimeType: "image/jpeg", pixels: size, filename: (base.isEmpty ? "photo" : base) + ".jpg")
    }

    /// Any pixel not fully opaque (sampled on a grid for big images).
    private static func hasTransparency(_ rep: NSBitmapImageRep) -> Bool {
        let step = max(1, Int((Double(rep.pixelsWide * rep.pixelsHigh) / 40_000).squareRoot()))
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent < 0.999 { return true }
                x += step
            }
            y += step
        }
        return false
    }

    /// The editor's run for an inline image: an attachment character carrying the bytes (the writer sends them as a
    /// `cid:` part) at its display size (600 pt wide at most), marked with its content id.
    static func attachment(_ image: Prepared, contentId: String, defaults: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let wrapper = FileWrapper(regularFileWithContents: image.data)
        wrapper.preferredFilename = image.filename
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        var display = image.pixels
        if display.width > MailHTMLWriter.maxImageWidth {
            display = CGSize(width: MailHTMLWriter.maxImageWidth, height: (display.height * MailHTMLWriter.maxImageWidth / display.width).rounded())
        }
        attachment.bounds = CGRect(origin: .zero, size: display)
        // No `.image`: setting it would replace the bytes the writer sends (it would re-encode a PNG of the picture).
        let out = NSMutableAttributedString(attachment: attachment)
        var attrs = defaults
        attrs[.ycInlineImage] = contentId
        out.addAttributes(attrs, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Inline images in a document: (content id, range) for each attachment character.
    static func inlineImages(_ doc: NSAttributedString) -> [(contentId: String, range: NSRange)] {
        var out: [(String, NSRange)] = []
        doc.enumerateAttribute(.attachment, in: NSRange(location: 0, length: doc.length)) { value, range, _ in
            guard value is NSTextAttachment else { return }
            let cid = doc.attribute(.ycInlineImage, at: range.location, effectiveRange: nil) as? String ?? ""
            out.append((cid, range))
        }
        return out
    }
}
