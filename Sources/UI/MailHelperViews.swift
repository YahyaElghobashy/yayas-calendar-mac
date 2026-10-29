import SwiftUI

// The Mail helper section (D-050): the owner's dashboard for Yaya's Mail Helper (Overview) and the daily digest
// (Digest), in the app's own dark look. Shown only while the helper is installed. Everything the helper wrote is drawn
// with `Text(verbatim:)`: plain text, never Markdown or a link. The logic lives in MailHelperSession.swift.

struct MailHelperSectionView: View {
    @ObservedObject var model: MailHelperModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 12)
            Rectangle().fill(AppTheme.stroke).frame(height: 1)
            content
        }
        .overlay(alignment: .bottom) {
            MailToastView(center: model.toasts)
                .padding(.bottom, 18)
                .animation(.easeOut(duration: 0.18), value: model.toasts.toast?.id)
        }
        .overlay {
            if let handover = model.handover {
                MailHelperHandoverOverlay(model: model, handover: handover)
            } else if let confirm = model.confirm {
                MailHelperConfirmOverlay(model: model, confirm: confirm)
            }
        }
        .onAppear {
            guard !headless else { return }
            model.session.refresh()
            if model.needsReply == .idle { model.loadNeedsReply() }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            if !headless { model.session.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mail helper").font(AppTheme.font(26, .heavy)).foregroundStyle(AppTheme.text)
                MailHelperStatusLine(text: model.session.statusLine.text, tone: model.session.statusLine.tone)
            }
            Spacer(minLength: 12)
            if model.installed {
                SegmentPicker(options: MailHelperModel.Page.allCases.map { ($0, $0.title) },
                              selection: Binding(get: { model.page }, set: { model.page = $0 }))
                    .padding(.top, 6)
                Button {
                    model.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(AccountsKit.IconButton())
                .help("Ask Yaya\u{2019}s Mail Helper for fresh numbers")
                .accessibilityLabel(Text("Refresh"))
                .padding(.top, 7)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.installed {
            InboxNote(symbol: "line.3.horizontal.decrease.circle", title: "Yaya\u{2019}s Mail Helper isn\u{2019}t on this Mac",
                      line: "This page belongs to the helper. When it\u{2019}s installed again, your dashboard and digest come back here.")
        } else if model.page == .digest {
            MailHelperDigestView(model: model)
        } else {
            ShellScroll {
                MailHelperOverview(model: model)
                    .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 70)
            }
        }
    }
}

/// A dot in the line's tone and the words.
struct MailHelperStatusLine: View {
    let text: String
    let tone: MailHelperText.Tone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            AccountsKit.Dot(color: MailHelperStyle.color(tone)).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(verbatim: text).font(AppTheme.font(12.5, .medium)).foregroundStyle(AppTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum MailHelperStyle {
    static func color(_ tone: MailHelperText.Tone) -> Color {
        switch tone {
        case .good: return AppTheme.good
        case .busy: return AppTheme.accent
        case .warn: return AppTheme.warn
        case .bad: return AppTheme.bad
        case .quiet: return AppTheme.text3
        }
    }

    static let gold = Color(hex: 0xF2C14E)
}

// MARK: - Overview

struct MailHelperOverview: View {
    @ObservedObject var model: MailHelperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let errors = model.state?.errors, !errors.isEmpty {
                problems(errors)
            }
            group("Your accounts", "Each mailbox has its own sorting, AI and clean-up.") {
                VStack(spacing: 14) {
                    ForEach(model.cards) { card in MailHelperAccountCard(model: model, card: card) }
                }
            }
            MailHelperReviewCard(model: model)
            MailHelperNeedsReplyCard(model: model)
            MailHelperSuggestionsCard(model: model)
            MailHelperActivityCard(model: model)
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    private func problems(_ errors: [String]) -> some View {
        ShellCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("What went wrong lately", systemImage: "exclamationmark.triangle.fill")
                    .font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.warn)
                ForEach(Array(errors.suffix(3).enumerated()), id: \.offset) { _, e in
                    Text(verbatim: e).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2).lineLimit(2)
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, _ line: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                Text(line).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
            }
            content()
        }
    }
}

/// A card's title row: title, a count, and whatever sits on the right.
private struct CardTitle<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var line: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title).font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                    if let count, count > 0 {
                        Text("\(count)").font(AppTheme.font(11, .bold)).monospacedDigit().foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(AppTheme.accentSoft))
                    }
                }
                if let line { Text(line).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2) }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// The account's badge, tag and address, as one small line.
private struct AccountLine: View {
    let account: DirectoryAccount?
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: 5) {
            MailLogoBadge(account: account, size: size)
            Text(verbatim: account?.tag ?? "?").font(AppTheme.font(11, .bold)).foregroundStyle(AppTheme.text2)
        }
    }
}

