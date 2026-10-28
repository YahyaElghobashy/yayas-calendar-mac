import AppKit
import Carbon

/// ⌃⌥J from anywhere: joins the meeting that's on now or starting within 30 minutes (allowlisted
/// links only), otherwise opens the menu-bar popover. Carbon `RegisterEventHotKey`: no Accessibility
/// permission, no event tap. J was picked to avoid common ⌃⌥ shortcuts; ⌃⌥ is also VoiceOver's modifier, so
/// the hotkey steps aside while VoiceOver runs. Settings → "Join with ⌃⌥J" turns it off.
@MainActor
final class JoinHotkeyCenter {
    static let shared = JoinHotkeyCenter()

    /// 'YCJN'
    private static let signature: OSType = 0x5943_4A4E
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []
    private var voiceOver: NSKeyValueObservation?
    private(set) var state: HotkeyState = .off

    func start() {
        guard observers.isEmpty else { return }
        MenuBarSettingsModel.liveState = { MainActor.assumeIsolated { JoinHotkeyCenter.shared.state } }
        observers.append(NotificationCenter.default.addObserver(forName: MenuBarPrefs.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { JoinHotkeyCenter.shared.apply() }
        })
        voiceOver = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { JoinHotkeyCenter.shared.apply() } }
        }
        apply()
    }

    /// Registers or unregisters to match Settings and VoiceOver.
    func apply() {
        let wanted = MenuBarPrefs.hotkeyEnabled()
        let voiceOverOn = NSWorkspace.shared.isVoiceOverEnabled
        guard wanted, !voiceOverOn else {
            unregister()
            state = wanted ? .pausedForVoiceOver : .off
            return
        }
        register()
    }

    private func register() {
        guard ref == nil else { state = .on; return }
        installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(JoinHotkey.keyCode, UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &newRef)
        if status == noErr, let newRef {
            ref = newRef
            state = .on
        } else {
            state = status == OSStatus(eventHotKeyExistsErr) ? .taken : .failed
        }
        Trace.app("hotkey", ["action": "register", "result": status == noErr ? "ok" : "\(status)"])
    }

    private func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        Trace.app("hotkey", ["action": "unregister"])
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C callback captures nothing: it checks the id and hops to the main actor's singleton.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == JoinHotkeyCenter.signature, id.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { JoinHotkeyCenter.shared.pressed() } }
            return noErr
        }, 1, &spec, nil, &handler)
        if status != noErr { Trace.app("hotkey", ["action": "handler", "result": "\(status)"]) }
    }

    /// What ⌃⌥J does right now (HotkeyDecision, tested).
    func pressed(now: Date = Date()) {
        let events = (try? Services.calendar.events(from: now, to: now.addingTimeInterval(MeetingFocus.joinEarly + 60), accounts: nil)) ?? []
        switch HotkeyDecision.decide(events, now: now) {
        case .join(_, let url):
            // The decision only returns allowlisted links; checked once more right before opening.
            guard JoinPolicy.isAllowed(url) else { return }
            let opened = NSWorkspace.shared.open(url)
            Trace.app("hotkey", ["action": "join", "result": opened ? "opened" : "failed"])
        case .openPopover:
            Trace.app("hotkey", ["action": "popover"])
            MenuPopoverController.shared.show(reason: "hotkey")
        }
    }
}
