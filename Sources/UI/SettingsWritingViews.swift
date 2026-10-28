import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings → Mail → Writing (D-042) and the rich signature editor. The Writing block sits
// between the account blocks and the images block; it applies at once (new composers read it).

struct SettingsWritingBlock: View {
    @ObservedObject var model: SettingsMailModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "textformat").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                    Text("Writing").font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                }
                Text("How new mail and replies look to the people you write to.")
                    .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
            }
            row("Font") {
                fontMenu
                preview
            }
            row("Size") {
                SegmentPicker(options: SizeChoice.allCases.map { ($0, $0.title) },
                              selection: Binding(get: { model.writing.size }, set: { model.setWritingSize($0) }))
                    .accessibilityLabel(Text("Default size"))
            }
            row("Quotes") {
                SegmentPicker(options: [(MailQuoteRequest.Style.bar, RichMailSettings.quoteStyleTitle(.bar)),
                                        (.header, RichMailSettings.quoteStyleTitle(.header))],
                              selection: Binding(get: { model.writing.quoteStyle }, set: { model.setQuoteStyle($0) }))
                    .accessibilityLabel(Text("Quote style for replies"))
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Send plain text only").font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text)
                    Text(RichMailSettings.plainTextLine).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                ShellSwitch(isOn: Binding(get: { model.writing.plainTextOnly }, set: { model.setPlainTextOnly($0) }),
                            label: "Send plain text only")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3)
                .frame(width: 54, alignment: .leading)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
    }

    /// Each choice drawn in its own face.
    @ViewBuilder
    private var fontMenu: some View {
        let current = model.writing.font
        let label = HStack(spacing: 6) {
            Text(current.title).font(Font(current.font(size: 12.5))).foregroundStyle(AppTheme.text).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(AppTheme.text3)
        }
        .padding(.horizontal, 10)
        .frame(width: 168, height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        if headless {
            label
        } else {
            Menu {
                ForEach(FontChoice.allCases, id: \.self) { choice in
                    Button { model.setWritingFont(choice) } label: { Text(choice.title).font(Font(choice.font(size: 13))) }
                }
            } label: { label }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(Text("Default font, \(current.title)"))
        }
    }

    /// "Aa" in the chosen font and size on a small white sheet.
    private var preview: some View {
        Text("Hello from the lake house")
            .font(Font(model.writing.font.font(size: model.writing.size.points)))
            .foregroundStyle(Color(hex: 0x1D1B20))
            .lineLimit(1)
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white))
            .accessibilityHidden(true)
    }
}

// MARK: - Rich signature editor

/// Keeps the signature editor's text view and its formatting for the mini toolbar.
final class SignatureEditorBridge: ObservableObject {
    weak var view: ComposerTextView?
    @Published var formatting = FormattingState()
    @Published var linkOpen = false
    @Published var colorOpen = false

    @MainActor
    func perform(_ op: ComposerDocument.Op) { view?.perform(op) }
}

/// A 96 pt rich editor on a small white sheet with B, I, U, colour and link (Settings → Mail, per account).
struct RichSignatureEditor: View {
    @ObservedObject var model: SettingsMailModel
    let row: SettingsMailModel.Row
    @Environment(\.headlessRender) private var headless
    @Local private var bridge = SignatureEditorBridge()

