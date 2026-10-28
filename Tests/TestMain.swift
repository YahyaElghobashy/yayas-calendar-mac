import Foundation

/// Plain swiftc test binary (no XCTest in the Command Line Tools). Pure logic only: no UI, no Keychain,
/// no network; the only files read are the committed JSON fixtures (Tests/Fixtures, via YC_FIXTURES).
@main
enum TestMain {
    @MainActor
    static func main() async {
        WidgetCalendar.current = WidgetCalendar.fixed
        // Tests never write the real app log or widget trace (models trace as they act).
        Trace.folderOverride = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("trace", isDirectory: true)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--write-fixtures"), i + 1 < args.count {
            exit(SnapshotTests.write(to: args[i + 1]))
        }
        RouteTests.run()
        SuiteTests.run()
        KindTests.run()
        TraceTests.run()
        PaginatorTests.run()
        InboxLayoutTests.run()
        // Day widget.
        DayLayoutTests.run()
        DayWidgetTests.run()
        // UI layer.
        SnapshotTests.run()
        TimelineTests.run()
        RenderCacheTests.run()
        LinkTests.run()
        RouterTests.run()
        await SurfaceTests.run()
        // UI layer.
        await MailTests.run()
        await RichMailSurfaceTests.run()
        RichMailViewerSurfaceTests.run()
        RichMailAttachmentSurfaceTests.run()
        await RichComposerSurfaceTests.run()
        await RichSendSurfaceTests.run()
        await RichMailReviewSurfaceTests.run()
        // UI layer.
        MenuBarTests.run()
        // First-run UX.
        StrangerUXTests.run()
        // Mail defaults (D-029).
        MailDefaultsTests.run()
        T.finish()
    }
}

enum T {
    private(set) static var passed = 0
    private(set) static var failed = 0
    private static var current = ""

    static func section(_ name: String) {
        current = name
        print("▸ \(name)")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("  ✗ [\(current)] \(message()) (line \(line))")
        }
    }

    static func equal<V: Equatable>(_ a: V, _ b: V, _ what: String, line: Int = #line) {
        check(a == b, "\(what): got \(a), expected \(b)", line: line)
    }

    static func note(_ text: String) { print("  · \(text)") }

    static func finish() -> Never {
        print(failed == 0 ? "✓ all \(passed) checks passed" : "✗ \(failed) of \(passed + failed) checks failed")
        print("TESTS passed=\(passed) failed=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}

/// Deterministic pseudo-random numbers for fixture generation (same fixtures every run).
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}
