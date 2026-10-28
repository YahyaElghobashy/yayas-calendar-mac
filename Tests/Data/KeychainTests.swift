import Foundation

/// D-021, data side: `KeychainGate` (serial background queue, 3 s → `.waiting`, fail fast while stuck,
/// the main-thread guard) and the widget link key loading off the main thread, so a Keychain dialog
/// never holds up a tap's publish.
enum KeychainTests {
    static func run() async {
        await gateBasics()
        await mainThreadGuard()
        await slowLinkKeyNeverBlocksATap()
    }

    /// `gate.sync` from a background thread, as KeychainStore's callers do.
    static func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: Result { try body() }) }
        }
    }

    static func isWaiting<T>(_ result: Result<T, Error>) -> Bool {
        if case .failure(let error) = result, let keychain = error as? KeychainError { return keychain == .waiting }
        return false
    }

    static func gateBasics() async {
        let gate = KeychainGate(label: "com.yahyaelghobashy.yayascalendar.test-gate", slowAfter: 0.25)
        let fast = await background { try gate.sync("fast") { 42 } }
        expect((try? fast.get()) == 42, "gate: a quick call returns its value")
        expect(!gate.isStuck, "gate: not stuck")

        // A call that hangs (a dialog): the caller gets .waiting after slowAfter, the gate is stuck, and
        // the next caller fails at once instead of queueing behind it.
        let released = Locked(false)
        let started = Date()
        let slow = await background {
            try gate.sync("slow") { () -> Int in
                while !released.value { Thread.sleep(forTimeInterval: 0.01) }
                return 1
            }
        }
        let waited = Date().timeIntervalSince(started)
        expect(isWaiting(slow) && waited >= 0.24 && waited < 1, "gate: a hung call answers .waiting after slowAfter (\(String(format: "%.2f", waited)) s)")
        expect(gate.isStuck && KeychainError.waiting.isTransient, "gate: stuck; .waiting is transient (retry later)")
        let quick = Date()
        let behind = await background { try gate.sync("behind") { 2 } }
        expect(isWaiting(behind) && Date().timeIntervalSince(quick) < 0.1, "gate: while stuck, callers fail fast")
        let recovered = Locked(false)
        let observer = NotificationCenter.default.addObserver(forName: KeychainGate.changed, object: gate, queue: .main) { _ in
            if !gate.isStuck { recovered.value = true }
        }
        released.value = true
        do { let ok = await eventually(2) { !gate.isStuck && recovered.value }; expect(ok, "gate: recovers (and says so) once the call returns") }
        NotificationCenter.default.removeObserver(observer)
        let after = await background { try gate.sync("after") { 3 } }
        expect((try? after.get()) == 3, "gate: works again after recovering")

        // The async form keeps waiting for the real answer and reports the slow moment once.
        let slowCalls = Locked(0)
        let value = try? await gate.run("slow-run", onSlow: { slowCalls.value += 1 }) { () -> Int in
            Thread.sleep(forTimeInterval: 0.5)
            return 7
        }
        expect(value == 7 && slowCalls.value == 1, "gate: run returns the late result; onSlow fired once")
        do { let ok = await eventually(1) { !gate.isStuck }; expect(ok, "gate: free after the slow run") }
        let quiet = Locked(0)
        _ = try? await gate.run("fast-run", onSlow: { quiet.value += 1 }) { 1 }
        try? await Task.sleep(nanoseconds: 400_000_000)
        expect(quiet.value == 0 && !gate.isStuck, "gate: a quick run never reports slow")

        // Re-entry from the gate's own queue runs inline (no deadlock).
        let nested = try? await gate.run("outer") { try gate.sync("inner") { 5 } }
        expect(nested == 5, "gate: sync inside run runs inline")
        let thrown = await background { try gate.sync("throws") { () -> Int in throw KeychainError.notFound } }
        if case .failure(let error) = thrown { expect(error as? KeychainError == .notFound, "gate: errors pass through") }
        else { expect(false, "gate: errors pass through") }
    }

    /// The debug assertion: a Keychain call on the main thread traps in DEBUG / YC_KEYCHAIN_ASSERT builds
    /// (this binary). The handler is swapped for a recorder here; the guard runs before any SecItem call,
    /// so nothing reaches the real Keychain.
    static func mainThreadGuard() async {
        await MainActor.run {
            expect(Thread.isMainThread, "guard: on the main thread")
            let saved = KeychainGate.mainThreadViolation
            let seen = Locked<[String]>([])
            KeychainGate.mainThreadViolation = { operation in seen.mutate { $0.append(operation) } }
            defer { KeychainGate.mainThreadViolation = saved }
            let store = KeychainStore(service: "com.yahyaelghobashy.yayascalendar.test-never-written")
            func waiting(_ body: () throws -> Void) -> Bool {
                do { try body(); return false } catch { return (error as? KeychainError) == .waiting }
            }
            expect(waiting { _ = try store.read(account: "never") }, "guard: read on main refused")
            expect(waiting { try store.save(Data([1]), account: "never") }, "guard: save on main refused")
            expect(waiting { _ = try store.delete(account: "never") }, "guard: delete on main refused")
            expect(waiting { _ = try store.entries() }, "guard: entries on main refused")
            expect(seen.value == ["read", "save", "delete", "entries"], "guard: every main-thread call reported (traps in debug)")
            expect(waiting { _ = try KeychainLinkKeyStore().load() } && seen.value.count == 4,
                   "guard: the link key store answers .waiting on main without asking the Keychain")
            expect(waiting { _ = try TokenVault(service: "com.yahyaelghobashy.yayascalendar.test-never-written").read(UUID()) },
                   "guard: TokenVault on main refused")
            expect(waiting { _ = try OAuthConfig.load(.google) }, "guard: OAuthConfig.load on main refused (the live freeze)")
            expect(seen.value.count == 6, "guard: …both reported")
            expect(!KeychainGate.allowMainThread, "guard: main thread not allowed outside headless flags")
        }
        let fromBackground = await background { KeychainGate.mayRun("background") }
        expect((try? fromBackground.get()) == true, "guard: background threads may run")
    }

    /// The link key store answers `.waiting` on main (like `KeychainLinkKeyStore`) and takes 1.5 s off
    /// main (a Keychain dialog). The engine starts off the main thread, as the app does; a widget tap on
    /// the main thread meanwhile publishes at once.
    final class SlowLinkKeys: LinkKeyStore, @unchecked Sendable {
        let stored = Locked<Data?>(nil)
        let delay: TimeInterval
        let mainCalls = Locked(0)
        init(delay: TimeInterval) { self.delay = delay }
        func load() throws -> Data? {
            if Thread.isMainThread { mainCalls.value += 1; throw KeychainError.waiting }
            Thread.sleep(forTimeInterval: delay)
            return stored.value
        }
        func save(_ key: Data) throws {
            if Thread.isMainThread { mainCalls.value += 1; throw KeychainError.waiting }
            stored.value = key
        }
    }

    static func slowLinkKeyNeverBlocksATap() async {
        let h = Harness("keychain-slow-link-key")
        let keys = SlowLinkKeys(delay: 1.5)
        h.env.linkKeys = keys
        let (orb, token) = h.account("y@orb.example", tag: "ORB", sort: 0)
        h.google.put(token: token, calendar: "y@orb.example",
                     G.timed("e1", "Planning", "2026-10-19T12:00:00+01:00", "2026-10-19T13:00:00+01:00"))
        let engine = h.engine
        let start = Task.detached { engine.start() }
        try? await Task.sleep(nanoseconds: 150_000_000)   // the background publish is now waiting on the key
        let tapMs: Double = await MainActor.run {
            let t0 = DispatchTime.now().uptimeNanoseconds
            engine.widgets.page(kind: "agenda.all", family: "L", to: 2)
            _ = engine.widgets.verify(r: "nope", k: "AAAAAAAAAAAAAAAA")
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        }
        expect(tapMs < 200, "slow key: a tap publishes in \(String(format: "%.0f", tapMs)) ms while the key loads (< 200)")
        expect(keys.mainCalls.value == 0, "slow key: the main thread never asked the store (it was busy elsewhere)")
        await start.value
        expect(!engine.links.isEphemeral && keys.stored.value?.count == 32, "slow key: the stored key is in use once read")
        _ = await engine.syncAccount(orb.id, force: true)
        let meeting = h.snapshot("agenda.all")?.meetings.first
        expect(meeting.map { engine.links.verify(r: $0.r, k: $0.k) } == true, "slow key: published links verify with it")
    }
}
