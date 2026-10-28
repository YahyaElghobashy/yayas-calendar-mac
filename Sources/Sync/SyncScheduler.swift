import Foundation

/// How one account's sync pass ended. Codes are short and PII-free (diagnostics, settings).
enum SyncOutcome: Equatable, Sendable {
    case ok
    /// Calendar off, account gone or not Google.
    case skipped
    /// Sign in again / admin / Provider Setup: nothing to do until the user acts.
    case waitingForUser
    /// No token source yet (OAuth client missing or unreadable).
    case notReady
    /// Locked keychain, dark wake, or a read that would prompt: retry later, never "sign in again".
    case keychainLocked
    case offline
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(retryAfter: TimeInterval?)
    /// Google said invalid_grant: AccountsModel is told, the account waits for a new sign-in.
    case reauthNeeded
    case cancelled
    case failed(String)

    init(error: Error) {
        switch error {
        case AuthError.reauthNeeded(let code) where code == "invalid_grant":
            self = .reauthNeeded
        case AuthError.reauthNeeded(let code):
            self = .failed("auth_\(Self.safe(code))")
        case AuthError.adminBlocked:
            self = .failed("admin_blocked")
        case AuthError.offline, AuthError.timedOut:
            self = .offline
        case AuthError.server:
            self = .serverError(retryAfter: nil)
        case AuthError.notConfigured:
            self = .notReady
        case let keychain as KeychainError where keychain.isTransient:
            self = .keychainLocked
        case TokenManagerError.persistFailed(let keychain) where keychain.isTransient:
            self = .keychainLocked
        case let api as GoogleAPIError:
            switch api {
            case .rateLimited(let after): self = .rateLimited(retryAfter: after)
            case .server(_, let after): self = .serverError(retryAfter: after)
            case .offline: self = .offline
            default: self = .failed(api.code)
            }
        case is CancellationError:
            self = .cancelled
        case let keychain as KeychainError:
            self = .failed("keychain_\(keychain)")
        default:
            self = .failed("unexpected")
        }
    }

