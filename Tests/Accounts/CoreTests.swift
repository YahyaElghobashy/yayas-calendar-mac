import Foundation

enum NamingTests {
    static func run() {
        expect(AccountNaming.domain(of: "You@OrbitalPickle.EXAMPLE") == "orbitalpickle.example", "domain is lowercased")
        expect(AccountNaming.domain(of: "no-at-sign") == nil, "no domain without @")
        expect(AccountNaming.domain(of: "a@") == nil, "empty domain is nil")
        expect(AccountNaming.isPersonal(email: consumerAddress("me")) && AccountNaming.isPersonal(email: consumerAddress("me", "GoogleMail.com")),
               "gmail.com and googlemail.com are personal")
        expect(!AccountNaming.isPersonal(email: "me@orbitalpickle.example"), "workspace domain is not personal")

        expect(AccountNaming.displayName(for: "you@orbitalpickle.example") == "Orbitalpickle", "name: Orbitalpickle")
        expect(AccountNaming.displayName(for: "you@quietcomets.example") == "Quietcomets", "name: Quietcomets")
        expect(AccountNaming.displayName(for: "you@moonfieldfamily.example") == "Moonfieldfamily", "name: Moonfieldfamily")
        expect(AccountNaming.displayName(for: consumerAddress("you")) == "Gmail", "name: Gmail")
        expect(AccountNaming.displayName(for: "you@moon-toast-bakery.example") == "Moon Toast Bakery", "hyphens become words")
        expect(AccountNaming.displayName(for: "nobody") == "Account", "fallback name")

        expect(AccountNaming.tag(for: "you@orbitalpickle.example") == "ORB", "tag ORB")
        expect(AccountNaming.tag(for: "you@quietcomets.example") == "QUI", "tag QUI")
        expect(AccountNaming.tag(for: "you@moonfieldfamily.example") == "MOO", "tag MOO")
        expect(AccountNaming.tag(for: consumerAddress("you")) == "Personal", "gmail tag is Personal")
        expect(AccountNaming.tag(for: consumerAddress("you", "googlemail.com")) == "Personal", "googlemail tag is Personal")
        expect(AccountNaming.tag(for: "you@ab.example") == "AB", "short label keeps what it has")
        expect(AccountNaming.tag(for: "you@o-r-b.example") == "ORB", "hyphens skipped in tags")
        expect(AccountNaming.tag(for: "you@quietly.example", taken: ["QUI"]) == "QUI2", "taken tag gets a digit")
        expect(AccountNaming.tag(for: "you@quietly.example", taken: ["qui", "QUI2"]) == "QUI3", "digits keep counting, case-insensitive")
        expect(AccountNaming.tag(for: consumerAddress("x"), taken: ["Personal"]) == "Personal2", "second personal account")
        expect(AccountNaming.tag(for: "nobody") == "ACC", "fallback tag")

        let palette = AppTheme.accountSwatches
        expect(AccountNaming.nextColor(used: []) == palette[0], "first colour")
        expect(AccountNaming.nextColor(used: [palette[0], palette[1]]) == palette[2], "next free colour")
        expect(AccountNaming.nextColor(used: [palette[1]]) == palette[0], "a freed colour is reused first")
        expect(AccountNaming.nextColor(used: palette) == palette[0], "all eight used → cycle")
        expect(AccountNaming.nextColor(used: palette + [palette[0]]) == palette[1], "cycle continues by count")
    }
}

