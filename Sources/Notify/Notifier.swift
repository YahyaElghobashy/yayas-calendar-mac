#if !YC_DATA_TESTS
import AppKit
import UserNotifications

/// Notifications in the app: meeting heads-up (Join / Snooze 1 min), re-auth notices, new-mail
/// notices (off by default) and the Deck export. One call from AppDelegate:
///
///     Notifier.install(openSection: { MainWindowController.shared.show($0) })
///
/// It sets the UNUserNotificationCenter delegate and categories, listens to the data engine through
/// `DataServices.observe` (calendar passes, RSVPs, account edits, mail passes), refreshes every
/// 5 minutes, when the time zone changes and when a pause ends. Nothing here logs titles, names,
/// addresses or URLs.
@MainActor
enum Notifier {
    private static var coordinator: NotifyCoordinator?
    private static var delegate: NotifyDelegate?
    private static var timer: Timer?
    private static var resumeTimer: Timer?
    private static var observers: [NSObjectProtocol] = []
    /// The settings last acted on, to spot writes from elsewhere (the popover's pause).
    private static var lastSettings = ""
    static let prefs = DefaultsNotifyPrefs()

    static func install(openSection: @escaping @MainActor (AppSection) -> Void) {
        guard coordinator == nil else { return }
        let center = SystemNoteCenter()
        let deck = DeckExporter(directory: Paths.share, poster: DistributedDeckPoster())
        // Off for a Mac without Deck (D-039): drop a file an earlier build left behind.
        if !DeckSharing.isOn { _ = deck.withdraw() }
        let coordinator = NotifyCoordinator(
            data: EngineNotifyData(), center: center, prefs: prefs, deck: deck,
            deckEnabled: { DeckSharing.isOn },
            trace: { event, detail in Trace.app(event, ["detail": detail]) })
        self.coordinator = coordinator
        let delegate = NotifyDelegate(coordinator: coordinator, openSection: openSection)
        self.delegate = delegate
        let un = UNUserNotificationCenter.current()
        un.delegate = delegate
        un.setNotificationCategories(SystemNoteCenter.categories)

        DataServices.observe { change in coordinator.changed(change) }

        // Backstop: the 24 h / 48 h windows slide even when no account syncs (all signed out, offline).
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in coordinator.changed(.calendar) }
        timer?.tolerance = 30
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange, .NSCalendarDayChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in coordinator.changed(.calendar) })
        }
        // Pause/toggles written by another surface straight into UserDefaults: re-plan and re-arm.
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Notifier.settingsMayHaveChanged() }
        })
        lastSettings = settingsSignature()
        armResume()
        coordinator.changed(.accounts)
    }

    private static func settingsSignature() -> String {
        "\(prefs.meetingsOn)|\(prefs.newMailOn)|\(prefs.pausedUntil?.timeIntervalSince1970 ?? 0)"
    }

    private static func settingsMayHaveChanged() {
        let now = settingsSignature()
        guard now != lastSettings else { return }
        lastSettings = now
        armResume()
        coordinator?.changed(.accounts)
    }

    /// App quitting (AppDelegate.applicationWillTerminate): withdraw pending heads-ups and snoozes.
    static func willTerminate() {
        timer?.invalidate()
        resumeTimer?.invalidate()
        NotifyCleanup.removeHeadsUps()
        Trace.app("notify-quit")
    }

    /// "Remove everything": no more passes, timers or Deck writes (they would recreate the data folder).
    static func shutDown() {
        timer?.invalidate()
        timer = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        coordinator = nil
    }

    /// Settings toggled (meetings, new mail): re-plan now.
    static func settingsChanged() {
        lastSettings = settingsSignature()
        coordinator?.changed(.accounts)
    }

    /// "Pause notifications 1 h" (Settings; the popover may call it too).
    static func pause(for seconds: TimeInterval = 3600) {
        prefs.pausedUntil = Date().addingTimeInterval(seconds)
        Trace.app("notify-pause", ["minutes": "\(Int(seconds / 60))"])
        armResume()
        settingsChanged()
    }

    static func resume() {
        prefs.pausedUntil = nil
        Trace.app("notify-pause", ["minutes": "0"])
        armResume()
        settingsChanged()
    }

    /// When the pause ends, plan again (the heads-ups after it go back in).
    private static func armResume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        guard let until = prefs.pausedUntil, until > Date() else { return }
        let timer = Timer(fire: until.addingTimeInterval(1), interval: 0, repeats: false) { _ in
            Task { @MainActor in Notifier.settingsChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }
}

/// Settings → "Share upcoming meetings with Deck" on this Mac (D-039), "… with Deck and Yaya's Murmur" while Murmur is
/// installed (D-046).
enum DeckSharing {
    nonisolated(unsafe) private static var cached: (installed: Bool, at: Date)?

