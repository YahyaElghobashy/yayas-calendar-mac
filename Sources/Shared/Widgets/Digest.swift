import SwiftUI

// The Daily Digest widget (D-053): Yaya's Mail Helper's latest digest at a glance, one box per mailbox. The app
// distils the helper's file into the snapshot (`WidgetSnapshot.Digest`); everything here draws from it and the entry
// date only. Unread = the items of the sections not marked read yet, so the badge falls as sections are read.

/// What the widget and the app's own gallery say about the digest's whole-card states, as `MailOffCopy` does for mail.
enum DigestCopy {
    static let offTitle = "Yaya\u{2019}s Mail Helper isn\u{2019}t on this Mac"
    static let offTitleSmall = "No mail helper"
    static let offLine = "The daily digest comes from Yaya\u{2019}s Mail Helper. It shows up here once the helper is installed."
    static let offLineSmall = "The digest needs Yaya\u{2019}s Mail Helper."
    static let noneTitle = "No digest yet"
    static let noneLine = "Your mail server writes one each morning. It lands here as soon as it\u{2019}s ready."
    static let noneLineSmall = "One lands each morning."
    static let noneButton = "Open the digest"
    static let quiet = "Nothing left this inbox"
    static let allRead = "All read"

    static var all: [String] {
        [offTitle, offTitleSmall, offLine, offLineSmall, noneTitle, noneLine, noneLineSmall, noneButton, quiet, allRead]
    }
}

/// The digest of one entry: sections with their read state, one box per mailbox with its own unread count.
struct WidgetDigest {
    struct Section: Equatable {
        let key: String
        let title: String
        let count: Int
        let read: Bool

        /// The chip's word: the helper's usual keys get one short word, any other key its title.
        var short: String {
            switch key {
            case "newsletters": return "Newsletters"
            case "updates": return "Updates"
            case "promotions": return "Deals"
            case "social": return "Social"
            case "orders": return "Orders"
            case "security": return "Security"
            case "forums": return "Forums"
            default: return title
            }
        }
    }

    struct Line: Equatable {
        let text: String
        let section: String
        let pick: Bool
    }

    struct Box {
        let account: WidgetAccount
        /// The helper's address for a mailbox the calendar doesn't know; nil otherwise.
        let label: String?
        let counts: [String: Int]
        let top: [Line]
        /// Items in sections not read yet.
        let unread: Int
        let total: Int
        /// Where its tap goes: its first section not read yet, else its first section; nil = the digest's top.
        let part: String?

        /// "ORB", "Personal", or for a mailbox the calendar doesn't know its address's domain ("Lanternhall").
        var name: String {
            if !account.short.isEmpty { return account.short }
            guard let label else { return account.name }
            let domain = label.split(separator: "@").last.map(String.init) ?? label
            return (domain.split(separator: ".").first.map(String.init) ?? domain).capitalizedFirst
        }
        /// The longer name for the larger cards ("Orbital Pickle Co.", or the address itself).
        var longName: String { account.name.isEmpty ? (label ?? name) : account.name }
    }

    let id: Int
    let dayKey: String
    let day: Date?
    let total: Int
    let sections: [Section]
    let boxes: [Box]

    init(_ d: WidgetSnapshot.Digest, account: (String) -> WidgetAccount) {
        id = d.id
        dayKey = d.day
        day = DayName.parseDay(d.day)
        total = max(0, d.total)
        let sections = d.sections.prefix(WidgetSnapshot.Digest.maxSections).map {
            Section(key: $0.key, title: $0.title, count: max(0, $0.count), read: $0.read)
        }
        self.sections = sections
        let read = Set(sections.filter(\.read).map(\.key))
        let order = sections.map(\.key)
        boxes = d.boxes.prefix(WidgetSnapshot.Digest.maxBoxes).map { b in
            let counts = b.counts.filter { $0.value > 0 }
            let unread = counts.filter { !read.contains($0.key) }.reduce(0) { $0 + $1.value }
            let mine = order.filter { (counts[$0] ?? 0) > 0 }
            let lines = b.top.prefix(WidgetSnapshot.Digest.maxLines).map {
                Line(text: $0.text, section: $0.section, pick: $0.pick ?? false)
            }
            return Box(account: account(b.account), label: b.label, counts: counts, top: Array(lines), unread: unread,
                       total: counts.values.reduce(0, +), part: mine.first { !read.contains($0) } ?? mine.first)
        }
    }