private struct Hairline: View {
    var inset: CGFloat = 0
    var body: some View { Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, inset) }
}

/// A small quiet button that shows a spinner-free "…" while its command is on its way.
private struct QuietButton: View {
    let title: String
    var busy = false
    var tint: Color = AppTheme.text
    let action: () -> Void

    var body: some View {
        Button(busy ? "\(title)\u{2026}" : title, action: action)
            .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: tint))
            .disabled(busy)
            .opacity(busy ? 0.6 : 1)
    }
}

/// A menu button (a real NSMenu at the pointer; headless renders draw only its label). `quiet`: text only.
private struct MenuLabelButton: View {
    let title: String
    var compact = true
    var quiet = false
    let items: () -> [AccountsKit.PopUpMenuButton.Item]

    var body: some View {
        if quiet {
            button.buttonStyle(AccountsKit.LinkButton(tint: AppTheme.text2))
        } else {
            button.buttonStyle(AccountsKit.SecondaryButton(compact: compact))
        }
    }

    private var button: some View {
        Button {
            AccountsKit.MenuPresenter.show(items())
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .heavy))
            }
        }
    }
}

// MARK: - Account card

private struct MailHelperAccountCard: View {
    @ObservedObject var model: MailHelperModel
    let card: MailHelperModel.Card

    private var id: UUID { card.id }

