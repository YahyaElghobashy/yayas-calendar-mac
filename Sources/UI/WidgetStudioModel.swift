import Foundation
import SwiftUI

/// Widget Studio: pick a widget kind, change its settings, see it live, save
/// (`Services.widgetSettings.save` republishes that kind's snapshot).
final class WidgetStudioModel: ObservableObject {
    enum Status: Equatable { case idle, saved, failed(String) }

    /// Custom slot content choices, in the order Studio lists them.
    static let contentChoices: [(WidgetSnapshot.Content, String)] = [
        (.agenda, "Agenda"), (.day, "Day"), (.upNext, "Up Next"), (.month, "Month"), (.inbox, "Inbox"),
        (.combo, "Agenda & Inbox"),
    ]
    static let lookChoices: [(WidgetSnapshot.Style.Look, String)] = [(.auto, "Match Mac"), (.paper, "Light"), (.ink, "Dark")]
    static let fontChoices: [(String, String)] = [("system", "System"), ("rounded", "Rounded"), ("serif", "Serif")]
    static let sizeChoices: [(String, String)] = [("small", "Small"), ("standard", "Standard"), ("large", "Large")]
    static let rangeChoices: [(Int, String)] = [(1, "Today"), (2, "2 days"), (7, "Week")]
    static let maxNameLength = 24

    @Published private(set) var selectedKind: String
    @Published var draft: WidgetSettings
    @Published private(set) var saved: WidgetSettings
    @Published private(set) var status: Status = .idle
    @Published var previewFamily: Family
    /// Custom slot names for the kind list ("Custom A · Work").
    @Published private(set) var names: [String: String] = [:]

    private let store: () -> WidgetSettingsStore
    private let mailEnabled: () -> Bool

    init(kind: String = WidgetKinds.agenda.kind, store: @escaping () -> WidgetSettingsStore = { Services.widgetSettings },
         mailEnabled: @escaping () -> Bool = { true }) {
        self.store = store
        self.mailEnabled = mailEnabled
        let loaded = store().settings(kind: kind)
        selectedKind = kind
        draft = loaded
        saved = loaded
        previewFamily = WidgetKinds.spec(kind)?.families.contains(.large) == true ? .large : (WidgetKinds.spec(kind)?.families.first ?? .large)
        refreshNames()
    }

    func refreshNames() {
        var out: [String: String] = [:]
        for spec in WidgetKinds.custom {
            if let title = store().settings(kind: spec.kind).title, !title.isEmpty { out[spec.kind] = title }
        }
        names = out
    }

    /// "Agenda", "Custom Widget A", "Custom A · Work".
    func listName(_ spec: WidgetKindSpec) -> String {
        guard case .custom(let letter) = spec.content else { return spec.galleryName }
        if let name = names[spec.kind] { return "Custom \(letter) · \(name)" }
        return spec.galleryName
    }

    var spec: WidgetKindSpec { WidgetKinds.spec(selectedKind) ?? WidgetKinds.agenda }
    var isCustom: Bool { if case .custom = spec.content { return true } else { return false } }
    var isDirty: Bool { draft != saved }
    var mailAvailable: Bool { mailEnabled() }

    /// Inbox and Agenda & Inbox need mail (greyed while the `mailEnabled` seam is off: renders and tests; the app
    /// passes on, D-029).
    func isAvailable(_ content: WidgetSnapshot.Content) -> Bool {
        switch content {
        case .inbox, .combo: return mailAvailable
        default: return true
        }
    }

    /// What the widget shows with the draft settings: the kind's own content, or the custom choice.
    var effectiveContent: WidgetSnapshot.Content? {
        if isCustom { return draft.customContent }
        switch spec.content {
        case .agenda: return .agenda
        case .upNext: return .upNext
        case .month: return .month
        case .inbox: return .inbox
        case .combo: return .combo
        case .day: return .day
        case .digest: return .digest
        case .custom: return nil
        }
    }

    /// The agenda range applies where an agenda list is drawn.
    var showsRange: Bool { effectiveContent == .agenda || effectiveContent == .combo }

    /// The families the preview offers: the kind's (custom slots: all five).
    var families: [Family] { spec.families }

    func select(_ kind: String) {
        guard WidgetKinds.spec(kind) != nil else { return }
        let loaded = store().settings(kind: kind)
        selectedKind = kind
        draft = loaded
        saved = loaded
        status = .idle
        if !spec.families.contains(previewFamily) {
            previewFamily = spec.families.contains(.large) ? .large : (spec.families.first ?? .large)
        }
    }

    // MARK: Edits (each clears the last "Saved")

    func setLook(_ look: WidgetSnapshot.Style.Look) { draft.style.look = look; status = .idle }
    func setFont(_ key: String) { draft.style.typeface = key; status = .idle }
    func setTextSize(_ key: String) { draft.style.textSize = key; status = .idle }
    func setShowLogos(_ on: Bool) { draft.style.showLogos = on; status = .idle }
    func setUse24Hour(_ on: Bool) { draft.style.use24Hour = on; status = .idle }
    func setRange(_ days: Int) { draft.rangeDays = days; status = .idle }

