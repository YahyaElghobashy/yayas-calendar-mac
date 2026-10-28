import SwiftUI
import WidgetKit

/// What one timeline entry draws from.
enum KindSource {
    /// Gallery previews only (`context.isPreview`): the sample week.
    case sample
    /// `widget/<kind>.json`, decoded and mapped once per timeline.
    case snapshot(SnapshotModel)
    /// On the desktop with no snapshot yet: the friendly "Open Yaya's Calendar" card. Never sample data.
    case missing
}

struct KindEntry: TimelineEntry {
    let date: Date
    let spec: WidgetKindSpec
    let source: KindSource

    var stateName: String {
        switch source {
        case .sample: return "sample"
        case .missing: return "missing"
        case .snapshot(let model):
            switch model.cardState {
            case .content: return model.snapshot.health.state.rawValue
            case .noSnapshot: return "missing"
            case .noAccounts: return "noAccounts"
            case .setup: return "setup"
            case .mailComingSoon: return "mailComingSoon"
            }
        }
    }
}

/// Reads `widget/<kind>.json` (the data layer writes it atomically, D-014) and plans entries at every
/// moment this family's drawing changes on its own (TimelinePlan): the shown meetings' starts/ends and
/// Join countdown, midnight, `pageResetAt`, the stale boundary. ≤16 entries (WidgetKit lays out every
/// entry before showing one); reload at min(last entry, now + 6 h), then ≤3 settle entries in case it
/// doesn't. The app reloads the timeline whenever the snapshot changes, so this never polls.
struct KindProvider: TimelineProvider {
    let spec: WidgetKindSpec

    func placeholder(in context: Context) -> KindEntry {
        KindEntry(date: Date(), spec: spec, source: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (KindEntry) -> Void) {
        let now = Date()
        let entry = KindEntry(date: now, spec: spec, source: context.isPreview ? .sample : load())
        trace(context, source: "snapshot", state: entry.stateName, entries: 1)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KindEntry>) -> Void) {
        let now = Date()
        if context.isPreview {
            trace(context, source: "timeline", state: "sample", entries: 1)
            completion(Timeline(entries: [KindEntry(date: now, spec: spec, source: .sample)],
                                policy: .after(now.addingTimeInterval(15 * 60))))
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        BodyTrace.refresh()
        let source = load()
        guard case .snapshot(let model) = source else {
            // No file yet: the app reloads us when it writes one; look again in an hour regardless.
            trace(context, source: "timeline", state: "missing", entries: 1)
            completion(Timeline(entries: [KindEntry(date: now, spec: spec, source: .missing)],
                                policy: .after(now.addingTimeInterval(3600))))
            return
        }
        let plan = TimelinePlan.timeline(now: now, model: model, spec: spec, family: Family(context.family))
        let entries = plan.entries.map { KindEntry(date: $0, spec: spec, source: source) }
        let reload = plan.reload
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        trace(context, source: "timeline", state: entries.first?.stateName ?? "-", entries: entries.count,
              extra: ["ms": String(format: "%.1f", ms), "reload-s": "\(Int(reload.timeIntervalSince(now)))"])
        completion(Timeline(entries: entries, policy: .after(reload)))
    }

    private func load() -> KindSource {
        guard let snapshot = WidgetSnapshot.read(kind: spec.kind) else { return .missing }
        return .snapshot(SnapshotModel(snapshot))
    }

    private func trace(_ context: Context, source: String, state: String, entries: Int, extra: [String: String] = [:]) {
        Trace.widget("render", [
            "kind": spec.kind,
            "family": Family(context.family).short,
            "w": "\(Int(context.displaySize.width.rounded()))",
            "h": "\(Int(context.displaySize.height.rounded()))",
            "src": source,
            "state": state,
            "entries": "\(entries)",
            "preview": context.isPreview ? "1" : "0",
            "ms": extra["ms"] ?? "-",
            "reload-s": extra["reload-s"] ?? "-",
        ])
    }
}

/// Draws the shared design at its nominal size, scaled to the size WidgetKit actually gives us (measured:
/// the nominal sizes, so the scale is normally 1). Everything time-relative comes from the
/// entry date.
struct KindEntryView: View {
    let entry: KindEntry
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    private struct Resolved {
        var data: WidgetData
        var style: WidgetStyle
        var page: Int
    }

    private func resolve(_ family: Family) -> Resolved {
        let dark = colorScheme == .dark
        switch entry.source {
        case .sample:
            var style = WidgetStyle()
            style.look = dark ? .ink : .paper
            return Resolved(data: WidgetSample.week(now: entry.date, logos: Paths.logos), style: style, page: 1)
        case .missing:
            var style = WidgetStyle()
            style.look = dark ? .ink : .paper
            return Resolved(data: .card(.noSnapshot, now: entry.date), style: style, page: 1)
        case .snapshot(let model):
            return Resolved(data: model.data(at: entry.date), style: model.style(dark: dark),
                            page: model.page(family: family, at: entry.date))
        }
    }

    var body: some View {
        let family = Family(widgetFamily)
        let _ = BodyTrace.note(entry, family: family, mono: renderingMode != .fullColor, dark: colorScheme == .dark)
        let resolved = resolve(family)
        let palette = resolved.style.palette
        GeometryReader { geo in
            let scale = min(geo.size.width / family.size.width, geo.size.height / family.size.height)
            KindView(spec: entry.spec, family: family, data: resolved.data, style: resolved.style, page: resolved.page)
                .scaleEffect(scale > 0 ? scale : 1, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .environment(\.widgetMono, renderingMode != .fullColor)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Live check of how many views WidgetKit builds per reload (entries × variants): while the file
/// `widget/trace-bodies` exists, every `KindEntryView.body` writes one `widget body` trace line. Off by
/// default; the provider looks for the file once per timeline.
enum BodyTrace {
    nonisolated(unsafe) static var enabled = false

    static func refresh() {
        enabled = FileManager.default.fileExists(atPath: Paths.widget.appendingPathComponent("trace-bodies").path)
    }

    static func note(_ entry: KindEntry, family: Family, mono: Bool, dark: Bool) {
        guard enabled else { return }
        Trace.widget("body", ["kind": entry.spec.kind, "family": family.short, "entry": "\(Trace.millis(entry.date))",
                              "mode": mono ? "mono" : "full", "dark": dark ? "1" : "0"])
    }
}
