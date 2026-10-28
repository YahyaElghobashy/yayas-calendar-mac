import Foundation

/// The agenda paginator under the design metrics (Standard text: 22.5 pt rows, 21 pt banners
/// + 7 pt gaps; D-013 slim banners 15 pt + 3 pt gaps for days with ≤2 meetings).
enum PaginatorTests {
    static let cal = WidgetCalendar.fixed
    static let now = WidgetSample.fixedNow
    static let account = WidgetAccount(id: "t", short: "T", name: "Test", logo: nil)

    static func run() {
        sampleWeek()
        busyAndQuietDays()
        invariants()
    }

    static func meeting(_ id: Int, day: Int, hour: Int, minute: Int = 0) -> WidgetMeeting {
        let d = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: now))!
        let start = cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
        return WidgetMeeting(id: id, account: account, title: "Meeting \(id)", start: start,
                             end: start.addingTimeInterval(25 * 60), place: nil, hasLink: true)
    }

    /// Meetings per day (day 0 = today, starting after "now" at 9:48).
    static func fixture(_ perDay: [Int]) -> [WidgetMeeting] {
        var out: [WidgetMeeting] = []
        for (day, count) in perDay.enumerated() {
            for i in 0..<count { out.append(meeting(out.count + 1, day: day, hour: 10 + i / 2, minute: (i % 2) * 30)) }
        }
        return out
    }

    static func firstPage(_ family: Family, _ meetings: [WidgetMeeting], _ style: WidgetStyle = WidgetStyle()) -> Int {
        let pages = AgendaWidget.pages(family: family, meetings: meetings, now: now, style: style)
        return pages.first.map(AgendaPaginator.meetingCount) ?? 0
    }

    static func sampleWeek() {
        T.section("paginator: approved sample week")
        let week = WidgetSample.week(now: now, logos: nil, calendar: cal).meetings
        let l = firstPage(.large, week), xl = firstPage(.extraLarge, week), xlp = firstPage(.extraLargePortrait, week)
        T.check(l >= 10, "Large page 1 shows ≥10 meetings at Standard text (got \(l))")
        T.note("sample week page 1 at Standard text: Large \(l), XL \(xl), XL Portrait \(xlp)")
        var large = WidgetStyle(); large.textSize = .large
        var small = WidgetStyle(); small.textSize = .small
        let lLarge = firstPage(.large, week, large), lSmall = firstPage(.large, week, small)
        T.check(lLarge <= l && l <= lSmall, "Large text shows no more rows than Standard, Small no fewer (\(lSmall)/\(l)/\(lLarge))")
    }

    static func busyAndQuietDays() {
        T.section("paginator: busy day, quiet days (D-013)")
        let busy = fixture([14])
        T.check(firstPage(.large, busy) >= 11, "one busy day: Large page 1 ≥11 (got \(firstPage(.large, busy)))")

        // Today 6, then two quiet days of 2: ten meetings in three days. Full banners would fit 9;
        // the slim banners make room for the tenth.
        let quiet = fixture([6, 2, 2, 1])
        T.equal(firstPage(.large, quiet), 10, "6+2+2: Large page 1 shows 10 thanks to slim banners")

        // Ten meetings within two days always fit on Large, whatever the split.
        for first in 1...9 {
            let two = fixture([first, 10 - first, 3])
            T.check(firstPage(.large, two) >= 10, "\(first)+\(10 - first): Large page 1 ≥10 (got \(firstPage(.large, two)))")
        }

        let sparse = WidgetSample.sparseWeek(now: now, logos: nil, calendar: cal).meetings
        T.note("sparse sample week page 1: Large \(firstPage(.large, sparse)), XL \(firstPage(.extraLarge, sparse)), "
               + "XL Portrait \(firstPage(.extraLargePortrait, sparse))")
        T.check(firstPage(.large, sparse) >= 8, "sparse week Large page 1 ≥8 (arithmetic ceiling with one banner per day)")
    }

    static func invariants() {
        T.section("paginator: invariants over generated weeks")
        var rng = SeededRandom(2026_10_19)
        var checked = 0
        let styles: [WidgetStyle] = [WidgetStyle.TextSize.small, .standard, .large].map { var s = WidgetStyle(); s.textSize = $0; return s }
        for _ in 0..<60 {
            let perDay = (0..<rng.int(1...9)).map { _ in rng.int(0...9) }
            let meetings = fixture(perDay)
            for style in styles {
                for (height, columns) in [(CGFloat(284), 1), (284, 2), (608, 1), (118, 1), (22, 1), (9, 1)] {
                    check(meetings, style: style, height: height, columns: columns)
                    checked += 1
                }
            }
        }
        T.note("\(checked) generated layouts checked")
    }

    private static func check(_ meetings: [WidgetMeeting], style: WidgetStyle, height: CGFloat, columns: Int) {
        let paginator = AgendaPaginator(style: style, columnHeight: height, columns: columns)
        let pages = paginator.pages(meetings, from: now)
        let upcoming = meetings.filter { $0.end > now }.sorted { $0.start < $1.start }
        let roomy = height >= style.dayBanner + style.meetingRow
        let label = "h=\(Int(height)) cols=\(columns) size=\(style.textSize.rawValue) n=\(upcoming.count)"
        var seen: [Int] = []
        var ok = true
        for page in pages {
            if page.count > columns { ok = false; T.check(false, "\(label): page has \(page.count) columns") }
            for column in page {
                guard !column.isEmpty else { ok = false; T.check(false, "\(label): empty column"); continue }
                if case .day = column.last! { ok = false; T.check(false, "\(label): column ends with a day banner") }
                for (i, line) in column.enumerated() {
                    switch line {
                    case .day(let day, let continued, _, let first, let slim):
                        if i + 1 >= column.count || !column[i + 1].isMeeting { ok = false; T.check(false, "\(label): orphan banner") }
                        if first != (i == 0) { ok = false; T.check(false, "\(label): first flag wrong") }
                        if continued && i != 0 { ok = false; T.check(false, "\(label): 'continued' banner mid-column") }
                        let dayCount = upcoming.filter { cal.isDate($0.start, inSameDayAs: day) }.count
                        if slim != (dayCount <= WidgetStyle.slimDayLimit) { ok = false; T.check(false, "\(label): slim flag wrong") }
                    case .meeting(let m):
                        seen.append(m.id)
                    }
                }
                let used = column.reduce(CGFloat(0)) { $0 + paginator.height($1) }
                if roomy && used > height + 0.001 { ok = false; T.check(false, "\(label): column \(used) pt > \(height) pt") }
            }
        }
        if seen != upcoming.map(\.id) { ok = false; T.check(false, "\(label): meetings lost, repeated or reordered") }
        T.check(ok, "\(label) holds every invariant")
    }
}

