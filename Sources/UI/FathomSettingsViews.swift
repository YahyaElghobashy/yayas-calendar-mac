import SwiftUI

/// Accounts → each card: "Record with Fathom" and which Fathom account (D-045). Shown only while Fathom is on
/// this Mac. The card hands it in through `AccountCardExtras` (Sources/Accounts stays free of the UI layer).
struct FathomAccountRow: View {
    @ObservedObject var model: FathomLinksModel
    let accountId: UUID
    let email: String
    /// "Record with Fathom"; "Fathom account" under the card's "Record with" while Yaya's Murmur is on this Mac (D-046).
    var title = "Record with Fathom"
    @Local private var editing = false
    @Local private var draft = ""
    @Local private var refused = false

    var body: some View {
        if model.installed {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(AppTheme.stroke).frame(height: 1)
                HStack(alignment: .center, spacing: 10) {
                    Circle().fill(model.link(accountId) == .off ? AppTheme.text3 : AppTheme.bad).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text)
                        Text(model.detail(accountId, email: email)).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button { showMenu() } label: {
                        HStack(spacing: 4) {
                            Text(choiceTitle).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.text))
                    .accessibilityLabel(Text("\(title): \(choiceTitle)"))
                }
                if editing { addressEditor }
                if model.isSignedIn(accountId, email: email) {
                    Label("Fathom on this Mac is signed in as this account", systemImage: "checkmark")
                        .font(AppTheme.font(11.5, .medium)).foregroundStyle(AppTheme.accent)
                }
            }
        }
    }

    private var choiceTitle: String {
        switch model.link(accountId) {
        case .ownAddress: return "This account\u{2019}s address"
        case .address: return "Another address"
        case .off: return "Off"
        }
    }

    private func showMenu() {
        AccountsKit.MenuPresenter.show([
            AccountsKit.PopUpMenuButton.Item(title: "This account\u{2019}s address (\(email))") {
                editing = false
                model.set(.ownAddress, for: accountId)
            },
            AccountsKit.PopUpMenuButton.Item(title: "Another address\u{2026}") {
                if case .address(let a) = model.link(accountId) { draft = a } else { draft = "" }
                refused = false
                editing = true
            },
            .separator,
            AccountsKit.PopUpMenuButton.Item(title: "Off") {
                editing = false
                model.set(.off, for: accountId)
            },
        ])
    }

    private var addressEditor: some View {
        HStack(spacing: 8) {
            TextField("name@company.example", text: Binding(get: { draft }, set: { draft = $0; refused = false }))
                .textFieldStyle(.roundedBorder)
                .font(AppTheme.font(12.5))
                .frame(maxWidth: 280)
                .onSubmit(save)
            Button("Save", action: save).buttonStyle(AccountsKit.PrimaryButton(compact: true))
            Button("Cancel") { editing = false }.buttonStyle(AccountsKit.LinkButton())
            if refused {
                Text("That isn\u{2019}t one address.").font(AppTheme.font(11.5)).foregroundStyle(AppTheme.warn)
            }
        }
    }

    private func save() {
        if model.setAddress(draft, for: accountId, own: email) {
            editing = false
        } else {
            refused = true
        }
    }
}

/// Settings → Fathom (D-045): what Join with Fathom does, which account Fathom on this Mac is signed into, and
/// "⌃⌥J records with Fathom". Shown while Fathom is on this Mac.
struct SettingsFathomCard: View {
    @ObservedObject var model: FathomLinksModel
    let directory: () -> AccountDirectory
    /// "⌃⌥J records with Fathom"; Settings → Yaya's Murmur holds it instead while Murmur is on this Mac (D-046).
    var showsHotkey = true
    @Environment(\.headlessRender) private var headless

    var body: some View {
        if model.installed {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fathom").font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                    Text("Join with Fathom opens the call and asks the Fathom app on this Mac to record it, in the Fathom account linked to the meeting\u{2019}s account (on each card in Accounts). Before it records, I check which account Fathom is signed into, in a small file Fathom keeps on this Mac. That address stays here.")
                        .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                ShellCard(padding: 0) {
                    VStack(spacing: 0) {
                        row(title: "Fathom on this Mac", detail: model.appStatus(directory: directory())) {
                            Button("Check again") { model.refresh() }.buttonStyle(AccountsKit.LinkButton())
                        }
                        if showsHotkey {
                            Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 18)
                            row(title: "\(JoinHotkey.display) records with Fathom",
                                detail: "When the meeting\u{2019}s account has Fathom linked, \(JoinHotkey.display) joins and records. Off, it only joins.") {
                                ShellSwitch(isOn: Binding(get: { model.hotkeyRecords }, set: { model.setHotkeyRecords($0) }),
                                            label: "Control Option J records with Fathom")
                            }
                        }
                    }
                }
            }
            .onAppear { if !headless { model.refresh() } }
        }
    }

    private func row<Trailing: View>(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                Text(detail).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
