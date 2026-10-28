import Foundation

/// Every Keychain call in the app runs on one serial background queue, never on the main thread.
///
/// Why (2026-10-20, live): after an install the app froze at launch. The main thread sat in
/// `SecItemCopyMatching` (AccountsModel → OAuthConfig.load → KeychainStore.read → securityd) while macOS
/// showed its legacy "allow access" dialog for the item: `kSecUseAuthenticationUIFail` does not suppress
/// the access-list dialog of a file-based keychain item. While it waited, no widget link, status item or
/// window could run.
///
/// - `sync` (KeychainStore, TokenManager's reads, the data layer): runs the call on the queue and waits
///   at most `slowAfter` (3 s). A call still running then is *stuck* (a dialog is up): the caller gets
///   `KeychainError.waiting`, and every later `sync` fails at once with the same error until the stuck
///   call returns (no thread piles up behind a dialog). The stuck call itself finishes normally.
/// - `run` (AccountsModel): `async`, on the same queue; `onSlow` fires once if it hasn't finished after
///   `slowAfter` ("Waiting for Keychain access"), and the result still arrives when it does.
/// - On the main thread `sync` never touches the Keychain: `mainThreadViolation` runs (a trap in DEBUG
///   and `YC_KEYCHAIN_ASSERT` test builds) and the call fails with `.waiting`. Headless flags
///   (`--uninstall --purge`, which exit and have no UI to block) set `allowMainThread`.
///
/// Never calls `SecKeychainSetUserInteractionAllowed` (docs/CONTRACTS.md, Keychain).
final class KeychainGate: @unchecked Sendable {
    static let shared = KeychainGate()

    /// Posted on the main queue when the gate becomes stuck or recovers (`isStuck`).
    static let changed = Notification.Name(Profile.scoped("keychainGateChanged"))

    /// What a Keychain call on the main thread does. Debug/test builds trap; release builds trace it
    /// (the call itself fails with `.waiting`, so the main thread never waits on securityd).
    nonisolated(unsafe) static var mainThreadViolation: @Sendable (String) -> Void = { operation in
        #if DEBUG || YC_KEYCHAIN_ASSERT
        preconditionFailure("Keychain call on the main thread: \(operation)")
        #else
        trace("keychain-main-thread", operation)
        #endif
    }

    /// PII-free trace (event, operation name). Tests point `Trace` at their scratch folder.
    nonisolated(unsafe) static var trace: @Sendable (String, String) -> Void = { event, operation in
        Trace.app(event, ["op": operation])
    }

    /// Headless flags only (they run on the main thread before any UI and exit).
    nonisolated(unsafe) static var allowMainThread = false

    let slowAfter: TimeInterval
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<ObjectIdentifier>()
    private let lock = NSLock()
    private var running = 0
    private var stuckSince: Date?

    init(label: String = Profile.scoped("keychain"), slowAfter: TimeInterval = 3) {
        self.slowAfter = slowAfter
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: key, value: ObjectIdentifier(self))
    }

    /// True while a call has been running longer than `slowAfter` (a Keychain dialog is waiting).
    var isStuck: Bool { lock.lock(); defer { lock.unlock() }; return stuckSince != nil }

    private var onQueue: Bool { DispatchQueue.getSpecific(key: key) == ObjectIdentifier(self) }

    /// False (after reporting it) when `operation` would run on the main thread.
    static func mayRun(_ operation: String) -> Bool {
        guard Thread.isMainThread, !allowMainThread else { return true }
        mainThreadViolation(operation)
        return false
    }

    /// Runs `body` on the gate's queue and waits up to `slowAfter`. See the type's notes.
    func sync<T>(_ operation: String, _ body: @escaping () throws -> T) throws -> T {
        if onQueue { return try body() }
        guard Self.mayRun(operation) else { throw KeychainError.waiting }
        if Thread.isMainThread {   // headless flags only: no UI to block, so no time limit
            return try queue.sync(execute: body)
        }
        if isStuck { throw KeychainError.waiting }
        let box = KeychainResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        begin()
        queue.async {
            box.result = Result { try body() }
            self.end()
            done.signal()
        }
        guard done.wait(timeout: .now() + slowAfter) == .success else {
            markStuck(operation)
            throw KeychainError.waiting
        }
        return try box.get()
    }

    /// Async form for UI models: `onSlow` (main queue) once the call has run `slowAfter`.
    func run<T: Sendable>(_ operation: String, onSlow: (@MainActor @Sendable () -> Void)? = nil,
                          _ body: @escaping @Sendable () throws -> T) async throws -> T {
        begin()
        let finished = OnceFlag()
        let slowAfter = self.slowAfter
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(slowAfter * 1_000_000_000))
            // Only for this call, while it still runs (the flag is claimed when it ends).
            guard !Task.isCancelled, !finished.isClaimed else { return }
            self?.markStuck(operation)
            onSlow?()
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                let result = Result { try body() }
                _ = finished.claim()
                self.end()
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Bookkeeping

    private func begin() {
        lock.lock(); running += 1; lock.unlock()
    }

    private func end() {
        lock.lock()
        running -= 1
        let recovered = stuckSince != nil && running == 0
        if recovered { stuckSince = nil }
        lock.unlock()
        if recovered { post() }
    }

    private func markStuck(_ operation: String) {
        lock.lock()
        let first = stuckSince == nil && running > 0
        if first { stuckSince = Date() }
        lock.unlock()
        if first {
            Self.trace("keychain-slow", operation)
            post()
        }
    }

    private func post() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
    }
}

private final class KeychainResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
    func get() throws -> T {
        guard let result else { throw KeychainError.waiting }
        return try result.get()
    }
}
