// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import SwiftUI

/// Renders that aren't reader cards: the risky-Open question
/// (`rm-attachment-risky-confirm`, the SwiftUI content of the sheet) and Settings → Mail's attachment rows
/// (`rm-settings-attachments`, extra). Plus the attachment budget line. Cast data only.
@MainActor
enum RichMailAttachmentRenders {
    static func run(save: (AnyView, String, [String: Any]) -> Void, attachments: FakeMailAttachments) {
        bench()
        promiseCheck(attachments: attachments)
        let installer = RichMailThreads.attachmentList[5]
        let name = AttachmentNames.display(installer.name, mimeType: installer.mimeType)
        let confirm = RiskyAttachmentConfirm(name: name, kind: AttachmentNames.kindName(name, mimeType: installer.mimeType),
                                             sender: RichMailCast.priya.name, saveTitle: "Save to Downloads",
                                             icon: AttachmentIcons.icon(name, mimeType: installer.mimeType))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .padding(36)
            .background(AppTheme.background)
            .environment(\.headlessRender, true)
        save(AnyView(confirm), "rm-attachment-risky-confirm.png",
             ["window": "rich-mail", "surface": "dialog", "state": "risky-open-confirm", "web": "none", "thread": RichMailThreads.attachments.r])

        // Settings: a chosen folder that went missing (the Downloads note) and what the cache holds.
        let local = MemoryMailLocalStore()
        local.setString("/Volumes/Archive/Invoices", AttachmentSaveFolder.key)
        let model = SettingsAttachmentsModel(local: local, store: { attachments })
        let settings = ShellCard(padding: 0) { SettingsAttachmentsBlock(model: model) }
            .frame(width: 680)
            .padding(24)
            .background(AppTheme.background)
            .environment(\.colorScheme, .dark)
            .environment(\.headlessRender, true)
        save(AnyView(settings), "rm-settings-attachments.png",
             ["window": "rich-mail", "surface": "settings", "state": "save-folder-fallback-cache-usage", "web": "none",
              "cacheFiles": model.files])
    }

    /// The drag-to-Finder path without Finder: the chip's file promise names the file with the sanitized
    /// name and writes a quarantined copy where it is asked to. Prints one CHECK line.
    static func promiseCheck(attachments: FakeMailAttachments) {
        let fixture = RichMailThreads.attachments
        let message = MailMessage(id: fixture.r + "-1", from: RichMailCast.priya.name, fromEmail: RichMailCast.priya.email, to: [], cc: [],
                                  date: Date(timeIntervalSince1970: 0), subject: fixture.subject, html: nil, text: "",
                                  hasRemoteImages: false, attachments: RichMailThreads.attachmentList)
        let model = AttachmentStripModel(threadR: fixture.r, message: message, store: { attachments }, local: MemoryMailLocalStore())
        let folder = attachments.folder.deletingLastPathComponent().appendingPathComponent("promise", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        var written: URL?
        for a in [RichMailThreads.attachmentList[0], RichMailThreads.attachmentList[7]] {
            guard let provider = model.promise(for: a), let delegate = provider.userInfo as? AttachmentPromise else { continue }
            let name = delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
            names.append(name)
            if a.id == RichMailThreads.attachmentList[0].id {
                let target = folder.appendingPathComponent(name)
                var failure: Error?
                delegate.filePromiseProvider(provider, writePromiseTo: target) { failure = $0 }
                if failure == nil { written = target }
            }
        }
        let quarantined = written.map { getxattr($0.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0 } ?? false
        let ok = names == ["Launch plan.pdf", "invoicefdp.exe"] && written.map { FileManager.default.fileExists(atPath: $0.path) } == true && quarantined
        print("CHECK rich mail file promise names=\(names.count) written=\(written != nil) quarantined=\(quarantined) \(ok ? "pass" : "FAIL")")
    }

    /// "Attachment fetch decode, 25 MB ≤ 1 s CPU" (JSON + base64url, as `GmailClient.attachment` does).
    static func bench() {
        var raw = Data(count: 25_000_000)
        raw.withUnsafeMutableBytes { buffer in
            for i in 0..<buffer.count { buffer[i] = UInt8(truncatingIfNeeded: i &* 31 &+ (i >> 8)) }
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["size": raw.count, "data": raw.base64URLString]) else { return }
        var times: [Double] = []
        var ok = true
        for _ in 0..<3 {
            let t = Date()
            let decoded = try? GmailClient.decodeAttachment(body)
            times.append(Date().timeIntervalSince(t) * 1000)
            ok = ok && decoded?.count == raw.count
        }
        let ms = times.sorted()[1]
        let budget = 1000.0
        print(String(format: "RICHMAIL-BENCH attachment decode 25MB %.1f ms (budget %.0f, gate %.0f) %@", ms, budget, budget * 2,
                     ok && ms <= budget * 2 ? "pass" : "FAIL"))
    }
}
#endif
