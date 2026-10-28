import Foundation

/// What the coordinator reads: the data layer's stores (the running engine in the app).
protocol NotifyDataSource: AnyObject, Sendable {
    /// False until the engine runs: nothing is planned (or removed) from an empty, not-yet-open store.
    var isReady: Bool { get }
    func events(from: Date, to: Date) throws -> [CalendarEvent]
    func event(r: String) throws -> CalendarEvent?
    func accounts() throws -> [AccountRecord]
    /// Inbox threads of one account, newest first.
    func inbox(account: UUID, limit: Int) throws -> [MailThread]
}

/// The running engine (`DataServices.engine` in the app; a test harness's engine in tests).
final class EngineNotifyData: NotifyDataSource, @unchecked Sendable {
    private let engine: @Sendable () -> DataEngine?

    init(engine: @escaping @Sendable () -> DataEngine? = { DataServices.engine }) {
        self.engine = engine
    }

    var isReady: Bool { engine()?.isRunning ?? false }

    func events(from: Date, to: Date) throws -> [CalendarEvent] {
        guard let engine = engine() else { return [] }
        return try engine.calendarStore.events(from: from, to: to, accounts: nil)
    }

    func event(r: String) throws -> CalendarEvent? {
        try engine()?.calendarStore.event(r: r)
    }

    func accounts() throws -> [AccountRecord] {
        guard let engine = engine() else { return [] }
        return try AccountRepo(db: engine.db).all()
    }

    func inbox(account: UUID, limit: Int) throws -> [MailThread] {
        guard let engine = engine() else { return [] }
        return try engine.mailStore.threads(accounts: [account], limit: limit)
    }
}

