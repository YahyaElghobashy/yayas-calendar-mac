import Foundation

// Menu-bar logic, free of AppKit so the test binary checks all of it: which meeting the menu bar
// talks about, the status title ("Standup · 7m", "Standup · 12m left"), what ⌃⌥J does, and the
// preferences behind them. The status item, the popover and the hotkey only call into here.

// MARK: - Preferences

/// Where the menu-bar preferences live. The app uses UserDefaults; renders and tests use memory, so a
/// render never writes the user's defaults.
protocol PreferenceBag: AnyObject {
    func object(_ key: String) -> Any?
    func set(_ value: Any?, _ key: String)
}

final class DefaultsBag: PreferenceBag {
    static let shared = DefaultsBag()
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func object(_ key: String) -> Any? { defaults.object(forKey: key) }
    func set(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

final class MemoryBag: PreferenceBag {
    private(set) var values: [String: Any] = [:]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(_ key: String) -> Any? { values[key] }
    func set(_ value: Any?, _ key: String) { values[key] = value }
}

/// What the menu bar shows beside the icon (Settings → "Menu bar shows").
enum MenuBarMode: String, CaseIterable {
    case icon, next, unread

    var title: String {
        switch self {
        case .icon: return "Icon only"
        case .next: return "Next meeting"
        case .unread: return "Unread count"
        }
    }
}

enum MenuBarPrefs {
    static let modeKey = "menuBar.shows"
    static let hotkeyKey = "hotkey.join.enabled"
    /// Posted (default center) when a menu-bar preference changes; the status item redraws, the hotkey
    /// registers or unregisters.
    static let changed = Notification.Name("YCMenuBarPrefsChanged")

    /// Default: the next meeting (the reason the status title exists).
    static func mode(_ bag: PreferenceBag = DefaultsBag.shared) -> MenuBarMode {
        (bag.object(modeKey) as? String).flatMap(MenuBarMode.init(rawValue:)) ?? .next
    }

    static func setMode(_ mode: MenuBarMode, _ bag: PreferenceBag = DefaultsBag.shared) {
        bag.set(mode.rawValue, modeKey)
    }

    /// Default on.
    static func hotkeyEnabled(_ bag: PreferenceBag = DefaultsBag.shared) -> Bool {
        bag.object(hotkeyKey) as? Bool ?? true
    }

    static func setHotkeyEnabled(_ on: Bool, _ bag: PreferenceBag = DefaultsBag.shared) {
        bag.set(on, hotkeyKey)
    }
}

/// "Pause notifications for 1 hour" (status menu). The heads-up notifier reads the same key:
/// UserDefaults `notifications.pausedUntil`, a Date; absent or in the past = not paused.
enum NotificationPause {
    static let key = "notifications.pausedUntil"
    static let hour: TimeInterval = 3600

    static func pausedUntil(now: Date = Date(), _ bag: PreferenceBag = DefaultsBag.shared) -> Date? {
        guard let until = bag.object(key) as? Date, until > now else { return nil }
        return until
    }

    static func pause(for seconds: TimeInterval = hour, now: Date = Date(), _ bag: PreferenceBag = DefaultsBag.shared) {
        bag.set(now.addingTimeInterval(seconds), key)
    }

    static func resume(_ bag: PreferenceBag = DefaultsBag.shared) {
        bag.set(nil, key)
    }
}

// MARK: - The meeting the menu bar talks about

enum MeetingFocus {
    /// A meeting starting this soon takes over from the one in progress (back-to-back hand-over).
    static let handover: TimeInterval = 5 * 60
    /// ⌃⌥J joins a meeting this early, the same 30 minutes the widget shows its Join chip.
    static let joinEarly: TimeInterval = 30 * 60

    /// Timed meetings that still matter: not all-day, not declined, positive length, not over.
    static func candidates(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        events.filter { !$0.allDay && $0.myResponse != .declined && $0.end > $0.start && $0.end > now }
    }

    /// In progress: the one that started last (then the one ending first).
    static func current(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        candidates(events, now: now).filter { $0.start <= now }
            .sorted { ($1.start, $0.end, $0.r) < ($0.start, $1.end, $1.r) }
            .first
    }

    /// The next one to start.
    static func next(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        candidates(events, now: now).filter { $0.start > now }
            .min { ($0.start, $0.r) < ($1.start, $1.r) }
    }

    /// The meeting in progress, unless the next one starts within `handover`; else the next one.
    static func pick(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        let upcoming = next(events, now: now)
        if let upcoming, upcoming.start.timeIntervalSince(now) <= handover { return upcoming }
        return current(events, now: now) ?? upcoming
    }

    static func isLive(_ e: CalendarEvent, now: Date) -> Bool { !e.allDay && e.start <= now && e.end > now }

    /// Live, or starting within the widget's 30 minutes: the card's Join is the loud one.
    static func isSoon(_ e: CalendarEvent, now: Date) -> Bool {
        isLive(e, now: now) || (!e.allDay && e.start > now && e.start.timeIntervalSince(now) <= joinEarly)
    }
}

// MARK: - Status title

enum StatusTitle {
    /// The meeting title part is cut to this many characters (… included); the countdown follows.
    static let titleLimit = 18
    /// A meeting further away than this leaves the menu bar with its icon only.
    static let lookahead: TimeInterval = 60 * 60
    static let unreadCap = 999

    /// "Standup · 7m" before (within the hour), "Standup · 12m left" during, nil otherwise.
    static func countdown(_ event: CalendarEvent?, now: Date) -> String? {
        guard let e = event, !e.allDay else { return nil }
        let name = isolatedIfNeeded(truncate(clean(e.title), limit: titleLimit))
        if MeetingFocus.isLive(e, now: now) {
            return "\(name) · \(duration(e.end.timeIntervalSince(now))) left"
        }
        let until = e.start.timeIntervalSince(now)
        guard until > 0, until <= lookahead else { return nil }
        return "\(name) · \(duration(until))"
    }

    /// The whole title for a mode ("" = icon only).
    static func text(mode: MenuBarMode, focus: CalendarEvent?, unread: Int?, mailEnabled: Bool, now: Date) -> String {
        switch mode {
        case .icon:
            return ""
        case .next:
            return countdown(focus, now: now) ?? ""
        case .unread:
            guard mailEnabled, let unread, unread > 0 else { return "" }
            return unread > unreadCap ? "\(unreadCap)+" : "\(unread)"
        }
    }

    /// What VoiceOver reads for the status item: "Launch plan review starts in 12 minutes".
    static func spoken(mode: MenuBarMode, focus: CalendarEvent?, unread: Int?, mailEnabled: Bool, now: Date) -> String {
        switch mode {
        case .icon:
            return ""
        case .next:
            guard let e = focus, countdown(e, now: now) != nil else { return "" }
            let name = clean(e.title)
            if MeetingFocus.isLive(e, now: now) { return "\(name) ends in \(spokenDuration(e.end.timeIntervalSince(now)))" }
            return "\(name) starts in \(spokenDuration(e.start.timeIntervalSince(now)))"
        case .unread:
            guard mailEnabled, let unread, unread > 0 else { return "" }
            return unread == 1 ? "1 unread conversation" : "\(unread) unread conversations"
        }
    }

    /// Minutes rounded up, like the widget's "in 12 min": "7m", "1h", "1h 5m", "1d", "1d 2h" (past a day,
    /// whole hours, rounded up).
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, m = minutes % 60
        if hours < 24 { return m == 0 ? "\(hours)h" : "\(hours)h \(m)m" }
        // Past a day the minutes go; the hours round up too, so it never says less than is left.
        let wholeHours = (minutes + 59) / 60
        let days = wholeHours / 24, h = wholeHours % 24
        return h == 0 ? "\(days)d" : "\(days)d \(h)h"
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String { WidgetA11y.spokenDuration(seconds) }

    /// One line, no control or bidi-override characters (a title can't flip the menu bar), single
    /// spaces, "Meeting" when empty.
    static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            let v = s.value
            if bidiControls.contains(v) { continue }
            // C0/C1 controls and line/paragraph separators become spaces (ZWJ stays: emoji sequences).
            let control = v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029 || v == 0x85
            scalars.append(control ? " " : s)
        }
        let words = String(scalars).split(whereSeparator: { $0.isWhitespace })
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? "Meeting" : joined
    }

