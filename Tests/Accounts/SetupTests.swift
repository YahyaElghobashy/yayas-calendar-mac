import Foundation

/// Sign-in setup (D-038): the bring-your-own Google guide, its links and copy, the client file checks, Replace…
/// and Remove with their confirms, the Trash offer, Check my setup and the error advice. Fakes only: no
/// Keychain, network, browser or Trash (the seams record what would have happened).
enum SetupTests {
    @MainActor
    static func run() async {
        guideSteps()
        errorAdvice()
        checkClassify()
        await clientFileProblems()
        await switchAndRemove()
        await trashOffer()
        await checkMySetup()
        await testingHintAndLogos()
    }

    static func guideSteps() {
        expect(GoogleSetupStep.allCases.count == 6, "six steps")
        expect(GoogleSetupStep.allCases.allSatisfy { !$0.title.isEmpty && !$0.lines.isEmpty }, "every step has words")
        expect(GoogleSetupStep.allCases.filter { $0 != .file }.allSatisfy { !$0.links().isEmpty }, "every step but the last opens a page")
        expect(GoogleSetupStep.file.links().isEmpty, "the last step is the drop zone")
        expect(GoogleSetupStep.apis.counter == "Step 2 of 6", "counter")
        expect(GoogleSetupStep.project.previous == nil && GoogleSetupStep.file.next == nil, "first and last")
        let hosts = Set(GoogleConsole.all.compactMap(\.host))
        expect(hosts == ["console.cloud.google.com", "console.developers.google.com", "myaccount.google.com"],
               "the guide only ever opens Google's own console pages (\(hosts.sorted()))")
        expect(GoogleConsole.all.allSatisfy { $0.scheme == "https" }, "https only")
        expect(GoogleSetupStep.client.lines.joined().contains("Download JSON") && GoogleSetupStep.client.lines.joined().contains("only once"),
               "step 5 says to download the JSON in the creation dialog")
        expect(GoogleSetupStep.audience.lines.joined().contains("Publish app") && GoogleSetupStep.audience.lines.joined().contains("7 days"),
               "step 4 says publish, and why")
        expect(GoogleSetupText.whyLines.count == 3, "Why do I need this? is three lines")
        expect(GoogleSetupText.consentHint.contains("your app\u{2019}s name") && GoogleSetupText.consentHint.contains("(unsafe)"),
               "consent copy names the user's own app")

        // A made-up project number, built at run time so the leak check's project-id rules see no number.
        let number = String(repeating: "4", count: 6)
        let gmail = GoogleAPIKind.gmail.enableURL(projectNumber: number)
        expect(gmail.absoluteString == "https://console.cloud.google.com/apis/enableflow;apiid=gmail.googleapis.com?project=" + number,
               "Gmail enable link opens in the project (\(gmail))")
        let calendar = GoogleAPIKind.calendar.enableURL(projectNumber: number)
        expect(calendar.absoluteString.hasSuffix("apiid=calendar-json.googleapis.com&project=" + number), "Calendar enable link adds &project")
        expect(GoogleAPIKind.gmail.enableURL(projectNumber: "12a").query == nil, "a non-number project is left out")
        expect(GoogleSetupAdvice.projectNumber(clientId: number + "-abc" + Fixtures.googleSuffix) == number, "project number from the client ID")
        expect(GoogleSetupAdvice.projectNumber(clientId: "abc-" + number + Fixtures.googleSuffix) == nil, "no digits, no project")
        expect(GoogleSetupAdvice.projectNumber(clientId: nil) == nil, "no client, no project")
    }

