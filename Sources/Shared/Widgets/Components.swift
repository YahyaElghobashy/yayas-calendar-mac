import AppKit
import SwiftUI

/// The calendar's logo. Personal accounts have none and keep the slot empty so titles stay aligned.
struct AccountBadge: View {
    let account: WidgetAccount
    let style: WidgetStyle
    var size: CGFloat = 16
    /// Merged invites: how many other accounts have this meeting (a small "+1" on the badge corner).
    var alsoCount = 0

    var body: some View {
        let side = size * style.scale
        badge(side)
            .overlay(alignment: .bottomTrailing) {
                if alsoCount > 0, style.showLogos {
                    Text("+\(alsoCount)")
                        .font(.system(size: 6.5 * style.scale, weight: .heavy, design: style.design))
                        .foregroundStyle(style.palette.text)
                        .padding(.horizontal, 1.5)
                        .background(Capsule().fill(style.palette.backgroundTop))
                        .overlay(Capsule().strokeBorder(style.palette.rule, lineWidth: 0.5))
                        .offset(x: 4, y: 3)
                        .fixedSize()
                }
            }
    }

    private func badge(_ side: CGFloat) -> some View {
        Group {
            if style.showLogos, let logo = account.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    // Dark look: a paper plate behind the logo so dark marks stay visible.
                    .background(style.look == .ink ? Color(hex: 0xF8F5F0) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                        .strokeBorder(style.palette.rule, lineWidth: 0.5))
            } else {
                Color.clear.frame(width: side, height: side)
            }
        }
        .opacity(style.showLogos ? 1 : 0)
        .frame(width: style.showLogos ? side : 0)
    }
}

enum WidgetClock {
    static func time(_ date: Date, _ style: WidgetStyle, alwaysMinutes: Bool = false) -> (String, String) {
        if style.use24Hour { return (DayName.format("HH:mm", date), "") }
        let minutes = WidgetCalendar.current.component(.minute, from: date)
        return (DayName.format(minutes == 0 && !alwaysMinutes ? "h" : "h:mm", date), DayName.format("a", date))
    }

    static func range(_ m: WidgetMeeting, _ style: WidgetStyle) -> String {
        let (s, sa) = time(m.start, style), (e, ea) = time(m.end, style)
        if style.use24Hour { return "\(s) – \(e)" }
        return sa == ea ? "\(s) – \(e) \(ea)" : "\(s) \(sa) – \(e) \(ea)"
    }

    static func until(_ date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }
}

struct TimeLabel: View {
    let date: Date
    let style: WidgetStyle
    var emphasised = false
    var showSuffix = true

    var body: some View {
        let (main, suffix) = WidgetClock.time(date, style, alwaysMinutes: !showSuffix)
        HStack(alignment: .firstTextBaseline, spacing: 1.5) {
            Text(main).font(style.font(12, emphasised ? .semibold : .medium)).monospacedDigit()
                .foregroundStyle(emphasised ? style.palette.text : style.palette.text2)
            if showSuffix, !suffix.isEmpty {
                Text(suffix.lowercased()).font(style.font(9, .medium)).foregroundStyle(style.palette.text3)
            }
        }
    }
}

/// "Today · Monday 19 October" banner that opens each day. Days with ≤2 meetings get the slim form
/// (D-013): the same label on a hairline, no fill, 15 pt.
struct DayBanner: View {
    let day: Date
    let continued: Bool
    let count: Int
    let now: Date
    let style: WidgetStyle
    var compact = false
    var slim = false

    var body: some View {
        if slim { slimBody } else { fullBody }
    }

    private var isToday: Bool { WidgetCalendar.current.isDate(day, inSameDayAs: now) }

