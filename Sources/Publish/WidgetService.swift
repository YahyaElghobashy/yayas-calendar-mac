import Foundation

/// `WidgetSettingsStore` + `WidgetInteractions` (docs/CONTRACTS.md "App seam"). Every change updates
/// the store, republishes that kind and reloads it at once (the agent is active after a tap or in
/// Studio, so the reload is free). Bad input from a link is ignored and traced, never thrown.
final class WidgetService: WidgetSettingsStore, WidgetInteractions, @unchecked Sendable {
    static let families: Set<String> = ["S", "M", "L", "XL", "XLP"]
    static let maxPage = 50

    let repo: WidgetRepo
    let publisher: SnapshotPublisher
    let governor: ReloadGovernor
    let links: LinkTokens
    let now: @Sendable () -> Date
    let calendar: @Sendable () -> Calendar
    var trace: @Sendable (String, String) -> Void = { _, _ in }

    init(repo: WidgetRepo, publisher: SnapshotPublisher, governor: ReloadGovernor, links: LinkTokens,
         now: @escaping @Sendable () -> Date, calendar: @escaping @Sendable () -> Calendar) {
        self.repo = repo
        self.publisher = publisher
        self.governor = governor
        self.links = links
        self.now = now
        self.calendar = calendar
    }

    // MARK: - WidgetSettingsStore

    func settings(kind: String) -> WidgetSettings {
        WidgetSettingsCodec.settings(from: try? repo.settings(kind: kind), kind: kind)
    }

    func save(_ settings: WidgetSettings) throws {
        guard WidgetKinds.spec(settings.kind) != nil else { throw ServiceError(description: "unknown widget") }
        try repo.saveSettings(WidgetSettingsCodec.row(from: settings))
        publisher.publish(kind: settings.kind, reason: .interaction)
    }

    // MARK: - WidgetInteractions

    func page(kind: String, family: String, to page: Int) {
        guard known(kind), Self.families.contains(family) else { return ignore("page", kind) }
        let clamped = min(max(page, 1), Self.maxPage)
        guard (try? repo.setPage(kind: kind, family: family, page: clamped, at: now())) != nil else { return ignore("page", kind) }
        publisher.publish(kind: kind, reason: .interaction)
    }

    func selectDay(kind: String, day: String) {
        let cal = calendar()
        guard known(kind), let date = DayKey.date(day, cal),
              SyncWindow.current(now: now(), calendar: cal).contains(date) else { return ignore("day", kind) }
        guard (try? repo.setKindState(kind: kind, selectedDay: DayKey.string(date, cal), at: now())) != nil else {
            return ignore("day", kind)
        }
        publisher.publish(kind: kind, reason: .interaction)
    }

    /// Month arrows clamp to the sync window: this month … the month the window ends in.
    func showMonth(kind: String, month: String) {
        let cal = calendar()
        let current = now()
        guard known(kind), let first = DayKey.monthStart(month, cal) else { return ignore("month", kind) }
        let window = SyncWindow.current(now: current, calendar: cal)
        let thisMonth = cal.dateInterval(of: .month, for: current)?.start ?? first
        let lastMonth = cal.dateInterval(of: .month, for: window.end.addingTimeInterval(-1))?.start ?? first
        let clamped = min(max(first, thisMonth), lastMonth)
        guard (try? repo.setKindState(kind: kind, monthShown: DayKey.month(clamped, cal), at: current)) != nil else {
            return ignore("month", kind)
        }
        publisher.publish(kind: kind, reason: .interaction)
    }

    func setRange(kind: String, days: Int) {
        guard known(kind), WidgetSettingsCodec.ranges.contains(days) else { return ignore("range", kind) }
        guard (try? repo.setKindState(kind: kind, rangeDays: days, at: now())) != nil else { return ignore("range", kind) }
        publisher.publish(kind: kind, reason: .interaction)
    }

    func flushChanged() {
        governor.flushChanged()
    }

    func verify(r: String, k: String) -> Bool {
        let ok = links.verify(r: r, k: k)
        if !ok { trace("link-verify", "failed") }
        return ok
    }

    // MARK: -

    private func known(_ kind: String) -> Bool { WidgetKinds.spec(kind) != nil }

    private func ignore(_ route: String, _ kind: String) {
        trace("widget-route-ignored", "\(route):\(WidgetKinds.spec(kind) == nil ? "unknown" : kind)")
    }
}