    /// Items in sections not read yet: the badge.
    var unread: Int { sections.filter { !$0.read }.reduce(0) { $0 + $1.count } }
    var unreadSections: Int { sections.filter { !$0.read && $0.count > 0 }.count }
    var allRead: Bool { unread == 0 }
    /// Where the badge and the header go: the first section not read yet (nil = the digest's top).
    var firstUnread: String? { sections.first { !$0.read && $0.count > 0 }?.key }
    func section(_ key: String) -> Section? { sections.first { $0.key == key } }
    func isRead(_ key: String) -> Bool { section(key)?.read ?? false }

    /// The summary of the summary: the top lines across mailboxes, unread sections first, picks first, one mailbox
    /// at a time so one busy inbox doesn't fill it.
    func headlines(_ n: Int) -> [Line] {
        guard n > 0 else { return [] }
        let all = boxes.flatMap { $0.top }
        func rank(_ l: Line) -> Int { (isRead(l.section) ? 2 : 0) + (l.pick ? 0 : 1) }
        var out: [Line] = []
        // Round-robin over mailboxes, each box's lines in order, then sorted by rank (stable).
        let byBox = boxes.map { $0.top }
        var i = 0
        var seen = Set<String>()
        while out.count < all.count, i < WidgetSnapshot.Digest.maxLines {
            for lines in byBox where i < lines.count {
                let l = lines[i]
                if seen.insert(l.text).inserted { out.append(l) }
            }
            i += 1
        }
        let ranked = out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return Array(ranked.prefix(n))
    }

    /// "Social 5 · Deals 2 · Updates 1": unread sections, then read ones.
    func countsLine(limit: Int = 4) -> String {
        let ordered = sections.filter { !$0.read && $0.count > 0 } + sections.filter { $0.read && $0.count > 0 }
        guard !ordered.isEmpty else { return total == 0 ? "Nothing left your inbox" : "\(total) emails" }
        let shown = ordered.prefix(limit).map { "\($0.short) \($0.count)" }
        let more = ordered.count - shown.count
        return (shown + (more > 0 ? ["+\(more)"] : [])).joined(separator: " \u{00B7} ")
    }

    /// "Today", "Yesterday" or "Thu 29 Oct" for the entry date.
    func dayLabel(now: Date, long: Bool = false) -> String {
        guard let day else { return "Latest" }
        let cal = WidgetCalendar.current
        if cal.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)), cal.isDate(day, inSameDayAs: y) {
            return "Yesterday"
        }
        return DayName.format(long ? "EEEE d MMMM" : "EEE d MMM", day)
    }

    /// "Friday 30 October" (the header's second half), or nil without a parsable day.
    func dayLong() -> String? { day.map { DayName.format("EEEE d MMMM", $0) } }
}

// MARK: - Layout

enum DigestLayout {
    /// How many of `count` items fit `height` at `item` points each with `gap` between them, keeping a "+N more" line
    /// of `more` points when some don't.
    static func fit(_ count: Int, height: CGFloat, item: CGFloat, gap: CGFloat = 0, more: CGFloat) -> (shown: Int, hidden: Int) {
        guard count > 0, item > 0 else { return (0, 0) }
        func need(_ n: Int) -> CGFloat { CGFloat(n) * item + CGFloat(max(0, n - 1)) * gap }
        if need(count) <= height + 0.01 { return (count, 0) }
        var n = count - 1
        while n > 0, need(n) + gap + more > height + 0.01 { n -= 1 }
        return (n, count - n)
    }

    /// Medium: the name over its first line.
    static func mediumRow(_ style: WidgetStyle) -> CGFloat { 33 * style.scale }
    /// Large: the name over one or two lines.
    static func largeRow(_ style: WidgetStyle, lines: Int = 1) -> CGFloat { (24 + 15 * CGFloat(max(1, lines))) * style.scale + 1 }
    static func moreLine(_ style: WidgetStyle) -> CGFloat { 16 * style.scale }

    /// Mailbox rows Medium shows (and how many go into "+N more").
    static func medium(_ boxes: Int, style: WidgetStyle) -> (shown: Int, hidden: Int) {
        fit(boxes, height: Family.medium.size.height - 26, item: mediumRow(style), more: moreLine(style))
    }

    /// Large: the space under the header, the summary and the chips.
    static func large(_ boxes: Int, headlines: Int, style: WidgetStyle) -> (shown: Int, hidden: Int, lines: Int) {
        // Padding, the header, the summary, the chips and the stack's four gaps.
        let used = 28 + headerHeight(style) + summaryHeight(headlines, style: style) + 22 * style.scale + 40
        let height = Family.large.size.height - used
        // Two lines a mailbox when every mailbox still fits, else one.
        let two = fit(boxes, height: height, item: largeRow(style, lines: 2), gap: 1, more: moreLine(style) + 2)
        if two.hidden == 0 { return (two.shown, 0, 2) }
        let one = fit(boxes, height: height, item: largeRow(style), gap: 1, more: moreLine(style) + 2)
        return (one.shown, one.hidden, 1)
    }

