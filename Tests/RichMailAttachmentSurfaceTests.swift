import CoreServices
import Foundation

/// Rich mail attachments, shell tests: the display-name sanitizer table, risky types
/// (Open asks every time), Quick Look exclusions, kind names, VoiceOver labels and preview caps; then real files saved under
/// Tests/.out: unique names, path traversal, symlinks, Open copies, the 24 h sweep, the quarantine record
/// and the save folder fallback. Cast names only.
enum RichMailAttachmentSurfaceTests {
    static func run() {
        names()
        risky()
        kinds()
        files()
        saveFolder()
    }

    typealias A = MailMessage.Attachment

    static func names() {
        T.section("Rich mail: attachment names")
        let table: [(String, String, String)] = [
            ("Launch plan.pdf", "application/pdf", "Launch plan.pdf"),
            ("invoice\u{202E}fdp.exe", "", "invoicefdp.exe"),
            ("a\u{0000}b\u{0007}c\u{007F}.txt", "", "abc.txt"),
            ("tab\tname\r\n.txt", "", "tabname.txt"),
            ("\u{0085}nel.txt", "", "nel.txt"),
            ("zero\u{200B}width\u{200D}\u{FEFF}.pdf", "", "zerowidth.pdf"),
            ("\u{200E}marks\u{200F}\u{061C}.pdf", "", "marks.pdf"),
            ("iso\u{2066}late\u{2069}.pdf", "", "isolate.pdf"),
            ("../../etc/passwd", "", "-..-etc-passwd"),
            ("C:\\Windows\\evil.bat", "", "C--Windows-evil.bat"),
            ("  report.pdf.  ", "", "report.pdf"),
            (".hidden", "", "hidden"),
            ("", "application/pdf", "Attachment.pdf"),
            (".", "", "Attachment"),
            ("..", "image/png", "Attachment.png"),
            ("\u{202E}\u{200B}", "text/calendar", "Attachment.ics"),
            ("Caf\u{00E9} Nowhere menu.jpg", "image/jpeg", "Caf\u{00E9} Nowhere menu.jpg"),
        ]
        for (raw, mime, want) in table {
            T.equal(AttachmentNames.display(raw, mimeType: mime), want, "display(\(raw.debugDescription))")
        }
        let long = String(repeating: "Pickle ", count: 50) + "plan.pdf"
        let capped = AttachmentNames.display(long)
        T.check(capped.utf8.count <= 255 && capped.hasSuffix("plan.pdf") == false && capped.hasSuffix(".pdf"),
                "capped at 255 UTF-8 bytes, the extension kept (\(capped.utf8.count))")
        let wide = AttachmentNames.display(String(repeating: "\u{00E9}", count: 200) + ".pdf")
        T.check(wide.utf8.count <= 255 && wide.hasSuffix(".pdf") && wide.unicodeScalars.allSatisfy { $0 == "\u{00E9}" || ".pdf".unicodeScalars.contains($0) },
                "two-byte characters are cut whole")
        T.equal(AttachmentNames.badge(AttachmentNames.display(RichMailThreads.bidiName)), "EXE", "the badge shows the real extension of a bidi spoof")
        T.equal(AttachmentNames.badge("Launch plan.pdf"), "PDF", "badge")
        T.equal(AttachmentNames.badge("Rehearsal", mimeType: "text/calendar"), "ICS", "badge from the MIME type")
        T.equal(AttachmentNames.fileExtension(forMIME: "application/pdf; name=x"), "pdf", "extension from a MIME type with parameters")
    }

