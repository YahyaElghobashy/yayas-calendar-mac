import CryptoKit
import Foundation

/// The attachment cache (rich mail, D-043): Gmail attachment bytes as local files under
/// `<data root>/attachments` (folder 0700, files 0600), indexed by `attachment_cache` (a quiet table: no widget
/// generation moves). Files are named by a hash of account, message and Gmail part id, never by the sender's
/// filename. Least recently opened files go past the limit (300 MB). Lives in Sources/Sync, which the widget
/// extension never compiles, and the folder is outside `widget/`, so the appex can't reach it.
///
/// Fetching: the part's attachment id comes from the body cache (`CachedMessage`). Gmail changes attachment ids
/// between fetches, so a 400/404 re-fetches the thread once and retries with the new id. Concurrent requests
/// for one part share one download. Over 50 MB is refused before any request.
final class LocalAttachmentStore: MailAttachmentStore, MailInlinePrefetching, @unchecked Sendable {
    /// Gmail accepts messages up to 50 MB; nothing bigger is fetched.
    static let maxBytes = 50 << 20

    static let tooBig = ServiceError(description: "This one is too big to open here.")
    static let gone = ServiceError(description: "Gmail no longer has that attachment.")
    static let notFetchable = ServiceError(description: "That attachment can\u{2019}t be downloaded.")
    static let offline = ServiceError(description: "You\u{2019}re offline, and this attachment isn\u{2019}t saved yet.")
    static let failed = ServiceError(description: "I couldn\u{2019}t download that attachment. Try again in a moment.")
    static let notReady = ServiceError(description: "That account isn\u{2019}t ready yet.")

    struct Key: Hashable, Sendable {
        var accountId: UUID
        var messageId: String
        var partId: String
        var id: String { "\(accountId.uuidString)\u{1F}\(messageId)\u{1F}\(partId)" }
    }

    let db: AppDatabase
    let directory: URL
    /// Bytes kept on disk before the least recently opened files go.
    var limit: Int
    let now: @Sendable () -> Date
    /// The body cache (attachment ids, sizes, types) and the thread refresh for stale ids.
    weak var mail: LocalMailStore?
    /// Per-account Gmail clients (the engine's token + quota bucket).
    var client: (@Sendable (UUID) async -> GmailClient?)?
    private let flights = AttachmentFlights()

    init(db: AppDatabase, directory: URL, limit: Int = 300 << 20, now: @escaping @Sendable () -> Date) {
        self.db = db
        self.directory = directory
        self.limit = limit
        self.now = now
    }

    private var repo: AttachmentCacheRepo { AttachmentCacheRepo(db: db) }