    /// Extra Large: a grid of two columns on the right.
    static func gridCard(lines: Int, style: WidgetStyle) -> CGFloat { (34 + 16 * CGFloat(lines)) * style.scale + 4 }

    static func extraLarge(_ boxes: Int, style: WidgetStyle) -> (shown: Int, hidden: Int, lines: Int) {
        let height = Family.extraLarge.size.height - 28 - headerHeight(style) - 10
        for lines in [3, 2, 1, 0] {
            let rows = Int((height + 8) / (gridCard(lines: lines, style: style) + 8))
            if rows * 2 >= boxes || lines == 0 {
                let capacity = max(rows, 1) * 2
                if boxes <= capacity { return (boxes, 0, lines) }
                return (capacity - 1, boxes - capacity + 1, lines)
            }
        }
        return (0, boxes, 0)
    }

    /// Extra Large Portrait: full-width cards, each with up to 3 lines (fewer when space runs short).
    static func portrait(_ boxes: Int, headlines: Int, style: WidgetStyle) -> (shown: Int, hidden: Int, lines: Int) {
        let used = 28 + headerHeight(style) + summaryHeight(headlines, style: style) + 24 * style.scale + 40
        let height = Family.extraLargePortrait.size.height - used
        for lines in [3, 2, 1] {
            let f = fit(boxes, height: height, item: gridCard(lines: lines, style: style), gap: 8, more: moreLine(style))
            if f.hidden == 0 || lines == 1 { return (f.shown, f.hidden, lines) }
        }
        return (0, boxes, 1)
    }

    /// "Daily Digest" over the day line.
    static func headerHeight(_ style: WidgetStyle) -> CGFloat { 34 * style.scale }

    static func summaryHeight(_ headlines: Int, style: WidgetStyle) -> CGFloat {
        headlines == 0 ? 0 : 16 + CGFloat(headlines) * 17 * style.scale
    }
}

// MARK: - The widget

struct DigestWidget: View {
    let family: Family
    let digest: WidgetDigest
    let now: Date
    let style: WidgetStyle

    var body: some View {
        WidgetCard(family, style) {
            switch family {
            case .small: DigestSmall(digest: digest, now: now, style: style)
            case .medium: DigestMedium(digest: digest, now: now, style: style)
            case .large: DigestLarge(digest: digest, now: now, style: style)
            case .extraLarge: DigestExtraLarge(digest: digest, now: now, style: style)
            case .extraLargePortrait: DigestPortrait(digest: digest, now: now, style: style)
            }
        }
    }

    /// Headlines in the summary card per family.
    static func headlineCount(_ family: Family) -> Int {
        switch family {
        case .small, .medium: return 0
        case .large: return 2
        case .extraLarge, .extraLargePortrait: return 3
        }
    }

    /// Mailboxes drawn (for the manifest and tests), the rest go into "+N more".
    static func shownBoxes(family: Family, digest: WidgetDigest, style: WidgetStyle) -> Int {
        let n = digest.boxes.count
        let h = digest.headlines(headlineCount(family)).count
        switch family {
        case .small: return min(n, DigestSmall.maxMarks)
        case .medium: return DigestLayout.medium(n, style: style).shown
        case .large: return DigestLayout.large(n, headlines: h, style: style).shown
        case .extraLarge: return DigestLayout.extraLarge(n, style: style).shown
        case .extraLargePortrait: return DigestLayout.portrait(n, headlines: h, style: style).shown
        }
    }
}

/// The digest's links: the Digest tab, at a section when there is one.
extension WidgetLinkContext {
    func digest(_ part: String? = nil) -> URL { YayaLink.openDigest(part: part) }
}

extension YayaLink {
    /// `open/app?section=mailhelper&tab=digest[&part=<section>]` (D-053).
    static func openDigest(part: String? = nil) -> URL {
        var query: [(String, String)] = [("section", AppSection.mailHelper.rawValue), ("tab", "digest")]
        if let part, Route.isSafeValue(part) { query.append(("part", part)) }
        return url("open/app", query)
    }
}

// MARK: Pieces

/// "8 unread" on the accent, or a quiet "✓ All read".
struct DigestBadge: View {
    let digest: WidgetDigest
    let style: WidgetStyle
    var big = false

