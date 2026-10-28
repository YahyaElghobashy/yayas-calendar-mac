import SwiftUI

// VoiceOver: what rows, cards and drawn controls say. The words live here so tests can read them;
// the `ycAccessible…` modifiers put them on views that are drawn by hand (tap gestures, no Button).

enum A11yText {
    /// A meeting row: label "Launch plan review, ORB", value "Today, 10:00 to 10:45 AM, in 12 minutes".
    /// The words live in Shared (`WidgetA11y`) so the widget says the same.
    static func meeting(_ m: WidgetMeeting, now: Date, use24Hour: Bool = false) -> (label: String, value: String) {
        WidgetA11y.meeting(m, now: now, use24Hour: use24Hour)
    }

    /// An inbox thread: label "Unread, Juniper Vale, Re: launch checklist", value "9:41 AM, starred, 3 messages".
    static func thread(_ t: MailThread, account: DirectoryAccount?, now: Date) -> (label: String, value: String) {
        var label = t.unread ? "Unread, " : ""
        label += "\(t.sender), \(t.subject.isEmpty ? "No subject" : t.subject)"
        var parts = [MailText.listTime(t.at, now: now)]
        if let tag = account?.tag, !tag.isEmpty { parts.append(tag) }
        if t.starred { parts.append("starred") }
        if t.messageCount > 1 { parts.append("\(t.messageCount) messages") }
        if !t.snippet.isEmpty { parts.append(t.snippet) }
        return (label, parts.joined(separator: ", "))
    }

    /// The popover's next-meeting card.
    static func card(_ card: PopoverModel.Card) -> (label: String, value: String) {
        let e = card.event
        var label = "Next meeting: \(e.title.isEmpty ? "Meeting" : e.title)"
        if card.live { label = "Now: \(e.title.isEmpty ? "Meeting" : e.title)" }
        let value = [card.when.replacingOccurrences(of: " – ", with: " to ").replacingOccurrences(of: " · ", with: ", "),
                     card.countdown.lowercased()].joined(separator: ", ")
        return (label, value)
    }

    /// "Mark read (U)" → "Mark read": tooltips name the key, VoiceOver doesn't need to.
    static func plainHelp(_ help: String) -> String {
        guard help.hasSuffix(")"), let open = help.lastIndex(of: "("),
              help.distance(from: open, to: help.endIndex) <= 5 else { return help }
        return help[..<open].trimmingCharacters(in: .whitespaces)
    }

    /// An account chip: "FAM", value "shown" / "hidden".
    static func chip(_ title: String, on: Bool) -> (label: String, value: String) {
        (title, on ? "shown" : "not shown")
    }
}

extension View {
    /// A hand-drawn control (tap gesture) as one VoiceOver button that does what a click does.
    func ycAccessibleButton(_ label: String, value: String? = nil, hint: String? = nil, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(value ?? ""))
            .accessibilityHint(Text(hint ?? ""))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}
