import Foundation

/// `yayacal://mail/…` routes (docs/CONTRACTS.md), handled after the router verified `k`.
enum MailRoute: String, CaseIterable, Sendable {
    case read = "mail/read"
    case archive = "mail/archive"
    case undo = "mail/undo"
    case star = "mail/star"
}

/// Where a queued send stands (the composer's "Sending… · Undo" toast polls it).
enum SendStatus: Equatable, Sendable {
    case queued(until: Date)
    case sending
    case sent
    case failed(String)
    case cancelled
    case unknown
}

extension Notification.Name {
    /// Posted when a queued send fails for good. userInfo: "token" (UndoToken id), "message" (friendly text).
    static let ycMailSendFailed = Notification.Name(Profile.scoped("mail-send-failed"))
}

/// Serializes work per key (one thread row): an undo never overtakes the archive it reverses.
actor KeyedSerial {
    private var tails: [String: Task<Void, Never>] = [:]

    func enqueue(_ key: String, _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tails[key]
        let task = Task {
            _ = await previous?.value
            await body()
        }
        tails[key] = task
        return task
    }

    func finished(_ key: String, _ task: Task<Void, Never>) {
        if tails[key] == task { tails[key] = nil }
    }
}

final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    func set(_ value: Result<T, Error>) { lock.lock(); stored = value; lock.unlock() }
    func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// `MailActions` (docs/CONTRACTS.md "Mail"): every change is applied to the local row first
/// (optimistic, republished at once), queued in `actions`, then sent to Gmail; a failure rolls the row
/// back, marks the action failed and throws a friendly error.
///
/// - read/unread → `threads.modify` −/+ UNREAD (unread on the newest message); star → +STARRED on the
///   newest message, unstar → −STARRED on the thread; archive → −INBOX; trash → `threads.trash`.
/// - archive/trash return an `UndoToken` valid 30 s (undo = +INBOX / `threads.untrash`); the last
///   token per row is remembered for `mail/undo?r&k`.
/// - send: SAFE_SEND check (D-023: every recipient is one of the user's own addresses or was approved
///   for this send in `MailDraft.approvedOutside`), MIME built now (our own Message-ID), queued for 5 s
///   (`cancelSend`), then `messages.send`. The switch is read once, when Send is pressed: the queued action
///   stores it (`ask`) with the approvals, and the delivery-time check (retries and recovery after a
///   restart too) applies that same rule, so flipping the switch afterwards never drops a send the user
///   already made. Before any retry the Sent folder is searched for `rfc822msgid:` so a send that timed
///   out after reaching Gmail is never sent twice.
final class MailActionService: MailActions, @unchecked Sendable {
    static let undoWindow: TimeInterval = 30
    static let sendDelay: TimeInterval = 5
    static let maxSendRounds = 4
    static let sendRetryDelays: [TimeInterval] = [2, 8, 20]
    /// Refused when Send is pressed (the composer shows it under the draft).
    static let safeSendMessage = "I didn\u{2019}t send this: you hadn\u{2019}t confirmed who it goes to. Press Send to check and send it."
    /// Refused at delivery, after the composer has closed.
    static let safeSendHeldMessage = "I didn\u{2019}t send this: you hadn\u{2019}t confirmed who it goes to. Nothing was sent."

    let db: AppDatabase
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async -> Void
    var safeSend: @Sendable () -> Bool = { true }
    var client: (@Sendable (UUID) async -> GmailClient?)?
    /// Republish the mail kinds now (interaction: unthrottled reloads).
    var publish: (@Sendable () -> Void)?
    /// Something changed on Gmail for this account (a send): sync it soon.
    var mailChanged: (@Sendable (UUID) -> Void)?
    var reauthNeeded: (@Sendable (UUID) async -> Void)?
    var trace: @Sendable (String, String) -> Void = { _, _ in }
    /// Settings → Mail "Images from people you've written to": a delivered send records its recipients only while on.
    var imagesFromCorrespondents: @Sendable () -> Bool = { false }
    /// Queued raw MIME over 64 KB, or with files or inline images (rich mail, D-044). Nil = everything rides in the row.
    var outbox: OutboxStore?
    /// The original a rich reply or forward quotes, from the body cache (fetched when missing; D-041).
    var quoteSource: (@Sendable (_ threadR: String, _ messageId: String) async throws -> CachedMessage?)?
    /// One of that original's inline images as a local file (the attachment cache).
    var quoteImage: (@Sendable (_ threadR: String, _ messageId: String, _ partId: String) async throws -> URL)?

