import Foundation

/// Asks WidgetKit to reload a kind's timeline. `WidgetKitReloader` in the app; a recorder in tests
/// (so the data layer builds and tests without WidgetKit).
protocol TimelineReloader: AnyObject, Sendable {
    func reloadTimelines(ofKind kind: String)
}

/// Decides when a changed snapshot is worth a timeline reload (measured: macOS honours background reloads
/// unevenly, Large 89 % / XL 33 % at one request per 5 minutes).
///
/// - Background changes reload a kind at most once per `budget` (15 minutes); a change inside the
///   budget waits and goes out when the budget reopens (`tick`). Only *significant* changes count: a
///   new "synced at" time alone never spends the budget — until the widget's copy of it is
///   `keepAlive` (24 minutes) old, so "Last synced …" (30 minutes after the widget's syncedAt) never
///   shows while the app keeps syncing. 24 minutes, not less: the keep-alive alone may then cost a
///   placed kind at most 60 reloads a day (the soft cap D-019 sets;
///   WidgetKit gives a frequently viewed widget 40–70), and none while taps or real changes keep its
///   copy fresh. At 10 minutes it went out every 15 (the budget): 96 a day per kind, past the budget
///   the trimmed timelines need for their own reloads at the cap and at midnight.
/// - Interactions (a widget tap, Studio) reload that kind immediately; the agent is active, so those
///   reloads are free and don't touch the background budget.
/// - `flushChanged()` (after a Link tap, the main window opening) reloads the kinds that are worth a
///   render: a significant change still waiting for its budget, a kind not reloaded yet this run, or a
///   sync time the widget holds for `keepAlive` already. A sync time alone (every sync pass moves it in
///   every snapshot) no longer reloads every kind on the first tap after a sync (D-019).
final class ReloadGovernor: @unchecked Sendable {
    struct KindState: Equatable {
        var content: UInt64?
        var significant: UInt64?
        /// The snapshot's `health.syncedAt`, and the one the widget got with its last reload.
        var syncedAt: Date?
        var reloadedContent: UInt64?
        var reloadedSignificant: UInt64?
        var reloadedSyncedAt: Date?
        var lastBackground: Date?
        /// Reloaded at least once this run (seeded kinds start false: the first flush reloads them).
        var everReloaded = false
        /// When the last reload of any kind was asked (a refresh reloads once after it began).
        var lastReload: Date?
    }

    let budget: TimeInterval
    /// How old the widget's sync time may get before a sync-time-only change is worth a reload. The
    /// strip shows at 30 minutes (`WidgetHealthInfo.staleAfter`); the 6 left cover the next sync pass,
    /// the 30 s tick and WidgetKit's own delay.
    let keepAlive: TimeInterval
    static let defaultKeepAlive: TimeInterval = 24 * 60
    private let reloader: TimelineReloader
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var kinds: [String: KindState] = [:]

    init(reloader: TimelineReloader, budget: TimeInterval = 15 * 60, keepAlive: TimeInterval = ReloadGovernor.defaultKeepAlive,
         now: @escaping @Sendable () -> Date) {
        self.reloader = reloader
        self.budget = budget
        self.keepAlive = keepAlive
        self.now = now
    }

    func state(_ kind: String) -> KindState? {
        lock.lock(); defer { lock.unlock() }
        return kinds[kind]
    }

    /// A publish wrote new content for `kind`. `syncedAt`: the snapshot's `health.syncedAt`.
    func changed(_ kind: String, content: UInt64, significant: UInt64, syncedAt: Date? = nil, interaction: Bool) {
        lock.lock()
        var s = kinds[kind] ?? KindState()
        s.content = content
        s.significant = significant
        s.syncedAt = syncedAt
        kinds[kind] = s
        lock.unlock()
        if interaction { reloadIfChanged(kind) } else { backgroundAttempt(kind) }
    }

    /// A snapshot already on disk at launch: the first interaction or flush reloads it (free), the
    /// background budget doesn't.
    /// `syncedAt`: the file's sync time, which the placed widget presumably holds (keep-alive counts from it).
    func seed(_ kind: String, content: UInt64, syncedAt: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard kinds[kind] == nil else { return }
        kinds[kind] = KindState(content: content, syncedAt: syncedAt, reloadedSyncedAt: syncedAt)
    }

