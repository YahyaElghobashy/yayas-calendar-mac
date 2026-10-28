import SwiftUI

/// Hand-rolled sidebar + content (no `List`/`Form`: their AppKit backing mis-renders with this toolchain).
struct MainView: View {
    @ObservedObject var shell: ShellModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(shell: shell)
                .frame(width: 200)
                .background(AppTheme.sidebar)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch shell.section {
        case .inbox:
            if shell.mailEnabled() {
                InboxSectionView(model: shell.inbox)
            } else {
                MailOffView(symbol: "tray.full", title: "Inbox", line: MailOffCopy.inboxLine, detail: MailOffCopy.inboxDetail)
            }
        case .calendar:
            CalendarSectionView(model: shell.calendar)
        case .widgets:
            WidgetsGalleryView(shell: shell)
        case .accounts:
            // Headless: no ScrollView or drop targets (ImageRenderer draws them blank or as a "not supported" box).
            AccountsScreen(model: AccountsModel.shared)
                .environment(\.accountsStaticRender, headless)
        case .settings:
            SettingsView(mail: shell.mailEnabled() ? shell.settingsMail : nil, menuBar: shell.menuBar,
                         fathom: shell.fixedNow == nil ? FathomLinksModel.shared : nil,
                         openGuide: shell.fixedNow == nil ? { MainWindowController.shared.presentOnboarding() } : nil,
                         removeEverything: shell.fixedNow == nil ? { MainWindowController.shared.presentRemoveEverything() } : nil)
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var shell: ShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 40)   // traffic lights sit here (full-size content view)
            HStack(spacing: 8) {
                BrandMark()
                    .fill(AppTheme.accent)
                    .frame(width: 16, height: 14)
                Text("Yaya's Calendar")
                    .font(AppTheme.font(14, .heavy))
                    .foregroundStyle(AppTheme.text)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
            // Many accounts make a long mailbox list: the sections and the list scroll, the version stays.
            ShellScroll {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AppSection.allCases) { section in
                        SidebarButton(section: section, selected: shell.section == section) { shell.section = section }
                        if section == .inbox, shell.section == .inbox, shell.mailEnabled() {
                            InboxMailboxList(model: shell.inbox)
                        }
                    }
                }
            }
            Text("Version \(AppInfo.version)")
                .font(AppTheme.font(10.5, .medium))
                .foregroundStyle(AppTheme.text3)
                .padding(.horizontal, 10)
        }
        .padding(12)
    }
}

private struct SidebarButton: View {
    let section: AppSection
    let selected: Bool
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.text2)
                    .frame(width: 18)
                Text(section.title)
                    .font(AppTheme.font(13, selected ? .bold : .medium))
                    .foregroundStyle(selected ? AppTheme.text : AppTheme.text2)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.12) : (hover ? Color.white.opacity(0.06) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Inbox section where mail is off (the `mailEnabled` seam: comparison renders; the app keeps mail on, D-029).
struct MailOffView: View {
    let symbol: String
    let title: String
    let line: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 72, height: 72)
                .background(Circle().fill(AppTheme.accentSoft))
            Text(title).font(AppTheme.font(24, .heavy)).foregroundStyle(AppTheme.text)
            Text(line).font(AppTheme.font(14, .semibold)).foregroundStyle(AppTheme.text)
                .multilineTextAlignment(.center)
            Text(detail).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return short
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }
}