    /// `sha256("att" ␟ account ␟ message ␟ part)` in hex + ".bin": no sender text ever reaches a path.
    static func fileName(_ key: Key) -> String {
        let digest = SHA256.hash(data: Data("att\u{1F}\(key.id)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".bin"
    }

    // MARK: MailAttachmentStore

    func file(threadR: String, messageId: String, partId: String) async throws -> URL {
        guard !partId.isEmpty, !messageId.isEmpty else { throw Self.notFetchable }
        guard let row = try MailRepo(db: db).thread(r: threadR) else { throw LocalMailStore.notFound }
        let key = Key(accountId: row.accountId, messageId: messageId, partId: partId)
        if let url = hit(key) { return url }
        return try await flights.run(key.id) { [self] in
            if let url = hit(key) { return url }
            return try await fetch(threadR: threadR, key: key, known: nil)
        }
    }

    func cachedFile(threadR: String, messageId: String, partId: String) -> URL? {
        guard !partId.isEmpty, let row = try? MailRepo(db: db).thread(r: threadR) else { return nil }
        return hit(Key(accountId: row.accountId, messageId: messageId, partId: partId))
    }

    func usage() -> (files: Int, bytes: Int) {
        ((try? repo.files().count) ?? 0, (try? repo.bytes()) ?? 0)
    }

    /// Settings → Mail "Clear": every row and every file in the folder.
    func clear() throws {
        try repo.deleteAll()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }

    // MARK: MailInlinePrefetching

    func store(accountId: UUID, threadR: String, messageId: String, partId: String, mimeType: String, data: Data) async throws {
        guard !partId.isEmpty, data.count <= Self.maxBytes else { return }
        let key = Key(accountId: accountId, messageId: messageId, partId: partId)
        guard hit(key, touch: false) == nil else { return }
        _ = try write(key, data: data, mimeType: mimeType)
    }

    func fetch(accountId: UUID, threadR: String, messageId: String, partId: String, attachmentId: String, mimeType: String) async throws {
        let key = Key(accountId: accountId, messageId: messageId, partId: partId)
        guard hit(key, touch: false) == nil else { return }
        _ = try await flights.run(key.id) { [self] in
            if let url = hit(key, touch: false) { return url }
            return try await fetch(threadR: threadR, key: key, known: Meta(attachmentId: attachmentId, bytes: 0, mimeType: mimeType))
        }
    }

    // MARK: Fetch

    struct Meta: Equatable {
        var attachmentId: String?
        var bytes: Int
        var mimeType: String
    }

    /// The part as the body cache knows it (attachment id, size, type).
    private func lookup(_ key: Key) -> Meta? {
        guard let message = mail?.cachedMessage(accountId: key.accountId, messageId: key.messageId),
              let part = message.attachments.first(where: { $0.partId == key.partId }) else { return nil }
        return Meta(attachmentId: part.attachmentId, bytes: part.bytes, mimeType: part.mimeType)
    }

    private func refresh(_ threadR: String) async throws {
        guard let mail else { throw Self.failed }
        do {
            try await mail.refreshThread(r: threadR)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw Self.friendly(error)
        }
    }

    private func fetch(threadR: String, key: Key, known: Meta?) async throws -> URL {
        var meta = known ?? lookup(key)
        var refreshed = false
        if meta?.attachmentId?.isEmpty ?? true {
            try await refresh(threadR)
            refreshed = true
            meta = lookup(key)
        }
        guard var m = meta, let first = m.attachmentId, !first.isEmpty else { throw Self.gone }
        guard m.bytes <= Self.maxBytes else { throw Self.tooBig }
        guard let client = await client?(key.accountId) else { throw Self.notReady }
        var data: Data
        do {
            data = try await client.attachment(messageId: key.messageId, id: first, expected: m.bytes)
        } catch let error as GoogleAPIError where Self.isStale(error) {
            guard !refreshed else { throw Self.gone }
            try await refresh(threadR)
            guard let again = lookup(key), let id = again.attachmentId, !id.isEmpty else { throw Self.gone }
            guard again.bytes <= Self.maxBytes else { throw Self.tooBig }
            m = again
            do {
                data = try await client.attachment(messageId: key.messageId, id: id, expected: again.bytes)
            } catch let error as GoogleAPIError where Self.isStale(error) {
                throw Self.gone
            } catch {
                throw Self.friendly(error)
            }
        } catch {
            throw Self.friendly(error)
        }
        guard data.count <= Self.maxBytes else { throw Self.tooBig }
        return try write(key, data: data, mimeType: m.mimeType.isEmpty ? "application/octet-stream" : m.mimeType)
    }

    /// Gmail answers 400 or 404 for an attachment id it no longer recognises.
    static func isStale(_ error: GoogleAPIError) -> Bool {
        switch error {
        case .notFound, .badRequest: return true
        default: return false
        }
    }

    static func friendly(_ error: Error) -> Error {
        if error is CancellationError || error is ServiceError { return error }
        if let api = error as? GoogleAPIError, api == .offline { return offline }
        return failed
    }

    // MARK: Files

    /// The cached file for `key` (its access time bumped), or nil. A row whose file is gone is dropped.
    private func hit(_ key: Key, touch: Bool = true) -> URL? {
        guard let entry = try? repo.get(accountId: key.accountId, messageId: key.messageId, partId: key.partId) else { return nil }
        let url = directory.appendingPathComponent(entry.file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? repo.delete(accountId: key.accountId, messageId: key.messageId, partId: key.partId)
            return nil
        }
        if touch { try? repo.touch(accountId: key.accountId, messageId: key.messageId, partId: key.partId, at: now()) }
        return url
    }

    private func ensureFolder() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Atomic write (0600), then the row, then the LRU trim (never the file just written).
    private func write(_ key: Key, data: Data, mimeType: String) throws -> URL {
        try ensureFolder()
        let name = Self.fileName(key)
        let url = directory.appendingPathComponent(name)
        try SnapshotPublisher.atomicWrite(data, to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try repo.put(AttachmentCacheEntry(accountId: key.accountId, messageId: key.messageId, partId: key.partId, file: name,
                                          bytes: data.count, mimeType: mimeType, sha256: sha, accessedAt: now()))
        trim(keeping: name)
        return url
    }

    /// Least recently opened files go until the cache is within `limit`.
    @discardableResult
    func trim(keeping kept: String? = nil) -> Int {
        let repo = self.repo
        var total = (try? repo.bytes()) ?? 0
        var removed = 0
        while total > limit {
            let batch = ((try? repo.oldest(limit: 51)) ?? []).filter { $0.file != kept }
            guard !batch.isEmpty else { break }
            for entry in batch where total > limit {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.file))
                try? repo.delete(accountId: entry.accountId, messageId: entry.messageId, partId: entry.partId)
                total -= entry.bytes
                removed += 1
            }
        }
        return removed
    }

    /// Files no row points at (their account was removed: the rows cascaded), and rows whose file is missing.
    /// Temporary files of a write in progress (younger than 10 minutes) are left alone.
    @discardableResult
    func sweepOrphans() -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let known = (try? repo.files()) ?? []
        var removed = 0
        let recent = now().addingTimeInterval(-600)
        for name in names where !known.contains(name) {
            let url = directory.appendingPathComponent(name)
            if name.hasPrefix("."), let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified > recent { continue }
            try? fm.removeItem(at: url)
            removed += 1
        }
        let present = Set(names)
        for entry in (try? repo.oldest(limit: 1_000_000)) ?? [] where !present.contains(entry.file) {
            try? repo.delete(accountId: entry.accountId, messageId: entry.messageId, partId: entry.partId)
        }
        return removed
    }
}

/// One download per part: concurrent requests for the same key await the same task.
actor AttachmentFlights {
    private var running: [String: Task<URL, Error>] = [:]

    func run(_ key: String, _ work: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let task = running[key] { return try await task.value }
        let task = Task { try await work() }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }
}
