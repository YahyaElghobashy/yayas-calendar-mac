import Foundation

/// Polling policy, outcome mapping, the per-account loop, and the engine's error handling.
enum SchedulerTests {
    static func run() async {
        policy()
        outcomes()
        await loop()
        await engineOutcomes()
    }

    static func policy() {
        let t = SyncTiming()
        func next(_ o: SyncOutcome, _ f: Int = 0, visible: Bool = false, jitter: Double = 0) -> SyncPolicy.Decision {
            SyncPolicy.next(after: o, failures: f, visible: visible, timing: t, jitter: jitter)
        }
        expect(next(.ok).delay == 120 && next(.ok).interruptible, "every 2 minutes")
        expect(next(.ok, visible: true).delay == 60, "every minute while a surface is visible")
        expect(next(.ok, jitter: -1).delay == 110 && next(.ok, jitter: 1).delay == 130 && next(.ok, jitter: 7).delay == 130,
               "±10 s jitter, clamped")
        let r1 = next(.rateLimited(retryAfter: nil))
        let r2 = next(.rateLimited(retryAfter: nil), r1.failures)
        let r3 = next(.serverError(retryAfter: nil), r2.failures)
        expect(r1.delay == 240 && r2.delay == 480 && r3.delay == 960, "exponential backoff on 429/403/5xx")
        expect(!r1.interruptible, "wake/network pokes don't cut a server backoff short")
        expect(next(.serverError(retryAfter: nil), 10).delay == 1800, "backoff capped at 30 minutes")
        expect(next(.rateLimited(retryAfter: 3600), 0).delay == 3600, "Retry-After honoured beyond the backoff")
        expect(next(.ok, r3.failures).failures == 0, "success resets the backoff")
        let locked = next(.keychainLocked, 3)
        expect(locked.delay == 120 && locked.failures == 0 && locked.interruptible, "locked keychain: retry at the normal pace")
        expect(next(.offline).delay == 120 && next(.reauthNeeded).delay == 120, "offline / reauth: normal pace (pokes wake it)")
    }

    static func outcomes() {
        expect(SyncOutcome(error: AuthError.reauthNeeded(code: "invalid_grant")) == .reauthNeeded, "invalid_grant → reauth")
        expect(SyncOutcome(error: AuthError.reauthNeeded(code: "interaction_required")) == .failed("auth_interaction_required"),
               "other reauth codes are hiccups, not sign-outs")
        for status: OSStatus in [-25308, -25320, -60008] {
            expect(SyncOutcome(error: KeychainError(status: status)) == .keychainLocked, "keychain \(status) → retry later")
        }
        expect(SyncOutcome(error: TokenManagerError.persistFailed(.locked(-25308))) == .keychainLocked, "persist failed while locked")
        expect(SyncOutcome(error: GoogleAPIError.rateLimited(retryAfter: 5)) == .rateLimited(retryAfter: 5), "429 → rateLimited")
        expect(SyncOutcome(error: GoogleAPIError.server(status: 503, retryAfter: nil)) == .serverError(retryAfter: nil), "5xx")
        expect(SyncOutcome(error: AuthError.offline) == .offline && SyncOutcome(error: GoogleAPIError.offline) == .offline, "offline")
        expect(SyncOutcome(error: GoogleAPIError.forbidden(reason: "x")).code == "forbidden_x", "codes")
        expect(SyncOutcome(error: CancellationError()) == .cancelled, "cancelled")
        expect(SyncOutcome(error: URLError(.badURL)) == .failed("unexpected"), "unknown errors")
    }

