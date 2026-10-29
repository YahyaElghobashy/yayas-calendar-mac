import Foundation

/// The data layer's entry points for the app (docs/CONTRACTS.md "App seam").
///
/// At launch the app calls `DataServices.start(accounts: AccountsModel.shared)` right after
/// `AccountsModel.shared.start()` (defined in `AccountsModel+Data.swift`); that installs
/// `Services.calendar`, `.calendarActions`, `.widgetSettings`, `.widgetInteractions`, `.mail`,
/// `.mailActions`, `.mailPreferences` and `.mailAttachments`. Surfaces set `surfaceVisible` while the popover or main
/// window is open (calendar every minute instead of 2, mail every 30 s instead of 60).
///
/// Mail routes: after `Services.widgetInteractions.verify(r:k:)`, the router calls
/// `DataServices.handleMailRoute(.read | .archive | .star | .undo, r:)`; it updates the row at once,
/// republishes the inbox/combo kinds unthrottled and returns false when nothing happened.
enum DataServices {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: DataEngine?
    nonisolated(unsafe) private static var visible = false
    nonisolated(unsafe) private static var appObservers: [DataObservers.Observer] = []

    static var engine: DataEngine? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// True while the popover or main window is on screen. Turning it on also syncs accounts whose
    /// last pass is more than a minute old.
    static var surfaceVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return visible }
        set {
            lock.lock()
            let was = visible
            visible = newValue
            let engine = current
            lock.unlock()
            engine?.surfaceVisible = newValue
            if newValue && !was { engine?.surfaceBecameVisible() }
        }
    }

    /// Builds the engine, installs the real stores in `Services`, publishes every widget snapshot and
    /// starts polling. Idempotent: a second call returns the running engine.
    @discardableResult
    static func start(environment: DataEnvironment) -> DataEngine {
        lock.lock()
        if let current {
            lock.unlock()
            return current
        }
        let engine = DataEngine(environment: environment)
        engine.surfaceVisible = visible
        for observer in appObservers { engine.observers.add(observer) }
        current = engine
        lock.unlock()
        Services.calendar = engine.calendarStore
        Services.calendarActions = engine.calendarStore
        Services.widgetSettings = engine.widgets
        Services.widgetInteractions = engine.widgets
        Services.mail = engine.mailStore
        Services.mailActions = engine.mailActions
        Services.mailPreferences = engine.mailStore
        Services.mailAttachments = engine.attachmentStore
        engine.start()
        return engine
    }

    /// Notifications (Sources/Notify): `observer` hears every `DataChange` of the running engine and of any engine
    /// started later. Observers only record the change; they read the store on their own queue.
    static func observe(_ observer: @escaping DataObservers.Observer) {
        lock.lock()
        appObservers.append(observer)
        let engine = current
        lock.unlock()
        engine?.observers.add(observer)
    }

    /// A Join with Fathom link changed (D-045): every kind is rebuilt (the Fathom button rides in each meeting's
    /// `rec`) and the changed ones reload; off the main thread, like a sync's publish.
    static func republishWidgets() {
        guard let engine else { return }
        Task.detached {
            engine.publisher.publishAll(reason: .interaction)
            Services.widgetInteractions.flushChanged()
        }
    }

    // MARK: - Mail helpers for the surfaces (beyond the frozen seam)

    /// `yayacal://mail/read|archive|star|undo?r&k`, after the router verified `k`. `mail/undo` reverses
    /// the row's last archive/trash within its 30 s window. False = engine not running or nothing done.
    @discardableResult
    static func handleMailRoute(_ route: MailRoute, r: String) async -> Bool {
        guard let engine else { return false }
        return await engine.handleMailRoute(route, r: r)
    }

    /// Route name ("mail/archive") → the helper above.
    @discardableResult
    static func handleMailRoute(named name: String, r: String) async -> Bool {
        guard let route = MailRoute(rawValue: name) else { return false }
        return await handleMailRoute(route, r: r)
    }

    /// The reader's one-off "Load images" (remote images for this view only, sender not remembered).
    static func messages(threadR: String, loadImages: Bool) async throws -> [MailMessage] {
        guard let engine else { throw ServiceError(description: "Mail isn\u{2019}t running yet.") }
        return try await engine.mailStore.messages(threadR: threadR, loadImages: loadImages)
    }

    /// The thread in Gmail on the web, signed in as its account ("Open in Gmail" for attachments over 50 MB).
    static func gmailURL(threadR: String) -> URL? {
        guard let engine, let row = try? MailRepo(db: engine.db).thread(r: threadR),
              let account = try? AccountRepo(db: engine.db).get(row.accountId) else { return nil }
        var parts = URLComponents(string: "https://mail.google.com/mail/u/")
        parts?.queryItems = [URLQueryItem(name: "authuser", value: account.email)]
        parts?.fragment = "all/" + row.threadId
        return parts?.url
    }

    /// Yaya's Mail Helper (D-050): a thread the helper named (its digest, Review, Needs reply), by account and Gmail
    /// thread id, for the app's own reader and reply composer. A stored row answers at once; otherwise one metadata
    /// GET (Google, through the account's own sign-in) stores it, outside the inbox when Gmail says so (such a row
    /// goes at the next prune, as every row outside the inbox does).
    static func mailThread(accountId: UUID, threadId: String) async throws -> MailThread {
        guard let engine else { throw ServiceError(description: "Mail isn\u{2019}t running yet.") }
        guard (1...32).contains(threadId.utf8.count),
              threadId.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            throw LocalMailStore.notFound
        }
        let repo = MailRepo(db: engine.db)
        if let row = try repo.thread(accountId: accountId, threadId: threadId) { return LocalMailStore.thread(row) }
        guard let client = await engine.gmailClient(for: accountId) else {
            throw ServiceError(description: "That account needs you to sign in again.")
        }
        guard let record = GmailThreadMapper.record(try await client.threadMetadata(threadId), accountId: accountId) else {
            throw LocalMailStore.notFound
        }
        try repo.upsert(record)
        return LocalMailStore.thread(record)
    }

    /// The Gmail thread id behind a row id (the composer's "Draft with AI", D-050); nil when the row is gone.
    static func gmailThreadId(r: String) -> String? {
        guard let engine else { return nil }
        return (try? MailRepo(db: engine.db).thread(r: r))?.threadId
    }

    /// Where a queued send stands (composer toast). Failures are also posted as `.ycMailSendFailed`.
    static func sendStatus(_ token: UndoToken) -> SendStatus {
        engine?.mailActions.sendStatus(token) ?? .unknown
    }

    /// The row's last archive/trash token while its undo window is open (in-app "Undo" buttons).
    static func lastUndoToken(r: String) -> UndoToken? {
        engine?.mailActions.lastUndoToken(r: r)
    }

    /// Stops polling and puts the empty stores back.
    static func stop() async {
        let engine = detach()
        Services.calendar = EmptyStores.shared
        Services.calendarActions = EmptyStores.shared
        Services.widgetSettings = EmptyStores.shared
        Services.widgetInteractions = EmptyStores.shared
        Services.mail = EmptyStores.shared
        Services.mailActions = EmptyStores.shared
        Services.mailPreferences = EmptyStores.shared
        Services.mailAttachments = EmptyStores.shared
        await engine?.stop()
    }

    private static func detach() -> DataEngine? {
        lock.lock(); defer { lock.unlock() }
        let engine = current
        current = nil
        return engine
    }

    /// One JSON line for a headless app flag: per account calendars/events counts, last sync, last
    /// error, loop state; per widget kind the snapshot's size, content, meeting count and health. No
    /// titles, addresses, tokens, account tags or zone names (people paste this into bug reports).
    /// Without a running engine it reads the store at `Paths.store`.
    static func diagnose() async -> String {
        if let engine { return await engine.diagnose() }
        guard let db = try? AppDatabase(url: Paths.store) else {
            return #"{"app":"yayascalendar","error":"store_unavailable","kind":"data-diagnose"}"#
        }
        return Diagnostics.report(db: db, widgetDirectory: Paths.widget, now: Date(),
                                  calendar: DayKey.systemCalendar(), loops: [:], running: false)
    }
}

