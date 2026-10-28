import AppKit
import ImageIO
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

// Reader attachments, the actions (rich mail, D-043): one `AttachmentStripModel` per shown
// message runs Quick Look, Open (risky types ask every time), Open With, Save / Save As / Save All, Copy,
// Show in Finder, drag to Finder (file promises) and the inline image previews. Bytes come from
// `Services.mailAttachments` (the cache under the data root); every file handed to the user is a copy with the
// sanitized name and a quarantine record (`AttachmentFiles`). Chips are SwiftUI drawings with an AppKit view on
// top (`AttachmentChipView`) that owns clicks, drags, the context menu, Space and the Quick Look panel.

// MARK: - Environment

private struct MailToastsKey: EnvironmentKey { static let defaultValue: MailToastCenter? = nil }
private struct AttachmentPreviewImagesKey: EnvironmentKey { static let defaultValue: [String: NSImage] = [:] }

extension EnvironmentValues {
    /// The toast center of the surface showing attachments (Inbox, Mail Peek): "Saved to Downloads · Show", errors.
    var mailToasts: MailToastCenter? {
        get { self[MailToastsKey.self] }
        set { self[MailToastsKey.self] = newValue }
    }

    /// Headless renders: "messageId/partId" → a decoded preview (the app loads its own).
    var attachmentPreviewImages: [String: NSImage] {
        get { self[AttachmentPreviewImagesKey.self] }
        set { self[AttachmentPreviewImagesKey.self] = newValue }
    }
}

// MARK: - Model

@MainActor
final class AttachmentStripModel: ObservableObject {
    /// The thread's Gmail web address (installed at launch; "Open in Gmail" for files over 50 MB).
    static var gmailLink: ((String) -> URL?)?
    /// Opens the thread in the main window (the Peek's "+N" chip).
    static var openThread: (@MainActor (String) -> Void)?

    let threadR: String
    let message: MailMessage
    /// File chips: inline parts drawn in the body are never listed.
    let files: [MailMessage.Attachment]

    @Published private(set) var focused: String?
    @Published private(set) var fetching: Set<String> = []
    @Published private(set) var previews: [String: NSImage] = [:]
    @Published private(set) var failedPreviews: Set<String> = []
    @Published private(set) var showsDeferred = false
    @Published private(set) var saved: [String: URL] = [:]

    var toasts: MailToastCenter?
    let quickLook = AttachmentQuickLook()
    private let store: () -> MailAttachmentStore
    private let local: MailLocalStore
    private var chips: [String: WeakChipView] = [:]
    private var copies: [String: URL] = [:]
    private var previewsStarted = false

    init(threadR: String, message: MailMessage, store: @escaping () -> MailAttachmentStore = { Services.mailAttachments },
         local: MailLocalStore = DefaultsMailLocalStore.shared) {
        self.threadR = threadR
        self.message = message
        self.files = message.attachments.filter { !$0.isInline }
        self.store = store
        self.local = local
    }

    func name(_ a: MailMessage.Attachment) -> String { AttachmentNames.display(a.name, mimeType: a.mimeType) }
    var saveFolder: AttachmentSaveFolder { AttachmentSaveFolder.resolve(local) }

    // MARK: Chips (AppKit views register themselves)

    func register(_ view: AttachmentChipView, for id: String) { chips[id] = WeakChipView(view: view) }

    func setFocus(_ id: String?) { focused = id }
    func clearFocus(_ id: String) { if focused == id { focused = nil } }

    /// Makes the chip first responder (Quick Look asks the responder chain for its controller).
    private func focusChip(_ id: String) {
        guard let view = chips[id]?.view, let window = view.window else { return }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
    }

    // MARK: Bytes

    private func fetch(_ a: MailMessage.Attachment) async throws -> URL {
        fetching.insert(a.id)
        defer { fetching.remove(a.id) }
        return try await store().file(threadR: threadR, messageId: message.id, partId: a.id)
    }

    /// The copy other apps (and Quick Look, which picks the type from the extension) get: Mail Downloads, quarantined.
    private func openCopy(_ a: MailMessage.Attachment) async throws -> URL {
        if let url = copies[a.id], FileManager.default.fileExists(atPath: url.path) { return url }
        let source = try await fetch(a)
        let url = try AttachmentFiles.openCopy(source, name: a.name, mimeType: a.mimeType)
        copies[a.id] = url
        return url
    }

