import SwiftUI

/// Settings. MadeByFooter() is the last element: nothing goes below it.
struct SettingsView: View {
    /// Settings → Mail (mail is on, D-029; renders of the mail-off seam pass nil).
    var mail: SettingsMailModel? = nil
    /// Menu bar: what shows beside the icon, and ⌃⌥J.
    var menuBar: MenuBarSettingsModel? = nil
    /// Join with Fathom (D-045): which account Fathom is on, and ⌃⌥J. The card shows while Fathom is on this Mac.
    var fathom: FathomLinksModel? = nil
    /// Yaya's Murmur (D-046): its state and ⌃⌥J. The card shows while Murmur is on this Mac.
    var recorders: RecorderChoicesModel? = nil
    var directory: () -> AccountDirectory = { AccountDirectory.current() }
    /// "Welcome guide · Open": the onboarding sheet again (resumes where you left off).
    var openGuide: (() -> Void)? = nil
    /// "Remove everything and quit…" (D-037): the confirm sheet.
    var removeEverything: (() -> Void)? = nil
    @Environment(\.headlessRender) private var headless
    @Local private var launchAtLogin = false
    @Local private var loaded = false
    @Local private var placement: PlacementChoice = .inApplications
    @Local private var moveNote: String?
    @Local private var fetchLogos = true
    @Local private var shareWithDeck = false
    @Local private var deckInstalled = false

    private var canRegister: Bool { !headless && LoginItem.isInApplications }

