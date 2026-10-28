import Foundation

/// Data tests: store, Google provider, sync, merge, join links, RSVP, publisher, governor,
/// link keys, interactions, scheduler, diagnostics; mail: MIME, sanitizer, Gmail sync, actions, send,
/// publisher mail rows; notifications + Deck export. No XCTest, no real Keychain/network/WidgetKit;
/// data lives under the folder given as the first argument (the worktree's .work/).
///     data-tests <scratch-dir>
@main
enum DataTests {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed: [String] = []
    nonisolated(unsafe) static var scratch = URL(fileURLWithPath: ".")
    static let lock = NSLock()

    static func expect(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
        let ok = condition()
        lock.lock(); defer { lock.unlock() }
        if ok { passed += 1 } else { failed.append("\(name) (\(file.split(separator: "/").last ?? ""):\(line))") }
    }

    /// A fresh folder for one test.
    static func folder(_ name: String) -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("usage: data-tests <scratch-dir>")
            exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered: a hang still shows how far it got
        // Everything formatted with the widget calendar (mail attribution and forward lines, day names) reads
        // the fixed London calendar, never the zone of the Mac running the tests: goldens stay byte-identical
        // whatever TZ says.
        WidgetCalendar.current = WidgetCalendar.fixed
        scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Trace.folderOverride = scratch.appendingPathComponent("trace", isDirectory: true)   // never the real logs
        // Tools/bench-widgets.sh: the tap-path benchmark only.
        if let i = CommandLine.arguments.firstIndex(of: "--bench") {
            let out = i + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil
            TapBench.run(out: out)
            exit(0)
        }

        let groups: [(String, () async -> Void)] = [
            ("store", { StoreTests.run() }),
            ("time", { TimeTests.run() }),
            ("join", { JoinTests.run() }),
            ("mapper", { MapperTests.run() }),
            ("provider", { await ProviderTests.run() }),
            ("sync", { await SyncTests.run() }),
            ("merge", { MergeTests.run() }),
            ("rsvp", { await RSVPTests.run() }),
            ("links", { LinkTests.run() }),
            ("governor", { GovernorTests.run() }),
            ("publish", { PublishTests.run() }),
            ("interactions", { InteractionTests.run() }),
            ("day widget", { DayPublishTests.run() }),
            ("tap path", { TapPathTests.run() }),
            ("refresh", { await RefreshTests.run() }),
            ("keychain", { await KeychainTests.run() }),
            ("scheduler", { await SchedulerTests.run() }),
            ("engine", { await EngineTests.run() }),
            ("perf", { PerfTests.run() }),
            ("mime", { MIMETests.run() }),
            ("sanitizer", { SanitizerTests.run() }),
            ("gmail", { await GmailSyncTests.run() }),
            ("mail actions", { await MailActionTests.run() }),
            ("mail publish", { await MailPublishTests.run() }),
            ("rich mail", { await RichMailDataTests.run() }),
            ("notify", { await NotifyTests.run() }),
            ("setup errors", { await SetupErrorTests.run() }),
        ]
        for (name, body) in groups {
            let before = (passed, failed.count)
            let started = Date()
            await body()
            let label = name.padding(toLength: 13, withPad: " ", startingAt: 0)
            print(String(format: "  %@ %4d passed, %d failed  (%.2f s)", label, passed - before.0,
                         failed.count - before.1, Date().timeIntervalSince(started)))
        }
        print("DATA TESTS passed=\(passed) failed=\(failed.count)")
        failed.forEach { print("  \u{2717} \($0)") }
        exit(failed.isEmpty ? 0 : 1)
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
    DataTests.expect(condition(), name, file: file, line: line)
}

/// Polls `condition` for up to `seconds`.
func eventually(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
