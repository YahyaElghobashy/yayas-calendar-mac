import Foundation

/// Mail preferences with their defaults: Primary only for consumer Gmail (a 12k inbox is mostly
/// promotions), the whole inbox for Workspace accounts; no signature.
enum MailDefaults {
    static let personalDomains: Set<String> = ["gmail.com", "googlemail.com"]

    static func prefs(email: String) -> MailAccountPrefs {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        return MailAccountPrefs(primaryOnly: personalDomains.contains(domain), signature: "")
    }

    static func prefs(db: AppDatabase, accountId: UUID) -> MailAccountPrefs {
        if let stored = try? MailRepo(db: db).prefs(accountId: accountId) {
            return MailAccountPrefs(primaryOnly: stored.primaryOnly, signature: stored.signature,
                                    signatureRich: stored.signatureRich.flatMap { Data(base64Encoded: $0) })
        }
        let email = (try? AccountRepo(db: db).get(accountId))?.email ?? ""
        return prefs(email: email)
    }

    /// Image allow-list key: the bare address, lowercased.
    static func senderKey(_ sender: String) -> String? {
        let address = MailAddress.parseList(sender).first?.email ?? sender
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MailAddress.isValid(key) ? key : nil
    }
}

/// A Gmail thread (metadata format) → the inbox row.
enum GmailThreadMapper {
    static func record(_ thread: GThread, accountId: UUID) -> MailThreadRecord? {
        guard let messages = thread.messages, !messages.isEmpty else { return nil }
        let sorted = messages.enumerated().sorted { a, b in
            let da = a.element.date ?? .distantPast
            let db = b.element.date ?? .distantPast
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
        guard let newest = sorted.last else { return nil }
        var labels = Set<String>()
        for m in sorted { labels.formUnion(m.labelIds ?? []) }
        let inboxMessages = sorted.filter { ($0.labelIds ?? []).contains("INBOX") }
        let considered = inboxMessages.isEmpty ? sorted : inboxMessages
        let primary = considered.contains { m in
            let l = m.labelIds ?? []
            return l.contains("CATEGORY_PERSONAL") || !l.contains { $0.hasPrefix("CATEGORY_") }
        }
        let senderMessage = sorted.last { !($0.labelIds ?? []).contains("SENT") } ?? newest
        let from = senderMessage.header("From").flatMap { MailAddress.parseList($0).first }
        var subject = newest.header("Subject").map(EncodedWord.decode) ?? ""
        if subject.trimmingCharacters(in: .whitespaces).isEmpty {
            subject = sorted.reversed().compactMap { $0.header("Subject").map(EncodedWord.decode) }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        }
        let snippet = HTMLEntities.decode(newest.snippet ?? thread.snippet ?? "")
        let messageIdHeader = newest.header("Message-ID")?.trimmingCharacters(in: .whitespaces)
        return MailThreadRecord(
            r: MailIds.threadR(accountId: accountId, threadId: thread.id), accountId: accountId, threadId: thread.id,
            historyId: thread.historyId ?? newest.historyId,
            subject: String(subject.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)),
            senderName: String((from?.name ?? "").prefix(200)), senderEmail: String((from?.email ?? "").prefix(254)),
            snippet: String(snippet.prefix(400)), lastAt: newest.date ?? Date(timeIntervalSince1970: 0),
            unread: labels.contains("UNREAD"), starred: labels.contains("STARRED"), inInbox: !inboxMessages.isEmpty,
            categoryPrimary: primary, messageCount: sorted.count,
            lastMessageIdHeader: messageIdHeader.flatMap { MIMEBuilder.isMessageID($0) ? $0 : nil },
            labels: labels.sorted(), messageIds: sorted.map(\.id))
    }
}

/// Runs `body` over `items` with at most `limit` in flight; `each` sees results as they arrive (on the
/// caller's task, so store writes stay serial).
enum Bounded {
    static func forEach<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ body: @escaping @Sendable (T) async throws -> R,
                                                  each: (T, R) throws -> Void) async throws {
        guard !items.isEmpty else { return }
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var next = 0
            while next < min(max(1, limit), items.count) {
                let i = next
                group.addTask { (i, try await body(items[i])) }
                next += 1
            }
            while let (i, result) = try await group.next() {
                try each(items[i], result)
                if next < items.count {
                    let j = next
                    group.addTask { (j, try await body(items[j])) }
                    next += 1
                }
            }
        }
    }
}

