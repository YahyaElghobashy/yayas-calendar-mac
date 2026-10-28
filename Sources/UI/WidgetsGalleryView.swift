import SwiftUI

/// Widgets: every design, drawn live from the same views the widget compiles, with sample data,
/// plus the three clicks to place one (macOS gives apps no way to place widgets).
struct WidgetsGalleryView: View {
    @ObservedObject var shell: ShellModel

    var body: some View {
        ShellScroll {
            WidgetsGalleryContent(shell: shell)
        }
    }
}

struct WidgetsGalleryContent: View {
    @ObservedObject var shell: ShellModel
    @Environment(\.headlessRender) private var headless

    static let previewScale: CGFloat = 0.72

    /// Kinds shown as cards: the six named kinds, then Custom A–F once.
    private var entries: [WidgetKindSpec] { [WidgetKinds.agenda, WidgetKinds.day, WidgetKinds.upNext, WidgetKinds.month,
                                            WidgetKinds.inbox, WidgetKinds.combo, WidgetKinds.custom[0]] }

    var body: some View {
        // Renders pin the sample week and the fixed calendar; the live app shows the sample week starting today.
        let now = shell.fixedNow ?? (headless ? WidgetSample.fixedNow : Date())
        let data = WidgetSample.week(now: now, logos: Paths.logos)
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(title: "Widgets",
                      subtitle: "Make each widget yours: pick one, change how it looks, save. Your desktop catches up in a moment.")
            WidgetStudioView(model: shell.studio, now: now)
            HowToAddCard()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Every widget, every size").font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                    Text("Apple's widgets can't scroll, so these page. Pick a size, place it, done.")
                        .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                }
                Spacer(minLength: 16)
                SegmentPicker(options: [(WidgetStyle.Look.paper, "Light"), (.ink, "Dark")], selection: $shell.galleryLook)
            }
            .padding(.top, 6)
            ForEach(entries) { spec in
                GalleryKindCard(spec: spec, data: data, look: shell.galleryLook)
            }
        }
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 28)
        .onAppear { if !headless { shell.studio.reload() } }
    }
}

private struct HowToAddCard: View {
    var body: some View {
        ShellCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a widget in three clicks")
                    .font(AppTheme.font(15, .bold)).foregroundStyle(AppTheme.text)
                Text("macOS won't let me place widgets for you, so here's the shortcut.")
                    .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                step(1, "Right-click an empty spot on your desktop and choose **Edit Widgets**.")
                step(2, "Type **Yaya** in the search field at the top of the widget gallery.")
                step(3, "Pick a widget and a size, then drag it where you want it.")
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 10) {
            StepNumber(number: n, size: 22)
            Text(text).font(AppTheme.font(13)).foregroundStyle(AppTheme.text)
        }
    }
}

private struct GalleryKindCard: View {
    let spec: WidgetKindSpec
    let data: WidgetData
    let look: WidgetStyle.Look

    private var isCustom: Bool { if case .custom = spec.content { return true } else { return false } }

    var body: some View {
        let compactRow = spec.families.filter { [.small, .medium, .large].contains($0) }
        let wideRow = spec.families.filter { [.extraLarge, .extraLargePortrait].contains($0) }
        ShellCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isCustom ? "Custom Widget A–F" : spec.galleryName)
                        .font(AppTheme.font(15, .bold)).foregroundStyle(AppTheme.text)
                    Text(isCustom ? "Six widgets you point at any calendars and look. Until you set one up it says so."
                                  : spec.description)
                        .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                }
                if !compactRow.isEmpty { row(compactRow) }
                if !wideRow.isEmpty { row(wideRow) }
            }
        }
    }

    private func row(_ families: [Family]) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(families, id: \.self) { family in
                VStack(alignment: .leading, spacing: 6) {
                    preview(family)
                    Text(family.displayName).font(AppTheme.font(10.5, .medium)).foregroundStyle(AppTheme.text3)
                }
            }
        }
    }

    private func preview(_ family: Family) -> some View {
        let s = WidgetsGalleryContent.previewScale
        var style = WidgetStyle()
        style.look = look
        var shown = data
        if spec.content == .month, family != .extraLargePortrait {
            // Show a picked day next to today, as the Month design does.
            shown.selectedDay = WidgetCalendar.current.date(byAdding: .day, value: 2, to: data.selectedDay) ?? data.selectedDay
        }
        return KindView(spec: spec, family: family, data: shown, style: style)
            .environment(\.plainLinks, true)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: family.size.width * s, height: family.size.height * s, alignment: .topLeading)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}
