import Foundation

/// Accounts tests: store, naming, adoption, health, sign-in, removal, Provider Setup, logos,
/// friendly text. No XCTest, no real Keychain/network/browser/UI; data lives under the folder given
/// as the first argument (the worktree's .work/).
///     accounts-tests <scratch-dir>
@main
enum AccountsTests {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed: [String] = []
    nonisolated(unsafe) static var scratch = URL(fileURLWithPath: ".")

    static func expect(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
        if condition() { passed += 1 } else { failed.append("\(name) (\(file.split(separator: "/").last ?? ""):\(line))") }
    }

    /// A fresh folder for one test.
    static func folder(_ name: String) -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls `condition` on the main actor for up to `seconds`.
    @MainActor
    static func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @MainActor
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("usage: accounts-tests <scratch-dir>")
            exit(2)
        }
        // The fixed London calendar, never the zone of the Mac running the tests.
        WidgetCalendar.current = WidgetCalendar.fixed
        scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Trace.folderOverride = scratch.appendingPathComponent("trace", isDirectory: true)   // never the real logs

        StoreTests.run()
        NamingTests.run()
        AdoptionTests.run()
        FriendlyTextTests.run()
        LogoTests.run()
        DevFileTests.run()
        await ModelTests.run()
        await KeychainLaunchTests.run()
        await SetupTests.run()

        print("\(passed) passed, \(failed.count) failed")
        failed.forEach { print("  \u{2717} \($0)") }
        exit(failed.isEmpty ? 0 : 1)
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
    AccountsTests.expect(condition(), name, file: file, line: line)
}

@MainActor
func expectEventually(_ name: String, seconds: Double = 3, file: String = #fileID, line: Int = #line,
                      _ condition: () -> Bool) async {
    let ok = await AccountsTests.eventually(seconds, condition)
    AccountsTests.expect(ok, name, file: file, line: line)
}
