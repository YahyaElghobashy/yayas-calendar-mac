import Foundation

/// Everything the data layer reaches outside itself. The app builds it in `DataServices.start(accounts:)`;
/// tests build it with fakes and folders under the worktree's `.work/`.
struct DataEnvironment {
    var database: AppDatabase
    var source: SyncAccountsSource
    var transport: HTTPTransport
    var linkKeys: LinkKeyStore
    var reloader: TimelineReloader
    var widgetDirectory: URL
    var logosDirectory: URL
    var now: @Sendable () -> Date = { Date() }
    var calendar: @Sendable () -> Calendar = { DayKey.systemCalendar() }
    /// Mail on. The app passes on (D-029: no labs gate); off here (the default) keeps the data tests' calendar-only
    /// runs free of Gmail traffic.
    var labsMail: @Sendable () -> Bool = { false }
    /// -1…1, for the ±10 s polling jitter.
    var random: @Sendable () -> Double = { Double.random(in: -1...1) }
    var timing = SyncTiming()
    var googlePageSize = 250
    /// Polling loops and the midnight/reload ticker. Off in tests that drive passes by hand.
    var runLoops = true
    /// PII-free event + detail (the app passes `Trace.app`).
    var trace: @Sendable (String, String) -> Void = { _, _ in }
    /// SAFE_SEND (`Labs.safeSend` in the app, D-023): sends only to the connected accounts' own addresses
    /// and to the outside addresses the user approved for that send (`MailDraft.approvedOutside`).
    var labsSafeSend: @Sendable () -> Bool = { true }
    /// Mail bodies (0700 folder, 0600 files). Nil = `mailcache` next to the database file.
    var mailCacheDirectory: URL?
    var mailCacheLimit = 100 << 20
    /// Attachment bytes (rich mail, D-043; 0700 folder, 0600 files). Nil = `attachments` next to the database file.
    var attachmentDirectory: URL?
    var attachmentCacheLimit = 300 << 20
    /// Queued raw MIME of big sends (rich mail, D-044; 0700 folder, 0600 files). Nil = `outbox` next to the database file.
    var outboxDirectory: URL?
    /// Settings → Mail "Images from people you've written to" (off by default).
    var imagesFromCorrespondents: @Sendable () -> Bool = { false }
    /// Waits (send delay, retry backoff, quota bucket). Tests pass a clock-driven or gated one.
    var sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// The data layer at runtime: per-account polling loops, the calendar store, the publisher, the reload
/// governor and the widget interactions, over one shared database connection.
final class DataEngine: @unchecked Sendable {
    let env: DataEnvironment
    let db: AppDatabase
    let syncer: CalendarSyncer
    let links: LinkTokens
    let governor: ReloadGovernor
    let publisher: SnapshotPublisher
    let widgets: WidgetService
    let calendarStore: LocalCalendarStore
    let mailSyncer: MailSyncer
    let mailStore: LocalMailStore
    let mailActions: MailActionService
    /// Attachment bytes on disk (rich mail): `Services.mailAttachments` and the inline-image prefetch.
    let attachmentStore: LocalAttachmentStore
    /// Observers (Sources/Notify): told after calendar passes, RSVPs, account edits and mail passes.
    let observers = DataObservers()
    /// When each kind's latest ↻ began (WidgetRefresh.swift).
    let refreshes = RefreshLedger()

    private let lock = NSLock()
    private var loops: [UUID: AccountSyncLoop] = [:]
    private var mailLoops: [UUID: AccountSyncLoop] = [:]
    private var quotas: [UUID: GmailQuota] = [:]
    private var ticker: Task<Void, Never>?
    private var lastDay: Date?
    private var lastLabsMail: Bool?
    private var mailExpiry: Date?
    private var running = false
    private var visible = false

