import AppKit
import ServiceManagement
import UserNotifications

/// Launch arguments for installers and setup scripts (docs/CONTRACTS.md, installer flags):
///
///   --permissions-json      one JSON line, `.prohibited` activation, no Keychain/network/UI, < 1 s, exit 0
///   --login-item on|off     register / unregister the login item, then keep launching
///   --onboarding            show the onboarding sheet; "Let's go" writes the handoff marker (Profile.suiteHandoffDir)
///   --uninstall [--purge]   drop the login item; with --purge also revoke Google tokens (≤5 s), delete
///                           this app's Keychain items (≤10 s through the Keychain gate), its data folder,
///                           preferences, WebKit and cache folders and the handoff marker; exit
///   --purge                 the same as --uninstall --purge
///   --purge --dry-run       print the paths and Keychain service names it would remove (never a value);
///                           removes nothing, reads no Keychain item, no network; exit 0
///
/// Dev-only flags (`--selftest`, `--render <dir>`) are handled in `Main` before NSApplication starts.
@MainActor
enum SuiteFlags {
    private(set) static var onboardingRequested = false

    static var handoffFile: URL { Paths.suiteHandoff.appendingPathComponent("yayascalendar.done") }

    /// From applicationWillFinishLaunching, so a probe never reaches the Dock, the menu bar or the Keychain.
    static func early(_ args: [String] = CommandLine.arguments) {
        if args.contains("--permissions-json") {
            NSApp.setActivationPolicy(.prohibited)
            let line = SuiteJSON.permissions(loginItem: SMAppService.mainApp.status == .enabled,
                                             notifications: notificationState(waitingAtMost: 0.8))
            print(line)
            fflush(stdout)
            exit(0)
        }
        if args.contains("--uninstall") || args.contains("--purge") {
            NSApp.setActivationPolicy(.prohibited)
            print(Uninstaller.run(purge: args.contains("--purge"), dryRun: args.contains("--dry-run")))
            fflush(stdout)
            exit(0)
        }
    }

    /// From applicationDidFinishLaunching.
    static func handle(_ args: [String] = CommandLine.arguments) {
        if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
            LoginItem.set(args[i + 1].lowercased() == "on")
        }
        onboardingRequested = args.contains("--onboarding")
    }

    /// Writes the handoff marker, but only when the installer asked for onboarding (`--onboarding`).
    static func markOnboardingDone() {
        guard onboardingRequested else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: handoffFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? Data("done \(stamp)\n".utf8).write(to: handoffFile, options: .atomic)
        Trace.app("onboarding-done")
    }

    /// Notification authorization, waiting at most `seconds` for UserNotifications to answer.
    private static func notificationState(waitingAtMost seconds: TimeInterval) -> String {
        let answer = LockedValue("undetermined")
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            answer.set(SuiteJSON.notificationState(settings.authorizationStatus))
            done.signal()
        }
        _ = done.wait(timeout: .now() + seconds)
        return answer.get()
    }
}

/// A value shared with a completion handler that may run after we stopped waiting for it.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&value); lock.unlock() }
}

/// Launch at login via `SMAppService.mainApp` (never a launch agent: a crashing agent relaunches into a
/// flood of crash dialogs). Registers only from /Applications or the user's own ~/Applications, so build
/// copies and scratch installs never end up as login items.
enum LoginItem {
    /// /Applications or the user's own ~/Applications ("Move me to Applications" offers either).
    static var isInApplications: Bool { AppPlacement.isInApplications(Bundle.main.bundleURL.path, home: Paths.realHome.path) }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        if on && !isInApplications {
            Trace.app("login-item", ["on": "1", "result": "skipped-not-in-applications"])
            return false
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Trace.app("login-item", ["on": on ? "1" : "0", "result": "ok"])
            return true
        } catch {
            Trace.app("login-item", ["on": on ? "1" : "0", "result": "error"])
            return false
        }
    }

    static func unregisterIfNeeded() {
        guard SMAppService.mainApp.status != .notRegistered else { return }
        try? SMAppService.mainApp.unregister()
    }
}