    static func risky() {
        T.section("Rich mail: risky types and Quick Look")
        for name in ["Installer.dmg", "Tool.app", "run.sh", "build.command", "page.html", "logo.svg", "Profile.mobileconfig",
                     "plugin.jar", "setup.exe", "Driver.pkg", "go.webloc", "notes.py", "Action.workflow", "x.scpt", "lib.dylib"] {
            T.check(AttachmentNames.isRisky(name), "\(name) is risky")
        }
        for name in ["Launch plan.pdf", "Budget Q4.xlsx", "Moodboard.zip", "Caf\u{00E9} Nowhere menu.jpg", "Rehearsal.ics", "Lake house.heic"] {
            T.check(!AttachmentNames.isRisky(name), "\(name) is not risky")
        }
        T.check(AttachmentNames.isRisky("driver", mimeType: "application/x-apple-diskimage"), "a disk image without an extension is risky")
        T.check(AttachmentNames.isRisky("update", mimeType: "application/x-msdownload"), "a Windows program by MIME type is risky")
        T.check(AttachmentNames.isRisky(AttachmentNames.display(RichMailThreads.bidiName)), "the bidi spoof is caught as .exe")
        T.check(!AttachmentNames.isRisky("data", mimeType: "application/octet-stream"), "octet-stream alone isn't risky")
        T.check(AttachmentNames.opensInBrowser("page.HTM") && !AttachmentNames.opensInBrowser("plan.pdf"), "HTML family opens in the browser")
        for name in ["page.html", "logo.svg", "Fwd.eml", "link.webloc", "feed.xml", "Profile.mobileconfig", "saved.webarchive"] {
            T.check(!AttachmentNames.canQuickLook(name), "\(name) is Open/Save only")
        }
        T.check(!AttachmentNames.canQuickLook("message", mimeType: "message/rfc822"), "a forwarded message by type is Open/Save only")
        for name in ["Launch plan.pdf", "Budget Q4.xlsx", "Caf\u{00E9} Nowhere menu.jpg", "Installer.dmg"] {
            T.check(AttachmentNames.canQuickLook(name), "\(name) previews in Quick Look")
        }
        T.equal(AttachmentNames.riskyTitle("Installer.dmg"), "\u{201C}Installer.dmg\u{201D} can run code or change your Mac.", "risky title")
        T.equal(AttachmentNames.riskyMessage(sender: "Juniper Vale"), "Open it only if you expected it from Juniper Vale.", "risky message")
        T.equal(AttachmentNames.riskyMessage(sender: " "), "Open it only if you expected it.", "risky message without a sender")
    }

    static func kinds() {
        T.section("Rich mail: kinds, labels, previews")
        let kinds: [(String, String, String)] = [
            ("Launch plan.pdf", "", "PDF document"), ("Budget Q4.xlsx", "", "Excel spreadsheet"), ("Moodboard.zip", "", "ZIP archive"),
            ("menu.JPG", "", "JPEG image"), ("Rehearsal.ics", "", "Calendar invite"), ("Installer.dmg", "", "Disk image"),
            ("scan", "image/x-weird", "Image"), ("notes.abc", "", "ABC file"), ("blob", "", "Document"), ("Lake house.heic", "", "HEIC image"),
        ]
        for (name, mime, want) in kinds { T.equal(AttachmentNames.kindName(name, mimeType: mime), want, "kind of \(name)") }
        let list = RichMailThreads.attachmentList
        T.equal(AttachmentNames.summary(list), "8 attachments \u{00B7} 18 MB", "strip header")
        T.equal(AttachmentNames.summary([list[0]]), "1 attachment \u{00B7} 2.4 MB", "strip header, one file")
        T.equal(AttachmentNames.detail(list[0]), "PDF document \u{00B7} 2.4 MB", "chip detail line")
        T.equal(AttachmentNames.accessibilityLabel(list[5]), "Attachment, Installer.dmg, Disk image, 3.1 MB, can run code or change your Mac",
                "VoiceOver label of a risky file")
        T.equal(AttachmentNames.accessibilityLabel(list[0]), "Attachment, Launch plan.pdf, PDF document, 2.4 MB", "VoiceOver label")
        T.check(AttachmentNames.accessibilityLabel(A(name: "Archive.zip", bytes: 60_000_000, id: "9")).hasSuffix("too big to open here"),
                "VoiceOver says when a file is too big")
        T.equal(AttachmentNames.previewPlan(list).auto.map(\.id), ["5"], "the menu photo previews; no other file is an image")
        T.equal(AttachmentNames.previewPlan(RichMailThreads.inlineImageList.filter { !$0.isInline }).auto.map(\.name), ["Lake house.heic"],
                "the HEIC panorama previews")
        let photos = (1...8).map { A(name: "Dock \($0).jpg", bytes: 3_000_000, id: "\($0)", mimeType: "image/jpeg") }
            + [A(name: "Huge.png", bytes: 12_000_000, id: "9", mimeType: "image/png"), A(name: "Raw.jpg", bytes: 5, id: "", mimeType: "image/jpeg")]
        let plan = AttachmentNames.previewPlan(photos)
        T.equal(plan.auto.map(\.id), ["1", "2", "3", "4", "5", "6"], "at most 6 previews and 20 MB per message")
        T.equal(plan.deferred.map(\.id), ["7", "8", "9"], "the rest wait for Show image previews (over 10 MB included)")
    }

