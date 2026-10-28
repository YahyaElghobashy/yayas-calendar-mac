import Foundation

/// A message as the body cache stores it: parsed, sanitized with remote images allowed (blocking them
/// again is a second sanitizer pass at read time). v2 (rich mail, D-040): attachment and inline-image
/// metadata (Gmail part ids, types, Content-IDs) and the text part's format=flowed. Quote markers and the
/// plain-text HTML are made at read time, never cached (the sanitizer strips `yc-` markers on a re-pass).
struct CachedMessage: Codable, Equatable {
    struct Attachment: Codable, Equatable {
        var name: String
        var bytes: Int
        /// Gmail part id; "" = can't be fetched (raw parses).
        var partId: String
        /// The last attachment id Gmail gave (it changes per fetch; only for requesting the bytes).
        var attachmentId: String?
        var mimeType: String
        var contentId: String?
        /// Drawn in the body through cid: (not a chip).
        var isInline: Bool
    }
    static let version = 2
    var v = CachedMessage.version
    var id: String
    var from: String
    var fromEmail: String
    var to: [String]
    var cc: [String]
    var date: Date
    var subject: String
    var html: String?
    var text: String
    var hasRemoteImages: Bool
    /// Files, then images sent inline that the HTML doesn't draw (chips), then the drawn inline images.
    var attachments: [Attachment]
    var flowed: Bool
    var delsp: Bool

    /// Gmail `format=full` message → parsed, sanitized cache entry.
    static func from(_ message: GMessage) -> CachedMessage { parsed(message).message }

    /// …plus the inline images the body draws, with their bytes when Gmail sent them (prefetch).
    static func parsed(_ message: GMessage) -> (message: CachedMessage, inline: [MIMEParser.PartRef]) {
        let part = message.payload.map { MIMEParser.fromGmail($0) } ?? MIMEPart()
        let extracted = MIMEParser.extract(part)
        let cids = Set(extracted.inline.compactMap { $0.contentId })
        let sanitized = extracted.html.map { HTMLSanitizer.sanitize($0, remote: .allow, cids: cids) }
        let drawn = sanitized.map { referencedCIDs($0.html) } ?? []
        var attachments = extracted.files.map { Attachment($0, isInline: false) }
        var inline: [Attachment] = []
        var drawnParts: [MIMEParser.PartRef] = []
        for ref in extracted.inline {
            if let id = ref.contentId.flatMap(MailCID.normalize), drawn.contains(id) {
                inline.append(Attachment(ref, isInline: true))
                drawnParts.append(ref)
            } else {
                // Sent inline but never drawn (an iPhone photo in a plain message): a chip, never lost.
                var chip = ref
                if chip.name.isEmpty { chip.name = imageName(ref.mimeType) }
                attachments.append(Attachment(chip, isInline: false))
            }
        }
        let from = part.header("From").flatMap { MailAddress.parseList($0).first }
        let date = message.date ?? part.header("Date").flatMap(MailDate.parse) ?? Date(timeIntervalSince1970: 0)
        let cached = CachedMessage(
            id: message.id, from: from?.name.isEmpty == false ? from!.name : (from?.email ?? ""), fromEmail: from?.email ?? "",
            to: MailAddress.parseList(part.header("To") ?? "").map(\.display),
            cc: MailAddress.parseList(part.header("Cc") ?? "").map(\.display), date: date,
            subject: EncodedWord.decode(part.header("Subject") ?? ""),
            html: sanitized?.html, text: extracted.text.replacingOccurrences(of: "\r\n", with: "\n"),
            hasRemoteImages: sanitized?.hasRemoteImages ?? false,
            attachments: attachments + inline, flowed: extracted.flowed, delsp: extracted.delsp)
        return (cached, drawnParts)
    }

    /// Normalized ids of every `<img src="cid:…">` the sanitizer kept.
    static func referencedCIDs(_ html: String) -> Set<String> {
        var out = Set<String>()
        var rest = Substring(html)
        while let r = rest.range(of: "src=\"cid:") {
            let tail = rest[r.upperBound...]
            let end = tail.firstIndex(of: "\"") ?? tail.endIndex
            if let id = MailCID.normalize(String(tail[..<end])) { out.insert(id) }
            rest = tail[end...]
        }
        return out
    }