    /// Raw MIME over this goes through the upload URI (`GmailClient.sendUpload`); smaller sends stay JSON `raw`.
    static let uploadThreshold = 1 << 20

    private let serial = KeyedSerial()
    private let lock = NSLock()
    private var lastUndo: [String: (token: UndoToken, until: Date)] = [:]
    private var deliveries: [String: Task<Void, Never>] = [:]
    /// Outbox names being written or uploaded right now (a send's file before its row exists, an upload's body file):
    /// the sweep leaves them alone.
    private var busyOutbox: Set<String> = []

    init(db: AppDatabase, now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        self.db = db
        self.now = now
        self.sleep = sleep
    }

    // MARK: MailActions

    func markRead(r: String, _ read: Bool) async throws {
        try await modify(r: r, kind: read ? .read : .unread)
    }

    func star(r: String, _ starred: Bool) async throws {
        try await modify(r: r, kind: starred ? .star : .unstar)
    }

    func archive(r: String) async throws -> UndoToken {
        try await modify(r: r, kind: .archive)
    }

    func trash(r: String) async throws -> UndoToken {
        try await modify(r: r, kind: .trash)
    }

    func undo(_ token: UndoToken) async throws {
        let actions = ActionRepo(db: db)
        guard let original = try actions.get(token.id) else { throw ServiceError(description: "Nothing to undo.") }
        if original.kind == .send {
            try await cancelSend(token)
            return
        }
        guard original.kind.removesFromInbox else { throw ServiceError(description: "Nothing to undo.") }
        switch original.state {
        case .undone: return
        case .failed, .cancelled: throw ServiceError(description: "Nothing to undo.")
        default: break
        }
        guard let until = original.undoUntil, now() <= until else { throw ServiceError(description: "Too late to undo.") }
        forget(original.r, token)
        let inverse: MailActionKind = original.kind == .archive ? .unarchive : .untrash
        let action = try enqueueLocal(r: original.r, kind: inverse)
        publish?()
        try await serialized(original.r) {
            try await self.execute(action)
            try? ActionRepo(db: self.db).setState(original.id, .undone)
        }
        publish?()
    }

