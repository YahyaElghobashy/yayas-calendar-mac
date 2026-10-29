// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import SwiftUI

/// `--bench` cases for the Day design drawn directly (the Day kind's snapshot cases are in HeadlessBench):
/// the 20-meeting day (`DaySample.twenty`, with the cast badges) drawn at the moments a timeline would plan — now,
/// then every start and end still ahead today, ≤16 — through the extension's path (GeometryReader +
/// scale + real Links + container background, like `BenchEntry`). The Agenda over the same meetings
/// and moments is timed alongside, so per-entry numbers compare like for like.
@MainActor
enum DayBench {
    static func run(now: Date, passes: Int, quick: Bool) -> [[String: Any]] {
        let meetings = DaySample.twenty(logos: WidgetSample.badges)
        let cal = WidgetCalendar.current
        let dayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let moments = Set(meetings.flatMap { [$0.start, $0.end] }.filter { $0 > now && $0 < dayEnd })
        let dates = Array(([now] + moments.sorted()).prefix(16))
        var rows: [[String: Any]] = []
        let only = ProcessInfo.processInfo.environment["YC_BENCH_ONLY"] ?? ""
        for family in [Family.large, .extraLarge, .extraLargePortrait] {
            for kind in ["day", "agenda20"] {
                if !only.isEmpty, only != "day20:\(kind):\(family.short)" { continue }
                let style = WidgetStyle()
                // The layout alone (DayModel: two DayLayout passes + windows), per entry.
                let layout = kind == "day" ? HeadlessBench.median(HeadlessBench.times(quick ? 5 : 50) {
                    _ = DayModel.make(meetings: meetings, day: now, now: now, family: family, style: style, gridHeight: 280)
                }) : 0
                let size = family.size
                let render = HeadlessBench.median((0..<passes).map { _ in
                    HeadlessBench.clock {
                        for d in dates { _ = HeadlessBench.image(Entry(kind: kind, family: family, meetings: meetings, date: d), size) }
                    }
                })
                let per = render / Double(dates.count)
                print(String(format: "%-6@ %-11@ %-4@ %7@ %7.3f %7@ %4d %9@ %9.1f %9@ %9.2f %8.1f", "day20" as NSString,
                             kind as NSString, family.short as NSString, "-" as NSString, layout, "-" as NSString,
                             dates.count, "-" as NSString, render, "-" as NSString, per, render))
                rows.append([
                    "fixture": "day20", "kind": kind, "family": family.short, "meetings": meetings.count,
                    "dayLayoutMs": HeadlessBench.round3(layout), "entries": dates.count,
                    "renderAllMs": HeadlessBench.round3(render), "renderPerEntryMs": HeadlessBench.round3(per),
                    "totalMs": HeadlessBench.round3(render),
                ])
            }
        }
        return rows
    }

    /// One timeline entry as the extension would draw it.
    struct Entry: View {
        let kind: String
        let family: Family
        let meetings: [WidgetMeeting]
        let date: Date

        var body: some View {
            let style = WidgetStyle()
            let palette = style.palette
            GeometryReader { geo in
                let scale = min(geo.size.width / family.size.width, geo.size.height / family.size.height)
                Group {
                    if kind == "day" {
                        DayTimelineWidget(family: family, meetings: meetings, now: date, style: style)
                    } else {
                        AgendaWidget(family: family, meetings: meetings.filter { $0.end > date }, now: date, style: style)
                    }
                }
                .scaleEffect(scale > 0 ? scale : 1, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .environment(\.widgetTone, .color)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}
#endif
