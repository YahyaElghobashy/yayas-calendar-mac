import Foundation

enum PublishReason: Sendable {
    /// Sync results, midnight, account edits: reloads go through the 15-minute budget.
    case background
    /// A widget tap, Widget Studio, RSVP: the agent is active, reload now.
    case interaction
}

/// Widget Studio settings ↔ `widget_settings` rows.
enum WidgetSettingsCodec {
    static let ranges = [1, 2, 7]
    static let customContents: Set<WidgetSnapshot.Content> = [.agenda, .day, .upNext, .month, .inbox, .combo]

    static func coerceRange(_ days: Int) -> Int { ranges.contains(days) ? days : 7 }
    static func isCustom(_ kind: String) -> Bool { kind.hasPrefix("custom.") }

    static func settings(from row: WidgetSettingsRow?, kind: String) -> WidgetSettings {
        var s = WidgetSettings(kind: kind)
        guard let row else { return s }
        if let data = row.styleJSON?.data(using: .utf8),
           let style = try? JSONDecoder().decode(WidgetSnapshot.Style.self, from: data) {
            s.style = style
        }
        if isCustom(kind) {
            s.title = cleanTitle(row.title)
            s.customContent = row.customContent.flatMap(WidgetSnapshot.Content.init(rawValue:))
                .flatMap { customContents.contains($0) ? $0 : nil }
        }
        if let data = row.accountIdsJSON?.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) {
            s.accountIds = ids.compactMap(UUID.init(uuidString:))
        }
        s.rangeDays = coerceRange(row.rangeDays)
        return s
    }

    static func row(from s: WidgetSettings) -> WidgetSettingsRow {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let style = (try? encoder.encode(s.style)).flatMap { String(data: $0, encoding: .utf8) }
        let ids = s.accountIds.flatMap { try? encoder.encode($0.map(\.uuidString)) }.flatMap { String(data: $0, encoding: .utf8) }
        let custom = isCustom(s.kind)
        return WidgetSettingsRow(kind: s.kind, styleJSON: style, title: custom ? cleanTitle(s.title) : nil,
                                 customContent: custom ? s.customContent.flatMap { customContents.contains($0) ? $0.rawValue : nil } : nil,
                                 accountIdsJSON: ids, rangeDays: coerceRange(s.rangeDays))
    }

    static func cleanTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(40))
    }
}

/// Builds `widget/<kind>.json` for the 12 kinds (D-014) and writes it atomically, only when the
/// content hash changed; then lets the `ReloadGovernor` decide about the timeline reload.
///
/// Content rules: no time-relative text; meetings capped at 120 (agenda kinds: today's start for the
/// range in days; Month: the picked day, or today, to the end of the window; Day: that day's meetings
/// only, D-022); 192 KB enforced by
/// trimming meetings (then mail rows) from the end; custom slots show `setup` until configured; Inbox
/// and Agenda & Inbox show `mailComingSoon` while the `labsMail` seam is off (tests only; on in the app, D-029),
/// and otherwise carry up to 96 mail threads (newest first, the widget's mail-on accounts), the unread count,
/// and for 30 s after an archive/trash the row itself with `archivedAt` (the widget's "Archived · Undo").
final class SnapshotPublisher: @unchecked Sendable {
    static let maxMeetings = WidgetSnapshot.maxMeetings
    static let maxTextLength = 200

    struct Context {
        var now: Date
        var cal: Calendar
        var window: SyncWindow
        var accounts: [AccountRecord]
        var rows: [EventRecord]
        var lastSuccess: [UUID: Date]
        var labsMail: Bool
        var assembler: CalendarAssembler
        /// Loaded only while the `labsMail` seam is on (always, in the app: D-029).
        var mail: MailContext?
        /// Assembled events and busy days per included-account set: built once, shared by every kind
        /// published from this data (and by taps while it is current).
        var memo = EventMemo()

        /// The window's events for `included` accounts, declined ones out (snapshots never show them).
        func events(included: Set<UUID>) -> [CalendarEvent] {
            memo.events(included) {
                assembler.events(rows: rows, included: included, people: false).filter { $0.myResponse != .declined }
            }
        }

