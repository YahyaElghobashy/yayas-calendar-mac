import Foundation

// `--uninstall [--purge] [--dry-run]` and Settings → "Remove everything and quit" (D-037). One list of what
// this app leaves on a Mac, one engine that removes it, and seams for everything that touches the
// system, so the tests run it against temporary folders and a fake keychain. The live seams (Google
// revoke, SecItemDelete, the login item, notifications, WebKit) are in Uninstaller+Live.swift.

// MARK: - Identifiers ─────────────────────────────────────────────────────────────────────────────────
// Read from the one identifier table (`Profile.Uninstall`, Sources/Shared/Profile.swift, D-034), so each
// build profile removes only its own items: the dev profile never names the release Keychain services or
// data folder. This file spells out no identifier.
enum UninstallIDs {
    static var appBundleID: String { Profile.bundleId }
    static var widgetBundleID: String { Profile.widgetBundleId }
    static var keychainServices: [String] { Profile.Uninstall.keychainServices }
    /// Relative to the user's home.
    static var dataFolder: String { Profile.Uninstall.dataRoot }
    /// Inside the data folder, removed with it (named in the dry run).
    static var dataFolderMail: [String] { Profile.Uninstall.dataRootMailFolders }
    static var defaultsDomain: String { Profile.Uninstall.defaultsDomain }
    static var widgetContainer: String { Profile.Uninstall.widgetContainer }
    static var suiteHandoffMarker: String { Profile.Uninstall.suiteHandoffMarker }
    /// Caches, WebKit's rule-list store, HTTP storage and saved window state (any may be missing).
    static var systemFolders: [String] { Profile.Uninstall.systemFolders }
}
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

/// Everything this app may leave behind for one user, as paths under `home`.
struct UninstallPlan: Equatable {
    var home: URL
    /// The data folder (store, widget snapshots and logos, Deck export, logs) and the per-app folders
    /// macOS keeps by bundle id (WebKit's rule-list store, caches, HTTP storage, saved window state).
    var folders: [URL]
    /// The preferences file, the HTTP cookie file and the installer's handoff marker.
    var files: [URL]
    var keychainServices: [String]
    var defaultsDomain: String
    /// The sandboxed widget's container. macOS may ask "access data from other apps" when a self-signed
    /// app touches it, so it stays (docs/TROUBLESHOOTING.md) and the final dialog names its path.
    var widgetContainer: URL

    static func make(home: URL) -> UninstallPlan {
        let id = UninstallIDs.appBundleID
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return UninstallPlan(
            home: home,
            folders: [home.appendingPathComponent(UninstallIDs.dataFolder, isDirectory: true)]
                + UninstallIDs.systemFolders.map { home.appendingPathComponent($0, isDirectory: true) },
            files: [
                library.appendingPathComponent("Preferences/\(UninstallIDs.defaultsDomain).plist"),
                library.appendingPathComponent("HTTPStorages/\(id).binarycookies"),
                home.appendingPathComponent(UninstallIDs.suiteHandoffMarker),
            ],
            keychainServices: UninstallIDs.keychainServices,
            defaultsDomain: UninstallIDs.defaultsDomain,
            widgetContainer: home.appendingPathComponent(UninstallIDs.widgetContainer, isDirectory: true))
    }

    /// `--purge --dry-run`: the paths and Keychain service names it would remove. Never a value: the
    /// Keychain isn't even read.
    func dryRun(exists: (URL) -> Bool) -> String {
        func mark(_ url: URL) -> String { "  \(url.path)\(exists(url) ? "" : "  (not there)")" }
        var lines = ["Yaya\u{2019}s Calendar --purge --dry-run: nothing is removed.",
                     "Would ask Google to revoke the sign-in of every connected account (5 s at most).",
                     "Would delete the Keychain items of these services:"]
        lines += keychainServices.map { "  \($0)" }
        lines.append("Would remove these folders:")
        lines += folders.map(mark)
        lines.append("  (the data folder holds mail\u{2019}s \(UninstallIDs.dataFolderMail.map { $0 + "/" }.joined(separator: ", ")) too)")
        lines.append("Would remove these files:")
        lines += files.map(mark)
        lines.append("Would clear the preferences domain \(defaultsDomain), this app\u{2019}s delivered and pending notifications, and its login item.")
        lines.append("Would leave in place (macOS protects it; see docs/TROUBLESHOOTING.md):")
        lines.append(mark(widgetContainer))
        return lines.joined(separator: "\n")
    }
}