    func setName(_ name: String) {
        guard isCustom else { return }
        let trimmed = String(name.prefix(Self.maxNameLength))
        draft.title = trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimmed
        status = .idle
    }

    func setContent(_ content: WidgetSnapshot.Content) {
        guard isCustom, isAvailable(content), content != .setup, content != .mailComingSoon else { return }
        draft.customContent = content
        status = .idle
    }

    /// nil = "All accounts (includes new ones)".
    func setAllAccounts() { draft.accountIds = nil; status = .idle }

    /// "Only the ones I pick": starts from every current account, the user unticks from there.
    func pickOnly(_ all: [UUID]) {
        guard draft.accountIds == nil, !all.isEmpty else { return }
        draft.accountIds = all
        status = .idle
    }

    func toggleAccount(_ id: UUID, all: [UUID]) {
        var picked = draft.accountIds ?? all
        if let i = picked.firstIndex(of: id) {
            guard picked.count > 1 else { return }   // a widget always shows at least one account
            picked.remove(at: i)
        } else {
            picked.append(id)
            picked.sort { (all.firstIndex(of: $0) ?? .max) < (all.firstIndex(of: $1) ?? .max) }
        }
        draft.accountIds = picked
        status = .idle
    }

    func isPicked(_ id: UUID) -> Bool { draft.accountIds?.contains(id) ?? true }

    func revert() { draft = saved; status = .idle }

    /// The window opened: pick up settings saved elsewhere (or a store installed after launch), unless
    /// the user has unsaved changes.
    func reload() {
        guard !isDirty else { return }
        select(selectedKind)
        refreshNames()
    }

    @discardableResult
    func save() -> Bool {
        var settings = draft
        settings.kind = selectedKind
        if !isCustom {
            settings.title = nil
            settings.customContent = nil
        } else {
            let name = settings.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            settings.title = name.isEmpty ? nil : name
            if let content = settings.customContent, !isAvailable(content) { settings.customContent = nil }
        }
        do {
            try store().save(settings)
            draft = settings
            saved = settings
            status = .saved
            refreshNames()
            return true
        } catch {
            status = .failed("I couldn\u{2019}t save that. Try again in a moment.")
            return false
        }
    }

    // MARK: Preview

    /// Draft settings drawn on fixture data at real point sizes. `dark` = the Mac's appearance for
    /// "Match Mac"; `now` anchors the sample week (renders pin its fixed Monday).
    func preview(now: Date, dark: Bool, calendar: Calendar = WidgetCalendar.current) -> (WidgetData, WidgetStyle) {
        var snapshot = SnapshotFixtures.busy(kind: WidgetKinds.agenda.kind, now: now, calendar: calendar)
        snapshot.kind = selectedKind
        snapshot.style = draft.style
        snapshot.rangeDays = draft.rangeDays
        snapshot.title = isCustom ? draft.title : nil
        snapshot.generatedAt = now
        snapshot.health.syncedAt = now
        switch effectiveContent {
        case nil: snapshot.content = .setup
        case let content? where !isAvailable(content): snapshot.content = .mailComingSoon
        case let content?: snapshot.content = content
        }
        if snapshot.content == .month {
            snapshot.selectedDay = DayName.posixDay(calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))!, calendar: calendar)
        }
        if snapshot.content == .inbox || snapshot.content == .combo {
            // Mail is on: the sample inbox (live rows, as the desktop will draw them).
            snapshot.mail = FixtureMail.snapshotRows(now: now, calendar: calendar)
            snapshot.unreadCount = FixtureMail.unread
        }
        let model = SnapshotModel(snapshot, logo: { id in
            UUID(uuidString: id).flatMap(Cast.account(id:)).flatMap { Cast.badge(key: $0.key) }
        })
        var data = model.data(at: now)
        // The preview always draws the sample cast (its accounts, badges, meetings and mail), never this
        // Mac's accounts or logos. Accounts picked in the draft keep the cast accounts at the same places
        // in the list, so the choice still shows at once.
        let directory = AccountDirectory.current()
        if let picked = draft.accountIds.map(Set.init), !directory.accounts.isEmpty {
            let places = Set(directory.accounts.enumerated().filter { picked.contains($0.element.id) }.map(\.offset))
            let kept = Set(FixtureAccounts.all.enumerated().filter { places.contains($0.offset) }.map { $0.element.id.uuidString })
            data.meetings = data.meetings.filter { m in m.accountIds.contains { kept.contains($0) } }
            data.mail = data.mail.filter { kept.contains($0.account.id) }
        }
        if snapshot.content == .digest {
            // The Daily Digest (D-053) draws the cast's sample digest, never this Mac's.
            data.digest = WidgetSample.digest(now: now, accounts: WidgetSample.accounts(logos: WidgetSample.badges), calendar: calendar)
            data.state = .content
        }
        return (data, model.style(dark: dark))
    }
}