    private var fullBody: some View {
        let p = style.palette
        return HStack(spacing: 6) {
            if compact {
                Text(isToday ? "Today" : DayName.format("EEE d MMM", day))
                    .font(style.font(11.5, .bold)).foregroundStyle(isToday ? p.accent : p.text)
                Spacer(minLength: 0)
            } else {
                Text(DayName.title(day, now: now) + (continued ? ", continued" : ""))
                    .font(style.font(11.5, .bold))
                    .foregroundStyle(isToday ? p.accent : p.text)
                if !continued, !isToday {
                    Text(DayName.subtitle(day, now: now))
                        .font(style.font(11, .regular)).foregroundStyle(p.text2)
                }
                Spacer(minLength: 4)
                if !continued {
                    Text(count == 1 ? "1 meeting" : "\(count) meetings")
                        .font(style.font(10, .medium)).foregroundStyle(p.text3)
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: style.dayBanner)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(p.band))
    }

    private var slimBody: some View {
        let p = style.palette
        return HStack(spacing: 6) {
            if compact {
                Text(isToday ? "Today" : DayName.format("EEE d MMM", day))
                    .font(style.font(10.5, .bold)).foregroundStyle(isToday ? p.accent : p.text)
            } else {
                Text(DayName.title(day, now: now) + (continued ? ", continued" : ""))
                    .font(style.font(10.5, .bold)).foregroundStyle(isToday ? p.accent : p.text)
                if !continued, !isToday {
                    Text(DayName.subtitle(day, now: now)).font(style.font(10, .regular)).foregroundStyle(p.text2)
                }
            }
            Rectangle().fill(p.rule).frame(height: 1).frame(maxWidth: .infinity)
        }
        .lineLimit(1)
        .padding(.leading, 2)
        .frame(height: style.slimBanner)
    }
}

struct JoinButton: View {
    let style: WidgetStyle
    var big = false

    var body: some View {
        let p = style.palette
        HStack(spacing: 4) {
            Image(systemName: "video.fill").font(.system(size: (big ? 11 : 9) * style.scale, weight: .semibold))
            Text("Join").font(style.font(big ? 13 : 10.5, .semibold))
        }
        .foregroundStyle(p.onAccent)
        .padding(.horizontal, big ? 14 : 8)
        .frame(height: (big ? 30 : 18) * style.scale)
        .frame(maxWidth: big ? .infinity : nil)
        .background(Capsule().fill(p.accent))
    }
}

/// The row and its Join button are sibling Links, never nested (nested Links hit-test unpredictably).
/// Snapshot rows open the Event Peek (`open/event?r&k`); Join goes straight in (`join?r&k`); the
/// "Reply?" chip opens the Peek too, where Yes / Maybe / No live.
struct WidgetMeetingRow: View {
    let meeting: WidgetMeeting
    let now: Date
    let style: WidgetStyle
    /// Medium widget: no status chips, so titles get the room.
    var compact = false
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        let live = !meeting.allDay && meeting.start <= now && meeting.end > now
        let soon = !meeting.allDay && !live && meeting.start > now && meeting.start.timeIntervalSince(now) <= 30 * 60
        let highlighted = live || soon
        HStack(spacing: 7) {
            WidgetLink(destination: links.event(meeting)) {
                HStack(spacing: 7) {
                    AccountBadge(account: meeting.account, style: style, alsoCount: meeting.also.count)
                    Group {
                        if highlighted {
                            Text(live ? "Now" : WidgetClock.until(meeting.start, from: now).replacingOccurrences(of: " min", with: "m"))
                                .font(style.font(12, .bold)).foregroundStyle(p.accent).monospacedDigit()
                        } else if meeting.allDay {
                            Text("All day").font(style.font(11, .medium)).foregroundStyle(p.text2).lineLimit(1)
                        } else {
                            TimeLabel(date: meeting.start, style: style, showSuffix: !compact)
                        }
                    }
                    .frame(width: timeWidth, alignment: .leading)
                    Text(meeting.title)
                        .font(style.font(12.5, highlighted ? .semibold : .medium))
                        .foregroundStyle(meeting.reply == .maybe ? p.text2 : p.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken.label)
                .accessibilityValue(spoken.value)
            }
            trailing(highlighted: highlighted)
        }
        .padding(.horizontal, highlighted ? 6 : 0)
        .frame(height: style.meetingRow - 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(highlighted ? p.accentSoft : .clear))
        .padding(.horizontal, highlighted ? -6 : 0)
        .frame(height: style.meetingRow)
    }

