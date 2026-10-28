import Foundation

/// Remove everything (D-037) against a temporary home and a fake keychain: the plan names every place the
/// app writes, the dry run prints paths and service names only, the engine removes what is there, leaves
/// the widget container and names it, and a Keychain call stuck behind a dialog costs at most the budget
/// and is reported as left. `-D YC_KEYCHAIN_ASSERT` traps any Keychain call on the main thread.
///     uninstall-tests <scratch-dir>
@main
enum UninstallTests {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed: [String] = []

    static func expect(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
        if condition() { passed += 1 } else { failed.append("\(name) (line \(line))") }
    }

    static func main() {
        guard CommandLine.arguments.count > 1 else {
            print("usage: uninstall-tests <scratch-dir>")
            exit(2)
        }
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Trace.folderOverride = scratch.appendingPathComponent("trace", isDirectory: true)   // never the real logs

        identifiers()
        planAndDryRun(scratch.appendingPathComponent("dry", isDirectory: true))
        removal(scratch.appendingPathComponent("remove", isDirectory: true))
        stuckKeychain(scratch.appendingPathComponent("stuck", isDirectory: true))
        nothingThere(scratch.appendingPathComponent("empty", isDirectory: true))

        print("UNINSTALL TESTS passed=\(passed) failed=\(failed.count)")
        failed.forEach { print("  \u{2717} \($0)") }
        exit(failed.isEmpty ? 0 : 1)
    }

    /// The identifier block matches the identifiers the app itself uses.
    static func identifiers() {
        expect(UninstallIDs.appBundleID == Paths.bundleId, "app bundle id")
        expect(UninstallIDs.widgetBundleID == Paths.widgetBundleId, "widget bundle id")
        expect(UninstallIDs.keychainServices.contains(TokenVault.service), "the token service")
        expect(UninstallIDs.keychainServices.contains(OAuthConfig.keychainService), "the client service")
        expect(UninstallIDs.keychainServices.contains { $0.hasSuffix(".linkkey") }, "the link-key service")
        expect(UninstallIDs.keychainServices.count == 3, "three services, no more")
        expect(UninstallIDs.keychainServices == Profile.Uninstall.keychainServices
               && UninstallIDs.dataFolder == Profile.Uninstall.dataRoot
               && UninstallIDs.defaultsDomain == Profile.Uninstall.defaultsDomain
               && UninstallIDs.widgetContainer == Profile.Uninstall.widgetContainer
               && UninstallIDs.suiteHandoffMarker == Profile.Uninstall.suiteHandoffMarker
               && UninstallIDs.systemFolders == Profile.Uninstall.systemFolders
               && UninstallIDs.dataFolderMail == Profile.Uninstall.dataRootMailFolders, "the block reads Profile.Uninstall")
        let home = Paths.realHome
        let plan = UninstallPlan.make(home: home)
        expect(plan.folders.first == Paths.root, "the data folder is Paths.root (widget folder, share, logs inside)")
        expect(Paths.widget.path.hasPrefix(Paths.root.path) && Paths.share.path.hasPrefix(Paths.root.path)
               && Paths.logs.path.hasPrefix(Paths.root.path), "every app folder sits in the data folder")
        expect(Paths.attachments.deletingLastPathComponent().path == Paths.root.path
               && Paths.outbox.deletingLastPathComponent().path == Paths.root.path
               && Profile.Uninstall.dataRootMailFolders.contains(Paths.attachments.lastPathComponent)
               && Profile.Uninstall.dataRootMailFolders.contains(Paths.outbox.lastPathComponent),
               "rich mail's attachment cache and outbox sit in the data folder (the profile's own)")
        expect(plan.files.contains(Paths.suiteHandoff.appendingPathComponent("yayascalendar.done")), "the installer's handoff marker")
    }

    static func makeHome(_ home: URL) -> UninstallPlan {
        try? FileManager.default.removeItem(at: home)
        let plan = UninstallPlan.make(home: home)
        let fm = FileManager.default
        for folder in plan.folders {
            try? fm.createDirectory(at: folder.appendingPathComponent("inner", isDirectory: true), withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: folder.appendingPathComponent("inner/file"))
        }
        for file in plan.files {
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: file)
        }
        try? fm.createDirectory(at: plan.widgetContainer.appendingPathComponent("Data", isDirectory: true), withIntermediateDirectories: true)
        // Something of another app's that must survive.
        let neighbour = home.appendingPathComponent("Library/Application Support/SomeOtherApp/keep.txt")
        try? fm.createDirectory(at: neighbour.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("keep".utf8).write(to: neighbour)
        return plan
    }

    static func planAndDryRun(_ home: URL) {
        let plan = makeHome(home)
        expect(plan.folders.count == 5 && plan.files.count == 3, "five folders, three files")
        expect(plan.folders.allSatisfy { $0.path.hasPrefix(home.path) } && plan.files.allSatisfy { $0.path.hasPrefix(home.path) },
               "everything is under the user's home")
        expect(plan.folders.contains { $0.path.hasSuffix("Library/WebKit/\(UninstallIDs.appBundleID)") }, "the WebKit rule-list store")
        expect(plan.files.contains { $0.path.hasSuffix("Library/Preferences/\(UninstallIDs.appBundleID).plist") }, "the preferences file")
        expect(plan.widgetContainer.path.hasSuffix("Library/Containers/\(UninstallIDs.widgetBundleID)"), "the widget container")
        let text = plan.dryRun { FileManager.default.fileExists(atPath: $0.path) }
        expect(text.contains("nothing is removed"), "dry run says it removes nothing")
        expect(UninstallIDs.dataFolderMail.allSatisfy { text.contains($0 + "/") },
               "dry run names mail's folders inside the data folder (attachments, outbox, compose, Mail Downloads)")
        expect(UninstallIDs.keychainServices.allSatisfy { text.contains($0) }, "dry run names every Keychain service")
        expect((plan.folders + plan.files).allSatisfy { text.contains($0.path) }, "dry run prints every path")
        expect(text.contains(plan.widgetContainer.path) && text.contains("Would leave in place"), "dry run names what stays")
        expect(!text.contains("(not there)"), "everything planted is found")
        expect((plan.folders + plan.files).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "the dry run removed nothing")
        let missing = UninstallPlan.make(home: home.appendingPathComponent("nobody", isDirectory: true))
            .dryRun { FileManager.default.fileExists(atPath: $0.path) }
        expect(missing.contains("(not there)"), "missing paths are marked")
    }

