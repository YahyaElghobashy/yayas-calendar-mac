import AppKit
import SwiftUI

// The composer's tray (rich mail, D-043/D-044): under the sheet, on the dark chrome. One chip per
// file (Finder's icon with the real extension, the name middle-truncated, "PDF document · 2.4 MB", a ring while a
// forwarded original downloads, × to remove with Undo), then one quiet line: the count and the size the message comes
// to, the 10 MB warning, or the 25 MB problem in the warning colour. Image chips offer "Place in Message".

struct AttachmentTray: View {
    @ObservedObject var model: ComposerModel
    var editable = true
    @Environment(\.undoManager) private var undoManager
    @Environment(\.headlessRender) private var headless

    var body: some View {
        if !model.attachments.isEmpty || model.sizeProblem != nil || model.sizeWarning != nil {
            VStack(alignment: .leading, spacing: 8) {
                if !model.attachments.isEmpty {
                    ChipGrid(spacing: 8, minWidth: 190, maxWidth: 250) {
                        ForEach(model.attachments) { a in
                            TrayChip(attachment: a, editable: editable, remove: { remove(a) },
                                     place: a.isImage && model.format == .rich ? { model.placeInMessage(a.id) } : nil)
                        }
                    }
                }
                summary
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Attachments"))
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: model.sizeProblem != nil ? "exclamationmark.circle.fill" : "paperclip")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(model.sizeProblem != nil ? AppTheme.warn : AppTheme.text3)
            if let problem = model.sizeProblem {
                Text(problem).foregroundStyle(AppTheme.warn).font(AppTheme.font(12, .semibold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(line).foregroundStyle(AppTheme.text3).font(AppTheme.font(12))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// "3 attachments · 14.7 MB", then the warning, then what is still downloading (or still copying into staging).
    private var line: String {
        let files = model.attachments.count
        var parts = [files == 0 ? "This message comes to \(MailSize.megabytes(model.estimatedSize))"
                                : ComposerSize.total(count: files, estimate: model.estimatedSize)]
        if let warning = model.sizeWarning { parts.append(warning) }
        let loading = model.attachments.filter(\.isLoading)
        if !loading.isEmpty { parts.append("\(loading.count) still " + (loading.allSatisfy(\.isCopying) ? "copying" : "downloading")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func remove(_ a: ComposerAttachment) {
        guard let index = model.attachments.firstIndex(where: { $0.id == a.id }) else { return }
        model.removeAttachment(a.id)
        undoManager?.registerUndo(withTarget: model) { $0.restoreAttachment(a, at: index) }
        undoManager?.setActionName("Remove Attachment")
    }
}

/// One file in the tray.
private struct TrayChip: View {
    let attachment: ComposerAttachment
    var editable = true
    let remove: () -> Void
    var place: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            AttachmentIconView(name: attachment.filename, mimeType: attachment.mimeType, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text)
                    .lineLimit(1).truncationMode(.middle)
                if let failure = attachment.failure {
                    Text(failure).font(AppTheme.font(10.5)).foregroundStyle(AppTheme.warn).lineLimit(1).truncationMode(.tail)
                } else {
                    // "PDF document · 2.4 MB": the kind gives way first, the size always shows.
                    HStack(spacing: 0) {
                        Text(attachment.isLoading ? (attachment.isCopying ? "Copying\u{2026}" : "Downloading\u{2026}") : AttachmentNames.kindName(attachment.filename, mimeType: attachment.mimeType))
                            .lineLimit(1).truncationMode(.tail)
                        Text(" \u{00B7} " + MailText.size(attachment.bytes)).lineLimit(1).fixedSize()
                    }
                    .font(AppTheme.font(10.5)).foregroundStyle(AppTheme.text3)
                }
            }
            Spacer(minLength: 0)
            if attachment.isLoading {
                ProgressView().progressViewStyle(.circular).controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(AppTheme.text2)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            .help("Remove \(attachment.filename)")
            .accessibilityLabel(Text("Remove \(attachment.filename)"))
        }
        .padding(.leading, 9).padding(.trailing, 7)
        .frame(minHeight: 42, maxHeight: 42)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(attachment.failure != nil ? AppTheme.warn.opacity(0.7) : AppTheme.stroke, lineWidth: 1))
        .contextMenu {
            if let place { Button("Place in Message", action: place).disabled(!editable || attachment.state != .ready) }
            Button("Remove", action: remove).disabled(!editable)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(attachment.spoken))
        .accessibilityAction(named: "Remove", remove)
    }

}
