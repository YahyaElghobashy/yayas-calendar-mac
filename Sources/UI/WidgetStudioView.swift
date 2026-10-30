import AppKit
import SwiftUI

/// Widget Studio (top of the Widgets section): the list of widgets on the left, its settings on the
/// right, and a live preview at real size below. Hand-rolled controls only (no List/Form).
struct WidgetStudioView: View {
    @ObservedObject var model: WidgetStudioModel
    /// Pinned in renders; nil = now.
    var now: Date?
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ShellCard(padding: 0) {
                HStack(alignment: .top, spacing: 0) {
                    kindList
                        .frame(width: 196, alignment: .topLeading)
                        .padding(.vertical, 14).padding(.horizontal, 10)
                    Rectangle().fill(AppTheme.stroke).frame(width: 1)
                    StudioSettings(model: model)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            StudioPreview(model: model, now: now ?? Date())
        }
    }

    private var kindList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("YOUR WIDGETS").font(AppTheme.font(10.5, .bold)).tracking(0.6).foregroundStyle(AppTheme.text3)
                .padding(.horizontal, 10).padding(.bottom, 6)
            // The Daily Digest (D-053) only while Yaya's Mail Helper is on this Mac.
            ForEach(WidgetKinds.all.filter { $0.content != .digest || MailHelperSession.shared.installed }) { spec in
                StudioKindRow(title: model.listName(spec), symbol: Self.symbol(spec), selected: spec.kind == model.selectedKind) {
                    model.select(spec.kind)
                }
                if spec.kind == WidgetKinds.combo.kind {
                    Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 10)
                }
            }
        }
    }

    static func symbol(_ spec: WidgetKindSpec) -> String {
        switch spec.content {
        case .agenda: return "list.bullet.rectangle"
        case .upNext: return "clock"
        case .month: return "calendar"
        case .inbox: return "tray"
        case .combo: return "rectangle.split.2x1"
        case .day: return "calendar.day.timeline.left"
        case .digest: return "newspaper"
        case .custom(let letter): return "\(letter.lowercased()).square"
        }
    }
}

private struct StudioKindRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.text2).frame(width: 18)
                Text(title).font(AppTheme.font(12.5, selected ? .bold : .medium))
                    .foregroundStyle(selected ? AppTheme.text : AppTheme.text2).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : (hover ? Color.white.opacity(0.05) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct StudioSettings: View {
    @ObservedObject var model: WidgetStudioModel
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.listName(model.spec)).font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                Text(model.isCustom ? "Name it, pick what it shows and whose calendars, then make it look right."
                                    : model.spec.description)
                    .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isCustom { customRows }
            row("Look") {
                SegmentPicker(options: WidgetStudioModel.lookChoices,
                              selection: Binding(get: { model.draft.style.look }, set: { model.setLook($0) }))
            }
            row("Font") {
                SegmentPicker(options: WidgetStudioModel.fontChoices,
                              selection: Binding(get: { model.draft.style.typeface }, set: { model.setFont($0) }))
            }
            row("Text size") {
                SegmentPicker(options: WidgetStudioModel.sizeChoices,
                              selection: Binding(get: { model.draft.style.textSize }, set: { model.setTextSize($0) }))
            }
            if model.showsRange {
                row("Shows") {
                    SegmentPicker(options: WidgetStudioModel.rangeChoices,
                                  selection: Binding(get: { model.draft.rangeDays }, set: { model.setRange($0) }))
                }
            }
            row("Calendar logos") {
                ShellSwitch(isOn: Binding(get: { model.draft.style.showLogos }, set: { model.setShowLogos($0) }), label: "Calendar logos")
            }
            row("24-hour clock") {
                ShellSwitch(isOn: Binding(get: { model.draft.style.use24Hour }, set: { model.setUse24Hour($0) }), label: "24-hour clock")
            }
            saveRow.padding(.top, 4)
        }
    }

    @ViewBuilder
    private var customRows: some View {
        row("Name") {
            StudioTextField(placeholder: "Work, Family, Clients only…", text: model.draft.title ?? "",
                            maxLength: WidgetStudioModel.maxNameLength) { model.setName($0) }
        }
        row("What it shows", alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(Array(WidgetStudioModel.contentChoices.enumerated()), id: \.offset) { _, choice in
                        StudioChip(title: choice.1, selected: model.draft.customContent == choice.0,
                                   enabled: model.isAvailable(choice.0)) { model.setContent(choice.0) }
                    }
                }
                if !model.mailAvailable {
                    Text(MailOffCopy.studioNote)
                        .font(AppTheme.font(11)).foregroundStyle(AppTheme.text3)
                }
                if model.draft.customContent == nil {
                    Text("Pick one and this widget stops saying \u{201C}Not set up yet\u{201D}.")
                        .font(AppTheme.font(11)).foregroundStyle(AppTheme.accent)
                }
            }
        }
        row(model.effectiveContent == .inbox ? "Inboxes" : (model.effectiveContent == .combo ? "Accounts" : "Calendars"),
            alignment: .top) { StudioAccounts(model: model) }
    }

    private var saveRow: some View {
        HStack(spacing: 12) {
            Button("Save changes") { model.save() }
                .buttonStyle(PrimaryButtonStyle())
                .opacity(model.isDirty ? 1 : 0.45)
                .disabled(!model.isDirty)
            if model.isDirty {
                Button("Undo changes") { model.revert() }
                    .buttonStyle(.plain)
                    .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
            }
            switch model.status {
            case .saved:
                Label("Saved. Your widget catches up in a moment.", systemImage: "checkmark.circle.fill")
                    .font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.good)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.bad)
            case .idle:
                if model.isDirty {
                    Text("Not saved yet").font(AppTheme.font(12)).foregroundStyle(AppTheme.text3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row<Control: View>(_ title: String, alignment: VerticalAlignment = .center,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: alignment, spacing: 14) {
            Text(title).font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                .frame(width: 112, alignment: .leading)
                .padding(.top, alignment == .top ? 5 : 0)
            control()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(title))
            Spacer(minLength: 0)
        }
    }
}

