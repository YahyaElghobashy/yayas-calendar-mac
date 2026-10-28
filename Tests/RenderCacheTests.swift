import AppKit
import Foundation

/// The render caches: `DateFormatterCache` behind `DayName.format`, formatter-free link
/// days, and `LogoCache` behind `SnapshotModel.logoFile`. Each must print / load exactly what the
/// uncached code did, follow the calendar it is asked about (time zone, locale, first weekday, 24 h),
/// and see a changed logo file.
enum RenderCacheTests {
    static func run() {
        formatters()
        linkDays()
        logos()
    }

    /// What `DayName.format` built on every call before the cache.
    static func fresh(_ pattern: String, _ date: Date, _ cal: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = cal.locale
        f.dateFormat = pattern
        return f.string(from: date)
    }

    static func calendar(_ zone: String, locale: String = "en_US", firstWeekday: Int = 2,
                         identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var c = Calendar(identifier: identifier)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: locale)
        c.firstWeekday = firstWeekday
        return c
    }

    static func formatters() {
        T.section("render caches: DayName.format = a fresh DateFormatter, per calendar")
        let saved = WidgetCalendar.current
        defer { WidgetCalendar.current = saved }
        let patterns = ["EEEE", "EEE d MMM", "d MMMM", "MMMM", "h", "h:mm", "a", "HH:mm", "EEEE d MMMM yyyy", "h:mm a", "d"]
        let calendars = [WidgetCalendar.fixed, calendar("UTC"), calendar("America/Los_Angeles", firstWeekday: 1),
                         calendar("Asia/Tokyo", locale: "fr_FR"), calendar("Asia/Tokyo", locale: "ja_JP", identifier: .japanese),
                         calendar("America/Los_Angeles", locale: "el_GR"), calendar("Asia/Tokyo", identifier: .islamicUmmAlQura)]
        let base = WidgetSample.fixedNow
        // Inside London's repeated hour (25 Oct, 01:18 GMT), a year boundary, and the fixed sample week.
        let dates = [base, base.addingTimeInterval(5 * 86_400 + 3_600 * 16 + 1_800), base.addingTimeInterval(74 * 86_400 + 1_800),
                     Date(timeIntervalSince1970: 1_798_754_399)]
        var same = true, checked = 0
        for cal in calendars {
            WidgetCalendar.current = cal
            for pattern in patterns {
                for date in dates {
                    checked += 1
                    if DayName.format(pattern, date) != fresh(pattern, date, cal) {
                        same = false
                        T.note("differs: \(pattern) \(cal.timeZone.identifier) \(cal.locale?.identifier ?? "-")")
                    }
                }
            }
        }
        T.check(same, "\(checked) pattern × calendar × date outputs match an uncached formatter")
        WidgetCalendar.current = WidgetCalendar.fixed
        let first = DateFormatterCache.formatter("EEEE", calendar: WidgetCalendar.fixed)
        T.check(first === DateFormatterCache.formatter("EEEE", calendar: WidgetCalendar.fixed), "one formatter per key, reused")
        let count = DateFormatterCache.count
        for _ in 0..<50 { _ = DayName.format("EEEE", base) }
        T.equal(DateFormatterCache.count, count, "repeat formatting builds nothing new")
        var sunday = WidgetCalendar.fixed; sunday.firstWeekday = 1
        T.check(DateFormatterCache.key("EEEE", calendar: sunday) != DateFormatterCache.key("EEEE", calendar: WidgetCalendar.fixed),
                "first weekday is part of the key (Sunday-first and Monday-first never share a formatter)")
        T.equal(DateFormatterCache.formatter("EEEE", calendar: WidgetCalendar.fixed).calendar.firstWeekday, 2,
                "the cached formatter keeps the Monday-first calendar")
        T.equal(DateFormatterCache.formatter("EEEE", calendar: sunday).calendar.firstWeekday, 1,
                "…and the Sunday-first one keeps its own")
        var otherZone = WidgetCalendar.fixed; otherZone.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        T.check(DateFormatterCache.formatter("HH:mm", calendar: otherZone) !== DateFormatterCache.formatter("HH:mm", calendar: WidgetCalendar.fixed),
                "a different time zone gets its own formatter")
        WidgetCalendar.current = otherZone
        T.equal(DayName.format("HH:mm", base), fresh("HH:mm", base, otherZone), "…and prints that zone's time")
        WidgetCalendar.current = WidgetCalendar.fixed

        T.section("render caches: 12 h / 24 h clock through the cache")
        var twelve = WidgetStyle(); twelve.use24Hour = false
        var day = WidgetStyle(); day.use24Hour = true
        let fixed = WidgetCalendar.fixed
        let at2pm = fixed.date(bySettingHour: 14, minute: 5, second: 0, of: base)!
        let at9 = fixed.date(bySettingHour: 9, minute: 0, second: 0, of: base)!
        T.check(WidgetClock.time(at2pm, twelve) == ("2:05", "PM"), "12 h: 2:05 PM")
        T.check(WidgetClock.time(at9, twelve) == ("9", "AM"), "12 h on the hour: 9 AM")
        T.check(WidgetClock.time(at2pm, day) == ("14:05", ""), "24 h: 14:05")
        T.check(WidgetClock.time(at9, day) == ("09:00", ""), "24 h on the hour: 09:00")
    }

    static func linkDays() {
        T.section("render caches: link days are Gregorian ASCII in the widget's time zone")
        let saved = WidgetCalendar.current
        defer { WidgetCalendar.current = saved }
        func posix(_ pattern: String, _ date: Date, _ zone: TimeZone) -> String {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian); f.timeZone = zone
            f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern
            return f.string(from: date)
        }
        // A non-Gregorian Mac calendar must not change link days: Hebrew, Buddhist, Japanese and Islamic, one per zone.
        let zones: [(String, String, Calendar.Identifier)] = [("Europe/London", "he_IL", .hebrew), ("Pacific/Kiritimati", "th_TH", .buddhist),
                                                              ("America/Los_Angeles", "ja_JP", .japanese), ("UTC", "ar", .islamicUmmAlQura)]
        var same = true, checked = 0
        for (zone, locale, identifier) in zones {
            WidgetCalendar.current = calendar(zone, locale: locale, identifier: identifier)
            let tz = TimeZone(identifier: zone)!
            var date = Date(timeIntervalSince1970: 1_790_000_000)   // Sep 2026
            for _ in 0..<500 {
                checked += 1
                if DayName.linkDay(date) != posix("yyyy-MM-dd", date, tz) || DayName.linkMonth(date) != posix("yyyy-MM", date, tz) {
                    same = false
                }
                date = date.addingTimeInterval(3 * 3_600 + 1_234)   // crosses midnights and both DST changes
            }
        }
        T.check(same, "\(checked) dates × 4 zones: linkDay/linkMonth = the POSIX yyyy-MM-dd formatter")
        WidgetCalendar.current = WidgetCalendar.fixed
        T.equal(DayName.parseDay("2026-10-29").map(DayName.linkDay), "2026-10-29", "parseDay round-trips on the DST day")
        T.equal(DayName.parseDay("2026-02-30"), nil, "2026-02-30 is rejected")
        T.equal(DayName.parseMonth("2026-12").map(DayName.linkMonth), "2026-12", "parseMonth round-trips")
    }

    static func logos() {
        T.section("render caches: logos decode once per file version")
        let folder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("logo-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = FixtureAccounts.orb.uuidString
        let file = folder.appendingPathComponent("\(id).png")
        func png(_ side: Int, _ white: CGFloat) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: white, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: side, height: side).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }
        let cache = LogoCache.shared
        cache.removeAll()
        let load = SnapshotModel.logoFile(in: folder)
        T.check(load(id) == nil, "no file → no logo")
        try? png(128, 0.2).write(to: file)
        let loadsBefore = cache.loads
        let first = load(id)
        T.check(first != nil && cache.loads == loadsBefore + 1, "first read decodes the file")
        let second = load(id)
        T.check(second === first && cache.loads == loadsBefore + 1, "a second timeline reuses the decoded image")
        // Same size, new pixels, new modification date (LogoStore rewrites the file atomically).
        try? png(128, 0.8).write(to: file)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        let changed = load(id)
        T.check(changed != nil && changed !== first && cache.loads == loadsBefore + 2, "a rewritten logo is read again")
        try? png(64, 0.5).write(to: file)
        T.equal(load(id).flatMap { $0.representations.first?.pixelsWide }, 64, "a new size is read again")
        // Same size, same modification date (to the nanosecond): what a restore or `cp -p` leaves, or two
        // logos of one size written within one timestamp tick. The file's identity and status-change
        // time still differ (mtime + size alone missed these).
        let same = png(64, 0.5)
        let held = load(id)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        let loads = cache.loads
        try? same.write(to: file, options: .atomic)   // a new inode, same bytes and size
        if let stamp { try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path) }
        let replaced = load(id)
        T.check(replaced != nil && replaced !== held && cache.loads == loads + 1,
                "an atomic replacement at the same size and modification date is read again")
        let inPlace = FileHandle(forWritingAtPath: file.path)
        inPlace?.write(same)   // the same file, rewritten in place
        try? inPlace?.close()
        if let stamp { try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path) }
        let rewritten = load(id)
        T.check(rewritten != nil && rewritten !== replaced && cache.loads == loads + 2,
                "an in-place rewrite with the modification date put back is read again")
        T.check(load(id) === rewritten && cache.loads == loads + 2, "…and then reused")
        try? FileManager.default.removeItem(at: file)
        T.check(load(id) == nil, "a removed logo stops drawing")
        T.check(load("../\(id)") == nil && load(".hidden") == nil, "ids that aren't plain file names load nothing")
        let model = SnapshotModel(SnapshotFixtures.busy(kind: "agenda.all"), logo: SnapshotModel.logoFile(in: folder))
        T.check(model.accounts[id]?.logo == nil, "the snapshot model sees the removal too")
        try? FileManager.default.removeItem(at: folder)
    }
}