enum AdoptionTests {
    static func run() {
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let orb = UUID(), orbOld = UUID(), cmt = UUID(), fam = UUID(), personal = UUID(), locked = UUID(), blank = UUID()
        let vault = FakeVault()
        vault.put(Fixtures.credential("you@orbitalpickle.example", token: "rt-orb-old", savedAt: t0), account: orbOld.uuidString,
                  createdAt: t0)
        vault.put(Fixtures.credential("You@OrbitalPickle.example", token: "rt-orb", savedAt: t0 + 500), account: orb.uuidString,
                  createdAt: t0 + 500)
        vault.put(Fixtures.credential("you@quietcomets.example", token: "rt-cmt", savedAt: t0 + 100), account: cmt.uuidString,
                  createdAt: t0 + 100)
        vault.put(Fixtures.credential("you@moonfieldfamily.example", token: "rt-fam", savedAt: t0 + 200), account: fam.uuidString,
                  createdAt: t0 + 200)
        vault.put(Fixtures.credential(consumerAddress("you"), token: "rt-personal", savedAt: t0 + 300), account: personal.uuidString,
                  createdAt: t0 + 300)
        vault.put(Fixtures.credential("you@locked.example", token: "rt-x", savedAt: t0 + 400), account: locked.uuidString,
                  createdAt: t0 + 400)
        vault.put(nil, account: "probe-1", createdAt: t0)
        vault.put(nil, account: "selftest", createdAt: t0)
        vault.put(Fixtures.credential(nil, token: "rt-blank", savedAt: t0 + 600), account: blank.uuidString, createdAt: t0 + 600)
        vault.lockedIDs = [locked]

        let plan = Adoption.plan(vault: vault, existing: [])
        expect(Set(plan.ignored) == ["probe-1", "selftest"], "non-UUID items ignored")
        expect(plan.unreadable == [locked], "locked item skipped for now")
        expect(plan.duplicates == [orbOld], "older duplicate of the same address skipped")
        expect(plan.adopt.map(\.id) == [cmt, fam, personal, orb, blank], "adopted oldest first, newest ORB kept")
        expect(vault.deleted.isEmpty, "planning never deletes Keychain items")

        // Rows that exist stop re-adoption, by id and by address.
        let existingCMT = Adoption.newRecord(id: cmt, provider: .google, email: "you@quietcomets.example",
                                             createdAt: t0, existing: [])
        let existingFAMOtherID = Adoption.newRecord(id: UUID(), provider: .google, email: "YOU@moonfieldfamily.example",
                                                    createdAt: t0, existing: [])
        let second = Adoption.plan(vault: vault, existing: [existingCMT, existingFAMOtherID])
        expect(!second.adopt.map(\.id).contains(cmt), "existing row id not adopted again")
        expect(second.duplicates.contains(fam), "address already connected under another id is a duplicate")

        vault.listError = KeychainError.locked(-25320)
        expect(Adoption.plan(vault: vault, existing: []).adopt.isEmpty, "a locked listing adopts nothing (retried later)")
        vault.listError = nil

        // Defaults for new rows.
        var rows: [AccountRecord] = []
        for candidate in plan.adopt {
            rows.append(Adoption.newRecord(id: candidate.id, provider: candidate.credential.provider,
                                           email: candidate.credential.email ?? "", createdAt: candidate.createdAt,
                                           existing: rows))
        }
        expect(rows.map(\.tag) == ["QUI", "MOO", "Personal", "ORB", "ACC"], "default tags")
        expect(rows.map(\.displayName) == ["Quietcomets", "Moonfieldfamily", "Gmail", "Orbitalpickle", "Account"],
               "default names")
        expect(rows.map(\.color) == Array(AppTheme.accountSwatches.prefix(5)), "distinct colours in swatch order")
        expect(rows.map(\.sortOrder) == [0, 1, 2, 3, 4], "sort order follows adoption order")
        expect(rows.allSatisfy { $0.includeInAll && $0.mailEnabled && $0.calendarEnabled }, "mail/calendar/All on by default")
        expect(rows[3].email == "you@orbitalpickle.example", "address stored lowercased")
        expect(rows.allSatisfy { $0.health == .unknown && $0.logoFile == nil }, "new rows start unchecked, no logo")
    }
}

enum FriendlyTextTests {
    static func run() {
        func failure(_ error: Error) -> AddAccountFailure { AddAccountFailure(error: error) }
        expect(failure(AuthError.cancelled) == .cancelled, "cancelled")
        expect(failure(CancellationError()) == .cancelled, "task cancellation reads as cancelled")
        expect(failure(AuthError.timedOut) == .timedOut, "timed out")
        expect(failure(AuthError.adminBlocked(code: "admin_policy_enforced")) == .adminBlocked(code: "admin_policy_enforced"),
               "admin blocked")
        expect(failure(AuthError.offline) == .offline, "offline")
        expect(failure(AuthError.browserUnavailable) == .browserUnavailable, "browser unavailable")
        expect(failure(AuthError.loopbackUnavailable) == .loopbackUnavailable, "loopback unavailable")
        expect(failure(AuthError.clientRejected(code: "invalid_client")) == .clientRejected(code: "invalid_client"),
               "client rejected")
        expect(failure(AuthError.notConfigured(.google)) == .notConfigured, "not configured")
        expect(failure(KeychainError.locked(-25308)) == .keychain, "keychain failure")
        expect(failure(OAuthConfigError.missing(.google)) == .notConfigured, "missing client config")
        expect(failure(AuthError.provider(code: "weird")) == .other(code: "weird"), "other provider code kept")
        expect(failure(AddAccountFailure.missingScopes(["x"])) == .missingScopes(["x"]), "failure passes through")

        let blocked = AddAccountFailure.adminBlocked(code: "admin_policy_enforced")
        expect(blocked.title == "Blocked by your admin" && blocked.isAdminBlocked, "admin blocked title")
        expect(AddAccountFailure.adminBlocked(code: "access_denied").title != "Blocked by your admin",
               "access_denied doesn't accuse the admin")
        expect(AddAccountFailure.missingScopes([]).message.hasPrefix(
            "Some boxes weren\u{2019}t ticked \u{2014} try again and tick all of them"), "missing scopes copy")
        expect(AddAccountFailure.timedOut.message.contains("5 minutes"), "timeout copy mentions 5 minutes")
        let all: [AddAccountFailure] = [.cancelled, .timedOut, blocked, .missingScopes([]), .offline, .browserUnavailable,
                                        .loopbackUnavailable, .clientRejected(code: "c"), .notConfigured, .keychain,
                                        .noEmail, .other(code: "o")]
        expect(all.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty }, "every failure has a title and message")
        expect(all.allSatisfy { !$0.message.contains("token") }, "no techie token talk")