    /// A name for a nameless inline image that becomes a chip: "Image.png".
    static func imageName(_ mimeType: String) -> String {
        let sub = mimeType.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        let ext = ["jpeg": "jpg", "pjpeg": "jpg", "svg+xml": "svg", "x-icon": "ico"][sub] ?? (sub.isEmpty ? "bin" : sub)
        return "Image." + ext
    }

    func message(blockRemote: Bool) -> MailMessage {
        let inlineIds = Set(attachments.filter(\.isInline).compactMap(\.contentId))
        var shown: String?
        var plain = false
        if let html {
            var page = html
            if blockRemote, hasRemoteImages { page = HTMLSanitizer.sanitize(html, remote: .block, cids: inlineIds).html }
            shown = MailQuote.mark(page).html
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shown = MailPlainText.html(text, flowed: flowed, delsp: delsp)
            plain = true
        }
        return MailMessage(id: id, from: from, fromEmail: fromEmail, to: to, cc: cc, date: date, subject: subject, html: shown,
                           text: text, hasRemoteImages: hasRemoteImages,
                           attachments: attachments.map {
                               MailMessage.Attachment(name: $0.name, bytes: $0.bytes, id: $0.partId, mimeType: $0.mimeType,
                                                      contentId: $0.contentId, isInline: $0.isInline)
                           },
                           isPlainText: plain)
    }
}

extension CachedMessage.Attachment {
    init(_ ref: MIMEParser.PartRef, isInline: Bool) {
        self.init(name: ref.name, bytes: ref.bytes, partId: ref.partId ?? "", attachmentId: ref.attachmentId, mimeType: ref.mimeType,
                  contentId: ref.contentId, isInline: isInline)
    }
}

/// Where inline (cid:) images go when a thread is fetched. The attachment store implements it
/// (`LocalAttachmentStore`, keyed by account, message and Gmail part id). Nil on the mail store = no
/// prefetch: the reader's `cid` scheme handler then loads each image on demand.
protocol MailInlinePrefetching: AnyObject, Sendable {
    /// Bytes that arrived with the message go straight into the cache (no request).
    func store(accountId: UUID, threadR: String, messageId: String, partId: String, mimeType: String, data: Data) async throws
    /// One part fetched into the cache (`messages.attachments.get`, 20 quota units).
    func fetch(accountId: UUID, threadR: String, messageId: String, partId: String, attachmentId: String, mimeType: String) async throws
}

/// Which inline images to fetch when a thread opens: the newest message's drawn images that came without
/// bytes, at most 8 parts and 8 MB, 4 at a time (8 parts = 160 quota units, under the 200-unit burst).
enum InlinePrefetch {
    static let maxParts = 8
    static let maxBytes = 8 << 20
    static let concurrency = 4

    struct Job: Equatable, Sendable {
        var messageId: String
        var partId: String
        var attachmentId: String
        var mimeType: String
        var bytes: Int
    }

    /// Raster images (and HEIC): what the reader's scheme handler will serve.
    static func isImage(_ mimeType: String) -> Bool { MailCID.isImageType(mimeType) }

    static func plan(messageId: String, parts: [MIMEParser.PartRef]) -> [Job] {
        var jobs: [Job] = []
        var total = 0
        for p in parts where p.data == nil && isImage(p.mimeType) {
            guard jobs.count < maxParts else { break }
            guard let partId = p.partId, !partId.isEmpty, let attachmentId = p.attachmentId, !attachmentId.isEmpty,
                  total + p.bytes <= maxBytes else { continue }
            total += p.bytes
            jobs.append(Job(messageId: messageId, partId: partId, attachmentId: attachmentId, mimeType: p.mimeType, bytes: p.bytes))
        }
        return jobs
    }

    /// Runs `work` for every job, never more than `limit` at once; returns when all are done.
    static func run(_ jobs: [Job], limit: Int = concurrency, _ work: @escaping @Sendable (Job) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(limit, jobs.count) {
                let job = jobs[next]
                group.addTask { await work(job) }
                next += 1
            }
            while await group.next() != nil {
                guard next < jobs.count else { continue }
                let job = jobs[next]
                group.addTask { await work(job) }
                next += 1
            }
        }
    }
}