    // MARK: Files

    static func quarantineValue(_ url: URL) -> String? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, "com.apple.quarantine", &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    static func posix(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Tests/.out/attachment-files (kept after the run so `xattr -p com.apple.quarantine` can be read by hand).
    static var outFolder: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("attachment-files", isDirectory: true)
    }

    static func files() {
        T.section("Rich mail: saved files, quarantine")
        let fm = FileManager.default
        let root = outFolder
        try? fm.removeItem(at: root)
        let saves = root.appendingPathComponent("Saved", isDirectory: true)
        try? fm.createDirectory(at: saves, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("cache.bin")
        let bytes = Data("yayas-calendar fixture bytes\n".utf8) + Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        try? bytes.write(to: cache)

        let first = try? AttachmentFiles.save(cache, to: saves, name: "Launch plan.pdf")
        let second = try? AttachmentFiles.save(cache, to: saves, name: "Launch plan.pdf")
        T.equal(first?.lastPathComponent, "Launch plan.pdf", "Save keeps the display name")
        T.equal(second?.lastPathComponent, "Launch plan 2.pdf", "a second save picks the next free name (never overwrites)")
        T.check(second.flatMap { try? Data(contentsOf: $0) } == bytes, "the bytes are copied")
        T.equal(first.map(posix), 0o644, "saved files are 0644")
        let record = first.flatMap(quarantineValue)
        // "flags;time;agent;event": LaunchServices fills the agent from the running bundle (empty for this unbundled binary).
        T.check(record.map { $0.split(separator: ";", omittingEmptySubsequences: false).count == 4 } == true,
                "the file carries com.apple.quarantine (\(record ?? "none"))")
        T.check(record.map { !$0.contains("orbitalpickle") && !$0.contains("@") && !$0.contains("http") } == true,
                "no sender, address or URL in the quarantine record")
        if let first, let props = try? first.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties {
            T.equal(props[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeEmailAttachment as String, "quarantine type: email attachment")
            T.equal(props[kLSQuarantineAgentBundleIdentifierKey as String] as? String, Paths.bundleId, "quarantine agent bundle id")
        } else {
            T.check(false, "quarantine properties read back")
        }

        // Path traversal: the sanitized name stays inside the folder.
        let escaped = try? AttachmentFiles.save(cache, to: saves, name: "../../escape.txt")
        T.check(escaped.map { AttachmentFiles.isInside($0, saves) } == true && !fm.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.txt").path),
                "a traversal name lands inside the folder (\(escaped?.lastPathComponent ?? "-"))")
        T.check(!AttachmentFiles.isInside(saves.appendingPathComponent("../x"), saves) && AttachmentFiles.isInside(saves.appendingPathComponent("x"), saves),
                "the prefix check")
        // A symlink already at the destination: the next name, never through the link.
        let outside = root.appendingPathComponent("outside.jpg")
        try? fm.createSymbolicLink(at: saves.appendingPathComponent("Menu.jpg"), withDestinationURL: outside)
        let menu = try? AttachmentFiles.save(cache, to: saves, name: "Menu.jpg")
        T.check(menu?.lastPathComponent == "Menu 2.jpg" && !fm.fileExists(atPath: outside.path), "an existing symlink is skipped, never written through")
        // Save As replaces exactly what the panel chose (but never follows a symlink).
        if let second {
            try? AttachmentFiles.replace(cache, at: second)
            T.check(quarantineValue(second) != nil && (try? Data(contentsOf: second)) == bytes, "Save As replaces and quarantines")
        }

        // Open copies: Mail Downloads/<uuid>/<name>, 0700/0600, quarantined; swept after 24 h.
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        let opened = try? AttachmentFiles.openCopy(cache, name: "Installer.dmg", root: dataRoot)
        T.check(opened?.path.contains("/data/Mail Downloads/") == true && opened?.lastPathComponent == "Installer.dmg", "Open copies go to Mail Downloads")
        T.equal(opened.map(posix), 0o600, "Open copies are 0600")
        T.equal(opened.map { posix($0.deletingLastPathComponent()) }, 0o700, "their folder is 0700")
        T.equal(posix(AttachmentFiles.downloads(root: dataRoot)), 0o700, "Mail Downloads is 0700")
        T.check(opened.flatMap(quarantineValue) != nil, "Open copies are quarantined")
        let fresh = try? AttachmentFiles.openCopy(cache, name: "Launch plan.pdf", root: dataRoot)
        if let old = opened?.deletingLastPathComponent() {
            let past = Date().addingTimeInterval(-25 * 3600)
            try? fm.setAttributes([.creationDate: past, .modificationDate: past], ofItemAtPath: old.path)
        }
        T.equal(AttachmentFiles.sweepDownloads(root: dataRoot), 1, "the launch sweep removes Open copies older than 24 h")
        T.check(fresh.map { fm.fileExists(atPath: $0.path) } == true && opened.map { !fm.fileExists(atPath: $0.path) } == true,
                "newer copies stay")
        let longName = String(repeating: "Orbital ", count: 40) + "plan.pdf"
        let dest = AttachmentFiles.destination(in: saves, name: longName)
        T.check(dest.map { $0.lastPathComponent.utf8.count <= 255 && $0.pathExtension == "pdf" } == true, "destinations stay within 255 bytes")
    }

    static func saveFolder() {
        T.section("Rich mail: save folder")
        let downloads = URL(fileURLWithPath: "/tmp/yc-test-downloads", isDirectory: true)
        let none = AttachmentSaveFolder.resolve(stored: "", downloads: downloads, usable: { _ in true })
        T.check(none.isDownloads && none.url == downloads && none.note == nil && none.title == "Downloads", "\"\" = Downloads")
        let chosen = AttachmentSaveFolder.resolve(stored: "/Volumes/Archive/Invoices", downloads: downloads, usable: { _ in true })
        T.check(!chosen.isDownloads && chosen.url.path == "/Volumes/Archive/Invoices" && chosen.title == "Invoices", "a chosen folder")
        let gone = AttachmentSaveFolder.resolve(stored: "/Volumes/Archive/Invoices", downloads: downloads, usable: { _ in false })
        T.check(gone.isDownloads && gone.note == "\u{201C}Invoices\u{201D} is missing or can\u{2019}t be written to, so files go to Downloads.",
                "a missing or unwritable folder falls back to Downloads with a note")
        let local = MemoryMailLocalStore()
        T.check(AttachmentSaveFolder.resolve(local).isDownloads, "no setting = Downloads")
        T.equal(AttachmentSaveFolder.key, "mail.attachments.saveFolder", "the key")
        T.equal(AttachmentSaveFolder.shown(Paths.realHome.appendingPathComponent("Documents/Invoices")), "~/Documents/Invoices", "shown with ~")
        T.check(AttachmentSaveFolder.isUsable(outFolder) && !AttachmentSaveFolder.isUsable(outFolder.appendingPathComponent("nope")),
                "usable = an existing, writable folder")
    }
}