/// What a removal did. Paths only, never a value from the Keychain.
struct UninstallReport: Equatable {
    var revoked = 0
    var keychainDeleted = 0
    /// Services whose items are still there (a Keychain dialog, or the budget ran out) → how many.
    var keychainLeft: [String: Int] = [:]
    var keychainTimedOut = false
    var removed: [String] = []
    var notFound: [String] = []
    var failed: [String] = []
    var defaultsCleared = false
    var widgetContainer = ""
    var widgetContainerExists = false

    var keychainLeftTotal: Int { keychainLeft.values.reduce(0, +) }

    /// The one line `--uninstall --purge` prints.
    var summary: String {
        var line = "Yaya\u{2019}s Calendar: login item removed, \(revoked) Google token(s) revoked, "
            + "\(keychainDeleted) Keychain item(s) deleted, \(removed.count) folder(s) and file(s) removed"
        if defaultsCleared { line += ", preferences cleared" }
        line += "."
        if keychainLeftTotal > 0 || keychainTimedOut {
            let services = keychainLeft.keys.sorted().joined(separator: ", ")
            line += " \(keychainLeftTotal) Keychain item(s) need you in Keychain Access"
            line += services.isEmpty ? "." : " (\(services))."
        }
        if !failed.isEmpty { line += " Could not remove: \(failed.joined(separator: ", "))." }
        if widgetContainerExists { line += " Left in place: \(widgetContainer) (see docs/TROUBLESHOOTING.md)." }
        return line
    }
}

/// Everything the engine does to the system, as seams.
struct UninstallSteps {
    /// Best-effort Google revoke within `budget` seconds; returns how many were confirmed.
    var revoke: (_ budget: TimeInterval) -> Int
    /// Deletes every item of one service (runs on the Keychain gate's queue); returns how many went.
    var deleteKeychain: (_ service: String) throws -> Int
    /// Items still under one service (attributes only: never prompts).
    var countKeychain: (_ service: String) -> Int
    var removeDefaults: (_ domain: String) -> Bool
    var loginItemOff: () -> Void
    var clearNotifications: () -> Void
    var fileManager: FileManager = .default
}

enum Uninstaller {
    /// Total time the Keychain deletes may take (a legacy access dialog must not hang the removal).
    static let keychainBudget: TimeInterval = 10

    /// Removes everything in `plan`. Call it off the main thread: the Keychain deletes go through a
    /// `KeychainGate` (its timed path), at most `keychainBudget` seconds in all; once one call is stuck
    /// behind a dialog the rest are reported as left, not tried.
    static func removeEverything(plan: UninstallPlan, steps: UninstallSteps, revokeBudget: TimeInterval = 5,
                                 keychainBudget: TimeInterval = Uninstaller.keychainBudget,
                                 now: () -> Date = Date.init) -> UninstallReport {
        var report = UninstallReport()
        steps.loginItemOff()
        steps.clearNotifications()
        report.revoked = steps.revoke(revokeBudget)

        let deadline = now().addingTimeInterval(keychainBudget)
        for service in plan.keychainServices {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0, !report.keychainTimedOut else {
                report.keychainTimedOut = true
                break
            }
            let gate = KeychainGate(label: Profile.scoped("purge"), slowAfter: remaining)
            do {
                report.keychainDeleted += try gate.sync("purge-delete") { try steps.deleteKeychain(service) }
            } catch KeychainError.waiting {
                report.keychainTimedOut = true
            } catch {
                // Counted below as left.
            }
        }
        for service in plan.keychainServices {
            let gate = KeychainGate(label: Profile.scoped("purge-count"), slowAfter: 1)
            let left = (try? gate.sync("purge-count") { steps.countKeychain(service) }) ?? (report.keychainTimedOut ? 1 : 0)
            if left > 0 { report.keychainLeft[service] = left }
        }

        report.defaultsCleared = steps.removeDefaults(plan.defaultsDomain)
        let fm = steps.fileManager
        for url in plan.folders + plan.files {
            guard fm.fileExists(atPath: url.path) else {
                report.notFound.append(url.path)
                continue
            }
            do {
                try fm.removeItem(at: url)
                report.removed.append(url.path)
            } catch {
                report.failed.append(url.path)
            }
        }
        report.widgetContainer = plan.widgetContainer.path
        report.widgetContainerExists = fm.fileExists(atPath: plan.widgetContainer.path)
        return report
    }

    /// Runs `body` on a background thread and waits for it (headless flags call from the main thread,
    /// where the Keychain gate refuses to run).
    static func offMain<T>(_ body: @escaping () -> T) -> T {
        guard Thread.isMainThread else { return body() }
        let box = UninstallBox<T>()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.value = body()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

private final class UninstallBox<T>: @unchecked Sendable {
    var value: T?
}
