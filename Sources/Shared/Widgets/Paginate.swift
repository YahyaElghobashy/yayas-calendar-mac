import Foundation

/// One line of an agenda column.
enum AgendaLine {
    /// `slim` (D-013): the day has ≤2 meetings in range, so its banner is a label + hairline.
    case day(Date, continued: Bool, count: Int, first: Bool, slim: Bool)
    case meeting(WidgetMeeting)

    var isMeeting: Bool { if case .meeting = self { return true } else { return false } }
}

/// Fills columns top to bottom by point height. A day banner never sits alone at the bottom of a
/// column; a column that resumes a day opens with "…, continued".
struct AgendaPaginator {
    let style: WidgetStyle
    let columnHeight: CGFloat
    let columns: Int

    func height(_ line: AgendaLine) -> CGFloat {
        switch line {
        case .day(_, _, _, let first, let slim):
            return slim ? style.slimBanner + (first ? 0 : style.slimGap)
                        : style.dayBanner + (first ? 0 : style.dayGap)
        case .meeting: return style.meetingRow
        }
    }

    /// `maxColumns`: stop once that many columns are full (callers that show only the first column);
    /// the columns returned are exactly the first ones of the full pagination.
    func pages(_ meetings: [WidgetMeeting], from now: Date, maxColumns: Int = .max) -> [[[AgendaLine]]] {
        let cal = WidgetCalendar.current
        let upcoming = meetings.filter { $0.end > now }.sorted { $0.start < $1.start }
        // A meeting already under way (an all-day event, an overnight call) belongs to today, not to the
        // day it started on.
        let byDay = Dictionary(grouping: upcoming) { cal.startOfDay(for: max($0.start, now)) }
        let days = byDay.keys.sorted()
        let todayCount = meetings.filter { cal.isDate($0.start, inSameDayAs: now) }.count

        var columnsOut: [[AgendaLine]] = []
        var column: [AgendaLine] = []
        var used: CGFloat = 0

        func closeColumn() {
            if !column.isEmpty { columnsOut.append(column) }
            column = []; used = 0
        }

        days: for day in days {
            let list = byDay[day]!
            let count = cal.isDate(day, inSameDayAs: now) ? todayCount : list.count
            let slim = list.count <= WidgetStyle.slimDayLimit
            var index = 0
            var continued = false
            while index < list.count {
                let banner = AgendaLine.day(day, continued: continued, count: count, first: column.isEmpty, slim: slim)
                if !column.isEmpty, used + height(banner) + style.meetingRow > columnHeight {
                    closeColumn()
                    if columnsOut.count >= maxColumns { break days }
                    continue
                }
                column.append(banner); used += height(banner)
                // At least one meeting follows every banner, even in a column too short for both
                // (otherwise an empty column that can't fit them would loop forever).
                repeat {
                    column.append(.meeting(list[index])); used += style.meetingRow; index += 1
                } while index < list.count && used + style.meetingRow <= columnHeight
                if index < list.count {
                    closeColumn(); continued = true
                    if columnsOut.count >= maxColumns { break days }
                }
            }
        }
        closeColumn()

        return stride(from: 0, to: columnsOut.count, by: columns).map {
            Array(columnsOut[$0..<min($0 + columns, columnsOut.count)])
        }
    }

    /// Meeting rows on a page (day banners never count).
    static func meetingCount(_ page: [[AgendaLine]]) -> Int {
        page.reduce(0) { $0 + $1.filter(\.isMeeting).count }
    }
}