/// `MailStore` + `MailPreferencesStore` over the local database (docs/CONTRACTS.md "App seam").
/// Thread lists and counts are SQLite reads; message bodies are fetched on demand
/// (`threads.get?format=full`), parsed, sanitized and cached under `<store folder>/mailcache`
/// (files 0600, folder 0700, least recently read trimmed past 100 MB).
final class LocalMailStore: MailStore, MailPreferencesStore, @unchecked Sendable {
    let db: AppDatabase
    let cacheDirectory: URL
    var cacheLimit: Int
    let now: @Sendable () -> Date
    /// The engine hands out per-account Gmail clients (token + quota bucket).
    var client: (@Sendable (UUID) async -> GmailClient?)?
    /// Primary-only changed for an account: the engine resyncs it.
    var prefsChanged: (@Sendable (UUID) -> Void)?
    /// Inline images of freshly fetched threads; nil = loaded on demand by the reader.
    var inlinePrefetch: MailInlinePrefetching?
    /// Settings → Mail "Images from people you've written to" (`mail.images.fromCorrespondents`, off by default).
    var imagesFromCorrespondents: @Sendable () -> Bool = { false }

    init(db: AppDatabase, cacheDirectory: URL, cacheLimit: Int = 100 << 20, now: @escaping @Sendable () -> Date) {
        self.db = db
        self.cacheDirectory = cacheDirectory
        self.cacheLimit = cacheLimit
        self.now = now
    }

    static let notFound = ServiceError(description: "That conversation isn\u{2019}t in your inbox anymore.")

    // MARK: MailStore

    /// Mail-on accounts in the user's order. `requested` nil = those also marked "Include in All".
    func mailAccounts(_ requested: Set<UUID>?) throws -> [AccountRecord] {
        let all = try AccountRepo(db: db).all().filter { $0.mailEnabled && $0.provider == Provider.google.rawValue }
        guard let requested else { return all.filter(\.includeInAll) }
        return all.filter { requested.contains($0.id) }
    }

    func threads(accounts: Set<UUID>?, limit: Int) throws -> [MailThread] {
        let ids = try mailAccounts(accounts).map(\.id)
        return try MailRepo(db: db).inbox(accountIds: ids, limit: max(0, min(limit, 1000))).map(Self.thread)
    }

    func thread(r: String) throws -> MailThread? {
        try MailRepo(db: db).thread(r: r).map(Self.thread)
    }

    static func thread(_ t: MailThreadRecord) -> MailThread {
        MailThread(r: t.r, accountId: t.accountId, sender: t.senderName.isEmpty ? t.senderEmail : t.senderName,
                   senderEmail: t.senderEmail, subject: t.subject, snippet: t.snippet, at: t.lastAt, unread: t.unread,
                   starred: t.starred, messageCount: t.messageCount)
    }

    /// Whole-inbox accounts: Gmail's INBOX threadsUnread (adjusted optimistically between syncs);
    /// Primary-only accounts: their cached unread inbox rows.
    func unreadCount(accounts: Set<UUID>?) throws -> Int {
        let repo = MailRepo(db: db)
        var total = 0
        for account in try mailAccounts(accounts) {
            let prefs = MailDefaults.prefs(db: db, accountId: account.id)
            if !prefs.primaryOnly, let fromLabel = try repo.state(accountId: account.id).unreadInbox {
                total += fromLabel
            } else {
                total += try repo.counts(accountId: account.id).unread
            }
        }
        return total
    }

    func messages(threadR: String) async throws -> [MailMessage] {
        try await messages(threadR: threadR, loadImages: false)
    }

    /// `loadImages` = the reader's one-off "Load images"; otherwise remote images load only for senders
    /// on the allow list.
    func messages(threadR: String, loadImages: Bool) async throws -> [MailMessage] {
        let repo = MailRepo(db: db)
        guard let row = try repo.thread(r: threadR) else { throw Self.notFound }
        let cached = try await cachedMessages(row)
        return cached.map { message in
            let allowed = loadImages || allowsImages(from: message.fromEmail, accountId: row.accountId)
            return message.message(blockRemote: !allowed)
        }
    }

    private func cachedMessages(_ row: MailThreadRecord) async throws -> [CachedMessage] {
        let repo = MailRepo(db: db)
        if !row.messageIds.isEmpty {
            var found: [CachedMessage] = []
            for id in row.messageIds {
                guard let entry = try repo.cacheEntry(accountId: row.accountId, messageId: id),
                      let message = readCache(entry.file) else { break }
                found.append(message)
            }
            if found.count == row.messageIds.count {
                let at = now()
                for id in row.messageIds { try? repo.touchCache(accountId: row.accountId, messageId: id, at: at) }
                return found
            }
        }
        return try await fetchThread(row, prefetch: true)
    }