/// One account's mail sync pass (D-018). Rows are threads.
///
/// - Full: `profile` (historyId baseline) → `threads.list` INBOX (+ `q=category:primary` when Primary
///   only), the newest 150 first (published as soon as they're stored), then more pages up to 500;
///   `threads.get?format=metadata` for each thread whose historyId changed, ≤4 in flight; inbox rows the
///   list didn't return leave the inbox.
/// - Incremental: `history.list` from the stored historyId (added/deleted messages, label changes) →
///   refetch every touched thread. 404 (history too old) → full. Also full once a day.
/// - Unread: `labels.get INBOX` threadsUnread for whole-inbox accounts; Primary-only accounts count
///   their cached rows.
/// - Actions not yet confirmed by Gmail are re-applied over fetched rows, so a sync never undoes an
///   optimistic change on screen.
final class MailSyncer: @unchecked Sendable {
    struct Report: Equatable, Sendable {
        var full = false
        var resets = 0
        var listed = 0
        var fetched = 0
        var skipped = 0
        var touched = 0
        var removed = 0
        var unread: Int?
    }

    let db: AppDatabase
    let now: @Sendable () -> Date
    var firstBatch = 150
    var pageSize = 150
    var maxThreads = 500
    /// Gmail also limits concurrent requests per user; 4 stays clear of it (6 drew 429s live).
    var concurrency = 4
    var fullEvery: TimeInterval = 24 * 3600
    /// More touched threads than this in one history read → a full sync is cheaper.
    var maxTouched = 300
    var maxHistoryPages = 40
    /// Settings → Mail "Images from people you've written to": correspondents are recorded only while it is on.
    var imagesFromCorrespondents: @Sendable () -> Bool = { false }

    init(db: AppDatabase, now: @escaping @Sendable () -> Date) {
        self.db = db
        self.now = now
    }