    init(environment env: DataEnvironment) {
        self.env = env
        db = env.database
        syncer = CalendarSyncer(db: env.database, now: env.now, calendar: env.calendar)
        syncer.relistInterval = 15 * 60
        links = LinkTokens(store: env.linkKeys)
        governor = ReloadGovernor(reloader: env.reloader, budget: env.timing.reloadBudget, now: env.now)
        publisher = SnapshotPublisher(db: env.database, links: links, governor: governor,
                                      directory: env.widgetDirectory, logos: env.logosDirectory, timing: env.timing,
                                      now: env.now, calendar: env.calendar, labsMail: env.labsMail)
        publisher.trace = env.trace
        widgets = WidgetService(repo: WidgetRepo(db: env.database), publisher: publisher, governor: governor,
                                links: links, now: env.now, calendar: env.calendar)
        widgets.trace = env.trace
        calendarStore = LocalCalendarStore(db: env.database)
        mailSyncer = MailSyncer(db: env.database, now: env.now)
        let cache = env.mailCacheDirectory
            ?? env.database.url.deletingLastPathComponent().appendingPathComponent("mailcache", isDirectory: true)
        mailStore = LocalMailStore(db: env.database, cacheDirectory: cache, cacheLimit: env.mailCacheLimit, now: env.now)
        mailActions = MailActionService(db: env.database, now: env.now, sleep: env.sleep)
        let attachments = env.attachmentDirectory
            ?? env.database.url.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
        attachmentStore = LocalAttachmentStore(db: env.database, directory: attachments, limit: env.attachmentCacheLimit, now: env.now)
        attachmentStore.mail = mailStore
        mailStore.inlinePrefetch = attachmentStore
        mailStore.imagesFromCorrespondents = env.imagesFromCorrespondents
        mailSyncer.imagesFromCorrespondents = env.imagesFromCorrespondents
        let outbox = env.outboxDirectory
            ?? env.database.url.deletingLastPathComponent().appendingPathComponent("outbox", isDirectory: true)
        mailActions.outbox = OutboxStore(directory: outbox)
        let store = mailStore, files = attachmentStore, database = env.database
        // A rich reply or forward quotes its original from the body cache (fetched when it isn't there yet), with the
        // original's inline images from the attachment cache.
        mailActions.quoteSource = { threadR, messageId in
            guard let row = try MailRepo(db: database).thread(r: threadR) else { throw LocalMailStore.notFound }
            if let cached = store.cachedMessage(accountId: row.accountId, messageId: messageId) { return cached }
            try await store.refreshThread(r: threadR)
            return store.cachedMessage(accountId: row.accountId, messageId: messageId)
        }
        mailActions.quoteImage = { threadR, messageId, partId in
            try await files.file(threadR: threadR, messageId: messageId, partId: partId)
        }
        calendarStore.engine = self
        mailActions.safeSend = env.labsSafeSend
        mailActions.trace = env.trace
        mailActions.imagesFromCorrespondents = env.imagesFromCorrespondents
        mailStore.client = { [weak self] id in await self?.gmailClient(for: id) }
        attachmentStore.client = { [weak self] id in await self?.gmailClient(for: id) }
        mailStore.prefsChanged = { [weak self] id in self?.mailResync(id) }
        mailActions.client = { [weak self] id in await self?.gmailClient(for: id) }
        mailActions.publish = { [weak self] in self?.publishMail(reason: .interaction) }
        mailActions.mailChanged = { [weak self] id in self?.pokeMail(id) }
        mailActions.reauthNeeded = { [weak self] id in await self?.env.source.markReauthNeeded(id) }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    var surfaceVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return visible }
        set { lock.lock(); visible = newValue; lock.unlock() }
    }

    // MARK: - Lifecycle

    func start() {
        defer { observers.post(.accounts) }
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        let cal = env.calendar()
        lastDay = cal.startOfDay(for: env.now())
        lock.unlock()
        _ = try? WidgetRepo(db: db).clearKindState(setBefore: cal.startOfDay(for: env.now()))
        publisher.publishAll(reason: .background)
        // "Images from people you've written to" is off: nothing recorded for it stays (it may have been turned off
        // while the engine wasn't running, or the clear may have failed).
        if !env.imagesFromCorrespondents() { try? mailStore.forgetCorrespondents() }
        mailStore.sweepOrphans()
        attachmentStore.sweepOrphans()
        mailActions.recover()
        env.trace("data-start", "loops=\(env.runLoops)")
        guard env.runLoops else { return }
        accountsChanged()
        startTicker()
    }