    /// Cut to `limit` characters (grapheme clusters, so emoji and letters with their marks stay whole), "…" included.
    static func truncate(_ s: String, limit: Int) -> String {
        guard s.count > limit, limit > 1 else { return s }
        let kept = String(s.prefix(limit - 1)).trimmingCharacters(in: .whitespaces)
        return kept + "\u{2026}"
    }

    /// Right-to-left titles go inside a first-strong isolate (U+2068 … U+2069), so " · 7m" stays after
    /// the title instead of the digits jumping into the right-to-left run.
    static func isolatedIfNeeded(_ s: String) -> String {
        containsRightToLeft(s) ? "\u{2068}\(s)\u{2069}" : s
    }

    static func containsRightToLeft(_ s: String) -> Bool {
        s.unicodeScalars.contains { v in
            let x = v.value
            return (0x0590...0x08FF).contains(x) || (0xFB1D...0xFDFF).contains(x) || (0xFE70...0xFEFF).contains(x)
                || (0x10800...0x10FFF).contains(x) || (0x1E800...0x1EFFF).contains(x)
        }
    }

    /// LRM, RLM, ALM, the embeddings/overrides (U+202A–202E) and the isolates (U+2066–2069).
    static let bidiControls: Set<UInt32> = [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                            0x2066, 0x2067, 0x2068, 0x2069]
}

// MARK: - ⌃⌥J

/// The global hotkey: ⌃⌥J (Carbon virtual key code). J was picked to avoid common ⌃⌥ shortcuts.
enum JoinHotkey {
    static let keyCode: UInt32 = 0x26          // kVK_ANSI_J
    static let display = "\u{2303}\u{2325}J"   // ⌃⌥J
}

