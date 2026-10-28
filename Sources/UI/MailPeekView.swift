import SwiftUI

/// The Mail Peek (a widget row → `open/message`): who and what, earlier messages folded, the latest on
/// the paper card, and Reply · Archive · Star · Trash · Mark unread. Its height is fixed by the thread
/// (not by the loaded body), so the panel is measured once and never jumps.
struct MailPeekView: View {
    @ObservedObject var model: MailPeekModel
    /// The panel measures a copy of this view: no web view, same height.
    var measuring = false
    @Local private var hovered: URL?

    static let bodyHeight: CGFloat = 220
    static let maxOlder = 2

    var body: some View {
        let thread = model.thread
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                PeekAccountChip(account: model.account)
                Text(thread.sender).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2).lineLimit(1)
                Spacer(minLength: 8)
                PeekCloseButton(action: model.onClose)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(thread.subject)
                    .font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if thread.starred {
                    Image(systemName: "star.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(AppTheme.warn)
                }
            }
            older(thread)
            card
            if model.gone == nil { actions } else { PeekGoneLine(gone: model.gone, center: model.toasts) }
        }
        .overlay(alignment: .bottom) {
            // After Archive/Trash the Undo lives in the line itself; errors still float.
            if model.gone == nil { MailToastView(center: model.toasts).padding(.bottom, -6) }
        }
        .environment(\.mailToasts, model.toasts)
    }

    /// Earlier messages, folded to one line each (at most two, then "and N more").
    @ViewBuilder
    private func older(_ thread: MailThread) -> some View {
        let count = max(0, thread.messageCount - 1)
        if count > 0 {
            VStack(alignment: .leading, spacing: 4) {
                let shown = model.reader.phase == .ready ? Array(model.reader.older.suffix(Self.maxOlder)) : []
                ForEach(0..<min(count, Self.maxOlder), id: \.self) { i in
                    let m = i < shown.count ? shown[i] : nil
                    HStack(spacing: 8) {
                        Text(m?.from ?? " ").font(AppTheme.font(11.5, .bold)).foregroundStyle(AppTheme.text2).lineLimit(1)
                        Text(m.map { CollapsedMessageRow.firstLine($0.text) } ?? "").font(AppTheme.font(11.5))
                            .foregroundStyle(AppTheme.text3).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
                }
                if count > Self.maxOlder {
                    Text("and \(count - Self.maxOlder) earlier").font(AppTheme.font(11, .medium)).foregroundStyle(AppTheme.text3)
                        .padding(.leading, 10)
                }
            }
        }
    }

    /// The latest message on paper: who, when, the images bar, the body (scrolls inside; the same web view as
    /// the reader: cid images, the quote pill, fit-to-width, the hovered link), attachments.
    private var card: some View {
        let latest = model.reader.latest
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(latest?.from ?? model.thread.sender).font(AppTheme.font(13, .bold)).foregroundStyle(PaperTheme.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(latest.map { MailText.longDate($0.date) } ?? MailText.longDate(model.thread.at))
                    .font(AppTheme.font(11)).foregroundStyle(PaperTheme.text3).lineLimit(1)
            }
            if let latest, model.reader.phase == .ready {
                let decision = model.reader.decision(for: latest)
                if decision.showImagesBar {
                    RemoteImagesBar(compact: true, onLoad: { model.reader.loadImages(latest) },
                                    onAlways: { model.reader.alwaysAllow(latest) })
                }
                if measuring {
                    Color.clear.frame(height: bodyHeight(decision, latest))
                } else {
                    MessageBody(message: latest, decision: decision, threadR: model.thread.r, fixedHeight: bodyHeight(decision, latest),
                                onCompose: { address in
                                    model.onReply(.new(from: model.thread.accountId, to: [address]))
                                    model.onClose()
                                }, onHover: { hovered = $0 })
                }
                if latest.attachments.contains(where: { !$0.isInline }) {
                    MessageAttachments(message: latest, threadR: model.thread.r, compact: true)
                }
            } else {
                Text(model.reader.phase == .failed ? "I couldn\u{2019}t open this one just now." : model.thread.snippet)
                    .font(AppTheme.font(13)).foregroundStyle(PaperTheme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .frame(height: Self.cardHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PaperTheme.surface))
        .overlay(alignment: .bottomLeading) {
            if let url = hovered { HoverURLCapsule(url: url).padding(.leading, 10).padding(.bottom, 6) }
        }
        .environment(\.colorScheme, .light)
    }

    static let cardHeight: CGFloat = 300

    /// The body takes what the bar and the attachment line leave.
    private func bodyHeight(_ decision: MailContentPolicy.Decision, _ m: MailMessage) -> CGFloat {
        var h = Self.cardHeight - 28 - 18 - 10
        if decision.showImagesBar { h -= RemoteImagesBar.compactHeight + 10 }
        if m.attachments.contains(where: { !$0.isInline }) { h -= AttachmentStrip.compactHeight + 10 }
        return max(80, h)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ToolbarCapsule(title: "Reply", symbol: "arrowshape.turn.up.left", help: "Reply in a new window", prominent: true) {
                model.reply()
            }
            ToolbarIcon(symbol: "arrowshape.turn.up.right", help: "Forward in a new window") { model.forward() }
            Spacer(minLength: 6)
            ToolbarIcon(symbol: "archivebox", help: "Archive") { Task { await model.archive() } }
            ToolbarIcon(symbol: model.thread.starred ? "star.fill" : "star", help: model.thread.starred ? "Unstar" : "Star",
                        tint: model.thread.starred ? AppTheme.warn : nil) { Task { await model.toggleStar() } }
            ToolbarIcon(symbol: "trash", help: "Move to Trash") { Task { await model.trash() } }
            ToolbarIcon(symbol: "envelope.badge", help: "Mark unread") { Task { await model.markUnread() } }
        }
        .frame(height: 30)
    }

}

/// After Archive/Trash, in place of the buttons: "Archived · Undo" while the 30 s last, then a quiet
/// "Out of your inbox." Same height as the buttons, so the Peek doesn't move.
private struct PeekGoneLine: View {
    let gone: MailUndoBook.Kind?
    @ObservedObject var center: MailToastCenter

    var body: some View {
        let live = center.toast.map { !$0.isError && $0.action != nil } ?? false
        HStack(spacing: 8) {
            Image(systemName: gone == .archive ? "archivebox.fill" : "trash.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.accent)
            if live, let toast = center.toast {
                Text(toast.text).font(AppTheme.font(13, .bold)).foregroundStyle(AppTheme.text)
                Text("·").font(AppTheme.font(13, .bold)).foregroundStyle(AppTheme.text3)
                Button {
                    Task { await center.performUndo() }
                } label: {
                    Text("Undo").font(AppTheme.font(13, .heavy)).foregroundStyle(AppTheme.accent).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("z", modifiers: .command)
            } else {
                Text(gone == .archive ? "Out of your inbox." : "In the Trash.")
                    .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(live ? Color.white.opacity(0.06) : Color.clear))
    }
}
