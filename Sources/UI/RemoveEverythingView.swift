import SwiftUI

/// Settings → "Remove everything and quit" (D-037): confirm, remove, report, quit. Plain words only: no
/// humour around deleting.
@MainActor
final class RemoveEverythingModel: ObservableObject {
    enum Phase: Equatable {
        case confirm
        case working
        case done(UninstallReport)
    }

    @Published private(set) var phase: Phase {
        didSet { onPhase?() }
    }
    /// The sheet resizes to each phase (the window controller sets it).
    var onPhase: (() -> Void)?
    let plan: UninstallPlan
    /// Connected accounts (the confirm names how many sign-ins it revokes).
    let accounts: Int
    private let perform: () async -> UninstallReport
    let cancel: () -> Void
    let quit: () -> Void
    let reveal: (URL) -> Void

    init(plan: UninstallPlan, accounts: Int, phase: Phase = .confirm,
         perform: @escaping () async -> UninstallReport, cancel: @escaping () -> Void,
         quit: @escaping () -> Void, reveal: @escaping (URL) -> Void = { _ in }) {
        self.plan = plan
        self.accounts = accounts
        self.phase = phase
        self.perform = perform
        self.cancel = cancel
        self.quit = quit
        self.reveal = reveal
    }

    func start() {
        guard phase == .confirm else { return }
        phase = .working
        Task { @MainActor in
            let report = await perform()
            phase = .done(report)
        }
    }

    /// What goes, in the confirm's words.
    var items: [String] {
        var lines: [String] = []
        lines.append(accounts == 1 ? "Your Google sign-in for 1 account (I ask Google to revoke it)"
                                   : "Your Google sign-ins for \(accounts) accounts (I ask Google to revoke them)")
        lines.append("Your Google client and every other item I keep in your Keychain")
        lines.append("Cached mail, calendars and widget data in \(Self.tilde(plan.folders.first, home: plan.home))")
        lines.append("My settings, the login item and my notifications")
        return lines
    }

    static func tilde(_ url: URL?, home: URL) -> String {
        guard let path = url?.path else { return "" }
        return path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }
}

struct RemoveEverythingView: View {
    @ObservedObject var model: RemoveEverythingModel

    static let width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .confirm: confirm
            case .working: working
            case .done(let report): done(report)
            }
        }
        .padding(26)
        .frame(width: Self.width, alignment: .topLeading)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Confirm

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(symbol: "trash", color: AppTheme.bad, title: "Remove everything and quit?",
                   line: "This takes Yaya\u{2019}s Calendar off this Mac, all but the app itself. Your mail and calendars at Google stay as they are.")
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "minus.circle.fill").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.bad.opacity(0.85)).accessibilityHidden(true)
                        Text(item).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.stroke))
            Text("It can\u{2019}t be undone. To use me again you set up Google sign-in and connect your accounts from the start.")
                .font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: model.cancel)
                    .buttonStyle(AccountsKit.SecondaryButton())
                    .keyboardShortcut(.cancelAction)
                Button("Remove everything and quit") { model.start() }
                    .buttonStyle(DangerButtonStyle())
            }
        }
    }

    // MARK: Working

    private var working: some View {
        header(symbol: "hourglass", color: AppTheme.text2, title: "Removing\u{2026}",
               line: "Revoking sign-ins and clearing the Keychain. This takes a few seconds; macOS may ask about a Keychain item.")
    }

    // MARK: Done

    private func done(_ report: UninstallReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(symbol: "checkmark", color: AppTheme.good, title: report.failed.isEmpty && report.keychainLeftTotal == 0 ? "Everything is removed" : "Almost everything is removed",
                   line: "Quit now to finish. Then drag the app to the Trash if you want it gone too.")
            VStack(alignment: .leading, spacing: 6) {
                fact("\(report.revoked) Google sign-in\(report.revoked == 1 ? "" : "s") revoked")
                fact("\(report.keychainDeleted) Keychain item\(report.keychainDeleted == 1 ? "" : "s") deleted")
                fact("\(report.removed.count) folder\(report.removed.count == 1 ? "" : "s") and file\(report.removed.count == 1 ? "" : "s") removed, settings cleared")
            }
            if report.keychainLeftTotal > 0 || report.keychainTimedOut {
                note("Some Keychain items are still there",
                     "Open Keychain Access, search for \u{201C}yayascalendar\u{201D} and delete what it finds. macOS asked about them, or they took too long.")
            }
            if !report.failed.isEmpty {
                note("I couldn\u{2019}t remove", report.failed.map { RemoveEverythingModel.tilde(URL(fileURLWithPath: $0), home: model.plan.home) }.joined(separator: "\n"))
            }
            if report.widgetContainerExists {
                VStack(alignment: .leading, spacing: 8) {
                    note("One folder stays: the widget\u{2019}s own",
                         "\(RemoveEverythingModel.tilde(URL(fileURLWithPath: report.widgetContainer), home: model.plan.home))\nmacOS guards widget folders, so I leave it. Remove my widgets from the desktop, then drag the folder to the Trash.")
                    Button("Show in Finder") { model.reveal(URL(fileURLWithPath: report.widgetContainer)) }
                        .buttonStyle(AccountsKit.SecondaryButton(compact: true))
                }
            }
            HStack {
                Spacer()
                Button("Quit", action: model.quit)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Pieces

    private func header(symbol: String, color: Color, title: String, line: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .bold)).foregroundStyle(color)
                .frame(width: 42, height: 42).background(Circle().fill(color.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(AppTheme.font(18, .heavy)).foregroundStyle(AppTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text(line).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fact(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(AppTheme.font(12.5, .medium)).foregroundStyle(AppTheme.text)
            .labelStyle(TintedIconLabel(tint: AppTheme.good))
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text)
            Text(text).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.warn.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.warn.opacity(0.3)))
    }
}

/// The one red button (Remove everything).
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.font(12.5, .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(AppTheme.bad.opacity(configuration.isPressed ? 0.75 : 0.92)))
            .contentShape(Capsule())
    }
}

private struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(tint).font(.system(size: 11.5, weight: .semibold))
            configuration.title
        }
    }
}
