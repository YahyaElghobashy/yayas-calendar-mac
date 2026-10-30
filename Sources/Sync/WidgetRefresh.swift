import Foundation

/// A widget's ↻ (`yayacal://sync?w=<kind>`, docs/CONTRACTS.md). Meetings get cancelled and moved, and
/// the user wants to see it now, so a refresh:
///
/// 1. finds the accounts the tapped widget shows (its Studio pick, or every "Include in All" account;
///    calendar kinds the ones with calendar on, Inbox the ones with mail on, Agenda & Inbox both);
/// 2. runs a **forced** calendar pass for each (through its loop, so passes never overlap): the
///    calendar list, then every selected calendar's window listed in full and replaced in one
///    transaction, so a cancelled meeting leaves the store even if a change-feed pass missed it;
/// 3. runs an incremental mail pass (history) for each mail account of Inbox / Agenda & Inbox, with that
///    account's Gmail quota bucket;
/// 4. leaves the republish of every kind to those passes (as any pass does) and the tapped kind's
///    reload to `finishRefresh`, which the router calls on the main thread while the agent is active.
///
/// Quotas: an account whose loop is sleeping off a 429 / 5xx backoff is left alone (a refresh never cuts
/// a server backoff short, unlike "Sync now"); a refresh joins a pass already due instead of adding one;
/// the router ignores a second ↻ on the same kind within 5 s.
struct WidgetRefreshReport: Equatable, Sendable {
    var kinds: [String] = []
    var calendarAccounts = 0
    var mailAccounts = 0
    /// Accounts left alone because Google asked us to back off.
    var backingOff = 0
    /// Short PII-free outcome codes of the passes ("ok", "offline", …), sorted.
    var outcomes: [String] = []

    var ok: Bool { outcomes.allSatisfy { $0 == "ok" || $0 == "skipped" } }

    /// "ok", or the first other outcome ("offline"), plus counts: for `refresh-done` traces.
    var traceResult: String {
        let first = outcomes.first { $0 != "ok" && $0 != "skipped" } ?? "ok"
        return "\(first) cal=\(calendarAccounts) mail=\(mailAccounts) backoff=\(backingOff)"
    }
}

/// When each kind's latest refresh began, so `finishRefresh` reloads it once (unless a reload already
/// went out after that moment).
final class RefreshLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String: Date] = [:]

    func begin(_ kinds: [String], at date: Date) {
        lock.lock(); defer { lock.unlock() }
        for kind in kinds { started[kind] = date }
    }

    func start(of kind: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return started[kind]
    }
}

extension DataEngine {
    /// The accounts a kind shows: calendar passes and mail passes (empty for a slot not set up yet).
    func refreshTargets(kind: String) -> (calendar: Set<UUID>, mail: Set<UUID>) {
        guard let spec = WidgetKinds.spec(kind) else { return ([], []) }
        let settings = WidgetSettingsCodec.settings(from: try? WidgetRepo(db: db).settings(kind: kind), kind: kind)
        // The Daily Digest (D-053) shows the helper's files, not Google: its ↻ runs no pass (the router re-reads them).
        guard let base = publisher.baseContent(spec, settings), base != .digest else { return ([], []) }
        let accounts = (try? AccountRepo(db: db).all()) ?? []
        let google = publisher.included(settings: settings, base: base, accounts: accounts)
            .filter { $0.provider == Provider.google.rawValue }
        let calendar = base == .inbox ? [] : Set(google.filter(\.calendarEnabled).map(\.id))
        let mail = (base == .inbox || base == .combo) && env.labsMail() ? Set(google.filter(\.mailEnabled).map(\.id)) : []
        return (calendar, mail)
    }

