import AppKit
import SwiftUI

/// Inbox: mailboxes live in the app sidebar under Inbox (InboxMailboxList); here, the
/// 360 pt thread list and the paper-card reader. Gmail's keys (J/K, E, U, S, #, R, Return) work while
/// the main window is key and no text field has focus. Every action leaves an undo toast.
struct InboxSectionView: View {
    @ObservedObject var model: InboxSectionModel
    @Environment(\.headlessRender) private var headless
    @Local private var keys = InboxKeyMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 14)
            Rectangle().fill(AppTheme.stroke).frame(height: 1)
            content
        }
        .overlay(alignment: .bottom) {
            MailToastView(center: model.toasts)
                .padding(.bottom, 18)
                .animation(.easeOut(duration: 0.18), value: model.toasts.toast?.id)
        }
        .environment(\.mailToasts, model.toasts)
        .onAppear {
            guard !headless else { return }
            model.load()
            keys.install { command in Task { await model.perform(command) } }
        }
        .onDisappear { keys.remove() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !headless { model.load() }
        }
        .onReceive(AccountsModel.shared.$accounts.dropFirst()) { _ in
            if !headless { DispatchQueue.main.async { model.load() } }
        }
        // Yaya's Mail Helper's labels changed (D-050): Priority first again.
        .onReceive(NotificationCenter.default.publisher(for: MailHelperInbox.changed)) { _ in
            if !headless { model.load() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            PageTitle(title: model.title, subtitle: model.phase == .ready ? model.subtitle : "Every inbox on one page.")
            Spacer(minLength: 16)
            Button {
                model.newMessage()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .bold))
                    Text("New message")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.phase == .noAccounts)
            .opacity(model.phase == .noAccounts ? 0.45 : 1)
            .keyboardShortcut("n", modifiers: .command)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            InboxNote(symbol: "hourglass", title: "Fetching your mail\u{2026}", line: "The first sync takes a moment.")
        case .noAccounts:
            InboxNote(symbol: "person.crop.circle.badge.plus", title: "No inboxes connected yet",
                      line: "Connect a Google account and your mail lands here, and on your widgets.",
                      button: ("Connect an account", { MainWindowController.openAccounts() }))
        case .failed:
            InboxNote(symbol: "exclamationmark.triangle", title: "I couldn\u{2019}t read your mail just now",
                      line: "Check your connection. If it keeps happening, the Accounts page says which account needs you.")
        case .ready:
            if model.threads.isEmpty {
                InboxNote(symbol: "checkmark.seal", title: model.emptyNote.title, line: model.emptyNote.line)
            } else {
                HStack(spacing: 0) {
                    ThreadList(model: model)
                        .frame(width: 360)
                    Rectangle().fill(AppTheme.stroke).frame(width: 1)
                    ReaderPane(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Sidebar mailboxes

/// Under "Inbox" in the app sidebar: Unified Inbox, one per account (logo, tag, unread), Starred.
struct InboxMailboxList: View {
    @ObservedObject var model: InboxSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            MailboxRow(title: "Unified Inbox", symbol: "tray.2", account: nil, count: model.unread[.unified],
                       selected: model.mailbox == .unified) { model.select(mailbox: .unified) }
            ForEach(model.accounts) { account in
                MailboxRow(title: account.tag, symbol: nil, account: account, count: model.unread[.account(account.id)],
                           selected: model.mailbox == .account(account.id)) { model.select(mailbox: .account(account.id)) }
            }
            MailboxRow(title: "Starred", symbol: "star", account: nil, count: model.starredCount > 0 ? model.starredCount : nil,
                       selected: model.mailbox == .starred, quietCount: true) { model.select(mailbox: .starred) }
        }
        .padding(.leading, 8)
        .padding(.bottom, 6)
    }
}

private struct MailboxRow: View {
    let title: String
    let symbol: String?
    let account: DirectoryAccount?
    let count: Int?
    let selected: Bool
    var quietCount = false
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? AppTheme.accent : AppTheme.text3)
                    } else {
                        MailLogoBadge(account: account, size: 15)
                    }
                }
                .frame(width: 16)
                Text(title).font(AppTheme.font(12.5, selected ? .bold : .medium))
                    .foregroundStyle(selected ? AppTheme.text : AppTheme.text2).lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)").font(AppTheme.font(10.5, .bold)).monospacedDigit()
                        .foregroundStyle(quietCount ? AppTheme.text3 : (selected ? AppTheme.accentText : AppTheme.accent))
                        .padding(.horizontal, 6).frame(height: 17)
                        .background(Capsule().fill(quietCount ? Color.clear : (selected ? AppTheme.accent : AppTheme.accentSoft)))
                }
            }
            .padding(.leading, 9).padding(.trailing, 7).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.white.opacity(0.09) : (hover ? Color.white.opacity(0.05) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// An account's logo on a small paper plate (dark marks stay visible), or its colour dot.
struct MailLogoBadge: View {
    let account: DirectoryAccount?
    var size: CGFloat = 22

    var body: some View {
        if let logo = account?.logo {
            Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .background(AppTheme.paper)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        } else {
            Circle().fill(Color(hex: account?.color ?? 0x8FB4C4)).frame(width: size * 0.5, height: size * 0.5)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }
}

// MARK: - Thread list

private struct ThreadList: View {
    @ObservedObject var model: InboxSectionModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        let directory = model.directoryNow
        if headless {
            rows(directory, lazy: false)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    rows(directory, lazy: true).padding(.horizontal, 10).padding(.vertical, 8)
                }
                .onChange(of: model.selection) { _, r in
                    guard let r else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(r) }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ directory: AccountDirectory, lazy: Bool) -> some View {
        // ImageRenderer draws nothing inside a lazy stack; the app wants one for 150 rows.
        if lazy {
            LazyVStack(alignment: .leading, spacing: 2) { items(directory) }
        } else {
            VStack(alignment: .leading, spacing: 2) { items(directory) }
        }
    }

    private func items(_ directory: AccountDirectory) -> some View {
        ForEach(model.threads) { thread in
            ThreadRow(thread: thread, account: directory.account(thread.accountId), now: model.now,
                      selected: model.selection == thread.r, chips: model.chips(thread)) {
                Task { await model.select(r: thread.r) }
            }
            .id(thread.r)
        }
    }
}

/// One conversation in a list (the Inbox section, the menu-bar popover). Click = open it.
struct ThreadRow: View {
    let thread: MailThread
    let account: DirectoryAccount?
    let now: Date
    let selected: Bool
    /// Yaya's Mail Helper's chips (D-050): the Inbox section passes them; the popover never does.
    var chips: [MailHelperChip] = []
    var hint = "Opens the conversation"
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(thread.unread ? AppTheme.accent : Color.clear).frame(width: 7, height: 7)
                .padding(.top, 13)
            MailLogoBadge(account: account, size: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(thread.sender)
                        .font(AppTheme.font(13.5, thread.unread ? .heavy : .medium))
                        .foregroundStyle(thread.unread ? AppTheme.text : AppTheme.text2)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)").font(AppTheme.font(10.5, .bold)).foregroundStyle(AppTheme.text3)
                    }
                    Spacer(minLength: 6)
                    Text(MailText.listTime(thread.at, now: now))
                        .font(AppTheme.font(11.5, thread.unread ? .semibold : .regular))
                        .foregroundStyle(thread.unread ? AppTheme.accent : AppTheme.text3)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(thread.subject)
                        .font(AppTheme.font(12.5, thread.unread ? .semibold : .regular))
                        .foregroundStyle(AppTheme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(chips, id: \.rawValue) { MailHelperChipView(chip: $0) }
                    if thread.starred {
                        Image(systemName: "star.fill").font(.system(size: 10.5, weight: .bold)).foregroundStyle(AppTheme.warn)
                    }
                }
                Text(thread.snippet).font(AppTheme.font(12)).foregroundStyle(AppTheme.text3).lineLimit(1)
            }
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : (hover ? Color.white.opacity(0.05) : Color.clear))
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(AppTheme.accent).frame(width: 3).padding(.vertical, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .ycAccessibleButton(A11yText.thread(thread, account: account, now: now).label,
                            value: A11yText.thread(thread, account: account, now: now).value
                                + (chips.isEmpty ? "" : ", " + chips.map(\.title).joined(separator: ", ")),
                            hint: hint, selected: selected, action: action)
    }
}