enum Diagnostics {
    /// Per account mail counts: threads, inbox rows, unread, last sync and error code. No subjects or
    /// addresses.
    static func mailRow(db: AppDatabase, account a: AccountRecord, loop: String?, stamp: (Date?) -> Any) -> [String: Any] {
        let repo = MailRepo(db: db)
        let counts: (threads: Int, inbox: Int, unread: Int) = (try? repo.counts(accountId: a.id)) ?? (0, 0, 0)
        let state = (try? repo.state(accountId: a.id)) ?? MailStateRecord()
        let prefs = MailDefaults.prefs(db: db, accountId: a.id)
        return [
            "on": a.mailEnabled,
            "primaryOnly": prefs.primaryOnly,
            "threads": counts.threads,
            "inbox": counts.inbox,
            "unreadCached": counts.unread,
            "unreadInbox": state.unreadInbox ?? NSNull(),
            "history": state.historyId != nil,
            "lastMailSync": stamp(state.lastSyncAt),
            "lastFull": stamp(state.lastFullAt),
            "mailError": state.lastError ?? NSNull(),
            "loop": loop ?? NSNull(),
        ]
    }

    static func report(db: AppDatabase, widgetDirectory: URL, now: Date, calendar cal: Calendar,
                       loops: [UUID: String], running: Bool, mailLoops: [UUID: String] = [:], labsMail: Bool? = nil,
                       mailCache: (files: Int, bytes: Int)? = nil) -> String {
        let iso = ISO8601DateFormatter()
        func stamp(_ date: Date?) -> Any { date.map { iso.string(from: $0) } ?? NSNull() }
        let status = SyncStatusRepo(db: db)
        let accounts = (try? AccountRepo(db: db).all()) ?? []
        let rows: [[String: Any]] = accounts.enumerated().map { index, a in
            let counts: (all: Int, selected: Int) = (try? CalendarRepo(db: db).count(accountId: a.id)) ?? (0, 0)
            return [
                "id": a.id.uuidString,
                "tag": redactedTag(index),
                "provider": a.provider,
                "health": a.health.rawValue,
                "calendarOn": a.calendarEnabled,
                "includeInAll": a.includeInAll,
                "calendars": counts.all,
                "selected": counts.selected,
                "events": (try? EventRepo(db: db).count(accountId: a.id)) ?? 0,
                "feedTokens": (try? SyncStateRepo(db: db).tokenCount(accountId: a.id)) ?? 0,
                "lastSync": stamp(status.lastSuccess(a.id)),
                "lastList": stamp((try? SyncStateRepo(db: db).lastList(accountId: a.id)) ?? nil),
                "lastError": status.lastError(a.id) ?? NSNull(),
                "loop": loops[a.id] ?? NSNull(),
                "mail": mailRow(db: db, account: a, loop: mailLoops[a.id], stamp: stamp),
            ]
        }
        var snapshots: [String: Any] = [:]
        for spec in WidgetKinds.all {
            let url = widgetDirectory.appendingPathComponent("\(spec.kind).json")
            guard let data = try? Data(contentsOf: url) else { snapshots[spec.kind] = NSNull(); continue }
            guard let s = try? WidgetSnapshot.decoder.decode(WidgetSnapshot.self, from: data) else {
                snapshots[spec.kind] = ["bytes": data.count, "error": "undecodable"]
                continue
            }
            snapshots[spec.kind] = [
                "bytes": data.count,
                "content": s.content.rawValue,
                "meetings": s.meetings.count,
                "mail": s.mail.count,
                "unread": s.unreadCount ?? NSNull(),
                "accounts": s.accounts.count,
                "health": s.health.state.rawValue,
                "busyDays": s.busyDays.count,
                "generatedAt": iso.string(from: s.generatedAt),
                "hash": String(s.contentHash, radix: 16),
            ]
        }
        let keys = SyncWindow.current(now: now, calendar: cal).dayKeys(cal)
        var root: [String: Any] = [
            "app": "yayascalendar",
            "kind": "data-diagnose",
            "at": iso.string(from: now),
            "schema": db.schemaVersion,
            "engine": running ? "running" : "stopped",
            "utcOffset": utcOffset(cal.timeZone, at: now),
            "firstWeekday": cal.firstWeekday,
            "window": [keys.first, keys.last],
            "accounts": rows,
            "snapshots": snapshots,
        ]
        if let labsMail { root["labsMail"] = labsMail }
        if let mailCache { root["mailCache"] = ["files": mailCache.files, "bytes": mailCache.bytes] }
        let actions = ActionRepo(db: db)
        root["mailActions"] = ["pending": (try? actions.count(state: .pending)) ?? 0,
                               "running": (try? actions.count(state: .running)) ?? 0,
                               "failed": (try? actions.count(state: .failed)) ?? 0]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return #"{"error":"encode"}"# }
        return line
    }

    /// The report never names an account: tags are often a company's initials, so rows say A1, A2, …
    /// in the user's order instead.
    static func redactedTag(_ index: Int) -> String { "A\(index + 1)" }

    /// The zone as an offset ("UTC+01:00") rather than its identifier, which names a city.
    static func utcOffset(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return "UTC" + sign + String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
