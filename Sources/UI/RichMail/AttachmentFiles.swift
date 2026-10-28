import CoreServices
import Foundation

/// Files handed to the user (rich mail, D-043): Save, Save All, Open copies and file
/// promises. Every copy gets the sanitized display name, lands strictly inside its folder (never overwriting: the
/// next free name, "Report 2.pdf"; an existing symlink counts as taken), and carries a quarantine record so
/// Gatekeeper still checks it. The record names this app only: no sender, URL or address (privacy). Foundation
/// only, so the shell tests save real files and read the attribute back.
enum AttachmentFiles {
    static let agentName = "Yaya\u{2019}s Calendar"
    /// Open copies: `<data root>/Mail Downloads/<uuid>/<name>` (folders 0700, files 0600), gone after 24 h.
    static let downloadsFolderName = "Mail Downloads"
    static let downloadsMaxAge: TimeInterval = 24 * 3600

    static let leftFolder = ServiceError(description: "That name can\u{2019}t be saved there.")
    static let notSaved = ServiceError(description: "I couldn\u{2019}t save that file. Try Save As\u{2026} instead.")

    // MARK: Quarantine

    static func quarantineProperties(bundleId: String = Paths.bundleId, now: Date = Date()) -> [String: Any] {
        [kLSQuarantineAgentNameKey as String: agentName,
         kLSQuarantineAgentBundleIdentifierKey as String: bundleId,
         kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
         kLSQuarantineTimeStampKey as String: now]
    }

    static func quarantine(_ url: URL, bundleId: String = Paths.bundleId, now: Date = Date()) throws {
        var values = URLResourceValues()
        values.quarantineProperties = quarantineProperties(bundleId: bundleId, now: now)
        var target = url
        try target.setResourceValues(values)
    }

    // MARK: Destinations

    /// Anything at that path, a dangling symlink included.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// `url` is strictly inside `folder`: both compared as canonical paths (`.` and `..` removed, symlinks resolved on the
    /// part that exists). The last component of `url` is not followed: an existing symlink there is the caller's to
    /// skip. (Foundation drops a leading "/private" only from paths that exist, so plain standardized paths disagree for
    /// a new file in a folder under /private/tmp or /private/var.)
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let target = url.standardizedFileURL
        let name = target.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", target.path != "/" else { return false }
        let root = canonicalPath(folder)
        let parent = canonicalPath(target.deletingLastPathComponent())
        let path = parent.hasSuffix("/") ? parent + name : parent + "/" + name
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The absolute path with `.` and `..` removed and symlinks resolved as far as the path exists (realpath on its
    /// deepest existing folder, the rest appended).
    static func canonicalPath(_ url: URL) -> String {
        func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var existing = url.standardizedFileURL
        var rest: [String] = []
        var path = real(existing.path)
        while path == nil, existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
            path = real(existing.path)
        }
        var out = path ?? existing.path
        for component in rest { out = out.hasSuffix("/") ? out + component : out + "/" + component }
        return out
    }