    private func usable(_ a: MailMessage.Attachment) -> Bool {
        guard !a.id.isEmpty else {
            fail(ServiceError(description: "That attachment can\u{2019}t be downloaded."))
            return false
        }
        guard a.bytes <= AttachmentNames.maxFetchBytes else {
            tooBig()
            return false
        }
        return true
    }

    private func tooBig() {
        let r = threadR
        if let toasts, Self.gmailLink?(r) != nil {
            toasts.show("This one is too big to open here.", action: "Open in Gmail", duration: 8) {
                if let url = AttachmentStripModel.gmailLink?(r) { NSWorkspace.shared.open(url) }
            }
        } else {
            fail(ServiceError(description: "This one is too big to open here."))
        }
    }

    private func fail(_ error: Error) {
        if error is CancellationError { return }
        let text = (error as? ServiceError)?.description ?? "I couldn\u{2019}t get that attachment. Try again in a moment."
        if let toasts { toasts.error(text) } else { NSSound.beep() }
    }

    private func confirmation(_ text: String, show urls: [URL]) {
        guard let toasts else { return }
        toasts.show(text, action: "Show", duration: 6) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: Quick Look

    func quickLook(_ a: MailMessage.Attachment) {
        let shown = name(a)
        guard AttachmentNames.canQuickLook(shown, mimeType: a.mimeType) else {
            fail(ServiceError(description: "Quick Look can\u{2019}t show this kind of file. Use Open or Save."))
            return
        }
        if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, panel.isVisible,
           quickLook.current == a.id {
            panel.orderOut(nil)                      // Space again closes it
            return
        }
        guard usable(a) else { return }
        focusChip(a.id)
        Task {
            do {
                let url = try await openCopy(a)
                quickLook.items = [AttachmentPreviewItem(url: url, title: shown)]
                quickLook.current = a.id
                focusChip(a.id)
                guard let panel = QLPreviewPanel.shared() else { return }
                panel.updateController()
                if panel.isVisible { panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
            } catch {
                fail(error)
            }
        }
    }

    // MARK: Open

    func open(_ a: MailMessage.Attachment, with app: URL? = nil) {
        guard usable(a) else { return }
        let shown = name(a)
        if AttachmentNames.isRisky(shown, mimeType: a.mimeType) {
            let window = chips[a.id]?.view?.window ?? NSApp.keyWindow
            AttachmentConfirmSheet.present(on: window, name: shown, kind: AttachmentNames.kindName(shown, mimeType: a.mimeType),
                                           sender: message.from.isEmpty ? message.fromEmail : message.from,
                                           saveTitle: "Save to \(saveFolder.title)",
                                           icon: AttachmentIcons.icon(shown, mimeType: a.mimeType)) { [weak self] choice in
                switch choice {
                case .open: self?.proceedOpen(a, with: app)
                case .save: self?.save(a)
                case .cancel: break
                }
            }
            return
        }
        proceedOpen(a, with: app)
    }

    private func proceedOpen(_ a: MailMessage.Attachment, with app: URL?) {
        let shown = name(a)
        Task {
            do {
                let url = try await openCopy(a)
                // HTML-family files open in the browser, never in a web view of ours.
                let target = app ?? (AttachmentNames.opensInBrowser(shown) ? NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) : nil)
                if let target {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: target, configuration: NSWorkspace.OpenConfiguration())
                } else if !NSWorkspace.shared.open(url) {
                    fail(ServiceError(description: "No app on this Mac opens \u{201C}\(shown)\u{201D}. Try Save."))
                }
            } catch {
                fail(error)
            }
        }
    }

