import SwiftUI

// Approved widget design (docs/DESIGN-WIDGETS.md), shared by the widget extension,
// the app's Widgets gallery and the headless renders. One copy: change it here only.

/// What the user controls per widget in Widget Studio.
struct WidgetStyle {
    enum Look: String { case paper = "Light", ink = "Dark" }
    enum Typeface: String, CaseIterable {
        case system = "System", rounded = "Rounded", serif = "Serif"
        /// The snapshot / settings spelling (`WidgetSnapshot.Style.typeface`).
        var key: String { String(describing: self) }
        init(key: String) { self = Self.allCases.first { $0.key == key } ?? .system }
    }
    enum TextSize: String, CaseIterable {
        case small = "Small", standard = "Standard", large = "Large"
        var key: String { String(describing: self) }
        init(key: String) { self = Self.allCases.first { $0.key == key } ?? .standard }
    }

    var look: Look = .paper
    var typeface: Typeface = .system
    var textSize: TextSize = .standard
    var showLogos = true
    var showEndTimes = false
    var use24Hour = false
    /// Monochrome palette: the system draws the widget accented or vibrant (desktop not in focus,
    /// tinted widgets). Set from `widgetRenderingMode` via the `widgetMono` environment value.
    var mono = false
    /// The app's own windows (Calendar section, Day Peek) draw the same rows larger.
    var scaleOverride: CGFloat? = nil

    var scale: CGFloat {
        if let scaleOverride { return scaleOverride }
        switch textSize {
        case .small: return 0.92
        case .standard: return 1.0
        case .large: return 1.14
        }
    }

    var design: Font.Design {
        switch typeface {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        }
    }

    var palette: Palette {
        if mono { return look == .paper ? .paperMono : .inkMono }
        return look == .paper ? .paper : .ink
    }

    /// The snapshot's style for this Mac (look `auto` follows the widget's colour scheme).
    static func from(_ s: WidgetSnapshot.Style, dark: Bool) -> WidgetStyle {
        var style = WidgetStyle()
        switch s.look {
        case .auto: style.look = dark ? .ink : .paper
        case .paper: style.look = .paper
        case .ink: style.look = .ink
        }
        style.typeface = Typeface(key: s.typeface)
        style.textSize = TextSize(key: s.textSize)
        style.showLogos = s.showLogos
        style.use24Hour = s.use24Hour
        return style
    }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }

    /// Row metrics grow with the text so nothing clips at Large.
    var meetingRow: CGFloat { 22.5 * scale }
    var dayBanner: CGFloat { 21 * scale }
    var dayGap: CGFloat { 7 }
    /// D-013: a day with ≤2 meetings opens with a slim banner (label + hairline, no fill).
    var slimBanner: CGFloat { 15 * scale }
    var slimGap: CGFloat { 3 }
    static let slimDayLimit = 2

    var label: String {
        "\(look.rawValue) · \(typeface.rawValue) · \(textSize.rawValue) text"
    }
}

struct Palette {
    let backgroundTop: Color
    let backgroundBottom: Color
    let text: Color
    let text2: Color
    let text3: Color
    let band: Color
    let rule: Color
    let accent: Color
    let onAccent: Color
    let accentSoft: Color
    let warn: Color
    let warnSoft: Color

    static let paper = Palette(
        backgroundTop: Color(hex: 0xFFFFFF), backgroundBottom: Color(hex: 0xF8F5F0),
        text: Color(hex: 0x1D1B20), text2: Color(hex: 0x6E6974), text3: Color(hex: 0xA7A2AC),
        band: Color(hex: 0xF2EEE8), rule: Color(hex: 0xEAE5DD),
        accent: Color(hex: 0x14937F), onAccent: .white, accentSoft: Color(hex: 0x14937F).opacity(0.10),
        warn: Color(hex: 0xC2410C), warnSoft: Color(hex: 0xC2410C).opacity(0.10))

    static let ink = Palette(
        backgroundTop: Color(hex: 0x15252E), backgroundBottom: Color(hex: 0x0C171E),
        text: Color(hex: 0xEEF5F3), text2: Color(hex: 0xEEF5F3).opacity(0.64), text3: Color(hex: 0xEEF5F3).opacity(0.40),
        band: Color.white.opacity(0.065), rule: Color.white.opacity(0.08),
        accent: Color(hex: 0x3CCBB4), onAccent: Color(hex: 0x05201B), accentSoft: Color(hex: 0x3CCBB4).opacity(0.16),
        warn: Color(hex: 0xF59E6B), warnSoft: Color(hex: 0xF59E6B).opacity(0.16))