    /// The first free name for `name` in `folder`: "Report.pdf", "Report 2.pdf", "Report 3.pdf"… Nil when the
    /// sanitized name would still leave the folder (it can't, but the check stays).
    static func destination(in folder: URL, name: String, mimeType: String = "") -> URL? {
        let safe = AttachmentNames.display(name, mimeType: mimeType)
        let ext = (safe as NSString).pathExtension
        let base = ext.isEmpty ? safe : (safe as NSString).deletingPathExtension
        for n in 1...9_999 {
            var candidate = n == 1 ? safe : (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            candidate = AttachmentNames.capped(candidate, bytes: 255)
            let url = folder.appendingPathComponent(candidate, isDirectory: false)
            guard isInside(url, folder) else { return nil }
            if !exists(url) { return url }
        }
        return nil
    }

    // MARK: Copies

    /// Copies `source` (a cache file) into `folder` as `name` (the next free name, never overwriting), sets
    /// `permissions` and quarantines it. Returns where it went.
    @discardableResult
    static func save(_ source: URL, to folder: URL, name: String, mimeType: String = "", permissions: Int = 0o644,
                     bundleId: String = Paths.bundleId, now: Date = Date()) throws -> URL {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        for _ in 0..<8 {
            guard let url = destination(in: folder, name: name, mimeType: mimeType) else { throw leftFolder }
            do {
                try data.write(to: url, options: .withoutOverwriting)
            } catch {
                if exists(url) { continue }      // someone took the name meanwhile: the next one
                throw error
            }
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            try quarantine(url, bundleId: bundleId, now: now)
            return url
        }
        throw notSaved
    }

    /// Writes to exactly `url` (Save As: the panel already asked about replacing), quarantined.
    static func replace(_ source: URL, at url: URL, bundleId: String = Paths.bundleId, now: Date = Date()) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            // Never write through a symlink; a regular file the user chose to replace goes first.
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .withoutOverwriting)
        try quarantine(url, bundleId: bundleId, now: now)
    }

    static func downloads(root: URL) -> URL { root.appendingPathComponent(downloadsFolderName, isDirectory: true) }

    /// The copy Open hands to another app: its own new folder under Mail Downloads, 0600, quarantined.
    static func openCopy(_ source: URL, name: String, mimeType: String = "", root: URL = Paths.root,
                         bundleId: String = Paths.bundleId, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let parent = downloads(root: root)
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        return try save(source, to: folder, name: name, mimeType: mimeType, permissions: 0o600, bundleId: bundleId, now: now)
    }

    /// Launch: Open copies older than 24 h go. Returns how many folders were removed.
    @discardableResult
    static func sweepDownloads(root: URL = Paths.root, now: Date = Date(), maxAge: TimeInterval = downloadsMaxAge) -> Int {
        let fm = FileManager.default
        let parent = downloads(root: root)
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return 0 }
        var removed = 0
        for name in names {
            let url = parent.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let stamp = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(stamp) > maxAge, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

/// Settings → Mail "Save attachments to" (`mail.attachments.saveFolder`, "" = Downloads; D-043): the folder
/// Save and Save All use. A missing or unwritable folder falls back to Downloads with a note.
struct AttachmentSaveFolder: Equatable {
    static let key = "mail.attachments.saveFolder"

    var url: URL
    var isDownloads: Bool
    /// Why the chosen folder isn't used, else nil.
    var note: String?

    /// What a toast or Settings calls it: "Downloads", or the folder's name.
    var title: String { isDownloads ? "Downloads" : url.lastPathComponent }

    static var downloads: URL { Paths.realHome.appendingPathComponent("Downloads", isDirectory: true) }

    static func resolve(stored: String?, downloads: URL = AttachmentSaveFolder.downloads,
                        usable: (URL) -> Bool = AttachmentSaveFolder.isUsable) -> AttachmentSaveFolder {
        let path = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return AttachmentSaveFolder(url: downloads, isDownloads: true, note: nil) }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        if url.path == downloads.standardizedFileURL.path { return AttachmentSaveFolder(url: downloads, isDownloads: true, note: nil) }
        if usable(url) { return AttachmentSaveFolder(url: url, isDownloads: false, note: nil) }
        return AttachmentSaveFolder(url: downloads, isDownloads: true,
                                    note: "\u{201C}\(url.lastPathComponent)\u{201D} is missing or can\u{2019}t be written to, so files go to Downloads.")
    }

    static func resolve(_ local: MailLocalStore) -> AttachmentSaveFolder { resolve(stored: local.string(key)) }

    /// Exists, is a folder, and can be written to.
    static func isUsable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// "~/Documents/Invoices" for Settings (home abbreviated).
    static func shown(_ url: URL) -> String {
        let home = Paths.realHome.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
