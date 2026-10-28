import AppKit

extension RichTextSnapshot {
    /// An offscreen `ComposerTextView` (TextKit 2, the editor's own drawing: list markers, quote bars, links) drawn
    /// with `cacheDisplay` into a 2× bitmap; never in a window. `height` nil = the text's own height.
    /// `selection` draws as an inactive selection would (renders of the link and colour popovers).
    @MainActor
    static func textSnapshot(_ attributed: NSAttributedString, width: CGFloat, height: CGFloat? = nil,
                             mode: ComposerTextView.Mode = .rich, background: NSColor? = nil, selection: NSRange? = nil,
                             scale: CGFloat = 2) -> NSImage {
        var attributed = attributed
        if let selection, selection.length > 0, NSMaxRange(selection) <= attributed.length {
            let marked = NSMutableAttributedString(attributedString: attributed)
            marked.addAttribute(.backgroundColor, value: NSColor(srgbRed: 0xC9 / 255, green: 0xDD / 255, blue: 0xFB / 255, alpha: 1),
                                range: selection)
            attributed = marked
        }
        let width = max(40, width.rounded())
        let view = ComposerTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: width, height: max(height ?? 2000, 40))
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        view.configure(mode: mode, defaults: ComposerDocument.Defaults())
        if let background {
            view.drawsBackground = true
            view.backgroundColor = background
        }
        view.textStorage?.setAttributedString(attributed)
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        let used = view.textLayoutManager?.usageBoundsForTextContainer.height ?? 0
        let h = max(20, (height ?? ceil(used + view.textContainerInset.height * 2)).rounded())
        view.frame = NSRect(x: 0, y: 0, width: width, height: h)
        if let tlm = view.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        let image = NSImage(size: NSSize(width: width, height: h))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(h * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = NSSize(width: width, height: h)
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
}
