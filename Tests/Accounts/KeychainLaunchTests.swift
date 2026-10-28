import Foundation

/// D-021, the live freeze: after an install the app hung at launch with the main thread in
/// `SecItemCopyMatching` (AccountsModel.kickOff → reloadProviderStatus → OAuthConfig.load) behind macOS's
/// "allow access" dialog, and no widget link was handled meanwhile. Here the vault and the client store
/// take 5 s (a dialog nobody has answered yet) and the launch path runs as in the app; the main thread
/// must stay free (a ping link is parsed and decided like the router does, within 200 ms), Accounts
/// says "Waiting for Keychain access" after 3 s with a one-time notice, and everything lands once the
/// calls return.
@MainActor
enum KeychainLaunchTests {
    static func run() async {
        await slowKeychainAtLaunch()
    }

    /// Like `LinkRouter.handle`'s first step for `yayacal://ping`: how long the main thread takes to get to it.
    static func pingLatency(_ probe: String) async -> (TimeInterval, RouteAction?) {
        let asked = Date()
        let action: RouteAction? = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let route = Route.parse(URL(string: "yayacal://ping?probe=\(probe)")!)
                continuation.resume(returning: route.map { RouteDecider.decide($0) { _, _ in false } })
            }
        }
        return (Date().timeIntervalSince(asked), action)
    }

    static func slowKeychainAtLaunch() async {
        let dir = AccountsTests.folder("keychain-slow-launch")
        let (vault, ids) = ModelTests.seededVault()
        let clients = FakeClientStore([.google: Fixtures.googleClient])
        vault.listDelay = 5
        clients.loadDelay = 5
        var env = Fixtures.environment(dir: dir, vault: vault, clients: clients, recorders: Fixtures.Recorders())
        env.keychain = KeychainGate(label: "com.yahyaelghobashy.yayascalendar.test-slow-launch", slowAfter: 3)
        let model = AccountsModel(environment: env)
        let started = Date()
        func at(_ seconds: TimeInterval) async {
            let wait = seconds - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }

        model.start()   // the app's launch path (AppDelegate → start → kickOff → bootstrap)
        var latencies: [TimeInterval] = []
        var decided = true
        func ping(_ n: Int) async {
            let (latency, action) = await pingLatency("launch\(n)")
            latencies.append(latency)
            decided = decided && action == .ping("launch\(n)")
        }

        await at(0.5)
        await ping(0)
        expect(model.google == .checking, "slow keychain: Provider Setup says checking… while the client is read")
        expect(model.storeProblem == nil && !model.keychainWaiting, "slow keychain: store open, not waiting yet")

        await at(3.4)
        await ping(1)
        expect(model.google == .waitingForKeychain, "slow keychain: after 3 s → waiting for Keychain access")
        expect(model.keychainWaiting && model.keychainNotice == AccountsModel.keychainNoticeText,
               "slow keychain: the friendly notice (click Always Allow)")

        await at(5.6)
        await ping(2)
        expect(model.google.isReady, "slow keychain: the client arrives when the read returns")
        expect(model.keychainNotice == nil, "slow keychain: notice gone once the Keychain answered")

        await at(8.5)
        await ping(3)
        expect(model.keychainWaiting && model.keychainNotice == nil,
               "slow keychain: the adoption read is slow too → waiting again, but the notice was one-time")

        let landed = await AccountsTests.eventually(8) { model.accounts.count == 4 && !model.keychainWaiting }
        await ping(4)
        expect(landed, "slow keychain: the four accounts are adopted once the vault answers")
        expect(Set(model.accounts.map(\.id)) == Set(ids.values), "slow keychain: same ids as the Keychain items")
        let checked = await AccountsTests.eventually(5) { model.checking.isEmpty && model.record(ids["orb"]!)?.health == .ok }
        expect(checked, "slow keychain: health checked afterwards (ORB ok)")

        expect(decided, "slow keychain: every ping link decided as a ping")
        expect(latencies.count == 5 && latencies.allSatisfy { $0 < 0.2 },
               "slow keychain: the main thread handled every ping within 200 ms (max \(Int((latencies.max() ?? 9) * 1000)) ms)")
        expect(vault.mainThreadCalls == 0 && clients.mainThreadCalls == 0,
               "slow keychain: no vault or client-store call ran on the main thread")
    }
}