    /// Apps that can open it, the default first (Open With ▸).
    func applications(for a: MailMessage.Attachment) -> [URL] {
        let type = AttachmentNames.type(name(a), mimeType: a.mimeType)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: type) {
            apps.removeAll { $0.standardizedFileURL == preferred.standardizedFileURL }
            apps.insert(preferred, at: 0)
        }
        var seen = Set<String>()
        return Array(apps.filter { seen.insert($0.lastPathComponent).inserted }.prefix(12))
    }

    // MARK: Save

    func save(_ a: MailMessage.Attachment) {
        guard usable(a) else { return }
        let folder = saveFolder
        Task {
            do {
                let source = try await fetch(a)
                do {
                    let url = try AttachmentFiles.save(source, to: folder.url, name: a.name, mimeType: a.mimeType)
                    saved[a.id] = url
                    confirmation("Saved to \(folder.title)", show: [url])
                } catch {
                    // Files and Folders access denied (or the folder went away): the save panel grants access.
                    saveAs(a)
                }
            } catch {
                fail(error)
            }
        }
    }

    func saveAs(_ a: MailMessage.Attachment) {
        guard usable(a) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name(a)
        panel.directoryURL = saveFolder.url
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let source = try await self.fetch(a)
                    try AttachmentFiles.replace(source, at: url)
                    self.saved[a.id] = url
                    self.confirmation("Saved \u{201C}\(url.lastPathComponent)\u{201D}", show: [url])
                } catch {
                    self.fail(error)
                }
            }
        }
        if let window = chips[a.id]?.view?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Save All: the save folder, or (⌥) a folder the user picks.
    func saveAll(askFolder: Bool) {
        let list = files.filter { !$0.id.isEmpty }
        guard !list.isEmpty else { return }
        if askFolder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Save Here"
            panel.directoryURL = saveFolder.url
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.saveAll(list, to: url, title: url.lastPathComponent)
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
        } else {
            let folder = saveFolder
            saveAll(list, to: folder.url, title: folder.title)
        }
    }

    private func saveAll(_ list: [MailMessage.Attachment], to folder: URL, title: String) {
        Task {
            var urls: [URL] = []
            var skipped = 0
            for a in list {
                guard a.bytes <= AttachmentNames.maxFetchBytes else { skipped += 1; continue }
                do {
                    let source = try await fetch(a)
                    let url = try AttachmentFiles.save(source, to: folder, name: a.name, mimeType: a.mimeType)
                    saved[a.id] = url
                    urls.append(url)
                } catch {
                    skipped += 1
                }
            }
            if urls.isEmpty {
                fail(ServiceError(description: "I couldn\u{2019}t save those files. Try Save As\u{2026} instead."))
                return
            }
            var text = urls.count == 1 ? "Saved 1 file to \(title)" : "Saved \(urls.count) files to \(title)"
            if skipped > 0 { text += " (\(skipped) couldn\u{2019}t be saved)" }
            confirmation(text, show: urls)
        }
    }

    // MARK: Copy, Show in Finder

    func copy(_ a: MailMessage.Attachment) {
        guard usable(a) else { return }
        Task {
            do {
                let url = try await openCopy(a)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            } catch {
                fail(error)
            }
        }
    }

    func showInFinder(_ a: MailMessage.Attachment) {
        guard let url = saved[a.id], FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Drag to Finder

    func promise(for a: MailMessage.Attachment) -> NSFilePromiseProvider? {
        guard !a.id.isEmpty, a.bytes <= AttachmentNames.maxFetchBytes else { return nil }
        let shown = name(a)
        let delegate = AttachmentPromise(store: store(), threadR: threadR, messageId: message.id, partId: a.id, name: shown,
                                         mimeType: a.mimeType)
        let provider = NSFilePromiseProvider(fileType: AttachmentNames.type(shown, mimeType: a.mimeType).identifier, delegate: delegate)
        provider.userInfo = delegate   // the provider holds its delegate weakly
        return provider
    }

    // MARK: Context menu

    func menu(for a: MailMessage.Attachment, compact: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let shown = name(a)
        let ql = ClosureMenuItem(title: "Quick Look", key: "") { [weak self] in self?.quickLook(a) }
        ql.isEnabled = AttachmentNames.canQuickLook(shown, mimeType: a.mimeType)
        menu.addItem(ql)
        menu.addItem(ClosureMenuItem(title: AttachmentNames.isRisky(shown, mimeType: a.mimeType) ? "Open\u{2026}" : "Open", key: "") { [weak self] in
            self?.open(a)
        })
        if !compact {
            let with = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for app in applications(for: a) {
                let item = ClosureMenuItem(title: FileManager.default.displayName(atPath: app.path), key: "") { [weak self] in self?.open(a, with: app) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                sub.addItem(item)
            }
            if sub.items.isEmpty {
                let none = NSMenuItem(title: "No Apps", action: nil, keyEquivalent: "")
                none.isEnabled = false
                sub.addItem(none)
            }
            with.submenu = sub
            menu.addItem(with)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Save to \(saveFolder.title)", key: "") { [weak self] in self?.save(a) })
        if !compact {
            menu.addItem(ClosureMenuItem(title: "Save As\u{2026}", key: "") { [weak self] in self?.saveAs(a) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Copy", key: "") { [weak self] in self?.copy(a) })
            if let url = saved[a.id], FileManager.default.fileExists(atPath: url.path) {
                menu.addItem(ClosureMenuItem(title: "Show in Finder", key: "") { [weak self] in self?.showInFinder(a) })
            }
        }
        if a.bytes > AttachmentNames.maxFetchBytes {
            for item in menu.items where !item.isSeparatorItem { item.isEnabled = false }
        }
        return menu
    }

    // MARK: Inline previews

    var previewPlan: (auto: [MailMessage.Attachment], deferred: [MailMessage.Attachment]) { AttachmentNames.previewPlan(files) }

    /// When the card first appears: the images within the caps.
    func loadPreviews() {
        guard !previewsStarted else { return }
        previewsStarted = true
        load(previewPlan.auto)
    }

    /// "Show image previews": the rest.
    func showDeferredPreviews() {
        showsDeferred = true
        load(previewPlan.deferred)
    }

    private func load(_ list: [MailMessage.Attachment]) {
        for a in list where previews[a.id] == nil && !failedPreviews.contains(a.id) {
            let hint = AttachmentNames.type(name(a), mimeType: a.mimeType).identifier
            Task {
                do {
                    let url = try await fetch(a)
                    let image = await Task.detached(priority: .userInitiated) { AttachmentPreviewDecoder.image(url, typeHint: hint) }.value
                    if let image { previews[a.id] = image } else { failedPreviews.insert(a.id) }
                } catch {
                    failedPreviews.insert(a.id)
                }
            }
        }
    }
}

private struct WeakChipView {
    weak var view: AttachmentChipView?
}

// MARK: - Icons

@MainActor
enum AttachmentIcons {
    private static var cache: [String: NSImage] = [:]
    /// Renders: only icons macOS itself draws (another app registered for a type would leak into the PNGs and differ
    /// between Macs). Set by the headless render run.
    static var systemIconsOnly = false

    /// Programs for other systems: macOS can't run them, so whatever app this Mac registered for them says nothing useful.
    static let foreignExecutables: Set<String> = ["exe", "msi", "bat", "cmd", "com", "scr", "ps1", "vbs", "jar", "msix", "appx", "dll", "apk"]

    /// Finder's icon for the type (by extension, else MIME type); a plain document icon for foreign executables (and, in
    /// renders, for any type whose default app isn't Apple's).
    static func icon(_ name: String, mimeType: String) -> NSImage {
        let type = AttachmentNames.type(name, mimeType: mimeType)
        let generic = foreignExecutables.contains(AttachmentNames.fileExtension(name)) || (systemIconsOnly && !isSystemType(type))
        let key = generic ? "generic" : type.identifier
        if let image = cache[key] { return image }
        let image = NSWorkspace.shared.icon(for: generic ? .data : type)
        cache[key] = image
        return image
    }

    /// The type's default app ships with macOS (or nothing claims it, so the system draws its own icon).
    private static func isSystemType(_ type: UTType) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return true }
        return Bundle(url: app)?.bundleIdentifier?.hasPrefix("com.apple.") ?? false
    }
}

// MARK: - Preview decoding

enum AttachmentPreviewDecoder {
    static let maxPixelSize = 1600
    /// Images bigger than this (from their properties) are never decoded (image bombs).
    static let maxSourcePixels = 50_000_000

    /// An ImageIO thumbnail (at most 1600 px on the long side), or nil for non-images and images over 50 MP.
    static func image(_ url: URL, typeHint: String? = nil) -> NSImage? {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let typeHint { options[kCGImageSourceTypeIdentifierHint] = typeHint }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary), CGImageSourceGetCount(source) > 0 else { return nil }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            if w * h > maxSourcePixels { return nil }
        }
        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) else { return nil }
        // Points = pixels / 2 (photos are drawn no larger than they are on a Retina screen).
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}

