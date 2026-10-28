import AppKit
import SwiftUI

// The rich composer's toolbar (D-042): on the dark chrome right above the light sheet, 34 pt
// tall. Font ▾ · Size ▾ │ B I U S │ Text colour ▾ │ Bulleted · Numbered │ Outdent · Indent │ Quote │ Link │ Clear
// formatting. Narrower than the full row (under ~600 pt), the tail folds into a "•••" menu (ViewThatFits). Every
// button reflects the selection (a mixed selection shows a dash), says its shortcut in its help tag and VoiceOver
// hint, and carries the selected trait when on. Headless renders draw static stand-ins for menus and popovers.

struct ComposerToolbar: View {
    @ObservedObject var model: ComposerModel
    /// The Attach button's action; nil = no button.
    var attach: (() -> Void)?
    @Environment(\.headlessRender) private var headless

    private var f: FormattingState { model.formatting }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.compact)
            row(.minimal)
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.isSending || model.isConfirming)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Formatting"))
    }

    enum Fit { case full, compact, minimal }

    private func row(_ fit: Fit) -> some View {
        HStack(spacing: 2) {
            if fit != .minimal {
                fontMenu
                sizeMenu
                separator
            }
            toggle("bold", "Bold", "\u{2318}B", f.bold) { model.perform(.bold) }
            toggle("italic", "Italic", "\u{2318}I", f.italic) { model.perform(.italic) }
            toggle("underline", "Underline", "\u{2318}U", f.underline) { model.perform(.underline) }
            if fit != .minimal {
                toggle("strikethrough", "Strikethrough", "\u{21E7}\u{2318}X", f.strikethrough) { model.perform(.strikethrough) }
                separator
                colorButton
                separator
                toggle("list.bullet", "Bulleted list", "\u{21E7}\u{2318}8", f.list == .bullet ? .on : .off) { model.perform(.list(.bullet)) }
                toggle("list.number", "Numbered list", "\u{21E7}\u{2318}7", f.list == .number ? .on : .off) { model.perform(.list(.number)) }
            }
            if fit == .full {
                separator
                toggle("decrease.indent", "Decrease indent", "\u{2318}[", .off, enabled: f.canOutdent) { model.perform(.outdent) }
                toggle("increase.indent", "Increase indent", "\u{2318}]", .off) { model.perform(.indent) }
                separator
                toggle("text.quote", "Quote block", "\u{21E7}\u{2318}9", f.quote) { model.perform(.quote) }
                linkButton
                toggle("eraser", "Clear formatting", "\u{2318}\\", .off) { model.perform(.clearFormatting) }
            } else {
                separator
                overflow(fit)
            }
            if let attach {
                separator
                toggle("paperclip", "Attach files", "\u{21E7}\u{2318}A", .off, action: attach)
            }
        }
        .fixedSize()
    }

    private var separator: some View {
        Rectangle().fill(AppTheme.stroke).frame(width: 1, height: 16).padding(.horizontal, 5).accessibilityHidden(true)
    }

    // MARK: Buttons

    private func toggle(_ symbol: String, _ label: String, _ keys: String, _ state: FormattingState.Tri, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolbarGlyph(symbol: symbol, state: state)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help("\(label) (\(keys))")
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(keys))
        .accessibilityValue(Text(state == .mixed ? "Mixed" : ""))
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }

    private var linkButton: some View {
        toggle("link", f.link == nil ? "Add link" : "Edit link", "\u{2318}K", f.link == nil ? .off : .on) { model.beginLink() }
            .overlay(alignment: .topTrailing) {
                if headless && model.popover == .link {
                    HeadlessPopover { LinkPopoverContent(model: model) }.offset(x: 34, y: 30)
                }
            }
            .popover(isPresented: Binding(get: { !headless && model.popover == .link },
                                          set: { if !$0, model.popover == .link { model.popover = nil; model.linkDraft = nil } }),
                     arrowEdge: .bottom) {
                LinkPopoverContent(model: model)
            }
    }

    private var colorButton: some View {
        Button { model.popover = model.popover == .color ? nil : .color } label: {
            HStack(spacing: 3) {
                VStack(spacing: 1.5) {
                    Text("A").font(.system(size: 13.5, weight: .heavy, design: .serif)).foregroundStyle(AppTheme.text2)
                    RoundedRectangle(cornerRadius: 1).fill(currentColor).frame(width: 14, height: 3)
                }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(AppTheme.text3)
            }
            .frame(width: 36, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(model.popover == .color ? AppTheme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if headless && model.popover == .color {
                HeadlessPopover { ColorPopoverContent(model: model) }.offset(x: -108, y: 30)
            }
        }
        .help("Text colour (\u{21E7}\u{2318}C shows all colours)")
        .accessibilityLabel(Text("Text colour"))
        .accessibilityValue(Text(f.color.map { ComposerPalette.name($0) } ?? "Default"))
        .popover(isPresented: Binding(get: { !headless && model.popover == .color },
                                      set: { if !$0, model.popover == .color { model.popover = nil } }),
                 arrowEdge: .bottom) {
            ColorPopoverContent(model: model)
        }
    }

    private var currentColor: Color {
        if f.colorMixed { return AppTheme.text3 }
        return f.color.map { Color(hex: $0) } ?? AppTheme.text2
    }

    // MARK: Font and size

    private var fontMenu: some View {
        dropdown(f.fontLabel, width: 100, help: "Font", font: f.font) {
            ForEach(FontChoice.allCases, id: \.self) { choice in
                Button { model.perform(.font(choice)) } label: {
                    Text(choice.title).font(Font(choice.font(size: 13)))
                }
            }
        }
    }

    private var sizeMenu: some View {
        dropdown(f.sizeLabel, width: 82, help: "Size (\u{2318}+ bigger, \u{2318}\u{2212} smaller)", font: nil) {
            ForEach(SizeChoice.allCases, id: \.self) { size in
                Button(size.title) { model.perform(.size(size)) }
            }
        }
    }

    @ViewBuilder
    private func dropdown<Items: View>(_ title: String, width: CGFloat, help: String, font: FontChoice?,
                                       @ViewBuilder items: () -> Items) -> some View {
        let label = HStack(spacing: 4) {
            Text(title).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text).lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(AppTheme.text3)
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        if headless {
            label
        } else {
            Menu { items() } label: { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(help)
                .accessibilityLabel(Text("\(help), \(title)"))
        }
    }

    // MARK: Overflow

    @ViewBuilder
    private func overflow(_ fit: Fit) -> some View {
        let glyph = ToolbarGlyph(symbol: "ellipsis", state: .off)
        if headless {
            glyph
        } else {
            Menu {
                if fit == .minimal {
                    Menu("Font") { ForEach(FontChoice.allCases, id: \.self) { c in Button(c.title) { model.perform(.font(c)) } } }
                    Menu("Size") { ForEach(SizeChoice.allCases, id: \.self) { s in Button(s.title) { model.perform(.size(s)) } } }
                    Button("Strikethrough") { model.perform(.strikethrough) }
                    Button("Text Colour\u{2026}") { model.popover = .color }
                    Button("Bulleted List") { model.perform(.list(.bullet)) }
                    Button("Numbered List") { model.perform(.list(.number)) }
                    Divider()
                }
                Button("Decrease Indent") { model.perform(.outdent) }.disabled(!f.canOutdent)
                Button("Increase Indent") { model.perform(.indent) }
                Button("Quote Block") { model.perform(.quote) }
                Button("Add Link\u{2026}") { model.beginLink() }
                Button("Clear Formatting") { model.perform(.clearFormatting) }
            } label: { glyph }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More formatting")
                .accessibilityLabel(Text("More formatting"))
                .popover(isPresented: Binding(get: { !headless && model.popover == .link && fit != .full },
                                              set: { if !$0, model.popover == .link { model.popover = nil; model.linkDraft = nil } }),
                         arrowEdge: .bottom) {
                    LinkPopoverContent(model: model)
                }
        }
    }
}

/// Renders only: a popover as the system draws it over the window (ImageRenderer can't draw `.popover`): the
/// content on a rounded card with a hairline and a soft shadow.
private struct HeadlessPopover<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            .fixedSize()
    }
}