    static func errorAdvice() {
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        expect(GoogleSetupAdvice.looksLikeTestingExpiry(consentAt: now.addingTimeInterval(-7 * day), now: now), "7 days → Testing hint")
        expect(GoogleSetupAdvice.looksLikeTestingExpiry(consentAt: now.addingTimeInterval(-6 * day), now: now), "6 days → Testing hint")
        expect(!GoogleSetupAdvice.looksLikeTestingExpiry(consentAt: now.addingTimeInterval(-2 * day), now: now), "2 days → plain re-auth")
        expect(!GoogleSetupAdvice.looksLikeTestingExpiry(consentAt: now.addingTimeInterval(-30 * day), now: now), "30 days → plain re-auth")
        expect(!GoogleSetupAdvice.looksLikeTestingExpiry(consentAt: nil, now: now), "unknown consent → plain re-auth")

        let denied = AddAccountFailure.adminBlocked(code: "access_denied")
        expect(denied.suggestsPublishing && denied.message.contains("Publish app"), "access_denied → the Testing / Publish hint")
        expect(!AddAccountFailure.adminBlocked(code: "admin_policy_enforced").suggestsPublishing, "admin policy → admin kit only")

        expect(OAuthFlow.classify(code: "deleted_client", description: "The OAuth client was deleted.") == .clientRejected(code: "deleted_client"),
               "deleted_client → client gone")
        expect(OAuthFlow.classify(code: "invalid_client", description: "The OAuth client was not found.") == .clientRejected(code: "deleted_client"),
               "invalid_client 'not found' → client gone")
        expect(OAuthFlow.classify(code: "invalid_client", description: "Unauthorized") == .clientRejected(code: "invalid_client"),
               "other invalid_client unchanged")
        let gone = HealthText.state(for: AuthError.clientRejected(code: "deleted_client"))
        expect(gone.0 == .setupNeeded && gone.1 == GoogleSetupAdvice.clientGone, "a deleted client → make a new one")
        expect(AddAccountFailure.clientRejected(code: "deleted_client").message == GoogleSetupAdvice.clientGone, "… also when adding")
        expect(GoogleSetupAdvice.turnOn(.gmail) == "Turn on the Gmail API in your Google Cloud project, then sync again.", "turn-on copy")
    }