    private var timeWidth: CGFloat {
        (style.use24Hour ? (compact ? 40 : 48) : (compact ? 40 : 54)) * style.scale
    }

    /// What VoiceOver reads for the row: title and accounts, then when, where and what is pending.
    private var spoken: (label: String, value: String) {
        WidgetA11y.meeting(meeting, now: now, use24Hour: style.use24Hour)
    }

    @ViewBuilder
    private func trailing(highlighted: Bool) -> some View {
        let p = style.palette
        if highlighted && meeting.hasLink {
            WidgetLink(destination: links.join(meeting)) { JoinButton(style: style).fixedSize() }
        } else if compact {
            EmptyView()
        } else if meeting.clashes {
            WidgetChip(text: "Overlaps", color: p.warn, fill: p.warnSoft, style: style)
        } else if meeting.reply == .needsReply {
            WidgetLink(destination: links.reply(meeting)) {
                WidgetChip(text: "Reply?", color: p.accent, fill: p.accentSoft, style: style)
            }
        } else if meeting.reply == .maybe {
            Text("Maybe").font(style.font(10, .medium)).foregroundStyle(p.text3)
        }
    }
}

struct WidgetChip: View {
    let text: String
    let color: Color
    let fill: Color
    let style: WidgetStyle

    var body: some View {
        Text(text).font(style.font(9.5, .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).frame(height: 16 * style.scale)
            .background(Capsule().fill(fill)).fixedSize()
    }
}

/// "‹ 1 of 3 ›": each enabled arrow is a `page` link for this widget (a CONTRACTS route).
struct WidgetPager: View {
    let page: Int
    let count: Int
    let style: WidgetStyle
    @Environment(\.widgetLinks) private var links

    var body: some View {
        let p = style.palette
        HStack(spacing: 5) {
            arrow("chevron.left", to: page - 1, enabled: page > 1)
                .accessibilityLabel(WidgetA11y.previousPage)
            Text("\(page) of \(count)").font(style.font(10.5, .medium)).foregroundStyle(p.text2).monospacedDigit()
                .accessibilityLabel(WidgetA11y.page(page, of: count))
            arrow("chevron.right", to: page + 1, enabled: page < count)
                .accessibilityLabel(WidgetA11y.nextPage)
        }
    }

    @ViewBuilder
    private func arrow(_ symbol: String, to target: Int, enabled: Bool) -> some View {
        let p = style.palette
        let circle = Image(systemName: symbol)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(enabled ? p.text : p.text3)
            .frame(width: 22, height: 22)
            .background(Circle().fill(p.band))
            .contentShape(Circle())
        if enabled {
            WidgetLink(destination: links.page(target)) { circle }
        } else {
            circle
        }
    }
}

/// Weekday in the accent colour over the date, plus a one-line summary of the day.
struct DateHeader: View {
    let now: Date
    let meetings: [WidgetMeeting]
    let style: WidgetStyle
    var compact = false
    @Environment(\.widgetLinks) private var links
    @Environment(\.widgetTitle) private var title

    var body: some View {
        let p = style.palette
        WidgetLink(destination: links.open(.calendar)) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(DayName.format("EEEE", now).uppercased())
                        .font(style.font(10.5, .bold)).tracking(0.6).foregroundStyle(p.accent)
                    if let title { WidgetTitleTag(title: title, style: style) }
                }
                Text(DayName.format("d MMMM", now))
                    .font(style.font(compact ? 17 : 19, .bold)).foregroundStyle(p.text)
                if !compact {
                    Text(DaySummary.text(meetings, now: now, style: style))
                        .font(style.font(10.5)).foregroundStyle(p.text2).lineLimit(1)
                }
            }
        }
    }
}

enum DaySummary {
    static func text(_ meetings: [WidgetMeeting], now: Date, style: WidgetStyle) -> String {
        let today = meetings.filter { !$0.allDay && WidgetCalendar.current.isDate($0.start, inSameDayAs: now) }
        guard let last = today.map(\.end).max() else { return "No meetings today. Enjoy it." }
        let left = today.filter { $0.end > now }.count
        let (t, s) = WidgetClock.time(last, style)
        return "\(left) of \(today.count) meetings left · free after \(t)\(s.isEmpty ? "" : " " + s)"
    }
}

