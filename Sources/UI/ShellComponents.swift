import SwiftUI

/// What the main window shows. One shared instance for the live window; renders make their own.
final class ShellModel: ObservableObject {
    static let shared = ShellModel()

    @Published var section: AppSection
    /// Light / Dark toggle of the Widgets gallery.
    @Published var galleryLook: WidgetStyle.Look
    /// The Calendar section's agenda and the Widgets section's Studio (renders pass fixture-backed ones).
    let calendar: CalendarSectionModel
    let studio: WidgetStudioModel
    /// The Inbox section and Settings → Mail.
    let inbox: InboxSectionModel
    let settingsMail: SettingsMailModel
    /// Settings → Menu bar.
    let menuBar: MenuBarSettingsModel
    /// Mail on (D-029: always, in the app); renders pin it off for the mail-off comparisons.
    let mailEnabled: () -> Bool
    /// Renders pin the clock (Monday 19 October 2026, 9:48 AM); nil = now.
    let fixedNow: Date?

    init(section: AppSection = .inbox, galleryLook: WidgetStyle.Look = .paper,
         calendar: CalendarSectionModel = CalendarSectionModel(), studio: WidgetStudioModel = WidgetStudioModel(),
         inbox: InboxSectionModel = InboxSectionModel(compose: { request in
             Task { @MainActor in ComposerWindowController.open(request) }
         }),
         settingsMail: SettingsMailModel = SettingsMailModel(),
         menuBar: MenuBarSettingsModel? = nil,
         mailEnabled: @escaping () -> Bool = { true },
         fixedNow: Date? = nil) {
        self.section = section
        self.galleryLook = galleryLook
        self.calendar = calendar
        self.studio = studio
        self.inbox = inbox
        self.settingsMail = settingsMail
        self.menuBar = menuBar ?? MenuBarSettingsModel()
        self.mailEnabled = mailEnabled
        self.fixedNow = fixedNow
    }
}

extension AppSection {
    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .calendar: return "Calendar"
        case .widgets: return "Widgets"
        case .accounts: return "Accounts"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .calendar: return "calendar"
        case .widgets: return "square.grid.2x2"
        case .accounts: return "person.2"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Headless rendering

private struct StillImageRenderKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside `--render`: ImageRenderer can't draw AppKit-backed views (ScrollView, system toggles),
    /// so views swap them for static stand-ins and skip live system queries.
    var headlessRender: Bool {
        get { self[StillImageRenderKey.self] }
        set { self[StillImageRenderKey.self] = newValue }
    }
}

/// A vertical ScrollView in the app; a top-aligned, clipped stack in headless renders.
struct ShellScroll<Content: View>: View {
    @Environment(\.headlessRender) private var headless
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if headless {
            // minHeight 0 makes the frame take the window's height instead of the content's, so the
            // content hangs from the top and the overflow is clipped (what a scroll view shows first).
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(.vertical) {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Building blocks (dark-app tokens)

struct ShellCard<Content: View>: View {
    var padding: CGFloat = 18
    let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(AppTheme.font(26, .heavy)).foregroundStyle(AppTheme.text)
            Text(subtitle).font(AppTheme.font(13)).foregroundStyle(AppTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Accent capsule, dark text: the primary button, in this app's teal.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.font(13, .bold))
            .foregroundStyle(AppTheme.accentText)
            .padding(.horizontal, 20).padding(.vertical, 9)
            .background(Capsule().fill(AppTheme.accent))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Numbered accent circle (onboarding steps, the widget how-to).
struct StepNumber: View {
    let number: Int
    var size: CGFloat = 26

    var body: some View {
        Text("\(number)")
            .font(AppTheme.font(size * 0.5, .heavy))
            .foregroundStyle(AppTheme.accentText)
            .frame(width: size, height: size)
            .background(Circle().fill(AppTheme.accent))
    }
}

/// A drawn switch: pure SwiftUI, so it renders headless and looks the same everywhere. A click toggles it;
/// with Full Keyboard Access on, Tab reaches it and Space toggles it (`.activate`: it never takes focus
/// on a click).
struct ShellSwitch: View {
    @Binding var isOn: Bool
    var enabled = true
    /// What VoiceOver calls it (the row's title).
    var label = ""

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AppTheme.accent : Color.white.opacity(0.14)).frame(width: 38, height: 22)
            Circle().fill(Color.white).frame(width: 18, height: 18).padding(2)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        }
        .frame(width: 38, height: 22)
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture {
            guard enabled else { return }
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        }
        .focusable(enabled, interactions: .activate)
        .onKeyPress(.space) {
            guard enabled else { return .ignored }
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .accessibilityAction(.default) {
            guard enabled else { return }
            isOn.toggle()
        }
    }
}

/// Two-option capsule picker (Light / Dark).
struct SegmentPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Text(option.1)
                    .font(AppTheme.font(12, selected ? .bold : .medium))
                    .foregroundStyle(selected ? AppTheme.accentText : AppTheme.text2)
                    .padding(.horizontal, 14).frame(height: 26)
                    .background(Capsule().fill(selected ? AppTheme.accent : Color.clear))
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = option.0 } }
                    .ycAccessibleButton(option.1, selected: selected) { selection = option.0 }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}
