import Foundation

/// The span the app keeps in sync and the Month widget can show: from the first day of this month's
/// grid (the week starts on the Mac's first weekday, Monday in the UK) to the end of the month
/// that contains today + 60 days. `end` is exclusive (local midnight).
struct SyncWindow: Equatable, Sendable {
    var start: Date
    var end: Date

    static let lookaheadDays = 60

    static func current(now: Date, calendar cal: Calendar) -> SyncWindow {
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? cal.startOfDay(for: now)
        let lead = (cal.component(.weekday, from: monthStart) - cal.firstWeekday + 7) % 7
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -lead, to: monthStart) ?? monthStart)
        let ahead = cal.date(byAdding: .day, value: lookaheadDays, to: cal.startOfDay(for: now)) ?? now
        let end = cal.dateInterval(of: .month, for: ahead)?.end ?? ahead
        return SyncWindow(start: start, end: end)
    }

    /// First and last day inside the window, `YYYY-MM-DD` (the snapshot's windowStart/windowEnd).
    func dayKeys(_ cal: Calendar) -> (first: String, last: String) {
        let lastDay = cal.date(byAdding: .day, value: -1, to: end) ?? end
        return (DayKey.string(start, cal), DayKey.string(lastDay, cal))
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// `YYYY-MM-DD` / `YYYY-MM` keys in a given calendar (always Gregorian digits).
enum DayKey {
    static func string(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func month(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Local midnight of `YYYY-MM-DD` (the first instant of that day when midnight is skipped by DST).
    static func date(_ key: String, _ cal: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        guard let noon = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              cal.component(.day, from: noon) == d, cal.component(.month, from: noon) == m else { return nil }
        return cal.startOfDay(for: noon)
    }

    /// First day of `YYYY-MM`.
    static func monthStart(_ key: String, _ cal: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2 else { return nil }
        return date("\(parts[0])-\(parts[1])-01", cal)
    }

    /// The Gregorian calendar the data layer groups days with: the Mac's time zone and first weekday.
    static func systemCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone.current
        cal.firstWeekday = Calendar.current.firstWeekday
        return cal
    }
}
