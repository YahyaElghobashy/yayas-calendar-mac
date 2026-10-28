import SwiftUI
import UniformTypeIdentifiers

/// Provider Setup: is the Google OAuth client in the Keychain? If not, the six-step guide (D-038) ends with
/// the downloaded `client_secret_*.json` (choose or drop; on a dev Mac also the developer file,
/// `DevClientFile`), saved under the app's `…client` Keychain service. Once it's there: Check my setup,
/// Replace… (confirmed when accounts would be signed out), Remove Google client. The secret is never
/// shown or logged.
struct ProviderSetupView: View {
    @ObservedObject var model: AccountsModel

    @Local private var dropTargeted = false

    var body: some View {
        AccountsKit.Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ProviderMark(provider: .google)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            AccountsKit.Dot(color: statusColor)
                            Text(title)
                                .font(AppTheme.font(14, .bold))
                                .foregroundStyle(AppTheme.text)
                        }
                        Text(subtitle)
                            .font(AppTheme.font(12))
                            .foregroundStyle(AppTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if model.google.isReady {
                        Button("Replace\u{2026}") { model.chooseClientFile() }
                            .buttonStyle(AccountsKit.SecondaryButton(compact: true))
                            .help("Choose a different Google client file")
                    }
                }

                if let pending = model.pendingClient {
                    ConfirmCard(text: pending.message, confirm: "Switch and sign out",
                                onConfirm: { model.confirmClientSwitch() }, onCancel: { model.cancelClientSwitch() })
                }

                if model.google.isReady {
                    readyBody
                } else if model.google != .checking && model.google != .waitingForKeychain {
                    GoogleSetupGuide(model: model)
                }