// MARK: - Quick Look

/// The panel's data source while a chip of this strip controls it. Items are Open copies (named, quarantined).
final class AttachmentQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [AttachmentPreviewItem] = []
    var current: String?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] : nil
    }

    /// Space closes the panel, as in Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 {
            panel.orderOut(nil)
            return true
        }
        return false
    }
}

final class AttachmentPreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}

// MARK: - The chip's AppKit layer

/// Sits over a chip: click selects (it becomes first responder), double-click opens, a drag hands Finder a file
/// promise, right-click shows the menu, Space is Quick Look and ⌘O is Open. It controls the Quick Look panel while
/// it is first responder. VoiceOver reads the SwiftUI chip underneath (with the same actions).
final class AttachmentChipView: NSView, NSDraggingSource {
    weak var model: AttachmentStripModel?
    var attachment: MailMessage.Attachment
    var compact = false
    private var downAt: NSPoint?
    private var dragged = false

    init(model: AttachmentStripModel, attachment: MailMessage.Attachment, compact: Bool) {
        self.model = model
        self.attachment = attachment
        self.compact = compact
        super.init(frame: .zero)
        model.register(self, for: attachment.id)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func becomeFirstResponder() -> Bool {
        model?.setFocus(attachment.id)
        return true
    }

    override func resignFirstResponder() -> Bool {
        model?.clearFocus(attachment.id)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downAt = convert(event.locationInWindow, from: nil)
        dragged = false
        if event.clickCount == 2 { model?.open(attachment) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, !dragged, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        dragged = true
        guard let provider = model.promise(for: attachment) else { return }
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: AttachmentDragImage.make(name: model.name(attachment), mimeType: attachment.mimeType,
                                                                        size: bounds.size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { downAt = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return model?.menu(for: attachment, compact: compact)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 49, mods.isEmpty {
            model?.quickLook(attachment)
        } else if mods == .command, event.charactersIgnoringModifiers == "o" {
            model?.open(attachment)
        } else {
            super.keyDown(with: event)
        }
    }

    // Quick Look panel control (QLPreviewPanelController)
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { model != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = model?.quickLook
        panel.delegate = model?.quickLook
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

struct AttachmentChipInteraction: NSViewRepresentable {
    let model: AttachmentStripModel
    let attachment: MailMessage.Attachment
    var compact = false

    func makeNSView(context: Context) -> AttachmentChipView {
        AttachmentChipView(model: model, attachment: attachment, compact: compact)
    }

    func updateNSView(_ view: AttachmentChipView, context: Context) {
        view.model = model
        view.attachment = attachment
        view.compact = compact
        view.toolTip = model.name(attachment)   // the view on top owns the pointer, so it carries the name's tooltip
        model.register(view, for: attachment.id)
    }
}

/// The drag image: the chip as a white card with the file's icon and name.
@MainActor
enum AttachmentDragImage {
    static func make(name: String, mimeType: String, size: NSSize) -> NSImage {
        let size = NSSize(width: max(size.width, 120), height: max(size.height, 30))
        return NSImage(size: size, flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            NSColor.white.withAlphaComponent(0.96).setFill()
            card.fill()
            NSColor(red: 0xE7 / 255, green: 0xE1 / 255, blue: 0xD8 / 255, alpha: 1).setStroke()
            card.stroke()
            let iconSide = min(28, rect.height - 8)
            AttachmentIcons.icon(name, mimeType: mimeType).draw(in: NSRect(x: 8, y: (rect.height - iconSide) / 2, width: iconSide, height: iconSide))
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                              .foregroundColor: NSColor(red: 0x1D / 255, green: 0x1B / 255, blue: 0x20 / 255, alpha: 1),
                                                              .paragraphStyle: style]
            (name as NSString).draw(in: NSRect(x: 16 + iconSide, y: (rect.height - 16) / 2, width: rect.width - iconSide - 24, height: 16),
                                    withAttributes: attributes)
            return true
        }
    }
}

// MARK: - File promises

/// Writes one attachment where Finder asks: fetched (or read from the cache), copied with the sanitized name,
/// quarantined. Runs on its own background queue; holds only values, never the reader.
final class AttachmentPromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let store: MailAttachmentStore
    let threadR: String
    let messageId: String
    let partId: String
    let name: String
    let mimeType: String
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.name = "attachment-promises"
        return q
    }()

    init(store: MailAttachmentStore, threadR: String, messageId: String, partId: String, name: String, mimeType: String) {
        self.store = store
        self.threadR = threadR
        self.messageId = messageId
        self.partId = partId
        self.name = name
        self.mimeType = mimeType
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let (store, threadR, messageId, partId, mimeType) = (self.store, self.threadR, self.messageId, self.partId, self.mimeType)
        Task.detached(priority: .userInitiated) {
            do {
                let source = try await store.file(threadR: threadR, messageId: messageId, partId: partId)
                try AttachmentFiles.save(source, to: url.deletingLastPathComponent(), name: url.lastPathComponent, mimeType: mimeType)
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        done.wait()
        completionHandler(outcome.error)
    }
}

// MARK: - Risky Open

enum AttachmentConfirmChoice { case cancel, save, open }

/// "“Installer.dmg” can run code or change your Mac." Cancel · Save to Downloads · Open (Cancel is the default).
struct RiskyAttachmentConfirm: View {
    let name: String
    let kind: String
    let sender: String
    let saveTitle: String
    var icon: NSImage?
    var onChoice: (AttachmentConfirmChoice) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 52, height: 52)
                    }
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.warn)
                        .background(Circle().fill(Color(hex: 0x14232C)).frame(width: 20, height: 20))
                        .offset(x: 4, y: 4)
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AttachmentNames.riskyTitle(name))
                        .font(AppTheme.font(15, .bold)).foregroundStyle(AppTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AttachmentNames.riskyMessage(sender: sender))
                        .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(kind). macOS checks it before it runs, because it came by email.")
                        .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { onChoice(.cancel) }
                    .buttonStyle(ConfirmButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                Button(saveTitle) { onChoice(.save) }
                    .buttonStyle(ConfirmButtonStyle(prominent: false))
                Button("Open") { onChoice(.open) }
                    .buttonStyle(ConfirmButtonStyle(prominent: false))
                Color.clear.frame(width: 0, height: 0)
                    .background(Button("") { onChoice(.cancel) }.keyboardShortcut(.cancelAction).opacity(0))
            }
        }
        .padding(22)
        .frame(width: 460, alignment: .leading)
        .background(Color(hex: 0x14232C))
        .environment(\.colorScheme, .dark)
    }
}

