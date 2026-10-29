import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Small hand-rolled pieces for the accounts screens. Everything is drawn with SwiftUI shapes (no
// List/Form/Menu/Toggle switch/TextField at rest), so it looks the same in the app and in headless
// ImageRenderer captures, and nothing mis-renders with the Xcode-less toolchain.

/// Headless renders drop the ScrollView (AppKit-backed, renders blank in ImageRenderer).
private struct AccountsStaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var accountsStaticRender: Bool {
        get { self[AccountsStaticRenderKey.self] }
        set { self[AccountsStaticRenderKey.self] = newValue }
    }
}

/// `.onDrop` installs an AppKit drop target, which ImageRenderer draws as a "not supported" box, so
/// headless renders skip it.
struct AccountsDropTarget: ViewModifier {
    let types: [UTType]
    @Binding var isTargeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    @Environment(\.accountsStaticRender) private var staticRender

    func body(content: Content) -> some View {
        if staticRender {
            content
        } else {
            content.onDrop(of: types, isTargeted: $isTargeted, perform: perform)
        }
    }
}

extension View {
    func accountsDropTarget(_ types: [UTType], isTargeted: Binding<Bool>,
                            perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        modifier(AccountsDropTarget(types: types, isTargeted: isTargeted, perform: perform))
    }
}

enum AccountsKit {
    static let cardRadius: CGFloat = 16
    static let logoRadius: CGFloat = 10