    var body: some View {
        ShellCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(16)
                if card.handedOver, let lab = card.lab {
                    Hairline()
                    today(lab).padding(.horizontal, 16).padding(.vertical, 12)
                    Hairline(inset: 16)
                    ai(lab).padding(.horizontal, 16).padding(.vertical, 12)
                    Hairline(inset: 16)
                    vips.padding(.horizontal, 16).padding(.vertical, 12)
                    Hairline(inset: 16)
                    MailHelperVoiceRow(model: model, account: id).padding(.horizontal, 16).padding(.vertical, 12)
                    if let backfill = card.backfill {
                        Hairline()
                        MailHelperBacklogPanel(model: model, backfill: backfill, tag: card.account.tag).padding(16)
                    } else if lab.state == "ready" {
                        Hairline(inset: 16)
                        HStack {
                            Text("Inbox clean-up").font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                            Spacer()
                            QuietButton(title: "Start a dry run", busy: model.isBusy("backfill-start:\(id)")) { model.backfillStart(id) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            MailLogoBadge(account: card.account, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(verbatim: card.account.tag).font(AppTheme.font(14, .heavy)).foregroundStyle(AppTheme.text)
                    Text(verbatim: card.account.email).font(AppTheme.font(12)).foregroundStyle(AppTheme.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
                MailHelperStatusLine(text: card.state.text, tone: card.state.tone)
            }
            Spacer(minLength: 10)
            if card.handedOver, let lab = card.lab {
                if lab.reviewWaiting > 0 {
                    Text("\(lab.reviewWaiting) to review").font(AppTheme.font(11.5, .bold)).foregroundStyle(MailHelperStyle.gold)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(MailHelperStyle.gold.opacity(0.14)))
                }
                if lab.state == "reauth" {
                    Button("Hand over again") { model.beginHandover(id) }.buttonStyle(AccountsKit.PrimaryButton(compact: true))
                } else {
                    HStack(spacing: 8) {
                        Text("Sorting").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2)
                        ShellSwitch(isOn: Binding(get: { !lab.paused }, set: { model.setPaused(!$0, id) }),
                                    enabled: !model.isBusy("pause:\(id)") && lab.state != "new", label: "Sorting")
                    }
                }
                AccountsKit.PopUpMenuButton(items: {
                    [AccountsKit.PopUpMenuButton.Item(title: "Take back the sign-in\u{2026}", destructive: true) { model.askForget(id) }]
                }, label: "More for \(card.account.tag)")
            } else {
                Button {
                    model.beginHandover(id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal.fill").font(.system(size: 11, weight: .bold))
                        Text(card.lab?.state == "reauth" ? "Hand over again" : "Hand over sign-in")
                    }
                }
                .buttonStyle(AccountsKit.PrimaryButton(compact: true))
                .disabled(model.state?.sealKey == nil)
                .opacity(model.state?.sealKey == nil ? 0.45 : 1)
                .help(model.state?.sealKey == nil ? "Pair the helper with your mail server first" : "Shows what is handed over before anything happens")
            }
        }
    }

    private func today(_ lab: MailHelperState.Account) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Today").font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2).frame(width: 74, alignment: .leading)
            // Priority first, then the busiest categories.
            let counts = lab.today.filter { $0.value > 0 }.sorted { a, b in
                if (a.key == "priority") != (b.key == "priority") { return a.key == "priority" }
                return a.value != b.value ? a.value > b.value : a.key < b.key
            }
            if counts.isEmpty {
                Text("Nothing sorted yet today.").font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text3)
            } else {
                MailHelperFlow(spacing: 6) {
                    ForEach(counts, id: \.key) { key, n in
                        let gold = key == "priority"
                        HStack(spacing: 4) {
                            if gold { Image(systemName: "star.fill").font(.system(size: 8.5, weight: .heavy)) }
                            Text(verbatim: MailHelperText.category(key)).foregroundStyle(gold ? MailHelperStyle.gold : AppTheme.text2)
                            Text("\(n)").monospacedDigit().foregroundStyle(gold ? MailHelperStyle.gold : AppTheme.text)
                        }
                        .foregroundStyle(MailHelperStyle.gold)
                        .font(AppTheme.font(11.5, .semibold))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(gold ? MailHelperStyle.gold.opacity(0.14) : Color.white.opacity(0.06)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func ai(_ lab: MailHelperState.Account) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("AI").font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2).frame(width: 74, alignment: .leading)
            SegmentPicker(options: MailAIPolicy.allCases.map { ($0, $0.title) },
                          selection: Binding(get: { lab.aiPolicy ?? .local }, set: { model.setPolicy($0, id) }))
            if lab.aiPolicy == .localClaude {
                MenuLabelButton(title: lab.claudeCredential.map { "Claude: \($0)" } ?? "Pick a Claude credential") {
                    var items = (model.state?.claudeCredentials ?? []).map { name in
                        AccountsKit.PopUpMenuButton.Item(title: name) { model.setCredential(name, id) }
                    }
                    if items.isEmpty { items.append(AccountsKit.PopUpMenuButton.Item(title: "No credentials on your mail server yet", enabled: false) {}) }
                    items.append(.separator)
                    items.append(AccountsKit.PopUpMenuButton.Item(title: "None") { model.setCredential(nil, id) })
                    return items
                }
                if lab.claudeCredential != nil, !lab.claudeReady {
                    Text("not ready").font(AppTheme.font(11.5, .semibold)).foregroundStyle(AppTheme.warn)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var vips: some View {
        if model.vipEditing == id {
            MailHelperVIPEditor(model: model)
        } else {
            let v = model.vips(id)
            HStack(spacing: 10) {
                Text("VIPs").font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2).frame(width: 74, alignment: .leading)
                Text(verbatim: Self.vipSummary(v.people.count, v.domains.count))
                    .font(AppTheme.font(12.5)).foregroundStyle(v.people.isEmpty && v.domains.isEmpty ? AppTheme.text3 : AppTheme.text)
                Spacer()
                QuietButton(title: "Edit", busy: model.isBusy("vip:\(id)") || model.isBusy("vip-domains:\(id)")) { model.editVIPs(id) }
            }
        }
    }

    static func vipSummary(_ people: Int, _ domains: Int) -> String {
        if people == 0 && domains == 0 { return "None yet. VIPs always stay in the inbox, on top." }
        let p = people == 1 ? "1 person" : "\(people) people"
        let d = domains == 1 ? "1 domain" : "\(domains) domains"
        return "\(p), \(d) always on top"
    }
}

/// Chips that wrap onto more lines.
struct MailHelperFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

private struct MailHelperVIPEditor: View {
    @ObservedObject var model: MailHelperModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VIPs always stay in the inbox, on top. One per line.").font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
            HStack(alignment: .top, spacing: 12) {
                field("People", "someone@company.example", $model.vipPeople)
                field("Whole domains", "company.example", $model.vipDomains)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelVIPs() }.buttonStyle(.plain)
                    .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                Button("Save") { model.saveVIPs() }.buttonStyle(AccountsKit.PrimaryButton(compact: true))
            }
        }
    }

    private func field(_ title: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            AccountsKit.SectionLabel(text: title)
            Group {
                if headless {
                    Text(verbatim: text.wrappedValue.isEmpty ? placeholder : text.wrappedValue)
                        .foregroundStyle(text.wrappedValue.isEmpty ? AppTheme.text3 : AppTheme.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: text).scrollContentBackground(.hidden).foregroundStyle(AppTheme.text)
                }
            }
            .font(AppTheme.font(12.5))
            .padding(8).frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppTheme.stroke))
        }
    }
}

// MARK: - Your voice

private struct MailHelperVoiceRow: View {
    @ObservedObject var model: MailHelperModel
    let account: UUID
    @Environment(\.headlessRender) private var headless