    /// `threads.get?format=full` → parsed, sanitized, written to the body cache (and the thread row's message ids).
    /// `prefetch`: hand the newest message's inline images to `inlinePrefetch` before returning.
    private func fetchThread(_ row: MailThreadRecord, prefetch: Bool) async throws -> [CachedMessage] {
        let repo = MailRepo(db: db)
        guard let client = await client?(row.accountId) else {
            throw ServiceError(description: "That account isn\u{2019}t ready yet.")
        }
        let thread: GThread
        do {
            thread = try await client.threadFull(row.threadId)
        } catch GoogleAPIError.notFound {
            throw Self.notFound
        } catch let error as GoogleAPIError where error == .offline {
            throw ServiceError(description: "You\u{2019}re offline, and this conversation isn\u{2019}t saved yet.")
        }
        let messages = (thread.messages ?? []).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var out: [CachedMessage] = []
        var inline: [(String, [MIMEParser.PartRef])] = []
        let at = now()
        for message in messages {
            let parsed = CachedMessage.parsed(message)
            out.append(parsed.message)
            inline.append((message.id, parsed.inline))
            if let entry = writeCache(parsed.message, accountId: row.accountId) {
                try? repo.putCache(entry, threadR: row.r, at: at)
            }
        }
        if prefetch, let store = inlinePrefetch {
            await Self.prefetch(inline, into: store, accountId: row.accountId, threadR: row.r)
        }
        let ids = messages.map(\.id)
        if ids != row.messageIds {
            var updated = row
            updated.messageIds = ids
            updated.messageCount = ids.count
            try? repo.upsert(updated)
        }
        trimCache()
        return out
    }

    /// Bytes that came with any message go into the cache; the newest message's missing images are fetched
    /// (capped) before the thread is returned, so the reader's first paint has them. Failures only leave alt text.
    static func prefetch(_ messages: [(String, [MIMEParser.PartRef])], into store: MailInlinePrefetching, accountId: UUID,
                         threadR: String) async {
        for (messageId, parts) in messages {
            for p in parts where InlinePrefetch.isImage(p.mimeType) {
                guard let data = p.data, let partId = p.partId, !partId.isEmpty else { continue }
                try? await store.store(accountId: accountId, threadR: threadR, messageId: messageId, partId: partId,
                                       mimeType: p.mimeType, data: data)
            }
        }
        guard let (newest, parts) = messages.last else { return }
        let jobs = InlinePrefetch.plan(messageId: newest, parts: parts)
        await InlinePrefetch.run(jobs) { job in
            try? await store.fetch(accountId: accountId, threadR: threadR, messageId: job.messageId, partId: job.partId,
                                   attachmentId: job.attachmentId, mimeType: job.mimeType)
        }
    }

    // MARK: For the attachment store (rich mail, D-043)

    /// A message from the body cache (no network); nil when it isn't cached (or is an older format).
    func cachedMessage(accountId: UUID, messageId: String) -> CachedMessage? {
        guard let entry = try? MailRepo(db: db).cacheEntry(accountId: accountId, messageId: messageId) else { return nil }
        return readCache(entry.file)
    }

    /// Fetches the thread again and rewrites its body cache: Gmail's attachment ids change between fetches,
    /// so a stale one is refreshed this way. No inline prefetch.
    @discardableResult
    func refreshThread(r: String) async throws -> [CachedMessage] {
        guard let row = try MailRepo(db: db).thread(r: r) else { throw Self.notFound }
        return try await fetchThread(row, prefetch: false)
    }

    // MARK: Body cache files

    static func fileName(accountId: UUID, messageId: String) -> String {
        String(MailIds.threadR(accountId: accountId, threadId: "body\u{1F}\(messageId)").dropFirst()) + ".json"
    }