    func stop() async {
        for loop in halt() { await loop.stop() }
    }

    private func halt() -> [AccountSyncLoop] {
        lock.lock(); defer { lock.unlock() }
        running = false
        let all = Array(loops.values) + Array(mailLoops.values)
        loops.removeAll()
        mailLoops.removeAll()
        ticker?.cancel()
        ticker = nil
        return all
    }

    /// Accounts were added, removed or edited (AccountsModel publishes; debounced by the app hook):
    /// start/stop loops, retry stuck accounts, republish.
    func accountsChanged() {
        defer { observers.post(.accounts) }
        let accounts = (try? AccountRepo(db: db).all()) ?? []
        let ids = Set(accounts.map(\.id))
        SyncStatusRepo(db: db).prune(keeping: ids)
        let labs = env.labsMail()
        let mailIds = labs ? Set(accounts.filter { $0.mailEnabled && $0.provider == Provider.google.rawValue }.map(\.id)) : []
        var added: [AccountSyncLoop] = []
        var removed: [AccountSyncLoop] = []
        var kept: [AccountSyncLoop] = []
        lock.lock()
        lastLabsMail = labs
        // An account that had a Gmail client is gone: its attachment rows cascaded, so sweep their files below.
        let lostAccount = quotas.keys.contains { !ids.contains($0) }
        for id in quotas.keys where !ids.contains(id) { quotas[id] = nil }
        if running && env.runLoops {
            for (id, loop) in mailLoops where !mailIds.contains(id) {
                removed.append(loop)
                mailLoops[id] = nil
            }
            for id in mailIds {
                if let loop = mailLoops[id] {
                    kept.append(loop)
                } else {
                    let loop = makeMailLoop(id)
                    mailLoops[id] = loop
                    added.append(loop)
                }
            }
            for (id, loop) in loops where !ids.contains(id) {
                removed.append(loop)
                loops[id] = nil
            }
            for id in ids {
                if let loop = loops[id] {
                    kept.append(loop)
                } else {
                    let loop = makeLoop(id)
                    loops[id] = loop
                    added.append(loop)
                }
            }
        }
        lock.unlock()
        publisher.publishAll(reason: .background)
        if !removed.isEmpty { mailStore.sweepOrphans() }
        if !removed.isEmpty || lostAccount { attachmentStore.sweepOrphans() }
        // A removed account's queued sends went with its rows (cascade): their outbox files go now, not at next launch.
        mailActions.sweepOutbox()
        Task {
            for loop in removed { await loop.stop() }
            for loop in added { await loop.start() }
            for loop in kept {
                switch await loop.lastOutcome {
                case .ok?, nil: break
                default: await loop.poke()
                }
            }
        }
    }

    private func makeLoop(_ id: UUID) -> AccountSyncLoop {
        let timing = env.timing
        let random = env.random
        return AccountSyncLoop(accountId: id, clock: env.now, work: { [weak self] force in
            guard let self else { return .cancelled }
            return await self.syncAccount(id, force: force)
        }, decide: { [weak self] outcome, failures in
            SyncPolicy.next(after: outcome, failures: failures, visible: self?.surfaceVisible ?? false,
                            timing: timing, jitter: random())
        })
    }

    private func makeMailLoop(_ id: UUID) -> AccountSyncLoop {
        let timing = env.timing.forMail
        let random = env.random
        return AccountSyncLoop(accountId: id, clock: env.now, work: { [weak self] _ in
            guard let self else { return .cancelled }
            return await self.syncMail(id)
        }, decide: { [weak self] outcome, failures in
            SyncPolicy.next(after: outcome, failures: failures, visible: self?.surfaceVisible ?? false,
                            timing: timing, jitter: random())
        })
    }