        /// Month dots for `included` accounts.
        func busyDays(included: Set<UUID>) -> [String] {
            memo.busyDays(included) { SnapshotPublisher.busyDays(events(included: included), window: window, cal: cal) }
        }
    }

    final class EventMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Set<UUID>: [CalendarEvent]] = [:]
        private var busy: [Set<UUID>: [String]] = [:]

        func events(_ key: Set<UUID>, _ build: () -> [CalendarEvent]) -> [CalendarEvent] {
            lock.lock()
            if let hit = events[key] { lock.unlock(); return hit }
            lock.unlock()
            let built = build()
            lock.lock(); events[key] = built; lock.unlock()
            return built
        }

        func busyDays(_ key: Set<UUID>, _ build: () -> [String]) -> [String] {
            lock.lock()
            if let hit = busy[key] { lock.unlock(); return hit }
            lock.unlock()
            let built = build()
            lock.lock(); busy[key] = built; lock.unlock()
            return built
        }
    }

    /// What `context` reloads from the store: everything (`publishAll`: a sync pass, account edits,
    /// midnight, RSVP), the mail part (`publishMail`), or only what changed since the last read (a widget
    /// tap, a Studio save: they change widget state and settings, which `snapshot` reads itself). The
    /// store's write generations say what changed (`AppDatabase.generations`): any write to events,
    /// calendars, accounts or sync state reloads everything, a mail write the mail part. The cache also
    /// expires after `cacheLifetime`, at midnight and when the mail switch (`labsMail`) flips; the mail part also when
    /// an "Archived · Undo" window it carries closes (time, not a write, ends that row).
    enum Refresh { case all, mail, none }
    static let cacheLifetime: TimeInterval = 5 * 60

    private struct CachedData {
        var day: Date
        var builtAt: Date
        var generations: AppDatabase.Generations
        var labsMail: Bool
        var accounts: [AccountRecord]
        var rows: [EventRecord]
        var lastSuccess: [UUID: Date]
        var assembler: CalendarAssembler
        var mail: MailContext?
        var memo: EventMemo
    }

    struct MailContext {
        /// Per mail account: inbox threads (newest first, ≤ 96) plus rows whose undo window is open.
        var threads: [UUID: [MailThreadRecord]]
        /// r → when it was archived/trashed (undo window still open).
        var removed: [String: Date]
        var unread: [UUID: Int]
        var lastSync: [UUID: Date]
        /// When the first of those undo windows closes: `removed` is only true until then, so cached
        /// mail data is read again at that moment (no store write marks it).
        var undoExpiry: Date? = nil
    }

    let db: AppDatabase
    let links: LinkTokens
    let governor: ReloadGovernor
    let directory: URL
    let logos: URL
    let timing: SyncTiming
    let now: @Sendable () -> Date
    let calendar: @Sendable () -> Calendar
    let labsMail: @Sendable () -> Bool
    var trace: @Sendable (String, String) -> Void = { _, _ in }
    /// Join with Fathom (D-045): whether a meeting on these accounts, with a join link, gets the widget's Fathom
    /// button. The app installs it before the engine starts; tests and renders keep the default (never).
    nonisolated(unsafe) static var fathomOffered: @Sendable ([UUID], Bool) -> Bool = { _, _ in false }
    /// The recorder a meeting's record button (and its heads-up's second action) joins with (D-046): "fathom",
    /// "murmur", "ask" or nil (no button). The app installs it while it runs; the default is D-045's Fathom button.
    nonisolated(unsafe) static var recorderKind: @Sendable ([UUID], Bool) -> String? = { ids, hasJoin in
        SnapshotPublisher.fathomOffered(ids, hasJoin) ? "fathom" : nil
    }

    private let lock = NSRecursiveLock()
    private var written: [String: UInt64] = [:]
    private var cached: CachedData?

    init(db: AppDatabase, links: LinkTokens, governor: ReloadGovernor, directory: URL, logos: URL,
         timing: SyncTiming, now: @escaping @Sendable () -> Date, calendar: @escaping @Sendable () -> Calendar,
         labsMail: @escaping @Sendable () -> Bool) {
        self.db = db
        self.links = links
        self.governor = governor
        self.directory = directory
        self.logos = logos
        self.timing = timing
        self.now = now
        self.calendar = calendar
        self.labsMail = labsMail
        seedFromDisk()
    }

    func url(kind: String) -> URL { directory.appendingPathComponent("\(kind).json") }

    /// Snapshots already on disk (from the previous run) count as written: an unchanged one is not
    /// rewritten, and the first flush still reloads it.
    private func seedFromDisk() {
        for spec in WidgetKinds.all {
            guard let data = try? Data(contentsOf: url(kind: spec.kind)),
                  let snapshot = try? WidgetSnapshot.decoder.decode(WidgetSnapshot.self, from: data) else { continue }
            written[spec.kind] = snapshot.contentHash
            governor.seed(spec.kind, content: snapshot.contentHash, syncedAt: Self.shownSyncedAt(snapshot))
        }
    }

    // MARK: - Publishing

    /// Every kind. Returns the kinds whose file changed.
    @discardableResult
    func publishAll(reason: PublishReason) -> [String] {
        // Before the lock: a Keychain read (≤ 3 s, off the main thread) must not hold up a tap's publish.
        links.prepare()
        lock.lock(); defer { lock.unlock() }
        guard let ctx = context(.all) else { return [] }
        var changed: [String] = []
        for spec in WidgetKinds.all {
            guard let snapshot = snapshot(kind: spec.kind, context: ctx) else { continue }
            if write(snapshot, reason: reason) { changed.append(spec.kind) }
        }
        return changed
    }

    /// The kinds showing mail (Inbox, Agenda & Inbox, custom slots set to either). Returns the kinds
    /// whose file changed.
    @discardableResult
    func publishMail(reason: PublishReason) -> [String] {
        links.prepare()
        lock.lock(); defer { lock.unlock() }
        guard let ctx = context(.mail) else { return [] }
        let repo = WidgetRepo(db: db)
        var changed: [String] = []
        for spec in WidgetKinds.all {
            let settings = WidgetSettingsCodec.settings(from: try? repo.settings(kind: spec.kind), kind: spec.kind)
            guard let base = baseContent(spec, settings), base == .inbox || base == .combo,
                  let snapshot = snapshot(kind: spec.kind, context: ctx) else { continue }
            if write(snapshot, reason: reason) { changed.append(spec.kind) }
        }
        return changed
    }

    /// One kind (route state change, Studio save). Returns whether its file changed.
    @discardableResult
    func publish(kind: String, reason: PublishReason) -> Bool {
        links.prepare()
        lock.lock(); defer { lock.unlock() }
        guard let ctx = context(.none), let snapshot = snapshot(kind: kind, context: ctx) else { return false }
        return write(snapshot, reason: reason)
    }

    /// Drops the cached store data: the next publish reads everything again.
    func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// The data snapshots are built from, read from the store as `refresh` asks (see `Refresh`).
    func context(_ refresh: Refresh = .all) -> Context? {
        lock.lock(); defer { lock.unlock() }
        let current = now()
        let cal = calendar()
        let window = SyncWindow.current(now: current, calendar: cal)
        let labs = labsMail()
        let day = cal.startOfDay(for: current)
        let generations = db.generations   // read before loading: a write meanwhile invalidates next time
        if refresh != .all, var c = cached, c.day == day, c.labsMail == labs, c.generations.calendar == generations.calendar,
           current >= c.builtAt, current.timeIntervalSince(c.builtAt) < Self.cacheLifetime {
            let undoClosed = c.mail?.undoExpiry.map { current >= $0 } ?? false
            if refresh == .mail || c.generations.mail != generations.mail || undoClosed {
                c.mail = labs ? mailContext(c.accounts, now: current) : nil
                c.generations.mail = generations.mail
                cached = c
            }
            return Context(now: current, cal: cal, window: window, accounts: c.accounts, rows: c.rows,
                           lastSuccess: c.lastSuccess, labsMail: labs, assembler: c.assembler, mail: c.mail, memo: c.memo)
        }
        guard let ctx = loadContext(now: current, cal: cal, window: window, labs: labs) else { cached = nil; return nil }
        cached = CachedData(day: day, builtAt: current, generations: generations, labsMail: labs, accounts: ctx.accounts,
                            rows: ctx.rows, lastSuccess: ctx.lastSuccess, assembler: ctx.assembler, mail: ctx.mail, memo: ctx.memo)
        return ctx
    }

    private func loadContext(now current: Date, cal: Calendar, window: SyncWindow, labs: Bool) -> Context? {
        guard let accounts = try? AccountRepo(db: db).all() else { return nil }
        let calendars = (try? CalendarRepo(db: db).all()) ?? []
        let enabled = Set(accounts.filter(\.calendarEnabled).map(\.id))
        let margin: TimeInterval = 2 * 86_400
        let rows = (try? EventRepo(db: db).overlapping(from: window.start.addingTimeInterval(-margin),
                                                       to: window.end.addingTimeInterval(margin),
                                                       accountIds: enabled)) ?? []
        let status = SyncStatusRepo(db: db)
        var last: [UUID: Date] = [:]
        for account in accounts { last[account.id] = status.lastSuccess(account.id) }
        return Context(now: current, cal: cal, window: window, accounts: accounts, rows: rows, lastSuccess: last,
                       labsMail: labs, assembler: CalendarAssembler(accounts: accounts, calendars: calendars),
                       mail: labs ? mailContext(accounts, now: current) : nil)
    }

    func mailContext(_ accounts: [AccountRecord], now: Date) -> MailContext {
        let repo = MailRepo(db: db)
        let removed = (try? ActionRepo(db: db).removedFromInbox(now: now)) ?? [:]
        let removedRows = (try? repo.threads(r: Array(removed.keys)))?.filter { !$0.inInbox } ?? []
        var threads: [UUID: [MailThreadRecord]] = [:]
        var unread: [UUID: Int] = [:]
        var lastSync: [UUID: Date] = [:]
        for account in accounts where account.mailEnabled && account.provider == Provider.google.rawValue {
            let inbox = (try? repo.inbox(accountIds: [account.id], limit: WidgetSnapshot.maxMail)) ?? []
            threads[account.id] = inbox + removedRows.filter { $0.accountId == account.id }
            let state = (try? repo.state(accountId: account.id)) ?? MailStateRecord()
            let primaryOnly = MailDefaults.prefs(db: db, accountId: account.id).primaryOnly
            if !primaryOnly, let count = state.unreadInbox {
                unread[account.id] = count
            } else {
                unread[account.id] = (try? repo.counts(accountId: account.id).unread) ?? 0
            }
            if let at = state.lastSyncAt { lastSync[account.id] = at }
        }
        let expiry = removed.isEmpty ? nil : ((try? ActionRepo(db: db).nextUndoExpiry(now: now)) ?? nil)
        return MailContext(threads: threads, removed: removed, unread: unread, lastSync: lastSync, undoExpiry: expiry)
    }

    // MARK: - Building

    func snapshot(kind: String, context ctx: Context) -> WidgetSnapshot? {
        guard let spec = WidgetKinds.spec(kind) else { return nil }
        let repo = WidgetRepo(db: db)
        let settings = WidgetSettingsCodec.settings(from: try? repo.settings(kind: kind), kind: kind)
        let base = baseContent(spec, settings)
        let shown: WidgetSnapshot.Content = {
            guard let base else { return .setup }
            if (base == .inbox || base == .combo) && !ctx.labsMail { return .mailComingSoon }
            return base
        }()

        let today = ctx.cal.startOfDay(for: ctx.now)
        let states = (try? repo.states(kind: kind)) ?? []
        let kindState = states.first { $0.family == WidgetStateRow.kindLevel && ($0.stateSetAt ?? .distantPast) >= today }
        let rangeDays = WidgetSettingsCodec.coerceRange(kindState?.rangeDays ?? settings.rangeDays)
        let keys = ctx.window.dayKeys(ctx.cal)

        let accounts = included(settings: settings, base: base, accounts: ctx.accounts)
        let calendarAccounts = Set(accounts.filter(\.calendarEnabled).map(\.id))

        // Month and Day: the picked day (a tap today, inside the window; midnight resets it). Month only:
        // the month shown.
        var selectedDay: String?
        var monthShown: String?
        if base == .month || base == .day, let state = kindState {
            if let day = state.selectedDay, let date = DayKey.date(day, ctx.cal), ctx.window.contains(date) {
                selectedDay = day
            }
            if base == .month, let month = state.monthShown, let first = DayKey.monthStart(month, ctx.cal),
               first < ctx.window.end, first >= ctx.cal.dateInterval(of: .month, for: ctx.now)?.start ?? first {
                monthShown = month
            }
        }

        var meetings: [WidgetSnapshot.Meeting] = []
        var busyDays: [String] = []
        if let base, base != .inbox {
            let events = ctx.events(included: calendarAccounts)
            let from: Date
            let to: Date
            if base == .month {
                let pick = selectedDay.flatMap { DayKey.date($0, ctx.cal) } ?? today
                from = max(pick, ctx.window.start)
                to = ctx.window.end
                busyDays = ctx.busyDays(included: calendarAccounts)
            } else if base == .day {
                // The day shown, midnight to midnight (meetings overlapping it, all-day ones included).
                from = selectedDay.flatMap { DayKey.date($0, ctx.cal) } ?? today
                to = ctx.cal.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86_400)
            } else {
                from = today
                to = ctx.cal.date(byAdding: .day, value: rangeDays, to: today) ?? today.addingTimeInterval(Double(rangeDays) * 86_400)
            }
            meetings = events
                .filter { $0.start < to && max($0.end, $0.start.addingTimeInterval(1)) > from }
                .prefix(Self.maxMeetings)
                .map(meeting)
        }

        let pageRows = states.filter {
            $0.family != WidgetStateRow.kindLevel && $0.page > 1
                && ($0.pageSetAt.map { ctx.now.timeIntervalSince($0) < timing.pageReset } ?? false)
        }
        var pages: [String: Int] = [:]
        for row in pageRows { pages[row.family] = row.page }
        let pageResetAt = pageRows.compactMap(\.pageSetAt).max()?.addingTimeInterval(timing.pageReset)

        var mail: [WidgetSnapshot.Mail] = []
        var unreadCount: Int?
        let mailShown = (shown == .inbox || shown == .combo) && ctx.mail != nil
        if mailShown, let box = ctx.mail {
            let mailAccounts: [AccountRecord] = accounts.filter { $0.mailEnabled && $0.provider == Provider.google.rawValue }
            var rows: [MailThreadRecord] = []
            for account in mailAccounts { rows += box.threads[account.id] ?? [] }
            rows.sort(by: Self.newestFirst)
            for row in rows.prefix(WidgetSnapshot.maxMail) {
                let archivedAt: Date? = row.inInbox ? nil : box.removed[row.r]
                mail.append(mailRow(row, archivedAt: archivedAt))
            }
            var unread = 0
            for account in mailAccounts { unread += box.unread[account.id] ?? 0 }
            unreadCount = unread
        }

        return WidgetSnapshot(
            kind: kind, generatedAt: ctx.now, content: shown,
            title: WidgetSettingsCodec.isCustom(kind) ? settings.title : nil,
            style: settings.style,
            accounts: accounts.map(snapshotAccount),
            health: health(accounts, ctx, calendar: !(base == .inbox && mailShown), mail: mailShown),
            meetings: meetings, mail: mail, unreadCount: unreadCount,
            pages: pages, pageResetAt: pageResetAt,
            selectedDay: selectedDay, monthShown: monthShown,
            busyDays: busyDays, windowStart: keys.first, windowEnd: keys.last, rangeDays: rangeDays)
    }

    /// What the kind shows, before the mail switch; nil = a custom slot not set up yet.
    func baseContent(_ spec: WidgetKindSpec, _ settings: WidgetSettings) -> WidgetSnapshot.Content? {
        switch spec.content {
        case .agenda: return .agenda
        case .upNext: return .upNext
        case .month: return .month
        case .inbox: return .inbox
        case .combo: return .combo
        case .day: return .day
        case .custom: return settings.customContent
        }
    }

    /// The widget's accounts in the user's order: its own pick, or every account marked "Include in
    /// All"; calendar kinds keep accounts with calendar on, Inbox those with mail on.
    func included(settings: WidgetSettings, base: WidgetSnapshot.Content?, accounts: [AccountRecord]) -> [AccountRecord] {
        let picked: [AccountRecord]
        if let ids = settings.accountIds {
            let wanted = Set(ids)
            picked = accounts.filter { wanted.contains($0.id) }
        } else {
            picked = accounts.filter(\.includeInAll)
        }
        switch base {
        case .inbox?: return picked.filter(\.mailEnabled)
        case .combo?: return picked.filter { $0.mailEnabled || $0.calendarEnabled }
        case .agenda?, .upNext?, .month?, .day?: return picked.filter(\.calendarEnabled)
        default: return picked
        }
    }

    func snapshotAccount(_ a: AccountRecord) -> WidgetSnapshot.Account {
        let logo = logos.appendingPathComponent("\(a.id.uuidString).png")
        return WidgetSnapshot.Account(id: a.id.uuidString, tag: a.tag, name: a.displayName, color: Int(a.color),
                                      hasLogo: FileManager.default.fileExists(atPath: logo.path))
    }

    static func newestFirst(_ a: MailThreadRecord, _ b: MailThreadRecord) -> Bool {
        a.lastAt != b.lastAt ? a.lastAt > b.lastAt : a.r < b.r
    }

    func mailRow(_ t: MailThreadRecord, archivedAt: Date?) -> WidgetSnapshot.Mail {
        let sender = t.senderName.isEmpty ? t.senderEmail : t.senderName
        let subject = t.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return WidgetSnapshot.Mail(r: t.r, k: links.k(for: t.r), accountId: t.accountId.uuidString,
                                   sender: Self.clip(sender.isEmpty ? "(unknown sender)" : sender),
                                   subject: Self.clip(subject.isEmpty ? "(no subject)" : subject), at: t.lastAt,
                                   unread: t.unread, starred: t.starred, archivedAt: archivedAt)
    }

    /// noAccounts > reauth (first account needing a sign-in, with its link key) > stale (an account's
    /// last good sync is missing or older than 15 minutes) > ok. `syncedAt` = the oldest good sync.
    /// Calendar kinds look at calendar syncs, Inbox at mail syncs, Agenda & Inbox at both.
    func health(_ accounts: [AccountRecord], _ ctx: Context, calendar: Bool = true, mail: Bool = false) -> WidgetSnapshot.Health {
        guard !accounts.isEmpty else { return WidgetSnapshot.Health(state: .noAccounts) }
        let google = accounts.filter { $0.provider == Provider.google.rawValue }
        let calendarSynced = calendar ? google.filter(\.calendarEnabled) : []
        let mailSynced = mail ? google.filter(\.mailEnabled) : []
        let synced = calendarSynced + mailSynced
        let times = calendarSynced.compactMap { ctx.lastSuccess[$0.id] } + mailSynced.compactMap { ctx.mail?.lastSync[$0.id] }
        let oldest = times.min()
        if let account = accounts.first(where: { $0.health == .reauthNeeded }) {
            let id = account.id.uuidString
            return WidgetSnapshot.Health(state: .reauth, accountId: id, k: links.k(for: id), syncedAt: oldest)
        }
        guard !synced.isEmpty else { return WidgetSnapshot.Health(state: .ok) }
        if times.count < synced.count || (oldest.map { ctx.now.timeIntervalSince($0) > timing.staleAfter } ?? true) {
            return WidgetSnapshot.Health(state: .stale, syncedAt: oldest)
        }
        return WidgetSnapshot.Health(state: .ok, syncedAt: oldest)
    }

    func meeting(_ e: CalendarEvent) -> WidgetSnapshot.Meeting {
        let reply: WidgetSnapshot.Meeting.Reply
        switch e.myResponse {
        case .tentative: reply = .maybe
        case .needsAction: reply = .needsReply
        default: reply = .accepted
        }
        let recorder = Self.recorderKind(e.accountIds, e.joinURL != nil)
        return WidgetSnapshot.Meeting(r: e.r, k: links.k(for: e.r), accountIds: e.accountIds.map(\.uuidString),
                                      title: Self.clip(e.title), start: e.start, end: e.end, allDay: e.allDay,
                                      place: Self.place(e.location), hasJoin: e.joinURL != nil, reply: reply,
                                      clashes: e.clashes, rec: recorder != nil ? true : nil,
                                      recBy: recorder == nil || recorder == "fathom" ? nil : recorder)
    }

    /// A location that is only a link (a Zoom URL pasted as the place) is left out: Join covers it,
    /// and the snapshot carries no URLs.
    static func place(_ location: String?) -> String? {
        guard let text = location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if (lower.hasPrefix("https://") || lower.hasPrefix("http://")) && !text.contains(" ") { return nil }
        return clip(text)
    }

    static func clip(_ text: String) -> String {
        text.count <= maxTextLength ? text : String(text.prefix(maxTextLength - 1)) + "\u{2026}"
    }

    /// Days inside the window with at least one meeting (multi-day events mark every day they cover).
    static func busyDays(_ events: [CalendarEvent], window: SyncWindow, cal: Calendar) -> [String] {
        var days = Set<String>()
        for e in events {
            let first = max(e.start, window.start)
            let last = min(max(e.end.addingTimeInterval(-1), e.start), window.end.addingTimeInterval(-1))
            guard first <= last else { continue }
            var day = cal.startOfDay(for: first)
            var guardCount = 0
            while day <= last && guardCount < 100 {
                days.insert(DayKey.string(day, cal))
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = cal.startOfDay(for: next)
                guardCount += 1
            }
        }
        return days.sorted()
    }

    // MARK: - Writing

    /// Hash without the sync time while healthy: a new "synced at" alone is written but never spends
    /// the background reload budget.
    static func significantHash(_ snapshot: WidgetSnapshot) -> UInt64 {
        var copy = snapshot
        if copy.health.state == .ok { copy.health.syncedAt = nil }
        return copy.contentHash
    }

    /// The sync time the widget can show ("Last synced …"), for the governor's keep-alive: nil for the
    /// whole-card states, which draw no strip (a set-up slot doesn't need its sync time kept fresh).
    static func shownSyncedAt(_ snapshot: WidgetSnapshot) -> Date? {
        switch snapshot.content {
        case .setup, .mailComingSoon: return nil
        default: return snapshot.health.state == .noAccounts ? nil : snapshot.health.syncedAt
        }
    }

    /// Encodes within 192 KB (dropping meetings from the end if needed), writes only when the content
    /// hash changed, then informs the governor. Returns whether the file changed.
    @discardableResult
    func write(_ snapshot: WidgetSnapshot, reason: PublishReason) -> Bool {
        var snap = snapshot
        guard var data = try? WidgetSnapshot.encoder.encode(snap) else { return false }
        while data.count > WidgetSnapshot.maxBytes, !snap.meetings.isEmpty || !snap.mail.isEmpty {
            if !snap.meetings.isEmpty {
                snap.meetings.removeLast(max(1, snap.meetings.count / 10))
            } else {
                snap.mail.removeLast(max(1, snap.mail.count / 10))
            }
            guard let smaller = try? WidgetSnapshot.encoder.encode(snap) else { return false }
            data = smaller
        }
        let hash = snap.contentHash
        if written[snap.kind] == hash {
            if reason == .interaction { governor.reloadIfChanged(snap.kind) }
            return false
        }
        do {
            try Self.atomicWrite(data, to: url(kind: snap.kind))
        } catch {
            trace("snapshot-write", "\(snap.kind):failed")
            return false
        }
        written[snap.kind] = hash
        // The sync time is only cut from the significant hash while healthy; otherwise they are equal.
        let significant = snap.health.state == .ok && snap.health.syncedAt != nil ? Self.significantHash(snap) : hash
        governor.changed(snap.kind, content: hash, significant: significant, syncedAt: Self.shownSyncedAt(snap),
                         interaction: reason == .interaction)
        return true
    }

    /// Temp file (0600) in the same folder, then rename(2): readers see the old file or the new one.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