    private var key: String { "voice:\(account)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Your voice").font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2).frame(width: 74, alignment: .leading)
                Text(verbatim: summary).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text3).lineLimit(1)
                Spacer()
                Button(model.isExpanded(key) ? "Hide" : "Show") {
                    model.toggle(key)
                    if model.isExpanded(key), model.voice(account) == nil { model.loadVoice(account) }
                }
                .buttonStyle(AccountsKit.LinkButton())
            }
            if model.isExpanded(key) { detail }
        }
    }

    private var summary: String {
        guard let v = model.voice(account) else { return "The style card drafts are written in." }
        switch v.phase {
        case .loading: return "Loading\u{2026}"
        case .building: return "Building from your sent mail\u{2026}"
        case .saving: return "Saving\u{2026}"
        case .failed: return "Couldn\u{2019}t load it"
        case .ready:
            if v.card == nil { return "No style card yet." }
            return v.samples > 0 ? "Style card from \(v.samples) sent emails" : "Style card ready"
        }
    }

    @ViewBuilder
    private var detail: some View {
        let v = model.voice(account) ?? MailHelperVoice(useClaude: model.defaultUseClaude(account))
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let message) = v.phase {
                Text(verbatim: message).font(AppTheme.font(12)).foregroundStyle(AppTheme.warn)
            }
            if let draft = v.draft {
                Group {
                    if headless {
                        Text(verbatim: draft).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        TextEditor(text: Binding(get: { model.voice(account)?.draft ?? "" }, set: { model.setVoiceDraft($0, account) }))
                            .scrollContentBackground(.hidden)
                    }
                }
                .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text)
                .padding(10).frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppTheme.accent.opacity(0.45)))
                HStack {
                    Text("\(draft.count) of \(MailHelperCommand.voiceCardLimit) characters").font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                    Spacer()
                    Button("Cancel") { model.cancelVoiceEdit(account) }.buttonStyle(.plain)
                        .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                    Button(v.phase == .saving ? "Saving\u{2026}" : "Save") { model.saveVoice(account) }
                        .buttonStyle(AccountsKit.PrimaryButton(compact: true)).disabled(v.phase == .saving)
                }
            } else {
                Text(verbatim: v.card ?? "No style card yet. Build one from your sent mail: it reads how you write (greetings, length, tone, sign-off) and drafts follow it.")
                    .font(AppTheme.font(12.5)).foregroundStyle(v.card == nil ? AppTheme.text3 : AppTheme.text)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
                HStack(spacing: 10) {
                    QuietButton(title: "Edit") { model.editVoice(account) }.disabled(v.phase == .loading)
                    QuietButton(title: "Build from my sent mail", busy: v.phase == .building) { model.buildVoice(account) }
                    Toggle("Use Claude for this", isOn: Binding(get: { v.useClaude }, set: { model.setVoiceUsesClaude($0, account) }))
                        .toggleStyle(AccountsKit.Switch())
                    Spacer()
                    if !headless {
                        Button("Check again") { model.loadVoice(account) }.buttonStyle(AccountsKit.LinkButton())
                    }
                }
            }
        }
        .padding(.leading, 84)
    }
}

// MARK: - Backlog review

private struct MailHelperBacklogPanel: View {
    @ObservedObject var model: MailHelperModel
    let backfill: MailHelperState.Backfill
    let tag: String
    @Environment(\.headlessRender) private var headless

