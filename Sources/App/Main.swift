import AppKit

/// AppKit lifecycle, no SwiftUI `App`: Yaya's Calendar is a resident menu-bar agent (LSUIElement) that
/// owns a status item, the main window, and the `yayacal://` handler widget taps go through.
@main
enum Main {
    /// `NSApplication.delegate` is weak; this keeps the delegate alive for the process lifetime.
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        // Everything the app writes (data folder, logs, Keychain-adjacent files) is private by default.
        umask(0o077)

        // Dev modes run headless BEFORE NSApplication exists: no Dock icon, no window, no LaunchServices
        // check-in that could let this build copy claim yayacal:// or the widget gallery.
        let args = CommandLine.arguments
        #if YC_DEV_TOOLS
        if args.contains("--selftest") {
            exit(SelfTest.run())
        }
        if let i = args.firstIndex(of: "--render") {
            guard i + 1 < args.count else {
                print("usage: YayasCalendar --render <dir>")
                exit(2)
            }
            exit(HeadlessRender.run(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)))
        }
        // `--bench <dir>`: widget timing numbers (D-019), headless like `--render`.
        if let i = args.firstIndex(of: "--bench") {
            guard i + 1 < args.count else {
                print("usage: YayasCalendar --bench <dir>")
                exit(2)
            }
            exit(HeadlessBench.run(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)))
        }
        #else
        // Release builds carry no developer tools (D-035): refuse their flags instead of starting the app.
        if let flag = args.first(where: { $0 == "--selftest" || $0 == "--render" || $0 == "--bench" }) {
            print("\(flag): developer tool, not in this build (./build.sh --dev)")
            exit(2)
        }
        #endif

        // `--diagnose`: one JSON line of sync/widget counts (no titles, addresses or tokens), then exit.
        if args.contains("--diagnose") {
            Task { @MainActor in
                print(await DataServices.diagnose())
                fflush(stdout)
                exit(0)
            }
            RunLoop.main.run()
        }

        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}