    /// Accent capsule with near-black text: the one loud button per view.
    struct PrimaryButton: ButtonStyle {
        var compact = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(AppTheme.font(compact ? 11.5 : 12.5, .bold))
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, compact ? 11 : 16)
                .padding(.vertical, compact ? 5 : 8)
                .background(Capsule().fill(AppTheme.accent))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(Capsule())
        }
    }

    /// Quiet capsule: white 0.08 fill, white 0.12 stroke.
    struct SecondaryButton: ButtonStyle {
        var compact = false
        var tint: Color = AppTheme.text
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(AppTheme.font(compact ? 11.5 : 12.5, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 5 : 8)
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.08)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                .contentShape(Capsule())
        }
    }

    /// Text-only button for small inline actions ("Check again").
    struct LinkButton: ButtonStyle {
        var tint: Color = AppTheme.accent
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(AppTheme.font(11.5, .semibold))
                .foregroundStyle(tint.opacity(configuration.isPressed ? 0.6 : 1))
                .contentShape(Rectangle())
        }
    }

    /// A round icon button (reorder arrows, the ⋯ menu).
    struct IconButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppTheme.text2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.06)))
                .contentShape(Circle())
        }
    }

    /// A switch drawn with shapes; label on the left.
    struct Switch: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 8) {
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(configuration.isOn ? AppTheme.accent : Color.white.opacity(0.14))
                            .frame(width: 28, height: 16)
                        Circle()
                            .fill(configuration.isOn ? Color.black.opacity(0.85) : AppTheme.text.opacity(0.85))
                            .frame(width: 12, height: 12)
                            .padding(.horizontal, 2)
                    }
                    configuration.label
                        .font(AppTheme.font(12, .medium))
                        .foregroundStyle(AppTheme.text2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(Text(configuration.isOn ? "On" : "Off"))
        }
    }

    struct Card<Content: View>: View {
        var padding: CGFloat = 18
        @ViewBuilder var content: Content

        var body: some View {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).fill(AppTheme.card))
                .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).strokeBorder(AppTheme.stroke))
        }
    }

    /// Status dot with a soft glow in its own colour.
    struct Dot: View {
        let color: Color
        var body: some View {
            Circle().fill(color).frame(width: 7, height: 7).shadow(color: color.opacity(0.7), radius: 3)
        }
    }

    struct TagChip: View {
        let text: String
        let color: Color
        var body: some View {
            Text(text)
                .font(AppTheme.font(10.5, .bold))
                .tracking(0.4)
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(color.opacity(0.16)))
                .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.7))
        }
    }

    struct SectionLabel: View {
        let text: String
        var body: some View {
            Text(text.uppercased())
                .font(AppTheme.font(10.5, .semibold))
                .tracking(0.6)
                .foregroundStyle(AppTheme.text3)
        }
    }

    /// Text that turns into a field on click. At rest it is plain Text (renders headlessly); the field
    /// commits on Return and reverts on Escape or an empty value.
    struct EditableText: View {
        let value: String
        var font: Font = AppTheme.font(15, .bold)
        var color: Color = AppTheme.text
        var maxLength = 40
        var placeholder = ""
        var help = "Click to rename"
        let commit: (String) -> Void

        @Local private var editing = false
        @Local private var draft = ""
        @Local private var hovering = false

        var body: some View {
            if editing {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AppTheme.accent.opacity(0.6)))
                    .frame(maxWidth: 260)
                    .onSubmit(finish)
                    .onExitCommand { editing = false }
                    .onChange(of: draft) { _, new in
                        if new.count > maxLength { draft = String(new.prefix(maxLength)) }
                    }
            } else {
                Button {
                    draft = value
                    editing = true
                } label: {
                    HStack(spacing: 5) {
                        Text(value).font(font).foregroundStyle(color).lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppTheme.text3)
                            .opacity(hovering ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(help)
                .accessibilityLabel(Text(value))
                .accessibilityHint(Text(help.replacingOccurrences(of: "Click", with: "Press")))
            }
        }

        private func finish() {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != value { commit(trimmed) }
            editing = false
        }
    }

    /// The ⋯ button. Its label is plain SwiftUI; the menu is a real NSMenu popped up at the pointer,
    /// which avoids SwiftUI's `Menu` (an AppKit pop-up button that renders as a blank box headlessly).
    struct PopUpMenuButton: View {
        struct Item {
            let title: String
            var enabled = true
            var destructive = false
            let action: () -> Void
            /// A submenu (Join with Yaya's Murmur ▸ Home lab / MacBook); its own action is never called.
            var children: [Item] = []
            static var separator: Item { Item(title: "-", action: {}) }
        }

        let items: () -> [Item]
        /// What VoiceOver calls the ⋯ button.
        var label = "More actions"

        var body: some View {
            Button {
                MenuPresenter.show(items())
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(IconButton())
            .help("More")
            .accessibilityLabel(Text(label))
        }
    }

    /// A menu at the pointer (the ⋯ button; the Fathom pickers on the account card and in the Event Peek).
    @MainActor
    enum MenuPresenter {
        final class Target: NSObject {
            let action: () -> Void
            init(_ action: @escaping () -> Void) { self.action = action }
            @objc func fire(_ sender: Any?) { action() }
        }

        static func show(_ items: [PopUpMenuButton.Item]) {
            var targets: [Target] = []
            let menu = build(items, &targets)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            withExtendedLifetime(targets) {}
        }

        private static func build(_ items: [PopUpMenuButton.Item], _ targets: inout [Target]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                if item.title == "-" {
                    menu.addItem(.separator())
                    continue
                }
                if !item.children.isEmpty {
                    let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    entry.isEnabled = item.enabled
                    entry.submenu = build(item.children, &targets)
                    menu.addItem(entry)
                    continue
                }
                let target = Target(item.action)
                targets.append(target)
                let entry = NSMenuItem(title: item.title, action: #selector(Target.fire(_:)), keyEquivalent: "")
                entry.target = target
                entry.isEnabled = item.enabled
                if item.destructive {
                    entry.attributedTitle = NSAttributedString(string: item.title,
                                                               attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(entry)
            }
            return menu
        }
    }

    /// The account's logo, or a dashed "No logo" placeholder. Drop an image on it to change it.
    struct LogoBadge: View {
        let image: NSImage?
        var size: CGFloat = 44
        var busy = false
        var tint: Color = AppTheme.text3

        var body: some View {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(size * 0.12)
                        .frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: logoRadius, style: .continuous).fill(Color.white))
                        .clipShape(RoundedRectangle(cornerRadius: logoRadius, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: logoRadius, style: .continuous)
                        .strokeBorder(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: size, height: size)
                        .overlay(
                            Text("No logo")
                                .font(AppTheme.font(size * 0.2, .semibold))
                                .foregroundStyle(tint)
                                .multilineTextAlignment(.center)
                        )
                }
                if busy {
                    RoundedRectangle(cornerRadius: logoRadius, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: size, height: size)
                        .overlay(Text("\u{2026}").font(AppTheme.font(16, .bold)).foregroundStyle(AppTheme.text))
                }
            }
            .frame(width: size, height: size)
        }
    }

    /// Eight round swatches; the chosen one gets a ring.
    struct SwatchPicker: View {
        let selected: UInt32
        let choose: (UInt32) -> Void

        var body: some View {
            HStack(spacing: 7) {
                ForEach(AppTheme.accountSwatches, id: \.self) { hex in
                    Button {
                        choose(hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 16, height: 16)
                            .padding(2.5)
                            .overlay(Circle().strokeBorder(hex == selected ? AppTheme.text : .clear, lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(SwatchPicker.name(hex)))
                    .accessibilityAddTraits(hex == selected ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Colour"))
        }

        /// VoiceOver names for `AppTheme.accountSwatches`, in order.
        static func name(_ hex: UInt32) -> String {
            let names: [UInt32: String] = [0x8FB4C4: "Slate blue", 0xB8A99A: "Sand", 0xC9A3E6: "Lilac", 0xE0A35C: "Amber",
                                           0xE07A80: "Rose", 0x8DBA74: "Sage", 0x7F96E8: "Periwinkle", 0xD2A6C6: "Orchid"]
            return names[hex] ?? "Colour"
        }
    }

    static func toneColor(_ tone: AccountsNotice.Tone) -> Color {
        switch tone {
        case .info: return AppTheme.text2
        case .good: return AppTheme.good
        case .warn: return AppTheme.warn
        }
    }

    static func healthColor(_ state: HealthState) -> Color {
        switch state {
        case .ok: return AppTheme.good
        case .checking: return AppTheme.accent
        case .reauthNeeded, .keychainLocked, .setupNeeded: return AppTheme.warn
        case .adminBlocked, .failing: return AppTheme.bad
        case .offline, .unknown: return AppTheme.text3
        }
    }
}

/// "Ask your admin": what to send a Workspace admin who blocks the app.
struct AdminKitView: View {
    let clientID: String?
    let copyClientID: () -> Void
    let copyMessage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AccountsKit.SectionLabel(text: "Ask your admin")
            Text("Your Google Workspace admin can allow me in a minute:")
                .font(AppTheme.font(12))
                .foregroundStyle(AppTheme.text2)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(AdminKit.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(AppTheme.font(10.5, .bold))
                            .foregroundStyle(AppTheme.accentText)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(AppTheme.accent))
                        Text(step)
                            .font(AppTheme.font(12))
                            .foregroundStyle(AppTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                Text(clientID ?? "Set up Google sign-in first")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppTheme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.25)))
                Button("Copy client ID", action: copyClientID)
                    .buttonStyle(AccountsKit.SecondaryButton(compact: true))
                    .disabled(clientID == nil)
                Button("Copy message", action: copyMessage)
                    .buttonStyle(AccountsKit.SecondaryButton(compact: true))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.bad.opacity(0.35)))
    }
}