    var body: some View {
        let p = style.palette
        let size: CGFloat = big ? 11.5 : 10.5
        Group {
            if digest.allRead {
                HStack(spacing: 3.5) {
                    Image(systemName: "checkmark").font(.system(size: (size - 1.5) * style.scale, weight: .heavy))
                    Text(DigestCopy.allRead).font(style.font(size, .bold))
                }
                .foregroundStyle(p.accent)
                .padding(.horizontal, 8)
                .frame(height: (big ? 22 : 19) * style.scale)
                .background(Capsule().fill(p.accentSoft))
            } else {
                HStack(spacing: 4) {
                    Text("\(digest.unread)").font(style.font(size + 0.5, .heavy)).monospacedDigit()
                    Text("unread").font(style.font(size - 0.5, .semibold))
                }
                .foregroundStyle(p.onAccent)
                .padding(.horizontal, 8.5)
                .frame(height: (big ? 22 : 19) * style.scale)
                .background(Capsule().fill(p.accentFill))
            }
        }
        .fixedSize()
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetA11y.digestBadge(unread: digest.unread))
    }
}

/// A mailbox's mark: its logo, or its initial on its own colour (Personal has no logo, and a mailbox without one
/// still gets a face).
struct MailboxMark: View {
    let account: WidgetAccount
    let name: String
    let style: WidgetStyle
    var size: CGFloat = 18

    var body: some View {
        let p = style.palette
        let side = size * style.scale
        let radius = side * 0.3
        if style.showLogos, account.logo != nil {
            AccountBadge(account: account, style: style, size: size)
        } else {
            let tint = account.color.map { Color(hex: UInt32($0 & 0xFFFFFF)) } ?? p.accent
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: side * 0.52, weight: .heavy, design: style.design))
                .foregroundStyle(style.mono ? p.text : Color.white)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(style.mono ? p.band : tint))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(p.rule, lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }
}

/// A mailbox's count: its unread items on the accent, ✓ once its sections are read, "–" on a quiet day.
struct DigestCountPill: View {
    let box: WidgetDigest.Box
    let style: WidgetStyle

    var body: some View {
        let p = style.palette
        Group {
            if box.unread > 0 {
                Text("\(box.unread)").font(style.font(10.5, .heavy)).monospacedDigit().foregroundStyle(p.accent)
                    .padding(.horizontal, 6.5).frame(minWidth: 20 * style.scale).frame(height: 17 * style.scale)
                    .background(Capsule().fill(p.accentSoft))
                    .widgetAccentable()
            } else if box.total > 0 {
                Image(systemName: "checkmark").font(.system(size: 9 * style.scale, weight: .heavy)).foregroundStyle(p.text3)
                    .frame(width: 20 * style.scale, height: 17 * style.scale)
            } else {
                Text("\u{2013}").font(style.font(11, .bold)).foregroundStyle(p.text3)
                    .frame(width: 20 * style.scale, height: 17 * style.scale)
            }
        }
        .fixedSize()
    }
}

/// One line of the digest: ✦ for "worth opening", a dot otherwise; dimmer once its section is read.
struct DigestLineView: View {
    let line: WidgetDigest.Line
    let read: Bool
    let style: WidgetStyle
    var size: CGFloat = 11.5
    var strong = false

    var body: some View {
        let p = style.palette
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Group {
                if line.pick {
                    Image(systemName: "sparkle").font(.system(size: (size - 2.5) * style.scale, weight: .bold))
                        .foregroundStyle(read ? p.text3 : p.accent).widgetAccentable()
                } else {
                    Circle().fill(read ? p.rule : p.text3).frame(width: 3.5 * style.scale, height: 3.5 * style.scale)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 3 * style.scale }
                }
            }
            .frame(width: 9 * style.scale)
            Text(verbatim: line.text)
                .font(style.font(size, strong ? .semibold : .medium))
                .foregroundStyle(read ? p.text3 : (strong ? p.text : p.text2))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// A section's chip: "Social 5", or "Social ✓" once read. Each opens its section.
struct DigestChip: View {
    let section: WidgetDigest.Section
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        WidgetLink(destination: links.digest(section.key)) {
            HStack(spacing: 4) {
                Text(verbatim: section.short).font(style.font(10.5, .semibold))
                    .foregroundStyle(section.read ? p.text3 : p.text)
                if section.read {
                    Image(systemName: "checkmark").font(.system(size: 8 * style.scale, weight: .heavy)).foregroundStyle(p.text3)
                } else {
                    Text("\(section.count)").font(style.font(10.5, .heavy)).monospacedDigit().foregroundStyle(p.accent)
                        .widgetAccentable()
                }
            }
            .padding(.horizontal, 8).frame(height: 22 * style.scale)
            .background(Capsule().fill(section.read ? Color.clear : p.band))
            .overlay(Capsule().strokeBorder(p.rule, lineWidth: 1))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetA11y.digestSection(section.title, count: section.count, read: section.read))
        }
    }
}

/// The chips that fit one line, in order (unread sections first); the rest as "+N".
struct DigestChips: View {
    let digest: WidgetDigest
    let style: WidgetStyle
    let width: CGFloat

