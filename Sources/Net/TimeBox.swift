import Foundation

/// Waits for a task's value at most `seconds`, without cancelling it: nil when the time ran out, and the
/// task keeps running (its result can still be awaited). `withTimeBudget` (Accounts) cancels its work
/// instead, which suits cancellable network calls but not a sync pass that should finish anyway.
enum TimeBox {
    static func wait<T: Sendable>(_ seconds: TimeInterval, for task: Task<T, Never>) async -> T? {
        let once = OnceFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task {
                let value = await task.value
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// True for the first caller of `claim()` only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    var isClaimed: Bool { lock.lock(); defer { lock.unlock() }; return claimed }

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