/// One toolbar glyph: 26 × 26, accent when on, a dash under it when mixed.
private struct ToolbarGlyph: View {
    let symbol: String
    let state: FormattingState.Tri

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(state == .on ? AppTheme.accent : AppTheme.text2)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(state == .on ? AppTheme.accentSoft : state == .mixed ? Color.white.opacity(0.06) : Color.clear))
            .overlay(alignment: .bottom) {
                if state == .mixed {
                    Capsule().fill(AppTheme.accent.opacity(0.8)).frame(width: 8, height: 2).padding(.bottom, 3)
                }
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Colours

enum ComposerPalette {
    /// Text colours (two rows), readable on white.
    static let text: [(UInt32, String)] = [
        (0x5F6368, "Grey"), (0xC5221F, "Red"), (0xE8710A, "Orange"), (0xB06000, "Amber"),
        (0x188038, "Green"), (0x12808C, "Teal"), (0x1967D2, "Blue"), (0x8430CE, "Purple"),
        (0x9AA0A6, "Light grey"), (0xEE675C, "Coral"), (0xFA903E, "Apricot"), (0xD9A400, "Gold"),
        (0x5BB974, "Leaf"), (0x4ECDE6, "Sky"), (0x669DF6, "Cornflower"), (0xC58AF9, "Lilac"),
    ]
    /// Highlights: soft tints.
    static let highlight: [(UInt32, String)] = [
        (0xFFF475, "Yellow"), (0xFFD8A8, "Peach"), (0xFDCFE8, "Pink"), (0xD7AEFB, "Lavender"),
        (0xCBF0F8, "Ice"), (0xA7FFEB, "Mint"), (0xCCFF90, "Lime"), (0xE8EAED, "Mist"),
    ]

    static func name(_ hex: UInt32) -> String {
        (text + highlight).first { $0.0 == hex }?.1 ?? String(format: "#%06X", hex)
    }
}

/// The colour popover: text colours, highlights, Default and "More colours…" (the system colour panel, ⇧⌘C).
struct ColorPopoverContent: View {
    @ObservedObject var model: ComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("TEXT COLOUR")
            grid(ComposerPalette.text, selected: model.formatting.color) { model.perform(.color($0)) }
            label("HIGHLIGHT")
            grid(ComposerPalette.highlight, selected: model.formatting.highlight) { model.perform(.highlight($0)) }
            HStack(spacing: 14) {
                Button("Default colour") {
                    model.perform(.color(nil))
                    model.perform(.highlight(nil))
                }
                .buttonStyle(.plain).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.accent)
                Spacer(minLength: 8)
                Button("More colours\u{2026}") { NSApp.orderFrontColorPanel(nil) }
                    .buttonStyle(.plain).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2)
            }
        }
        .padding(14)
        .frame(width: 252)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(AppTheme.font(10, .bold)).tracking(0.5).foregroundStyle(AppTheme.text3)
    }

    private func grid(_ colors: [(UInt32, String)], selected: UInt32?, pick: @escaping (UInt32) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<((colors.count + 7) / 8), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(Array(colors[(row * 8)..<min(colors.count, row * 8 + 8)].enumerated()), id: \.offset) { _, item in
                        Button { pick(item.0) } label: {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: item.0))
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(selected == item.0 ? Color.white : Color.white.opacity(0.12), lineWidth: selected == item.0 ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(item.1)
                        .accessibilityLabel(Text(item.1))
                        .accessibilityAddTraits(selected == item.0 ? .isSelected : [])
                    }
                }
            }
        }
    }
}