    static func checkClassify() {
        let disabled = Data(#"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}],"details":[{"reason":"SERVICE_DISABLED","metadata":{"service":"gmail.googleapis.com"}}]}}"#.utf8)
        expect(GoogleSetupCheck.classify(status: 403, body: disabled) == .disabled, "403 accessNotConfigured → off")
        let detailsOnly = Data(#"{"error":{"status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#.utf8)
        expect(GoogleSetupCheck.classify(status: 403, body: detailsOnly) == .disabled, "SERVICE_DISABLED alone → off")
        expect(GoogleSetupAdvice.reasons(in: disabled).service == "gmail.googleapis.com", "the disabled service is named")
        expect(GoogleSetupCheck.classify(status: 200, body: Data("{}".utf8)) == .ok, "200 → on")
        expect(GoogleSetupCheck.classify(status: 403, body: Data(#"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#.utf8))
               == .failed("http_403_insufficientPermissions"), "other 403 → its code")
        expect(GoogleSetupCheck.classify(status: 500, body: Data("oops".utf8)) == .failed("http_500"), "garbage → status only")
        let check = GoogleSetupCheck(account: "ORB", signIn: .ok, apis: [.calendar: .ok, .gmail: .disabled])
        expect(!check.allGood && check.line(for: .gmail).hasPrefix("Gmail API: off"), "result lines")
        expect(GoogleSetupCheck.probeURL(.calendar).host == "www.googleapis.com" && GoogleSetupCheck.probeURL(.gmail).host == "gmail.googleapis.com",
               "probes stay on hosts the HTTP allowlist already has")
        expect(GoogleAPIKind.allCases.allSatisfy { HTTP.allowedHosts.contains(GoogleSetupCheck.probeURL($0).host ?? "") }, "allowlisted")
    }

    @MainActor
    static func clientFileProblems() async {
        let dir = AccountsTests.folder("setup-file")
        let clients = FakeClientStore()
        let model = AccountsModel(environment: Fixtures.environment(dir: dir, vault: FakeVault(), clients: clients,
                                                                    recorders: Fixtures.Recorders()))
        await model.bootstrap()
        model.importClientData(Data(#"{"installed":{"client_id":"55-x\#(Fixtures.googleSuffix)"}}"#.utf8))
        expect(model.clientFileProblem == .noSecret && clients.clients.isEmpty, "a JSON without a secret → rotate / re-download")
        expect(model.clientFileProblem?.message == GoogleSetupAdvice.noSecret, "… with that advice")
        expect(model.clientFileProblem?.link?.url == GoogleConsole.clients, "… and the Clients page")
        model.importClientData(Data(#"{"web":{"client_id":"x","client_secret":"y"}}"#.utf8))
        expect(model.clientFileProblem == .webClient, "a Web client is named")
        model.importClientData(Data("[1,2]".utf8))
        expect(model.clientFileProblem == .notAClientFile, "not a client file")
        let installed = #"{"installed":{"client_id":"55-file\#(Fixtures.googleSuffix)","client_secret":"file-fixture"}}"#
        await model.importClientData(Data(installed.utf8))?.value
        expect(model.google.isReady && model.clientFileProblem == nil, "a good file clears the problem")
    }

    @MainActor
    static func switchAndRemove() async {
        let dir = AccountsTests.folder("setup-switch")
        let (vault, _) = ModelTests.seededVault()
        let clients = FakeClientStore([.google: Fixtures.googleClient])
        let model = AccountsModel(environment: Fixtures.environment(dir: dir, vault: vault, clients: clients,
                                                                    recorders: Fixtures.Recorders()))
        await model.bootstrap()
        expect(model.accounts.count == 4, "four accounts connected")
        let other = #"{"installed":{"client_id":"42-other\#(Fixtures.googleSuffix)","client_secret":"other-fixture"}}"#
        let task = model.importClientData(Data(other.utf8))
        expect(task == nil && model.pendingClient?.accounts == 4, "a different client with accounts → confirm first")
        expect(model.pendingClient?.message.contains("all 4 accounts") == true, "the confirm says how many sign out")
        expect(clients.clients[.google]?.clientId == Fixtures.googleClient.clientId, "nothing saved before the OK")
        model.cancelClientSwitch()
        expect(model.pendingClient == nil && clients.clients[.google]?.clientId == Fixtures.googleClient.clientId, "cancel keeps the old client")

        let same = #"{"installed":{"client_id":"\#(Fixtures.googleClient.clientId)","client_secret":"fixture-not-a-secret"}}"#
        await model.importClientData(Data(same.utf8))?.value
        expect(model.pendingClient == nil, "the same client again needs no confirm")

        model.importClientData(Data(other.utf8))
        await model.confirmClientSwitch()?.value
        expect(clients.clients[.google]?.clientId.hasPrefix("42-other") == true, "switch saves the new client")
        expect(model.accounts.allSatisfy { $0.health == .reauthNeeded && $0.healthDetail == AccountsModel.switchedClientDetail },
               "every account is marked to sign in again at once")

        model.confirmingRemoveClient = true
        await model.removeGoogleClient().value
        expect(clients.clients[.google] == nil && clients.deletes == [.google], "Remove Google client deletes it from the store")
        expect(model.google == .missing && !model.confirmingRemoveClient, "back to the guide")
        expect(model.setupStep == .project, "the guide starts over")
        expect(model.accounts.count == 4 && model.accounts.allSatisfy { $0.health == .setupNeeded }, "accounts stay listed, waiting for setup")
    }

    @MainActor
    static func trashOffer() async {
        let dir = AccountsTests.folder("setup-trash")
        let downloads = AccountsTests.folder("setup-trash-downloads")
        let file = downloads.appendingPathComponent("client_secret_fixture.json")
        try? Data(#"{"installed":{"client_id":"55-t\#(Fixtures.googleSuffix)","client_secret":"t-fixture"}}"#.utf8).write(to: file)
        var env = Fixtures.environment(dir: dir, vault: FakeVault(), clients: FakeClientStore(), recorders: Fixtures.Recorders())
        let trashed = Recorder<[URL]>([])
        env.trashFile = { url in trashed.mutate { $0.append(url) }; return true }
        let opened = Recorder<[URL]>([])
        env.openURL = { url in opened.mutate { $0.append(url) } }
        let model = AccountsModel(environment: env)
        await model.bootstrap()
        await model.importClientFile(file)?.value
        expect(model.importedDownload == file, "after the import the download is offered to the Trash")
        model.trashImportedDownload()
        expect(trashed.value == [file] && model.importedDownload == nil, "Move to Trash goes through the Trash seam")
        expect(FileManager.default.fileExists(atPath: file.path), "the fake never deletes the real file")

        model.showSetupStep(.audience)
        model.openConsole(GoogleConsole.audience)
        expect(opened.value == [GoogleConsole.audience] && model.setupStep == .audience, "links go through openURL")
    }

    @MainActor
    static func checkMySetup() async {
        let dir = AccountsTests.folder("setup-check")
        let clients = FakeClientStore([.google: Fixtures.googleClient])
        var env = Fixtures.environment(dir: dir, vault: FakeVault(), clients: clients, recorders: Fixtures.Recorders())
        let asked = Recorder<[String]>([])
        let gmailOff = #"{"error":{"code":403,"errors":[{"reason":"accessNotConfigured"}]}}"#
        env.probe = { url, token in
            asked.mutate { $0.append("\(url.host ?? "")|\(token)") }
            return url.host == "gmail.googleapis.com" ? (403, Data(gmailOff.utf8)) : (200, Data("{}".utf8))
        }
        let empty = AccountsModel(environment: env)
        await empty.bootstrap()
        await empty.checkSetup()
        expect(empty.setupCheck == .needsAccount && asked.value.isEmpty, "no account: nothing to check with")

        let (vault, ids) = ModelTests.seededVault()
        env.vault = vault
        let model = AccountsModel(environment: env)
        await model.bootstrap()
        await model.checkSetup()
        guard case .done(let check) = model.setupCheck else {
            expect(false, "check finished")
            return
        }
        expect(check.signIn == .ok, "one token refresh")
        expect(check.apis[.calendar] == .ok && check.apis[.gmail] == .disabled, "Calendar on, Gmail off")
        expect(asked.value.count == 2 && asked.value.allSatisfy { $0.hasSuffix("|fixture-access") }, "two read-only probes with the fresh token")
        let first = model.accounts.first { $0.provider == "google" }!.id
        expect(model.apiProblems[first] == [.gmail], "the account card learns Gmail is off")
        model.noteAPIWorking(first, .gmail)
        expect(model.apiProblems[first] == nil, "and forgets it once it works")
        _ = ids
    }

    @MainActor
    static func testingHintAndLogos() async {
        // A sign-in that died 7 days after consent says the project is likely still in Testing.
        let dir = AccountsTests.folder("setup-testing")
        let vault = FakeVault()
        let id = UUID()
        let now = Date()
        vault.put(Fixtures.credential("you@quietcomets.example", token: "rt-dead-cmt", savedAt: now.addingTimeInterval(-7 * 86_400)),
                  account: id.uuidString, createdAt: now.addingTimeInterval(-7 * 86_400))
        let model = AccountsModel(environment: Fixtures.environment(dir: dir, vault: vault,
                                                                    clients: FakeClientStore([.google: Fixtures.googleClient]),
                                                                    recorders: Fixtures.Recorders()))
        await model.bootstrap()
        expect(model.accounts.first?.health == .reauthNeeded, "dead token → sign in again")
        expect(model.accounts.first?.healthDetail == GoogleSetupAdvice.stillInTesting, "… with the Testing hint 7 days in")
        let detail = await model.reauthDetail(id)
        expect(detail == GoogleSetupAdvice.stillInTesting, "reauthDetail reads the consent date")

        // Fetch company logos off: adopting and connecting never asks a website.
        let recorders = Fixtures.Recorders()
        var env = Fixtures.environment(dir: AccountsTests.folder("setup-nologos"), vault: ModelTests.seededVault().0,
                                       clients: FakeClientStore([.google: Fixtures.googleClient]), recorders: recorders,
                                       logo: Data([0x89, 0x50]))
        env.autoLogo = { false }
        let quiet = AccountsModel(environment: env)
        await quiet.bootstrap()
        expect(recorders.logoDomains.value.isEmpty, "logo fetch off: no website asked on adoption")
    }
}