// MARK: - Reader

private struct ReaderPane: View {
    @ObservedObject var model: InboxSectionModel

    var body: some View {
        if let reader = model.reader, let thread = model.selectedThread {
            ThreadReaderView(reader: reader, thread: thread, directory: model.directoryNow, model: model)
        } else {
            InboxNote(symbol: "envelope.open", title: "Pick a conversation",
                      line: "J and K move through the list, Return opens, E archives. Every action can be undone.")
        }
    }
}

private struct ThreadReaderView: View {
    @ObservedObject var reader: ThreadReaderModel
    let thread: MailThread
    let directory: AccountDirectory
    @ObservedObject var model: InboxSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(thread.subject)
                    .font(AppTheme.font(19, .heavy)).foregroundStyle(AppTheme.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                ReaderToolbar(thread: thread, model: model)
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
            ShellScroll {
                messages.padding(.horizontal, 22).padding(.bottom, 70)
            }
            .overlay(alignment: .bottomLeading) {
                // The hovered link's real destination, at the pane's visible bottom-left (anti-phishing).
                if let url = reader.hoveredLink { HoverURLCapsule(url: url).padding(.leading, 22).padding(.bottom, 14) }
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        switch reader.phase {
        case .loading:
            Text("Opening\u{2026}").font(AppTheme.font(13)).foregroundStyle(AppTheme.text3).padding(.top, 20)
        case .failed:
            Text("I couldn\u{2019}t open that conversation just now. Try again in a moment.")
                .font(AppTheme.font(13)).foregroundStyle(AppTheme.text2).padding(.top, 20)
        case .ready:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(reader.messages) { m in
                    if reader.isExpanded(m) {
                        PaperMessageCard(message: m, reader: reader, account: directory.account(thread.accountId),
                                         own: Set(directory.accounts.map { $0.email.lowercased() }),
                                         collapsible: m.id != reader.latest?.id) { address in
                            model.compose(.new(from: thread.accountId, to: [address]))
                        }
                    } else {
                        CollapsedMessageRow(message: m) { reader.toggle(m) }
                    }
                }
                if let problem = reader.problem {
                    Text(problem).font(AppTheme.font(12)).foregroundStyle(AppTheme.warn)
                }
            }
        }
    }
}

