import SwiftUI

/// A `Link` in the widget; just its label in the app's gallery and in headless renders, where
/// `ImageRenderer` would draw a `Link` as a placeholder box and a click would open our own scheme.
struct WidgetLink<Label: View>: View {
    @Environment(\.plainLinks) private var plainLinks
    let destination: URL
    @ViewBuilder let label: () -> Label

    var body: some View {
        if plainLinks {
            label()
        } else {
            Link(destination: destination, label: label)
        }
    }
}

/// Which widget a view sits in, so leaf views can build their own links (docs/CONTRACTS.md routes).
/// Snapshot rows carry `r` + `k` and link to `open/event` / `join`; sample rows (gallery previews) have
/// neither and keep pinging, so a stray tap on a preview never reaches a handler with a fake id.
struct WidgetLinkContext {
    var kind = "preview"
    var family: Family = .large
    /// Sync window (`YYYY-MM-DD` bounds from the snapshot): Month arrows never leave it.
    var windowStart: Date? = nil
    var windowEnd: Date? = nil

    func page(_ to: Int) -> URL { YayaLink.page(kind: kind, family: family.short, to: to) }
    /// `ping?probe=<kind>.<fam>.<element>.<n>`: no PII, just which element was tapped.
    func probe(_ element: String, _ n: Int) -> URL { YayaLink.ping("\(kind).\(family.short).\(element).\(n)") }
    func open(_ section: AppSection) -> URL { YayaLink.openApp(section) }
    /// The ↻ glyph → `sync?w=<kind>`: re-list this widget's calendars (and mail), then reload it.
    func refresh() -> URL { YayaLink.sync(kind: kind) }

    /// Row tap → Event Peek.
    func event(_ meeting: WidgetMeeting) -> URL {
        guard let key = Self.keyed(meeting.r, meeting.k) else { return probe("row", meeting.id) }
        return YayaLink.openEvent(r: key.r, k: key.k)
    }

    /// The Join chip → straight into the call (the agent re-checks the link's host).
    func join(_ meeting: WidgetMeeting) -> URL {
        guard let key = Self.keyed(meeting.r, meeting.k) else { return probe("join", meeting.id) }
        return YayaLink.join(r: key.r, k: key.k)
    }

    /// "Reply?" chip → Event Peek, where Yes / Maybe / No live.
    func reply(_ meeting: WidgetMeeting) -> URL { event(meeting) }

    /// Mail row tap → Mail Peek (`open/message?r&k`). Sample rows (no r/k) keep pinging.
    func mail(_ mail: WidgetMail) -> URL {
        guard let key = Self.keyed(mail.r, mail.k) else { return probe("mail", mail.id) }
        return YayaLink.openMessage(r: key.r, k: key.k)
    }

    /// The unread dot → mark read (`mail/read?r&k`), quietly.
    func mailRead(_ mail: WidgetMail) -> URL {
        guard let key = Self.keyed(mail.r, mail.k) else { return probe("mailread", mail.id) }
        return YayaLink.mailRead(r: key.r, k: key.k)
    }

    /// The archive glyph → archive (`mail/archive?r&k`); the row then reads "Archived · Undo" for 30 s.
    func mailArchive(_ mail: WidgetMail) -> URL {
        guard let key = Self.keyed(mail.r, mail.k) else { return probe("archive", mail.id) }
        return YayaLink.mailArchive(r: key.r, k: key.k)
    }

    /// "Archived · Undo" → `mail/undo?r&k` (reverses the archive within 30 s).
    func mailUndo(_ mail: WidgetMail) -> URL {
        guard let key = Self.keyed(mail.r, mail.k) else { return probe("undo", mail.id) }
        return YayaLink.mailUndo(r: key.r, k: key.k)
    }

    /// Month arrows: nil (arrow disabled) when the month lies outside the sync window.
    func month(_ date: Date) -> URL? {
        guard monthInWindow(date) else { return nil }
        return YayaLink.month(kind: kind, to: DayName.linkMonth(date))
    }

    func monthInWindow(_ date: Date) -> Bool {
        let cal = WidgetCalendar.current
        guard let target = cal.dateInterval(of: .month, for: date)?.start else { return false }
        if let windowStart, let first = cal.dateInterval(of: .month, for: windowStart)?.start, target < first { return false }
        if let windowEnd, let last = cal.dateInterval(of: .month, for: windowEnd)?.start, target > last { return false }
        return true
    }

    /// Month day cells pick the day in place; Small has no room to list it, so its tap opens a Day Peek.
    func day(_ date: Date) -> URL {
        if family == .small { return YayaLink.openDay(kind: kind, day: DayName.linkDay(date)) }
        return YayaLink.day(kind: kind, day: DayName.linkDay(date))
    }

