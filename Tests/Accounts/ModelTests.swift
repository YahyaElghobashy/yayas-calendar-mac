import Foundation

@MainActor
enum ModelTests {
    static func run() async {
        await bootstrapAdoptsAndChecks()
        await lockedAtLaunchRecovers()
        await missingClientAndProviderSetup()
        await addAccountFlows()
        await removeAccount()
        await editing()
    }

    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    /// Four sample accounts: ORB ok, CMT signed out, FAM blocked, personal offline; plus a probe item.
    static func seededVault() -> (FakeVault, [String: UUID]) {
        let vault = FakeVault()
        var ids: [String: UUID] = [:]
        let rows: [(String, String, String)] = [
            ("orb", "you@orbitalpickle.example", "rt-ok-orb"),
            ("cmt", "you@quietcomets.example", "rt-dead-cmt"),
            ("fam", "you@moonfieldfamily.example", "rt-blocked-fam"),
            ("personal", consumerAddress("you"), "rt-offline-personal"),
        ]
        for (index, row) in rows.enumerated() {
            let id = UUID()
            ids[row.0] = id
            let at = t0.addingTimeInterval(Double(index) * 60)
            vault.put(Fixtures.credential(row.1, token: row.2, savedAt: at), account: id.uuidString, createdAt: at)
        }
        vault.put(nil, account: "probe-1", createdAt: t0)
        return (vault, ids)
    }

