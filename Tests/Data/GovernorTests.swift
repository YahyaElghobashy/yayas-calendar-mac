import CryptoKit
import Foundation

enum LinkTests {
    static func run() {
        let keys = FakeLinkKeys()
        let links = LinkTokens(store: keys)
        expect(links.prepare() == true && keys.saves.value == 1 && keys.stored.value?.count == 32, "32-byte key created once")
        expect(links.prepare() == false && keys.saves.value == 1, "second prepare keeps the key")
        let again = LinkTokens(store: keys)
        again.prepare()
        expect(keys.saves.value == 1 && again.k(for: "r1") == links.k(for: "r1"), "a new run loads the same key")

        let r = "gAbCdEfGhIjKlMnOpQrStUv"
        let k = links.k(for: r)
        let manual = Data(HMAC<SHA256>.authenticationCode(for: Data(r.utf8), using: SymmetricKey(data: keys.stored.value!)))
        expect(k == Data(manual.prefix(12)).base64URLEncodedString(), "k = base64url(first 12 bytes of HMAC-SHA256(key, r))")
        expect(k.count == 16 && !k.contains("=") && Route.isSafeValue(k), "k is 16 link-safe characters")
        expect(links.verify(r: r, k: k), "valid k verifies")
        var tampered = Array(k)
        tampered[5] = tampered[5] == "A" ? "B" : "A"
        expect(!links.verify(r: r, k: String(tampered)), "tampered k rejected")
        expect(!links.verify(r: r + "x", k: k), "k for another r rejected")
        expect(!links.verify(r: r, k: String(k.dropLast())) && !links.verify(r: r, k: k + "A") && !links.verify(r: r, k: ""),
               "wrong-length k rejected")
        expect(!links.verify(r: "", k: k), "empty r rejected")
        expect(!links.verify(r: r, k: "!!!!!!!!!!!!!!!!"), "non-base64 k rejected")

        // Locked keychain at launch: an in-memory key stands in, then the real one is swapped in.
        let lockedKeys = FakeLinkKeys()
        lockedKeys.stored.value = keys.stored.value
        lockedKeys.locked.value = true
        let late = LinkTokens(store: lockedKeys)
        expect(late.prepare() == true && late.isEphemeral, "locked keychain → ephemeral key, no prompt")
        let temporary = late.k(for: r)
        expect(late.verify(r: r, k: temporary) && lockedKeys.saves.value == 0, "ephemeral links verify; nothing written")
        expect(late.prepare() == false, "still locked → keep the ephemeral key")
        lockedKeys.locked.value = false
        expect(late.prepare() == true && !late.isEphemeral, "unlocked → the stored key replaces it")
        expect(late.k(for: r) == k && !late.verify(r: r, k: temporary), "real key in use; ephemeral links now stale")
        expect(lockedKeys.saves.value == 0, "an existing key is never overwritten")

        let corrupt = FakeLinkKeys()
        corrupt.stored.value = Data([1, 2, 3])
        let fixed = LinkTokens(store: corrupt)
        fixed.prepare()
        expect(corrupt.stored.value?.count == 32 && !fixed.isEphemeral, "a damaged key is replaced with a fresh one")
    }
}

enum GovernorTests {
    static func run() {
        let clock = TestClock(TestCal.labNow)
        let reloader = FakeReloader()
        let gov = ReloadGovernor(reloader: reloader, budget: 15 * 60, now: clock.closure)

        gov.changed("agenda.all", content: 1, significant: 1, interaction: false)
        expect(reloader.count("agenda.all") == 1, "first background change reloads at once")
        clock.advance(60)
        gov.changed("agenda.all", content: 2, significant: 2, interaction: false)
        expect(reloader.count("agenda.all") == 1 && gov.isPending("agenda.all"), "second change within 15 min waits")
        expect(gov.nextDue() == TestCal.labNow.addingTimeInterval(15 * 60), "due when the budget reopens")
        clock.set(TestCal.labNow.addingTimeInterval(15 * 60 - 1))
        gov.tick()
        expect(reloader.count("agenda.all") == 1, "not a second early")
        clock.set(TestCal.labNow.addingTimeInterval(15 * 60))
        gov.tick()
        expect(reloader.count("agenda.all") == 2 && !gov.isPending("agenda.all"), "deferred reload sent at 15:00")

        // Only the sync time changed: written, never spends the budget, and a tap's flush leaves it alone
        // while the widget's own sync time is fresh (every sync pass moves it in every snapshot).
        clock.advance(20 * 60)
        gov.changed("agenda.all", content: 3, significant: 2, interaction: false)
        gov.tick()
        expect(reloader.count("agenda.all") == 2 && !gov.isPending("agenda.all"), "syncedAt-only change: no background reload")
        gov.flushChanged()
        expect(reloader.count("agenda.all") == 2, "flush skips a sync-time-only change")
        gov.reloadIfChanged("agenda.all")
        expect(reloader.count("agenda.all") == 3, "an interaction on that kind still takes it along")
        gov.flushChanged()
        expect(reloader.count("agenda.all") == 3, "flush again: nothing changed")

        // Interactions: immediate, and they don't consume the background budget.
        gov.changed("month", content: 10, significant: 10, interaction: true)
        expect(reloader.count("month") == 1, "interaction reloads at once")
        gov.changed("month", content: 11, significant: 11, interaction: true)
        expect(reloader.count("month") == 2, "every interaction reloads, budget or not")
        gov.changed("month", content: 12, significant: 12, interaction: false)
        expect(reloader.count("month") == 3, "interaction reloads leave the background budget untouched")

        // Flush touches only changed kinds; seeded kinds reload once on the first flush.
        gov.seed("upnext", content: 99)
        gov.seed("upnext", content: 98)
        gov.changed("custom.a", content: 5, significant: 5, interaction: false)
        clock.advance(60)
        gov.changed("custom.a", content: 6, significant: 6, interaction: false)
        reloader.reset()
        gov.flushChanged()
        expect(Set(reloader.reloads.value) == ["upnext", "custom.a"], "flush: pending + seeded kinds only")
        gov.tick()
        expect(reloader.reloads.value.count == 2, "a flushed change is not sent again by the budget")
        gov.reloadIfChanged("upnext")
        expect(reloader.reloads.value.count == 2, "interaction with nothing new: no reload")

        keepAlive()
    }