    static func loop() async {
        let runs = Locked(0)
        let forced = Locked(0)
        let outcome = Locked<SyncOutcome>(.ok)
        let passLength = Locked<UInt64>(20_000_000)
        let loop = AccountSyncLoop(accountId: UUID(), work: { force in
            runs.value += 1
            if force { forced.value += 1 }
            try? await Task.sleep(nanoseconds: passLength.value)
            return outcome.value
        }, decide: { o, f in
            o.backsOff ? SyncPolicy.Decision(delay: 60, failures: f + 1, interruptible: false)
                       : SyncPolicy.Decision(delay: 60, failures: 0, interruptible: true)
        })
        await loop.start()
        do { let ok = await eventually(2) { runs.value == 1 }; expect(ok, "loop runs a pass at start") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        expect(runs.value == 1, "then waits")
        await loop.poke()
        do { let ok = await eventually(2) { runs.value == 2 }; expect(ok, "poke (wake/network) syncs at once") }
        await loop.syncNow()
        expect(runs.value == 3 && forced.value == 1, "syncNow waits for a forced pass to finish")

        // Pokes during a pass coalesce into one more pass.
        passLength.value = 300_000_000
        await loop.poke()
        do { let ok = await eventually(2) { runs.value == 4 }; expect(ok, "pass 4 running") }
        await loop.poke()
        await loop.poke()
        passLength.value = 20_000_000
        do { let ok = await eventually(3) { runs.value == 5 }; expect(ok, "pokes during a pass → another pass") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(runs.value == 5, "…exactly one")

        outcome.value = .serverError(retryAfter: nil)
        await loop.poke()
        do { let ok = await eventually(2) { runs.value == 6 }; expect(ok, "pass that hits a 5xx") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await loop.poke()
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(runs.value == 6, "a plain poke doesn't cut a server backoff short")
        outcome.value = .ok
        await loop.syncNow()
        expect(runs.value == 7, "a forced sync does")
        do { let ok = await loop.lastOutcome == .ok; expect(ok, "last outcome recorded") }

        await loop.stop()
        let before = runs.value
        await loop.poke()
        await loop.syncNow()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let stillRunning = await loop.isRunning
        expect(runs.value == before && !stillRunning, "stopped loop does nothing and syncNow returns")
    }

    static func engineOutcomes() async {
        let h = Harness("scheduler-engine")
        let (a, _) = h.account("y@orb.example", tag: "ORB", sort: 0)
        let engine = h.engine
        let tokens = h.source.tokens.value[a.id]!

        tokens.error.value = KeychainError.locked(-25308)
        let locked = await engine.syncAccount(a.id, force: false)
        expect(locked == .keychainLocked && h.source.reauthMarked.value.isEmpty, "locked keychain → retry later, never reauth")
        expect(SyncStatusRepo(db: h.db).lastError(a.id) == "keychain_locked", "error code recorded")
        expect((try? AccountRepo(db: h.db).get(a.id))?.health == .ok, "account health untouched")

        tokens.error.value = nil
        h.google.inject("calendarList", status: 429, body: "{}", headers: ["retry-after": "120"])
        let limited = await engine.syncAccount(a.id, force: false)
        expect(limited == .rateLimited(retryAfter: 120), "429 surfaces as rateLimited with Retry-After")

        let ok = await engine.syncAccount(a.id, force: false)
        expect(ok == .ok && SyncStatusRepo(db: h.db).lastError(a.id) == nil, "success clears the error")
        expect(SyncStatusRepo(db: h.db).lastSuccess(a.id) == h.clock.now, "last success recorded")
        expect(h.snapshot("agenda.all")?.health.state == .ok, "snapshot published after the pass")

        tokens.error.value = AuthError.reauthNeeded(code: "invalid_grant")
        let dead = await engine.syncAccount(a.id, force: false)
        expect(dead == .reauthNeeded && h.source.reauthMarked.value == [a.id], "invalid_grant → AccountsModel told")
        expect(h.snapshot("agenda.all")?.health.state == .reauth, "widget shows the reauth chip")
        h.google.clearLog()
        let waiting = await engine.syncAccount(a.id, force: false)
        expect(waiting == .waitingForUser && h.google.requests.isEmpty, "reauth-needed account isn't polled")

        _ = try? AccountRepo(db: h.db).setHealth(a.id, .ok, detail: nil)
        tokens.error.value = nil
        h.source.tokens.mutate { $0[a.id] = nil }
        do { let ok = await engine.syncAccount(a.id, force: false) == .notReady; expect(ok, "no token source (client missing) → not ready") }
        var off = (try? AccountRepo(db: h.db).get(a.id)) ?? nil
        off?.calendarEnabled = false
        if let off { _ = try? AccountRepo(db: h.db).update(off) }
        do { let ok = await engine.syncAccount(a.id, force: false) == .skipped; expect(ok, "calendar off → skipped") }
        do { let ok = await engine.syncAccount(UUID(), force: false) == .skipped; expect(ok, "unknown account → skipped") }
    }
}