    func send(_ draft: MailDraft) async throws -> UndoToken {
        let accounts = try AccountRepo(db: db).all()
        guard let account = accounts.first(where: { $0.id == draft.from }), account.provider == Provider.google.rawValue else {
            throw ServiceError(description: "Pick an account to send from.")
        }
        guard account.mailEnabled else { throw ServiceError(description: "Mail is off for that account.") }
        let to = try Self.recipients(draft.to)
        let cc = try Self.recipients(draft.cc)
        let bcc = try Self.recipients(draft.bcc)
        let everyone = to + cc + bcc
        guard !everyone.isEmpty else { throw ServiceError(description: "Add at least one recipient.") }
        let approved = Self.approvals(draft.approvedOutside, for: everyone.map(\.email), accounts: accounts)
        let ask = safeSend()   // read once: the check here and the one at delivery use the same answer
        if ask && !Self.cleared(everyone.map(\.email), accounts: accounts, approved: approved) {
            trace("mail-send", "refused:safe_send")
            throw ServiceError(description: Self.safeSendMessage)
        }

        var subject = String(draft.subject.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces).prefix(500))
        var threadId: String?
        var inReplyTo: String?
        var references: [String] = []
        var rowR = ""
        if let replyTo = draft.replyTo {
            guard let row = try MailRepo(db: db).thread(r: replyTo) else { throw LocalMailStore.notFound }
            rowR = row.r
            if subject.isEmpty { subject = MIMEBuilder.replySubject(row.subject) }
            var parentID = row.lastMessageIdHeader
            var parentRefs: String?
            var parentInReplyTo: String?
            if row.accountId == account.id {
                threadId = row.threadId
                if let client = await client?(account.id), let fresh = try? await client.threadReplyHeaders(row.threadId),
                   let newest = fresh.messages?.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
                    if let id = newest.header("Message-ID")?.trimmingCharacters(in: .whitespaces), MIMEBuilder.isMessageID(id) {
                        parentID = id
                    }
                    parentRefs = newest.header("References")
                    parentInReplyTo = newest.header("In-Reply-To")
                }
            }
            if let parentID, MIMEBuilder.isMessageID(parentID) { inReplyTo = parentID }
            references = MIMEBuilder.references(parentReferences: parentRefs, parentInReplyTo: parentInReplyTo,
                                                parentMessageID: inReplyTo)
        }
        let prefs = MailDefaults.prefs(db: db, accountId: account.id)
        let name = ((try? MailRepo(db: db).state(accountId: account.id))?.sendAsName ?? "")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let messageID = MIMEBuilder.newMessageID()
        let mail = OutgoingMail(from: MailAddress(name: name, email: account.email), to: to, cc: cc, bcc: bcc,
                                subject: subject,
                                body: draft.signatureIncluded ? draft.body : MIMEBuilder.appendSignature(draft.body, prefs.signature),
                                messageID: messageID, inReplyTo: inReplyTo, references: references, date: now())
        let id = UUID().uuidString
        let fileName = OutboxStore.fileName(actionId: id)
        markBusy(fileName)   // written before its row exists: the sweep keeps it until then
        defer { clearBusy(fileName) }
        var payload = ["messageId": messageID, "rcpt": everyone.map { $0.email.lowercased() }.joined(separator: ",")]
        if Self.isRich(draft) {
            // Rich (D-042/D-044): multipart MIME with the quoted original and attachments, built to the outbox file.
            let rich = try await richMail(draft, envelope: mail, signature: prefs.signature)
            try queueRaw(id: id, payload: &payload, keepSmallInRow: rich.files.isEmpty && rich.related.isEmpty) { url in
                try MIMEBuilder.buildRich(rich, to: url)
            }
        } else {
            let raw = MIMEBuilder.build(mail)
            if raw.count <= OutboxStore.inlineLimit || outbox == nil {
                payload["raw"] = raw.base64URLString
            } else {
                try queueRaw(id: id, payload: &payload, keepSmallInRow: true) { url in
                    let out = try MIMEFileWriter(url)
                    defer { out.close() }
                    try out.write(raw)
                    try out.flush()
                    return out.count
                }
            }
        }
        if let threadId { payload["threadId"] = threadId }
        payload["ask"] = ask ? "1" : "0"
        if !approved.isEmpty { payload["approved"] = approved.joined(separator: ",") }
        let created = now()
        do {
            try ActionRepo(db: db).insert(MailActionRecord(id: id, kind: .send, r: rowR, accountId: account.id, payload: payload,
                                                           state: .pending, createdAt: created,
                                                           undoUntil: created.addingTimeInterval(Self.sendDelay)))
        } catch {
            outbox?.delete(payload["rawFile"])
            throw error
        }
        trace("mail-send", payload["rawFile"] == nil ? "queued" : "queued:file")
        scheduleDelivery(id, after: Self.sendDelay)
        return UndoToken(id: id)
    }

    func cancelSend(_ token: UndoToken) async throws {
        let actions = ActionRepo(db: db)
        guard let action = try actions.get(token.id), action.kind == .send else {
            throw ServiceError(description: "Nothing to cancel.")
        }
        if action.state == .cancelled { return }
        guard try actions.setState(token.id, .cancelled, from: .pending) else {
            throw ServiceError(description: "That message has already gone.")
        }
        outbox?.delete(action.payload["rawFile"])
        trace("mail-send", "cancelled")
    }

    // MARK: Routes and helpers for the surfaces

    /// `mail/read` marks read, `mail/archive` archives (remembering the undo token), `mail/star` toggles
    /// the star, `mail/undo` reverses the row's last archive/trash within 30 s. False = nothing happened.
    @discardableResult
    func handleRoute(_ route: MailRoute, r: String) async -> Bool {
        do {
            switch route {
            case .read:
                try await markRead(r: r, true)
            case .archive:
                _ = try await archive(r: r)
            case .star:
                let starred = (try? MailRepo(db: db).thread(r: r))?.starred ?? false
                try await star(r: r, !starred)
            case .undo:
                try await undoLast(r: r)
            }
            trace("mail-route", "\(route.rawValue):ok")
            return true
        } catch {
            trace("mail-route", "\(route.rawValue):error")
            return false
        }
    }

    /// The row's last archive/trash token, while its 30 s window is open.
    func lastUndoToken(r: String) -> UndoToken? {
        let current = now()
        lock.lock(); defer { lock.unlock() }
        lastUndo = lastUndo.filter { $0.value.until >= current }
        return lastUndo[r]?.token
    }

    func undoLast(r: String) async throws {
        guard let token = lastUndoToken(r: r) else { throw ServiceError(description: "Nothing to undo.") }
        try await undo(token)
    }

    func sendStatus(_ token: UndoToken) -> SendStatus {
        guard let action = try? ActionRepo(db: db).get(token.id), action.kind == .send else { return .unknown }
        switch action.state {
        case .pending: return .queued(until: action.undoUntil ?? now())
        case .running: return .sending
        case .done: return .sent
        case .failed: return .failed(action.payload["error"] ?? "Couldn\u{2019}t send.")
        case .cancelled, .undone: return .cancelled
        }
    }

    /// At launch: actions a previous run left unfinished. Sends resume (searching Sent first when they
    /// may already have gone); label changes are re-sent (they're idempotent) or rolled back.
    func recover() {
        let actions = ActionRepo(db: db)
        _ = try? actions.purge(before: now().addingTimeInterval(-7 * 86_400))
        // Outbox files of sends that finished, were cancelled or purged (and strays) go; failed ones stay 7 days.
        sweepOutbox()
        for action in (try? actions.unfinished()) ?? [] {
            if action.state == .running { try? actions.setState(action.id, .pending) }
            var pending = action
            pending.state = .pending
            if action.kind == .send {
                let wait = max(0, (action.undoUntil ?? now()).timeIntervalSince(now()))
                scheduleDelivery(action.id, after: wait)
            } else {
                Task { try? await self.serialized(action.r) { try await self.execute(pending) } }
            }
        }
    }

    /// Deletes outbox files no pending, running or failed send points at: at launch, and when an account goes (its
    /// queued sends' rows went with it, so their files go now rather than at the next launch). Files being written or
    /// uploaded right now are kept: the listing is taken first, then the busy names, then the rows, so a send that
    /// started meanwhile is either busy or already has its row.
    @discardableResult
    func sweepOutbox() -> Int {
        guard let outbox else { return 0 }
        let names = outbox.files()
        lock.lock()
        let busy = busyOutbox
        lock.unlock()
        guard let kept = try? ActionRepo(db: db).sends(in: [.pending, .running, .failed]) else { return 0 }
        return outbox.sweep(names, keeping: Set(kept.compactMap { $0.payload["rawFile"] }).union(busy))
    }

    private func markBusy(_ name: String) { lock.lock(); busyOutbox.insert(name); lock.unlock() }
    private func clearBusy(_ name: String) { lock.lock(); busyOutbox.remove(name); lock.unlock() }

    /// Waits for every queued delivery (tests, quitting).
    func drain() async {
        lock.lock()
        let tasks = Array(deliveries.values)
        lock.unlock()
        for task in tasks { await task.value }
    }

    // MARK: Internals

    @discardableResult
    private func modify(r: String, kind: MailActionKind) async throws -> UndoToken {
        let action = try enqueueLocal(r: r, kind: kind)
        let token = UndoToken(id: action.id)
        if let until = action.undoUntil { remember(r, token, until: until) }
        publish?()
        do {
            try await serialized(r) { try await self.execute(action) }
        } catch {
            forget(r, token)
            throw error
        }
        return token
    }

    /// Inserts the action and applies its effect to the row, in one transaction.
    private func enqueueLocal(r: String, kind: MailActionKind) throws -> MailActionRecord {
        let repo = MailRepo(db: db)
        let created = now()
        return try db.transaction {
            guard let row = try repo.thread(r: r) else { throw LocalMailStore.notFound }
            var payload = ["threadId": row.threadId, "unread": row.unread ? "1" : "0", "starred": row.starred ? "1" : "0",
                           "inInbox": row.inInbox ? "1" : "0"]
            if let newest = row.messageIds.last { payload["messageId"] = newest }
            let record = MailActionRecord(id: UUID().uuidString, kind: kind, r: r, accountId: row.accountId, payload: payload,
                                          state: .pending, createdAt: created,
                                          undoUntil: kind.removesFromInbox ? created.addingTimeInterval(Self.undoWindow) : nil)
            try ActionRepo(db: db).insert(record)
            var updated = row
            kind.apply(to: &updated)
            try save(from: row, to: updated)
            return record
        }
    }

    private func save(from before: MailThreadRecord, to after: MailThreadRecord) throws {
        let repo = MailRepo(db: db)
        try repo.setFlags(r: after.r, unread: after.unread, starred: after.starred, inInbox: after.inInbox)
        let delta = (after.inInbox && after.unread ? 1 : 0) - (before.inInbox && before.unread ? 1 : 0)
        if delta != 0 { try repo.adjustUnreadInbox(accountId: after.accountId, by: delta) }
    }

    /// Restores only the field this action changed (another action may own the others).
    private func rollback(_ action: MailActionRecord) {
        try? db.transaction {
            if let row = try MailRepo(db: db).thread(r: action.r) {
                var restored = row
                switch action.kind {
                case .read, .unread: restored.unread = action.payload["unread"] == "1"
                case .star, .unstar: restored.starred = action.payload["starred"] == "1"
                case .archive, .trash, .unarchive, .untrash: restored.inInbox = action.payload["inInbox"] == "1"
                case .send: break
                }
                try save(from: row, to: restored)
            }
            try ActionRepo(db: db).setState(action.id, .failed)
        }
        publish?()
    }

    private func execute(_ action: MailActionRecord) async throws {
        let actions = ActionRepo(db: db)
        guard (try? actions.setState(action.id, .running, from: .pending)) == true else { return }
        do {
            guard let client = await client?(action.accountId) else {
                throw ServiceError(description: "That account isn\u{2019}t ready yet. Nothing changed.")
            }
            try await perform(action, client)
            try actions.setState(action.id, .done)
            trace("mail-action", "\(action.kind.rawValue):ok")
        } catch {
            rollback(action)
            let outcome = SyncOutcome(error: error)
            trace("mail-action", "\(action.kind.rawValue):\(outcome.code)")
            if outcome == .reauthNeeded { await reauthNeeded?(action.accountId) }
            throw Self.friendly(error)
        }
    }

    private func perform(_ action: MailActionRecord, _ client: GmailClient) async throws {
        guard let thread = action.payload["threadId"] else { throw LocalMailStore.notFound }
        let newest = action.payload["messageId"]
        switch action.kind {
        case .read:
            try await client.modifyThread(thread, remove: ["UNREAD"])
        case .unread:
            if let newest { try await client.modifyMessage(newest, add: ["UNREAD"]) } else { try await client.modifyThread(thread, add: ["UNREAD"]) }
        case .star:
            if let newest { try await client.modifyMessage(newest, add: ["STARRED"]) } else { try await client.modifyThread(thread, add: ["STARRED"]) }
        case .unstar:
            try await client.modifyThread(thread, remove: ["STARRED"])
        case .archive:
            try await client.modifyThread(thread, remove: ["INBOX"])
        case .unarchive:
            try await client.modifyThread(thread, add: ["INBOX"])
        case .trash:
            try await client.trashThread(thread)
        case .untrash:
            let restored = try await client.untrashThread(thread)
            let inInbox = restored?.messages?.contains { ($0.labelIds ?? []).contains("INBOX") } ?? false
            if !inInbox { try await client.modifyThread(thread, add: ["INBOX"]) }
        case .send:
            break
        }
    }

    private func serialized<T>(_ key: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = ResultBox<T>()
        let task = await serial.enqueue(key) {
            do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
        }
        await task.value
        await serial.finished(key, task)
        guard let result = box.get() else { throw CancellationError() }
        return try result.get()
    }

    private func remember(_ r: String, _ token: UndoToken, until: Date) {
        lock.lock(); lastUndo[r] = (token, until); lock.unlock()
    }

    private func forget(_ r: String, _ token: UndoToken) {
        lock.lock()
        if lastUndo[r]?.token == token { lastUndo[r] = nil }
        lock.unlock()
    }

    // MARK: Sending

    private func scheduleDelivery(_ id: String, after delay: TimeInterval) {
        let task = Task { [weak self] in
            guard let self else { return }
            if delay > 0 { await self.sleep(delay) }
            await self.deliver(id)
            self.lock.lock()
            self.deliveries[id] = nil
            self.lock.unlock()
        }
        lock.lock()
        if deliveries[id] == nil { deliveries[id] = task }
        lock.unlock()
    }

    /// After the undo window: running → (search Sent if a send may already have reached Gmail) → send.
    /// Transient failures retry with backoff; nothing is ever sent without that search first.
    func deliver(_ id: String) async {
        let actions = ActionRepo(db: db)
        guard (try? actions.setState(id, .running, from: .pending)) == true, let action = try? actions.get(id) else { return }
        // Small sends ride in the row; big ones (and any with attachments) in the outbox file, checked by SHA-256.
        var stored = action.payload["raw"].flatMap({ Data(base64URL: $0) })
        if stored == nil, let name = action.payload["rawFile"], let outbox {
            stored = try? outbox.read(name, sha256: action.payload["rawSHA256"])
        }
        guard let raw = stored, let messageID = action.payload["messageId"] else {
            return fail(action, OutboxStore.unreadable)
        }
        // What Gmail will deliver to (the raw To, Cc and Bcc) must be exactly the recipients checked below and when Send
        // was pressed: a row or file changed after queueing never reaches anyone else.
        let rcpt = (action.payload["rcpt"] ?? "").split(separator: ",").map { $0.lowercased() }
        guard let envelope = MIMEParser.envelopeRecipients(raw), Set(envelope) == Set(rcpt), !envelope.isEmpty else {
            trace("mail-send", "refused:recipients")
            return fail(action, OutboxStore.unreadable)
        }
        // The rule in force when Send was pressed; a send queued before `ask` was stored follows the switch now.
        if action.payload["ask"].map({ $0 == "1" }) ?? safeSend() {
            let recipients = (action.payload["rcpt"] ?? "").split(separator: ",").map(String.init)
            let approved = (action.payload["approved"] ?? "").split(separator: ",").map(String.init)
            if !Self.cleared(recipients, accounts: (try? AccountRepo(db: db).all()) ?? [], approved: approved) {
                return fail(action, Self.safeSendHeldMessage)
            }
        }
        var attempts = action.attempts
        var lastError: Error?
        for round in 0..<Self.maxSendRounds {
            if round > 0 { await sleep(Self.sendRetryDelays[min(round - 1, Self.sendRetryDelays.count - 1)]) }
            guard let client = await client?(action.accountId) else {
                lastError = ServiceError(description: "That account isn\u{2019}t ready yet.")
                continue
            }
            if attempts > 0 {
                do {
                    if !(try await client.searchSent(messageID: messageID)).isEmpty {
                        trace("mail-send", "found_in_sent")
                        return finishSent(action)
                    }
                } catch {
                    lastError = error
                    if Self.transient(error) { continue }
                    break
                }
            }
            attempts += 1
            try? actions.setAttempts(id, attempts)
            let upload = raw.count > Self.uploadThreshold
            do {
                if upload {
                    // The upload body streams from a file next to the message (busy while it uploads).
                    let body = outbox?.uploadFile(actionId: action.id)
                    if let body { markBusy(body.lastPathComponent) }
                    defer { if let body { clearBusy(body.lastPathComponent) } }
                    _ = try await client.sendUpload(raw: raw, threadId: action.payload["threadId"], bodyFile: body)
                } else {
                    _ = try await client.send(raw: raw, threadId: action.payload["threadId"])
                }
                return finishSent(action)
            } catch {
                lastError = error
                if upload { trace("mail-send", "upload_failed:\(Self.sizeBucket(raw.count))") }
                trace("mail-send", "attempt:\(SyncOutcome(error: error).code)")
                if SyncOutcome(error: error) == .reauthNeeded { await reauthNeeded?(action.accountId) }
                if !Self.transient(error) { break }
            }
        }
        fail(action, Self.friendlySend(lastError))
    }

    private func finishSent(_ action: MailActionRecord) {
        try? ActionRepo(db: db).setState(action.id, .done)
        outbox?.delete(action.payload["rawFile"])
        // "Images from people you've written to": everyone this app sent to counts, recorded only while it is on
        // (your own addresses never are).
        if imagesFromCorrespondents() {
            let recipients = (action.payload["rcpt"] ?? "").split(separator: ",").map(String.init)
            _ = try? CorrespondentRepo(db: db).add(accountId: action.accountId, addresses: recipients, at: now(),
                                                   onlyIf: imagesFromCorrespondents)
        }
        trace("mail-send", "sent")
        mailChanged?(action.accountId)
    }

    private func fail(_ action: MailActionRecord, _ message: String) {
        var payload = action.payload
        payload["error"] = message
        try? ActionRepo(db: db).setPayload(action.id, payload)
        try? ActionRepo(db: db).setState(action.id, .failed)
        trace("mail-send", "failed")
        NotificationCenter.default.post(name: .ycMailSendFailed, object: nil,
                                        userInfo: ["token": action.id, "message": message])
    }

    // MARK: Rich sends (D-042, D-044)

    /// HTML, attachments or a quoted original: anything the plain single-part builder can't carry.
    static func isRich(_ draft: MailDraft) -> Bool {
        draft.html != nil || !draft.attachments.isEmpty || draft.quote != nil
    }

    /// The draft as multipart parts: its text and HTML, inline images (with html) as related parts, files, and the
    /// quoted original composed from the body cache with its own inline images (alt text when one can't be read).
    private func richMail(_ draft: MailDraft, envelope: OutgoingMail, signature: String) async throws -> RichOutgoingMail {
        var text = envelope.body
        var html = draft.html
        if let current = html, !draft.signatureIncluded {
            let sig = signature.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sig.isEmpty {
                html = current + "<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">-- <br>"
                    + MailHTMLWriter.escape(sig).replacingOccurrences(of: "\n", with: "<br>") + "</div>"
            }
        }
        var related: [MIMEAttachment] = []
        var files: [MIMEAttachment] = []
        for a in draft.attachments {
            let part = MIMEAttachment(filename: a.filename, mimeType: a.mimeType, contentId: a.contentId,
                                      source: a.data.map { .data($0) } ?? .file(a.file))
            if a.contentId != nil, html != nil { related.append(part) } else {
                files.append(MIMEAttachment(filename: part.filename, mimeType: part.mimeType, contentId: nil, source: part.source))
            }
        }
        if let request = draft.quote {
            let original: CachedMessage?
            do {
                original = try await quoteSource?(request.threadR, request.messageId)
            } catch let error as ServiceError {
                throw error
            } catch {
                throw Self.friendly(error)
            }
            guard let original else {
                throw ServiceError(description: "I couldn\u{2019}t find the message you\u{2019}re answering, so nothing was sent.")
            }
            var quote = MailQuoteComposer.compose(original, kind: request.kind, style: request.style)
            for image in quote.images {
                if let url = try? await quoteImage?(request.threadR, request.messageId, image.partId) {
                    related.append(MIMEAttachment(filename: image.filename, mimeType: image.mimeType, contentId: image.contentId,
                                                  source: .file(url)))
                } else {
                    quote.html = MailQuoteComposer.replaceImage(quote.html, cid: image.contentId)
                }
            }
            // One blank line between the reply and the quote, as Gmail writes it.
            while let last = text.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { text.unicodeScalars.removeLast() }
            text += (text.isEmpty ? "" : "\n\n") + quote.text
            html = (html ?? HTMLSanitizer.html(fromText: envelope.body)) + "<br>" + quote.html
        }
        if html == nil { related.removeAll() }
        return RichOutgoingMail(headers: envelope, text: text, html: html, related: related, files: files)
    }

    /// Builds the raw MIME into `outbox/<id>.eml` (before any row exists), refuses it over 25 MB (no row, no file), and
    /// records the file in `payload`; a small message without files or inline images moves back into the row.
    private func queueRaw(id: String, payload: inout [String: String], keepSmallInRow: Bool, build: (URL) throws -> Int) throws {
        guard let outbox else {
            // No outbox (plain-send callers): the bytes ride in the row.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("yc-\(UUID().uuidString).eml")
            defer { try? FileManager.default.removeItem(at: url) }
            let bytes = try build(url)
            guard MailSize.fits(bytes) else { throw ServiceError(description: MailSize.tooLargeMessage(bytes)) }
            payload["raw"] = try Data(contentsOf: url).base64URLString
            return
        }
        let name = OutboxStore.fileName(actionId: id)
        guard let url = outbox.url(name) else { throw OutboxStore.notQueued }
        let bytes: Int
        do {
            try outbox.prepare()
            bytes = try build(url)
        } catch {
            outbox.delete(name)
            trace("mail-send", "refused:build")
            throw Self.queueError(error)
        }
        guard MailSize.fits(bytes) else {
            outbox.delete(name)
            trace("mail-send", "refused:too_large")
            throw ServiceError(description: MailSize.tooLargeMessage(bytes))
        }
        if keepSmallInRow, bytes <= OutboxStore.inlineLimit, let data = try? Data(contentsOf: url) {
            outbox.delete(name)
            payload["raw"] = data.base64URLString
            return
        }
        do {
            payload["rawSHA256"] = try OutboxStore.sha256(file: url)
        } catch {
            outbox.delete(name)
            throw Self.queueError(error)
        }
        payload["rawFile"] = name
        payload["rawBytes"] = "\(bytes)"
    }

    static func queueError(_ error: Error) -> ServiceError {
        if let service = error as? ServiceError { return service }
        if case MIMEBuildError.unreadable(let name) = error {
            return ServiceError(description: "I couldn\u{2019}t read \u{201C}\(name)\u{201D}. Remove it or attach it again.")
        }
        if OutboxStore.isOutOfSpace(error) { return OutboxStore.outOfSpace }
        return OutboxStore.notQueued
    }

    /// Trace lines carry size buckets, never names or exact sizes.
    static func sizeBucket(_ bytes: Int) -> String {
        switch bytes {
        case ..<(1 << 20): return "<1MB"
        case ..<(5 << 20): return "1-5MB"
        case ..<(10 << 20): return "5-10MB"
        case ..<(20 << 20): return "10-20MB"
        default: return "20MB+"
        }
    }

    // MARK: Rules

    /// Each entry may hold several addresses ("a@x, B <b@y>"); duplicates collapse; anything that isn't
    /// a plain address (or tries to carry a line break) is refused.
    static func recipients(_ entries: [String]) throws -> [MailAddress] {
        var out: [MailAddress] = []
        var seen = Set<String>()
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parsed = MailAddress.parseList(trimmed)
            // Unicode scalars, not Characters: "\r\n" is ONE Character, so `contains("\r")` misses a CRLF pair.
            guard !trimmed.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }), !parsed.isEmpty else {
                throw ServiceError(description: "\u{201C}\(trimmed.prefix(60))\u{201D} isn\u{2019}t an email address.")
            }
            for address in parsed {
                let email = address.email.trimmingCharacters(in: .whitespaces)
                guard MailAddress.isValid(email) else {
                    throw ServiceError(description: "\u{201C}\(email.prefix(60))\u{201D} isn\u{2019}t an email address.")
                }
                guard seen.insert(email.lowercased()).inserted else { continue }
                out.append(MailAddress(name: address.name.replacingOccurrences(of: "\r", with: "")
                                                .replacingOccurrences(of: "\n", with: ""), email: email))
            }
        }
        return out
    }

    /// SAFE_SEND (D-023): every recipient is one of the connected accounts' own addresses or one the user
    /// approved for this send. Case-insensitive; approving one address never clears another.
    static func cleared(_ recipients: [String], accounts: [AccountRecord], approved: [String] = []) -> Bool {
        let own = Set(accounts.map { normalized($0.email) })
        let ok = own.union(approved.map(normalized))
        return !recipients.isEmpty && recipients.allSatisfy { ok.contains(normalized($0)) }
    }

    /// The approvals worth keeping for this send: normalized, deduplicated, only addresses that are on it
    /// and aren't the user's own (what the queued action stores for the delivery-time check).
    static func approvals(_ approved: [String], for recipients: [String], accounts: [AccountRecord]) -> [String] {
        let own = Set(accounts.map { normalized($0.email) })
        let on = Set(recipients.map(normalized))
        var seen = Set<String>()
        return approved.map(normalized).filter { !$0.isEmpty && on.contains($0) && !own.contains($0) && seen.insert($0).inserted }
    }

    private static func normalized(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func transient(_ error: Error) -> Bool {
        switch SyncOutcome(error: error) {
        case .offline, .serverError, .rateLimited, .keychainLocked, .notReady: return true
        default: return error is ServiceError
        }
    }

    static func friendly(_ error: Error) -> ServiceError {
        if let service = error as? ServiceError { return service }
        if let api = error as? GoogleAPIError, api == .notFound {
            return ServiceError(description: "Gmail no longer has that conversation.")
        }
        switch SyncOutcome(error: error) {
        case .offline: return ServiceError(description: "You\u{2019}re offline. Nothing changed.")
        case .reauthNeeded: return ServiceError(description: "Sign in to that account again. Nothing changed.")
        case .rateLimited: return ServiceError(description: "Gmail asked us to slow down. Nothing changed; try again in a minute.")
        case .keychainLocked: return ServiceError(description: "Your keychain is locked. Nothing changed.")
        default: return ServiceError(description: "Gmail didn\u{2019}t accept that. Nothing changed.")
        }
    }

    static func friendlySend(_ error: Error?) -> String {
        guard let error else { return "Couldn\u{2019}t send. Try again in a moment." }
        if let service = error as? ServiceError { return service.description }
        switch SyncOutcome(error: error) {
        case .offline: return "Couldn\u{2019}t send: you\u{2019}re offline."
        case .reauthNeeded: return "Couldn\u{2019}t send: sign in to that account again."
        case .rateLimited: return "Couldn\u{2019}t send: Gmail asked us to slow down."
        default: return "Couldn\u{2019}t send: Gmail refused the message."
        }
    }
}
