// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import SwiftUI

/// `--bench <dir>`: headless widget performance numbers. The widget extension's own work for
/// one timeline, measured on the shared code it runs:
///
/// 1. decode `widget/<kind>.json` (the committed fixtures in `YC_FIXTURES`, else the same snapshots built
///    in memory) and map it (`SnapshotModel`, logos read from disk like the widget does);
/// 2. plan the timeline (`TimelinePlan`): entry count and time;
/// 3. lay out and draw EVERY entry with `ImageRenderer` at 2x, as WidgetKit archives every entry of a
///    timeline before it shows one (WWDC20 10028). `layout` evaluates and lays out the views without
///    drawing; `render` also rasterises; `raster` is a plain card of the same size (the drawing floor).
///
/// Cases: the busy week (29 meetings) and a heavy month (120 meetings, the publisher's cap: what a picked
/// day carries on a busy calendar), for Month and Agenda in the families the user places; the Day kind on
/// its 20-meeting day (`busyDay`, today) and on another day (`dayPicked`), every family; then `day20`
/// (DayBench): the Day design and the Agenda drawn directly over one 20-meeting day, L / XL / XLP.
/// No window, Keychain, network or user defaults; traces go to `<dir>/trace/`. Prints a table and writes
/// `<dir>/bench.json`.
@MainActor
enum HeadlessBench {
    struct Case {
        let fixture: String
        let spec: WidgetKindSpec
        let family: Family
        let data: Data
    }

    static func run(to dir: URL) -> Int32 {
        WidgetCalendar.current = WidgetCalendar.fixed
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("✗ cannot create \(dir.path)")
            return 1
        }
        Trace.folderOverride = dir.appendingPathComponent("trace", isDirectory: true)
        let now = WidgetSample.fixedNow
        let logos = prepareLogos(in: dir.appendingPathComponent("logos", isDirectory: true))
        let quick = ProcessInfo.processInfo.environment["YC_BENCH_QUICK"] == "1"
        let passes = quick ? 1 : 3

        var cases: [Case] = []
        for spec in [WidgetKinds.month, WidgetKinds.agenda] {
            let families: [Family] = spec.kind == "month" ? [.small, .medium, .large, .extraLargePortrait]
                                                           : [.medium, .large, .extraLarge, .extraLargePortrait]
            for fixture in ["busy", "heavy"] {
                guard let data = snapshotData(fixture, kind: spec.kind, now: now) else {
                    print("✗ no \(fixture) fixture for \(spec.kind)")
                    return 1
                }
                for family in families { cases.append(Case(fixture: fixture, spec: spec, family: family, data: data)) }
            }
        }
        // The Day kind (D-022) through the extension's path: the 20-meeting day shown today (busyDay), and
        // another day picked with ‹ › (dayPicked: one entry until midnight).
        for fixture in ["busyDay", "dayPicked"] {
            guard let data = snapshotData(fixture, kind: WidgetKinds.day.kind, now: now) else { return 1 }
            for family in Family.allCases { cases.append(Case(fixture: fixture, spec: WidgetKinds.day, family: family, data: data)) }
        }

        // The Daily Digest (D-053): the busy digest and seven mailboxes, every family.
        for fixture in ["busy", "digestMany"] {
            guard let data = snapshotData(fixture, kind: WidgetKinds.digest.kind, now: now) else { return 1 }
            for family in Family.allCases { cases.append(Case(fixture: fixture, spec: WidgetKinds.digest, family: family, data: data)) }
        }