    var body: some View {
        let ordered = digest.sections.filter { !$0.read && $0.count > 0 } + digest.sections.filter { $0.read && $0.count > 0 }
        let n = Self.fitting(ordered, width: width, style: style)
        HStack(spacing: 6) {
            ForEach(Array(ordered.prefix(n).enumerated()), id: \.offset) { _, s in DigestChip(section: s, style: style) }
            if n < ordered.count {
                Text("+\(ordered.count - n)").font(style.font(10.5, .bold)).foregroundStyle(style.palette.text3)
            }
            Spacer(minLength: 0)
        }
    }

    /// A chip's width estimate (words at about 0.56 em, digits 0.62 em, plus padding and gap).
    static func chipWidth(_ s: WidgetDigest.Section, style: WidgetStyle) -> CGFloat {
        let word = CGFloat(s.short.count) * 10.5 * 0.57 * style.scale
        let tail = s.read ? 8 * style.scale : CGFloat("\(s.count)".count) * 10.5 * 0.64 * style.scale
        return word + 4 + tail + 16 + 6
    }

    static func fitting(_ sections: [WidgetDigest.Section], width: CGFloat, style: WidgetStyle) -> Int {
        var used: CGFloat = 0
        for (i, s) in sections.enumerated() {
            let w = chipWidth(s, style: style)
            let reserve: CGFloat = i < sections.count - 1 ? 26 * style.scale : 0
            if used + w + reserve > width { return i }
            used += w
        }
        return sections.count
    }
}

/// The header of Large and up: mark, "Daily Digest", the day; the badge and ↻ at the other end.
struct DigestHeader: View {
    let digest: WidgetDigest
    let now: Date
    let style: WidgetStyle
    var mark = true
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        HStack(alignment: .center, spacing: 8) {
            WidgetLink(destination: links.digest()) {
                VStack(alignment: .leading, spacing: 1) {
                    HeaderMarked(style: style, show: mark) {
                        Text("Daily Digest").font(style.font(15, .bold)).foregroundStyle(p.text).lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text(digest.dayLabel(now: now)).font(style.font(10.5, .bold)).foregroundStyle(p.accent)
                            .widgetAccentable()
                        if digest.dayLabel(now: now) == "Today" || digest.dayLabel(now: now) == "Yesterday",
                           let long = digest.dayLong() {
                            Text("\u{00B7} \(long)").font(style.font(10.5)).foregroundStyle(p.text2)
                        }
                    }
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            WidgetLink(destination: links.digest(digest.firstUnread)) { DigestBadge(digest: digest, style: style) }
            RefreshButton(style: style)
        }
    }
}

/// The summary of the summary: the top lines across mailboxes on a soft band, each opening its section.
struct DigestSummaryCard: View {
    let lines: [WidgetDigest.Line]
    let digest: WidgetDigest
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        VStack(alignment: .leading, spacing: 4 * style.scale) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                WidgetLink(destination: links.digest(line.section)) {
                    DigestLineView(line: line, read: digest.isRead(line.section), style: style, size: 12, strong: i == 0)
                        .frame(height: 13 * style.scale)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(WidgetA11y.digestLine(line.text, pick: line.pick))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.band))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(digest.allRead ? p.rule : p.accent).frame(width: 3).padding(.vertical, 9).padding(.leading, 0.5)
                .widgetAccentable()
        }
    }
}

/// "+2 more mailboxes".
struct DigestMoreLine: View {
    let hidden: Int
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        WidgetLink(destination: links.digest()) {
            HStack(spacing: 4) {
                Text(hidden == 1 ? "+1 more mailbox" : "+\(hidden) more mailboxes").font(style.font(10.5, .semibold))
                Image(systemName: "chevron.right").font(.system(size: 7.5 * style.scale, weight: .heavy))
            }
            .foregroundStyle(style.palette.text3)
            .frame(height: DigestLayout.moreLine(style))
        }
    }
}

