import AppKit

/// The Format menu (D-042). Every item sends a first-responder action that the composer's text
/// view implements and validates (checkmarks follow the selection); outside a composer nothing answers, so the items
/// are disabled. Shortcuts follow Apple Mail, and Gmail where macOS has no standard. None collide with the D-023
/// approval card's key monitor: while the card is up the composer has no first responder.
enum FormatMenu {
    @MainActor
    static func build() -> NSMenu {
        let menu = NSMenu(title: "Format")
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            return item
        }
        menu.addItem(item("Bold", #selector(ComposerTextView.ycToggleBold(_:)), "b"))
        menu.addItem(item("Italic", #selector(ComposerTextView.ycToggleItalic(_:)), "i"))
        menu.addItem(item("Underline", #selector(ComposerTextView.ycToggleUnderline(_:)), "u"))
        menu.addItem(item("Strikethrough", #selector(ComposerTextView.ycToggleStrikethrough(_:)), "x", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(ComposerTextView.ycBigger(_:)), "+"))
        menu.addItem(item("Smaller", #selector(ComposerTextView.ycSmaller(_:)), "-"))
        menu.addItem(item("Show Colors", #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Bulleted List", #selector(ComposerTextView.ycToggleBulletedList(_:)), "8", [.command, .shift]))
        menu.addItem(item("Numbered List", #selector(ComposerTextView.ycToggleNumberedList(_:)), "7", [.command, .shift]))
        menu.addItem(item("Increase Indent", #selector(ComposerTextView.ycIndent(_:)), "]"))
        menu.addItem(item("Decrease Indent", #selector(ComposerTextView.ycOutdent(_:)), "["))
        menu.addItem(item("Quote Block", #selector(ComposerTextView.ycToggleQuote(_:)), "9", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Add Link\u{2026}", #selector(ComposerTextView.ycInsertLink(_:)), "k"))
        menu.addItem(item("Clear Formatting", #selector(ComposerTextView.ycClearFormatting(_:)), "\\"))
        menu.addItem(.separator())
        menu.addItem(item("Make Plain Text", #selector(ComposerTextView.ycToggleRich(_:)), "t", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Attach Files\u{2026}", #selector(ComposerTextView.ycAttachFiles(_:)), "a", [.command, .shift]))
        return menu
    }

    /// Edit → Paste and Match Style (⌥⇧⌘V): NSTextView's own plain paste in the typing style.
    @MainActor
    static func pasteAndMatchStyle() -> NSMenuItem {
        let item = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        item.keyEquivalentModifierMask = [.command, .option, .shift]
        return item
    }
}