/// The link popover: the text shown and the address (http, https or mailto). Add, Cancel, Remove.
struct LinkPopoverContent: View {
    @ObservedObject var model: ComposerModel
    @Environment(\.headlessRender) private var headless
    @Local private var text = ""
    @Local private var url = ""
    @Local private var problem: String?
    @Local private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.linkDraft?.existing == true ? "Edit link" : "Add a link")
                .font(AppTheme.font(14, .heavy)).foregroundStyle(AppTheme.text)
            field("Text", text: $text, placeholder: "What the link says", value: headless ? model.linkDraft?.text ?? "" : text)
            field("Link", text: $url, placeholder: "https://… or name@example.com", value: headless ? model.linkDraft?.url ?? "" : url)
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(AppTheme.font(11.5, .semibold)).foregroundStyle(AppTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if model.linkDraft?.existing == true {
                    Button("Remove link") { model.removeLink() }
                        .buttonStyle(.plain).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.bad)
                }
                Spacer(minLength: 8)
                Button("Cancel") {
                    model.popover = nil
                    model.linkDraft = nil
                }
                .buttonStyle(.plain).font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                .keyboardShortcut(.cancelAction)
                Button(model.linkDraft?.existing == true ? "Update" : "Add link") {
                    problem = model.commitLink(text: text, url: url)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = model.linkDraft?.text ?? ""
            url = model.linkDraft?.url ?? ""
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3).frame(width: 34, alignment: .leading)
            Group {
                if headless {
                    Text(value.isEmpty ? placeholder : value)
                        .font(AppTheme.font(13)).foregroundStyle(value.isEmpty ? AppTheme.text3 : AppTheme.text)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: text)
                        .textFieldStyle(.plain)
                        .font(AppTheme.font(13))
                        .foregroundStyle(AppTheme.text)
                }
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        }
    }
}