    /// Deck registers the `deck:` URL scheme; sharing starts on only when an app that handles it carries
    /// Deck's own bundle id (`DeckIdentity`). Any other handler of the scheme leaves it off. Cached for 10 minutes.
    static var deckInstalled: Bool {
        if let cached, Date().timeIntervalSince(cached.at) < 600 { return cached.installed }
        var found = false
        if let probe = URL(string: "deck:") {
            found = NSWorkspace.shared.urlsForApplications(toOpen: probe).contains { app in
                DeckIdentity.isDeck(bundleId: Bundle(url: app)?.bundleIdentifier)
            }
        }
        cached = (found, Date())
        return found
    }

    /// Yaya's Murmur reads the same file (D-046): installed, it turns sharing on as Deck does.
    static var murmurInstalled: Bool { MurmurLive.installedFlag.get() }

    static var stored: Bool? { UserDefaults.standard.object(forKey: DeckExportSetting.key) as? Bool }
    static var isOn: Bool {
        DeckExportSetting.isOn(stored: stored, deckInstalled: deckInstalled, murmurInstalled: murmurInstalled)
    }

    /// The switch: off withdraws the file now (and pings Deck); on writes it with the next pass.
    @MainActor static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: DeckExportSetting.key)
        if !on { _ = DeckExporter(directory: Paths.share, poster: DistributedDeckPoster()).withdraw() }
        Trace.app("deck-export", ["on": on ? "1" : "0"])
        Notifier.settingsChanged()
    }
}

/// Notes that must not outlive the process that planned them. Each waits for usernoted at most
/// `seconds` per round trip, so the removal lands before the process exits.
enum NotifyCleanup {
    /// `--uninstall`: heads-ups already handed to the system would still fire after the app is gone
    /// (with a Join nobody can answer), so every pending and delivered note goes, and the Deck export
    /// is withdrawn (file deleted, then the no-payload ping).
    static func removeAll(waitingAtMost seconds: TimeInterval = 0.8) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        roundTrip(center, seconds)
        DeckExporter(directory: Paths.share, poster: DistributedDeckPoster()).withdraw()
    }

    /// Quit: pending heads-ups and snoozes go (nobody would answer their Join or Snooze); the next
    /// launch plans them again. Re-auth and mail notes are left alone.
    static func removeHeadsUps(waitingAtMost seconds: TimeInterval = 0.8) {
        let center = UNUserNotificationCenter.current()
        let ids = LockedIds()
        let done = DispatchSemaphore(value: 0)
        center.getPendingNotificationRequests { requests in
            ids.set(requests.map(\.identifier).filter(HeadsUp.isManaged))
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return }
        let managed = ids.get()
        guard !managed.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: managed)
        roundTrip(center, seconds)
    }

    private static func roundTrip(_ center: UNUserNotificationCenter, _ seconds: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        center.getPendingNotificationRequests { _ in done.signal() }
        _ = done.wait(timeout: .now() + seconds)
    }

    private final class LockedIds: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func set(_ value: [String]) { lock.lock(); ids = value; lock.unlock() }
        func get() -> [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }
}