/// Turns data changes into notifications and the Deck export, one pass at a time.
///
/// - Every `DataChange` is queued; a single drain runs the passes in order (a change that lands
///   during a pass gets its own pass after it), so two plans never interleave.
/// - A calendar/accounts change → `refresh()`: heads-up diff against the system's pending requests,
///   re-auth notices, Deck export. A mail change → `mailSynced(account)`.
/// - Pending requests are read back from the system on every pass, so a restart neither duplicates
///   nor forgets them (ids are deterministic; a re-added id replaces its old request).
actor NotifyCoordinator {
    let data: NotifyDataSource
    let center: NoteCenter
    let prefs: NotifyPrefs
    let deck: DeckExporter?
    /// Settings → "Share upcoming meetings with Deck" (read on every pass).
    private let deckEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private let locale: Locale
    private let trace: @Sendable (String, String) -> Void
    /// Coalesces bursts (four accounts finishing a pass together) into one pass.
    private let debounce: TimeInterval

    /// Permission is read from the system (no prompt) every time something is to be shown, so turning
    /// notifications off or on in System Settings counts at once. Undecided → the system prompt runs in
    /// the background, at most once per 10 minutes (a pass never waits on it: an ignored prompt would
    /// freeze heads-ups and the Deck export); a "yes" queues a pass. Nothing is added meanwhile.
    private var asking = false
    private var promptedAt: Date?
    private var lastAuth: NoteAuth?
    static let authRecheck: TimeInterval = 600
    /// Accounts whose delivered re-auth notice was already withdrawn this run (saves repeat calls; the
    /// decision itself comes from the persisted stamps and the stored health).
    private var withdrawn = Set<UUID>()
    /// Pass again just after the soonest heads-up fires (meetings past the cap get their slot).
    private(set) var nextWake: Date?
    private var wakeTask: Task<Void, Never>?
    private var queued: [DataChange] = []
    private var draining = false
    private(set) var passes = 0

    init(data: NotifyDataSource, center: NoteCenter, prefs: NotifyPrefs, deck: DeckExporter?,
         deckEnabled: @escaping @Sendable () -> Bool = { true },
         now: @escaping @Sendable () -> Date = { Date() },
         calendar: @escaping @Sendable () -> Calendar = { Calendar.autoupdatingCurrent },
         locale: Locale = .autoupdatingCurrent, debounce: TimeInterval = 1.5,
         trace: @escaping @Sendable (String, String) -> Void = { _, _ in }) {
        self.data = data
        self.center = center
        self.prefs = prefs
        self.deck = deck
        self.deckEnabled = deckEnabled
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.debounce = debounce
        self.trace = trace
    }

    // MARK: - Queue

    /// From any thread (engine observers, timers, Settings).
    nonisolated func changed(_ change: DataChange) {
        Task { await self.enqueue(change) }
    }

    func enqueue(_ change: DataChange) {
        if !queued.contains(change) { queued.append(change) }
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    /// True while a pass is queued or running (tests wait on it).
    var isBusy: Bool { draining || !queued.isEmpty }

    private func drain() async {
        if debounce > 0 { try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000)) }
        while !queued.isEmpty {
            let batch = queued
            queued.removeAll()
            if batch.contains(where: { $0 == .calendar || $0 == .accounts }) { await refresh() }
            for case .mail(let id) in batch { await mailSynced(id) }
        }
        draining = false
    }

    // MARK: - Passes

    /// Heads-up plan, re-auth notices, Deck export.
    func refresh() async {
        guard data.isReady else { return }
        passes += 1
        let now = self.now()
        let accounts: [AccountRecord]
        let events: [CalendarEvent]
        do {
            accounts = try data.accounts()
            let span = max(HeadsUp.horizon, DeckExportBuilder.after)
            events = try data.events(from: now.addingTimeInterval(-DeckExportBuilder.before), to: now.addingTimeInterval(span))
        } catch {
            // Never plan from a failed read: that would remove every pending heads-up.
            trace("notify-plan", "read-failed")
            return
        }
        await planMeetings(events, accounts: accounts, now: now)
        await reauthNotices(accounts, now: now)
        exportDeck(events, accounts: accounts, now: now)
    }

    func context(accounts: [AccountRecord], now: Date) -> HeadsUp.Context {
        HeadsUp.Context(now: now, calendar: calendar(), locale: locale, meetingsOn: prefs.meetingsOn,
                        pausedUntil: prefs.isPaused(at: now) ? prefs.pausedUntil : nil,
                        tags: Dictionary(accounts.map { ($0.id, $0.tag) }, uniquingKeysWith: { first, _ in first }))
    }

    private func planMeetings(_ events: [CalendarEvent], accounts: [AccountRecord], now: Date) async {
        let c = context(accounts: accounts, now: now)
        let desired = HeadsUp.desired(events, c)
        armWake(HeadsUp.nextWake(desired, now: now), now: now)
        guard let pending = await center.pending() else {
            trace("notify-plan", "pending-unavailable")
            return
        }
        let plan = HeadsUp.plan(desired: desired, pending: pending, liveKeys: HeadsUp.liveKeys(events, c),
                                pausedUntil: c.pausedUntil)
        if !plan.remove.isEmpty { await center.removePending(plan.remove) }
        var failed = 0
        var added = 0
        if !plan.add.isEmpty, await permitted(now) {
            for note in plan.add {
                do { try await center.add(note); added += 1 } catch { failed += 1 }
            }
        }
        if added > 0 || !plan.remove.isEmpty || failed > 0 {
            trace("notify-plan", "add=\(added) remove=\(plan.remove.count) kept=\(plan.unchanged) failed=\(failed)")
        }
    }

    private func reauthNotices(_ accounts: [AccountRecord], now: Date) async {
        let prefs = self.prefs
        // Signed back in (or removed) — also across restarts: every account stamped as notified whose
        // health is no longer reauthNeeded loses its "signed me out" note in Notification Center.
        let current = Dictionary(accounts.map { ($0.id, $0.health) }, uniquingKeysWith: { first, _ in first })
        for (id, health) in current where health == .reauthNeeded { withdrawn.remove(id) }
        let fixed = prefs.reauthStamped().filter { current[$0] != .reauthNeeded && !withdrawn.contains($0) }
        if !fixed.isEmpty {
            await center.removeDelivered(fixed.map(ReauthNotices.id).sorted())
            withdrawn.formUnion(fixed)
        }

        let due = ReauthNotices.due(accounts, now: now, paused: prefs.isPaused(at: now), sentAt: { prefs.reauthSentAt($0) })
        guard !due.isEmpty, await permitted(now) else { return }
        for account in due {
            // Stamp first: a crash right after the add must not repeat the notice on the next launch.
            let previous = prefs.reauthSentAt(account.id)
            prefs.setReauthSent(account.id, at: now)
            do {
                try await center.add(ReauthNotices.note(account))
                trace("notify-reauth", "sent")
            } catch {
                if let previous { prefs.setReauthSent(account.id, at: previous) } else { prefs.clearReauthSent(account.id) }
                trace("notify-reauth", "failed")
            }
        }
    }

    private func exportDeck(_ events: [CalendarEvent], accounts: [AccountRecord], now: Date) {
        guard let deck, deckEnabled() else { return }
        let export = DeckExportBuilder.build(events: events, accounts: accounts, now: now)
        do {
            if try deck.publish(export) { trace("deck-export", "written meetings=\(export.meetings.count)") }
        } catch {
            trace("deck-export", "failed")
        }
    }

    /// One account's mail pass ended: batch its new unread inbox threads into one note (setting OFF by
    /// default). The watermark moves when nothing is to be shown or after the note went out; a batch
    /// held back (paused, not permitted, add failed) comes again with the next pass.
    func mailSynced(_ id: UUID) async {
        guard data.isReady else { return }
        guard let account = try? data.accounts().first(where: { $0.id == id }),
              let threads = try? data.inbox(account: id, limit: MailNotices.fetchLimit) else { return }
        let now = self.now()
        let outcome = MailNotices.batch(account: account, threads: threads, seen: prefs.mailSeen(id), now: now,
                                        enabled: prefs.newMailOn, paused: prefs.isPaused(at: now))
        guard let note = outcome.note else {
            if let seen = outcome.seen { prefs.setMailSeen(id, seen) }
            return
        }
        guard await permitted(now) else { return }
        do {
            try await center.add(note)
            if let seen = outcome.seen { prefs.setMailSeen(id, seen) }
            trace("notify-mail", "sent new=\(outcome.newCount)")
        } catch {
            trace("notify-mail", "failed")
        }
    }

    // MARK: - Actions

    /// "Snooze 1 min": the same meeting again in 60 s (`snooze-<r>-<epoch start>`, replaces an earlier
    /// snooze of it). Ignored when the meeting is gone, moved, declined, over, or notifications are
    /// off or paused.
    @discardableResult
    func snooze(userInfo: [String: String]) async -> Bool {
        guard let r = userInfo["r"], NoteIds.isSafeRowId(r), let start = userInfo["start"].flatMap(Int64.init) else { return false }
        let now = self.now()
        guard prefs.meetingsOn, !prefs.isPaused(at: now) else { return false }
        guard let event = try? data.event(r: r), HeadsUp.epoch(event.start) == start, HeadsUp.isEligible(event),
              event.end > now else { return false }
        let accounts = (try? data.accounts()) ?? []
        let note = HeadsUp.note(event, fire: now.addingTimeInterval(HeadsUp.snoozeDelay), snooze: true,
                                context(accounts: accounts, now: now))
        guard await permitted(now) else { return false }
        do {
            try await center.add(note)
            trace("notify-snooze", "ok")
            return true
        } catch {
            trace("notify-snooze", "failed")
            return false
        }
    }

    /// "Join": the meeting's link from the store (never from the notification), re-checked against the
    /// allowlist. Nil = nothing safe to open.
    func joinURL(userInfo: [String: String]) -> URL? {
        guard let r = userInfo["r"], NoteIds.isSafeRowId(r), let event = (try? data.event(r: r)) ?? nil,
              let url = event.joinURL, JoinGuard.isAllowed(url) else { return nil }
        return url
    }

    /// Notifications allowed right now (system status, read every time; never latched).
    private func permitted(_ now: Date) async -> Bool {
        let status = await center.authorizationStatus()
        if status != lastAuth {
            lastAuth = status
            trace("notify-auth", "\(status)")
        }
        switch status {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            // No await between this check and setting `asking`: concurrent callers prompt once.
            guard !asking else { return false }
            if let asked = promptedAt, now >= asked, now.timeIntervalSince(asked) < Self.authRecheck { return false }
            promptedAt = now
            asking = true
            let center = self.center
            Task { [weak self] in
                let granted = await center.authorize()
                await self?.answered(granted)
            }
            return false
        }
    }

    private func answered(_ granted: Bool) {
        asking = false
        trace("notify-auth", granted ? "granted" : "declined")
        if granted { enqueue(.accounts) }
    }

    /// One pending wake at a time; re-armed only when the moment changes.
    private func armWake(_ at: Date?, now: Date) {
        guard at != nextWake else { return }
        nextWake = at
        wakeTask?.cancel()
        wakeTask = nil
        guard let at else { return }
        let delay = max(1, at.timeIntervalSince(now))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 2 * 86_400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.changed(.calendar)
        }
    }

    /// The engine runs (a notification action can launch the app: wait for the store, at most `seconds`).
    func waitUntilReady(_ seconds: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !data.isReady {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }
}