enum InboxLayoutTests {
    static func run() {
        T.section("inbox layout")
        let data = WidgetSample.week(now: WidgetSample.fixedNow, logos: nil, calendar: WidgetCalendar.fixed)
        let style = WidgetStyle()
        for (height, columns, banners) in [(CGFloat(284), 1, true), (284, 2, true), (104, 1, false), (630, 1, true), (10, 1, true)] {
            let blocks = InboxLayout.columns(data.mail, style: style, height: height, columns: columns, showBanners: banners)
            T.check(blocks.count <= columns, "h=\(Int(height)): at most \(columns) column(s)")
            var ids: [Int] = []
            for column in blocks {
                var used: CGFloat = 0
                for block in column {
                    used += (banners ? style.dayBanner + (block.first ? 0 : style.dayGap) : 0) + CGFloat(block.mail.count) * style.meetingRow
                    T.check(!block.mail.isEmpty, "h=\(Int(height)): no empty day blocks")
                    ids += block.mail.map(\.id)
                }
                T.check(used <= height + 0.001, "h=\(Int(height)): column fits (\(used) pt)")
            }
            T.equal(Set(ids).count, ids.count, "h=\(Int(height)): no mail twice")
            let newestFirst = data.mail.sorted { $0.at > $1.at }.prefix(ids.count).map(\.id)
            T.equal(ids, Array(newestFirst), "h=\(Int(height)): newest first, no gaps")
        }
        let medium = InboxLayout.columns(data.mail, style: style, height: 164 - 26 - 26 - 8, columns: 1, showBanners: false)
        T.equal(medium.reduce(0) { $0 + $1.reduce(0) { $0 + $1.mail.count } }, 4, "Medium inbox shows 4 rows")
    }
}