/// First caller wins (a reply racing its timeout).
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// UNUserNotificationCenter adapter.
final class SystemNoteCenter: NoteCenter, @unchecked Sendable {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    static var categories: Set<UNNotificationCategory> {
        let join = UNNotificationAction(identifier: NoteIds.joinAction, title: "Join", options: [])
        let fathom = UNNotificationAction(identifier: NoteIds.fathomAction, title: "Join with Fathom", options: [])
        let murmur = UNNotificationAction(identifier: NoteIds.murmurAction, title: "Join with Yaya\u{2019}s Murmur", options: [])
        let ask = UNNotificationAction(identifier: NoteIds.askAction, title: "Join and record\u{2026}", options: [])
        let snooze = UNNotificationAction(identifier: NoteIds.snoozeAction, title: "Snooze 1 min", options: [])
        let fix = UNNotificationAction(identifier: NoteIds.fixAction, title: "Sign in again", options: [.foreground])
        return [
            UNNotificationCategory(identifier: NoteIds.meetingCategory, actions: [join, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NoteIds.meetingFathomCategory, actions: [join, fathom, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NoteIds.meetingMurmurCategory, actions: [join, murmur, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NoteIds.meetingAskCategory, actions: [join, ask, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NoteIds.meetingNoLinkCategory, actions: [snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NoteIds.reauthCategory, actions: [fix], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NoteIds.mailCategory, actions: [], intentIdentifiers: [], options: []),
        ]
    }

    func authorizationStatus() async -> NoteAuth {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func authorize() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// At most 5 s: a stuck usernoted must not freeze every later pass.
    func pending() async -> [PendingNote]? {
        let center = self.center
        return await withCheckedContinuation { (continuation: CheckedContinuation<[PendingNote]?, Never>) in
            let once = OnceGate()
            center.getPendingNotificationRequests { requests in
                guard once.claim() else { return }
                continuation.resume(returning: requests.map { request in
                    let info = request.content.userInfo
                    return PendingNote(id: request.identifier, fingerprint: info["fp"] as? String,
                                       fireAt: (info["fire"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
                })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                guard once.claim() else { return }
                continuation.resume(returning: nil)
            }
        }
    }

    func add(_ note: LocalNote) async throws {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.categoryIdentifier = note.category
        content.threadIdentifier = note.thread
        if note.sound { content.sound = .default }
        var info: [String: String] = note.userInfo
        info["fp"] = note.fingerprint
        content.userInfo = info
        let trigger: UNNotificationTrigger?
        switch note.trigger {
        case .calendar(let components)?:
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .interval(let seconds)?:
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        case nil:
            trigger = nil
        }
        try await center.add(UNNotificationRequest(identifier: note.id, content: content, trigger: trigger))
    }

    func removePending(_ ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func removeDelivered(_ ids: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// Banner actions. Join opens the store's link after the allowlist check; Snooze re-arms in 60 s;
/// a click on a meeting opens Calendar, on a re-auth notice Accounts, on a mail notice Inbox.
final class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let coordinator: NotifyCoordinator
    let openSection: @MainActor (AppSection) -> Void

    init(coordinator: NotifyCoordinator, openSection: @escaping @MainActor (AppSection) -> Void) {
        self.coordinator = coordinator
        self.openSection = openSection
    }

    /// The agent is often frontmost (popover, main window): show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String, value.count <= 256 { info[key] = value }
        }
        let action = response.actionIdentifier
        let coordinator = self.coordinator
        let open = self.openSection
        Task {
            await Self.handle(action: action, info: info, coordinator: coordinator, open: open)
            completionHandler()
        }
    }

    private static func handle(action: String, info: [String: String], coordinator: NotifyCoordinator,
                               open: @escaping @MainActor (AppSection) -> Void) async {
        let kind = info["kind"] ?? "-"
        // An action can launch the app: give the store a moment to open before reading it.
        if [NoteIds.joinAction, NoteIds.fathomAction, NoteIds.murmurAction, NoteIds.askAction, NoteIds.snoozeAction].contains(action) {
            _ = await coordinator.waitUntilReady(5)
        }
        switch action {
        case NoteIds.joinAction:
            guard let url = await coordinator.joinURL(userInfo: info) else {
                Trace.app("notify-action", ["action": "join", "result": "blocked"])
                return
            }
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            Trace.app("notify-action", ["action": "join", "result": opened ? "opened" : "failed"])
        case NoteIds.fathomAction:
            // Records with the meeting's Fathom account, or the Event Peek waits for Fathom to switch (D-045).
            guard let event = await coordinator.event(userInfo: info) else {
                Trace.app("notify-action", ["action": "fathom", "result": "blocked"])
                return
            }
            await MainActor.run {
                switch FathomSession.shared.join(event, directory: AccountDirectory.current(), via: "heads-up") {
                case .waiting:
                    PeekController.shared.showEvent(r: event.r)
                case .notLinked:
                    if let url = event.joinURL, JoinGuard.isAllowed(url) { NSWorkspace.shared.open(url) }
                case .started, .blocked:
                    break
                }
            }
        case NoteIds.murmurAction:
            // Join with Yaya's Murmur (D-046): its join link for the event, then the meeting.
            guard let event = await coordinator.event(userInfo: info) else {
                Trace.app("notify-action", ["action": "murmur", "result": "blocked"])
                return
            }
            await MainActor.run {
                if MurmurSession.shared.join(event, mode: nil, via: "heads-up") == .notInstalled,
                   let url = event.joinURL, JoinGuard.isAllowed(url) {
                    NSWorkspace.shared.open(url)
                }
            }
        case NoteIds.askAction:
            // "Join and record…" (D-046): the Event Peek, where the Join menu offers every recorder.
            guard let event = await coordinator.event(userInfo: info) else {
                Trace.app("notify-action", ["action": "ask", "result": "blocked"])
                return
            }
            await MainActor.run { PeekController.shared.showEvent(r: event.r) }
            Trace.app("notify-action", ["action": "ask", "result": "peek"])
        case NoteIds.snoozeAction:
            let ok = await coordinator.snooze(userInfo: info)
            Trace.app("notify-action", ["action": "snooze", "result": ok ? "ok" : "ignored"])
        case NoteIds.fixAction:
            await MainActor.run { open(.accounts) }
            Trace.app("notify-action", ["action": "fix"])
        case UNNotificationDefaultActionIdentifier:
            let section: AppSection
            switch kind {
            case "reauth": section = .accounts
            case "mail": section = .inbox
            default: section = .calendar
            }
            await MainActor.run { open(section) }
            Trace.app("notify-action", ["action": "open", "kind": kind])
        default:
            break
        }
    }
}

/// The Deck ping: a distributed notification with no object and no userInfo (any process can hear it,
/// so it says nothing but "the file changed").
final class DistributedDeckPoster: DeckChangePoster, @unchecked Sendable {
    func post() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(DeckExport.changedNotification), object: nil, userInfo: nil, deliverImmediately: true)
    }
}
#endif