private struct ConfirmButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.font(13, .bold))
            .foregroundStyle(prominent ? AppTheme.accentText : AppTheme.text)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(prominent ? AppTheme.accent : Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : AppTheme.stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Shows `RiskyAttachmentConfirm` as a sheet on `window` (or as a small modal window when there is none).
@MainActor
enum AttachmentConfirmSheet {
    static func present(on window: NSWindow?, name: String, kind: String, sender: String, saveTitle: String, icon: NSImage?,
                        done: @escaping (AttachmentConfirmChoice) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = NSAppearance(named: .darkAqua)
        var finished = false
        let finish: (AttachmentConfirmChoice) -> Void = { [weak panel, weak window] choice in
            guard !finished, let panel else { return }
            finished = true
            if let parent = panel.sheetParent ?? window, parent.attachedSheet === panel { parent.endSheet(panel) } else { panel.orderOut(nil) }
            if NSApp.modalWindow === panel { NSApp.stopModal() }
            done(choice)
        }
        let host = NSHostingView(rootView: RiskyAttachmentConfirm(name: name, kind: kind, sender: sender, saveTitle: saveTitle,
                                                                   icon: icon, onChoice: finish))
        host.frame.size = host.fittingSize
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        if let window {
            window.beginSheet(panel) { _ in }
        } else {
            panel.center()
            NSApp.runModal(for: panel)
        }
    }
}
