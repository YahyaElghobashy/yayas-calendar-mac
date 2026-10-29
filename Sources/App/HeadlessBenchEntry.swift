// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import SwiftUI
import WidgetKit

// What the extension does per timeline entry, for `--bench` (HeadlessBench). Kept in step with
// Sources/Widget/KindProvider.swift: the bench must time exactly the extension's path.

/// The extension's `KindEntryView` without WidgetKit's environment: the entry is resolved inside
/// `body`, then GeometryReader + scale + KindView, real `Link`s, the container background.
struct BenchEntry: View {
    let spec: WidgetKindSpec
    let family: Family
    let model: SnapshotModel
    let date: Date

    /// Experiments (`YC_BENCH_VARIANT`): `nogeo` draws KindView without the GeometryReader + scale,
    /// `plain` draws links as plain views. Unset = exactly the extension's path.
    static let variant = ProcessInfo.processInfo.environment["YC_BENCH_VARIANT"] ?? ""

    var body: some View {
        let data = model.data(at: date)
        let style = model.style(dark: false)
        let page = model.page(family: family, at: date)
        let palette = style.palette
        Group {
            if Self.variant == "nogeo" {
                KindView(spec: spec, family: family, data: data, style: style, page: page)
            } else {
                GeometryReader { geo in
                    let scale = min(geo.size.width / family.size.width, geo.size.height / family.size.height)
                    KindView(spec: spec, family: family, data: data, style: style, page: page)
                        .scaleEffect(scale > 0 ? scale : 1, anchor: .topLeading)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
        }
        .environment(\.widgetTone, .color)
        .environment(\.plainLinks, Self.variant == "plain")
        .containerBackground(for: .widget) {
            LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The extension's `getTimeline` entry dates (planned + settle entries: WidgetKit lays out every one).
enum BenchPlan {
    static func entryDates(now: Date, model: SnapshotModel, spec: WidgetKindSpec, family: Family) -> [Date] {
        TimelinePlan.timeline(now: now, model: model, spec: spec, family: family).entries
    }
}
#endif
