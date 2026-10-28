import AppKit
import SwiftUI

/// Which of the app's surfaces are on screen (main window, menu-bar popover). The data layer polls
/// faster while any is visible (`DataServices.surfaceVisible`); closing one must not switch that off
/// while the other is still open.
@MainActor
enum SurfacePresence {
    private(set) static var window = false
    private(set) static var popover = false

    static func set(window: Bool? = nil, popover: Bool? = nil) {
        if let window { self.window = window }
        if let popover { self.popover = popover }
        DataServices.surfaceVisible = self.window || self.popover
    }
}

/// The popover's window: borderless and non-activating, like the Peek panel. It takes clicks and Esc
/// without activating the app, so the app the user is in stays in front and desktop widgets keep their
/// colour. The rounded card is the SwiftUI content; the window itself is clear.
final class PopoverPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: PopoverView.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityLabel("Yaya\u{2019}s Calendar")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Opens and closes the popover under the status item. Closes on Esc, on a click anywhere else (other
/// apps, the desktop, our other windows; a Peek opened from it stays), when another app comes forward
/// and when the Space changes. While open it counts as a visible surface and redraws once a minute.
@MainActor
final class MenuPopoverController {
    static let shared = MenuPopoverController()

    weak var statusButton: NSStatusBarButton?
    /// The status item highlights its button while the popover is open.
    var onShownChange: (Bool) -> Void = { _ in }

    private var panel: PopoverPanel?
    private var model: PopoverModel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var refresh: Timer?
    /// A click on the status item also reaches the outside-click monitor first; the toggle that
    /// follows must not reopen what that click just closed.
    private var closedByClickAt = Date.distantPast

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isShown {
            close(reason: "toggle")
        } else if Date().timeIntervalSince(closedByClickAt) > 0.35 {
            show(reason: "click")
        }
    }

    func show(reason: String) {
        let model = self.model ?? PopoverModel()
        self.model = model
        model.load()
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        place(panel)
        let wasShown = panel.isVisible
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        guard !wasShown else { return }
        installMonitors()
        startRefresh()
        // Opening a surface makes reloads free and polling faster (CONTRACTS: WidgetInteractions.flushChanged).
        SurfacePresence.set(popover: true)
        Services.widgetInteractions.flushChanged()
        onShownChange(true)
        Trace.app("popover", ["action": "open", "via": reason, "rows": "\(model.eventCount)", "card": model.card == nil ? "0" : "1"])
    }

    func close(reason: String) {
        guard isShown || !monitors.isEmpty else { return }
        removeMonitors()
        refresh?.invalidate()
        refresh = nil
        panel?.orderOut(nil)
        SurfacePresence.set(popover: false)
        onShownChange(false)
        Trace.app("popover", ["action": "close", "via": reason])
    }

    // MARK: - Actions

    private func makeActions() -> PopoverActions {
        PopoverActions(
            openApp: { [weak self] section in
                self?.close(reason: "open-app")
                PeekController.shared.close()
                MainWindowController.shared.show(section)
            },
            join: { [weak self] event in self?.join(event) },
            showEvent: { [weak self] r in
                guard let self else { return }
                PeekController.shared.showEvent(r: r, at: self.peekAnchor())
            },
            showThread: { [weak self] r in
                guard let self else { return }
                PeekController.shared.showMessage(r: r, at: self.peekAnchor())
            })
    }

    /// The card's Join: the store's link, checked against the allowlist again before anything opens it.
    private func join(_ event: CalendarEvent) {
        guard let url = event.joinURL, JoinPolicy.isAllowed(url) else {
            Trace.app("popover-join", ["result": "blocked"])
            return
        }
        let opened = NSWorkspace.shared.open(url)
        Trace.app("popover-join", ["result": opened ? "opened" : "failed"])
        if opened { close(reason: "join") }
    }

    /// Peeks open beside the popover (left of it when there's room), level with the row clicked.
    private func peekAnchor() -> NSPoint {
        let pointer = NSEvent.mouseLocation
        guard let frame = panel?.frame else { return pointer }
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        return PopoverPlacement.peekAnchor(popover: frame, pointer: pointer, visible: screen?.visibleFrame ?? frame)
    }

    // MARK: - Window

    private func makePanel(_ model: PopoverModel) -> PopoverPanel {
        let panel = PopoverPanel()
        panel.onEscape = { [weak self] in self?.close(reason: "escape") }
        let host = PeekHostingView(rootView: AnyView(PopoverView(model: model, actions: makeActions())))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: PopoverView.size)
        panel.contentView = host
        return panel
    }

    private func place(_ panel: NSPanel) {
        var anchor: CGRect?
        if let button = statusButton, let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: PopoverView.size)
        panel.setFrame(PopoverPlacement.frame(size: PopoverView.size, anchor: anchor, visible: visible), display: true)
    }

    private func startRefresh() {
        refresh?.invalidate()
        let next = (floor(Date().timeIntervalSinceReferenceDate / 60) + 1) * 60 + 0.2
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.load() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    // MARK: - Closing

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closedByClickAt = Date()
                self?.close(reason: "click-outside")
            }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = event.window else { return }
                // Clicks in the popover, in a Peek it opened, or on the status item itself (its action
                // toggles) keep it; anything else in the app closes it.
                if window === self.panel || window is PeekPanel || window === self.statusButton?.window { return }
                self.closedByClickAt = Date()
                self.close(reason: "click-app")
            }
            return event
        }) { monitors.append(local) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // Another app came forward (cmd-tab, a call opened from a Peek): the popover's moment has passed.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { self?.close(reason: "app-switch") }
        })
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(reason: "space") }
        })
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