        // `YC_BENCH_ONLY=fixture:kind:family` (e.g. busy:month:S) keeps one case (profiling with `sample`).
        if let only = ProcessInfo.processInfo.environment["YC_BENCH_ONLY"], !only.isEmpty {
            cases = cases.filter { "\($0.fixture):\($0.spec.kind):\($0.family.short)" == only }
        }
        print(String(format: "%-6@ %-11@ %-4@ %7@ %7@ %7@ %4@ %9@ %9@ %9@ %9@ %8@", "fixt" as NSString, "kind" as NSString,
                     "fam" as NSString, "decode" as NSString, "model" as NSString, "plan" as NSString, "n" as NSString,
                     "layout" as NSString, "render" as NSString, "raster" as NSString, "per-entry" as NSString,
                     "total" as NSString))
        var rows: [[String: Any]] = []
        let started = Date()
        for c in cases {
            let decode = median(times(quick ? 3 : 20) { _ = try? WidgetSnapshot.decoder.decode(WidgetSnapshot.self, from: c.data) })
            guard let snapshot = try? WidgetSnapshot.decoder.decode(WidgetSnapshot.self, from: c.data) else {
                print("✗ \(c.fixture) \(c.spec.kind) does not decode")
                return 1
            }
            let loader = SnapshotModel.logoFile(in: logos)
            let model = median(times(quick ? 3 : 20) { _ = SnapshotModel(snapshot, logo: loader) })
            let m = SnapshotModel(snapshot, logo: loader)
            var dates: [Date] = []
            let plan = median(times(quick ? 5 : 50) { dates = BenchPlan.entryDates(now: now, model: m, spec: c.spec, family: c.family) })

            let size = c.family.size
            let layout = median((0..<passes).map { _ in
                clock { for d in dates { layoutOnly(BenchEntry(spec: c.spec, family: c.family, model: m, date: d), size) } }
            })
            let render = median((0..<passes).map { _ in
                clock { for d in dates { _ = image(BenchEntry(spec: c.spec, family: c.family, model: m, date: d), size) } }
            })
            let raster = median((0..<passes).map { _ in
                clock { for _ in dates { _ = image(Color.white.frame(width: size.width, height: size.height), size) } }
            })
            let total = decode + model + plan + render
            print(String(format: "%-6@ %-11@ %-4@ %7.2f %7.2f %7.3f %4d %9.1f %9.1f %9.1f %9.2f %8.1f",
                         c.fixture as NSString, c.spec.kind as NSString, c.family.short as NSString,
                         decode, model, plan, dates.count, layout, render, raster, render / Double(max(1, dates.count)), total))
            rows.append([
                "fixture": c.fixture, "kind": c.spec.kind, "family": c.family.short, "meetings": snapshot.meetings.count,
                "decodeMs": round3(decode), "modelMs": round3(model), "planMs": round3(plan), "entries": dates.count,
                "layoutAllMs": round3(layout), "renderAllMs": round3(render), "rasterAllMs": round3(raster),
                "renderPerEntryMs": round3(render / Double(max(1, dates.count))),
                "totalMs": round3(total),
            ])
        }
        // Day widget design: Day vs Agenda over the same 20 meetings and moments.
        rows += DayBench.run(now: now, passes: passes, quick: quick)
        let report: [String: Any] = [
            "generated": ISO8601DateFormatter().string(from: Date()),
            "now": ISO8601DateFormatter().string(from: now),
            "passes": passes, "scale": 2, "logos": logos == nil ? "none" : "128 px PNGs (LogoStore size)",
            "cases": rows,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: dir.appendingPathComponent("bench.json"))
        }
        print(String(format: "BENCH widget cases=%d in %.1f s → %@", rows.count, Date().timeIntervalSince(started),
                     dir.appendingPathComponent("bench.json").path))
        return 0
    }

    // MARK: - Fixtures

    /// `busy`: the committed `Tests/Fixtures/busy-<kind>.json` (YC_FIXTURES), else built in memory (the
    /// same snapshot). `heavy`: the busy week repeated over five weeks, capped at 120 meetings, Month
    /// picked on today (the list starts now), as a busy calendar publishes it.
    static func snapshotData(_ fixture: String, kind: String, now: Date) -> Data? {
        if fixture == "busy" {
            if let folder = ProcessInfo.processInfo.environment["YC_FIXTURES"], !folder.isEmpty,
               let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("busy-\(kind).json")) {
                return data
            }
            return SnapshotFixtures.json(SnapshotFixtures.busy(kind: kind, now: now))
        }
        if fixture != "heavy" { return SnapshotFixtures.json(SnapshotFixtures.named(fixture, kind: kind, now: now)) }
        let cal = WidgetCalendar.fixed
        var snapshot = SnapshotFixtures.busy(kind: kind, now: now)
        let week = FixtureWeek.busy(now: now, calendar: cal)
        var meetings: [FixtureMeeting] = []
        for w in 0..<5 {
            for var m in week {
                guard let start = cal.date(byAdding: .day, value: 7 * w, to: m.start),
                      let end = cal.date(byAdding: .day, value: 7 * w, to: m.end) else { continue }
                m.start = start; m.end = end
                if w > 0 { m.r += "-w\(w)" }
                meetings.append(m)
            }
        }
        let rows = meetings.filter { $0.end > cal.startOfDay(for: now) }.sorted { ($0.start, $0.r) < ($1.start, $1.r) }
            .prefix(WidgetSnapshot.maxMeetings).map(\.snapshotRow)
        snapshot.meetings = Array(rows)
        snapshot.busyDays = Set(meetings.map { DayName.posixDay($0.start, calendar: cal) }).sorted()
        if kind == WidgetKinds.month.kind { snapshot.selectedDay = DayName.posixDay(now, calendar: cal) }
        return SnapshotFixtures.json(snapshot)
    }

    /// `<dir>/logos/<uuid>.png` at the size LogoStore writes (128 px): the cast's badges (`Cast.badge`), so
    /// the bench reads logo files from disk like the widget does without any real logo; nil if none wrote.
    static func prepareLogos(in folder: URL) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var wrote = 0
        for account in Cast.accounts {
            guard let image = Cast.badge(key: account.key), let tiff = image.tiffRepresentation,
                  let png = LogoStore.normalizedPNG(from: tiff)?.png else { continue }
            if (try? png.write(to: folder.appendingPathComponent("\(account.id.uuidString).png"))) != nil { wrote += 1 }
        }
        return wrote > 0 ? folder : nil
    }

    // MARK: - Timing

    static func clock(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    static func times(_ n: Int, _ body: () -> Void) -> [Double] {
        body()   // warm-up
        return (0..<n).map { _ in clock(body) }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    static func image<V: View>(_ view: V, _ size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        return renderer.cgImage
    }

    /// Evaluates and lays out the view tree without drawing it.
    static func layoutOnly<V: View>(_ view: V, _ size: CGSize) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        renderer.render { _, _ in }
    }
}
#endif