    private var groupsKey: String { "groups:\(backfill.run)" }
    static let folded = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inbox clean-up").font(AppTheme.font(14.5, .heavy)).foregroundStyle(AppTheme.text)
                    Text(verbatim: MailHelperText.backfillState(backfill)).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                buttons
            }
            if backfill.state == "applying" || backfill.state == "scanning" { progress }
            if !backfill.totals.isEmpty, backfill.state != "undone" { totals }
            if !backfill.groups.isEmpty, backfill.state != "undone" {
                VStack(spacing: 0) {
                    let shown = model.isExpanded(groupsKey) ? backfill.groups : Array(backfill.groups.prefix(Self.folded))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, g in
                        if index > 0 { Hairline(inset: 14) }
                        group(g)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.stroke))
                if backfill.groups.count > Self.folded {
                    Button(model.isExpanded(groupsKey) ? "Show fewer labels" : "Show all \(backfill.groups.count) labels") { model.toggle(groupsKey) }
                        .buttonStyle(AccountsKit.LinkButton())
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let run = backfill.run
        HStack(spacing: 8) {
            switch backfill.state {
            case "scanning":
                QuietButton(title: "Stop", busy: model.isBusy("stop:\(run)")) { model.backfillStop(run) }
            case "ready":
                Button(model.isBusy("apply:\(run)") ? "Apply\u{2026}" : "Apply") { model.backfillApply(run) }
                    .buttonStyle(AccountsKit.PrimaryButton(compact: true)).disabled(model.isBusy("apply:\(run)"))
            case "applying":
                QuietButton(title: "Stop", busy: model.isBusy("stop:\(run)")) { model.backfillStop(run) }
                QuietButton(title: "Apply the rest", busy: model.isBusy("apply:\(run)")) { model.backfillApply(run) }
                QuietButton(title: "Undo all", busy: model.isBusy("undo-all:\(run)"), tint: AppTheme.bad) { model.askUndoAll(run, tag: tag) }
            case "applied":
                QuietButton(title: "Undo all", busy: model.isBusy("undo-all:\(run)"), tint: AppTheme.bad) { model.askUndoAll(run, tag: tag) }
            default:
                EmptyView()
            }
        }
    }

    private var progress: some View {
        let total = max(1, backfill.totals["threads"] ?? max(backfill.scanned, 1))
        let done = backfill.state == "applying" ? backfill.applied : backfill.scanned
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(AppTheme.accent).frame(width: g.size.width * min(1, CGFloat(done) / CGFloat(total)))
            }
        }
        .frame(height: 6)
    }

    private var totals: some View {
        let t = backfill.totals
        return HStack(spacing: 14) {
            stat("Conversations", t["threads"] ?? 0)
            stat("Leave the inbox", t["leave"] ?? 0)
            stat("Stay", t["stay"] ?? 0)
            stat("Priority", t["priority"] ?? 0)
            stat("To review", t["review"] ?? 0)
        }
    }

    private func stat(_ title: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(n)").font(AppTheme.font(16, .heavy)).monospacedDigit().foregroundStyle(AppTheme.text)
            Text(title).font(AppTheme.font(11)).foregroundStyle(AppTheme.text3)
        }
    }

    private func group(_ g: MailHelperState.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "tag.fill").font(.system(size: 10.5, weight: .bold)).foregroundStyle(AppTheme.accent)
                Text(verbatim: MailHelperText.label(g.label, root: model.rootLabel)).font(AppTheme.font(13, .bold)).foregroundStyle(AppTheme.text)
                Text("\(g.count)").font(AppTheme.font(12, .bold)).monospacedDigit().foregroundStyle(AppTheme.text2)
                if g.staysInInbox > 0 {
                    Text(g.staysInInbox == g.count ? "all stay in the inbox" : "\(g.staysInInbox) stay in the inbox")
                        .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                }
                Spacer()
            }
            ForEach(g.senders, id: \.sender) { s in
                HStack(spacing: 8) {
                    Text(verbatim: s.sender).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2).lineLimit(1).truncationMode(.middle)
                    Text("\(s.count)").font(AppTheme.font(11.5, .semibold)).monospacedDigit().foregroundStyle(AppTheme.text3)
                    Spacer(minLength: 8)
                    MenuLabelButton(title: model.isBusy("move:\(backfill.run):\(s.sender)") ? "Moving\u{2026}" : "Move to", quiet: true) {
                        MailCategory.choices.filter { $0.rawValue != g.category }.map { c in
                            AccountsKit.PopUpMenuButton.Item(title: c.title) { model.move(run: backfill.run, sender: s.sender, to: c) }
                        }
                    }
                    .disabled(backfill.state != "ready" && backfill.state != "scanning")
                }
                .padding(.leading, 18)
            }
            if !g.samples.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(g.samples, id: \.threadId) { sample in
                        Button {
                            model.open(account: backfill.account, thread: sample.threadId)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "envelope").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(AppTheme.text3)
                                Text(verbatim: sample.subject.isEmpty ? "(no subject)" : sample.subject)
                                    .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Opens this email")
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(14)
    }
}

// MARK: - Review

private struct MailHelperReviewCard: View {
    @ObservedObject var model: MailHelperModel

