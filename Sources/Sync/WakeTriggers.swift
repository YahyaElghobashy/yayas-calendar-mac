// Wake, unlock and network-return triggers adapted from the author's own earlier code (MIT; portions © the
// author). See THIRD_PARTY_NOTICES.md.

import AppKit
import Foundation
import Network

/// Syncs the moment the Mac is usable again instead of waiting for the next poll: system wake, screen
/// wake, unlock, the user session coming back, and the network returning (wake often comes before
/// Wi-Fi). Several arrive together on a wake; one call answers them.
@MainActor
final class WakeTriggers {
    private let fire: () -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var network: NetworkReturn?
    private var pending: DispatchWorkItem?

    init(fire: @escaping () -> Void) {
        self.fire = fire
    }

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(after: 0.5) }
            }
            observers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let unlock = distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 0.5) }
        }
        observers.append((distributed, unlock))
        let network = NetworkReturn { [weak self] in
            Task { @MainActor in self?.schedule(after: 1.5) }
        }
        network.start()
        self.network = network
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        network?.stop()
        network = nil
        pending?.cancel()
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Reports the network coming back. It only watches the path status the system already knows; it
/// opens no connection and sends nothing.
final class NetworkReturn: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: Profile.scoped("network-return"))
    private let onReturn: @Sendable () -> Void
    private var wasSatisfied: Bool?

    init(onReturn: @escaping @Sendable () -> Void) {
        self.onReturn = onReturn
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            // Only the transition from offline to online, never the first report.
            if self.wasSatisfied == false, satisfied { self.onReturn() }
            self.wasSatisfied = satisfied
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