struct WidgetCard<Content: View>: View {
    let family: Family
    let style: WidgetStyle
    let content: Content

    init(_ family: Family, _ style: WidgetStyle, @ViewBuilder content: () -> Content) {
        self.family = family; self.style = style; self.content = content()
    }

    var body: some View {
        let p = style.palette
        content
            .frame(width: family.size.width, height: family.size.height, alignment: .topLeading)
            .background(LinearGradient(colors: [p.backgroundTop, p.backgroundBottom], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, style.look == .paper ? .light : .dark)
    }
}

/// The Yaya mark at the far left of a Large or Extra Large header (brand/BRAND.md): 12 pt wide, in the accent,
/// inside the header's own link. ↻ (D-021) stays at the other end of the line.
struct HeaderMark: View {
    let style: WidgetStyle

    var body: some View {
        BrandMark().fill(style.palette.accent).frame(width: 12, height: 12 / BrandMark.aspect)
    }
}

/// A header title with `HeaderMark` before it, when the line has room: the mark gives way before the
/// title would truncate (a custom slot's name, Large text), so it never costs a word.
struct HeaderMarked<Content: View>: View {
    let style: WidgetStyle
    var show = true
    var spacing: CGFloat = 6
    @ViewBuilder let content: () -> Content

    var body: some View {
        if show {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: spacing) {
                    HeaderMark(style: style)
                    content()
                }
                content()
            }
        } else {
            content()
        }
    }
}

/// ↻ in a widget's header or top corner: `sync?w=<kind>` (meetings get cancelled and moved) re-lists the
/// calendars this widget shows (and its mail), then reloads it. A widget can't animate while the app
/// syncs; the reload that follows comes back with ✓ in the accent colour for
/// `WidgetHealthInfo.justSyncedWindow` ("synced just now"), then ↻ again. 18 pt tap target, text3 glyph:
/// quieter than the pager and Month arrows beside it.
struct RefreshButton: View {
    let style: WidgetStyle
    /// The Day widget's round button (its pager look, D-022): this diameter, text2 glyph on a band circle.
    /// Nil = the quiet 18 pt glyph every other widget uses.
    var round: CGFloat? = nil
    @Environment(\.widgetLinks) private var links
    @Environment(\.widgetJustSynced) private var justSynced

    static let side: CGFloat = 18

    var body: some View {
        let p = style.palette
        WidgetLink(destination: links.refresh()) {
            if let round {
                Image(systemName: justSynced ? "checkmark" : "arrow.clockwise")
                    .font(.system(size: round * 0.42, weight: .bold))
                    .foregroundStyle(justSynced ? p.accent : p.text2)
                    .frame(width: round, height: round)
                    .background(Circle().fill(p.band))
                    .contentShape(Circle())
            } else {
                Image(systemName: justSynced ? "checkmark" : "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(justSynced ? p.accent : p.text3)
                    .frame(width: Self.side, height: Self.side)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityLabel(justSynced ? "Synced just now" : "Refresh")
    }
}

/// The custom slot's name ("Work") in a header: a small soft capsule, never louder than the date.
struct WidgetTitleTag: View {
    let title: String
    let style: WidgetStyle

    var body: some View {
        Text(title)
            .font(style.font(9.5, .bold)).foregroundStyle(style.palette.accent)
            .lineLimit(1)
            .padding(.horizontal, 6).frame(height: 15 * style.scale)
            .background(Capsule().fill(style.palette.accentSoft))
            .fixedSize()
    }
}

/// The strip at the bottom of a widget: amber "ORB needs you to sign in again" (a `reauth` link) or a
/// quiet "Last synced 2 h ago". Overlays the card's bottom padding; Small and Medium keep their Join
/// buttons at the bottom, so there it is a shorter strip in the top padding (`compact`).
struct WidgetFooterView: View {
    let footer: WidgetFooter
    let style: WidgetStyle
    var compact = false

    static let height: CGFloat = 16
    static let compactHeight: CGFloat = 12
    /// What paged lists give up so the strip never covers a row (bottom padding is 13 pt).
    static let reserve: CGFloat = 7

    var body: some View {
        let p = style.palette
        switch footer {
        case .none:
            EmptyView()
        case .stale(let text):
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise").font(.system(size: compact ? 7 : 8, weight: .bold))
                Text(compact ? text.replacingOccurrences(of: "Last synced", with: "Synced") : text)
                    .font(style.font(compact ? 8.5 : 9.5, .semibold)).lineLimit(1)
            }
            .foregroundStyle(p.text2)
            .padding(.horizontal, compact ? 6 : 8).frame(height: compact ? Self.compactHeight : Self.height)
            .background(Capsule().fill(p.band).background(Capsule().fill(p.backgroundBottom)))
            .fixedSize()
        case .reauth(let tag, let link):
            let label = HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: compact ? 7.5 : 8.5, weight: .bold))
                Text(compact ? "\(tag): sign in again" : "\(tag) needs you to sign in again")
                    .font(style.font(compact ? 8.5 : 9.5, .semibold)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: compact ? 6 : 7, weight: .heavy))
            }
            .foregroundStyle(p.warn)
            .padding(.horizontal, compact ? 7 : 9).frame(height: compact ? Self.compactHeight : Self.height)
            .background(Capsule().fill(p.warnSoft).background(Capsule().fill(p.backgroundBottom)))
            .fixedSize()
            if let link {
                WidgetLink(destination: link) { label }
            } else {
                label
            }
        }
    }
}