    var body: some View {
        ShellScroll {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "Settings", subtitle: "The few things worth a switch.")
                ShellCard(padding: 0) {
                    VStack(spacing: 0) {
                        row(title: "Launch at login",
                            detail: loginDetail) {
                            ShellSwitch(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }),
                                        enabled: canRegister, label: "Launch at login")
                        }
                        if let move = moveRow {
                            divider
                            row(title: "Applications folder", detail: move.detail) {
                                if let title = move.button {
                                    Button(title) { moveNote = AppMover.move(toUserApplications: move.user) }
                                        .buttonStyle(AccountsKit.SecondaryButton(compact: true))
                                }
                            }
                        }
                        divider
                        row(title: "Version", detail: "Yaya's Calendar \(AppInfo.version) (build \(AppInfo.build))") {
                            EmptyView()
                        }
                        divider
                        row(title: "Data folder", detail: "\(Profile.dataRootForDisplay) · private to you (0700)") {
                            EmptyView()
                        }
                    }
                }
                .frame(maxWidth: 640)
                privacyCard.frame(maxWidth: 640)
                if let menuBar {
                    SettingsMenuBarCard(model: menuBar, openGuide: openGuide)
                        .frame(maxWidth: 640)
                }
                if let fathom {
                    SettingsFathomCard(model: fathom, directory: directory, showsHotkey: !(recorders?.active ?? false))
                        .frame(maxWidth: 640)
                    if let recorders {
                        SettingsMurmurCard(recorders: recorders, links: fathom)
                            .frame(maxWidth: 640)
                    }
                }
                if let mail {
                    SettingsMailCard(model: mail)
                        .frame(maxWidth: 640)
                }
                NotificationSettingsCard(showMail: mail != nil).frame(maxWidth: 640)
                removeCard.frame(maxWidth: 640)
                Spacer(minLength: 12)
                MadeByFooter()
                    .frame(maxWidth: 640)
            }
            .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 24)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            guard !headless else { return }
            launchAtLogin = LoginItem.isEnabled
            placement = AppMover.placement()
            fetchLogos = AccountsPreferences.fetchLogos
            deckInstalled = DeckSharing.deckInstalled
            shareWithDeck = DeckSharing.isOn
        }
    }

    // MARK: Applications folder (D-039)

    private var moveRow: (detail: String, button: String?, user: Bool)? {
        if let moveNote { return (moveNote, nil, false) }
        switch placement {
        case .inApplications: return nil
        case .moveToApplications:
            return ("Launch at login and a steady home for the widgets need me in Applications.", "Move me to Applications", false)
        case .offerUserApplications(let reason):
            return ("\(reason) I\u{2019}ll leave it alone; your own ~/Applications works too.", "Move me to ~/Applications", true)
        case .notNow(let reason):
            return (reason, nil, false)
        }
    }

    // MARK: What leaves this Mac (D-039)

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What leaves this Mac").font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                Text("Your mail and calendars go only between Google and this Mac. Two things reach past Google, and both are yours to switch: company logos and images in mail.")
                    .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            ShellCard(padding: 0) {
                VStack(spacing: 0) {
                    row(title: "Fetch company logos",
                        detail: "When you connect a work account, I make a few requests to that company\u{2019}s own website (seven at most), only to find its logo. Personal Gmail is never asked. Off, I ask only when you choose \u{201C}Fetch logo from website\u{201D}.") {
                        ShellSwitch(isOn: Binding(get: { fetchLogos }, set: { on in
                            fetchLogos = on
                            if !headless { AccountsPreferences.fetchLogos = on }
                        }), label: "Fetch company logos")
                    }
                    divider
                    row(title: "Images in mail", detail: imagesDetail) { EmptyView() }
                }
            }
            Text("STAYS ON THIS MAC").font(AppTheme.font(10, .bold)).tracking(0.5).foregroundStyle(AppTheme.text3)
                .padding(.top, 4)
            ShellCard(padding: 0) {
                row(title: "Share upcoming meetings with Deck", detail: deckDetail) {
                    ShellSwitch(isOn: Binding(get: { shareWithDeck }, set: { on in
                        shareWithDeck = on
                        if !headless { DeckSharing.set(on) }
                    }), label: "Share upcoming meetings with Deck")
                }
            }
        }
    }

    private var imagesDetail: String {
        let what = "Pictures hosted outside a message stay hidden until you load them, for that message or that sender. A loaded picture comes from wherever the sender keeps it, so the sender, or their mail service, can see your IP address and when you opened the message."
        return mail == nil ? what : what + " Your choices are under Mail, below."
    }

    private var deckDetail: String {
        let what = "Titles, times, attendees and join links of the next two days, in a private file on this Mac that Deck, a meeting recorder, reads."
        return deckInstalled ? what + " Deck is installed, so this starts on." : what + " Deck isn\u{2019}t on this Mac, so it starts off."
    }

    // MARK: Remove everything (D-037)

    private var removeCard: some View {
        ShellCard(padding: 0) {
            row(title: "Remove everything",
                detail: "Signs out every account at Google, deletes my Keychain items, cached mail and calendars, widget data and settings, then quits. The app itself stays until you drag it to the Trash.") {
                Button("Remove everything and quit\u{2026}") { removeEverything?() }
                    .buttonStyle(DangerButtonStyle())
                    .accessibilityHint(Text("Asks first"))
            }
        }
        .padding(.top, 8)
    }

    private var loginDetail: String {
        if headless || !LoginItem.isInApplications {
            return moveRow?.button != nil ? "Works once I live in an Applications folder. Move me there below."
                                          : "Works once I live in an Applications folder. Drag me there in Finder."
        }
        if LoginItem.needsApproval { return "Waiting for your OK in System Settings → General → Login Items." }
        return "Starts quietly in the menu bar so your widgets always have someone to talk to."
    }

    private func setLaunchAtLogin(_ on: Bool) {
        LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 18)
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

/// Settings → Menu bar: what shows beside the icon, the ⌃⌥J hotkey, and the welcome guide.
struct SettingsMenuBarCard: View {
    @ObservedObject var model: MenuBarSettingsModel
    var openGuide: (() -> Void)?
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Menu bar").font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                Text("Click the calendar icon for your next meetings. Right-click it (or control-click) for Sync now, Pause notifications and Quit.")
                    .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            ShellCard(padding: 0) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 14) {
                            Text("Menu bar shows").font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                            Spacer(minLength: 12)
                            SegmentPicker(options: model.modes.map { ($0, $0.title) },
                                          selection: Binding(get: { model.shownMode }, set: { model.setMode($0) }))
                        }
                        Text(model.modeDetail).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    divider
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text("Join with").font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                                Text(JoinHotkey.display)
                                    .font(AppTheme.font(12, .bold)).foregroundStyle(AppTheme.text)
                                    .padding(.horizontal, 7).frame(height: 20)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.09)))
                                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
                                    .accessibilityLabel(Text("Control Option J"))
                            }
                            Text(model.hotkeyDetail).font(AppTheme.font(11.5))
                                .foregroundStyle(model.hotkeyNeedsAttention ? AppTheme.warn : AppTheme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        ShellSwitch(isOn: Binding(get: { model.hotkeyEnabled }, set: { model.setHotkey($0) }),
                                    label: "Join with Control Option J")
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    if let openGuide {
                        divider
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Welcome guide").font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                                Text("The \(OnboardingFlow.countWord.lowercased()) setup steps, picked up where you left them.")
                                    .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                            }
                            Spacer(minLength: 12)
                            Button("Open", action: openGuide).buttonStyle(PrimaryButtonStyle())
                                .accessibilityLabel(Text("Open the welcome guide"))
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                    }
                }
            }
        }
        .onAppear { if !headless { model.reload() } }
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 18)
    }
}