    private func startTicker() {
        let interval = env.timing.tick
        ticker = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, interval) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// Midnight check, the mail switch (`labsMail`), closed undo windows, and background reloads whose budget reopened.
    func tick() {
        let current = env.now()
        let today = env.calendar().startOfDay(for: current)
        let labs = env.labsMail()
        lock.lock()
        let rolled = lastDay.map { today > $0 } ?? false
        lastDay = today
        let labsFlipped = lastLabsMail.map { $0 != labs } ?? false
        let expired = mailExpiry.map { current >= $0 } ?? false
        if expired { mailExpiry = nil }
        lock.unlock()
        if rolled { midnight() }
        if labsFlipped { accountsChanged() }
        if expired {
            _ = try? MailRepo(db: db).prune(now: current)
            publishMail(reason: .background)
        }
        governor.tick()
    }

    /// A new day: forget picked days/months/ranges, republish (today moved), re-list every window.
    func midnight() {
        let today = env.calendar().startOfDay(for: env.now())
        _ = try? WidgetRepo(db: db).clearKindState(setBefore: today)
        publisher.publishAll(reason: .background)
        pokeAll(force: true)
    }

    /// Screen wake, unlock, session back, network back.
    func wake() {
        tick()
        pokeAll(force: false)
        for loop in currentMailLoops() { Task { await loop.poke() } }
    }

    /// The popover or main window opened: sync accounts whose last pass is older than the visible
    /// interval (1 minute for calendars, 30 s for mail).
    func surfaceBecameVisible() {
        let now = env.now()
        for (group, threshold) in [(currentLoops(), env.timing.visibleInterval),
                                   (currentMailLoops(), env.timing.mailVisibleInterval)] {
            for loop in group {
                Task {
                    let last = await loop.lastRunAt
                    if last.map({ now.timeIntervalSince($0) >= threshold }) ?? true { await loop.poke() }
                }
            }
        }
    }

    private func currentLoops() -> [AccountSyncLoop] {
        lock.lock(); defer { lock.unlock() }
        return Array(loops.values)
    }

    private func currentMailLoops() -> [AccountSyncLoop] {
        lock.lock(); defer { lock.unlock() }
        return Array(mailLoops.values)
    }

    func mailLoop(_ id: UUID) -> AccountSyncLoop? {
        lock.lock(); defer { lock.unlock() }
        return mailLoops[id]
    }

    /// Sync this account's mail soon (a send went out).
    func pokeMail(_ id: UUID) {
        guard let loop = mailLoop(id) else { return }
        Task { await loop.poke() }
    }

    /// Primary-only changed: the history id is gone, so the next pass is a full sync; run it now (when
    /// mail loops aren't running, the next pass whenever it comes is that full sync).
    func mailResync(_ id: UUID) {
        guard let loop = mailLoop(id) else { return }
        Task { await loop.poke(force: true) }
    }

    func loop(_ id: UUID) -> AccountSyncLoop? {
        lock.lock(); defer { lock.unlock() }
        return loops[id]
    }

    private func pokeAll(force: Bool) {
        for loop in currentLoops() { Task { await loop.poke(force: force) } }
    }

    // MARK: - Sync

    /// One pass for one account. Never throws: the outcome drives the loop's next wait.
    func syncAccount(_ id: UUID, force: Bool) async -> SyncOutcome {
        defer { observers.post(.calendar) }
        guard let account = try? AccountRepo(db: db).get(id) else { return .skipped }
        guard account.provider == Provider.google.rawValue, account.calendarEnabled else { return .skipped }
        switch account.health {
        case .reauthNeeded, .adminBlocked, .setupNeeded: return .waitingForUser
        default: break
        }
        let status = SyncStatusRepo(db: db)
        guard let tokens = await env.source.tokenSource(for: id) else {
            status.recordError(id, code: SyncOutcome.notReady.code)
            return .notReady
        }
        let client = GoogleCalendarClient(transport: env.transport, tokens: tokens, pageSize: env.googlePageSize)
        do {
            let report = try await syncer.sync(accountId: id, client: client, force: force)
            status.recordSuccess(id, at: env.now())
            await env.source.apiAvailability(id, api: "calendar", available: true)
            env.trace("calendar-sync", "ok cals=\(report.calendars) listed=\(report.listed) changes=\(report.feedChanges) resets=\(report.resets) up=\(report.upserted) del=\(report.deleted) skipped=\(report.skipped.count)")
            publisher.publishAll(reason: .background)
            return .ok
        } catch {
            let outcome = SyncOutcome(error: error)
            status.recordError(id, code: outcome.code)
            env.trace("calendar-sync", outcome.code)
            if outcome == .reauthNeeded { await env.source.markReauthNeeded(id) }
            if (error as? GoogleAPIError)?.isServiceDisabled == true {
                await env.source.apiAvailability(id, api: "calendar", available: false)
            }
            publisher.publishAll(reason: .background)
            return outcome
        }
    }

