import CryptoKit
import Foundation

/// Queued sends too big for the action row (rich mail, D-044): the raw MIME of a send over 64 KB,
/// or with files or inline images, lives in `<data root>/outbox/<action-id>.eml` (folder 0700, file 0600), written
/// before the row exists. The row's payload holds only the file name (`rawFile`, checked against a strict pattern, never
/// a path), its size and its SHA-256. The file goes when the send is delivered or cancelled; a failed send keeps it until
/// its row is purged (7 days), and anything no pending, running or failed send points at is swept at launch.
final class OutboxStore: @unchecked Sendable {
    /// `<UUID>.eml`, uppercase as `UUID().uuidString` writes it.
    static let namePattern = "^[0-9A-F-]{36}\\.eml$"
    /// Raw MIME at most this big, without files or inline images, stays in the row (`payload["raw"]`) as before.
    static let inlineLimit = 64 << 10

    static let unreadable = "That message couldn\u{2019}t be read back."
    static let outOfSpace = ServiceError(description: "Your Mac is out of space, so I couldn\u{2019}t queue this.")
    static let notQueued = ServiceError(description: "I couldn\u{2019}t get that message ready to send. Nothing was sent.")

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: namePattern, options: .regularExpression) != nil
    }

    static func fileName(actionId: String) -> String { actionId.uppercased() + ".eml" }

    /// The file for a payload's `rawFile`, or nil when the name isn't one of ours (never a path).
    func url(_ name: String) -> URL? {
        guard Self.isValidName(name) else { return nil }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// The folder exists (0700).
    func prepare() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// The bytes of a queued send, checked against the SHA-256 the row recorded. The hash is mandatory: a row without
    /// one (or with an empty one) is unreadable. Throws for a bad name, a missing hash or file, or a mismatch.
    func read(_ name: String, sha256: String?) throws -> Data {
        guard let url = url(name), let sha256, !sha256.isEmpty else { throw ServiceError(description: Self.unreadable) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Self.sha256(data) == sha256.lowercased() else { throw ServiceError(description: Self.unreadable) }
        return data
    }

    func delete(_ name: String?) {
        guard let name, let url = url(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every file in the folder that isn't in `keeping` (stray files, sends that finished or were purged).
    @discardableResult
    func sweep(keeping: Set<String>) -> Int {
        sweep(files(), keeping: keeping)
    }

    /// Deletes those of `names` (a listing taken earlier) that aren't in `keeping`.
    @discardableResult
    func sweep(_ names: Set<String>, keeping: Set<String>) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in names where !keeping.contains(name) && !name.isEmpty && !name.contains("/") && name != "." && name != ".." {
            if (try? fm.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// The scratch file a big send's upload body is written to while it uploads: `<action-id>.upload`, next to its
    /// message (so a crash mid-upload leaves it to the launch sweep, not in the system temp folder).
    func uploadFile(actionId: String) -> URL {
        directory.appendingPathComponent(actionId.uppercased() + ".upload", isDirectory: false)
    }

    func files() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a file, read in 1 MB chunks.
    static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A write that failed because the disk is full.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}