    func sync(accountId: UUID, client: GmailClient, firstBatchStored: (() -> Void)? = nil) async throws -> Report {
        let repo = MailRepo(db: db)
        let prefs = MailDefaults.prefs(db: db, accountId: accountId)
        let state = try repo.state(accountId: accountId)
        var report = Report()
        let fullDue = state.historyId == nil || (state.lastFullAt.map { now().timeIntervalSince($0) >= fullEvery } ?? true)
        if fullDue {
            try await full(accountId: accountId, client: client, prefs: prefs, report: &report, firstBatchStored: firstBatchStored)
        } else if let start = state.historyId {
            do {
                try await incremental(accountId: accountId, client: client, prefs: prefs, start: start, report: &report)
            } catch GoogleAPIError.notFound {
                report.resets += 1
                try repo.setHistory(accountId: accountId, historyId: nil)
                try await full(accountId: accountId, client: client, prefs: prefs, report: &report, firstBatchStored: firstBatchStored)
            }
        }
        if prefs.primaryOnly {
            try repo.setUnreadInbox(accountId: accountId, nil)
        } else {
            let label = try await client.label("INBOX")
            try repo.setUnreadInbox(accountId: accountId, label.threadsUnread)
            report.unread = label.threadsUnread
        }
        if report.full, (try repo.state(accountId: accountId)).sendAsName == nil {
            let list = (try? await client.sendAs()) ?? []
            let primary = list.first { $0.isPrimary == true } ?? list.first { $0.isDefault == true } ?? list.first
            try? repo.setSendAsName(accountId: accountId, (primary?.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        report.removed += try repo.prune(now: now())
        try repo.recordSuccess(accountId: accountId, at: now())
        return report
    }

    private func full(accountId: UUID, client: GmailClient, prefs: MailAccountPrefs, report: inout Report,
                      firstBatchStored: (() -> Void)?) async throws {
        report.full = true
        let repo = MailRepo(db: db)
        let baseline = try await client.profile().historyId
        let known = try repo.historyIds(accountId: accountId)
        var listed = Set<String>()
        var pageToken: String?
        var first = true
        repeat {
            let size = first ? min(firstBatch, maxThreads) : min(pageSize, maxThreads - listed.count)
            guard size > 0 else { break }
            let page = try await client.listThreads(q: prefs.primaryOnly ? "category:primary" : nil, maxResults: size,
                                                    pageToken: pageToken)
            let items = (page.threads ?? []).filter { !listed.contains($0.id) }
            report.listed += items.count
            listed.formUnion(items.map(\.id))
            let changed = items.filter { item in
                guard let stored = known[item.id], let current = item.historyId else { return true }
                return stored != current
            }
            report.skipped += items.count - changed.count
            try await fetch(changed.map(\.id), accountId: accountId, client: client, prefs: prefs, report: &report)
            if first { firstBatchStored?() }
            first = false
            pageToken = page.nextPageToken
        } while pageToken != nil && listed.count < maxThreads
        report.removed += try repo.markOutOfInbox(accountId: accountId, keeping: listed)
        try repo.setHistory(accountId: accountId, historyId: baseline, fullAt: now())
    }

    private func incremental(accountId: UUID, client: GmailClient, prefs: MailAccountPrefs, start: String,
                             report: inout Report) async throws {
        var touched: [String] = []
        var seen = Set<String>()
        var latest = start
        var pageToken: String?
        var pages = 0
        repeat {
            let page = try await client.history(startHistoryId: start, pageToken: pageToken)
            for record in page.history ?? [] {
                for id in record.threadIds where seen.insert(id).inserted { touched.append(id) }
            }
            if let id = page.historyId { latest = id }
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < maxHistoryPages
        report.touched = touched.count
        if touched.count > maxTouched || pageToken != nil {
            try MailRepo(db: db).setHistory(accountId: accountId, historyId: nil)
            try await full(accountId: accountId, client: client, prefs: prefs, report: &report, firstBatchStored: nil)
            return
        }
        try await fetch(touched, accountId: accountId, client: client, prefs: prefs, report: &report)
        let repo = MailRepo(db: db)
        try repo.trimInbox(accountId: accountId, keep: maxThreads)
        try repo.setHistory(accountId: accountId, historyId: latest)
    }

    /// "Images from people you've written to": in a thread where one of the user's messages carries SENT, the
    /// other messages' senders are correspondents (never the user's own addresses). From the metadata already fetched;
    /// no extra calls. Called only while the setting is on; `enabled` is the setting, asked again as the rows are written.
    static func recordCorrespondents(_ thread: GThread, accountId: UUID, db: AppDatabase, at date: Date,
                                     onlyIf enabled: () -> Bool = { true }) throws {
        let messages = thread.messages ?? []
        guard messages.contains(where: { ($0.labelIds ?? []).contains("SENT") }) else { return }
        let senders = messages.filter { !($0.labelIds ?? []).contains("SENT") }
            .compactMap { $0.header("From").flatMap { MailAddress.parseList($0).first?.email } }
        guard !senders.isEmpty else { return }
        try CorrespondentRepo(db: db).add(accountId: accountId, addresses: senders, at: date, onlyIf: enabled)
    }

    /// Metadata GETs (≤ `concurrency` in flight), stored as they arrive. A 404 means the thread is gone.
    private func fetch(_ ids: [String], accountId: UUID, client: GmailClient, prefs: MailAccountPrefs,
                       report: inout Report) async throws {
        let repo = MailRepo(db: db)
        let actions = ActionRepo(db: db)
        var fetched = 0
        var removed = 0
        try await Bounded.forEach(ids, limit: concurrency, { id -> GThread? in
            do {
                return try await client.threadMetadata(id)
            } catch GoogleAPIError.notFound {
                return nil
            }
        }, each: { id, thread in
            fetched += 1
            if let thread, self.imagesFromCorrespondents() {
                try? Self.recordCorrespondents(thread, accountId: accountId, db: self.db, at: self.now(),
                                               onlyIf: self.imagesFromCorrespondents)
            }
            guard let thread, var record = GmailThreadMapper.record(thread, accountId: accountId) else {
                if try repo.markOutOfInbox(accountId: accountId, threadId: id) { removed += 1 }
                return
            }
            for action in try actions.inFlight(r: record.r) { action.kind.apply(to: &record) }
            let visible = record.inInbox && (!prefs.primaryOnly || record.categoryPrimary)
            if visible {
                try repo.upsert(record)
            } else if try repo.thread(r: record.r) != nil {
                record.inInbox = false
                try repo.upsert(record)
                removed += 1
            }
        })
        report.fetched += fetched
        report.removed += removed
    }
}