        // Health: only invalid_grant means "sign in again"; a locked keychain is always "retry later".
        func state(_ error: Error) -> HealthState { HealthText.state(for: error).0 }
        expect(state(AuthError.reauthNeeded(code: "invalid_grant")) == .reauthNeeded, "invalid_grant → sign in again")
        expect(state(AuthError.reauthNeeded(code: "interaction_required")) == .failing, "other Google code → retry")
        expect(HealthText.state(for: AuthError.reauthNeeded(code: "AADSTS70008"), provider: .microsoft).0 == .reauthNeeded,
               "Microsoft expiry → sign in again")
        expect(state(AuthError.adminBlocked(code: "admin_policy_enforced")) == .adminBlocked, "admin blocked health")
        expect(state(AuthError.offline) == .offline, "offline health")
        expect(state(AuthError.server(status: 503)) == .failing, "server error → retry")
        expect(state(AuthError.notConfigured(.google)) == .setupNeeded, "no client → setup")
        for status: OSStatus in [-25308, -25320, -60008, -25291] {
            expect(state(KeychainError(status: status)) == .keychainLocked, "keychain \(status) → retry later")
        }
        expect(state(KeychainError(status: -25293)) == .keychainLocked, "refused read (-25293) → retry later, not sign in")
        expect(state(TokenManagerError.persistFailed(.locked(-25308))) == .keychainLocked, "persist failure while locked")
        expect(state(KeychainError.notFound) == .reauthNeeded, "lost credential → sign in again")
        expect(HealthState.keychainLocked.isTransient && HealthState.offline.isTransient && !HealthState.reauthNeeded.isTransient,
               "transient states")

        let now = Date(timeIntervalSince1970: 1_000_000)
        expect(HealthText.relative(now - 5, now: now) == "just now", "relative: just now")
        expect(HealthText.relative(now - 120, now: now) == "2 min ago", "relative: minutes")
        expect(HealthText.relative(now - 3_700, now: now) == "1 hour ago", "relative: an hour")
        expect(HealthText.relative(now - 3 * 86_400, now: now) == "3 days ago", "relative: days")
        expect(HealthText.connectedLine(checkedAt: now - 120, now: now) == "Connected \u{00B7} checked 2 min ago",
               "connected line")
        expect(HealthText.connectedLine(checkedAt: nil, now: now) == "Connected", "connected line without a check")

        let message = AdminKit.message(clientID: "1234-abc")
        expect(message.contains("1234-abc") && message.contains("Trusted") && message.contains("API controls"),
               "admin message carries the client ID and the steps")
    }
}

enum DevFileTests {
    static func run() {
        let root = AccountsTests.folder("devfile")
        let fm = FileManager.default
        let configDir = root.appendingPathComponent("repo/Config", isDirectory: true)
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent("oauth.local.json")
        try? Data(#"{"google":{"clientId":"9-dev\#(Fixtures.googleSuffix)","clientSecret":"dev-fixture"}}"#.utf8).write(to: file)
        let exe = root.appendingPathComponent("repo/worktrees/wt/build/App.app/Contents/MacOS/YayasCalendar")
        try? fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)

        let viaExe = DevClientFile.locate(environment: [:], executable: exe)
        expect(viaExe?.standardizedFileURL.path == file.standardizedFileURL.path, "found walking up from the executable")
        let viaDir = DevClientFile.locate(environment: ["YAYACAL_DEV_OAUTH": root.appendingPathComponent("repo/sub").path],
                                          executable: nil)
        expect(viaDir == nil, "missing env folder is ignored")
        try? fm.createDirectory(at: root.appendingPathComponent("repo/sub/deeper"), withIntermediateDirectories: true)
        let viaEnvDir = DevClientFile.locate(environment: ["YAYACAL_DEV_OAUTH": root.appendingPathComponent("repo/sub/deeper").path],
                                             executable: nil)
        expect(viaEnvDir?.standardizedFileURL.path == file.standardizedFileURL.path, "found walking up from YAYACAL_DEV_OAUTH")
        let viaEnvFile = DevClientFile.locate(environment: ["YAYACAL_DEV_OAUTH": file.path], executable: nil)
        expect(viaEnvFile?.path == file.path, "YAYACAL_DEV_OAUTH may name the file itself")
        let lonely = root.appendingPathComponent("elsewhere/bin/YayasCalendar")
        try? fm.createDirectory(at: lonely.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `root` lives inside the worktree's .work, so a parent may hold a real dev file; only check that
        // whatever is found is never inside "elsewhere".
        let none = DevClientFile.locate(environment: [:], executable: lonely)
        expect(none.map { !$0.path.contains("/elsewhere/") } ?? true, "nothing invented beside the executable")

        let parsed = try? OAuthConfig.parseDevFile(Data(contentsOf: file))
        expect(parsed?[.google]?.clientSecret == "dev-fixture", "dev file parses outside the probe build")
        expect((try? OAuthConfig.parseDevFile(Data("[]".utf8))) == nil, "dev file must be an object")
    }
}