/// One mailbox as a row: mark, name, its first line, its count. The whole row opens its first unread section.
struct DigestBoxRow: View {
    let box: WidgetDigest.Box
    let digest: WidgetDigest
    let style: WidgetStyle
    /// Large: the long name over `lines` lines; Medium (false): the short name over one line.
    var tall = false
    var lines = 1
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        let line = box.top.first
        let shown = tall ? max(1, lines) : 1
        WidgetLink(destination: links.digest(box.part)) {
            HStack(alignment: .center, spacing: tall ? 9 : 8) {
                MailboxMark(account: box.account, name: box.name, style: style, size: tall ? 22 : 18)
                VStack(alignment: .leading, spacing: tall ? 2 : 1) {
                    Text(verbatim: tall ? box.longName : box.name)
                        .font(style.font(tall ? 12.5 : 11.5, tall ? .semibold : .bold)).foregroundStyle(p.text).lineLimit(1)
                    if box.top.isEmpty {
                        lineText(nil, size: tall ? 11 : 10.5)
                    } else {
                        ForEach(Array(box.top.prefix(shown).enumerated()), id: \.offset) { _, l in lineText(l, size: tall ? 11 : 10.5) }
                    }
                }
                Spacer(minLength: 2)
                DigestCountPill(box: box, style: style)
            }
            .frame(height: tall ? DigestLayout.largeRow(style, lines: lines) : DigestLayout.mediumRow(style))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetA11y.digestBox(box.longName, unread: box.unread, total: box.total, line: line?.text))
        }
    }

    @ViewBuilder
    private func lineText(_ line: WidgetDigest.Line?, size: CGFloat) -> some View {
        let p = style.palette
        if let line {
            HStack(spacing: 4) {
                Group {
                    if line.pick {
                        Image(systemName: "sparkle").font(.system(size: (size - 2.5) * style.scale, weight: .bold))
                            .foregroundStyle(digest.isRead(line.section) ? p.text3 : p.accent).widgetAccentable()
                    } else {
                        Circle().fill(digest.isRead(line.section) ? p.rule : p.text3).frame(width: 3.5 * style.scale, height: 3.5 * style.scale)
                    }
                }
                .frame(width: 9 * style.scale)
                Text(verbatim: line.text).font(style.font(size)).lineLimit(1)
                    .foregroundStyle(digest.isRead(line.section) ? p.text3 : p.text2)
            }
        } else {
            Text(DigestCopy.quiet).font(style.font(size)).foregroundStyle(p.text3).lineLimit(1)
        }
    }
}

/// One mailbox as a card (Extra Large and Portrait): mark, name, count, then up to `lines` lines.
struct DigestBoxCard: View {
    let box: WidgetDigest.Box
    let digest: WidgetDigest
    let style: WidgetStyle
    let lines: Int
    /// Extra Large's grid: every card the same height. Portrait: each card as tall as its lines.
    var fill = true
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        WidgetLink(destination: links.digest(box.part)) {
            VStack(alignment: .leading, spacing: 4 * style.scale) {
                HStack(spacing: 7) {
                    MailboxMark(account: box.account, name: box.name, style: style, size: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: box.longName).font(style.font(12, .bold)).foregroundStyle(p.text).lineLimit(1)
                        Text(Self.subline(box, digest: digest)).font(style.font(9.5, .medium)).foregroundStyle(p.text3).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    DigestCountPill(box: box, style: style)
                }
                if lines > 0 {
                    if box.top.isEmpty {
                        Text(DigestCopy.quiet).font(style.font(11)).foregroundStyle(p.text3).lineLimit(1)
                            .frame(height: 12 * style.scale)
                    } else {
                        ForEach(Array(box.top.prefix(lines).enumerated()), id: \.offset) { _, line in
                            DigestLineView(line: line, read: digest.isRead(line.section), style: style, size: 11)
                                .frame(height: 12 * style.scale)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(height: fill ? DigestLayout.gridCard(lines: lines, style: style) : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.band))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.rule, lineWidth: 0.5))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetA11y.digestBox(box.longName, unread: box.unread, total: box.total, line: box.top.first?.text))
        }
    }

    /// "ORB · Social 5 · Deals 1": its tag, then its sections.
    static func subline(_ box: WidgetDigest.Box, digest: WidgetDigest) -> String {
        let parts = digest.sections.compactMap { s -> String? in
            guard let n = box.counts[s.key], n > 0 else { return nil }
            return "\(s.short) \(n)"
        }
        let head = box.account.short.isEmpty || box.account.short == box.longName ? [] : [box.account.short]
        let all = head + (parts.isEmpty ? [box.total == 0 ? "Quiet day" : "\(box.total) emails"] : Array(parts.prefix(3)))
        return all.joined(separator: " \u{00B7} ")
    }
}

// MARK: Families

struct DigestSmall: View {
    let digest: WidgetDigest
    let now: Date
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    static let maxMarks = 4

    /// "3 sections to read" (Small, Medium): the counts line needs more room than they have.
    static func toRead(_ d: WidgetDigest) -> String {
        d.unreadSections == 1 ? "1 section to read" : "\(d.unreadSections) sections to read"
    }

    static func mailboxes(_ d: WidgetDigest) -> String { d.boxes.count == 1 ? "1 mailbox" : "\(d.boxes.count) mailboxes" }