    var body: some View {
        let rows = model.state?.review ?? []
        ShellCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Review", count: rows.count, line: "Emails I wasn\u{2019}t sure about. They stay in the inbox with a Review chip until you decide; their sender follows your choice.") {
                    EmptyView()
                }
                .padding(16)
                if rows.isEmpty {
                    Hairline()
                    Text("Nothing to review.").font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text3).padding(16)
                }
                ForEach(rows.prefix(12)) { r in
                    Hairline(inset: 16)
                    row(r)
                }
            }
        }
    }

    private func row(_ r: MailHelperState.ReviewThread) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                model.open(account: r.account, thread: r.threadId)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        AccountLine(account: model.account(r.account))
                        Text(verbatim: r.sender).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text).lineLimit(1)
                    }
                    Text(verbatim: r.subject.isEmpty ? "(no subject)" : r.subject).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2).lineLimit(1)
                    if !r.reasons.isEmpty {
                        Text(verbatim: r.reasons.joined(separator: " \u{00B7} ")).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Opens this email")
            HStack(spacing: 6) {
                ForEach(MailCategory.quick) { c in
                    QuietButton(title: c.title, busy: false) { model.review(r, as: c) }
                }
                MenuLabelButton(title: "More") {
                    var items = MailCategory.choices.filter { !MailCategory.quick.contains($0) }.map { c in
                        AccountsKit.PopUpMenuButton.Item(title: c.title) { model.review(r, as: c) }
                    }
                    items.append(.separator)
                    items.append(AccountsKit.PopUpMenuButton.Item(title: "Only this email", action: {}, children: MailCategory.choices.map { c in
                        AccountsKit.PopUpMenuButton.Item(title: c.title) { model.review(r, as: c, onlyThisThread: true) }
                    }))
                    return items
                }
            }
            .disabled(model.isBusy("review:\(r.id)"))
            .opacity(model.isBusy("review:\(r.id)") ? 0.5 : 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - Needs reply

private struct MailHelperNeedsReplyCard: View {
    @ObservedObject var model: MailHelperModel

    var body: some View {
        ShellCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Needs reply", count: rows.count, line: "Priority and people mail from the last two weeks where the last word isn\u{2019}t yours.") {
                    Button("Reload") { model.loadNeedsReply() }.buttonStyle(AccountsKit.LinkButton())
                        .disabled(model.needsReply == .loading)
                }
                .padding(16)
                switch model.needsReply {
                case .idle, .loading:
                    Hairline()
                    Text("Asking your mail server\u{2026}").font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text3).padding(16)
                case .failed(let message):
                    Hairline()
                    Text(verbatim: message).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.warn).padding(16)
                case .ready(let list):
                    if list.isEmpty {
                        Hairline()
                        Text("Nobody is waiting on you.").font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text3).padding(16)
                    }
                    ForEach(list.prefix(12)) { r in
                        Hairline(inset: 16)
                        row(r)
                    }
                }
            }
        }
    }

    private var rows: [MailHelperNeedsReply] { if case .ready(let l) = model.needsReply { return l } else { return [] } }

    private func row(_ r: MailHelperNeedsReply) -> some View {
        HStack(spacing: 12) {
            if r.priority {
                Image(systemName: "star.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(MailHelperStyle.gold).frame(width: 14)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Button {
                model.open(account: r.account, thread: r.threadId)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        AccountLine(account: model.account(r.account))
                        Text(verbatim: r.sender).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text).lineLimit(1)
                    }
                    Text(verbatim: r.subject.isEmpty ? "(no subject)" : r.subject).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(verbatim: MailHelperText.ago(r.decidedAt, now: model.now)).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
            Button {
                model.reply(r)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10, weight: .bold))
                    Text("Reply")
                }
            }
            .buttonStyle(AccountsKit.SecondaryButton(compact: true))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

// MARK: - Suggestions

private struct MailHelperSuggestionsCard: View {
    @ObservedObject var model: MailHelperModel

    var body: some View {
        let list = model.state?.proposals ?? []
        ShellCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Suggestions", count: list.count, line: "What I learned from your moves, and labels that grew. Nothing changes until you answer.") {
                    EmptyView()
                }
                .padding(16)
                if list.isEmpty {
                    Hairline()
                    Text("No suggestions right now.").font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text3).padding(16)
                }
                ForEach(list.prefix(12)) { p in
                    Hairline(inset: 16)
                    row(p)
                }
            }
        }
    }

    private func row(_ p: MailHelperState.Proposal) -> some View {
        let words = MailHelperText.proposal(p)
        let busy = model.isBusy("proposal:\(p.id)")
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: Self.symbol(p.kind)).font(.system(size: 13, weight: .semibold)).foregroundStyle(AppTheme.accent)
                .frame(width: 30, height: 30).background(Circle().fill(AppTheme.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    AccountLine(account: model.account(p.account))
                    Text(verbatim: words.title).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text).lineLimit(2)
                }
                if !words.detail.isEmpty {
                    Text(verbatim: words.detail).font(AppTheme.font(12)).foregroundStyle(AppTheme.text3).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(words.reject) { model.decide(p, accept: false) }.buttonStyle(.plain)
                .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
            Button(words.accept) { model.decide(p, accept: true) }.buttonStyle(AccountsKit.PrimaryButton(compact: true))
        }
        .disabled(busy).opacity(busy ? 0.5 : 1)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "rule_suggested", "rule_active": return "person.crop.circle.badge.checkmark"
        case "new_label": return "tag"
        case "merge": return "arrow.triangle.merge"
        default: return "lightbulb"
        }
    }
}

// MARK: - Activity

private struct MailHelperActivityCard: View {
    @ObservedObject var model: MailHelperModel
    static let folded = 8

