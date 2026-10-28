import SwiftUI

/// The Accounts section of the main window (docs/CONTRACTS.md: `AccountsScreen(model:)`).
/// Transparent background: the window shell paints the navy gradient.
struct AccountsScreen: View {
    @ObservedObject var model: AccountsModel
    /// Fixed clock for headless renders; nil = now.
    var now: Date?

    @Environment(\.accountsStaticRender) private var staticRender

    init(model: AccountsModel) {
        self.model = model
    }

    init(model: AccountsModel, now: Date?) {
        self.model = model
        self.now = now
    }

    var body: some View {
        Group {
            if staticRender {
                content
            } else {
                ScrollView(.vertical) { content }
                    .scrollIndicators(.automatic)
            }
        }
        .sheet(isPresented: $model.isAddSheetPresented, onDismiss: {
            MainActor.assumeIsolated { model.dismissAddSheet() }
        }) {
            AddAccountSheet(model: model)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let problem = model.storeProblem {
                banner(problem, color: AppTheme.bad)
            }
            if let notice = model.notice {
                banner(notice.text, color: AccountsKit.toneColor(notice.tone))
            }
            if let keychain = model.keychainNotice {
                banner(keychain, color: AccountsKit.toneColor(.warn))
            }
            if model.accounts.isEmpty {
                emptyState
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                        AccountCard(model: model, account: account, isFirst: index == 0,
                                    isLast: index == model.accounts.count - 1, now: now)
                    }
                }
                Text("Widgets list accounts in this order. Use the arrows to change it.")
                    .font(AppTheme.font(11.5))
                    .foregroundStyle(AppTheme.text3)
                    .padding(.leading, 4)
            }
            AccountsKit.SectionLabel(text: "Sign-in setup").padding(.top, 8).padding(.leading, 4)
            ProviderSetupView(model: model)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 28)
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your accounts")
                    .font(AppTheme.font(26, .heavy))
                    .foregroundStyle(AppTheme.text)
                Text("Every inbox and calendar I keep an eye on. Name them, give each a colour and a logo, and choose where they show up.")
                    .font(AppTheme.font(13))
                    .foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !model.accounts.isEmpty {
                Button {
                    model.presentAdd()
                } label: {
                    Label("Add Google account", systemImage: "plus")
                }
                .buttonStyle(AccountsKit.PrimaryButton())
                .padding(.top, 4)
            }
        }
    }

    private var emptyState: some View {
        AccountsKit.Card(padding: 28) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(AppTheme.accentSoft).frame(width: 58, height: 58)
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                }
                Text("No accounts yet")
                    .font(AppTheme.font(17, .bold))
                    .foregroundStyle(AppTheme.text)
                Text(model.google.isReady
                     ? "Connect a Google account and I\u{2019}ll gather its meetings and mail into your widgets. Workspace or personal Gmail, both fine."
                     : "First, set up Google sign-in below: about 5 minutes, once, and I walk you through it. Then connect as many Google accounts as you like.")
                    .font(AppTheme.font(13))
                    .foregroundStyle(AppTheme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.presentAdd()
                } label: {
                    Label("Add Google account", systemImage: "plus")
                }
                .buttonStyle(AccountsKit.PrimaryButton())
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            AccountsKit.Dot(color: color)
            Text(text)
                .font(AppTheme.font(12.5, .medium))
                .foregroundStyle(AppTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.3)))
    }
}
