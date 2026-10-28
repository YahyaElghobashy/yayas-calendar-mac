import AppKit
import UniformTypeIdentifiers

/// The few places the accounts screen asks AppKit for a system panel. Kept apart from the model's core
/// so tests never reach them.
extension AccountsModel {
    @MainActor func chooseLogo(for id: UUID) {
        guard let account = record(id) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a logo for \(account.tag)"
        panel.prompt = "Use as logo"
        panel.message = "Any square-ish image works: PNG, JPEG or SVG. I\u{2019}ll shrink it to fit."
        panel.allowedContentTypes = [.png, .jpeg, .svg, .tiff, .heic, .gif, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLogo(from: url, for: id)
    }

    @MainActor func chooseClientFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Google client file"
        panel.prompt = "Use this file"
        panel.message = "The client_secret JSON file you downloaded for the Desktop app client in Google Cloud."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importClientFile(url)
    }

    /// "Remove ORB?" — then revoke, forget the Keychain item, drop the row and logo.
    @MainActor func confirmRemove(_ id: UUID) {
        guard let account = record(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(account.tag)?"
        alert.informativeText = "Yaya\u{2019}s Calendar forgets it and asks Google to revoke access. Your mail and calendar stay untouched."
        alert.alertStyle = .warning
        let remove = alert.addButton(withTitle: "Remove")
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await self.remove(id) }
    }
}