    /// "Sync now": a forced pass for every account (through its loop when loops run).
    func syncAll(force: Bool) async {
        let ids = ((try? AccountRepo(db: db).all()) ?? []).map(\.id)
        await refresh(accounts: Set(ids), force: force)
    }

    func refresh(accounts ids: Set<UUID>, force: Bool = true) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    if let loop = self.loop(id), await loop.isRunning {
                        await loop.syncNow()
                    } else {
                        _ = await self.syncAccount(id, force: force)
                    }
                }
            }
        }
    }

    // MARK: - Mail

    /// The account's Gmail client: its token source and its own quota bucket.
    func gmailClient(for id: UUID) async -> GmailClient? {
        guard let tokens = await env.source.tokenSource(for: id) else { return nil }
        lock.lock()
        let quota: GmailQuota
        if let existing = quotas[id] {
            quota = existing
        } else {
            quota = GmailQuota(now: env.now, sleep: env.sleep)
            quotas[id] = quota
        }
        lock.unlock()
        return GmailClient(transport: env.transport, tokens: tokens, quota: quota)
    }

    func quota(for id: UUID) -> GmailQuota? {
        lock.lock(); defer { lock.unlock() }
        return quotas[id]
    }

    /// One mail pass for one account (only while the `labsMail` seam is on: always, in the app, D-029). Never throws.
    func syncMail(_ id: UUID) async -> SyncOutcome {
        defer { observers.post(.mail(id)) }
        guard env.labsMail() else { return .skipped }
        guard let account = try? AccountRepo(db: db).get(id) else { return .skipped }
        guard account.provider == Provider.google.rawValue, account.mailEnabled else { return .skipped }
        switch account.health {
        case .reauthNeeded, .adminBlocked, .setupNeeded: return .waitingForUser
        default: break
        }
        let repo = MailRepo(db: db)
        guard let client = await gmailClient(for: id) else {
            try? repo.recordError(accountId: id, code: SyncOutcome.notReady.code)
            return .notReady
        }
        do {
            let report = try await mailSyncer.sync(accountId: id, client: client) { [weak self] in
                self?.publishMail(reason: .background)
            }
            env.trace("mail-sync", "ok full=\(report.full) listed=\(report.listed) fetched=\(report.fetched) skipped=\(report.skipped) touched=\(report.touched) removed=\(report.removed) resets=\(report.resets)")
            publishMail(reason: .background)
            await env.source.apiAvailability(id, api: "gmail", available: true)
            return .ok
        } catch {
            let outcome = SyncOutcome(error: error)
            try? repo.recordError(accountId: id, code: outcome.code)
            env.trace("mail-sync", outcome.code)
            if outcome == .reauthNeeded { await env.source.markReauthNeeded(id) }
            if (error as? GoogleAPIError)?.isServiceDisabled == true {
                await env.source.apiAvailability(id, api: "gmail", available: false)
            }
            publishMail(reason: .background)
            return outcome
        }
    }

    /// Republishes the inbox/combo kinds and remembers when the next undo window closes (the archived
    /// row leaves the snapshot then).
    func publishMail(reason: PublishReason) {
        publisher.publishMail(reason: reason)
        let next = try? ActionRepo(db: db).nextUndoExpiry(now: env.now())
        lock.lock()
        if let soonest = next { mailExpiry = min(mailExpiry ?? soonest, soonest) }
        lock.unlock()
    }

    /// The mail route helpers for the surface router (after `verify(r:k:)`).
    @discardableResult
    func handleMailRoute(_ route: MailRoute, r: String) async -> Bool {
        await mailActions.handleRoute(route, r: r)
    }

    // MARK: - RSVP

    /// This occurrence, on every copy whose own response is still pending (or, when none is, the
    /// primary copy: the user changed their mind). Per copy: fresh GET → PATCH the self attendee with
    /// If-Match; a 412 refetches and retries once. Then the touched accounts re-list.
    func rsvp(r: String, response: CalendarEvent.Response) async throws {
        defer { observers.post(.calendar) }
        guard response != .needsAction else { throw ServiceError(description: "Pick yes, maybe or no.") }
        let events = EventRepo(db: db)
        let accounts = try AccountRepo(db: db).all()
        let included = Set(accounts.filter(\.calendarEnabled).map(\.id))
        let copies = try events.copies(of: r).filter { included.contains($0.accountId) }
        guard !copies.isEmpty else { throw ServiceError(description: "That meeting is no longer in your calendar.") }
        let invited = copies.filter { copy in StoredPerson.decodeList(copy.attendeesJSON).contains { $0.isSelf } }
        var targets = invited.filter { $0.myResponse == "needsAction" }
        if targets.isEmpty {
            let primary = CalendarAssembler(accounts: accounts, calendars: []).primary(of: copies)
            if invited.contains(where: { $0.r == primary.r }) {
                targets = [primary]
            } else if let first = invited.first {
                targets = [first]
            }
        }
        guard !targets.isEmpty else { throw ServiceError(description: "You aren\u{2019}t a guest of that meeting.") }

        var touched = Set<UUID>()
        var firstError: Error?
        for copy in targets {
            guard let tokens = await env.source.tokenSource(for: copy.accountId) else {
                firstError = firstError ?? ServiceError(description: "That account isn\u{2019}t ready yet.")
                continue
            }
            let client = GoogleCalendarClient(transport: env.transport, tokens: tokens, pageSize: env.googlePageSize)
            do {
                let etag = try await Self.answer(client: client, calendarId: copy.calendarId, eventId: copy.eventId,
                                                 response: response)
                try events.setResponse(r: copy.r, response: response.rawValue, etag: etag)
                touched.insert(copy.accountId)
            } catch {
                env.trace("rsvp", SyncOutcome(error: error).code)
                firstError = firstError ?? error
            }
        }
        if !touched.isEmpty { publisher.publishAll(reason: .interaction) }
        await refresh(accounts: touched, force: true)
        if touched.isEmpty, let firstError { throw firstError }
    }

    /// One copy: fresh GET, set the self attendee's responseStatus, PATCH with If-Match. Returns the
    /// new etag.
    static func answer(client: GoogleCalendarClient, calendarId: String, eventId: String,
                       response: CalendarEvent.Response) async throws -> String? {
        var retried = false
        while true {
            let fresh = try await client.getEvent(calendarId: calendarId, eventId: eventId)
            guard var attendees = fresh.json["attendees"] as? [[String: Any]],
                  let index = attendees.firstIndex(where: { ($0["self"] as? Bool) == true })
            else { throw ServiceError(description: "You aren\u{2019}t a guest of that meeting.") }
            guard let etag = fresh.event.etag else { throw GoogleAPIError.undecodable }
            attendees[index]["responseStatus"] = response.rawValue
            do {
                let updated = try await client.patchAttendees(calendarId: calendarId, eventId: eventId,
                                                              attendees: attendees, etag: etag)
                return updated.etag
            } catch GoogleAPIError.preconditionFailed where !retried {
                retried = true
            }
        }
    }

    // MARK: - Diagnostics

    func diagnose() async -> String {
        var loopsState: [UUID: String] = [:]
        for loop in currentLoops() {
            loopsState[loop.accountId] = await loop.lastOutcome?.code ?? "pending"
        }
        var mailState: [UUID: String] = [:]
        for loop in currentMailLoops() {
            mailState[loop.accountId] = await loop.lastOutcome?.code ?? "pending"
        }
        return Diagnostics.report(db: db, widgetDirectory: env.widgetDirectory, now: env.now(),
                                  calendar: env.calendar(), loops: loopsState, running: isRunning,
                                  mailLoops: mailState, labsMail: env.labsMail(), mailCache: mailStore.cacheSummary())
    }
}
