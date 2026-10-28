import Foundation

/// What the app and the widget say where mail is off. Mail is always on in the app (D-029: no labs gate; the
/// per-account mail toggle stays), so these show only where the `mailEnabled` / `labsMail` seam is off: tests
/// and the comparison renders. Plain statements about now, never a promise of a later version.
enum MailOffCopy {
    /// The Inbox and Agenda & Inbox widgets (`mailComingSoon`).
    static let widgetTitle = "Mail is off"
    static let widgetLine = "Turn mail on for an account in Yaya's Calendar \u{2192} Accounts."
    static let widgetLineSmall = "Turn it on in Accounts."

    /// The app's Inbox section.
    static let inboxLine = "Mail is off."
    static let inboxDetail = "Turn mail on for an account in Accounts and its inbox shows up here."

    /// Widget Studio, beside the greyed Inbox choices.
    static let studioNote = "Inbox and Agenda & Inbox need mail on."
    static let studioChipHelp = "Needs mail on"

    static var all: [String] {
        [widgetTitle, widgetLine, widgetLineSmall, inboxLine, inboxDetail, studioNote, studioChipHelp]
    }
}