    static let height: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignatureToolbar(bridge: bridge)
            sheet
        }
    }

    private var sheet: some View {
        GeometryReader { proxy in
            if headless {
                Image(nsImage: RichTextSnapshot.textSnapshot(row.signatureRich, width: proxy.size.width, height: Self.height, mode: .signature))
                    .resizable().frame(width: proxy.size.width, height: Self.height)
            } else {
                RichTextEditor(document: row.signatureRich, revision: row.richRevision, mode: .signature,
                               defaults: model.writing.documentDefaults,
                               onChange: { model.editRichSignature(row.id, $0) },
                               onSelection: { range, typing in
                                   let current = model.rows.first { $0.id == row.id }?.signatureRich ?? row.signatureRich
                                   bridge.formatting = ComposerDocument.formatting(current, selection: range, typing: typing,
                                                                                    defaults: model.writing.documentDefaults)
                               },
                               onRequestLink: { bridge.linkOpen = true },
                               formatting: { bridge.formatting },
                               register: { bridge.view = $0 })
            }
        }
        .frame(height: Self.height)
        .overlay(alignment: .topLeading) {
            if row.signatureRich.length == 0 {
                Text("No signature yet").font(.system(size: 13)).foregroundStyle(Color(hex: 0x8C8590))
                    .padding(.leading, 9).padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        .environment(\.colorScheme, .light)
        .accessibilityLabel(Text("Signature for \(row.account.tag)"))
    }
}

private struct SignatureToolbar: View {
    @ObservedObject var bridge: SignatureEditorBridge
    @Local private var url = ""
    @Local private var problem: String?
    @Local private var logoProblem: String?
    @Environment(\.headlessRender) private var headless

    var body: some View {
        HStack(spacing: 2) {
            glyph("bold", "Bold", bridge.formatting.bold) { bridge.perform(.bold) }
            glyph("italic", "Italic", bridge.formatting.italic) { bridge.perform(.italic) }
            glyph("underline", "Underline", bridge.formatting.underline) { bridge.perform(.underline) }
            Rectangle().fill(AppTheme.stroke).frame(width: 1, height: 14).padding(.horizontal, 4)
            glyph("paintpalette", "Text colour", bridge.formatting.color == nil ? .off : .on) { bridge.colorOpen = true }
                .popover(isPresented: Binding(get: { !headless && bridge.colorOpen }, set: { bridge.colorOpen = $0 }), arrowEdge: .bottom) {
                    palette
                }
            glyph("link", "Link", bridge.formatting.link == nil ? .off : .on) {
                url = bridge.formatting.link ?? ""
                bridge.linkOpen = true
            }
            .popover(isPresented: Binding(get: { !headless && bridge.linkOpen }, set: { bridge.linkOpen = $0 }), arrowEdge: .bottom) {
                linkForm
            }
            // A logo (PNG or JPEG, up to 200 KB), sent inline with every message from this account (D-042).
            glyph("photo", "Add a logo (PNG or JPEG, up to 200 KB)", .off) { addLogo() }
            if let logoProblem {
                Text(logoProblem).font(AppTheme.font(11)).foregroundStyle(AppTheme.warn).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }

    private func addLogo() {
        guard !headless, let view = bridge.view else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add Logo"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            switch SignatureLogo.attachment(url) {
            case .success(let run):
                logoProblem = nil
                view.insert(run, actionName: "Add Logo")
            case .failure(let why):
                logoProblem = why.description
            }
        }
    }

    private func glyph(_ symbol: String, _ label: String, _ state: FormattingState.Tri, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state == .on ? AppTheme.accent : AppTheme.text2)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(state == .on ? AppTheme.accentSoft : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(ComposerPalette.text.prefix(8).enumerated()), id: \.offset) { _, item in
                    Button {
                        bridge.perform(.color(item.0))
                        bridge.colorOpen = false
                    } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: item.0)).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain).help(item.1).accessibilityLabel(Text(item.1))
                }
            }
            Button("Default colour") {
                bridge.perform(.color(nil))
                bridge.colorOpen = false
            }
            .buttonStyle(.plain).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.accent)
        }
        .padding(12)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link the selected text").font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text)
            TextField("https://… or name@example.com", text: $url)
                .textFieldStyle(.plain).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text)
                .padding(.horizontal, 8).frame(width: 240, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
            if let problem {
                Text(problem).font(AppTheme.font(11)).foregroundStyle(AppTheme.warn).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if bridge.formatting.link != nil {
                    Button("Remove") {
                        bridge.perform(.link(nil))
                        bridge.linkOpen = false
                    }
                    .buttonStyle(.plain).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.bad)
                }
                Spacer()
                Button("Add link") {
                    guard ComposerDocument.composerLink(url) != nil else {
                        problem = ComposerLinkDraft.problem
                        return
                    }
                    problem = nil
                    bridge.perform(.link(url))
                    bridge.linkOpen = false
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 268)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
    }
}