/// A capsule choice; disabled ones are greyed.
private struct StudioChip: View {
    let title: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Text(title)
            .font(AppTheme.font(12, selected ? .bold : .medium))
            .foregroundStyle(selected ? AppTheme.accentText : (enabled ? AppTheme.text : AppTheme.text3))
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(selected ? AppTheme.accent : Color.white.opacity(enabled ? 0.07 : 0.03)))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : AppTheme.stroke, lineWidth: 1))
            .opacity(enabled ? 1 : 0.6)
            .contentShape(Capsule())
            .onTapGesture { if enabled { action() } }
            .help(enabled ? "" : MailOffCopy.studioChipHelp)
            .ycAccessibleButton(title, value: enabled ? nil : MailOffCopy.studioChipHelp, selected: selected) { if enabled { action() } }
    }
}

/// "All accounts (includes new ones)" or a pick of accounts.
private struct StudioAccounts: View {
    @ObservedObject var model: WidgetStudioModel

    var body: some View {
        let directory = AccountDirectory.current()
        let ids = directory.accounts.map(\.id)
        VStack(alignment: .leading, spacing: 7) {
            radio("All accounts (includes new ones)", on: model.draft.accountIds == nil) { model.setAllAccounts() }
            radio("Only the ones I pick", on: model.draft.accountIds != nil) {
                model.pickOnly(ids)
            }
            if directory.accounts.isEmpty {
                Text("Connect an account in Accounts first.").font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                    .padding(.leading, 26)
            } else if model.draft.accountIds != nil {
                ForEach(directory.accounts) { account in
                    HStack(spacing: 8) {
                        StudioCheck(on: model.isPicked(account.id))
                        PeekAccountChip(account: account, size: 16)
                        Text(account.name).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2).lineLimit(1)
                    }
                    .padding(.leading, 26)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleAccount(account.id, all: ids) }
                    .ycAccessibleButton("\(account.tag), \(account.name)", value: model.isPicked(account.id) ? "Included" : "Not included",
                                        selected: model.isPicked(account.id)) { model.toggleAccount(account.id, all: ids) }
                }
            }
        }
    }

    private func radio(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().strokeBorder(on ? AppTheme.accent : AppTheme.text3, lineWidth: 1.5).frame(width: 16, height: 16)
                if on { Circle().fill(AppTheme.accent).frame(width: 8, height: 8) }
            }
            .frame(width: 18)
            Text(title).font(AppTheme.font(12.5, on ? .semibold : .regular)).foregroundStyle(AppTheme.text)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .ycAccessibleButton(title, selected: on, action: action)
    }
}

private struct StudioCheck: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(on ? AppTheme.accent : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(on ? Color.clear : AppTheme.text3, lineWidth: 1.5))
            .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(AppTheme.accentText).opacity(on ? 1 : 0))
            .frame(width: 16, height: 16)
    }
}

/// A text field in the app; its text (or placeholder) in headless renders, where AppKit-backed fields
/// draw as a placeholder box.
struct StudioTextField: View {
    let placeholder: String
    let text: String
    var maxLength = 40
    let commit: (String) -> Void
    @Environment(\.headlessRender) private var headless

    var body: some View {
        Group {
            if headless {
                Text(text.isEmpty ? placeholder : text)
                    .font(AppTheme.font(13, .medium))
                    .foregroundStyle(text.isEmpty ? AppTheme.text3 : AppTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: Binding(get: { text }, set: { commit(String($0.prefix(maxLength))) }))
                    .textFieldStyle(.plain)
                    .accessibilityLabel(Text("Name"))
                    .font(AppTheme.font(13, .medium))
                    .foregroundStyle(AppTheme.text)
            }
        }
        .padding(.horizontal, 10).frame(width: 260, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
    }
}

/// The live preview at real point sizes, with a size picker.
private struct StudioPreview: View {
    @ObservedObject var model: WidgetStudioModel
    let now: Date
    @Environment(\.headlessRender) private var headless

    var body: some View {
        let dark = headless ? false : Self.macIsDark
        let (data, style) = model.preview(now: now, dark: dark)
        let family = model.families.contains(model.previewFamily) ? model.previewFamily : (model.families.first ?? .large)
        ShellCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preview").font(AppTheme.font(15, .bold)).foregroundStyle(AppTheme.text)
                        Text("Real size, with a sample week. Your desktop shows your own meetings.")
                            .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                    }
                    Spacer(minLength: 12)
                    SegmentPicker(options: model.families.map { ($0, $0.shortLabel) },
                                  selection: Binding(get: { family }, set: { model.previewFamily = $0 }))
                }
                KindView(spec: model.spec, family: family, data: data, style: style)
                    .environment(\.plainLinks, true)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
        }
    }

    /// "Match Mac": the system appearance, not the app's forced-dark window.
    static var macIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
}

extension Family {
    /// Size picker labels.
    var shortLabel: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "XL"
        case .extraLargePortrait: return "XL Portrait"
        }
    }
}
