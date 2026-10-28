import AppKit
import SwiftUI

/// Borderless, non-activating panel for the Peeks. It can become key (so Esc works once clicked) without
/// activating the app, floats above windows, and survives `NSApp.hide` and deactivation: the router
/// hands the front back to the user's app right after showing it, so desktop widgets regain their colour
/// while the Peek stays up. D-011: a Peek is transient; it never parks on the desktop.
final class PeekPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PeekPlacement.width, height: 200),
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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Clicks reach the Peek's buttons even while another app is active (the panel never activates us).
final class PeekHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows one Peek at a time at the pointer, clamped to that screen; closes on Esc, on any click outside
/// (global + local monitors) and on the close button.
@MainActor
final class PeekController {
    static let shared = PeekController()

    private var panel: PeekPanel?
    private var monitors: [Any] = []
    private var eventModel: EventPeekModel?
    private var dayModel: DayPeekModel?
    private var mailModel: MailPeekModel?

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Event Peek for row `r`. False when the event isn't in the store (stale widget, not synced yet).
    @discardableResult
    func showEvent(r: String, at anchor: NSPoint? = nil, keepTopLeft: Bool = false, back: (title: String, action: () -> Void)? = nil) -> Bool {
        let found: CalendarEvent?
        do {
            found = try Services.calendar.event(r: r)
        } catch {
            found = nil
        }
        guard let event = found else {
            Trace.app("peek", ["kind": "event", "result": "missing"])
            return false
        }
        let model = EventPeekModel(event: event, directory: AccountDirectory.current())
        model.onClose = { [weak self] in self?.close() }
        if let back {
            model.backTitle = back.title
            model.onBack = back.action
        }
        eventModel = model
        present(AnyView(EventPeekView(model: model)), measure: AnyView(EventPeekView(model: model)),
                anchor: anchor ?? NSEvent.mouseLocation, keepTopLeft: keepTopLeft)
        Trace.app("peek", ["kind": "event", "result": "shown"])
        return true
    }

    /// Day Peek (Small Month): that day's meetings for the widget's accounts; rows open the Event Peek
    /// in the same panel, with a way back.
    @discardableResult
    func showDay(kind: String, day: Date, at anchor: NSPoint? = nil, keepTopLeft: Bool = false) -> Bool {
        let model = DayPeekModel(kind: kind, day: day, directory: AccountDirectory.current())
        dayModel = model
        let title = "Back to \(model.title)"
        // Swapping the panel's content from inside its own click handler is deferred one turn.
        let view = DayPeekView(model: model, onSelect: { [weak self] event in
            DispatchQueue.main.async {
                self?.showEvent(r: event.r, keepTopLeft: true, back: (title, { [weak self] in
                    DispatchQueue.main.async { self?.showDay(kind: kind, day: day, keepTopLeft: true) }
                }))
            }
        }, onClose: { [weak self] in self?.close() })
        present(AnyView(view), measure: AnyView(view), anchor: anchor ?? NSEvent.mouseLocation, keepTopLeft: keepTopLeft)
        Trace.app("peek", ["kind": "day", "result": "shown", "n": "\(model.events.count)"])
        return true
    }

    /// Mail Peek for thread `r` (`open/message`): the thread on the paper card, the latest message open;
    /// Reply opens the composer window. False when the thread isn't in the store.
    @discardableResult
    func showMessage(r: String, at anchor: NSPoint? = nil) -> Bool {
        let found: MailThread?
        do {
            found = try Services.mail.thread(r: r)
        } catch {
            found = nil
        }
        guard let thread = found else {
            Trace.app("peek", ["kind": "message", "result": "missing"])
            return false
        }
        let model = MailPeekModel(thread: thread, directory: AccountDirectory.current())
        model.onClose = { [weak self] in DispatchQueue.main.async { self?.close() } }
        model.onReply = { request in DispatchQueue.main.async { ComposerWindowController.open(request) } }
        mailModel = model
        present(AnyView(MailPeekView(model: model)), measure: AnyView(MailPeekView(model: model, measuring: true)),
                anchor: anchor ?? NSEvent.mouseLocation, keepTopLeft: false)
        Task { @MainActor in await model.open() }
        Trace.app("peek", ["kind": "message", "result": "shown"])
        return true
    }

    func close() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        panel?.orderOut(nil)
        eventModel = nil
        dayModel = nil
        mailModel = nil
    }

    // MARK: - Panel

    private func present(_ view: AnyView, measure: AnyView, anchor: NSPoint, keepTopLeft: Bool) {
        let panel = self.panel ?? PeekPanel()
        self.panel = panel
        panel.onEscape = { [weak self] in self?.close() }

        // Natural height of the content at 420 pt; past 560 it scrolls.
        let measuring = NSHostingView(rootView: PeekCard { measure }.fixedSize(horizontal: false, vertical: true))
        let natural = measuring.fittingSize.height
        let height = min(max(natural, 120), PeekPlacement.maxHeight)
        let scrolls = natural > PeekPlacement.maxHeight

        let root = AnyView(
            Group {
                if scrolls {
                    ScrollView(.vertical) { PeekCard { view } }
                        .frame(width: PeekPlacement.width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    PeekCard { view }
                }
            }
            .frame(width: PeekPlacement.width, height: height, alignment: .top)
        )
        let host = PeekHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        let size = CGSize(width: PeekPlacement.width, height: height)
        let frame: NSRect
        if keepTopLeft, panel.isVisible {
            let top = panel.frame.maxY
            let screen = panel.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? panel.frame
            frame = PeekPlacement.frame(size: size, anchor: CGPoint(x: panel.frame.minX - PeekPlacement.offset,
                                                                    y: top + PeekPlacement.offset), visible: visible)
        } else {
            let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
            frame = PeekPlacement.frame(size: size, anchor: anchor, visible: screen?.visibleFrame ?? NSRect(origin: .zero, size: size))
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let panel = self.panel, event.window !== panel { self.close() }
            }
            return event
        }) { monitors.append(local) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let isEscape = event.keyCode == 53
            if isEscape { MainActor.assumeIsolated { self?.close() } }
            return isEscape ? nil : event
        }) { monitors.append(keys) }
    }
}