    /// Steps 1–3 above for every kind in `kinds` (each account once). Never throws; returns when every
    /// calendar pass has finished (mail keeps going behind it), or after mail for an Inbox-only kind.
    func refreshWidgets(_ kinds: [String]) async -> WidgetRefreshReport {
        let known = kinds.filter { WidgetKinds.spec($0) != nil }
        refreshes.begin(known, at: env.now())
        var calendarIds = Set<UUID>()
        var mailIds = Set<UUID>()
        for kind in known {
            let targets = refreshTargets(kind: kind)
            calendarIds.formUnion(targets.calendar)
            mailIds.formUnion(targets.mail)
        }
        env.trace("widget-refresh", "start kinds=\(known.joined(separator: ",")) cal=\(calendarIds.count) mail=\(mailIds.count)")
        // Calendars first: cancelled and moved meetings are why people tap ↻, so the reload (and the
        // hand-back) waits only for them. Mail runs behind it and republishes when it lands; a slow or
        // rate-limited inbox never holds the widget dimmed. Inbox-only kinds have no calendar pass, so
        // they wait for mail.
        let calendar = await withTaskGroup(of: SyncOutcome?.self) { group -> [SyncOutcome?] in
            for id in calendarIds { group.addTask { await self.refreshCalendar(id) } }
            var all: [SyncOutcome?] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        let mailWork = Task { () -> [SyncOutcome?] in
            await withTaskGroup(of: SyncOutcome?.self) { group -> [SyncOutcome?] in
                for id in mailIds { group.addTask { await self.refreshMail(id) } }
                var all: [SyncOutcome?] = []
                for await outcome in group { all.append(outcome) }
                return all
            }
        }
        var results = calendar
        if calendarIds.isEmpty {
            results += await mailWork.value
        } else if !mailIds.isEmpty {
            Task {
                let mail = await mailWork.value
                let codes = mail.compactMap { $0?.code }.filter { $0 != "ok" && $0 != "skipped" }
                self.env.trace("widget-refresh", "mail-done kinds=\(known.joined(separator: ",")) result=\(codes.first ?? "ok")")
            }
        }
        let report = WidgetRefreshReport(kinds: known, calendarAccounts: calendarIds.count, mailAccounts: mailIds.count,
                                         backingOff: results.filter { $0 == nil }.count,
                                         outcomes: results.compactMap { $0?.code }.sorted())
        env.trace("widget-refresh", "done \(report.traceResult)")
        return report
    }

    /// A forced pass (full window re-list) for one account; nil when its loop is backing off.
    func refreshCalendar(_ id: UUID) async -> SyncOutcome? {
        if let loop = loop(id), await loop.isRunning {
            guard await loop.refreshNow() else { return nil }
            return await loop.lastOutcome
        }
        return await syncAccount(id, force: true)
    }

    /// An incremental mail pass (the mail loop ignores `force`); nil when its loop is backing off.
    /// An inbox that finished a healthy pass in the last 30 s is fresh enough: another history call
    /// right away only spends Gmail quota (two quick taps hit 429s live, 2026-10-26).
    func refreshMail(_ id: UUID) async -> SyncOutcome? {
        if let loop = mailLoop(id), await loop.isRunning {
            if await loop.lastOutcome == .ok, let last = await loop.lastRunAt,
               env.now().timeIntervalSince(last) < 30 { return .skipped }
            guard await loop.refreshNow() else { return nil }
            return await loop.lastOutcome
        }
        return await syncMail(id)
    }

    /// Step 4, for each tapped kind: republish it (the passes' data is cached by now, so this is the
    /// cheap tap path) and reload it, unless a reload already went out since its refresh began (a
    /// changed snapshot reloads through `publish` itself). On the main thread in the app, while the
    /// link still has the agent active: the reload is free and unthrottled.
    func finishRefresh(_ kinds: [String]) {
        for kind in kinds where WidgetKinds.spec(kind) != nil {
            publisher.publish(kind: kind, reason: .interaction)
            governor.reload(kind, unlessSince: refreshes.start(of: kind))
        }
    }
}

extension DataServices {
    /// The router's ↻ (off the main thread). A cold launch by the tap itself waits for the engine to
    /// start (at most 4 s); nil when it never does.
    static func refreshWidgets(_ kinds: [String]) async -> WidgetRefreshReport? {
        var waited: TimeInterval = 0
        while engine == nil && waited < 4 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        guard let engine else { return nil }
        return await engine.refreshWidgets(kinds)
    }

    /// The router's last step of a ↻, on the main thread while the agent is active.
    static func finishRefresh(_ kinds: [String]) {
        engine?.finishRefresh(kinds)
    }
}
