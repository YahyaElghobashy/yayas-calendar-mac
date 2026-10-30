import Foundation

// VoiceOver words for widget rows and icon-only links. Shared, so the widget extension, the app's
// gallery and the Peek say the same thing; the app's own A11yText builds on it. Plain words only: the
// humour rules never reach VoiceOver.

enum WidgetA11y {
    /// A meeting row: label "Launch plan review, ORB", value "Today, 10:00 to 10:45 AM, in 12 minutes".
    static func meeting(_ m: WidgetMeeting, now: Date, use24Hour: Bool = false) -> (label: String, value: String) {
        var label = m.title.isEmpty ? "Meeting" : m.title
        let tags = m.accountsLabel.replacingOccurrences(of: "+", with: " and ")
        if !tags.isEmpty { label += ", \(tags)" }
        var parts: [String] = []
        let day = DayName.title(m.start, now: now)
        if m.allDay {
            parts.append("\(day), all day")
        } else {
            var style = WidgetStyle()
            style.use24Hour = use24Hour
            let range = WidgetClock.range(m, style).replacingOccurrences(of: " – ", with: " to ")
            parts.append("\(day), \(range)")
            if m.start <= now && m.end > now {
                parts.append("happening now")
            } else if m.start > now, m.start.timeIntervalSince(now) <= 30 * 60 {
                parts.append("starts in \(spokenDuration(m.start.timeIntervalSince(now)))")
            }
        }
        if let place = m.place, !place.isEmpty { parts.append("at \(place)") }
        if m.hasLink { parts.append("has a video link") }
        switch m.reply {
        case .needsReply: parts.append("not answered yet")
        case .maybe: parts.append("you said maybe")
        case .accepted: break
        }
        if m.clashes { parts.append("overlaps another meeting") }
        return (label, parts.joined(separator: ", "))
    }

    /// Minutes rounded up, in words: "1 minute", "1 hour 30 minutes", "2 days".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        if minutes < 60 { return unit(minutes, "minute") }
        let hours = minutes / 60, m = minutes % 60
        if hours < 24 { return m == 0 ? unit(hours, "hour") : "\(unit(hours, "hour")) \(unit(m, "minute"))" }
        let wholeHours = (minutes + 59) / 60
        let days = wholeHours / 24, h = wholeHours % 24
        return h == 0 ? unit(days, "day") : "\(unit(days, "day")) \(unit(h, "hour"))"
    }

    // MARK: Icon-only links

    static let previousPage = "Previous page"
    static let nextPage = "Next page"

    /// "Page 2 of 3" (the pager's middle text, read once with the arrows).
    static func page(_ page: Int, of count: Int) -> String { "Page \(page) of \(count)" }

    /// "Previous month, September" / "Next month, November" (the month the arrow goes to).
    static func month(forward: Bool, to month: Date) -> String {
        "\(forward ? "Next" : "Previous") month, \(DayName.format("MMMM", month))"
    }

    static func archive(_ subject: String) -> String { "Archive \(spokenSubject(subject))" }
    static func markRead(_ subject: String) -> String { "Mark \(spokenSubject(subject)) read" }
    static func undoArchive(_ subject: String) -> String { "Archived \(spokenSubject(subject)). Undo" }
    static let starred = "Starred"

    /// A mail row's main link: label "Unread, Juniper Vale, Launch checklist", value "9:41 AM, starred".
    static func mail(sender: String, subject: String, unread: Bool, starred: Bool, when: String) -> (label: String, value: String) {
        let label = (unread ? "Unread, " : "") + "\(sender.isEmpty ? "Unknown sender" : sender), \(spokenSubject(subject))"
        var parts = [when]
        if starred { parts.append(Self.starred.lowercased()) }
        return (label, parts.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    // MARK: Daily Digest (D-053)

    /// "8 unread in the digest" / "Digest, all read".
    static func digestBadge(unread: Int) -> String {
        unread == 0 ? "Digest, all read" : (unread == 1 ? "1 unread in the digest" : "\(unread) unread in the digest")
    }

    /// A mailbox: label "Orbital Pickle Co., 3 unread, A pickle-sized satellite arm…".
    static func digestBox(_ name: String, unread: Int, total: Int, line: String?) -> String {
        var parts = [name.isEmpty ? "Mailbox" : name]
        if total == 0 { parts.append("nothing in today\u{2019}s digest") }
        else if unread == 0 { parts.append("all read") }
        else { parts.append(unread == 1 ? "1 unread" : "\(unread) unread") }
        if let line, !line.isEmpty { parts.append(line) }
        return parts.joined(separator: ", ")
    }

    /// A section chip or row: "Social, 5, not read yet" / "Updates, read".
    static func digestSection(_ title: String, count: Int, read: Bool) -> String {
        read ? "\(title), read" : "\(title), \(count), not read yet"
    }

    /// A summary line: "Worth opening: …" for the helper's picks.
    static func digestLine(_ text: String, pick: Bool) -> String { pick ? "Worth opening: \(text)" : text }

    private static func spokenSubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No subject" : trimmed
    }
}