/// Settings → Mail: Primary inbox and the signature per account, the senders allowed to load images,
/// and "Ask before sending to other people" (D-023).
struct SettingsMailCard: View {
    @ObservedObject var model: SettingsMailModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Mail").font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                Text("Signatures and how your mail looks, which Gmail tab counts as your inbox, who may show you images, and when I check before sending.")
                    .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
            }
            .padding(.top, 8)
            ShellCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if model.rows.isEmpty {
                        Text("Connect a Google account and its mail settings appear here.")
                            .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                            .padding(18)
                    }
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { divider }
                        accountBlock(row)
                    }
                    divider
                    SettingsWritingBlock(model: model)
                    divider
                    imagesBlock
                    divider
                    SettingsAttachmentsBlock()
                    divider
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.raised.fill").font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(model.askBeforeSending ? AppTheme.accent : AppTheme.text3)
                                    .accessibilityHidden(true)
                                Text(SettingsMailModel.askTitle).font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                            }
                            Text(model.safeSendLine).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        ShellSwitch(isOn: Binding(get: { model.askBeforeSending }, set: { model.setAskBeforeSending($0) }),
                                    label: SettingsMailModel.askTitle)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
            }
            if let status = model.status {
                Label(status, systemImage: model.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(AppTheme.font(12, .semibold)).foregroundStyle(model.failed ? AppTheme.bad : AppTheme.good)
            }
        }
        .onAppear { if !headless { model.load() } }
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 18)
    }

    private func accountBlock(_ row: SettingsMailModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MailLogoBadge(account: row.account, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.account.tag).font(AppTheme.font(13.5, .bold)).foregroundStyle(AppTheme.text)
                    Text(row.account.email).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Primary inbox only").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text)
                    Text("Promotions and Social stay out of the way").font(AppTheme.font(10.5)).foregroundStyle(AppTheme.text3)
                }
                ShellSwitch(isOn: Binding(get: { row.primaryOnly }, set: { model.setPrimaryOnly(row.id, $0) }),
                            label: "Primary inbox only for \(row.account.tag)")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("SIGNATURE").font(AppTheme.font(10, .bold)).tracking(0.5).foregroundStyle(AppTheme.text3)
                RichSignatureEditor(model: model, row: row)
                if row.isDirty {
                    HStack(spacing: 12) {
                        Button("Save signature") { model.saveSignature(row.id) }.buttonStyle(PrimaryButtonStyle())
                        Button("Undo changes") { model.revertSignature(row.id) }
                            .buttonStyle(.plain).font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                    }
                }
            }
            .padding(.leading, 32)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var imagesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(SettingsMailModel.correspondentsTitle).font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                    Text(SettingsMailModel.correspondentsLine).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                ShellSwitch(isOn: Binding(get: { model.writing.imagesFromCorrespondents }, set: { model.setImagesFromCorrespondents($0) }),
                            label: SettingsMailModel.correspondentsTitle)
            }
            .padding(.bottom, 6)
            Text("Images from these senders load by themselves").font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
            if model.senders.isEmpty {
                Text("Nobody yet. Pick \u{201C}Always for this sender\u{201D} on a message to add one.")
                    .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
            } else {
                ForEach(model.senders, id: \.self) { sender in
                    HStack(spacing: 8) {
                        Image(systemName: "photo").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.text3)
                        Text(sender).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Remove") { model.removeSender(sender) }
                            .buttonStyle(.plain).font(AppTheme.font(12, .bold)).foregroundStyle(AppTheme.accent)
                    }
                    .frame(height: 24)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