    private func ensureFolder() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDirectory.path) {
            try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Nil for unreadable files and older formats (v1 had no part ids): the thread is fetched again.
    private func readCache(_ file: String) -> CachedMessage? {
        guard let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent(file)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let message = try? decoder.decode(CachedMessage.self, from: data), message.v >= CachedMessage.version else { return nil }
        return message
    }

    private func writeCache(_ message: CachedMessage, accountId: UUID) -> MailRepo.CacheEntry? {
        ensureFolder()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(message) else { return nil }
        let name = Self.fileName(accountId: accountId, messageId: message.id)
        let url = cacheDirectory.appendingPathComponent(name)
        do {
            try SnapshotPublisher.atomicWrite(data, to: url)
        } catch {
            return nil
        }
        return MailRepo.CacheEntry(accountId: accountId, messageId: message.id, file: name, bytes: data.count)
    }

    /// Least recently read entries go until the cache is within its limit.
    @discardableResult
    func trimCache() -> Int {
        let repo = MailRepo(db: db)
        var removed = 0
        var total = (try? repo.cacheBytes()) ?? 0
        while total > cacheLimit {
            let batch = (try? repo.cacheOldest(limit: 50)) ?? []
            guard !batch.isEmpty else { break }
            for entry in batch where total > cacheLimit {
                try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(entry.file))
                try? repo.deleteCache(accountId: entry.accountId, messageId: entry.messageId)
                total -= entry.bytes
                removed += 1
            }
        }
        return removed
    }

    /// Files no index row points at (their account was removed, or a write raced a crash).
    @discardableResult
    func sweepOrphans() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) else { return 0 }
        let known = (try? MailRepo(db: db).cacheFiles()) ?? []
        var removed = 0
        for name in names where !known.contains(name) {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    func cacheSummary() -> (files: Int, bytes: Int) {
        let repo = MailRepo(db: db)
        return ((try? repo.cacheFiles().count) ?? 0, (try? repo.cacheBytes()) ?? 0)
    }

    // MARK: MailPreferencesStore

    func prefs(account: UUID) -> MailAccountPrefs {
        MailDefaults.prefs(db: db, accountId: account)
    }

    func save(account: UUID, _ prefs: MailAccountPrefs) throws {
        guard try AccountRepo(db: db).get(account) != nil else {
            throw ServiceError(description: "That account isn\u{2019}t connected anymore.")
        }
        let before = self.prefs(account: account)
        if let rich = prefs.signatureRich, rich.count > 512 * 1024 {   // rich signatures: RTFD, 512 KB at most (D-042)
            throw ServiceError(description: "That signature is too big to keep. Signatures can be up to 512 KB.")
        }
        let signature = String(prefs.signature.replacingOccurrences(of: "\r\n", with: "\n").prefix(2_000))
        try MailRepo(db: db).savePrefs(accountId: account, MailPrefsRecord(primaryOnly: prefs.primaryOnly, signature: signature,
                                                                           signatureRich: prefs.signatureRich?.base64EncodedString()))
        if before.primaryOnly != prefs.primaryOnly {
            try MailRepo(db: db).setHistory(accountId: account, historyId: nil)
            prefsChanged?(account)
        }
    }

    /// The allow list has the sender ("Always for this sender"; any account).
    func allowsImages(from sender: String) -> Bool {
        guard let key = MailDefaults.senderKey(sender) else { return false }
        return (try? MailRepo(db: db).allowsImages(sender: key)) ?? false
    }

    /// For a message in `accountId`: the allow list has the sender, or (with "Images from people you've written to" on)
    /// that account has written to them: they sent a message in a thread the user replied in, or got a send from this
    /// app (`mail_correspondents`). Your own addresses never count as correspondents (a spoofed self-sender stays
    /// blocked), and a correspondent of one account is not one of another's.
    func allowsImages(from sender: String, accountId: UUID) -> Bool {
        guard let key = MailDefaults.senderKey(sender) else { return false }
        if (try? MailRepo(db: db).allowsImages(sender: key)) ?? false { return true }
        guard imagesFromCorrespondents() else { return false }
        let repo = CorrespondentRepo(db: db)
        guard let own = try? repo.ownAddresses(), !own.contains(key) else { return false }
        return (try? repo.contains(key, accountId: accountId)) ?? false
    }

    func setAllowsImages(from sender: String, _ allowed: Bool) throws {
        guard let key = MailDefaults.senderKey(sender) else {
            throw ServiceError(description: "That isn\u{2019}t an email address.")
        }
        try MailRepo(db: db).setAllowsImages(sender: key, allowed)
    }

    /// "Images from people you've written to" was turned off: every address recorded for it goes, all accounts. Call it
    /// after the setting is saved off (Settings → Mail does), so nothing is recorded again behind it. The engine also
    /// clears them at start while the setting is off.
    func forgetCorrespondents() throws {
        try CorrespondentRepo(db: db).removeAll()
    }
}
