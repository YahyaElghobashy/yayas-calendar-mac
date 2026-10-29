import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var router: LinkRouter?
    private var sigterm: DispatchSourceSignal?

    /// Installer probes (`--permissions-json`, `--uninstall`) answer here, before any UI, Keychain or network,
    /// and exit. A link that cold-launches the app arrives before `didFinishLaunching`, so the router
    /// starts here too.
    func applicationWillFinishLaunching(_ notification: Notification) {
        SuiteFlags.early()
        // D-029: "Ask before sending to other people" leaves labs.* (once; before anything reads it).
        MailSettingsMigration.run(UserDefaults.standard)
        // The widgets' 24-hour default follows the Mac; days follow its time zone after travel (D-039).
        WidgetClockDefaults.refresh()
        WidgetCalendar.followSystemChanges()
        // The tracker starts now so it already knows the user's app when a cold-launching link lands.
        _ = FrontAppTracker.shared
        AccountDirectory.current = { AccountDirectory.live() }
        // Join with Fathom (D-045): the session's live side, the widgets' Fathom button and each account card's link.
        FathomLive.install()
        // Yaya's Murmur (D-046): whether it's here, its marks and their ping, the widgets' and heads-ups' recorder. Before
        // the notifier: the meeting export starts on when Murmur is installed.
        MurmurLive.install()
        RecorderDispatch.install()
        AccountCardExtras.footer = { account in
            AnyView(AccountRecorderSection(recorders: RecorderChoicesModel.shared, links: FathomLinksModel.shared,
                                           accountId: account.id, email: account.email))
        }
        router = LinkRouter(openMain: { section in MainWindowController.shared.show(section) })
        // Notification delegate + categories (set before launch finishes), heads-up/re-auth/mail notices
        // and the Deck export, fed by the data engine's observers.
        Notifier.install(openSection: { section in MainWindowController.shared.show(section) })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try DataFolders.ensure()
        } catch {
            Trace.app("data-folders", ["result": "error"])
        }
        installTerminationHandler()
        NSApp.mainMenu = MainMenu.build(openSettings: { MainWindowController.shared.show(.settings) })

        let status = StatusItemController(
            openMain: { MainWindowController.shared.show(nil) },
            openSettings: { MainWindowController.shared.show(.settings) })
        status.install()
        statusItem = status

        SuiteFlags.handle()
        Trace.app("launched", [
            "pid": "\(getpid())",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
        ])
        AccountsModel.shared.start()
        // Data layer: installs the real stores in `Services`, publishes every widget snapshot and starts
        // polling (docs/CONTRACTS.md "App seam").
        DataServices.start(accounts: AccountsModel.shared)
        MailIntegration.install()
        // The status title reads the store now that it's installed; ⌃⌥J registers (Settings can turn it off).
        status.refreshTitle()
        JoinHotkeyCenter.shared.start()

        if SuiteFlags.onboardingRequested {
            MainWindowController.shared.presentOnboarding()
        } else {
            MainWindowController.shared.openGuideIfFirstRun()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        router?.handle(urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        router?.lastActivation = Date()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Double-clicking the app while it runs opens the main window (plain launch = menu-bar icon only).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Trace.app("terminating")
        router?.flushNow()   // a tap's deferred flush must not be lost to a quit inside its 1.5 s
        Notifier.willTerminate()   // No heads-up fires while the app isn't running to answer it
    }

    /// `pkill -x YayasCalendar` (the installer's quit) sends SIGTERM: leave through NSApp.terminate so the
    /// normal shutdown path runs instead of dying mid-write.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Trace.app("sigterm")
            NSApp.terminate(nil)
        }
        source.resume()
        sigterm = source
    }
}

/// The app's private folders, all 0700 (CONTRACTS paths).
enum DataFolders {
    static var all: [URL] { [Paths.root, Paths.widget, Paths.logos, Paths.share, Paths.logs] }

    @discardableResult
    static func ensure() throws -> [URL] {
        let fm = FileManager.default
        for url in all {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return all
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }
}
