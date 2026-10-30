import SwiftUI

// Yaya's Mail Helper's cards (D-050): the hand-over approval card (in the spirit of D-023's send card, but its own
// component: the send card is untouched), the confirmation card (Undo all, Undo today, Take back), and the composer's
// "Draft with AI" button and its pop-over.

// MARK: - Hand-over

/// The dimmed page and, on top, the card. A click on the dimmed part is Cancel.
struct MailHelperHandoverOverlay: View {
    @ObservedObject var model: MailHelperModel
    let handover: MailHelperHandover

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.62)
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancelHandover() }
                    .accessibilityHidden(true)
                MailHelperHandoverCard(model: model, handover: handover)
                    .frame(maxHeight: max(0, proxy.size.height - 48))
                    .padding(24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// "Hand over ORB's sign-in?": the account, the mail server's key fingerprint (to compare with the helper's own
/// window), personal or work, what is handed over and what it can and can't do. Return hands over (only 0.3 s after
/// the card appears), Esc goes back.
struct MailHelperHandoverCard: View {
    @ObservedObject var model: MailHelperModel
    let handover: MailHelperHandover
    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.accentSoft))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    if headless { title } else { title.accessibilityFocused($titleFocused) }
                    Text("Your mail server sorts this mailbox from now on: labels, archive, read or unread. It has no way to send, delete, forward or change settings, and every change can be undone.")
                        .font(AppTheme.font(12.5, .medium)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            details
            Text("What goes: this account\u{2019}s Google sign-in (its refresh token and your Google client), sealed so only your mail server can open it. Yaya\u{2019}s Mail Helper carries it but can\u{2019}t read it. Nothing else leaves this Mac.")
                .font(AppTheme.font(12)).foregroundStyle(AppTheme.text3)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = model.handoverProblem {
                Label {
                    Text(verbatim: problem)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.warn)
                .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(22)
        .frame(width: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.background))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AppTheme.strokeStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { titleFocused = true }
    }

    private var title: some View {
        Text(verbatim: "Hand over \(handover.tag)\u{2019}s sign-in?")
            .font(AppTheme.font(19, .heavy)).foregroundStyle(AppTheme.text)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            detail("Account") {
                HStack(spacing: 6) {
                    MailLogoBadge(account: model.cards.first { $0.id == handover.account }?.account, size: 15)
                    Text(verbatim: handover.tag).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text)
                    Text(verbatim: handover.email).font(AppTheme.font(12)).foregroundStyle(AppTheme.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Account \(handover.tag), \(handover.email)"))
            }
            Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 86)
            detail("Server key") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: handover.fingerprint).font(.system(size: 13.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.text).tracking(0.6)
                    Text("Check it matches the key Yaya\u{2019}s Mail Helper shows.").font(AppTheme.font(11)).foregroundStyle(AppTheme.text3)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Server key \(handover.fingerprint.map { String($0) }.joined(separator: " "))"))
            }
            Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 86)
            detail("Kind") {
                HStack(spacing: 10) {
                    SegmentPicker(options: [("personal", "Personal"), ("work", "Work")],
                                  selection: Binding(get: { model.handover?.kind ?? handover.kind }, set: { model.setHandoverKind($0) }))
                    Text(handover.kind == "work" ? "Claude stays off unless you pick a work credential." : "Your own Claude may help with mail it\u{2019}s unsure about.")
                        .font(AppTheme.font(11)).foregroundStyle(AppTheme.text3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detail<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3)
                .frame(width: 64, alignment: .leading)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(minHeight: 36)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Text("Return hands over  \u{00B7}  Esc goes back")
                .font(AppTheme.font(11.5, .medium)).foregroundStyle(AppTheme.text3)
                .lineLimit(1)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Button("Cancel") { model.cancelHandover() }
                .buttonStyle(.plain)
                .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                .keyboardShortcut(.cancelAction)
                .disabled(model.handoverBusy)
                .accessibilityHint(Text("Hands nothing over"))
            Button {
                Task { await model.approveHandover() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "key.horizontal.fill").font(.system(size: 11.5, weight: .bold))
                    Text(model.handoverBusy ? "Sealing\u{2026}" : "Hand over")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(model.handoverBusy)
            .accessibilityLabel(Text(verbatim: "Hand over \(handover.tag)\u{2019}s sign-in"))
        }
        .padding(.top, 2)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Confirmations

struct MailHelperConfirmOverlay: View {
    @ObservedObject var model: MailHelperModel
    let confirm: MailHelperModel.Confirm

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture { model.confirm = nil }
                .accessibilityHidden(true)
            card.padding(24)
        }
    }

    private var words: (title: String, line: String, button: String) {
        switch confirm {
        case .undoAll(_, let tag):
            return ("Undo \(tag)\u{2019}s whole clean-up?",
                    "Every conversation it moved goes back exactly as it was: inbox, labels and read state. Your rules stay.", "Undo all")
        case .undoToday:
            return ("Undo everything sorted today?",
                    "Every email sorted since midnight goes back the way it was, in every account.", "Undo today")
        case .forget(_, let tag):
            return ("Take back \(tag)\u{2019}s sign-in?",
                    "Your mail server forgets it and stops sorting this mailbox. Nothing in Gmail changes; you can hand it over again.", "Take back")
        }
    }

    private var card: some View {
        let w = words
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(AppTheme.bad)
                    .frame(width: 36, height: 36).background(Circle().fill(AppTheme.bad.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: w.title).font(AppTheme.font(18, .heavy)).foregroundStyle(AppTheme.text)
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    Text(verbatim: w.line).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { model.confirm = nil }.buttonStyle(.plain)
                    .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                    .keyboardShortcut(.cancelAction)
                Button(w.button) { model.confirmed() }
                    .buttonStyle(AccountsKit.SecondaryButton(tint: AppTheme.bad))
            }
        }
        .padding(22)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.background))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AppTheme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Composer: Draft with AI