    /// Day widget ‹ ›: `day?w&d` (quiet: the app picks that day and republishes); nil (arrow disabled)
    /// outside the sync window, whose meetings the app doesn't have.
    func selectDay(_ date: Date) -> URL? {
        guard dayInWindow(date) else { return nil }
        return YayaLink.day(kind: kind, day: DayName.linkDay(date))
    }

    /// Back to today from another day (the header date and the "Today" chip).
    func today(_ now: Date) -> URL { YayaLink.day(kind: kind, day: DayName.linkDay(now)) }

    /// Day widget "+N" and empty grid → the Day Peek for that day (`open/day?w&d`).
    func openDay(_ date: Date) -> URL { YayaLink.openDay(kind: kind, day: DayName.linkDay(date)) }

    /// Inside the snapshot's window (whole days); no window (sample data) = unbounded.
    func dayInWindow(_ date: Date) -> Bool {
        let cal = WidgetCalendar.current
        let day = cal.startOfDay(for: date)
        if let windowStart, day < cal.startOfDay(for: windowStart) { return false }
        if let windowEnd, day > cal.startOfDay(for: windowEnd) { return false }
        return true
    }

    /// Both values present and link-safe (Route.isSafeValue), else nil.
    static func keyed(_ r: String?, _ k: String?) -> (r: String, k: String)? {
        guard let r, let k, Route.isSafeValue(r), Route.isSafeValue(k) else { return nil }
        return (r, k)
    }
}

/// Link builders (kept beside the widget code; Shared/Routes.swift holds the table and the app-level ones).
extension YayaLink {
    static func join(r: String, k: String) -> URL { url("join", [("r", r), ("k", k)]) }
    static func openEvent(r: String, k: String) -> URL { url("open/event", [("r", r), ("k", k)]) }
    /// `v`: yes | maybe | no.
    static func rsvp(r: String, k: String, v: String) -> URL { url("rsvp", [("r", r), ("k", k), ("v", v)]) }
    static func reauth(a: String, k: String) -> URL { url("reauth", [("a", a), ("k", k)]) }
    static func range(kind: String, days: Int) -> URL { url("range", [("w", kind), ("v", "\(days)")]) }
    /// `sync` alone syncs every account; `sync?w=<kind>` is a widget's ↻ (that widget's accounts, a full
    /// re-list, then that widget reloads).
    static func sync(kind: String? = nil) -> URL { url("sync", kind.map { [("w", $0)] } ?? []) }

    // Mail routes (CONTRACTS "URL routes").
    static func openMessage(r: String, k: String) -> URL { url("open/message", [("r", r), ("k", k)]) }
    static func mailRead(r: String, k: String) -> URL { url("mail/read", [("r", r), ("k", k)]) }
    static func mailArchive(r: String, k: String) -> URL { url("mail/archive", [("r", r), ("k", k)]) }
    static func mailUndo(r: String, k: String) -> URL { url("mail/undo", [("r", r), ("k", k)]) }
    static func mailStar(r: String, k: String) -> URL { url("mail/star", [("r", r), ("k", k)]) }
}

/// CONTRACTS "Mail": an archive or trash can be undone for 30 s (`mail/undo`, the app's toasts).
enum MailUndo {
    static let window: TimeInterval = 30
}

private struct PlainLinksKey: EnvironmentKey { static let defaultValue = false }
private struct WidgetLinkContextKey: EnvironmentKey { static let defaultValue = WidgetLinkContext() }
private struct WidgetMonoKey: EnvironmentKey { static let defaultValue = false }
private struct WidgetTitleKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct WidgetJustSyncedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    // Written by hand: the `@Entry` macro needs Xcode's SwiftUI macro plugin.
    var plainLinks: Bool {
        get { self[PlainLinksKey.self] }
        set { self[PlainLinksKey.self] = newValue }
    }

    var widgetLinks: WidgetLinkContext {
        get { self[WidgetLinkContextKey.self] }
        set { self[WidgetLinkContextKey.self] = newValue }
    }

    /// True when the system draws the widget accented or vibrant (the extension maps
    /// `widgetRenderingMode` onto it; renders set it directly). KindView switches to the mono palette.
    var widgetMono: Bool {
        get { self[WidgetMonoKey.self] }
        set { self[WidgetMonoKey.self] = newValue }
    }

    /// Custom slot name ("Work"), shown in headers.
    var widgetTitle: String? {
        get { self[WidgetTitleKey.self] }
        set { self[WidgetTitleKey.self] = newValue }
    }

    /// The entry falls within `WidgetHealthInfo.justSyncedWindow` of a good sync: ↻ reads ✓.
    var widgetJustSynced: Bool {
        get { self[WidgetJustSyncedKey.self] }
        set { self[WidgetJustSyncedKey.self] = newValue }
    }
}