    /// A keychain in memory: items per service, deletes and counts recorded with their thread.
    final class FakeKeychain: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: Int]
        var deleted: [String] = []
        var onMain = 0
        var delay: [String: TimeInterval] = [:]
        init(_ items: [String: Int]) { self.items = items }

        func delete(_ service: String) -> Int {
            if Thread.isMainThread { lock.lock(); onMain += 1; lock.unlock() }
            if let wait = delay[service] { Thread.sleep(forTimeInterval: wait) }
            lock.lock(); defer { lock.unlock() }
            deleted.append(service)
            let n = items[service] ?? 0
            items[service] = 0
            return n
        }

        func count(_ service: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return items[service] ?? 0
        }
    }

    static func steps(_ keychain: FakeKeychain, log: NSMutableArray) -> UninstallSteps {
        UninstallSteps(
            revoke: { _ in log.add("revoke"); return 2 },
            deleteKeychain: { keychain.delete($0) },
            countKeychain: { keychain.count($0) },
            removeDefaults: { domain in log.add("defaults \(domain)"); return true },
            loginItemOff: { log.add("login-item") },
            clearNotifications: { log.add("notifications") })
    }

    static func removal(_ home: URL) {
        let plan = makeHome(home)
        let keychain = FakeKeychain(Dictionary(uniqueKeysWithValues: UninstallIDs.keychainServices.map { ($0, 2) }))
        let log = NSMutableArray()
        let report = Uninstaller.offMain { Uninstaller.removeEverything(plan: plan, steps: steps(keychain, log: log)) }
        expect(keychain.onMain == 0, "no Keychain call on the main thread")
        expect(keychain.deleted == UninstallIDs.keychainServices, "every service deleted once, in order")
        expect(report.keychainDeleted == 6 && report.keychainLeftTotal == 0 && !report.keychainTimedOut, "six items deleted, none left")
        expect(report.revoked == 2, "revoked count reported")
        expect((log as? [String]) == ["login-item", "notifications", "revoke", "defaults \(UninstallIDs.appBundleID)"],
               "login item, notifications and revoke first, preferences after the Keychain (\(log))")
        expect(report.defaultsCleared, "preferences domain cleared")
        let fm = FileManager.default
        expect((plan.folders + plan.files).allSatisfy { !fm.fileExists(atPath: $0.path) }, "every planned path is gone")
        expect(report.removed.count == 8 && report.failed.isEmpty && report.notFound.isEmpty, "eight removed, none failed")
        expect(fm.fileExists(atPath: plan.widgetContainer.path) && report.widgetContainerExists
               && report.widgetContainer == plan.widgetContainer.path, "the widget container stays and is named")
        expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/SomeOtherApp/keep.txt").path),
               "another app's files are untouched")
        expect(report.summary.contains("6 Keychain item(s) deleted") && report.summary.contains(plan.widgetContainer.path),
               "summary line (\(report.summary))")
        expect(!report.summary.contains("need you"), "nothing left to do by hand")
    }

    /// One service hangs behind a "wants to access" dialog: the budget caps the wait, the rest are not
    /// tried, and what's still there is reported.
    static func stuckKeychain(_ home: URL) {
        let plan = makeHome(home)
        let services = UninstallIDs.keychainServices
        let keychain = FakeKeychain(Dictionary(uniqueKeysWithValues: services.map { ($0, 1) }))
        keychain.delay[services[1]] = 3
        let log = NSMutableArray()
        let started = Date()
        let report = Uninstaller.offMain {
            Uninstaller.removeEverything(plan: plan, steps: steps(keychain, log: log), keychainBudget: 1)
        }
        let took = Date().timeIntervalSince(started)
        expect(took < 3, "the stuck call costs about the budget, not the dialog's time (\(String(format: "%.1f", took)) s)")
        expect(report.keychainTimedOut, "timed out is reported")
        expect(report.keychainDeleted == 1, "the first service went")
        expect(report.keychainLeft[services[2]] == 1, "the untried service is reported as left")
        expect(report.summary.contains("need you in Keychain Access"), "the summary says what's left to do")
        expect(!FileManager.default.fileExists(atPath: plan.folders[0].path), "files are removed even when the Keychain stalls")
        Thread.sleep(forTimeInterval: 2.2)   // let the stuck fake finish before the next test
    }

    static func nothingThere(_ home: URL) {
        try? FileManager.default.removeItem(at: home)
        let plan = UninstallPlan.make(home: home)
        let keychain = FakeKeychain([:])
        let report = Uninstaller.offMain { Uninstaller.removeEverything(plan: plan, steps: steps(keychain, log: NSMutableArray())) }
        expect(report.removed.isEmpty && report.notFound.count == 8 && report.failed.isEmpty, "a clean Mac: nothing to remove, no errors")
        expect(!report.widgetContainerExists && !report.summary.contains("Left in place"), "no container, no mention")
    }
}
