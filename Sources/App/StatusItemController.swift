import AppKit

/// The menu-bar item: the way into an LSUIElement app. Left click toggles the popover; right click
/// (or control-click) shows the menu: Open, Sync now, Pause notifications for an hour, Settings…, Quit.
/// Beside the icon, the next meeting's countdown ("Standup · 7m", "Standup · 12m left") or the unread
/// count, per Settings → "Menu bar shows", redrawn on every minute boundary.
///
/// macOS 27 closes a status item's menu when its image is larger than 20×15 pt, so the glyph is clamped
/// to that box; the title is text beside it. No NSMenuItem images (macOS 27 menus don't draw them).
/// The glyph is the Yaya mark (MenuBarIcon.png + @2x, Tools/MakeIcons.swift); the SF Symbol "calendar"
/// stands in when the bundle has none (tests, a build without resources).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let openMain: () -> Void
    private let openSettings: () -> Void
    private let popover: MenuPopoverController
    private var tick: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var title = ""

    init(openMain: @escaping () -> Void, openSettings: @escaping () -> Void,
         popover: MenuPopoverController = .shared) {
        self.openMain = openMain
        self.openSettings = openSettings
        self.popover = popover
    }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.glyph()
            button.imagePosition = .imageOnly
            button.toolTip = "Yaya\u{2019}s Calendar"
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Yaya\u{2019}s Calendar")
            button.setAccessibilityHelp("Shows your next meetings. Right-click or control-click for more.")
            popover.statusButton = button
            popover.onShownChange = { [weak button] shown in button?.highlight(shown) }
        }
        self.item = item
        refreshTitle()
        scheduleTick()
        observe()
    }

    // MARK: - Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            popover.toggle()
        }
    }

    /// The menu is attached only while it shows (detached in `menuDidClose`), so a left click keeps
    /// opening the popover.
    private func showMenu() {
        guard let item, let button = item.button else { return }
        popover.close(reason: "menu")
        let menu = makeMenu()
        menu.delegate = self
        item.menu = menu
        button.performClick(nil)
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        // Detach on the next turn: the item's own click handling may still be unwinding.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.item?.menu === menu else { return }
                self.item?.menu = nil
            }
        }
    }

    private func makeMenu(now: Date = Date()) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: "Open Yaya\u{2019}s Calendar", key: "") { [weak self] in self?.openMain() })
        menu.addItem(ClosureMenuItem(title: "Sync now", key: "") {
            Trace.app("menu", ["action": "sync"])
            Task { await Services.calendarActions.syncNow() }
        })
        menu.addItem(.separator())
        if let until = NotificationPause.pausedUntil(now: now) {
            menu.addItem(ClosureMenuItem(title: "Resume notifications (paused until \(StatusItemController.clock(until)))", key: "") {
                NotificationPause.resume()
                Trace.app("menu", ["action": "notifications-resume"])
            })
        } else {
            menu.addItem(ClosureMenuItem(title: "Pause notifications for 1 hour", key: "") {
                NotificationPause.pause()
                Trace.app("menu", ["action": "notifications-pause"])
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings\u{2026}", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Yaya\u{2019}s Calendar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    /// "10:48 AM" in the Mac's own clock style.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Title

    /// Recomputes the title from the store (local SQLite; a couple of hours of events or one count).
    func refreshTitle(now: Date = Date()) {
        let mode = MenuBarPrefs.mode()
        var focus: CalendarEvent?
        var unread: Int?
        switch mode {
        case .icon:
            break
        case .next:
            let events = (try? Services.calendar.events(from: now, to: now.addingTimeInterval(2 * 3600), accounts: nil)) ?? []
            focus = MeetingFocus.pick(events, now: now)
        case .unread:
            unread = try? Services.mail.unreadCount(accounts: nil)
        }
        let text = StatusTitle.text(mode: mode, focus: focus, unread: unread, mailEnabled: true, now: now)
        let spoken = StatusTitle.spoken(mode: mode, focus: focus, unread: unread, mailEnabled: true, now: now)
        apply(text, spoken: spoken)
    }

    private func apply(_ text: String, spoken: String) {
        guard let button = item?.button else { return }
        button.setAccessibilityValue(spoken.isEmpty ? nil : spoken)
        button.toolTip = spoken.isEmpty ? "Yaya\u{2019}s Calendar" : spoken
        guard text != title else { return }
        let appeared = title.isEmpty != text.isEmpty
        title = text
        if text.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        } else {
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: Self.titleFont])
            button.imagePosition = .imageLeading
        }
        // Only when a title appears or goes (not every minute of a countdown): the log stays small.
        if appeared { Trace.app("status-title", ["mode": MenuBarPrefs.mode().rawValue, "chars": "\(text.count)"]) }
    }

    /// The menu bar's own size, with digits of equal width so "9m" → "10m" doesn't jiggle neighbours.
    static var titleFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    /// Fires just after every minute boundary (a repeating timer keeps its grid, also across sleep).
    private func scheduleTick() {
        tick?.invalidate()
        let next = (floor(Date().timeIntervalSinceReferenceDate / 60) + 1) * 60 + 0.05
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// Wake, clock and time-zone changes realign the tick; preference changes redraw at once.
    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let realign: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (center, .NSSystemClockDidChange),
            (center, .NSSystemTimeZoneDidChange),
            (center, .NSCalendarDayChanged),
        ]
        for (nc, name) in realign {
            observers.append((nc, nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshTitle()
                    self?.scheduleTick()
                }
            }))
        }
        observers.append((center, center.addObserver(forName: MenuBarPrefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }))
    }

    static let maxGlyph = NSSize(width: 20, height: 15)

    static func glyph() -> NSImage? {
        if let mark = brandGlyph() { return mark }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Yaya\u{2019}s Calendar"),
              let image = symbol.withSymbolConfiguration(config) else { return nil }
        let size = image.size
        let scale = min(1, maxGlyph.width / max(size.width, 1), maxGlyph.height / max(size.height, 1))
        image.size = NSSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        image.isTemplate = true
        return image
    }

    /// The hand-tuned 1x sprite and the @2x vector render as one 20 × 15 pt template image (AppKit
    /// picks the representation for the screen). Nil when either file is missing from the bundle.
    static func brandGlyph(in bundle: Bundle = .main) -> NSImage? {
        let image = NSImage(size: maxGlyph)
        for name in ["MenuBarIcon", "MenuBarIcon@2x"] {
            guard let url = bundle.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { return nil }
            rep.size = maxGlyph
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Yaya\u{2019}s Calendar"
        return image
    }
}

/// With `.regular` activation (main window open) AppKit-hosted text fields need a main menu with Edit
/// commands, or ⌘C/⌘V do nothing (Provider Setup pastes client IDs there).
enum MainMenu {
    @MainActor
    static func build(openSettings: @escaping () -> Void) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Yaya's Calendar")
        let settings = ClosureMenuItem(title: "Settings…", key: ",", action: openSettings)
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Yaya's Calendar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Yaya's Calendar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(FormatMenu.pasteAndMatchStyle())
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu(edit))
        main.addItem(submenu(FormatMenu.build()))

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu(window))
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// A menu item that runs a closure (keeps the menu free of a dedicated target class).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, key: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { run() }
}