enum HotkeyDecision: Equatable {
    case join(r: String, url: URL)
    case openPopover

    /// The menu bar's meeting when it can be joined now (live or within 30 min); else any live meeting
    /// with a link (latest start first); else the next one with a link within 30 min; else the popover.
    /// Only allowlisted https links (JoinPolicy) ever count.
    static func decide(_ events: [CalendarEvent], now: Date) -> HotkeyDecision {
        let joinable = MeetingFocus.candidates(events, now: now).filter { JoinPolicy.isAllowed($0.joinURL) }
        func ok(_ e: CalendarEvent) -> HotkeyDecision? {
            guard let url = e.joinURL, JoinPolicy.isAllowed(url), MeetingFocus.isSoon(e, now: now) else { return nil }
            return .join(r: e.r, url: url)
        }
        if let focus = MeetingFocus.pick(events, now: now), let decision = ok(focus) { return decision }
        if let live = MeetingFocus.current(joinable, now: now), let decision = ok(live) { return decision }
        if let soon = MeetingFocus.next(joinable, now: now), let decision = ok(soon) { return decision }
        return .openPopover
    }
}

// MARK: - Settings → Menu bar

/// Where ⌃⌥J stands, for Settings.
enum HotkeyState: Equatable {
    case on, off, taken, failed, pausedForVoiceOver
}

/// Settings → "Menu bar shows" and "Join with ⌃⌥J". Writes the preference and posts
/// `MenuBarPrefs.changed`; the status item redraws and the hotkey (re)registers synchronously, so the
/// state read right after is already the new one. Not actor-bound, like the other section models.
final class MenuBarSettingsModel: ObservableObject {
    /// The app points this at the hotkey center at launch; renders and tests leave it alone.
    static var liveState: () -> HotkeyState = { .off }

    @Published private(set) var mode: MenuBarMode
    @Published private(set) var hotkeyEnabled: Bool
    @Published private(set) var hotkeyState: HotkeyState

    private let bag: PreferenceBag
    let mailEnabled: () -> Bool
    private let state: () -> HotkeyState
    private let post: () -> Void

    init(bag: PreferenceBag = DefaultsBag.shared, mailEnabled: @escaping () -> Bool = { true },
         state: @escaping () -> HotkeyState = { MenuBarSettingsModel.liveState() },
         post: @escaping () -> Void = { NotificationCenter.default.post(name: MenuBarPrefs.changed, object: nil) }) {
        self.bag = bag
        self.mailEnabled = mailEnabled
        self.state = state
        self.post = post
        mode = MenuBarPrefs.mode(bag)
        hotkeyEnabled = MenuBarPrefs.hotkeyEnabled(bag)
        hotkeyState = state()
    }

    /// Unread count needs the Inbox (mail on): without it the choice isn't offered.
    var modes: [MenuBarMode] { mailEnabled() ? MenuBarMode.allCases : [.icon, .next] }

    /// What the picker shows: an unread choice left over while mail is off reads as icon only.
    var shownMode: MenuBarMode { modes.contains(mode) ? mode : .icon }

    func reload() {
        mode = MenuBarPrefs.mode(bag)
        hotkeyEnabled = MenuBarPrefs.hotkeyEnabled(bag)
        hotkeyState = state()
    }

    func setMode(_ new: MenuBarMode) {
        guard modes.contains(new), new != mode else { return }
        MenuBarPrefs.setMode(new, bag)
        mode = new
        post()
    }

    func setHotkey(_ on: Bool) {
        MenuBarPrefs.setHotkeyEnabled(on, bag)
        hotkeyEnabled = on
        post()
        hotkeyState = state()
    }

    var modeDetail: String {
        switch shownMode {
        case .icon: return "Just the calendar icon. Everything is one click away."
        case .next: return "\u{201C}Standup \u{00B7} 7m\u{201D} in the hour before a meeting, \u{201C}12m left\u{201D} while it runs."
        case .unread: return "How many conversations are waiting, across every inbox."
        }
    }

    var hotkeyDetail: String {
        guard hotkeyEnabled else { return "Off. The Join button in the menu-bar view still works." }
        switch hotkeyState {
        case .on, .off:
            return "From anywhere: joins the meeting that\u{2019}s on, or starts within 30 minutes. Otherwise it opens the menu-bar view."
        case .taken:
            return "Another app already listens for \(JoinHotkey.display), so I can\u{2019}t. Free it there, or switch this off."
        case .failed:
            return "macOS didn\u{2019}t let me listen for \(JoinHotkey.display) just now. Switching it off and on tries again."
        case .pausedForVoiceOver:
            return "Resting while VoiceOver is on (\u{2303}\u{2325} is VoiceOver\u{2019}s key). It comes back when VoiceOver stops."
        }
    }

    var hotkeyNeedsAttention: Bool { hotkeyEnabled && (hotkeyState == .taken || hotkeyState == .failed) }
}