/// In the composer's title row (plain and rich alike), only for a reply while the helper is installed.
struct MailDraftButton: View {
    @ObservedObject var model: MailHelperDraftModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        Button {
            model.open.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11.5, weight: .bold))
                Text(model.isWorking ? "Drafting\u{2026}" : "Draft with AI")
            }
        }
        .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.accent))
        .help("Yaya\u{2019}s Mail Helper drafts a reply in your voice. It never sends.")
        .popover(isPresented: Binding(get: { !headless && model.open }, set: { model.open = $0 }), arrowEdge: .bottom) {
            MailDraftPopover(model: model)
        }
    }
}

/// Renders only: the pop-over as the system draws it, over the whole composer (ImageRenderer can't draw `.popover`).
struct MailDraftHeadlessPopover: View {
    @ObservedObject var model: MailHelperDraftModel

    var body: some View {
        if model.open {
            MailDraftPopover(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                .fixedSize()
        }
    }
}

/// "What should it say?", the model, the thinking level, then Draft (or the wait with Cancel, or why not).
struct MailDraftPopover: View {
    @ObservedObject var model: MailHelperDraftModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draft a reply in your voice").font(AppTheme.font(14, .heavy)).foregroundStyle(AppTheme.text)
            VStack(alignment: .leading, spacing: 5) {
                AccountsKit.SectionLabel(text: "What should it say? (optional)")
                Group {
                    if headless {
                        Text(verbatim: model.instruction.isEmpty ? "Say yes to Thursday, ask for the agenda" : model.instruction)
                            .foregroundStyle(model.instruction.isEmpty ? AppTheme.text3 : AppTheme.text)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        TextEditor(text: $model.instruction).scrollContentBackground(.hidden).foregroundStyle(AppTheme.text)
                    }
                }
                .font(AppTheme.font(12.5))
                .padding(8).frame(height: 62)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AppTheme.stroke))
                .disabled(model.isWorking)
                if let voice = model.voice {
                    MailVoiceNoteBar(voice: voice, disabled: model.isWorking)
                }
            }
            row("Model") {
                pickerButton(model.model.title, modelItems)
            }
            if !model.model.efforts.isEmpty {
                row("Thinking") {
                    pickerButton(MailDraftEffort.title(model.effort), model.model.efforts.map { e in
                        AccountsKit.PopUpMenuButton.Item(title: MailDraftEffort.title(e)) { model.effort = e }
                    })
                }
            }
            if let note = model.note, !model.isFailed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: note).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    if let name = model.enableCredential {
                        Button(model.enabling ? "Turning on\u{2026}" : "Turn on Claude for this account (\(name))") { model.enableClaude() }
                            .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.accent))
                            .disabled(model.enabling)
                    }
                }
            }
            if let last = model.lastNote, !model.isWorking, !model.isFailed {
                Text(verbatim: last).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 330, alignment: .leading)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
    }

    /// Local, then each cloud provider's current models under its name.
    private var modelItems: [AccountsKit.PopUpMenuButton.Item] {
        var items: [AccountsKit.PopUpMenuButton.Item] = []
        var last: String?
        for m in model.models {
            if let last, last != m.provider { items.append(.separator) }
            last = m.provider
            let title = m.provider == "codex" && !m.title.lowercased().contains("codex") ? "Codex \u{00B7} \(m.title)" : m.title
            items.append(AccountsKit.PopUpMenuButton.Item(title: title) { model.model = m })
        }
        return items
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2).frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func pickerButton(_ title: String, _ items: [AccountsKit.PopUpMenuButton.Item]) -> some View {
        Button {
            AccountsKit.MenuPresenter.show(items)
        } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .heavy))
            }
        }
        .buttonStyle(AccountsKit.SecondaryButton(compact: true))
        .disabled(model.isWorking)
    }

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .idle:
            HStack {
                Text("It never sends. You read it, then Send.").font(AppTheme.font(11)).foregroundStyle(AppTheme.text3)
                Spacer()
                Button("Draft") { model.draft() }.buttonStyle(AccountsKit.PrimaryButton(compact: true))
                    .keyboardShortcut(.defaultAction)
            }
        case .working:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    if !headless { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Writing\u{2026} \(model.elapsed(model.now))").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text)
                        Text("This can take a few minutes.").font(AppTheme.font(11)).foregroundStyle(AppTheme.text3)
                    }
                    Spacer()
                    Button("Cancel") { model.cancel() }.buttonStyle(AccountsKit.SecondaryButton(compact: true))
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.warn)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let name = model.enableCredential {
                        Button(model.enabling ? "Turning on\u{2026}" : "Turn on Claude (\(name))") { model.enableClaude() }
                            .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.accent))
                            .disabled(model.enabling)
                    }
                    Spacer()
                    Button("Try again") { model.draft() }.buttonStyle(AccountsKit.PrimaryButton(compact: true))
                }
            }
        }
    }
}

