// The activation-policy switch below follows Codenotch's Sources/Settings/SettingsWindowController.swift
// (https://github.com/vinzdg/codenotch; MIT License, Copyright (c) 2026 Vinz). See THIRD_PARTY_NOTICES.md.

import AppKit
import SwiftUI

/// The main window (1100×740, hidden title bar, full-size content, forced dark).
///
/// An accessory (LSUIElement) app is not allowed to properly activate and composite its own windows:
/// the window can exist, report itself visible, and never be drawn. So the app becomes `.regular`
/// while the window is open and returns to `.accessory` when it closes (see THIRD_PARTY_NOTICES.md).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    /// The Inbox's keys only act in this window (InboxKeyMonitor).
    static let windowIdentifier = "YayasCalendarMain"

    let shell = ShellModel.shared
    private var window: NSWindow?
    private var sheet: NSWindow?
    private var onboarding: OnboardingModel?

    var isOpen: Bool { window?.isVisible ?? false }

    /// "Connect an account" buttons outside the Accounts screen.
    static func openAccounts() { shared.show(.accounts) }

    func show(_ section: AppSection?) {
        if let section { shell.section = section }
        // Opening a window makes the agent active: reloads are free now, so flush what changed.
        Services.widgetInteractions.flushChanged()
        SurfacePresence.set(window: true)
        MenuPopoverController.shared.close(reason: "window")
        let window = self.window ?? makeWindow()
        // A window positioned on a display that has since gone away would come forward nowhere.
        if !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) { window.center() }
        surface(window)
    }

    /// `--onboarding` (and Settings → Welcome guide): the window with the guide sheet on top. It resumes
    /// at the step left open last time. The add-account flow runs inside the guide, so the window behind
    /// must not show Accounts (its own add sheet would open too).
    func presentOnboarding() {
        show(nil)
        guard let window, sheet == nil else { return }
        if shell.section == .accounts { shell.section = .calendar }
        let accounts = AccountsModel.shared
        let model = OnboardingModel(accounts: accounts)
        onboarding = model
        let host = NSHostingView(rootView: OnboardingView(model: model, accounts: accounts,
                                                          onDone: { [weak self] in self?.finishOnboarding() }))
        host.sizingOptions = []
        let size = OnboardingView.size
        host.frame = NSRect(origin: .zero, size: size)
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.contentView = host
        self.sheet = sheet
        window.beginSheet(sheet)
        model.appeared()
        Trace.app("onboarding", ["action": "open", "step": "\(model.shown.rawValue)", "installer": SuiteFlags.onboardingRequested ? "1" : "0"])
    }

    /// A plain launch (Finder, a GitHub download) opens the window and the guide while nothing is
    /// connected and the guide was never finished. Waits for the accounts store to open first.
    func openGuideIfFirstRun(accounts: AccountsModel = .shared, bag: PreferenceBag = DefaultsBag.shared) {
        Task { @MainActor in
            var waited = 0
            while accounts.repo == nil && accounts.storeProblem == nil && waited < 100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            let open = OnboardingFlow.opensOnLaunch(accounts: accounts.accounts.count,
                                                    completedAt: bag.object(OnboardingFlow.completedKey) as? Date,
                                                    suiteRequested: SuiteFlags.onboardingRequested,
                                                    storeOpen: accounts.repo != nil)
            Trace.app("first-run", ["guide": open ? "1" : "0"])
            if open { self.presentOnboarding() }
        }
    }

    /// Settings → "Remove everything and quit" (D-037): the confirm, then the removal, then the report.
    func presentRemoveEverything() {
        show(.settings)
        guard let window, sheet == nil else { return }
        let plan = UninstallPlan.make(home: Paths.realHome)
        let model = RemoveEverythingModel(
            plan: plan, accounts: AccountsModel.shared.accounts.count,
            perform: { [weak self] in await self?.removeEverything(plan) ?? UninstallReport() },
            cancel: { [weak self] in self?.closeSheet() },
            quit: { exit(0) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
        let host = NSHostingView(rootView: RemoveEverythingView(model: model))
        host.sizingOptions = []
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        // Confirm, working and the report differ in height: fit the sheet to each.
        model.onPhase = { [weak sheet, weak host] in
            DispatchQueue.main.async {
                guard let sheet, let host else { return }
                host.layoutSubtreeIfNeeded()
                sheet.setContentSize(host.fittingSize)
            }
        }
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.contentView = host
        self.sheet = sheet
        window.beginSheet(sheet)
    }

    private func closeSheet() {
        if let sheet, let window { window.endSheet(sheet) }
        sheet = nil
    }

    /// Stops everything that writes, then removes it all. After this nothing may touch the data folder,
    /// the preferences or the Keychain: the only way on is Quit.
    private func removeEverything(_ plan: UninstallPlan) async -> UninstallReport {
        Trace.app("remove-everything", ["action": "start"])
        Trace.muted = true
        window?.setFrameAutosaveName("")
        Notifier.shutDown()
        await DataServices.stop()
        await Uninstaller.removeWebKitRuleLists()
        let report = await Task.detached { Uninstaller.removeEverything(plan: plan, steps: .live) }.value
        return report
    }

    private func finishOnboarding() {
        onboarding?.noteClosed()
        onboarding = nil
        SuiteFlags.markOnboardingDone()
        // An account sign-in still waiting carries on in Accounts, where its sheet reappears.
        if let sheet, let window { window.endSheet(sheet) }
        sheet = nil
        // From an installer (`--onboarding`): land where the next thing is. From Settings: stay put, unless a sign-in is pending.
        let accounts = AccountsModel.shared
        if accounts.isAddSheetPresented {
            shell.section = .accounts
        } else if SuiteFlags.onboardingRequested {
            shell.section = accounts.accounts.isEmpty ? .accounts : .calendar
        }
        Trace.app("onboarding", ["action": "done"])
    }

    private func surface(_ window: NSWindow) {
        WindowPresence.opened(self)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Yaya's Calendar"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x0C / 255, green: 0x16 / 255, blue: 0x1D / 255, alpha: 1)
        window.isMovableByWindowBackground = false
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        let host = NSHostingView(rootView: MainView(shell: shell))
        host.sizingOptions = []
        window.contentView = host
        // Reopen where the user left it; first time, centred at 1100×740.
        if !window.setFrameUsingName("YayasCalendarMain") || window.frame.width < 900 {
            window.setContentSize(NSSize(width: 1100, height: 740))
            window.center()
        }
        window.setFrameAutosaveName("YayasCalendarMain")
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let sheet, let window { window.endSheet(sheet) }
        sheet = nil
        onboarding?.noteClosed()
        onboarding = nil
        SurfacePresence.set(window: false)
        // Back to the menu bar unless a composer is still open.
        WindowPresence.closed(self)
    }
}
