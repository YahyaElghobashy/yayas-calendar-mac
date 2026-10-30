import Foundation

/// What a widget kind draws.
enum WidgetContent: Equatable {
    case agenda, upNext, month, inbox, combo, day
    /// Daily Digest (D-053): Yaya's Mail Helper's latest digest, one box per mailbox.
    case digest
    /// Custom Widget A…F (letter); configured in Widget Studio.
    case custom(String)
}

/// One widget kind. Kind strings are a public contract (placed widgets are keyed by them): docs/CONTRACTS.md.
struct WidgetKindSpec: Identifiable, Equatable {
    let kind: String
    let galleryName: String
    let description: String
    let families: [Family]
    let content: WidgetContent
    var id: String { kind }
}

enum WidgetKinds {
    static let agenda = WidgetKindSpec(
        kind: "agenda.all", galleryName: "Agenda",
        description: "Your meetings from every calendar, day by day. Flip pages with the arrows.",
        families: Family.allCases, content: .agenda)
    static let upNext = WidgetKindSpec(
        kind: "upnext", galleryName: "Up Next",
        description: "Your next meeting, a countdown and a Join button.",
        families: [.small, .medium], content: .upNext)
    static let month = WidgetKindSpec(
        kind: "month", galleryName: "Month",
        description: "Tap a day on the calendar to see its meetings.",
        families: Family.allCases, content: .month)
    static let inbox = WidgetKindSpec(
        kind: "inbox.all", galleryName: "Inbox",
        description: "Newest mail from all your inboxes. Tap to read, mark read or archive.",
        families: [.medium, .large, .extraLarge, .extraLargePortrait], content: .inbox)
    static let combo = WidgetKindSpec(
        kind: "combo.all", galleryName: "Agenda & Inbox",
        description: "Meetings on one side, mail on the other.",
        families: [.large, .extraLarge, .extraLargePortrait], content: .combo)

    static let day = WidgetKindSpec(
        kind: "day", galleryName: "Day",
        description: "One day hour by hour, with overlapping meetings side by side. Flip days with the arrows.",
        families: Family.allCases, content: .day)

    static let digest = WidgetKindSpec(
        kind: "digest", galleryName: "Daily Digest",
        description: "Today's mail digest from Yaya's Mail Helper, one box per mailbox. Tap to read it.",
        families: Family.allCases, content: .digest)

    static let customLetters = ["A", "B", "C", "D", "E", "F"]
    static let custom: [WidgetKindSpec] = customLetters.map { letter in
        WidgetKindSpec(
            kind: "custom.\(letter.lowercased())", galleryName: "Custom Widget \(letter)",
            description: "Pick its calendars and look in Yaya's Calendar → Widgets.",
            families: Family.allCases, content: .custom(letter))
    }

    /// All 13, in gallery order.
    static let all: [WidgetKindSpec] = [agenda, day, upNext, month, inbox, combo, digest] + custom

    static func spec(_ kind: String) -> WidgetKindSpec? { all.first { $0.kind == kind } }
}