    var body: some View {
        let all = model.state?.activity ?? []
        let shown = model.isExpanded("activity") ? Array(all.prefix(60)) : Array(all.prefix(Self.folded))
        ShellCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: "Activity", line: "What I did, newest first. Every change can be undone.") {
                    QuietButton(title: "Undo today", busy: model.isBusy("undo-today"), tint: AppTheme.bad) { model.askUndoToday() }
                        .disabled(all.isEmpty)
                }
                .padding(16)
                if all.isEmpty {
                    Hairline()
                    Text("Nothing sorted yet.").font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text3).padding(16)
                }
                ForEach(shown) { a in
                    Hairline(inset: 16)
                    row(a)
                }
                if all.count > Self.folded {
                    Hairline()
                    Button(model.isExpanded("activity") ? "Show less" : "Show more") { model.toggle("activity") }
                        .buttonStyle(AccountsKit.LinkButton()).padding(14)
                }
            }
        }
    }

    private func row(_ a: MailHelperState.Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: MailText.listTime(a.at, now: model.now)).font(AppTheme.font(11.5, .semibold)).monospacedDigit()
                .foregroundStyle(AppTheme.text3).frame(width: 52, alignment: .leading).padding(.top, 1)
            Button {
                model.open(account: a.account, thread: a.threadId)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        AccountLine(account: model.account(a.account))
                        Text(verbatim: a.subject ?? "(no subject)").font(AppTheme.font(12.5, .semibold))
                            .foregroundStyle(a.undone ? AppTheme.text3 : AppTheme.text).lineLimit(1)
                    }
                    Text(verbatim: [a.sender ?? "", MailHelperText.change(a, root: model.rootLabel)].filter { !$0.isEmpty }.joined(separator: " \u{2014} "))
                        .font(AppTheme.font(12)).foregroundStyle(AppTheme.text2).lineLimit(1)
                    if !a.reason.isEmpty {
                        Text(verbatim: "Why: " + a.reason).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if a.undone {
                Text("Undone").font(AppTheme.font(11.5, .semibold)).foregroundStyle(AppTheme.text3).padding(.top, 2)
            } else {
                QuietButton(title: "Undo", busy: model.isBusy("undo:\(a.id)")) { model.undo(a) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

// MARK: - Digest

struct MailHelperDigestView: View {
    @ObservedObject var model: MailHelperModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        if let digest = model.digest {
            if headless {
                pages(digest)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            } else {
                ScrollView(.vertical) {
                    pages(digest).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                    if offset > 12 { model.digestDidScroll() }
                }
            }
        } else {
            InboxNote(symbol: "newspaper", title: "No digest yet",
                      line: "Your mail server writes one every morning from the mail that left your inbox. You can ask for one now.",
                      button: ("Build one now", { model.buildDigest() }))
        }
    }

    private func pages(_ d: MailHelperDigest) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Self.title(d, now: model.now)).font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                    Text(verbatim: d.total == 1 ? "1 email left your inbox. Reading a section to its end marks it read."
                                                : "\(d.total) emails left your inbox. Reading a section to its end marks it read.")
                        .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                }
                Spacer()
            }
            ForEach(d.sections) { s in MailHelperDigestSection(model: model, section: s) }
            HStack {
                Spacer()
                MailHelperMarkControl(model: model, section: nil, title: "Mark all read")
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 70)
    }

    static func title(_ d: MailHelperDigest, now: Date) -> String {
        guard let date = MailHelperDigestView.dayFormat.date(from: d.day) else { return "Your digest" }
        let out = DateFormatter()
        out.calendar = WidgetCalendar.current
        out.timeZone = WidgetCalendar.current.timeZone
        out.locale = Locale(identifier: "en_GB")
        out.dateFormat = "EEEE d MMMM"
        let day = out.string(from: date)
        return WidgetCalendar.current.isDate(date, inSameDayAs: now) ? "Today\u{2019}s digest \u{00B7} \(day)" : "Digest \u{00B7} \(day)"
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = WidgetCalendar.current
        f.timeZone = WidgetCalendar.current.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private struct MailHelperDigestSection: View {
    @ObservedObject var model: MailHelperModel
    let section: MailHelperDigest.Section
    @Environment(\.headlessRender) private var headless

    var body: some View {
        ShellCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: section.title).font(AppTheme.font(16, .heavy)).foregroundStyle(AppTheme.text)
                    Text("\(section.count)").font(AppTheme.font(12, .bold)).monospacedDigit().foregroundStyle(AppTheme.text3)
                    Spacer()
                    MailHelperMarkControl(model: model, section: section.key, title: "Mark section read")
                }
                .padding(16)
                ForEach(section.items) { item in
                    Hairline(inset: 16)
                    MailHelperDigestItem(model: model, item: item)
                }
                // The section's end: on screen after the page moved = read (D-050).
                Group {
                    if headless {
                        Color.clear.frame(height: 1)
                    } else {
                        Color.clear.frame(height: 1)
                            .onScrollVisibilityChange(threshold: 0.9) { model.sectionEnd(section.key, visible: $0) }
                    }
                }
            }
        }
        .opacity(model.mark(section.key) == .marked ? 0.72 : 1)
    }
}

