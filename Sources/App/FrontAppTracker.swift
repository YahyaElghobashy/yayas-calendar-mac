import AppKit

/// Remembers the last app other than us that was frontmost. A widget tap activates the agent; after a
/// quiet route it hides and must hand the front back to *that* app, because `NSApp.hide` alone lets
/// macOS pick the next app (measured: right only 3 of 8 times).
@MainActor
final class FrontAppTracker {
    static let shared = FrontAppTracker()

    private(set) var memory = FrontAppMemory(ownPid: getpid())
    private var observers: [NSObjectProtocol] = []

    init() {
        if let front = NSWorkspace.shared.frontmostApplication {
            memory.didActivate(pid: front.processIdentifier, bundleId: front.bundleIdentifier)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier ?? 0, bundle = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.memory.didActivate(pid: pid, bundleId: bundle) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            MainActor.assumeIsolated { self?.memory.didTerminate(pid: pid) }
        })
    }

    /// The running app to give the front back to, if any.
    func restoreTarget() -> NSRunningApplication? {
        guard let pid = memory.target(isRunning: { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }) else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Cooperative hand-off (macOS 14+): yield our activation to the target, then ask it to activate
    /// from us. Returns the target asked, nil when there was nothing to restore.
    @discardableResult
    func restore(reason: String) -> NSRunningApplication? {
        let target = restoreTarget()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard FrontRestorePolicy.shouldRestore(agentWasActivated: true, target: target?.processIdentifier, frontmost: frontmost),
              let target else {
            Trace.app("front-restore", ["reason": reason, "front-restored": target == nil ? "0" : "1",
                                        "note": target == nil ? "no-target" : "already-front"])
            return nil
        }
        NSApp.yieldActivation(to: target)
        let asked = target.activate(from: NSRunningApplication.current, options: [])
        let kind = Self.traceKind(target.bundleIdentifier)
        // Did it work? Check once the activation has had time to land (traced for the live tap check).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
            Trace.app("front-restore", [
                "reason": reason,
                "target": kind,
                "asked": asked ? "1" : "0",
                "front-restored": now == target.processIdentifier ? "1" : "0",
            ])
        }
        return target
    }

    /// What the trace says about the app it handed the front to: `self`, `apple` (com.apple.*) or
    /// `other`, never the bundle id (the log must not record which other apps the user runs).
    nonisolated static func traceKind(_ bundleId: String?, own: String? = Bundle.main.bundleIdentifier) -> String {
        guard let bundleId, !bundleId.isEmpty else { return "-" }
        if let own, bundleId == own { return "self" }
        return bundleId.hasPrefix("com.apple.") ? "apple" : "other"
    }
}
