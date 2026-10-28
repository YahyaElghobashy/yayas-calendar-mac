import SwiftUI
import WidgetKit

// Intent-free on purpose (D-004): StaticConfiguration only, no AppIntents import, no
// Metadata.appintents. Every tap is a Link to yayacal://, handled by the resident menu-bar agent.

@main
struct YayasCalendarWidgets: WidgetBundle {
    init() {
        Trace.widget("bundle-init", ["pid": "\(getpid())"])
        // A long-lived extension keeps grouping days in the Mac's current time zone.
        WidgetCalendar.followSystemChanges()
    }

    // A bundle block takes at most 10 widgets, so the six Custom kinds come from a nested bundle.
    // Gallery order = WidgetKinds.all (Agenda, Day, Up Next, …).
    var body: some Widget {
        AgendaKindWidget()
        DayKindWidget()
        UpNextKindWidget()
        MonthKindWidget()
        InboxKindWidget()
        ComboKindWidget()
        CustomKindWidgets().body
    }
}

struct CustomKindWidgets: WidgetBundle {
    var body: some Widget {
        CustomAWidget()
        CustomBWidget()
        CustomCWidget()
        CustomDWidget()
        CustomEWidget()
        CustomFWidget()
    }
}

// `Widget` requires `init()`, so each kind is its own small type over one shared configuration.
struct AgendaKindWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.agenda) } }
struct DayKindWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.day) } }
struct UpNextKindWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.upNext) } }
struct MonthKindWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.month) } }
struct InboxKindWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.inbox) } }
struct ComboKindWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.combo) } }
struct CustomAWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.custom[0]) } }
struct CustomBWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.custom[1]) } }
struct CustomCWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.custom[2]) } }
struct CustomDWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.custom[3]) } }
struct CustomEWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.custom[4]) } }
struct CustomFWidget: Widget { var body: some WidgetConfiguration { KindConfiguration.make(WidgetKinds.custom[5]) } }

enum KindConfiguration {
    static func make(_ spec: WidgetKindSpec) -> some WidgetConfiguration {
        StaticConfiguration(kind: spec.kind, provider: KindProvider(spec: spec)) { entry in
            KindEntryView(entry: entry)
        }
        .configurationDisplayName(spec.galleryName)
        .description(spec.description)
        .supportedFamilies(widgetFamilies(spec.families))
        .contentMarginsDisabled()
    }

    /// Extra Large Portrait exists from macOS 27; the app targets 26, so it is added only when available.
    static func widgetFamilies(_ families: [Family]) -> [WidgetFamily] {
        families.compactMap { family -> WidgetFamily? in
            switch family {
            case .small: return .systemSmall
            case .medium: return .systemMedium
            case .large: return .systemLarge
            case .extraLarge: return .systemExtraLarge
            case .extraLargePortrait:
                if #available(macOS 27, *) { return .systemExtraLargePortrait }
                return nil
            }
        }
    }
}

extension Family {
    init(_ family: WidgetFamily) {
        if #available(macOS 27, *), family == .systemExtraLargePortrait {
            self = .extraLargePortrait
            return
        }
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemExtraLarge: self = .extraLarge
        default: self = .large
        }
    }
}