    var body: some View {
        let p = style.palette
        ZStack(alignment: .topTrailing) {
            WidgetLink(destination: links.digest(digest.firstUnread)) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("DIGEST").font(style.font(10, .heavy)).tracking(0.8).foregroundStyle(p.accent).widgetAccentable()
                        .frame(height: 18, alignment: .center)
                    Text(digest.dayLabel(now: now)).font(style.font(11, .semibold)).foregroundStyle(p.text2).lineLimit(1)
                    Spacer(minLength: 2)
                    if digest.allRead {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 24 * style.scale, weight: .semibold))
                                .foregroundStyle(p.accent).widgetAccentable()
                            Text(DigestCopy.allRead).font(style.font(16, .heavy)).foregroundStyle(p.text).lineLimit(1)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(digest.unread)").font(.system(size: 38 * style.scale, weight: .heavy, design: .rounded))
                                .monospacedDigit().foregroundStyle(p.text).minimumScaleFactor(0.6)
                            Text("unread").font(style.font(12, .semibold)).foregroundStyle(p.text2)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(WidgetA11y.digestBadge(unread: digest.unread))
                    }
                    Spacer(minLength: 4)
                    marks
                    Text(digest.allRead ? Self.mailboxes(digest) : Self.toRead(digest))
                        .font(style.font(10, .medium)).foregroundStyle(p.text3).lineLimit(1).padding(.top, 5)
                }
                .padding(14)
                .frame(width: Family.small.size.width, height: Family.small.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            RefreshButton(style: style).padding(14)
        }
    }

    private var marks: some View {
        let p = style.palette
        let shown = digest.boxes.prefix(Self.maxMarks)
        return HStack(spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, box in
                MailboxMark(account: box.account, name: box.name, style: style, size: 18)
                    .overlay(alignment: .topTrailing) {
                        if box.unread > 0 {
                            Circle().fill(p.accentFill).frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(p.backgroundTop, lineWidth: style.mono ? 0 : 1.5))
                                .offset(x: 2.5, y: -2.5).widgetAccentable()
                        }
                    }
            }
            if digest.boxes.count > shown.count {
                Text("+\(digest.boxes.count - shown.count)").font(style.font(10.5, .bold)).foregroundStyle(p.text3)
            }
        }
    }
}

struct DigestMedium: View {
    let digest: WidgetDigest
    let now: Date
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        let fit = DigestLayout.medium(digest.boxes.count, style: style)
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                WidgetLink(destination: links.digest(digest.firstUnread)) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("DAILY DIGEST").font(style.font(9.5, .heavy)).tracking(0.8).foregroundStyle(p.accent).widgetAccentable()
                            .frame(height: 18, alignment: .center)
                        Text(digest.dayLabel(now: now)).font(style.font(17, .bold)).foregroundStyle(p.text).lineLimit(1)
                        if let day = digest.day, digest.dayLabel(now: now) == "Today" || digest.dayLabel(now: now) == "Yesterday" {
                            Text(DayName.format("EEE d MMM", day)).font(style.font(10.5)).foregroundStyle(p.text2).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if digest.allRead {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 18 * style.scale, weight: .semibold))
                                    .foregroundStyle(p.accent).widgetAccentable()
                                Text(DigestCopy.allRead).font(style.font(14, .heavy)).foregroundStyle(p.text)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(digest.unread)").font(.system(size: 30 * style.scale, weight: .heavy, design: .rounded))
                                    .monospacedDigit().foregroundStyle(p.text)
                                Text("unread").font(style.font(11, .semibold)).foregroundStyle(p.text2)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(WidgetA11y.digestBadge(unread: digest.unread))
                        }
                        Text(digest.allRead ? DigestSmall.mailboxes(digest) : DigestSmall.toRead(digest))
                            .font(style.font(10, .medium)).foregroundStyle(p.text3).lineLimit(1).padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                RefreshButton(style: style)
            }
            .frame(width: 118 * min(style.scale, 1.06))
            Rectangle().fill(p.rule).frame(width: 1).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(digest.boxes.prefix(fit.shown).enumerated()), id: \.offset) { _, box in
                    DigestBoxRow(box: box, digest: digest, style: style)
                }
                if fit.hidden > 0 { DigestMoreLine(hidden: fit.hidden, style: style) }
                Spacer(minLength: 0)
            }
        }
        .padding(13)
        .frame(width: Family.medium.size.width, height: Family.medium.size.height, alignment: .topLeading)
    }
}

struct DigestLarge: View {
    let digest: WidgetDigest
    let now: Date
    let style: WidgetStyle

