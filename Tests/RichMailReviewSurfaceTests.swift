import AppKit
import Foundation
import ImageIO

/// Rich mail hardening, composer and file side: a symlink is staged as a copy of its target (never a live link, never a
/// chmod through it) and a symlink to a folder is refused; a file too big for any message is refused before anything is
/// copied, and copies are made off the main actor; signature logos and inline pictures go out without their metadata
/// (EXIF, GPS, comments, text, anything after the end), or redrawn; saves work into folders under /private/tmp; the
/// reader asks about images with the message's account. Cast data only; files under Tests/.out and one folder under
/// /private/tmp (removed after).
@MainActor
enum RichMailReviewSurfaceTests {
    static func run() async {
        symlinks()
        await bigFilesAndCopies()
        pictureMetadata()
        privateFolders()
        readerAccount()
    }

    typealias R = RichSendSurfaceTests

    static func fresh(_ name: String) -> URL {
        let url = R.outFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    // MARK: Symlinks

    static func symlinks() {
        T.section("Rich mail: attaching symlinks")
        let fm = FileManager.default
        let root = fresh("review-links")
        let real = root.appendingPathComponent("Shared plan.pdf")
        try? Data("plan v1".utf8).write(to: real)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: real.path)
        let link = root.appendingPathComponent("Plan link.pdf")
        try? fm.createSymbolicLink(at: link, withDestinationURL: real)
        let staging = ComposeStaging(root: root.appendingPathComponent("data", isDirectory: true))
        let staged = try? staging.stage(link)
        T.check(staged.map(isRegularFile) == true, "a symlink is staged as a regular file (a copy of its target), never as a link")
        T.equal(ComposerAttachRules.size(link), 7, "a symlink's size is its target's (size checks can't be passed with a link)")
        T.equal(R.posix(real), 0o644, "the link's target keeps its permissions (nothing is chmodded through the link)")
        T.equal(staged.map(R.posix), 0o600, "the staged copy is 0600")
        try? Data("plan v2, edited after attaching".utf8).write(to: real)
        T.check(staged.flatMap { try? Data(contentsOf: $0) } == Data("plan v1".utf8), "the staged copy keeps the bytes from when it was attached")
        // A symlink to a folder is a folder.
        let folder = root.appendingPathComponent("Tour photos", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderLink = root.appendingPathComponent("Tour photos link")
        try? fm.createSymbolicLink(at: folderLink, withDestinationURL: folder)
        T.check(ComposerAttachRules.isFolderOrPackage(folderLink), "a symlink to a folder counts as a folder")
        T.check((try? staging.stage(folderLink)) == nil, "staging refuses a symlink to a folder")
        let m = R.model(.new(from: RichMailCast.orb.id), staging: staging)
        T.equal(m.attach(urls: [folderLink]), 0, "the composer refuses a symlink to a folder")
        T.equal(m.problem, ComposerAttachRules.folderRefused, "with the folders line")
        // A link to nothing.
        let dangling = root.appendingPathComponent("Gone.pdf")
        try? fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing.pdf"))
        T.check((try? staging.stage(dangling)) == nil, "a dangling symlink can't be staged")
        T.equal(m.attach(urls: [dangling]), 0, "…or attached")
        T.equal(m.problem, ComposerProblem.attachmentFailed("Gone.pdf").message, "with the can't-read line")
        staging.removeAll()
    }

    // MARK: Big files, copies off the main actor

    static func bigFilesAndCopies() async {
        T.section("Rich mail: big files and background copies")
        let fm = FileManager.default
        let root = fresh("review-big")
        let huge = root.appendingPathComponent("Tour footage.mov")
        _ = fm.createFile(atPath: huge.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: huge) { try? handle.truncate(atOffset: 30_000_000); try? handle.close() }   // sparse
        let staging = ComposeStaging(root: root.appendingPathComponent("data", isDirectory: true))
        let m = R.model(.new(from: RichMailCast.orb.id), staging: staging)
        m.to = RichMailCast.juniper.email
        T.equal(m.attach(urls: [huge]), 0, "a file too big for any message is refused")
        T.equal(m.problem, "\u{201C}Tour footage.mov\u{201D} is 30.0 MB. Gmail takes up to 25 MB with attachments, so it can\u{2019}t be sent.",
                "with its size")
        let copied = (try? fm.contentsOfDirectory(atPath: staging.folder.path)) ?? []
        T.check(copied.isEmpty && m.attachments.isEmpty, "nothing was copied for it")
        T.check(ComposerAttachRules.fitsAlone(18_000_000) && !ComposerAttachRules.fitsAlone(18_400_000),
                "the line: a file whose base64 alone passes 25 MB (about 18.3 MB)")
        // A normal file: the chip at once, the copy in the background.
        let plan = root.appendingPathComponent("Launch plan.pdf")
        try? Data(repeating: 0x25, count: 24_000).write(to: plan)
        T.equal(m.attach(urls: [plan]), 1, "a normal file is attached")
        let chip = m.attachments.first
        T.check(chip?.isLoading == true && chip?.file == nil && chip?.bytes == 24_000 && m.problem == nil,
                "its chip shows at once (name, size) while the copy is made off the main actor")
        T.check(chip?.spoken.hasSuffix(", still copying") == true, "VoiceOver says it is still copying")
        guard case .failure(.attachmentsCopying) = m.draft() else { T.check(false, "send while copying → .attachmentsCopying"); return }
        T.equal(ComposerProblem.attachmentsCopying.message, "Still copying your files. Send again in a moment.", "copying text")
        await m.attachmentsCopied()
        let ready = m.attachments.first
        T.check(ready?.state == .ready && ready?.file?.path.hasPrefix(staging.folder.path + "/") == true && ready?.file.map(R.posix) == 0o600,
                "then it is ready: a 0600 staged copy")
        if case .success(let d) = m.draft() { T.check(d.attachments.count == 1, "and the draft carries it") } else { T.check(false, "draft after copying") }
        // Removed while copying, then Undo: the finished copy is used.
        let sheet = root.appendingPathComponent("Budget Q4.xlsx")
        try? Data(repeating: 0x42, count: 4_100).write(to: sheet)
        m.attach(urls: [sheet])
        guard let pending = m.attachments.last, pending.isLoading else { T.check(false, "second chip copying"); return }
        m.removeAttachment(pending.id)
        await m.attachmentsCopied()
        m.restoreAttachment(pending, at: 1)
        T.check(m.attachments.last?.state == .ready && m.attachments.last?.file?.path.hasPrefix(staging.folder.path + "/") == true,
                "a chip removed while copying comes back ready on Undo")
        // The window closed while copying: nothing is left in the staging folder.
        let late = R.model(.new(from: RichMailCast.orb.id), staging: ComposeStaging(root: root.appendingPathComponent("late", isDirectory: true)))
        late.attach(urls: [plan])
        late.discardStaging()
        await late.attachmentsCopied()
        let lateFolder = root.appendingPathComponent("late/compose", isDirectory: true)
        T.check(((try? fm.contentsOfDirectory(atPath: lateFolder.path)) ?? []).isEmpty, "a copy that finishes after the window closed is not kept")
        staging.removeAll()
    }

    // MARK: Picture metadata

    static func taggedJPEG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.5, green: 0.65, blue: 0.85, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 64, height: 48).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            // The fixed clock's London (D-028): a public landmark, nobody's home.
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5072, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.1276, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:01 10:00:00",
                                             kCGImagePropertyExifUserComment: "Orbital Pickle Co. headshot"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Pickle", kCGImagePropertyTIFFModel: "Cam 2"],
        ]
        CGImageDestinationAddImage(dest, rep.cgImage!, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func taggedPNG() -> Data {
        let png = R.png(80, 40, alpha: true)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return png }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGAuthor: "Avery Moonfield", kCGImagePropertyPNGDescription: "lake house",
                                            kCGImagePropertyPNGCreationTime: "2026:10:01 10:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5072, kCGImagePropertyGPSLatitudeRef: "N"],
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        return props
    }

    /// GPS, the EXIF/TIFF fields the fixtures set, or PNG text.
    static func leaks(_ data: Data) -> [String] {
        let p = properties(data)
        var out: [String] = []
        if p[kCGImagePropertyGPSDictionary] != nil { out.append("GPS") }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifUserComment] != nil { out.append("EXIF") }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil { out.append("TIFF") }
        let png = p[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        if png[kCGImagePropertyPNGAuthor] != nil || png[kCGImagePropertyPNGDescription] != nil || png[kCGImagePropertyPNGCreationTime] != nil {
            out.append("PNG text")
        }
        return out
    }

    static func size(_ data: Data) -> CGSize {
        let p = properties(data)
        return CGSize(width: (p[kCGImagePropertyPixelWidth] as? Int) ?? 0, height: (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    static func pictureMetadata() {
        T.section("Rich mail: picture metadata")
        let jpeg = taggedJPEG(), png = taggedPNG()
        T.check(leaks(jpeg) == ["GPS", "EXIF", "TIFF"] && leaks(png).contains("PNG text"), "the fixtures carry GPS, EXIF and PNG text (\(leaks(jpeg)) \(leaks(png)))")
        // Picked in Settings.
        for (name, data) in [("headshot.jpg", jpeg), ("logo.png", png)] {
            guard case .success(let run) = SignatureLogo.attachment(data, name: name) else { T.check(false, "\(name) is accepted as a logo"); continue }
            let sent = MailHTMLWriter.render(run, font: .sans, size: 14, contentId: { "logo@yayascalendar.local" }).inlineImages.first?.data ?? Data()
            T.check(leaks(sent).isEmpty, "a \(name) signature logo goes out without metadata (left: \(leaks(sent)))")
            T.equal(size(sent), size(data), "\(name): same pixel size")
        }
        // A logo stored before the fix (RTFD holding the original bytes): the writer strips it at send time.
        let wrapper = FileWrapper(regularFileWithContents: jpeg)
        wrapper.preferredFilename = "headshot.jpg"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.bounds = CGRect(x: 0, y: 0, width: 64, height: 48)
        let run = NSAttributedString(attachment: attachment)
        if let rtfd = run.rtfd(from: NSRange(location: 0, length: run.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]),
           let loaded = NSAttributedString(rtfd: rtfd, documentAttributes: nil) {
            let out = MailHTMLWriter.render(loaded, font: .sans, size: 14, contentId: { "logo@yayascalendar.local" })
            T.check(out.inlineImages.count == 1 && out.inlineImages.first.map { leaks($0.data).isEmpty && $0.mimeType == "image/jpeg" } == true,
                    "an older stored logo is sent without GPS or EXIF")
        } else { T.check(false, "RTFD round trip") }
        // Pictures with nothing to remove go byte for byte (inline photos are already re-encoded without metadata).
        let photo = ComposerImages.prepare(R.png(300, 200))!.data, shot = ComposerImages.prepare(R.png(300, 200, alpha: true))!.data
        T.check(MailHTMLWriter.stripMetadata(photo) == photo && MailHTMLWriter.stripMetadata(shot) == shot,
                "a picture with nothing to remove is sent byte for byte")
        T.check(MailHTMLWriter.stripMetadata(Data("not a picture".utf8)) == nil, "anything else is never vouched for (nil)")
        hiddenExtras(photo: photo, shot: shot)
        gifBlocks()
        redrawnPictures()
    }

    static func ascii(_ data: Data, has text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

    /// CRC-32 of a PNG chunk's type and data.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    static func pngChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let n = UInt32(payload.count), body = Array(type.utf8) + payload, crc = crc32(body)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
            + [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
    }

    /// Metadata ImageIO's properties don't show: a JPEG comment, an unknown JPEG segment, a PNG text chunk with its own
    /// keyword, a time chunk and bytes after the end. None of it is sent; the pixels are.
    static func hiddenExtras(photo: Data, shot: Data) {
        T.check(!PictureFile.hasExtras(photo) && !PictureFile.hasExtras(shot), "the app's own JPEG and PNG have no extras")
        let jpeg = [UInt8](photo), note = Array("Shot by Avery Moonfield".utf8)
        let comment = Data(jpeg.prefix(2) + [0xFF, 0xFE, 0, UInt8(note.count + 2)] + note + jpeg.dropFirst(2))
        let segment = Data(jpeg.prefix(2) + [0xFF, 0xEB, 0, UInt8(note.count + 2)] + note + jpeg.dropFirst(2))
        let trailer = Data(jpeg + note)
        let byline: [UInt8] = [0x1C, 0x02, 0x50, 0x00, UInt8(note.count)] + note        // IPTC by-line (28 bytes, even)
        let irb = Array("Photoshop 3.0".utf8) + [0] + Array("8BIM".utf8) + [0x04, 0x04, 0, 0, 0, 0, 0, UInt8(byline.count)] + byline
        let photoshop = Data(jpeg.prefix(2) + [0xFF, 0xED, 0, UInt8(irb.count + 2)] + irb + jpeg.dropFirst(2))
        let png = [UInt8](shot), iend = png.count - 12
        let text = Data(png.prefix(iend) + pngChunk("tEXt", Array("Owner".utf8) + [0] + note) + png.suffix(12))
        let time = Data(png.prefix(iend) + pngChunk("tIME", [0x07, 0xEA, 10, 19, 9, 48, 0]) + png.suffix(12))
        for (name, data, original) in [("a JPEG comment", comment, photo), ("an unknown JPEG segment", segment, photo),
                                       ("bytes after a JPEG's end", trailer, photo), ("a Photoshop block with a by-line", photoshop, photo),
                                       ("a PNG text chunk", text, shot), ("a PNG time chunk", time, shot)] {
            T.check(PictureFile.hasExtras(data), "\(name) is found")
            guard let out = MailHTMLWriter.stripMetadata(data) else { T.check(false, "\(name): a clean copy is made"); continue }
            T.check(!PictureFile.hasExtras(out) && !ascii(out, has: "Avery") && out != data && size(out) == size(original),
                    "\(name) is not sent; the pixels are (\(data.count) → \(out.count) bytes)")
        }
        // The writer sends the clean copy, never the bytes it was given.
        let wrapper = FileWrapper(regularFileWithContents: comment)
        wrapper.preferredFilename = "photo.jpg"
        let out = MailHTMLWriter.render(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)), font: .sans, size: 14)
        T.check(out.inlineImages.first.map { !ascii($0.data, has: "Avery") && $0.mimeType == "image/jpeg" } == true,
                "an inline JPEG with a comment goes out without it")
    }

    /// A two-frame GIF with a comment block and an XMP block: both dropped, the frames and loop count kept byte for byte.
    static func gifBlocks() {
        let frames = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(frames, "com.compuserve.gif" as CFString, 2, nil) else { T.check(false, "GIF encoder"); return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for alpha in [false, true] {
            guard let source = CGImageSourceCreateWithData(R.png(24, 16, alpha: alpha) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { T.check(false, "GIF written"); return }
        let gif = [UInt8](frames as Data)
        T.check(gif.last == 0x3B && PictureFile.strippedGIF(frames as Data) == frames as Data && !PictureFile.hasExtras(frames as Data),
                "a plain GIF strips to itself")
        let note = Array("Avery Moonfield, lake house".utf8)
        let comment: [UInt8] = [0x21, 0xFE, UInt8(note.count)] + note + [0]
        let packet = Array("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:creator=\"Avery Moonfield\"/></rdf:RDF></x:xmpmeta>".utf8)
        var xmp: [UInt8] = [0x21, 0xFF, 11] + Array("XMP DataXMP".utf8)
        for chunk in stride(from: 0, to: packet.count, by: 255) { let part = packet[chunk..<min(chunk + 255, packet.count)]; xmp += [UInt8(part.count)] + part }
        xmp.append(0)
        let tagged = Data(gif.dropLast() + comment + xmp + [0x3B] + Array("trailing".utf8))
        T.check(PictureFile.hasExtras(tagged), "the comment, XMP and trailing bytes are found")
        guard let out = MailHTMLWriter.stripMetadata(tagged) else { T.check(false, "the tagged GIF gets a clean copy"); return }
        T.check(out == frames as Data, "the clean GIF is the original frames byte for byte (\(out.count) of \(tagged.count) bytes)")
        let loops = CGImageSourceCreateWithData(out as CFData, nil).flatMap { CGImageSourceCopyProperties($0, nil) as? [CFString: Any] }
            .flatMap { $0[kCGImagePropertyGIFDictionary] as? [CFString: Any] }?[kCGImagePropertyGIFLoopCount] as? Int
        T.check(CGImageSourceCreateWithData(out as CFData, nil).map(CGImageSourceGetCount) == 2 && loops == 0, "two frames, looping forever")
        let wrapper = FileWrapper(regularFileWithContents: tagged)
        wrapper.preferredFilename = "wave.gif"
        let sent = MailHTMLWriter.render(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)), font: .sans, size: 14).inlineImages.first
        T.check(sent?.mimeType == "image/gif" && sent?.data == out, "the writer sends the GIF without its comment and XMP")
    }

    /// Pictures stripMetadata can't vouch for (here a TIFF with GPS, which isn't PNG, JPEG or GIF) are redrawn from their
    /// pixels as a new PNG, upright: the original bytes never go.
    static func redrawnPictures() {
        guard let source = CGImageSourceCreateWithData(taggedJPEG() as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            T.check(false, "fixture image"); return
        }
        let tiff = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 1, nil) else { T.check(false, "TIFF encoder"); return }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5072, kCGImagePropertyGPSLatitudeRef: "N"],
                                                 kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(dest)
        T.check(leaks(tiff as Data) == ["GPS"] && MailHTMLWriter.stripMetadata(tiff as Data) == nil, "a TIFF with GPS isn't vouched for")
        let wrapper = FileWrapper(regularFileWithContents: tiff as Data)
        wrapper.preferredFilename = "scan.tiff"
        guard let sent = MailHTMLWriter.render(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)), font: .sans, size: 14).inlineImages.first else {
            T.check(false, "the TIFF is sent"); return
        }
        T.check(sent.mimeType == "image/png" && leaks(sent.data).isEmpty && !PictureFile.hasExtras(sent.data), "it goes as a new PNG without GPS")
        T.equal(size(sent.data), CGSize(width: 48, height: 64), "turned upright (orientation 6: 64 × 48 → 48 × 64)")
    }

    // MARK: Saves under /private

    static func privateFolders() {
        T.section("Rich mail: saving under /private/tmp")
        let fm = FileManager.default
        let name = "yc-shell-\(UUID().uuidString)"
        let base = URL(fileURLWithPath: "/private/tmp/" + name, isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let saves = base.appendingPathComponent("Saved", isDirectory: true)
        try? fm.createDirectory(at: saves, withIntermediateDirectories: true)
        let cache = base.appendingPathComponent("cache.bin")
        try? Data("yayas-calendar fixture bytes\n".utf8).write(to: cache)
        let first = try? AttachmentFiles.save(cache, to: saves, name: "Launch plan.pdf")
        T.equal(first?.lastPathComponent, "Launch plan.pdf", "a save into a folder under /private/tmp works")
        let viaTmp = URL(fileURLWithPath: "/tmp/" + name + "/Saved", isDirectory: true)
        let second = try? AttachmentFiles.save(cache, to: viaTmp, name: "Launch plan.pdf")
        T.equal(second?.lastPathComponent, "Launch plan 2.pdf", "the same folder spelled /tmp: the next free name")
        T.check(AttachmentFiles.isInside(saves.appendingPathComponent("x.pdf"), viaTmp) && AttachmentFiles.isInside(viaTmp.appendingPathComponent("x.pdf"), saves),
                "inside, whichever way the folder is spelled")
        T.check(!AttachmentFiles.isInside(saves.appendingPathComponent("../x.pdf"), saves) && !AttachmentFiles.isInside(base.appendingPathComponent("x.pdf"), saves),
                "a path out of the folder is still refused")
        let linked = base.appendingPathComponent("Linked", isDirectory: true)
        try? fm.createSymbolicLink(at: linked, withDestinationURL: saves)
        let third = try? AttachmentFiles.save(cache, to: linked, name: "Menu.jpg")
        T.check(third != nil && fm.fileExists(atPath: saves.appendingPathComponent("Menu.jpg").path), "a save folder that is a symlink works")
        let out = base.appendingPathComponent("Elsewhere", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: saves.appendingPathComponent("Out", isDirectory: true), withDestinationURL: out)
        T.check(!AttachmentFiles.isInside(saves.appendingPathComponent("Out/x.pdf"), saves), "a symlinked subfolder that leaves the folder is outside")
    }

    // MARK: The reader asks with the message's account

    final class ScopedPrefs: MailPreferencesStore {
        let account: UUID
        init(account: UUID) { self.account = account }
        func prefs(account: UUID) -> MailAccountPrefs { MailAccountPrefs(primaryOnly: false, signature: "") }
        func save(account: UUID, _ prefs: MailAccountPrefs) throws {}
        func allowsImages(from sender: String) -> Bool { false }
        func allowsImages(from sender: String, accountId: UUID) -> Bool { accountId == account && sender == RichMailCast.kofi.email }
        func setAllowsImages(from sender: String, _ allowed: Bool) throws {}
    }

    static func readerAccount() {
        T.section("Rich mail: images from correspondents per account")
        let at = Date(timeIntervalSince1970: 1_792_400_000)
        let message = MailMessage(id: "k1", from: RichMailCast.kofi.name, fromEmail: RichMailCast.kofi.email, to: [], cc: [], date: at,
                                  subject: "Photos", html: "<div>Photos <img src=\"https://photos.quietcomets.example/a.jpg\"></div>", text: "Photos",
                                  hasRemoteImages: true, attachments: [])
        func thread(_ account: UUID) -> MailThread {
            MailThread(r: "r-\(account.uuidString)", accountId: account, sender: RichMailCast.kofi.name, senderEmail: RichMailCast.kofi.email,
                       subject: "Photos", snippet: "", at: at, unread: false, starred: false, messageCount: 1)
        }
        let prefs = ScopedPrefs(account: RichMailCast.fam.id)
        let mine = ThreadReaderModel(thread: thread(RichMailCast.fam.id), messages: [message], prefs: { prefs })
        let other = ThreadReaderModel(thread: thread(RichMailCast.orb.id), messages: [message], prefs: { prefs })
        T.check(mine.decision(for: message).allowRemote, "a correspondent of the thread's account: images load")
        T.check(!other.decision(for: message).allowRemote && other.decision(for: message).showImagesBar,
                "the same sender in another account's mail: blocked, with the bar")
    }
}