    static func bootstrapAdoptsAndChecks() async {
        let dir = AccountsTests.folder("model-bootstrap")
        let (vault, ids) = seededVault()
        let clients = FakeClientStore([.google: Fixtures.googleClient])
        let recorders = Fixtures.Recorders()
        let logo = LogoTests.pngData(width: 180, height: 180)
        let model = AccountsModel(environment: Fixtures.environment(dir: dir, vault: vault, clients: clients,
                                                                    recorders: recorders, logo: logo))
        await model.bootstrap()

        expect(model.storeProblem == nil, "store opened in the scratch folder")
        expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("store.sqlite").path), "store created under .work")
        expect(model.accounts.map(\.tag) == ["ORB", "QUI", "MOO", "Personal"], "four accounts adopted in connection order")
        expect(model.accounts.map(\.id) == [ids["orb"]!, ids["cmt"]!, ids["fam"]!, ids["personal"]!],
               "rows reuse the Keychain UUIDs")
        expect(model.lastAdoption.ignored == ["probe-1"], "probe item ignored")
        expect(vault.deleted.isEmpty, "adoption never deletes Keychain items")
        // The hint is "…" plus the last six characters, never the whole client id (Provider Setup's rule lives in AccountsModel).
        expect(model.google == .ready(clientIDHint: AccountsModel.clientHint(Fixtures.googleClient.clientId)),
               "Google client ready, shown as a short hint")
        if case .ready(let hint) = model.google {
            expect(hint.hasPrefix("\u{2026}") && hint.count == 7 && !Fixtures.googleClient.clientId.hasPrefix(hint),
                   "the hint is the cut tail, not the client id")
        }

        let health = Dictionary(uniqueKeysWithValues: model.accounts.map { ($0.tag, $0.health) })
        expect(health["ORB"] == .ok, "ORB refreshes → ok")
        expect(health["QUI"] == .reauthNeeded, "invalid_grant → sign in again")
        expect(health["MOO"] == .adminBlocked, "admin policy → blocked")
        expect(health["Personal"] == .offline, "offline → offline")
        expect(model.checking.isEmpty, "no account left in checking")
        expect(model.checkedAt.count == 4, "every account has a check time")
        expect(model.accounts.first { $0.tag == "QUI" }?.healthDetail?.contains("Sign in again") == true, "friendly detail stored")
        expect(model.attentionCount == 2, "two accounts need the user")

        expect(Set(recorders.logoDomains.value) == ["orbitalpickle.example", "quietcomets.example", "moonfieldfamily.example"],
               "logos fetched for the three Workspace domains, never gmail.com")
        expect(model.accounts.filter { $0.tag != "Personal" }.allSatisfy { $0.logoFile == "\($0.id.uuidString).png" },
               "logo files recorded")
        expect(model.logos.count == 3, "logos loaded for display")
        expect(model.accounts.first { $0.tag == "Personal" }?.logoFile == nil, "personal stays blank")

        // Persisted: a second model on the same store adopts nothing new and reads the same rows.
        let again = AccountsModel(environment: Fixtures.environment(dir: dir, vault: vault, clients: clients,
                                                                    recorders: Fixtures.Recorders()))
        again.openStore()
        let secondLaunch = await again.adoptKeychainItems()
        expect(secondLaunch.isEmpty, "second launch adopts nothing")
        again.reload()
        expect(again.accounts.map(\.tag) == ["ORB", "QUI", "MOO", "Personal"], "rows persisted")
        expect(again.accounts.first { $0.tag == "QUI" }?.health == .reauthNeeded, "health persisted")

        // A locked keychain read is "retry later", never "sign in again".
        vault.lockedIDs = [ids["orb"]!]
        await model.checkHealth([ids["orb"]!])
        expect(model.record(ids["orb"]!)?.health == .keychainLocked, "locked keychain → retry later")
        vault.lockedIDs = []
        await model.checkHealth([ids["orb"]!])
        expect(model.record(ids["orb"]!)?.health == .ok, "unlocked → ok again")

        // A new item appearing later (another Mac session, a probe) is adopted on the next start.
        let late = UUID()
        vault.put(Fixtures.credential("you@newco.example", token: "rt-ok-late", savedAt: t0 + 999), account: late.uuidString,
                  createdAt: t0 + 999)
        let lateAdopted = await model.adoptKeychainItems()
        expect(lateAdopted == [late], "late item adopted")
        model.reload()
        expect(model.record(late)?.tag == "NEW" && model.record(late)?.color == AppTheme.accountSwatches[4],
               "late item gets the next tag and colour")
    }

    /// Keychain locked at launch (login, dark wake): nothing is lost, and a later pass picks it all up.
    static func lockedAtLaunchRecovers() async {
        let (vault, ids) = seededVault()
        vault.lockedIDs = [ids["orb"]!]
        let clients = FakeClientStore([.google: Fixtures.googleClient])
        clients.loadError = KeychainError.locked(-25320)
        let model = AccountsModel(environment: Fixtures.environment(dir: AccountsTests.folder("model-locked-launch"),
                                                                    vault: vault, clients: clients,
                                                                    recorders: Fixtures.Recorders(), retryDelay: 0.1))
        await model.bootstrap()
        expect(model.google == .locked, "client unreadable while locked")
        expect(model.record(ids["orb"]!) == nil && model.lastAdoption.unreadable == [ids["orb"]!],
               "locked item not adopted yet, not lost")
        expect(model.accounts.allSatisfy { $0.health == .keychainLocked }, "everything waits as 'retry later'")
        expect(vault.deleted.isEmpty, "nothing deleted while locked")

        vault.lockedIDs = []
        clients.loadError = nil
        await expectEventually("retry adopts the unlocked item", seconds: 5) { model.record(ids["orb"]!) != nil }
        await expectEventually("retry re-checks health once unlocked", seconds: 5) {
            model.google.isReady && model.record(ids["orb"]!)?.health == .ok
                && model.accounts.first { $0.tag == "QUI" }?.health == .reauthNeeded
        }
    }

    static func missingClientAndProviderSetup() async {
        let dir = AccountsTests.folder("model-setup")
        let (vault, _) = seededVault()
        let clients = FakeClientStore()
        let devDir = dir.appendingPathComponent("Config", isDirectory: true)
        try? FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        let devFile = devDir.appendingPathComponent("oauth.local.json")
        try? Data(#"{"google":{"clientId":"77-dev\#(Fixtures.googleSuffix)","clientSecret":"dev-fixture"},"microsoft":{"clientId":"00000000-0000-0000-0000-000000000000"}}"#.utf8)
            .write(to: devFile)
        let recorders = Fixtures.Recorders()
        let model = AccountsModel(environment: Fixtures.environment(dir: dir, vault: vault, clients: clients,
                                                                    recorders: recorders, devFile: devFile))
        await model.bootstrap()
        expect(model.google == .missing, "no client → missing")
        expect(model.accounts.count == 4, "adoption does not depend on the Google client")
        expect(model.accounts.allSatisfy { $0.health == .setupNeeded }, "without a client every account waits for setup")
        expect(model.devClientFile == devFile, "developer file offered")

        // A Web client is refused with a reason; nothing saved.
        model.importClientData(Data(#"{"web":{"client_id":"x","client_secret":"y"}}"#.utf8))
        expect(clients.clients.isEmpty && model.notice?.text.contains("Web client") == true, "web client refused")
        model.importClientData(Data("{}".utf8))
        expect(clients.clients.isEmpty && model.notice?.tone == .warn, "empty JSON refused")

        // A downloaded client_secret file works.
        let installed = #"{"installed":{"client_id":"55-file\#(Fixtures.googleSuffix)","client_secret":"file-fixture","redirect_uris":["http://localhost"]}}"#
        let file = dir.appendingPathComponent("client_secret_fixture.json")
        try? Data(installed.utf8).write(to: file)
        await model.importClientFile(file)?.value
        expect(clients.clients[.google]?.clientId.hasPrefix("55-file") == true, "client file saved to the client store")
        expect(model.google.isReady && model.devClientFile == nil, "status ready, dev offer hidden")
        await expectEventually("health re-checked after setup") { model.accounts.contains { $0.health == .ok } }

        // The developer file path.
        let clients2 = FakeClientStore()
        let model2 = AccountsModel(environment: Fixtures.environment(dir: AccountsTests.folder("model-setup-dev"), vault: vault,
                                                                     clients: clients2, recorders: Fixtures.Recorders(),
                                                                     devFile: devFile))
        await model2.bootstrap()
        await model2.importDevClientFile()?.value
        expect(clients2.clients[.google]?.clientSecret == "dev-fixture", "developer file imported into the client store")
        expect(clients2.clients[.microsoft] == nil, "placeholder Microsoft entry skipped")

        // A locked client store maps to "Keychain locked" and keeps accounts in retry-later.
        let clients3 = FakeClientStore()
        clients3.loadError = KeychainError.locked(-25308)
        let model3 = AccountsModel(environment: Fixtures.environment(dir: AccountsTests.folder("model-setup-locked"),
                                                                     vault: vault, clients: clients3,
                                                                     recorders: Fixtures.Recorders()))
        await model3.bootstrap()
        expect(model3.google == .locked, "locked client store")
        expect(model3.accounts.allSatisfy { $0.health == .keychainLocked }, "locked → retry later, not sign in again")
    }

    static func addAccountFlows() async {
        let dir = AccountsTests.folder("model-add")
        let (vault, ids) = seededVault()
        let clients = FakeClientStore([.google: Fixtures.googleClient])
        let recorders = Fixtures.Recorders()
        let consent = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=fixture&state=s")!
        let script = Recorder<(email: String?, scopes: [String], error: Error?, hang: Bool)>(
            (email: "hello@acme.example", scopes: Fixtures.allScopes, error: nil, hang: false))
        let hints = Recorder<[String?]>([])
        let authorize: AccountsEnvironment.Authorize = { _, _, opener, hint, _ in
            hints.mutate { $0.append(hint) }
            _ = await opener(consent)
            let step = script.value
            if step.hang { try await Task.sleep(nanoseconds: 30_000_000_000) }
            if let error = step.error { throw error }
            return AuthorizationResult(grant: Fixtures.grant(refresh: "rt-ok-new", scopes: step.scopes),
                                       claims: Fixtures.claims(email: step.email))
        }
        let model = AccountsModel(environment: Fixtures.environment(dir: dir, vault: vault, clients: clients,
                                                                    recorders: recorders, authorize: authorize,
                                                                    logo: LogoTests.pngData(width: 64, height: 64)))
        await model.bootstrap()

        // Copy sign-in link → success.
        model.presentAdd()
        expect(model.isAddSheetPresented && model.addPhase == .idle, "sheet opens idle")
        model.beginSignIn(mode: .link)
        guard case .waiting(let waiting) = model.addPhase else { expect(false, "waiting after begin"); return }
        expect(waiting.mode == .link, "link mode")
        await expectEventually("link sign-in succeeds") { if case .success = model.addPhase { return true }; return false }
        expect(recorders.copied.value == [consent.absoluteString], "consent link copied to the pasteboard")
        expect(recorders.opened.value.isEmpty, "link mode never opens a browser")
        guard case .success(let success) = model.addPhase else { return }
        expect(success.isNew && success.email == "hello@acme.example", "new account reported")
        expect(vault.credential(success.accountId)?.refreshToken == "rt-ok-new", "credential saved to the vault")
        let added = model.record(success.accountId)
        expect(added?.tag == "ACM" && added?.displayName == "Acme" && added?.health == .ok, "row added with defaults, healthy")
        expect(added?.sortOrder == 4, "new account goes last")
        await expectEventually("logo auto-fetched on add") { model.record(success.accountId)?.logoFile != nil }
        expect(recorders.logoDomains.value.contains("acme.example"), "logo fetched from the account's own domain")

        // Open in browser uses the injected opener.
        model.presentAdd()
        script.value = (email: "hello@acme.example", scopes: Fixtures.allScopes, error: nil, hang: false)
        model.beginSignIn(mode: .browser)
        await expectEventually("browser sign-in succeeds") { if case .success = model.addPhase { return true }; return false }
        expect(recorders.opened.value == [consent], "browser opener called once")
        guard case .success(let again) = model.addPhase else { return }
        expect(!again.isNew && again.accountId == success.accountId, "same address → same account, no duplicate")
        expect(model.accounts.count == 5, "still five accounts")

        // Missing boxes → revoked and refused.
        model.presentAdd()
        let revokedBefore = recorders.revoked.value.count
        script.value = (email: "partial@acme2.example", scopes: ["openid", "email"], error: nil, hang: false)
        model.beginSignIn(mode: .link)
        await expectEventually("missing scopes fail") { if case .failed = model.addPhase { return true }; return false }
        if case .failed(let failure) = model.addPhase {
            if case .missingScopes(let scopes) = failure {
                expect(scopes.count == 3, "three API scopes reported missing")
            } else {
                expect(false, "missing scopes failure type")
            }
        }
        expect(recorders.revoked.value.count == revokedBefore + 1, "half grant revoked")
        expect(!model.accounts.contains { $0.email == "partial@acme2.example" }, "no row for a half grant")

        // …but never for an address that is already connected: Google's revoke would end its grant too.
        model.presentAdd()
        let orbToken = vault.credential(ids["orb"]!)?.refreshToken
        script.value = (email: "you@orbitalpickle.example", scopes: ["openid", "email"], error: nil, hang: false)
        model.beginSignIn(mode: .link)
        await expectEventually("missing scopes on a connected address fail") {
            if case .failed(.missingScopes) = model.addPhase { return true }; return false
        }
        expect(recorders.revoked.value.count == revokedBefore + 1, "connected address's grant not revoked")
        expect(vault.credential(ids["orb"]!)?.refreshToken == orbToken, "working credential untouched")

        // Provider errors map to friendly failures.
        let cases: [(Error, AddAccountFailure)] = [
            (AuthError.adminBlocked(code: "admin_policy_enforced"), .adminBlocked(code: "admin_policy_enforced")),
            (AuthError.timedOut, .timedOut),
            (AuthError.offline, .offline),
        ]
        for (error, expected) in cases {
            model.presentAdd()
            script.value = (email: nil, scopes: [], error: error, hang: false)
            model.beginSignIn(mode: .link)
            await expectEventually("failure \(expected)") { model.addPhase == .failed(expected) }
        }

        // Cancel while waiting: back to idle and stays idle.
        model.presentAdd()
        script.value = (email: "hello@acme.example", scopes: Fixtures.allScopes, error: nil, hang: true)
        model.beginSignIn(mode: .link)
        try? await Task.sleep(nanoseconds: 50_000_000)
        model.cancelSignIn()
        expect(model.addPhase == .idle, "cancel returns to idle")
        try? await Task.sleep(nanoseconds: 100_000_000)
        expect(model.addPhase == .idle, "cancelled flow doesn't come back as an error")

        // Copy link again keeps the same link.
        script.value = (email: "hello@acme.example", scopes: Fixtures.allScopes, error: nil, hang: true)
        model.beginSignIn(mode: .browser)
        _ = await AccountsTests.eventually { if case .waiting(let w) = model.addPhase { return w.link != nil }; return false }
        model.copySignInLinkAgain()
        if case .waiting(let w) = model.addPhase {
            expect(w.mode == .link && recorders.copied.value.last == consent.absoluteString, "copy again switches to link mode")
        } else {
            expect(false, "still waiting after copy again")
        }
        model.dismissAddSheet()
        expect(!model.isAddSheetPresented && model.addPhase == .idle, "closing the sheet cancels")

        // Sign in again passes the address as a login hint and heals the row.
        let cmt = ids["cmt"]!
        expect(model.record(cmt)?.health == .reauthNeeded, "CMT starts signed out")
        model.presentReauth(cmt)
        expect(model.addTarget.reauthAccount == cmt && model.addTarget.loginHint == "you@quietcomets.example",
               "reauth targets CMT with a login hint")
        script.value = (email: "you@quietcomets.example", scopes: Fixtures.allScopes, error: nil, hang: false)
        model.beginSignIn(mode: .link)
        await expectEventually("reauth succeeds") { if case .success = model.addPhase { return true }; return false }
        expect(hints.value.last == "you@quietcomets.example", "login hint passed to Google")
        expect(model.record(cmt)?.health == .ok, "CMT healthy again")
        expect(vault.credential(cmt)?.refreshToken == "rt-ok-new", "CMT credential replaced in place")
        expect(model.accounts.count == 5, "reauth adds no row")

        // No client → setup failure without calling Google.
        let noClient = AccountsModel(environment: Fixtures.environment(dir: AccountsTests.folder("model-add-noclient"),
                                                                       vault: FakeVault(), clients: FakeClientStore(),
                                                                       recorders: Fixtures.Recorders(), authorize: authorize))
        await noClient.bootstrap()
        noClient.presentAdd()
        noClient.beginSignIn(mode: .browser)
        expect(noClient.addPhase == .failed(.notConfigured), "no client → set up first")
    }

    static func removeAccount() async {
        let dir = AccountsTests.folder("model-remove")
        let (vault, ids) = seededVault()
        let clients = FakeClientStore([.google: Fixtures.googleClient])
        let recorders = Fixtures.Recorders()
        let model = AccountsModel(environment: Fixtures.environment(dir: dir, vault: vault, clients: clients,
                                                                    recorders: recorders,
                                                                    logo: LogoTests.pngData(width: 64, height: 64)))
        await model.bootstrap()
        let orb = ids["orb"]!
        let logoPath = dir.appendingPathComponent("widget/logos/\(orb.uuidString).png").path
        expect(FileManager.default.fileExists(atPath: logoPath), "ORB logo on disk before removal")

        await model.remove(orb)
        expect(recorders.revoked.value == ["rt-ok-orb"], "token revoked with Google")
        expect(vault.deleted == [orb] && vault.credential(orb) == nil, "Keychain item deleted")
        expect(model.record(orb) == nil && model.accounts.count == 3, "row deleted")
        expect(!FileManager.default.fileExists(atPath: logoPath), "logo deleted")
        let readopted = await model.adoptKeychainItems()
        expect(readopted.isEmpty, "removed account is not adopted back")

        // If the Keychain refuses, the row stays (so it isn't silently re-adopted later).
        vault.failDeletes = true
        let fam = ids["fam"]!
        await model.remove(fam)
        expect(model.record(fam) != nil, "row kept when the Keychain item can't be deleted")
        expect(model.notice?.tone == .warn, "user told why")
        vault.failDeletes = false

        // The revoke budget is honoured even if Google never answers.
        let slow = AccountsModel(environment: {
            var env = Fixtures.environment(dir: AccountsTests.folder("model-remove-slow"), vault: vault, clients: clients,
                                           recorders: Fixtures.Recorders())
            env.revoke = { _, _, _ in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return true
            }
            env.revokeBudget = 0.2
            return env
        }())
        await slow.bootstrap()
        let started = Date()
        if let first = slow.accounts.first?.id { await slow.remove(first) }
        expect(Date().timeIntervalSince(started) < 3, "revoke gives up after its budget")
    }

    static func editing() async {
        let dir = AccountsTests.folder("model-edit")
        let (vault, ids) = seededVault()
        let model = AccountsModel(environment: Fixtures.environment(dir: dir, vault: vault,
                                                                    clients: FakeClientStore([.google: Fixtures.googleClient]),
                                                                    recorders: Fixtures.Recorders()))
        model.openStore()
        await model.adoptKeychainItems()
        model.reload()
        let cmt = ids["cmt"]!
        model.rename(cmt, to: "  The Quiet Comets  ")
        model.setTag(cmt, "CMT")
        model.setColor(cmt, 0xE07A80)
        model.setMailEnabled(cmt, false)
        model.setIncludeInAll(cmt, false)
        model.rename(cmt, to: "   ")
        let row = model.record(cmt)
        expect(row?.displayName == "The Quiet Comets" && row?.tag == "CMT", "rename + retag, blank names ignored")
        expect(row?.color == 0xE07A80 && row?.mailEnabled == false && row?.includeInAll == false && row?.calendarEnabled == true,
               "colour and switches")
        let reread = model.repo.flatMap { try? $0.get(cmt) }
        expect(reread == row, "edits persisted")
        model.move(cmt, by: -1)
        expect(model.accounts.first?.id == cmt, "moved to the top")
        model.removeLogo(cmt)
        expect(model.record(cmt)?.logoFile == nil, "remove logo clears the row")
    }
}