// MARK: - Draft with AI: the voice note

/// Under "What should it say?": say it instead of typing. Record, pause, stop, listen back, discard or send; the
/// helper writes it out on this Mac and the draft starts (D-052).
struct MailVoiceNoteBar: View {
    @ObservedObject var voice: MailVoiceNoteModel
    var disabled: Bool
    @Environment(\.headlessRender) private var headless

    var body: some View {
        Group {
            switch voice.phase {
            case .idle:
                HStack(spacing: 10) {
                    Button { voice.record() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill").font(.system(size: 11, weight: .bold))
                            Text("Say it instead")
                        }
                    }
                    .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.accent))
                    .help("Record what the reply should say. It\u{2019}s written out on this Mac.")
                    Text("Record, then Send").font(AppTheme.font(11)).foregroundStyle(AppTheme.text3)
                    Spacer(minLength: 0)
                }
            case .asking:
                status(spinner: true, "Waiting for microphone access\u{2026}")
            case .recording, .paused:
                live
            case .stopped:
                HStack(spacing: 8) {
                    round(voice.playing ? "pause.fill" : "play.fill", voice.playing ? "Pause" : "Listen back") { voice.togglePlay() }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Voice note").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text)
                        Text(MailVoiceNoteModel.clock(voice.elapsed)).font(AppTheme.font(11)).monospacedDigit().foregroundStyle(AppTheme.text3)
                    }
                    Spacer(minLength: 0)
                    round("trash", "Discard") { voice.discard() }
                    round("arrow.counterclockwise", "Record again") { voice.record() }
                    sendButton
                }
            case .sending:
                status(spinner: true, "Writing out your voice note\u{2026}")
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Yaya\u{2019}s Calendar can\u{2019}t use the microphone. Turn it on in System Settings \u{2192} Privacy & Security \u{2192} Microphone.")
                        .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.warn).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Settings") { voice.openPrivacy() }.buttonStyle(AccountsKit.SecondaryButton(compact: true))
                        Button("Not now") { voice.discard() }.buttonStyle(AccountsKit.SecondaryButton(compact: true))
                    }
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: message).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if voice.isFailedWithClip {
                            round(voice.playing ? "pause.fill" : "play.fill", "Listen back") { voice.togglePlay() }
                        }
                        Spacer(minLength: 0)
                        round("trash", "Discard") { voice.discard() }
                        if voice.isFailedWithClip { sendButton } else {
                            Button("Record again") { voice.record() }.buttonStyle(AccountsKit.SecondaryButton(compact: true))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(voice.phase == .recording ? AppTheme.bad.opacity(0.08) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(voice.phase == .recording ? AppTheme.bad.opacity(0.35) : AppTheme.stroke))
        .disabled(disabled)
        .animation(headless ? nil : .easeOut(duration: 0.15), value: voice.phase)
    }

    /// Recording or paused: the dot, the time, the bars, then pause or resume, stop and send.
    private var live: some View {
        let recording = voice.phase == .recording
        return HStack(spacing: 8) {
            Circle().fill(recording ? AppTheme.bad : AppTheme.text3).frame(width: 8, height: 8)
                .opacity(recording && !headless ? 0.6 + 0.4 * Double(voice.levels.last ?? 0) : 1)
            Text(recording ? MailVoiceNoteModel.clock(voice.elapsed) : "Paused \u{00B7} " + MailVoiceNoteModel.clock(voice.elapsed))
                .font(AppTheme.font(12, .semibold)).monospacedDigit().foregroundStyle(recording ? AppTheme.text : AppTheme.text2)
                .fixedSize()
            MailVoiceBars(levels: voice.levels, tint: recording ? AppTheme.accent : AppTheme.text3)
                .frame(height: 22)
            round(recording ? "pause.fill" : "record.circle", recording ? "Pause" : "Resume") {
                recording ? voice.pause() : voice.resume()
            }
            round("stop.fill", "Stop") { voice.stop() }
            sendButton
        }
    }

    private var sendButton: some View {
        Button { voice.send() } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperplane.fill").font(.system(size: 10.5, weight: .bold))
                Text("Send")
            }
        }
        .buttonStyle(AccountsKit.PrimaryButton(compact: true))
        .help("Write it out and draft the reply")
    }

    private func round(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(AppTheme.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(AppTheme.stroke))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func status(spinner: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            if spinner && !headless { ProgressView().controlSize(.small) }
            Text(text).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2)
            Spacer(minLength: 0)
            Button("Cancel") { voice.discard() }.buttonStyle(AccountsKit.SecondaryButton(compact: true))
        }
    }
}

/// The input level of the last few seconds, as rounded bars (newest on the right).
struct MailVoiceBars: View {
    var levels: [Float]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            // As many of the newest bars as fit (2.5 pt wide, 2 pt apart), right-aligned.
            let fit = max(0, min(levels.count, Int((geo.size.width + 2) / 4.5)))
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.suffix(fit).enumerated()), id: \.offset) { _, level in
                    Capsule().fill(tint.opacity(0.35 + 0.65 * Double(level)))
                        .frame(width: 2.5, height: max(3, geo.size.height * CGFloat(min(1, level * 1.4))))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
        }
        .frame(minWidth: 24, maxWidth: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}
