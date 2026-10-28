import Foundation

// Glue between the data layer and the UI: the data layer's preferences store lists the image
// allow list for Settings → Mail. Lives in UI because `MailImageAllowListing` is a UI-side protocol and
// the data tests compile without UI.
extension LocalMailStore: MailImageAllowListing {
    func allowedImageSenders() -> [String] {
        (try? MailRepo(db: db).allowedSenders()) ?? []
    }
}

/// Settings → Mail turning "Images from people you've written to" off clears what it recorded
/// (`LocalMailStore.forgetCorrespondents`).
extension LocalMailStore: MailCorrespondentForgetting {}

enum MailIntegration {
    /// Called once at launch, after `DataServices.start`.
    @MainActor
    static func install() {
        ThreadReaderModel.imageFetcher = { try await DataServices.messages(threadR: $0, loadImages: true) }
        // Rich mail attachments: "Open in Gmail" for files over 50 MB, the Peek's "+N", and Open copies older
        // than 24 h removed at launch (D-043).
        AttachmentStripModel.gmailLink = { DataServices.gmailURL(threadR: $0) }
        AttachmentStripModel.openThread = { r in
            MainWindowController.shared.show(.inbox)
            Task { @MainActor in await MainWindowController.shared.shell.inbox.select(r: r) }
        }
        DispatchQueue.global(qos: .utility).async {
            AttachmentFiles.sweepDownloads()
            ComposeStaging.sweep()   // no composer is open at launch: every staging folder is left over
        }
    }
}
