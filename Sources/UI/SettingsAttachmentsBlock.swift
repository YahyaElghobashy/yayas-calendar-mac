import AppKit
import SwiftUI

// Settings → Mail, attachments (rich mail, D-043): where Save puts files
// (`mail.attachments.saveFolder`, "" = Downloads; a missing or unwritable folder falls back to Downloads with a
// note) and the attachment cache on this Mac ("124 MB · Clear", `Services.mailAttachments.usage()/clear()`).

@MainActor
final class SettingsAttachmentsModel: ObservableObject {
    @Published private(set) var folder: AttachmentSaveFolder
    @Published private(set) var files = 0
    @Published private(set) var bytes = 0

    private let local: MailLocalStore
    private let store: () -> MailAttachmentStore

    init(local: MailLocalStore = DefaultsMailLocalStore.shared, store: @escaping () -> MailAttachmentStore = { Services.mailAttachments }) {
        self.local = local
        self.store = store
        folder = AttachmentSaveFolder.resolve(local)
        refresh()
    }

    var hasCustomFolder: Bool { !(local.string(AttachmentSaveFolder.key) ?? "").isEmpty }

    func refresh() {
        folder = AttachmentSaveFolder.resolve(local)
        let usage = store().usage()
        files = usage.files
        bytes = usage.bytes
    }

    /// "Change…": a folder panel (it also grants access to folders macOS protects).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.directoryURL = folder.url
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setFolder(url.path)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func setFolder(_ path: String) {
        local.setString(path, AttachmentSaveFolder.key)
        refresh()
    }

    func useDownloads() { setFolder("") }

    func clear() {
        try? store().clear()
        refresh()
    }

    var usageLine: String {
        guard bytes > 0 else { return "Nothing kept yet" }
        return MailText.size(bytes) + " \u{00B7} " + (files == 1 ? "1 file" : "\(files) files")
    }
}

/// The two rows, drawn like the other Mail blocks (one `SettingsMailCard` line hooks it in).
struct SettingsAttachmentsBlock: View {
    var model: SettingsAttachmentsModel?
    @Environment(\.headlessRender) private var headless
    @Local private var box = SettingsAttachmentsBox()

    var body: some View {
        SettingsAttachmentsRows(model: model ?? box.model(headless: headless))
    }
}

@MainActor
final class SettingsAttachmentsBox {
    private var made: SettingsAttachmentsModel?

    /// Renders never read the user's defaults or cache.
    func model(headless: Bool) -> SettingsAttachmentsModel {
        if let made { return made }
        let model = headless ? SettingsAttachmentsModel(local: MemoryMailLocalStore(), store: { EmptyStores.shared }) : SettingsAttachmentsModel()
        made = model
        return model
    }
}

private struct SettingsAttachmentsRows: View {
    @ObservedObject var model: SettingsAttachmentsModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save attachments to").font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.text3)
                            .accessibilityHidden(true)
                        Text(AttachmentSaveFolder.shown(model.folder.url)).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let note = model.folder.note {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if model.hasCustomFolder {
                    Button("Use Downloads") { model.useDownloads() }
                        .buttonStyle(.plain).font(AppTheme.font(12, .bold)).foregroundStyle(AppTheme.text2)
                }
                Button("Change\u{2026}") { model.chooseFolder() }
                    .buttonStyle(.plain).font(AppTheme.font(12, .bold)).foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("Change the folder for saved attachments")
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Attachments kept on this Mac").font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                    Text("Opened attachments stay here so they reopen at once, up to 300 MB. Files you saved aren\u{2019}t touched.")
                        .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(model.usageLine).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2).lineLimit(1).fixedSize()
                Button("Clear") { model.clear() }
                    .buttonStyle(.plain).font(AppTheme.font(12, .bold))
                    .foregroundStyle(model.bytes > 0 ? AppTheme.accent : AppTheme.text3)
                    .disabled(model.bytes == 0)
                    .accessibilityLabel("Clear attachments kept on this Mac")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .onAppear { if !headless { model.refresh() } }
    }
}
