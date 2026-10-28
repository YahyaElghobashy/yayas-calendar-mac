import AppKit
import SwiftUI

/// An account as the app's own surfaces draw it (Event Peek, Day Peek, the Calendar section, Widget
/// Studio). Built from the accounts store in the app, from fixtures in renders and tests.
struct DirectoryAccount: Identifiable {
    let id: UUID
    var tag: String
    var name: String
    var email: String
    var color: UInt32
    var logo: NSImage?
    var includeInAll = true
    var calendarEnabled = true
    var mailEnabled = true
}

extension DirectoryAccount: Equatable {
    static func == (a: DirectoryAccount, b: DirectoryAccount) -> Bool {
        a.id == b.id && a.tag == b.tag && a.name == b.name && a.email == b.email && a.color == b.color
            && a.logo === b.logo && a.includeInAll == b.includeInAll && a.calendarEnabled == b.calendarEnabled
            && a.mailEnabled == b.mailEnabled
    }
}

struct AccountDirectory {
    var accounts: [DirectoryAccount]

    func account(_ id: UUID) -> DirectoryAccount? { accounts.first { $0.id == id } }

    /// The widget model for an account (unknown ids draw as an untagged, logo-less row).
    func widgetAccount(_ id: UUID) -> WidgetAccount {
        guard let a = account(id) else { return WidgetAccount(id: id.uuidString, short: "", name: "", logo: nil) }
        return WidgetAccount(id: id.uuidString, short: a.tag, name: a.name, logo: a.logo, color: Int(a.color))
    }

    /// "ORB+FAM": every tag, primary first.
    func label(_ ids: [UUID]) -> String {
        ids.compactMap { account($0)?.tag }.filter { !$0.isEmpty }.joined(separator: "+")
    }

    /// Where surfaces get the directory. The app points it at the live accounts store at launch
    /// (LiveAccountDirectory.swift); renders and tests point it at fixtures.
    static var current: () -> AccountDirectory = { AccountDirectory(accounts: []) }
}

extension CalendarEvent.Response {
    /// The widget's three-way reply state.
    var widgetReply: WidgetMeeting.Reply {
        switch self {
        case .accepted, .declined: return .accepted
        case .tentative: return .maybe
        case .needsAction: return .needsReply
        }
    }
}

extension CalendarEvent {
    /// The same row model the widgets draw, so the app's lists reuse the widget row.
    func widgetMeeting(index: Int, directory: AccountDirectory) -> WidgetMeeting {
        let primary = accountIds.first.map(directory.widgetAccount) ?? WidgetAccount(id: "", short: "", name: "", logo: nil)
        var m = WidgetMeeting(id: index, account: primary, title: title, start: start, end: max(end, start),
                              place: location, hasLink: joinURL != nil, reply: myResponse.widgetReply, clashes: clashes)
        m.r = r
        m.also = accountIds.dropFirst().map(directory.widgetAccount)
        m.allDay = allDay
        return m
    }
}