private struct ReaderToolbar: View {
    let thread: MailThread
    @ObservedObject var model: InboxSectionModel

    var body: some View {
        HStack(spacing: 8) {
            ToolbarCapsule(title: "Reply", symbol: "arrowshape.turn.up.left", help: "Reply (R)") { model.reply(all: false) }
            ToolbarCapsule(title: "Reply all", symbol: "arrowshape.turn.up.left.2", help: "Reply all") { model.reply(all: true) }
            ToolbarCapsule(title: "Forward", symbol: "arrowshape.turn.up.right", help: "Forward (F)") { model.forward() }
            Spacer(minLength: 8)
            ToolbarIcon(symbol: "archivebox", help: "Archive (E)") { Task { await model.archive(thread.r) } }
            ToolbarIcon(symbol: thread.starred ? "star.fill" : "star", help: thread.starred ? "Unstar (S)" : "Star (S)",
                        tint: thread.starred ? AppTheme.warn : nil) {
                Task { await model.setStarred(thread.r, !thread.starred) }
            }
            ToolbarIcon(symbol: "trash", help: "Move to Trash (#)") { Task { await model.trash(thread.r) } }
            ToolbarIcon(symbol: thread.unread ? "envelope.open" : "envelope.badge", help: thread.unread ? "Mark read (U)" : "Mark unread (U)") {
                Task { await model.setUnread(thread.r, !thread.unread, toast: true) }
            }
        }
    }
}

struct ToolbarCapsule: View {
    let title: String
    let symbol: String
    var help = ""
    var prominent = false
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .bold))
                Text(title).font(AppTheme.font(12.5, .bold))
            }
            .foregroundStyle(prominent ? AppTheme.accentText : AppTheme.text)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(prominent ? AppTheme.accent : Color.white.opacity(hover ? 0.12 : 0.07)))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : AppTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(A11yText.plainHelp(help)))
    }
}

struct ToolbarIcon: View {
    let symbol: String
    var help = ""
    var tint: Color? = nil
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint ?? (hover ? AppTheme.text : AppTheme.text2))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(Text(help.isEmpty ? symbol : A11yText.plainHelp(help)))
    }
}