    private static func safe(_ code: String) -> String {
        String(code.prefix(32).filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    var code: String {
        switch self {
        case .ok: return "ok"
        case .skipped: return "skipped"
        case .waitingForUser: return "waiting_for_user"
        case .notReady: return "not_ready"
        case .keychainLocked: return "keychain_locked"
        case .offline: return "offline"
        case .rateLimited: return "rate_limited"
        case .serverError: return "server_error"
        case .reauthNeeded: return "reauth_needed"
        case .cancelled: return "cancelled"
        case .failed(let code): return code
        }
    }

    /// Server-side trouble: back off exponentially.
    var backsOff: Bool {
        switch self {
        case .rateLimited, .serverError: return true
        default: return false
        }
    }
}

/// Polling numbers (D-015): every 2 minutes, every minute while a surface (popover, main
/// window) is visible, ±10 s jitter, exponential backoff on 429 / 403 rate limits / 5xx.
struct SyncTiming: Sendable {
    var interval: TimeInterval = 120
    var visibleInterval: TimeInterval = 60
    var jitter: TimeInterval = 10
    var backoffCap: TimeInterval = 30 * 60
    /// The widget shows "stale" when an included account's last good sync is older than this.
    var staleAfter: TimeInterval = 15 * 60
    /// Background reload budget per widget kind (measured: macOS honours background reloads unevenly).
    var reloadBudget: TimeInterval = 15 * 60
    /// A flipped page returns to page 1 after this long.
    var pageReset: TimeInterval = 5 * 60
    /// How often the engine checks for midnight and due reloads.
    var tick: TimeInterval = 30
    /// Mail (D-018): every minute, every 30 s while a surface is visible; same jitter and backoff.
    var mailInterval: TimeInterval = 60
    var mailVisibleInterval: TimeInterval = 30

    /// The same policy with the mail intervals.
    var forMail: SyncTiming {
        var copy = self
        copy.interval = mailInterval
        copy.visibleInterval = mailVisibleInterval
        return copy
    }
}

enum SyncPolicy {
    struct Decision: Equatable, Sendable {
        var delay: TimeInterval
        var failures: Int
        /// Wake / unlock / network pokes may cut the wait short (not during a server backoff; a forced
        /// "Sync now" always can).
        var interruptible: Bool
    }

    /// `jitter` is a random number in -1…1.
    static func next(after outcome: SyncOutcome, failures: Int, visible: Bool, timing: SyncTiming,
                     jitter: Double) -> Decision {
        let base = visible ? timing.visibleInterval : timing.interval
        let wobble = max(-1, min(1, jitter)) * timing.jitter
        guard outcome.backsOff else {
            return Decision(delay: max(1, base + wobble), failures: 0, interruptible: true)
        }
        let count = failures + 1
        let backoff = min(base * pow(2, Double(count)), timing.backoffCap)
        var retryAfter: TimeInterval = 0
        switch outcome {
        case .rateLimited(let after), .serverError(let after): retryAfter = after ?? 0
        default: break
        }
        return Decision(delay: max(1, max(backoff, retryAfter) + wobble), failures: count, interruptible: false)
    }
}

/// One account's polling loop. Runs `work` (a sync pass), sleeps per `SyncPolicy`, and wakes early on
/// `poke` (wake, unlock, network return, a visible surface) or `syncNow`. Passes never overlap.
actor AccountSyncLoop {
    typealias Work = @Sendable (_ force: Bool) async -> SyncOutcome
    typealias Decide = @Sendable (_ outcome: SyncOutcome, _ failures: Int) -> SyncPolicy.Decision

    nonisolated let accountId: UUID
    private let work: Work
    private let decide: Decide
    private let clock: @Sendable () -> Date

    private var task: Task<Void, Never>?
    private var sleeper: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?
    private var sleepGeneration = 0
    private var sleepingInterruptible = true
    private var pokePending = false
    private var forcePending = false
    private var failures = 0
    private var stopped = false
    private var started = 0
    private var completed = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    private(set) var lastOutcome: SyncOutcome?
    private(set) var lastRunAt: Date?
    private(set) var runs = 0

    init(accountId: UUID, clock: @escaping @Sendable () -> Date = { Date() }, work: @escaping Work,
         decide: @escaping Decide) {
        self.accountId = accountId
        self.clock = clock
        self.work = work
        self.decide = decide
    }

    func start() {
        guard task == nil, !stopped else { return }
        task = Task { await self.run() }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
        wakeSleeper()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume() }
    }

    /// Sync soon. `force` re-lists every window and also cuts a server backoff short.
    func poke(force: Bool = false) {
        guard !stopped else { return }
        pokePending = true
        if force { forcePending = true }
        if sleepingInterruptible || force { wakeSleeper() }
    }

    /// Starts a forced pass and returns when a pass that began after this call has finished.
    func syncNow() async {
        guard !stopped, task != nil else { return }
        let target = started + 1
        poke(force: true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((target, continuation))
        }
    }

    var isRunning: Bool { task != nil && !stopped }

    /// A widget's ↻: a forced pass (as `syncNow`) unless the loop is sleeping off a server backoff (429 /
    /// 5xx), which a refresh never cuts short. Returns false then (nothing ran), true once a pass that
    /// began after this call has finished.
    func refreshNow() async -> Bool {
        guard !stopped, task != nil else { return false }
        if sleeper != nil && !sleepingInterruptible { return false }
        await syncNow()
        return true
    }

    // MARK: - Loop

    private func run() async {
        while !Task.isCancelled && !stopped {
            started += 1
            let force = forcePending
            forcePending = false
            pokePending = false
            let outcome = await work(force)
            lastOutcome = outcome
            lastRunAt = clock()
            runs += 1
            completed += 1
            resumeWaiters()
            if Task.isCancelled || stopped { break }
            let decision = decide(outcome, failures)
            failures = decision.failures
            if pokePending && (decision.interruptible || forcePending) { continue }
            await sleep(decision.delay, interruptible: decision.interruptible)
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume() }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { $0.target <= completed }
        waiters.removeAll { $0.target <= completed }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func sleep(_ seconds: TimeInterval, interruptible: Bool) async {
        sleepGeneration += 1
        let generation = sleepGeneration
        sleepingInterruptible = interruptible
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sleeper = continuation
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.timerFired(generation)
            }
        }
        sleepingInterruptible = true
    }

    private func timerFired(_ generation: Int) {
        guard generation == sleepGeneration else { return }
        wakeSleeper()
    }

    private func wakeSleeper() {
        timer?.cancel()
        timer = nil
        if let sleeper {
            self.sleeper = nil
            sleeper.resume()
        }
    }
}