/// Friendly whole-card states: no snapshot yet, no accounts, mail off. Same voice and
/// shape as the Custom "not set up yet" card; one tap target.
struct WidgetMessageCard: View {
    let family: Family
    let style: WidgetStyle
    let symbol: String
    let title: String
    let line: String
    var button: String? = nil
    let destination: URL
    /// The Yaya mark in the medallion instead of `symbol` (the setup states, brand/BRAND.md).
    var mark = false

    var body: some View {
        let p = style.palette
        let small = family == .small
        WidgetCard(family, style) {
            ZStack(alignment: .topTrailing) {
                WidgetLink(destination: destination) {
                    VStack(alignment: small ? .leading : .center, spacing: small ? 6 : 10) {
                        Group {
                            if mark {
                                BrandMark().fill(p.accent)
                                    .frame(width: (small ? 18 : 24) * style.scale, height: (small ? 18 : 24) * style.scale)
                            } else {
                                Image(systemName: symbol)
                                    .font(.system(size: (small ? 15 : 19) * style.scale, weight: .semibold))
                                    .foregroundStyle(p.accent)
                            }
                        }
                            .frame(width: small ? 36 : 48, height: small ? 36 : 48)
                            .background(Circle().fill(p.accentSoft))
                        Text(title)
                            .font(style.font(small ? 13 : 16, .bold)).foregroundStyle(p.text)
                            .multilineTextAlignment(small ? .leading : .center)
                            .fixedSize(horizontal: false, vertical: true)
                        if !line.isEmpty {
                            Text(line)
                                .font(style.font(small ? 11 : 12)).foregroundStyle(p.text2)
                                .multilineTextAlignment(small ? .leading : .center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if small { Spacer(minLength: 0) }
                        if let button {
                            HStack(spacing: 4) {
                                Text(button).font(style.font(11.5, .semibold))
                                Image(systemName: "arrow.right").font(.system(size: 9.5 * style.scale, weight: .bold))
                            }
                            .foregroundStyle(p.onAccent)
                            .padding(.horizontal, 12)
                            .frame(height: 26 * style.scale)
                            .background(Capsule().fill(p.accent))
                        }
                    }
                    .padding(small ? 14 : 24)
                    .frame(width: family.size.width, height: family.size.height, alignment: small ? .topLeading : .center)
                    .contentShape(Rectangle())
                }
                // A sibling of the card's link (never nested): the corner the other widgets keep ↻ in.
                RefreshButton(style: style).padding(Self.refreshInset(family))
            }
        }
    }

    /// Small cards keep their 14 pt padding; the larger ones put ↻ where a header's would be.
    static func refreshInset(_ family: Family) -> CGFloat { family == .small ? 14 : 13 }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