/// One open message on the paper card: who, to whom (collapsed), when, the images bar, the body on its
/// white sheet, attachments (files only: inline images draw in the body). A hovered link goes to the reader
/// model, which shows its real destination at the reader pane's bottom-left.
struct PaperMessageCard: View {
    let message: MailMessage
    @ObservedObject var reader: ThreadReaderModel
    let account: DirectoryAccount?
    let own: Set<String>
    var collapsible = false
    var onCompose: (String) -> Void = { _ in }
    @Local private var showRecipients = false

    var body: some View {
        let decision = reader.decision(for: message)
        let files = message.attachments.filter { !$0.isInline }
        VStack(alignment: .leading, spacing: 12) {
            header
            if decision.showImagesBar {
                RemoteImagesBar(onLoad: { reader.loadImages(message) }, onAlways: { reader.alwaysAllow(message) })
            }
            MessageBody(message: message, decision: decision, threadR: reader.thread.r, onCompose: onCompose) { reader.hoveredLink = $0 }
            if !files.isEmpty {
                Rectangle().fill(PaperTheme.rule).frame(height: 1)
                MessageAttachments(message: message, threadR: reader.thread.r)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PaperTheme.surface))
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.from).font(AppTheme.font(14, .bold)).foregroundStyle(PaperTheme.text).lineLimit(1)
                    Text(message.fromEmail).font(AppTheme.font(11.5)).foregroundStyle(PaperTheme.text3).lineLimit(1)
                }
                Button { showRecipients.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(MailText.recipients(to: message.to, cc: message.cc, own: own))
                            .font(AppTheme.font(11.5, .medium)).foregroundStyle(PaperTheme.text2).lineLimit(1)
                        Image(systemName: showRecipients ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(PaperTheme.text3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showRecipients {
                    VStack(alignment: .leading, spacing: 2) {
                        if !message.to.isEmpty { recipientLine("To", message.to) }
                        if !message.cc.isEmpty { recipientLine("Cc", message.cc) }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(MailText.longDate(message.date)).font(AppTheme.font(11.5)).foregroundStyle(PaperTheme.text3)
                PaperAccountChip(account: account, size: 15)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if collapsible { reader.toggle(message) } }
    }

    private func recipientLine(_ label: String, _ list: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(AppTheme.font(11, .bold)).foregroundStyle(PaperTheme.text3).frame(width: 22, alignment: .leading)
            Text(list.joined(separator: ", ")).font(AppTheme.font(11.5)).foregroundStyle(PaperTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An older message, folded: who, the first line, when. Click to open.
struct CollapsedMessageRow: View {
    let message: MailMessage
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(message.from).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text).lineLimit(1)
            Text(Self.firstLine(message.text)).font(AppTheme.font(12)).foregroundStyle(AppTheme.text3).lineLimit(1)
            Spacer(minLength: 8)
            Text(MailText.listTime(message.date, now: Date())).font(AppTheme.font(11)).foregroundStyle(AppTheme.text3)
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hover ? 0.09 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }

    static func firstLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasSuffix(",") } ?? ""
    }
}

/// Empty / loading / no accounts / error states, in the app's voice.
struct InboxNote: View {
    let symbol: String
    let title: String
    let line: String
    var button: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(AppTheme.accent)
                .frame(width: 64, height: 64).background(Circle().fill(AppTheme.accentSoft))
            Text(title).font(AppTheme.font(18, .heavy)).foregroundStyle(AppTheme.text)
                .multilineTextAlignment(.center)
            Text(line).font(AppTheme.font(13)).foregroundStyle(AppTheme.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if let button {
                Button(button.0, action: button.1).buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Keys

/// Gmail's keys for the Inbox, only while the main window is key and nothing is being typed.
final class InboxKeyMonitor {
    private var monitor: Any?

    func install(_ handle: @escaping (InboxCommand) -> Void) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.identifier?.rawValue == MainWindowController.windowIdentifier,
                  !(event.window?.firstResponder is NSTextView),
                  let command = InboxCommand.from(characters: event.characters, keyCode: event.keyCode,
                                                  commandKeys: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty)
            else { return event }
            handle(command)
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { remove() }
}
