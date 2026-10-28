import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Rows another layer adds under an account card's switches (Join with Fathom's link, D-045). The app installs
/// it at launch; the accounts tests leave it empty.
@MainActor
enum AccountCardExtras {
    static var footer: (AccountRecord) -> AnyView? = { _ in nil }
}

/// One connected account: logo, name, address, tag, colour, status, switches, and the ⋯ menu.
struct AccountCard: View {
    @ObservedObject var model: AccountsModel
    let account: AccountRecord
    let isFirst: Bool
    let isLast: Bool
    /// Fixed "now" for headless renders; nil = the real clock.
    var now: Date?

    @Local private var dropTargeted = false

    private var accent: Color { Color(hex: account.color) }
    private var isPersonal: Bool { AccountNaming.isPersonal(email: account.email) }
    private var isChecking: Bool { model.checking.contains(account.id) }

    var body: some View {
        AccountsKit.Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    logo
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            AccountsKit.EditableText(value: account.displayName) { model.rename(account.id, to: $0) }
                            AccountsKit.EditableText(value: account.tag, font: AppTheme.font(10.5, .bold),
                                                     color: accent, maxLength: 10, help: "Click to change the tag") {
                                model.setTag(account.id, $0)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(accent.opacity(0.16)))
                            .overlay(Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 0.7))
                        }
                        Text(account.email)
                            .font(AppTheme.font(12))
                            .foregroundStyle(AppTheme.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        status.padding(.top, 2)
                        apiProblems
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Button { model.move(account.id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(AccountsKit.IconButton())
                            .disabled(isFirst)
                            .opacity(isFirst ? 0.35 : 1)
                            .help("Move up")
                            .accessibilityLabel(Text("Move \(account.tag) up"))
                        Button { model.move(account.id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(AccountsKit.IconButton())
                            .disabled(isLast)
                            .opacity(isLast ? 0.35 : 1)
                            .help("Move down")
                            .accessibilityLabel(Text("Move \(account.tag) down"))
                        AccountsKit.PopUpMenuButton(items: menuItems, label: "More actions for \(account.tag)")
                    }
                }

                if account.health == .adminBlocked && model.adminKitOpen.contains(account.id) {
                    AdminKitView(clientID: model.googleClientID, copyClientID: model.copyClientID,
                                 copyMessage: model.copyAdminMessage)
                }

                Rectangle().fill(AppTheme.stroke).frame(height: 1)

                HStack(alignment: .center, spacing: 18) {
                    HStack(spacing: 8) {
                        Text("Colour")
                            .font(AppTheme.font(12, .medium))
                            .foregroundStyle(AppTheme.text3)
                        AccountsKit.SwatchPicker(selected: account.color) { model.setColor(account.id, $0) }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 20) {
                    Toggle("Show mail", isOn: binding(\.mailEnabled, model.setMailEnabled))
                    Toggle("Show calendar", isOn: binding(\.calendarEnabled, model.setCalendarEnabled))
                    Toggle("Include in \u{201C}All\u{201D} widgets", isOn: binding(\.includeInAll, model.setIncludeInAll))
                    Spacer(minLength: 0)
                }
                .toggleStyle(AccountsKit.Switch())
                if let extra = AccountCardExtras.footer(account) { extra }
            }
        }
        .opacity(model.removing.contains(account.id) ? 0.45 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(account.tag) account, \(account.email)"))
        .overlay(
            RoundedRectangle(cornerRadius: AccountsKit.cardRadius, style: .continuous)
                .strokeBorder(AppTheme.accent, lineWidth: dropTargeted ? 2 : 0)
        )
    }

    // MARK: - Pieces

    private var logo: some View {
        AccountsKit.LogoBadge(image: model.logos[account.id], busy: model.fetchingLogo.contains(account.id))
            .accountsDropTarget([UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
                LogoDrop.handle(providers, model: model, id: account.id)
            }
            .help("Drop an image here to use it as this account\u{2019}s logo")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(model.logos[account.id] == nil ? "\(account.tag) has no logo yet" : "\(account.tag) logo"))
            .accessibilityHint(Text("Drop an image here, or use More actions, to change it"))
    }

    @ViewBuilder private var status: some View {
        let state: HealthState = isChecking ? .checking : account.health
        HStack(spacing: 7) {
            AccountsKit.Dot(color: AccountsKit.healthColor(state))
            switch state {
            case .ok:
                statusText(HealthText.connectedLine(checkedAt: model.checkedAt[account.id], now: now ?? Date()))
            case .reauthNeeded:
                statusText(account.healthDetail ?? HealthText.detail(.reauthNeeded))
                Button("Sign in again") { model.presentReauth(account.id) }
                    .buttonStyle(AccountsKit.PrimaryButton(compact: true))
            case .adminBlocked:
                statusText("Blocked by your admin")
                Button(model.adminKitOpen.contains(account.id) ? "Hide" : "Ask your admin") {
                    model.toggleAdminKit(account.id)
                }
                .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.text))
            case .offline, .failing, .keychainLocked:
                statusText(account.healthDetail ?? HealthText.detail(state))
                Button("Check again") { Task { await model.checkHealth([account.id]) } }
                    .buttonStyle(AccountsKit.LinkButton())
            default:
                statusText(account.healthDetail ?? HealthText.detail(state))
            }
        }
    }

    /// "Turn on the Gmail API in your Google Cloud project" (403 accessNotConfigured / SERVICE_DISABLED from
    /// the sync engine or Check my setup), with the Enable page.
    @ViewBuilder private var apiProblems: some View {
        let off = GoogleAPIKind.allCases.filter { model.apiProblems[account.id]?.contains($0) ?? false }
        ForEach(off, id: \.self) { api in
            HStack(spacing: 7) {
                AccountsKit.Dot(color: AppTheme.warn)
                statusText(GoogleSetupAdvice.turnOn(api))
                Button("Turn it on") { model.openConsole(api.enableURL(projectNumber: model.projectNumber)) }
                    .buttonStyle(AccountsKit.PrimaryButton(compact: true))
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.font(12, .medium))
            .foregroundStyle(AppTheme.text2)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func binding(_ key: KeyPath<AccountRecord, Bool>,
                         _ set: @escaping @MainActor (UUID, Bool) -> Void) -> Binding<Bool> {
        let id = account.id
        return Binding(get: { account[keyPath: key] }, set: { value in
            MainActor.assumeIsolated { set(id, value) }
        })
    }

    private func menuItems() -> [AccountsKit.PopUpMenuButton.Item] {
        let id = account.id
        let hasLogo = model.logos[id] != nil
        return [
            .init(title: "Change logo\u{2026}") { model.chooseLogo(for: id) },
            .init(title: "Fetch logo from website", enabled: !isPersonal) {
                Task { await model.fetchLogo(id) }
            },
            .init(title: "Remove logo", enabled: hasLogo) { model.removeLogo(id) },
            .separator,
            .init(title: "Sign in again") { model.presentReauth(id) },
            .separator,
            .init(title: "Remove account\u{2026}", destructive: true) { model.confirmRemove(id) },
        ]
    }
}

/// Turns a drop (a file from Finder or an image from a browser) into a logo.
enum LogoDrop {
    @MainActor
    static func handle(_ providers: [NSItemProvider], model: AccountsModel, id: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { model.importLogo(from: url, for: id) } }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = model.applyLogo(data, to: id) } }
            }
            return true
        }
        return false
    }
}