    /// The widget shows "Last synced …" 30 min after the sync time it holds: a sync-time-only change goes
    /// out once that copy is 24 min old (budgeted in the background, free on a flush), never sooner, so
    /// the keep-alive alone stays within 60 reloads a day per kind (WidgetKit's daily budget).
    static func keepAlive() {
        let clock = TestClock(TestCal.labNow)
        let reloader = FakeReloader()
        let gov = ReloadGovernor(reloader: reloader, budget: 15 * 60, now: clock.closure)
        expect(gov.keepAlive == 24 * 60, "keep-alive at 24 min (the strip shows at 30)")
        let t0 = TestCal.labNow
        gov.changed("month", content: 1, significant: 1, syncedAt: t0, interaction: false)
        expect(reloader.count("month") == 1 && gov.state("month")?.reloadedSyncedAt == t0, "first change reloads, the widget holds t0")
        for minute in stride(from: 2, through: 22, by: 2) {
            clock.set(t0.addingTimeInterval(Double(minute) * 60))
            gov.changed("month", content: UInt64(10 + minute), significant: 1, syncedAt: clock.now, interaction: false)
            gov.tick()
        }
        gov.flushChanged()
        expect(reloader.count("month") == 1, "sync passes for 22 min: no reload, not even on a flush (was: one at 15 min)")
        expect(gov.nextDue() == t0.addingTimeInterval(24 * 60), "next due when the widget's copy is 24 min old")
        clock.set(t0.addingTimeInterval(24 * 60))
        gov.changed("month", content: 40, significant: 1, syncedAt: clock.now, interaction: false)
        expect(reloader.count("month") == 2 && gov.state("month")?.reloadedSyncedAt == t0.addingTimeInterval(24 * 60),
               "24 min: the keep-alive goes out, 6 min before the strip would show")
        clock.set(t0.addingTimeInterval(40 * 60))
        gov.changed("month", content: 41, significant: 1, syncedAt: clock.now, interaction: false)
        gov.flushChanged()
        expect(reloader.count("month") == 2, "a flush leaves a 16 min old copy alone")
        clock.set(t0.addingTimeInterval(48 * 60))
        gov.changed("month", content: 42, significant: 1, syncedAt: clock.now.addingTimeInterval(-60), interaction: false)
        gov.flushChanged()
        expect(reloader.count("month") == 3, "a flush sends a due keep-alive at once (free while active)")

        // A day of sync passes every 2 min (ticks every 30 s), nothing else: the keep-alive alone.
        let day = ReloadGovernor(reloader: reloader, budget: 15 * 60, now: clock.closure)
        reloader.reset()
        let d0 = t0.addingTimeInterval(3600)
        clock.set(d0)
        day.changed("agenda.all", content: 1, significant: 1, syncedAt: d0, interaction: false)
        reloader.reset()
        var held = d0, oldest: TimeInterval = 0, content: UInt64 = 1
        for step in 1...(24 * 120) {   // 30 s steps
            clock.set(d0.addingTimeInterval(Double(step) * 30))
            if step % 4 == 0 {
                content += 1
                day.changed("agenda.all", content: content, significant: 1, syncedAt: clock.now, interaction: false)
            }
            day.tick()
            if let h = day.state("agenda.all")?.reloadedSyncedAt { held = h }
            oldest = max(oldest, clock.now.timeIntervalSince(held))
        }
        let perDay = reloader.count("agenda.all")
        expect(perDay <= 60 && perDay >= 58, "a day of sync passes alone: \(perDay) keep-alive reloads (≤ 60; was 96)")
        expect(oldest < WidgetHealthInfo.staleAfter - 5 * 60,
               "…and the widget's copy is never older than \(Int(oldest / 60)) min (the strip shows at 30)")

        reloader.reset()
        gov.seed("agenda.all", content: 5, syncedAt: t0)
        clock.set(t0.addingTimeInterval(40 * 60))
        gov.changed("agenda.all", content: 6, significant: 0, syncedAt: clock.now, interaction: false)
        expect(reloader.count("agenda.all") == 1, "a seeded kind's significant change reloads in the background as before")
    }
}
