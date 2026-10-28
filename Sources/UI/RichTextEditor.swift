import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The composer's text view (D-042): one NSTextView subclass for the rich body on the
// light sheet, the plain body (today's dark composer) and the Settings signature editor.
//
// - TextKit 2 only: built with `init(usingTextLayoutManager: true)`; `.layoutManager` is never read
//   (reading it once silently switches the view to TextKit 1 for good). List markers are drawn by layout.
// - Paste and drop never go through WebKit: `readablePasteboardTypes` is RTFD, RTF, HTML and plain text, never
//   web archives; RTF(D) is AppKit's local import, HTML goes through `HTMLSanitizer` (remote blocked) and our own
//   `MailHTMLReader`; both are normalized. ⌥⇧⌘V (`pasteAsPlainText:`) pastes the string in the typing style.
// - Every toolbar and Format-menu operation is one named undo group (`perform`), through `shouldChangeText` /
//   `didChangeText`, so Undo and Redo come from NSTextView itself.
// - Quote-block bars are drawn in `drawBackground(in:)` over the TextKit 2 layout fragments.

/// Notified when the composer's formatting state may have changed outside our own operations (native underline,
/// the font panel, the colour panel).
extension Notification.Name {
    static let ycComposerTypingChanged = Notification.Name(Profile.scoped("composer-typing"))
}

final class ComposerTextView: NSTextView, ComposerEditing {
    enum Mode: Equatable { case rich, plain, signature }

    var mode: Mode = .rich
    var defaults = ComposerDocument.Defaults()
    /// The rich document changed (typing, paste, an operation).
    var onChange: ((NSAttributedString) -> Void)?
    /// Selection or typing attributes changed.
    var onSelection: ((NSRange, [NSAttributedString.Key: Any]) -> Void)?
    /// ⌘K / Add Link…: the model opens the link popover.
    var onRequestLink: (() -> Void)?
    /// ⇧⌘T: Make Plain Text / Make Rich Text (the composer asks first when formatting would be lost).
    var onToggleRich: (() -> Void)?
    /// The formatting the toolbar shows (menu checkmarks read it).
    var formatting: () -> FormattingState = { FormattingState() }
    /// Files dropped or pasted (every mode): the composer attaches them.
    var onAttachFiles: (([URL]) -> Void)?
    /// Image bytes dropped or pasted, with a name when known; `asFile` when ⌥ is held (or in plain mode).
    var onImage: ((Data, String?, Bool) -> Void)?
    /// Right-click an inline image → Send as Attachment (its content id).
    var onSendAsAttachment: ((String) -> Void)?
    /// ⇧⌘A / Attach Files…: the composer's open panel.
    var onAttachRequest: (() -> Void)?

    static let quoteBar = NSColor(srgbRed: 0xC9 / 255, green: 0xC4 / 255, blue: 0xCF / 255, alpha: 1)
    static let sheetText = NSColor(srgbRed: 0x1D / 255, green: 0x1B / 255, blue: 0x20 / 255, alpha: 1)

    // MARK: Building

    /// A TextKit 2 text view in a scroll view, configured for `mode`.
    @MainActor
    static func make(mode: Mode, defaults: ComposerDocument.Defaults = .init()) -> (NSScrollView, ComposerTextView) {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = ComposerTextView(usingTextLayoutManager: true)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        view.configure(mode: mode, defaults: defaults)
        scroll.documentView = view
        return (scroll, view)
    }