    var body: some View {
        let lines = digest.headlines(DigestWidget.headlineCount(.large))
        let fit = DigestLayout.large(digest.boxes.count, headlines: lines.count, style: style)
        VStack(alignment: .leading, spacing: 10) {
            DigestHeader(digest: digest, now: now, style: style)
            if !lines.isEmpty { DigestSummaryCard(lines: lines, digest: digest, style: style) }
            DigestChips(digest: digest, style: style, width: Family.large.size.width - 28)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(digest.boxes.prefix(fit.shown).enumerated()), id: \.offset) { i, box in
                    if i > 0 { Rectangle().fill(style.palette.rule).frame(height: 1).padding(.leading, 30 * style.scale) }
                    DigestBoxRow(box: box, digest: digest, style: style, tall: true, lines: fit.lines)
                }
                if fit.hidden > 0 { DigestMoreLine(hidden: fit.hidden, style: style).padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: Family.large.size.width, height: Family.large.size.height, alignment: .topLeading)
    }
}

struct DigestExtraLarge: View {
    let digest: WidgetDigest
    let now: Date
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        let lines = digest.headlines(DigestWidget.headlineCount(.extraLarge))
        let grid = DigestLayout.extraLarge(digest.boxes.count, style: style)
        let shown = Array(digest.boxes.prefix(grid.shown))
        VStack(alignment: .leading, spacing: 10) {
            DigestHeader(digest: digest, now: now, style: style)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty {
                        Text(digest.total == 0 ? DigestCopy.quiet : digest.countsLine())
                            .font(style.font(12, .medium)).foregroundStyle(p.text2)
                    } else {
                        DigestSummaryCard(lines: lines, digest: digest, style: style)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(digest.sections.filter { $0.count > 0 }.prefix(5).enumerated()), id: \.offset) { i, s in
                            if i > 0 { Rectangle().fill(p.rule).frame(height: 1) }
                            sectionRow(s)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 290)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<((shown.count + (grid.hidden > 0 ? 1 : 0) + 1) / 2), id: \.self) { row in
                        HStack(spacing: 8) {
                            cell(row * 2, shown: shown, hidden: grid.hidden, lines: grid.lines)
                            cell(row * 2 + 1, shown: shown, hidden: grid.hidden, lines: grid.lines)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(width: Family.extraLarge.size.width, height: Family.extraLarge.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func cell(_ i: Int, shown: [WidgetDigest.Box], hidden: Int, lines: Int) -> some View {
        if i < shown.count {
            DigestBoxCard(box: shown[i], digest: digest, style: style, lines: lines)
        } else if i == shown.count, hidden > 0 {
            DigestMoreLine(hidden: hidden, style: style)
                .frame(maxWidth: .infinity).frame(height: DigestLayout.gridCard(lines: lines, style: style))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.palette.rule, lineWidth: 1))
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: DigestLayout.gridCard(lines: lines, style: style))
        }
    }

    private func sectionRow(_ s: WidgetDigest.Section) -> some View {
        let p = style.palette
        return WidgetLink(destination: links.digest(s.key)) {
            HStack(spacing: 7) {
                Circle().fill(s.read ? p.rule : p.accent).frame(width: 6, height: 6).widgetAccentable()
                Text(verbatim: s.title).font(style.font(11.5, .semibold)).foregroundStyle(s.read ? p.text3 : p.text).lineLimit(1)
                Spacer(minLength: 4)
                if s.read {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 8 * style.scale, weight: .heavy))
                        Text("Read").font(style.font(10, .semibold))
                    }
                    .foregroundStyle(p.text3)
                } else {
                    Text("\(s.count)").font(style.font(11, .heavy)).monospacedDigit().foregroundStyle(p.accent).widgetAccentable()
                }
            }
            .frame(height: 22 * style.scale)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WidgetA11y.digestSection(s.title, count: s.count, read: s.read))
        }
    }
}

struct DigestPortrait: View {
    let digest: WidgetDigest
    let now: Date
    let style: WidgetStyle

    var body: some View {
        let lines = digest.headlines(DigestWidget.headlineCount(.extraLargePortrait))
        let fit = DigestLayout.portrait(digest.boxes.count, headlines: lines.count, style: style)
        VStack(alignment: .leading, spacing: 10) {
            DigestHeader(digest: digest, now: now, style: style)
            if !lines.isEmpty { DigestSummaryCard(lines: lines, digest: digest, style: style) }
            DigestChips(digest: digest, style: style, width: Family.extraLargePortrait.size.width - 28)
                .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(digest.boxes.prefix(fit.shown).enumerated()), id: \.offset) { _, box in
                    DigestBoxCard(box: box, digest: digest, style: style, lines: fit.lines, fill: false)
                }
                if fit.hidden > 0 { DigestMoreLine(hidden: fit.hidden, style: style) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: Family.extraLargePortrait.size.width, height: Family.extraLargePortrait.size.height, alignment: .topLeading)
    }
}
