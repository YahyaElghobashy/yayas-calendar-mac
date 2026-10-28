import SwiftUI

/// "Add a Google account" / "Sign in to ORB again": explains what Google will show, then hands the
/// consent page to the browser (or copies its link) and waits for the loopback redirect.
struct AddAccountSheet: View {
    @ObservedObject var model: AccountsModel
    /// Fixed clock for headless renders; nil = now.
    var now: Date?

    private var target: AddFlowTarget { model.addTarget }
    private var reauthAccount: AccountRecord? { target.reauthAccount.flatMap { model.record($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(AppTheme.font(20, .heavy))
                    .foregroundStyle(AppTheme.text)
                Spacer()
                Button {
                    model.dismissAddSheet()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(AccountsKit.IconButton())
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            switch model.addPhase {
            case .idle: intro
            case .waiting(let waiting): waitingView(waiting)
            case .finishing: finishing
            case .success(let success): successView(success)
            case .failed(let failure): failedView(failure)
            }
        }
        .padding(26)
        .frame(width: 540, alignment: .topLeading)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
    }

    private var title: String {
        if let account = reauthAccount { return "Sign in to \(account.tag) again" }
        return "Add a Google account"
    }

    // MARK: - Idle

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            if reauthAccount == nil {
                providerRow(mark: .google, name: "Google", detail: "Workspace or personal Gmail", available: true)
            } else if let account = reauthAccount {
                Text("Google signed \(account.email) out. Approve me once more and everything carries on: same name, colour and logo.")
                    .font(AppTheme.font(13))
                    .foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.google.isReady {
                VStack(alignment: .leading, spacing: 10) {
                    AccountsKit.SectionLabel(text: "What happens next")
                    step(1, "Google asks you to pick an account and lets me see your mail and calendar.")
                    step(2, "Google says it hasn\u{2019}t verified the app. That\u{2019}s the one you made in Google Cloud: click **Advanced**, then **Go to Yaya\u{2019}s Calendar (unsafe)**, or whatever name you gave your app.")
                    step(3, "**Tick every box.** I need mail and calendar to fill your widgets; leave one out and I\u{2019}ll have to ask again.")
                }
                HStack(spacing: 10) {
                    Button("Open in browser") { model.beginSignIn(mode: .browser) }
                        .buttonStyle(AccountsKit.PrimaryButton())
                        .keyboardShortcut(.defaultAction)
                    Button("Copy sign-in link") { model.beginSignIn(mode: .link) }
                        .buttonStyle(AccountsKit.SecondaryButton())
                    Spacer()
                }
                Text("Signed in to that account in a different browser or profile? Copy the link and paste it there.")
                    .font(AppTheme.font(11.5))
                    .foregroundStyle(AppTheme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                setupFirst
            }
            footnote
        }
    }

    private var setupFirst: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AccountsKit.Dot(color: AppTheme.warn)
                Text("Set up Google sign-in first")
                    .font(AppTheme.font(13.5, .bold))
                    .foregroundStyle(AppTheme.text)
            }
            Text("You make your own free Google sign-in once, in about 5 minutes. The guide under Accounts \u{2192} Sign-in setup walks you through it. Already have the client_secret JSON file? Choose it here; it goes straight into your Keychain.")
                .font(AppTheme.font(12.5))
                .foregroundStyle(AppTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Choose client file\u{2026}") { model.chooseClientFile() }
                    .buttonStyle(AccountsKit.PrimaryButton(compact: true))
                #if YC_DEV_TOOLS   // developer builds only (D-035); release never finds a developer file
                if model.devClientFile != nil {
                    Button("Import from developer file") { model.importDevClientFile() }
                        .buttonStyle(AccountsKit.SecondaryButton(compact: true))
                }
                #endif
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.warn.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.warn.opacity(0.3)))
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 9))
            Text("Your sign-in stays on this Mac, in your Keychain, and goes only to Google.")
        }
        .font(AppTheme.font(11))
        .foregroundStyle(AppTheme.text3)
    }

    // MARK: - Waiting

    private func waitingView(_ waiting: SignInWaiting) -> some View {
        let current = now ?? Date()
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().fill(AppTheme.accentSoft).frame(width: 46, height: 46)
                    Image(systemName: waiting.mode == .link ? "link" : "safari")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for you to approve\u{2026}")
                        .font(AppTheme.font(16, .bold))
                        .foregroundStyle(AppTheme.text)
                    Text(waiting.mode == .link
                         ? "Link copied. Paste it into the browser where you\u{2019}re signed in to that Google account, then approve."
                         : "Your browser has Google\u{2019}s page open. Pick the account, tick every box, approve.")
                        .font(AppTheme.font(12.5))
                        .foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TimelineView(.periodic(from: current, by: 1)) { context in
                HStack(spacing: 6) {
                    Text("This link works for")
                    Text(Self.remaining(until: waiting.deadline, now: now ?? context.date))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.text)
                    Text("more.")
                }
                .font(AppTheme.font(12, .medium))
                .foregroundStyle(AppTheme.text3)
            }
            HStack(spacing: 10) {
                Button(waiting.mode == .link ? "Copy link again" : "Copy link instead") { model.copySignInLinkAgain() }
                    .buttonStyle(AccountsKit.SecondaryButton())
                    .disabled(waiting.link == nil)
                Button("Cancel") { model.cancelSignIn() }
                    .buttonStyle(AccountsKit.SecondaryButton(tint: AppTheme.text2))
                Spacer()
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.stroke))
    }

    /// "4:32" until the loopback gives up.
    static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var finishing: some View {
        HStack(spacing: 10) {
            AccountsKit.Dot(color: AppTheme.accent)
            Text("Got it. Saving your sign-in\u{2026}")
                .font(AppTheme.font(14, .semibold))
                .foregroundStyle(AppTheme.text)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Done

    private func successView(_ success: SignInSuccess) -> some View {
        let account = model.record(success.accountId)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AccountsKit.LogoBadge(image: model.logos[success.accountId],
                                      busy: model.fetchingLogo.contains(success.accountId))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(account?.displayName ?? "Your account") is connected")
                        .font(AppTheme.font(16, .bold))
                        .foregroundStyle(AppTheme.text)
                    Text(success.email)
                        .font(AppTheme.font(12.5))
                        .foregroundStyle(AppTheme.text2)
                }
            }
            if let note = success.note {
                Text(note)
                    .font(AppTheme.font(12.5))
                    .foregroundStyle(AppTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else if success.isNew {
                Text("Rename it, pick a colour or swap the logo any time on the Accounts page.")
                    .font(AppTheme.font(12.5))
                    .foregroundStyle(AppTheme.text2)
            }
            if let domain = success.logoDomain {
                Text("I asked \(domain)\u{2019}s own website for its logo: a few requests from this Mac, seven at most. Turn it off in Settings \u{2192} What leaves this Mac.")
                    .font(AppTheme.font(11.5))
                    .foregroundStyle(AppTheme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Done") { model.dismissAddSheet() }
                    .buttonStyle(AccountsKit.PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                if reauthAccount == nil {
                    Button("Add another") { model.presentAdd() }
                        .buttonStyle(AccountsKit.SecondaryButton())
                }
                Spacer()
            }
        }
    }

    private func failedView(_ failure: AddAccountFailure) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(color(for: failure).opacity(0.16)).frame(width: 40, height: 40)
                    Image(systemName: failure == .cancelled ? "arrow.uturn.backward" : "exclamationmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(color(for: failure))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                        .font(AppTheme.font(16, .bold))
                        .foregroundStyle(AppTheme.text)
                    Text(failure.message)
                        .font(AppTheme.font(12.5))
                        .foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if failure.suggestsPublishing {
                Button("Open Audience in Google Cloud") { model.openConsole(GoogleConsole.audience) }
                    .buttonStyle(AccountsKit.SecondaryButton(compact: true))
            }
            if failure == .clientRejected(code: "deleted_client") {
                Button("Open Clients in Google Cloud") { model.openConsole(GoogleConsole.clients) }
                    .buttonStyle(AccountsKit.SecondaryButton(compact: true))
            }
            if failure.isAdminBlocked {
                AdminKitView(clientID: model.googleClientID, copyClientID: model.copyClientID,
                             copyMessage: model.copyAdminMessage)
            }
            if failure == .notConfigured {
                setupFirst
            }
            HStack(spacing: 10) {
                Button("Try again") { model.addPhase = .idle }
                    .buttonStyle(AccountsKit.PrimaryButton())
                    .keyboardShortcut(.defaultAction)
                Button("Close") { model.dismissAddSheet() }
                    .buttonStyle(AccountsKit.SecondaryButton())
                Spacer()
            }
        }
    }

    private func color(for failure: AddAccountFailure) -> Color {
        switch failure {
        case .cancelled, .timedOut: return AppTheme.text2
        case .missingScopes, .offline, .browserUnavailable, .notConfigured: return AppTheme.warn
        default: return AppTheme.bad
        }
    }

    // MARK: - Pieces

    private func providerRow(mark: Provider, name: String, detail: String, available: Bool) -> some View {
        HStack(spacing: 12) {
            ProviderMark(provider: mark)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(AppTheme.font(13.5, .bold)).foregroundStyle(AppTheme.text)
                Text(detail).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
            }
            Spacer()
            if available {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(AppTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(available ? AppTheme.accentSoft : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(available ? AppTheme.accent.opacity(0.55) : AppTheme.stroke))
        .opacity(available ? 1 : 0.55)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(AppTheme.font(11, .bold))
                .foregroundStyle(AppTheme.accentText)
                .frame(width: 19, height: 19)
                .background(Circle().fill(AppTheme.accent))
            Text(text)
                .font(AppTheme.font(13))
                .foregroundStyle(AppTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Original monograms (no traced vendor logos): Google = circle; the squircle stays for the dormant
/// Microsoft provider (nothing in 1.0 shows it).
struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            switch provider {
            case .google:
                Circle().fill(Color.white.opacity(0.92))
            case .microsoft:
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.white.opacity(0.92))
            }
            Text(provider == .google ? "G" : "O")
                .font(AppTheme.font(size * 0.5, .heavy))
                .foregroundStyle(Color(hex: 0x0E1A22))
        }
        .frame(width: size, height: size)
    }
}
