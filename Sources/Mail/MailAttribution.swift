import Foundation

// The one formatter for "On … wrote:" and the Outlook-style header lines. Shared by the
// composer (`ComposerText.quote`, the quote bar), the data layer's quote composition and the shell tests, so it uses
// only Foundation and the widget calendar (`DayName`, Sources/Shared): dates read in the calendar's time zone.

enum MailAttribution {
    /// "Monday 19 October 2026 at 9:41 AM".
    static func date(_ date: Date) -> String {
        "\(DayName.format("EEEE d MMMM yyyy", date)) at \(DayName.format("h:mm a", date))"
    }

    /// "On Monday 19 October 2026 at 9:41 AM, Juniper Vale <juniper@vale.example> wrote:" (byte-identical to the
    /// plain composer's quote header).
    static func line(name: String, address: String, date: Date) -> String {
        "On \(Self.date(date)), \(name) <\(address)> wrote:"
    }

    /// "Juniper Vale <juniper@vale.example>", or the address alone when there is no name.
    static func person(name: String, address: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == address ? address : "\(n) <\(address)>"
    }

    /// Outlook-style header (Settings → Writing → Quote style "Header"): From, Sent, To, Cc (when any), Subject.
    static func header(name: String, address: String, date: Date, to: [String], cc: [String], subject: String) -> [(String, String)] {
        var lines: [(String, String)] = [("From", person(name: name, address: address)), ("Sent", Self.date(date))]
        if !to.isEmpty { lines.append(("To", to.joined(separator: ", "))) }
        if !cc.isEmpty { lines.append(("Cc", cc.joined(separator: ", "))) }
        lines.append(("Subject", subject.isEmpty ? "(no subject)" : subject))
        return lines
    }

    /// Forward header, Gmail's shape: "---------- Forwarded message ---------" then From, Date, Subject, To, Cc.
    static func forwardHeader(name: String, address: String, date: Date, to: [String], cc: [String], subject: String) -> [(String, String)] {
        var lines: [(String, String)] = [("From", person(name: name, address: address)), ("Date", Self.date(date)),
                                         ("Subject", subject.isEmpty ? "(no subject)" : subject)]
        if !to.isEmpty { lines.append(("To", to.joined(separator: ", "))) }
        if !cc.isEmpty { lines.append(("Cc", cc.joined(separator: ", "))) }
        return lines
    }

    static let forwardLine = "---------- Forwarded message ---------"
}