    /// Accented / vibrant rendering: the system keeps only luminance, so the accent becomes the text
    /// colour and fills become neutral (no teal-on-teal mush when desaturated).
    static let paperMono = Palette(
        backgroundTop: Color(hex: 0xFFFFFF), backgroundBottom: Color(hex: 0xF8F5F0),
        text: Color(hex: 0x1D1B20), text2: Color(hex: 0x1D1B20).opacity(0.62), text3: Color(hex: 0x1D1B20).opacity(0.40),
        band: Color(hex: 0x1D1B20).opacity(0.06), rule: Color(hex: 0x1D1B20).opacity(0.10),
        accent: Color(hex: 0x1D1B20), onAccent: .white, accentSoft: Color(hex: 0x1D1B20).opacity(0.09),
        warn: Color(hex: 0x1D1B20), warnSoft: Color(hex: 0x1D1B20).opacity(0.12))

    static let inkMono = Palette(
        backgroundTop: Color(hex: 0x15252E), backgroundBottom: Color(hex: 0x0C171E),
        text: .white, text2: Color.white.opacity(0.66), text3: Color.white.opacity(0.42),
        band: Color.white.opacity(0.08), rule: Color.white.opacity(0.12),
        accent: .white, onAccent: Color(hex: 0x0C171E), accentSoft: Color.white.opacity(0.14),
        warn: .white, warnSoft: Color.white.opacity(0.16))
}

/// Nominal macOS desktop widget sizes (from chronod's log; measured, the same displaySize).
enum Family: String, CaseIterable {
    case small, medium, large, extraLarge, extraLargePortrait

    var size: CGSize {
        switch self {
        case .small: return CGSize(width: 164, height: 164)
        case .medium: return CGSize(width: 344, height: 164)
        case .large: return CGSize(width: 344, height: 344)
        case .extraLarge: return CGSize(width: 704, height: 344)
        case .extraLargePortrait: return CGSize(width: 344, height: 704)
        }
    }

    /// Token used in links, traces and file names.
    var short: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .extraLarge: return "XL"
        case .extraLargePortrait: return "XLP"
        }
    }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        case .extraLargePortrait: return "Extra Large Portrait"
        }
    }
}

/// The calendar every widget view groups and formats with. The live widget uses a Gregorian calendar
/// with the Mac's time zone and first weekday and English text (a Mac set to another calendar system
/// still gets Gregorian dates); renders and tests pin `fixed` so PNGs and text are the same on every Mac,
/// whatever its time zone.
enum WidgetCalendar {
    static var current: Calendar = system()

    /// Always Gregorian (the data layer groups days in Gregorian too, `DayKey`): a Mac set to the
    /// Buddhist, Japanese or Islamic calendar keeps only its time zone and first weekday.
    static func system(mac: Calendar = .current, timeZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = mac.firstWeekday   // setting the locale would otherwise reset it
        c.minimumDaysInFirstWeek = mac.minimumDaysInFirstWeek
        return c
    }

    /// Rebuilds `current` from the Mac as it is now (after travel, or a new first weekday).
    static func reset() {
        NSTimeZone.resetSystemTimeZone()
        current = system(mac: Calendar.autoupdatingCurrent, timeZone: TimeZone.current)
        WidgetClockDefaults.refresh()
    }

    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []

    /// The resident app and the widget extension stay in step with the Mac: `current` is rebuilt when
    /// the time zone or the region settings change. Idempotent.
    static func followSystemChanges(center: NotificationCenter = .default, queue: OperationQueue? = .main) {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: queue) { _ in reset() })
        }
    }

    /// Tests only: drop the observers so another centre can be followed.
    static func stopFollowing(center: NotificationCenter = .default) {
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    /// The fixed calendar of renders and tests: London, Monday first, English.
    static var fixed: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = 2
        return c
    }
}

/// The 24-hour clock follows the Mac (D-039): a widget nobody styled in Widget Studio
/// uses the Mac's clock setting. Renders and tests never call `refresh()`, so they keep the 12-hour
/// default and stay deterministic.
enum WidgetClockDefaults {
    /// True when the Mac's region formats times with a 24-hour clock ("j" resolves to H or k).
    static func macUses24Hour(locale: Locale = .autoupdatingCurrent) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h"
        return format.contains("H") || format.contains("k")
    }

    /// Re-reads the Mac (the app at launch and on a region change).
    static func refresh(locale: Locale = .autoupdatingCurrent) {
        WidgetSnapshot.Style.defaultUse24Hour = macUses24Hour(locale: locale)
    }
}