/// "Mark section read", "Marking read…", "Marked read · Undo", "Unread again".
private struct MailHelperMarkControl: View {
    @ObservedObject var model: MailHelperModel
    let section: String?
    let title: String

    var body: some View {
        let key = section ?? "all"
        switch section == nil ? model.marks["all"] : model.mark(key) {
        case nil:
            QuietButton(title: title) { model.markRead(section) }
        case .sending?:
            Text("Marking read\u{2026}").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3)
        case .marked?:
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .heavy)).foregroundStyle(AppTheme.good)
                Text("Marked read").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2)
                Text("\u{00B7}").foregroundStyle(AppTheme.text3)
                Button("Undo") { model.undoRead(section) }.buttonStyle(AccountsKit.LinkButton())
            }
        case .undoing?:
            Text("Undoing\u{2026}").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3)
        case .undone?:
            Text("Unread again").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3)
        case .failed(let message)?:
            HStack(spacing: 6) {
                Text(verbatim: message).font(AppTheme.font(12)).foregroundStyle(AppTheme.warn).lineLimit(1)
                Button("Try again") { model.markRead(section) }.buttonStyle(AccountsKit.LinkButton())
            }
        }
    }
}

private struct MailHelperDigestItem: View {
    @ObservedObject var model: MailHelperModel
    let item: MailHelperDigest.Item

    var body: some View {
        Button {
            if let first = item.threads.first { model.open(first) }
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Opens this email in the reader")
    }

    @ViewBuilder
    private var content: some View {
        if let service = item.service {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    AccountLine(account: model.account(item.account))
                    Text(verbatim: service).font(AppTheme.font(13, .bold)).foregroundStyle(AppTheme.text)
                    Text("\(item.threads.count)").font(AppTheme.font(11.5, .bold)).monospacedDigit().foregroundStyle(AppTheme.text3)
                }
                ForEach(Array(item.subjects.prefix(4).enumerated()), id: \.offset) { _, subject in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\u{2022}").foregroundStyle(AppTheme.accent)
                        Text(verbatim: subject).foregroundStyle(AppTheme.text2).lineLimit(1)
                    }
                    .font(AppTheme.font(12.5))
                }
                if item.subjects.count > 4 {
                    Text("and \(item.subjects.count - 4) more").font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                }
            }
        } else if item.isSummary {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    AccountLine(account: model.account(item.account))
                    Text(verbatim: item.sender).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3).lineLimit(1)
                    if let topic = item.topic {
                        Text(verbatim: topic).font(AppTheme.font(10.5, .bold)).foregroundStyle(AppTheme.text2)
                            .padding(.horizontal, 6).frame(height: 17).background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    Spacer(minLength: 6)
                    if item.worthOpening {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.system(size: 9, weight: .bold))
                            Text("Worth opening")
                        }
                        .font(AppTheme.font(10.5, .bold)).foregroundStyle(MailHelperStyle.gold)
                        .padding(.horizontal, 7).frame(height: 19).background(Capsule().fill(MailHelperStyle.gold.opacity(0.14)))
                    }
                }
                Text(verbatim: item.headline ?? item.subject).font(AppTheme.font(13.5, .bold)).foregroundStyle(AppTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(item.bullets.enumerated()), id: \.offset) { _, b in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\u{2022}").foregroundStyle(AppTheme.accent)
                        Text(verbatim: b).foregroundStyle(AppTheme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(AppTheme.font(12.5))
                }
            }
        } else {
            HStack(spacing: 8) {
                AccountLine(account: model.account(item.account))
                Text(verbatim: item.subject.isEmpty ? "(no subject)" : item.subject).font(AppTheme.font(12.5, .semibold))
                    .foregroundStyle(AppTheme.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: item.sender).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

// MARK: - Inbox chip

/// ⭐ Priority and Review on an inbox row (D-050).
struct MailHelperChipView: View {
    let chip: MailHelperChip

    var body: some View {
        Group {
            switch chip {
            case .priority:
                Image(systemName: "star.fill").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(MailHelperStyle.gold)
                    .frame(width: 22, height: 16)
                    .background(Capsule().fill(MailHelperStyle.gold.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(MailHelperStyle.gold.opacity(0.35), lineWidth: 0.7))
                    .help("Priority")
            case .review:
                Text("Review").font(AppTheme.font(10, .bold)).foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(AppTheme.accentSoft))
            }
        }
        .accessibilityHidden(true)
    }
}