    func configure(mode: Mode, defaults: ComposerDocument.Defaults) {
        self.mode = mode
        self.defaults = defaults
        allowsUndo = true
        isContinuousSpellCheckingEnabled = true
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        drawsBackground = false
        switch mode {
        case .plain:
            // Exactly today's plain composer.
            isRichText = false
            importsGraphics = false
            appearance = nil
            font = NSFont.systemFont(ofSize: 13.5)
            textColor = NSColor(red: 0xE9 / 255, green: 0xF4 / 255, blue: 0xF1 / 255, alpha: 1)
            insertionPointColor = NSColor(red: 0x3C / 255, green: 0xCB / 255, blue: 0xB4 / 255, alpha: 1)
            textContainerInset = NSSize(width: 2, height: 6)
            isAutomaticLinkDetectionEnabled = false
        case .rich, .signature:
            // The light sheet: aqua, so text without a colour attribute draws black (never a foreground colour).
            isRichText = true
            importsGraphics = false
            appearance = NSAppearance(named: .aqua)
            usesFontPanel = true
            usesRuler = false
            isAutomaticLinkDetectionEnabled = true
            insertionPointColor = Self.sheetText
            textContainerInset = mode == .rich ? NSSize(width: 12, height: 12) : NSSize(width: 4, height: 6)
            typingAttributes = ComposerDocument.defaultAttributes(defaults)
            linkTextAttributes = [.foregroundColor: NSColor(srgbRed: 0x1A / 255, green: 0x5F / 255, blue: 0xB4 / 255, alpha: 1),
                                  .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        }
        updateDragTypeRegistration()
    }

    /// Loads a document (no undo: the first load, or Settings' revert).
    func load(_ doc: NSAttributedString) {
        textStorage?.setAttributedString(doc)
        setSelectedRange(NSRange(location: 0, length: 0))
        if mode != .plain { typingAttributes = ComposerDocument.attributesAtCaret(doc, 0, defaults: defaults) }
    }

    /// The model replaced the document (From switch, Make Rich Text, Edit quoted text): one undoable change.
    func replaceAll(with doc: NSAttributedString, actionName: String) {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        let keep = selectedRange()
        guard shouldChangeText(in: all, replacementString: doc.string) else { return }
        storage.setAttributedString(doc)
        didChangeText()
        undoManager?.setActionName(actionName)
        setSelectedRange(ComposerDocument.clamp(keep, doc.length))
    }

    // MARK: Operations (one undo group each)

    func perform(_ op: ComposerDocument.Op) {
        guard mode != .plain, isEditable, let storage = textStorage else { return }
        let sel = selectedRange()
        let affected = ComposerDocument.affectedRange(op, in: storage, selection: sel)
        let replacement = ComposerDocument.replacementString(op)
        if op.isCharacterOp, sel.length == 0, replacement == nil {
            let result = ComposerDocument.apply(op, to: storage, selection: sel, typing: typingAttributes, defaults: defaults)
            if let typing = result.typing { typingAttributes = typing }
            reportSelection()
            return
        }
        undoManager?.beginUndoGrouping()
        if shouldChangeText(in: affected, replacementString: replacement) {
            storage.beginEditing()
            let result = ComposerDocument.apply(op, to: storage, selection: sel, typing: typingAttributes, defaults: defaults)
            storage.endEditing()
            didChangeText()
            setSelectedRange(result.selection)
            if let typing = result.typing { typingAttributes = typing }
        }
        undoManager?.setActionName(op.actionName)
        undoManager?.endUndoGrouping()
        reportSelection()
    }

    func focusEditor() {
        window?.makeFirstResponder(self)
    }

    func select(_ range: NSRange) {
        setSelectedRange(ComposerDocument.clamp(range, textStorage?.length ?? 0))
    }

    func reportSelection() {
        onSelection?(selectedRange(), typingAttributes)
    }

    override var typingAttributes: [NSAttributedString.Key: Any] {
        didSet { if mode != .plain { NotificationCenter.default.post(name: .ycComposerTypingChanged, object: self) } }
    }

    // MARK: Format menu actions (first responder)

    @objc func ycToggleBold(_ sender: Any?) { perform(.bold) }
    @objc func ycToggleItalic(_ sender: Any?) { perform(.italic) }
    @objc func ycToggleUnderline(_ sender: Any?) { perform(.underline) }
    @objc func ycToggleStrikethrough(_ sender: Any?) { perform(.strikethrough) }
    @objc func ycBigger(_ sender: Any?) { perform(.bigger) }
    @objc func ycSmaller(_ sender: Any?) { perform(.smaller) }
    @objc func ycToggleBulletedList(_ sender: Any?) { perform(.list(.bullet)) }
    @objc func ycToggleNumberedList(_ sender: Any?) { perform(.list(.number)) }
    @objc func ycIndent(_ sender: Any?) { perform(.indent) }
    @objc func ycOutdent(_ sender: Any?) { perform(.outdent) }
    @objc func ycToggleQuote(_ sender: Any?) { perform(.quote) }
    @objc func ycClearFormatting(_ sender: Any?) { perform(.clearFormatting) }
    @objc func ycInsertLink(_ sender: Any?) { if mode != .plain { onRequestLink?() } }
    @objc func ycToggleRich(_ sender: Any?) { onToggleRich?() }
    @objc func ycAttachFiles(_ sender: Any?) { onAttachRequest?() }

    static let richActions: Set<Selector> = [
        #selector(ycToggleBold(_:)), #selector(ycToggleItalic(_:)), #selector(ycToggleUnderline(_:)),
        #selector(ycToggleStrikethrough(_:)), #selector(ycBigger(_:)), #selector(ycSmaller(_:)),
        #selector(ycToggleBulletedList(_:)), #selector(ycToggleNumberedList(_:)), #selector(ycIndent(_:)), #selector(ycOutdent(_:)),
        #selector(ycToggleQuote(_:)), #selector(ycClearFormatting(_:)), #selector(ycInsertLink(_:)),
    ]

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return super.validateMenuItem(item) }
        if action == #selector(ycAttachFiles(_:)) { return mode != .signature && onAttachRequest != nil && isEditable }
        if action == #selector(ycToggleRich(_:)) {
            item.title = mode == .plain ? "Make Rich Text" : "Make Plain Text"
            return mode != .signature && onToggleRich != nil && isEditable
        }
        if Self.richActions.contains(action) {
            guard mode != .plain, isEditable else { item.state = .off; return false }
            let f = formatting()
            func tri(_ t: FormattingState.Tri) -> NSControl.StateValue { t == .on ? .on : t == .mixed ? .mixed : .off }
            switch action {
            case #selector(ycToggleBold(_:)): item.state = tri(f.bold)
            case #selector(ycToggleItalic(_:)): item.state = tri(f.italic)
            case #selector(ycToggleUnderline(_:)): item.state = tri(f.underline)
            case #selector(ycToggleStrikethrough(_:)): item.state = tri(f.strikethrough)
            case #selector(ycToggleBulletedList(_:)): item.state = f.list == .bullet ? .on : .off
            case #selector(ycToggleNumberedList(_:)): item.state = f.list == .number ? .on : .off
            case #selector(ycToggleQuote(_:)): item.state = tri(f.quote)
            case #selector(ycOutdent(_:)): return f.canOutdent
            case #selector(ycBigger(_:)): return SizeChoice.step(from: CGFloat(f.size ?? defaults.size.rawValue), up: true) != nil
            case #selector(ycSmaller(_:)): return SizeChoice.step(from: CGFloat(f.size ?? defaults.size.rawValue), up: false) != nil
            default: break
            }
            return true
        }
        if action == #selector(pasteAsPlainText(_:)) { return isEditable && super.validateMenuItem(item) }
        return super.validateMenuItem(item)
    }

    // MARK: Keys: lists and quotes

    private var caretParagraph: ComposerDocument.ParagraphInfo? {
        guard let storage = textStorage else { return nil }
        return ComposerDocument.paragraphs(storage, in: selectedRange()).first
    }

    override func insertTab(_ sender: Any?) {
        if mode != .plain, let p = caretParagraph, !p.lists.isEmpty {
            perform(.indent)
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if mode != .plain, let p = caretParagraph, !p.lists.isEmpty {
            perform(.outdent)
            return
        }
        super.insertBacktab(sender)
    }

    /// Return on an empty quote line leaves the quote (lists end on an empty item by themselves in TextKit 2).
    override func insertNewline(_ sender: Any?) {
        if mode != .plain, selectedRange().length == 0, let p = caretParagraph, p.range.length == 0, p.quote > 0, p.lists.isEmpty {
            perform(.quote)
            return
        }
        super.insertNewline(sender)
    }

    // MARK: Paste and drop (never WebKit)

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // Files first (a Finder copy also carries the path as a string and an icon picture), then rich text, pictures
        // (screenshots), plain text. Never web archives.
        let files: [NSPasteboard.PasteboardType] = onAttachFiles == nil ? [] : [.fileURL]
        let pictures: [NSPasteboard.PasteboardType] = onImage == nil ? [] : [.png, .tiff]
        switch mode {
        case .plain: return files + pictures + [.string]
        case .rich: return files + [.rtfd, .rtf, .html] + pictures + [.string]
        case .signature: return [.rtfd, .rtf, .html, .string]
        }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .fileURL, let onAttachFiles {
            // Images up to 5 MB go inline in a rich body (⌥ attaches them); everything else becomes a chip.
            let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            let asFile = mode == .plain || NSEvent.modifierFlags.contains(.option) || onImage == nil
            var files: [URL] = []
            for url in urls {
                let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                if !asFile, isImage, ComposerAttachRules.size(url) <= ComposerImages.inlineLimit, let data = try? Data(contentsOf: url),
                   ComposerImages.prepare(data) != nil {
                    onImage?(data, url.lastPathComponent, false)
                } else {
                    files.append(url)
                }
            }
            if !files.isEmpty { onAttachFiles(files) }
            return true
        }
        if type == .png || type == .tiff, let onImage {
            guard let data = pboard.data(forType: type) else { return false }
            onImage(data, nil, mode == .plain || NSEvent.modifierFlags.contains(.option))
            return true
        }
        guard mode != .plain else { return type == .string ? super.readSelection(from: pboard, type: type) : false }
        switch type {
        case .rtfd:
            guard let data = pboard.data(forType: .rtfd), let read = NSAttributedString(rtfd: data, documentAttributes: nil) else { return false }
            return insertNormalized(read)
        case .rtf:
            guard let data = pboard.data(forType: .rtf), let read = NSAttributedString(rtf: data, documentAttributes: nil) else { return false }
            return insertNormalized(read)
        case .html:
            guard let html = pboard.string(forType: .html) else { return false }
            return insertNormalized(Self.importHTML(html, defaults: defaults))
        case .string:
            return super.readSelection(from: pboard, type: type)
        default:
            return false   // .webArchive and everything else: never read
        }
    }

    /// Pasted HTML: sanitized with remote content blocked (alt text kept), then read by our own subset reader.
    static func importHTML(_ html: String, defaults: ComposerDocument.Defaults) -> NSAttributedString {
        let clean = HTMLSanitizer.sanitize(html, remote: .block).html
        return MailHTMLReader.attributedString(clean, font: defaults.css, size: defaults.size.points)
    }

    private func insertNormalized(_ read: NSAttributedString) -> Bool {
        var normalized = ComposerDocument.normalize(read, defaults: defaults)
        // One pasted paragraph keeps the paragraph it lands in (no stray line break from the source's terminator).
        if normalized.string.hasSuffix("\n"), !normalized.string.dropLast().contains("\n") {
            normalized = normalized.attributedSubstring(from: NSRange(location: 0, length: normalized.length - 1))
        }
        guard let storage = textStorage else { return false }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound, shouldChangeText(in: range, replacementString: normalized.string) else { return false }
        storage.replaceCharacters(in: range, with: normalized)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + normalized.length, length: 0))
        return true
    }

    // MARK: Inline images

    /// Inserts at the selection as one undoable change.
    func insert(_ text: NSAttributedString, actionName: String) {
        guard mode != .plain, isEditable, let storage = textStorage else { return }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound, shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        undoManager?.setActionName(actionName)
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
    }

    /// Removes every attachment character carrying `contentId` (one undo group).
    func removeInlineImage(_ contentId: String) {
        guard let storage = textStorage else { return }
        let ranges = ComposerImages.inlineImages(storage).filter { $0.contentId == contentId }.map(\.range)
        guard !ranges.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        for range in ranges.reversed() where shouldChangeText(in: range, replacementString: "") {
            storage.replaceCharacters(in: range, with: "")
            didChangeText()
        }
        undoManager?.setActionName("Send as Attachment")
        undoManager?.endUndoGrouping()
    }

    /// The inline image under the pointer, if any.
    private func inlineImage(at event: NSEvent) -> String? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        for i in [index, index - 1] where i >= 0 && i < storage.length {
            if storage.attribute(.attachment, at: i, effectiveRange: nil) != nil,
               let cid = storage.attribute(.ycInlineImage, at: i, effectiveRange: nil) as? String, !cid.isEmpty { return cid }
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if mode == .rich, isEditable, onSendAsAttachment != nil, let cid = inlineImage(at: event) {
            let item = NSMenuItem(title: "Send as Attachment", action: #selector(ycSendImageAsAttachment(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cid
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc func ycSendImageAsAttachment(_ sender: NSMenuItem) {
        guard let cid = sender.representedObject as? String else { return }
        onSendAsAttachment?(cid)
    }

    // MARK: Quote bars

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard mode != .plain, let tlm = textLayoutManager else { return }
        let origin = textContainerOrigin
        let top = CGPoint(x: 0, y: max(0, rect.minY - origin.y))
        let start = tlm.textLayoutFragment(for: top)?.rangeInElement.location ?? tlm.documentRange.location
        Self.quoteBar.setFill()
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > rect.maxY { return false }
            guard let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return true }
            let level = MailRichText.quoteLevel(paragraph.attributedString.attribute(.ycQuoteBlock, at: 0, effectiveRange: nil))
            guard level > 0 else { return true }
            for l in 0..<level {
                let x = origin.x + 4 + CGFloat(l) * MailRichText.quoteStep
                NSRect(x: x, y: frame.minY + origin.y, width: 2, height: frame.height).fill()
            }
            return true
        }
    }
}