    /// Interaction on `kind`: reload it if its content moved since the last reload.
    func reloadIfChanged(_ kind: String) {
        if take(kind, background: false, onlyIf: { $0.content != nil && $0.content != $0.reloadedContent }) {
            reloader.reloadTimelines(ofKind: kind)
        }
    }

    /// A widget's ↻ is done: reload `kind` now, changed or not (the user asked; the agent is active), unless
    /// a reload already went out at or after `since` (the refresh's start). Returns whether it reloaded.
    @discardableResult
    func reload(_ kind: String, unlessSince since: Date?) -> Bool {
        let current = now()
        lock.lock()
        var s = kinds[kind] ?? KindState()
        if let since, let last = s.lastReload, last >= since {
            lock.unlock()
            return false
        }
        s.reloadedContent = s.content
        s.reloadedSignificant = s.significant
        s.reloadedSyncedAt = s.syncedAt
        s.everReloaded = true
        s.lastReload = current
        kinds[kind] = s
        lock.unlock()
        reloader.reloadTimelines(ofKind: kind)
        return true
    }

    /// Every kind with a change worth a render (see the type's notes), now. Returns the kinds reloaded.
    @discardableResult
    func flushChanged() -> [String] {
        let current = now()
        let keepAlive = self.keepAlive
        var reloaded: [String] = []
        for kind in kindNames() where take(kind, background: false, onlyIf: { s in
            guard s.content != nil, s.content != s.reloadedContent else { return false }
            return !s.everReloaded || s.significant != s.reloadedSignificant || Self.syncDue(s, now: current, keepAlive: keepAlive)
        }) {
            reloader.reloadTimelines(ofKind: kind)
            reloaded.append(kind)
        }
        return reloaded
    }

    /// Only the sync time moved, and the widget's copy is `keepAlive` old.
    static func syncDue(_ s: KindState, now: Date, keepAlive: TimeInterval) -> Bool {
        guard s.content != s.reloadedContent, let held = s.reloadedSyncedAt, let latest = s.syncedAt, latest > held else { return false }
        return now.timeIntervalSince(held) >= keepAlive
    }

    /// Sends background reloads whose budget has reopened. Returns the next time one will be due.
    @discardableResult
    func tick() -> Date? {
        for kind in kindNames() { backgroundAttempt(kind) }
        return nextDue()
    }

    func nextDue() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return kinds.values.compactMap { s -> Date? in
            let syncPending = s.content != s.reloadedContent && (s.syncedAt ?? .distantPast) > (s.reloadedSyncedAt ?? .distantFuture)
            guard s.significant != s.reloadedSignificant || syncPending else { return nil }
            var due = s.lastBackground.map { $0.addingTimeInterval(budget) } ?? .distantPast
            if s.significant == s.reloadedSignificant, let held = s.reloadedSyncedAt {
                due = max(due, held.addingTimeInterval(keepAlive))
            }
            return due
        }.min()
    }

    func isPending(_ kind: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = kinds[kind] else { return false }
        return s.significant != s.reloadedSignificant
    }

    // MARK: - Internals

    private func backgroundAttempt(_ kind: String) {
        let current = now()
        let budget = self.budget
        let keepAlive = self.keepAlive
        if take(kind, background: true, onlyIf: { s in
            let significant = s.significant != nil && s.significant != s.reloadedSignificant
            guard significant || Self.syncDue(s, now: current, keepAlive: keepAlive) else { return false }
            guard let last = s.lastBackground else { return true }
            return current.timeIntervalSince(last) >= budget
        }) {
            reloader.reloadTimelines(ofKind: kind)
        }
    }

    /// Atomically checks `condition` and, when it holds, records the reload.
    private func take(_ kind: String, background: Bool, onlyIf condition: (KindState) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var s = kinds[kind], condition(s) else { return false }
        s.reloadedContent = s.content
        s.reloadedSignificant = s.significant
        s.reloadedSyncedAt = s.syncedAt
        s.everReloaded = true
        let current = now()
        s.lastReload = current
        if background { s.lastBackground = current }
        kinds[kind] = s
        return true
    }

    private func kindNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return kinds.keys.sorted()
    }
}