enum DayName {
    static func title(_ day: Date, now: Date) -> String {
        let cal = WidgetCalendar.current
        if cal.isDate(day, inSameDayAs: now) { return "Today" }
        if let t = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)), cal.isDate(day, inSameDayAs: t) {
            return "Tomorrow"
        }
        return format("EEEE", day)
    }

    static func subtitle(_ day: Date, now: Date) -> String {
        if title(day, now: now) == "Tomorrow" { return format("EEEE d", day) }
        return format("d MMMM", day)
    }

    /// `pattern` in the widget calendar (its time zone, locale and first weekday). The formatter comes
    /// from `DateFormatterCache`: building one costs ~1 ms (ICU), and renders format hundreds of labels.
    static func format(_ pattern: String, _ date: Date) -> String {
        DateFormatterCache.formatter(pattern, calendar: WidgetCalendar.current).string(from: date)
    }

    /// `YYYY-MM-DD` / `YYYY-MM` for link parameters: Gregorian, ASCII digits, in the widget calendar's
    /// time zone, whatever the Mac's calendar or locale (what a POSIX `yyyy-MM-dd` formatter prints).
    static func linkDay(_ date: Date) -> String {
        let c = gregorian(WidgetCalendar.current.timeZone).dateComponents([.year, .month, .day], from: date)
        return digits(c.year ?? 0, 4) + "-" + digits(c.month ?? 0, 2) + "-" + digits(c.day ?? 0, 2)
    }

    static func linkMonth(_ date: Date) -> String {
        let c = gregorian(WidgetCalendar.current.timeZone).dateComponents([.year, .month], from: date)
        return digits(c.year ?? 0, 4) + "-" + digits(c.month ?? 0, 2)
    }

    /// Parses a link / snapshot day `YYYY-MM-DD` to the start of that day in the widget calendar.
    /// Strict: anything that does not round-trip (2026-02-30, 2026-1-5) is nil.
    static func parseDay(_ text: String?) -> Date? {
        guard let text, text.count == 10 else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let cal = WidgetCalendar.current
        // Link days are Gregorian whatever the Mac uses.
        guard let date = gregorian(cal.timeZone).date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              linkDay(date) == text else { return nil }
        return cal.startOfDay(for: date)
    }

    /// Parses `YYYY-MM` to the first day of that month.
    static func parseMonth(_ text: String?) -> Date? {
        guard let text, text.count == 7 else { return nil }
        return parseDay(text + "-01")
    }

    /// A Gregorian calendar in `zone` (cached: link days are built for every Month cell).
    static func gregorian(_ zone: TimeZone) -> Calendar {
        gregorianLock.lock(); defer { gregorianLock.unlock() }
        if let cached = gregorianCache, cached.timeZone == zone { return cached }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        gregorianCache = c
        return c
    }

    private static let gregorianLock = NSLock()
    nonisolated(unsafe) private static var gregorianCache: Calendar?

    /// `value` in ASCII digits, zero-padded to `width` (like `yyyy` / `MM` / `dd`).
    private static func digits(_ value: Int, _ width: Int) -> String {
        let text = String(abs(value))
        let padded = text.count < width ? String(repeating: "0", count: width - text.count) + text : text
        return value < 0 ? "-" + padded : padded
    }
}

/// Configured `DateFormatter`s, shared by every render (widget extension, app gallery, Peeks, renders).
/// Building a formatter loads ICU data (~1 ms each); renders used to build one per label and per Month
/// cell, which dominated the widget's timeline work (D-019). A formatter is keyed by
/// everything that changes its output — pattern, calendar identifier, first weekday, minimum days in
/// the first week, time zone and locale — configured once in the order `format` always used (calendar,
/// time zone, locale, pattern) and never mutated afterwards: formatting from several threads is safe.
enum DateFormatterCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    static let limit = 256

    static func formatter(_ pattern: String, calendar cal: Calendar) -> DateFormatter {
        let key = key(pattern, calendar: cal)
        lock.lock(); defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = cal.locale
        f.dateFormat = pattern
        if formatters.count >= limit { formatters.removeAll() }
        formatters[key] = f
        return f
    }

    static func key(_ pattern: String, calendar cal: Calendar) -> String {
        [pattern, "\(cal.identifier)", "\(cal.firstWeekday)", "\(cal.minimumDaysInFirstWeek)",
         cal.timeZone.identifier, cal.locale?.identifier ?? "-"].joined(separator: "\u{1F}")
    }

    /// Formatters currently cached (tests).
    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return formatters.count
    }
}