                if let download = model.importedDownload {
                    trashOffer(download)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: AccountsKit.cardRadius, style: .continuous)
                .strokeBorder(AppTheme.accent, lineWidth: dropTargeted ? 2 : 0)
        )
        .accountsDropTarget([UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { model.importClientFile(url) } }
            }
            return true
        }
    }

    private var title: String {
        switch model.google {
        case .ready: return "Google sign-in: ready"
        case .checking: return "Google sign-in: checking\u{2026}"
        case .waitingForKeychain: return "Google sign-in: waiting for Keychain access"
        case .locked: return "Google sign-in: Keychain locked"
        case .unreadable: return "Google sign-in: needs a fresh client file"
        case .missing, .unknown: return "Google sign-in: not set up yet"
        }
    }

    private var subtitle: String {
        switch model.google {
        case .ready(let hint):
            return "Using your Desktop client \(hint) from the Keychain."
        case .checking:
            return "Reading your saved Google client from the Keychain."
        case .waitingForKeychain:
            return AccountsModel.keychainNoticeText
        case .locked:
            return "Unlock your Mac and I\u{2019}ll read it again."
        case .unreadable(let reason):
            return reason
        case .missing, .unknown:
            return GoogleSetupText.intro
        }
    }

    private var statusColor: Color {
        switch model.google {
        case .ready: return AppTheme.good
        case .checking, .waitingForKeychain, .locked, .missing, .unknown: return AppTheme.warn
        case .unreadable: return AppTheme.bad
        }
    }

    // MARK: Ready

    private var readyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(model.setupCheck == .running ? "Checking\u{2026}" : "Check my setup") {
                    Task { await model.checkSetup() }
                }
                .buttonStyle(AccountsKit.PrimaryButton(compact: true))
                .disabled(model.setupCheck == .running)
                Button(GoogleSetupText.why) { model.setupWhyOpen.toggle() }
                    .buttonStyle(AccountsKit.LinkButton())
                Spacer(minLength: 8)
                Button("Remove Google client\u{2026}") { model.confirmingRemoveClient = true }
                    .buttonStyle(AccountsKit.LinkButton(tint: AppTheme.text3))
            }
            if model.setupWhyOpen { WhyLines() }
            if model.accounts.isEmpty {
                // The next thing they'll see is Google's warning: say what to click before it shows.
                Text(LocalizedStringKey(GoogleSetupText.consentHint))
                    .font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            checkResult
            if model.confirmingRemoveClient {
                ConfirmCard(text: removeMessage, confirm: "Remove client",
                            onConfirm: { model.removeGoogleClient() }, onCancel: { model.confirmingRemoveClient = false })
            }
        }
    }

    private var removeMessage: String {
        switch model.accounts.count {
        case 0: return "This removes your Google client from the Keychain. You can add it again any time."
        case 1: return "Removing the Google client signs out your 1 account. It stays listed, and you approve it again after a new setup."
        default: return "Removing the Google client signs out all \(model.accounts.count) accounts. They stay listed, and you approve each again after a new setup."
        }
    }

    @ViewBuilder private var checkResult: some View {
        switch model.setupCheck {
        case .idle, .running:
            EmptyView()
        case .needsAccount:
            resultLine("Connect an account first, then I can check both APIs with it.", color: AppTheme.text2, symbol: "info.circle.fill")
        case .done(let check):
            VStack(alignment: .leading, spacing: 6) {
                resultLine(check.signInLine, color: check.signIn == .ok ? AppTheme.good : AppTheme.warn,
                           symbol: check.signIn == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                ForEach(GoogleAPIKind.allCases, id: \.self) { api in
                    let result = check.apis[api] ?? .failed("not_checked")
                    HStack(spacing: 8) {
                        resultLine(check.line(for: api), color: result == .ok ? AppTheme.good : AppTheme.warn,
                                   symbol: result == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        if result == .disabled {
                            Button("Turn it on") { model.openConsole(api.enableURL(projectNumber: model.projectNumber)) }
                                .buttonStyle(AccountsKit.LinkButton())
                        }
                    }
                }
                if check.allGood {
                    Text("All set. Your accounts can sync mail and calendars.")
                        .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }

    private func resultLine(_ text: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text).font(AppTheme.font(12, .medium)).foregroundStyle(AppTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trashOffer(_ file: URL) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "trash").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.text2)
                .accessibilityHidden(true)
            Text("\(file.lastPathComponent) still holds the client secret. It\u{2019}s safe in your Keychain now.")
                .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                .lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Move to Trash") { model.trashImportedDownload() }
                .buttonStyle(AccountsKit.SecondaryButton(compact: true))
            Button("Keep") { model.keepImportedDownload() }
                .buttonStyle(AccountsKit.LinkButton(tint: AppTheme.text3))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }
}

/// The six steps, one at a time (D-038): what to do, the Google Cloud page that does it, Back / Done.
struct GoogleSetupGuide: View {
    @ObservedObject var model: AccountsModel

    var body: some View {
        let step = model.setupStep
        VStack(alignment: .leading, spacing: 12) {
            pills(step)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(step.counter) \u{00B7} \(step.title)")
                    .font(AppTheme.font(13.5, .bold))
                    .foregroundStyle(AppTheme.text)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(step.lines.enumerated()), id: \.offset) { _, line in
                    Text(LocalizedStringKey(line))
                        .font(AppTheme.font(12.5))
                        .foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let links = step.links(projectNumber: model.projectNumber)
            if !links.isEmpty {
                HStack(spacing: 8) {
                    ForEach(links, id: \.url) { link in
                        Button {
                            model.openConsole(link.url)
                        } label: {
                            Label(link.title, systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(AccountsKit.SecondaryButton(compact: true))
                        .help(link.url.host ?? "")
                    }
                }
            }
            if step == .file { dropZone }
            if let problem = model.clientFileProblem { problemLine(problem) }
            HStack(spacing: 10) {
                if let previous = step.previous {
                    Button("Back") { model.showSetupStep(previous) }
                        .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.text2))
                }
                if let next = step.next {
                    Button("Done, next") { model.showSetupStep(next) }
                        .buttonStyle(AccountsKit.PrimaryButton(compact: true))
                }
                Spacer(minLength: 8)
                Button(GoogleSetupText.why) { model.setupWhyOpen.toggle() }
                    .buttonStyle(AccountsKit.LinkButton())
            }
            if model.setupWhyOpen { WhyLines() }
        }
    }

    /// ① ② ③ ④ ⑤ ⑥: earlier steps ticked, the open one filled; each one opens its step.
    private func pills(_ current: GoogleSetupStep) -> some View {
        HStack(spacing: 6) {
            ForEach(GoogleSetupStep.allCases) { step in
                let done = step.rawValue < current.rawValue
                let open = step == current
                Group {
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 9.5, weight: .heavy))
                            .foregroundStyle(AppTheme.accent)
                    } else {
                        Text("\(step.rawValue)").font(AppTheme.font(11, .heavy))
                            .foregroundStyle(open ? AppTheme.accentText : AppTheme.text3)
                    }
                }
                .frame(width: 22, height: 22)
                .background(Circle().fill(open ? AppTheme.accent : (done ? AppTheme.accentSoft : Color.white.opacity(0.06))))
                .contentShape(Circle())
                .onTapGesture { model.showSetupStep(step) }
                .ycStepButton("Step \(step.rawValue): \(step.title)", value: open ? "Open" : (done ? "Done" : "To do")) {
                    model.showSetupStep(step)
                }
                if step.next != nil {
                    Rectangle().fill(done ? AppTheme.accent.opacity(0.5) : AppTheme.stroke).frame(width: 10, height: 1.5)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                Text("Drop your client_secret JSON file here")
                    .font(AppTheme.font(13, .semibold))
                    .foregroundStyle(AppTheme.text)
            }
            HStack(spacing: 10) {
                Button("Choose client file\u{2026}") { model.chooseClientFile() }
                    .buttonStyle(AccountsKit.PrimaryButton(compact: true))
                #if YC_DEV_TOOLS   // developer builds only (D-035); release never finds a developer file
                if model.devClientFile != nil {
                    Button("Import from developer file") { model.importDevClientFile() }
                        .buttonStyle(AccountsKit.SecondaryButton(compact: true))
                        .help("Copies the Google client from your local developer file into your Keychain")
                }
                #endif
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }

    private func problemLine(_ problem: ClientFileProblem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.warn).accessibilityHidden(true)
                Text(problem.message).font(AppTheme.font(12, .medium)).foregroundStyle(AppTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link = problem.link {
                Button(link.title) { model.openConsole(link.url) }
                    .buttonStyle(AccountsKit.SecondaryButton(compact: true))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.warn.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.warn.opacity(0.3)))
    }
}

/// "Why do I need this?": three plain lines.
private struct WhyLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(GoogleSetupText.whyLines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(AppTheme.text3).frame(width: 4, height: 4).accessibilityHidden(true)
                    Text(line).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }
}

/// A plain confirm card (switching or removing the Google client). No humour: it signs accounts out.
struct ConfirmCard: View {
    let text: String
    let confirm: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppTheme.warn).accessibilityHidden(true)
                Text(text).font(AppTheme.font(12.5, .medium)).foregroundStyle(AppTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(confirm, action: onConfirm)
                    .buttonStyle(AccountsKit.PrimaryButton(compact: true))
                Button("Cancel", action: onCancel)
                    .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.text2))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.warn.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.warn.opacity(0.35)))
    }
}

private extension View {
    /// A drawn step pill as one VoiceOver button (Accounts has no `ycAccessibleButton`).
    func ycStepButton(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        self.accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(value))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}