// MARK: - SwiftUI

/// The rich body and the signature editor: a ComposerTextView bound to a document with a revision counter (the
/// model's own replacements load as one undoable change; typing flows back through `onChange`).
struct RichTextEditor: NSViewRepresentable {
    var document: NSAttributedString
    var revision: Int
    var mode: ComposerTextView.Mode = .rich
    var defaults = ComposerDocument.Defaults()
    var editable = true
    /// False while the approval card is up (VoiceOver skips the AppKit view; SwiftUI's accessibilityHidden doesn't reach it).
    var accessible = true
    var focusOnAppear = false
    var onChange: (NSAttributedString) -> Void
    var onSelection: (NSRange, [NSAttributedString.Key: Any]) -> Void = { _, _ in }
    var onRequestLink: (() -> Void)?
    var onToggleRich: (() -> Void)?
    var formatting: () -> FormattingState = { FormattingState() }
    var onAttachFiles: (([URL]) -> Void)?
    var onImage: ((Data, String?, Bool) -> Void)?
    var onSendAsAttachment: ((String) -> Void)?
    var onAttachRequest: (() -> Void)?
    /// The model's handle on the view (operations, focus).
    var register: (ComposerTextView?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = ComposerTextView.make(mode: mode, defaults: defaults)
        view.load(document)
        view.delegate = context.coordinator
        context.coordinator.revision = revision
        context.coordinator.parent = self
        wire(view)
        register(view)
        context.coordinator.observe(view)
        if focusOnAppear { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        wire(view)
        view.isEditable = editable
        if view.isAccessibilityElement() != accessible {
            view.setAccessibilityElement(accessible)
            scroll.setAccessibilityElement(accessible)
        }
        if revision != context.coordinator.revision {
            context.coordinator.revision = revision
            if !(view.textStorage?.isEqual(to: document) ?? false) {
                context.coordinator.applying = true
                view.replaceAll(with: document, actionName: "Change")
                context.coordinator.applying = false
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.parent?.register(nil)
        coordinator.stop()
    }

    private func wire(_ view: ComposerTextView) {
        view.onRequestLink = onRequestLink
        view.onToggleRich = onToggleRich
        view.formatting = formatting
        view.defaults = defaults
        let attaching = (onAttachFiles != nil) != (view.onAttachFiles != nil) || (onImage != nil) != (view.onImage != nil)
        view.onAttachFiles = onAttachFiles
        view.onImage = onImage
        view.onSendAsAttachment = onSendAsAttachment
        view.onAttachRequest = onAttachRequest
        if attaching { view.updateDragTypeRegistration() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor?
        var revision = 0
        var applying = false
        private var observer: NSObjectProtocol?

        func observe(_ view: ComposerTextView) {
            observer = NotificationCenter.default.addObserver(forName: .ycComposerTypingChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, !self.applying else { return }
                    self.parent?.onSelection(view.selectedRange(), view.typingAttributes)
                }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        /// While the model's own document loads (inside a SwiftUI update) nothing is echoed back: the model already
        /// has it, and publishing from a view update is not allowed. The selection is reported on the next turn.
        func textDidChange(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView, let storage = view.textStorage else { return }
            parent?.onChange(NSAttributedString(attributedString: storage))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if applying {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.parent?.onSelection(view.selectedRange(), view.typingAttributes)
                }
                return
            }
            parent?.onSelection(view.selectedRange(), view.typingAttributes)
        }
    }
}
