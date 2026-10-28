import AppKit
import SwiftUI

/// Whether a provider's OAuth client is in the Keychain (Provider Setup).
enum ProviderStatus: Equatable, Sendable {
    case unknown
    /// The Keychain read is under way (off the main thread).
    case checking
    /// The read has taken more than 3 s: macOS is showing its "allow access" dialog (D-021).
    case waitingForKeychain
    case missing
    /// `clientIDHint` is `clientHint(_:)` of the client ID, for display only.
    case ready(clientIDHint: String)
    /// The Keychain is locked or in dark wake; checked again later.
    case locked
    case unreadable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum SignInMode: Equatable, Sendable {
    /// Opened in the default browser.
    case browser
    /// The consent link was copied so the user can paste it into the browser profile that holds the account.
    case link
}

struct SignInWaiting: Equatable, Sendable {
    var mode: SignInMode
    var link: URL?
    var deadline: Date
}

struct SignInSuccess: Equatable, Sendable {
    let accountId: UUID
    let email: String
    let isNew: Bool
    let note: String?
    /// The company website asked for a logo right after this sign-in (disclosed on the success screen).
    var logoDomain: String? = nil
}

/// "Check my setup" (Provider Setup).
enum SetupCheckState: Equatable, Sendable {
    case idle
    case running
    /// No connected account yet: the APIs can only be checked with one.
    case needsAccount
    case done(GoogleSetupCheck)
}

enum AddFlowPhase: Equatable, Sendable {
    case idle
    case waiting(SignInWaiting)
    case finishing
    case success(SignInSuccess)
    case failed(AddAccountFailure)
}

/// What the add sheet is doing: a new account, or signing an existing one in again.
struct AddFlowTarget: Equatable, Sendable {
    var provider: Provider = .google
    var reauthAccount: UUID?
    var loginHint: String?
}

struct AccountsNotice: Equatable, Identifiable {
    enum Tone: Equatable { case info, good, warn }
    let id = UUID()
    let text: String
    let tone: Tone
}

/// The accounts screen's brain: the store, the Keychain vault, Provider Setup, health checks, sign-in,
/// logos. Shared with the app shell through `AccountsModel.shared` + `start()` (docs/CONTRACTS.md).
///
/// Threading: the class is not actor-bound so the shell can reach `shared` and `start()` from anywhere;
/// every method that touches published or private state is `@MainActor` (hence `@unchecked Sendable`),
/// and `start()` hops to the main thread.
final class AccountsModel: ObservableObject, @unchecked Sendable {
    static let shared = AccountsModel()

    @Published var accounts: [AccountRecord] = []
    @Published var logos: [UUID: NSImage] = [:]
    @Published var checkedAt: [UUID: Date] = [:]
    @Published var checking: Set<UUID> = []
    @Published var removing: Set<UUID> = []
    @Published var fetchingLogo: Set<UUID> = []
    @Published var google: ProviderStatus = .unknown
    /// A developer `Config/oauth.local.json` that "Import from developer file" can copy into the Keychain.
    @Published var devClientFile: URL?
    @Published var isAddSheetPresented = false
    @Published var addTarget = AddFlowTarget()
    @Published var addPhase: AddFlowPhase = .idle
    @Published var notice: AccountsNotice?
    @Published var storeProblem: String?
    /// Accounts whose "Ask your admin" kit is unfolded on the card.
    @Published var adminKitOpen: Set<UUID> = []
    /// A Keychain call has run past 3 s (macOS is asking whether we may read our own item).
    @Published var keychainWaiting = false
    /// Shown once per run, the first time a Keychain call is slow, until it returns.
    @Published var keychainNotice: String?

    // Google setup guide (D-038)
    /// The guide's open step (remembered between launches when `env.preferences` is set).
    @Published var setupStep: GoogleSetupStep = .project
    /// "Why do I need this?" unfolded.
    @Published var setupWhyOpen = false
    /// The last client file that couldn't be used, and why.
    @Published var clientFileProblem: ClientFileProblem?
    /// "Replace…" picked a different client while accounts are connected: waiting for the user's OK.
    @Published var pendingClient: PendingClientSwitch?
    /// "Remove Google client" waiting for the user's OK.
    @Published var confirmingRemoveClient = false
    /// The client file just imported, offered to the Trash (it holds the secret).
    @Published var importedDownload: URL?
    @Published var setupCheck: SetupCheckState = .idle
    /// APIs the sync engine found turned off, per account ("Turn on the Gmail API").
    @Published var apiProblems: [UUID: Set<GoogleAPIKind>] = [:]

    let env: AccountsEnvironment
    let logoStore: LogoStore
    private(set) var repo: AccountRepo?
    private(set) var lastAdoption = Adoption.Plan()
    private var clients: [Provider: ProviderClient] = [:]
    private var tokenManagers: [UUID: TokenManager] = [:]
    private var signInTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var started = false
    private var keychainNoticeShown = false
    private var bootstrapping = false
    private var gateObserver: NSObjectProtocol?

    static let keychainNoticeText = "macOS is asking if Yaya\u{2019}s Calendar may read its saved sign-in. Click Always Allow."

    init(environment: AccountsEnvironment = .live) {
        env = environment
        logoStore = LogoStore(directory: environment.logosDirectory)
        if let stored = environment.preferences?.object(forKey: Self.setupStepKey) as? Int,
           let step = GoogleSetupStep(rawValue: stored) {
            setupStep = step
        }
    }

    static let setupStepKey = "googleSetup.step"

    /// Called once at launch by the app shell: open the store, adopt Keychain items, check health.
    func start() {
        let kickOff = { MainActor.assumeIsolated { self.kickOff() } }
        if Thread.isMainThread { kickOff() } else { DispatchQueue.main.async(execute: kickOff) }
    }

    @MainActor private func kickOff() {
        guard !started else { return }
        started = true
        Task { await self.bootstrap() }
    }

    /// Everything `start()` does, awaitable (tests call it directly). The store opens on the main thread
    /// (SQLite, milliseconds); every Keychain call is awaited on `env.keychain`, so a dialog from macOS
    /// never holds up links, the status item or widgets (D-021).
    @MainActor func bootstrap() async {
        bootstrapping = true
        openStore()
        watchKeychainGate()
        reload()
        await reloadProviderStatus()
        let adopted = await adoptKeychainItems()
        bootstrapping = false
        reload()
        let fetchLogos = env.autoLogo()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.checkHealth() }
            if fetchLogos {
                for id in adopted { group.addTask { await self.fetchLogo(id, quiet: true) } }
            }
        }
    }

    // MARK: - Store

    @MainActor func openStore() {
        guard repo == nil else { return }
        do {
            repo = AccountRepo(db: try AppDatabase(url: env.storeURL))
            storeProblem = nil
        } catch {
            storeProblem = "I couldn\u{2019}t open my little database, so nothing can be saved right now. Your sign-ins are safe in the Keychain; quit and reopen me to try again."
        }
    }

    @MainActor func reload() {
        guard let repo, let rows = try? repo.all() else { return }
        accounts = rows
        var images: [UUID: NSImage] = [:]
        for account in rows {
            if let image = logoStore.image(named: account.logoFile) { images[account.id] = image }
        }
        logos = images
    }

    @MainActor func record(_ id: UUID) -> AccountRecord? { accounts.first { $0.id == id } }

    /// Accounts that need the user (sign in again, admin, setup).
    var attentionCount: Int {
        accounts.filter { [.reauthNeeded, .adminBlocked, .setupNeeded].contains($0.health) }.count
    }

    // MARK: - Keychain (never on the main thread)

    /// Runs one vault / client-store call on `env.keychain`. Past 3 s: "Waiting for Keychain access" and,
    /// once per run, the notice; both clear when the gate is free again.
    @MainActor func keychain<T: Sendable>(_ operation: String, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        defer { keychainSettled() }
        return try await env.keychain.run(operation, onSlow: { [weak self] in self?.keychainSlow() }, body)
    }

    @MainActor private func keychainSlow() {
        keychainWaiting = true
        if google == .checking { google = .waitingForKeychain }
        if !keychainNoticeShown {
            keychainNoticeShown = true
            keychainNotice = Self.keychainNoticeText
        }
    }

    @MainActor private func keychainSettled() {
        guard !env.keychain.isStuck else { return }
        keychainWaiting = false
        keychainNotice = nil
    }

    /// Another caller (a token refresh, the data layer) can be the one stuck behind the dialog: follow the
    /// gate, and once it is free again re-read what was waiting.
    @MainActor private func watchKeychainGate() {
        guard gateObserver == nil else { return }
        let gate = env.keychain
        gateObserver = NotificationCenter.default.addObserver(forName: KeychainGate.changed, object: gate, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if gate.isStuck {
                    self.keychainSlow()
                } else {
                    let wasWaiting = self.keychainWaiting || self.google == .waitingForKeychain
                    self.keychainSettled()
                    // bootstrap reads everything itself; afterwards, re-read what waited.
                    if wasWaiting && !self.bootstrapping { Task { await self.retryPass() } }
                }
            }
        }
    }

    // MARK: - Adoption

    /// Creates rows for refresh tokens already in the Keychain (see `Adoption`). Returns the new ids.
    /// The vault is read on `env.keychain`; rows are written here, on the main thread.
    @MainActor @discardableResult
    func adoptKeychainItems() async -> [UUID] {
        guard let repo else { return [] }
        let existing = (try? repo.all()) ?? []
        let vault = env.vault
        let plan = (try? await keychain("adopt") { Adoption.plan(vault: vault, existing: existing) }) ?? Adoption.Plan()
        lastAdoption = plan
        var rows = (try? repo.all()) ?? []
        var adopted: [UUID] = []
        for candidate in plan.adopt where !rows.contains(where: { $0.id == candidate.id }) {
            let record = Adoption.newRecord(id: candidate.id, provider: candidate.credential.provider,
                                            email: candidate.credential.email ?? "",
                                            createdAt: candidate.createdAt, existing: rows)
            guard (try? repo.insert(record)) != nil else { continue }
            rows.append(record)
            adopted.append(candidate.id)
        }
        return adopted
    }

    // MARK: - Provider setup

    @MainActor var googleClientID: String? { clients[.google]?.clientId }

    /// How Provider Setup shows a client ID: "…" plus the last 6 characters of its random part. Never the
    /// leading digits, which are the Google Cloud project number (screenshots and screen recordings).
    static func clientHint(_ clientId: String) -> String {
        var id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = ".apps.googleusercontent.com"
        if id.lowercased().hasSuffix(domain) { id = String(id.dropLast(domain.count)) }
        return "\u{2026}" + String(id.suffix(6))
    }

    /// Reads the Google client on `env.keychain` ("Checking…" until it answers).
    @MainActor func reloadProviderStatus() async {
        tokenManagers.removeAll()
        if google == .unknown { google = .checking }
        let store = env.clients
        do {
            if let client = try await keychain("client-load", { try store.load(.google) }) {
                tokenManagers.removeAll()
                clients[.google] = client
                google = .ready(clientIDHint: Self.clientHint(client.clientId))
                devClientFile = nil
                return
            }
            clients[.google] = nil
            google = .missing
        } catch KeychainError.waiting {
            clients[.google] = nil
            google = .waitingForKeychain
        } catch let error as KeychainError where error.isTransient {
            clients[.google] = nil
            google = .locked
        } catch {
            clients[.google] = nil
            google = .unreadable("The saved Google client looks damaged. Choose the client file again.")
        }
        devClientFile = env.findDeveloperClient()
    }

    /// A `client_secret_*.json` the user chose or dropped. The save runs off the main thread; the
    /// returned task (tests await it) ends once the status is read back.
    @MainActor @discardableResult
    func importClientFile(_ url: URL) -> Task<Void, Never>? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 64 << 10, let data = try? Data(contentsOf: url) else {
            clientFileProblem = .tooBig
            show(ClientFileProblem.tooBig.message, .warn)
            return nil
        }
        return importClientData(data, source: url)
    }

    /// `source`: the file it came from, offered to the Trash once the client is saved.
    @MainActor @discardableResult
    func importClientData(_ data: Data, source: URL? = nil) -> Task<Void, Never>? {
        let client: ProviderClient
        do {
            client = try OAuthConfig.parseGoogleClientSecretJSON(data)
        } catch {
            let problem = Self.clientFileProblem(for: error)
            clientFileProblem = problem
            show(problem.message, .warn)
            return nil
        }
        clientFileProblem = nil
        // Every refresh token belongs to the client that issued it: a different client signs everyone out.
        if !accounts.isEmpty, let current = googleClientID, current != client.clientId {
            pendingClient = PendingClientSwitch(client: client, accounts: accounts.count, source: source)
            return nil
        }
        return saveClient(client, for: .google, source: source)
    }

    /// What was wrong with a client file, for the guide's fix-it line.
    static func clientFileProblem(for error: Error) -> ClientFileProblem {
        switch error {
        case OAuthConfigError.invalid(_, let reason) where reason.contains("Web client"): return .webClient
        case OAuthConfigError.invalid(_, let reason) where reason.contains("secret"): return .noSecret
        default: return .notAClientFile
        }
    }

    /// "Switch" on the confirm card: save the new client and mark every account as needing a new
    /// sign-in at once (their tokens can't refresh with it).
    @MainActor @discardableResult
    func confirmClientSwitch() -> Task<Void, Never>? {
        guard let pending = pendingClient else { return nil }
        pendingClient = nil
        let ids = accounts.map(\.id)
        let task = saveClient(pending.client, for: .google, source: pending.source, checkAfter: false)
        return Task { @MainActor in
            await task.value
            guard self.google.isReady else { return }
            for id in ids { self.applyHealth(id, .reauthNeeded, Self.switchedClientDetail) }
            Trace.app("google-client", ["action": "switched", "accounts": "\(ids.count)"])
        }
    }

    @MainActor func cancelClientSwitch() { pendingClient = nil }

    static let switchedClientDetail = "You switched Google clients. Sign in again to reconnect."
    static let removedClientDetail = "Google sign-in was removed. Set it up again below, then sign in."

    /// "Remove Google client" (after the confirm): the client leaves the Keychain; accounts stay listed
    /// and wait for a new client.
    @MainActor @discardableResult
    func removeGoogleClient() -> Task<Void, Never> {
        confirmingRemoveClient = false
        let store = env.clients
        return Task { @MainActor in
            do {
                try await self.keychain("client-delete") { try store.delete(.google) }
            } catch KeychainError.notFound {
                // Already gone: carry on and show the setup again.
            } catch {
                self.show("I couldn\u{2019}t remove the client from your Keychain. Unlock your Mac and try again.", .warn)
                return
            }
            self.clients[.google] = nil
            self.tokenManagers.removeAll()
            self.google = .missing
            self.setupCheck = .idle
            self.showSetupStep(.project)
            for account in self.accounts { self.applyHealth(account.id, .setupNeeded, Self.removedClientDetail) }
            Trace.app("google-client", ["action": "removed"])
            self.show("Google sign-in removed.", .info)
        }
    }

    // MARK: - Google setup guide

    @MainActor func showSetupStep(_ step: GoogleSetupStep) {
        setupStep = step
        env.preferences?.set(step.rawValue, forKey: Self.setupStepKey)
    }

    /// A guide link: the user's browser (never in tests or renders).
    @MainActor func openConsole(_ url: URL) {
        env.openURL(url)
        Trace.app("google-setup", ["action": "open", "step": "\(setupStep.rawValue)"])
    }

    /// The project number from the saved client, so "Enable" links open in the right project.
    @MainActor var projectNumber: String? { GoogleSetupAdvice.projectNumber(clientId: googleClientID) }

    /// "Move it to the Trash": the downloaded client file holds the secret, now safe in the Keychain.
    @MainActor func trashImportedDownload() {
        guard let url = importedDownload else { return }
        importedDownload = nil
        if env.trashFile(url) {
            show("Moved the client file to the Trash.", .good)
        } else {
            show("I couldn\u{2019}t move that file. Delete it yourself when you like.", .warn)
        }
    }

    @MainActor func keepImportedDownload() { importedDownload = nil }

    /// "Check my setup": one token refresh with the first connected account, then the calendar list and
    /// the Gmail profile (read-only). Reports which API is off.
    @MainActor func checkSetup() async {
        guard google.isReady else { return }
        guard let account = accounts.first(where: { Provider(rawValue: $0.provider) == .google }) else {
            setupCheck = .needsAccount
            return
        }
        setupCheck = .running
        var check = GoogleSetupCheck(account: account.tag, signIn: .ok, apis: [:])
        guard let manager = tokenManager(for: account.id) else {
            check.signIn = .failed("no_client")
            setupCheck = .done(check)
            return
        }
        let token: String
        do {
            token = try await manager.accessToken(forceRefresh: true)
        } catch {
            check.signIn = (error as? AuthError) == .offline ? .offline : .failed(Self.shortCode(error))
            setupCheck = .done(check)
            return
        }
        let probe = env.probe
        for api in GoogleAPIKind.allCases {
            if let answer = await probe(GoogleSetupCheck.probeURL(api), token) {
                check.apis[api] = GoogleSetupCheck.classify(status: answer.status, body: answer.body)
            } else {
                check.apis[api] = .offline
            }
            if check.apis[api] == .disabled { noteAPIDisabled(account.id, api) } else if check.apis[api] == .ok { noteAPIWorking(account.id, api) }
        }
        setupCheck = .done(check)
        Trace.app("google-setup", ["action": "check", "result": check.allGood ? "ok" : "problem"])
    }

    private static func shortCode(_ error: Error) -> String {
        if let auth = error as? AuthError { return String("\(auth)".prefix(40)) }
        return "error"
    }

    // MARK: - APIs turned off (reported by the sync engine)

    @MainActor func noteAPIDisabled(_ id: UUID, _ api: GoogleAPIKind) {
        guard !(apiProblems[id]?.contains(api) ?? false) else { return }
        apiProblems[id, default: []].insert(api)
        Trace.app("google-api-off", ["api": api.rawValue])
    }

    @MainActor func noteAPIWorking(_ id: UUID, _ api: GoogleAPIKind) {
        guard apiProblems[id]?.contains(api) ?? false else { return }
        apiProblems[id]?.remove(api)
        if apiProblems[id]?.isEmpty ?? false { apiProblems[id] = nil }
    }

    /// The re-auth line, with the Testing-mode hint when the sign-in died about a week after consent.
    @MainActor func reauthDetail(_ id: UUID) async -> String {
        let vault = env.vault
        let savedAt = try? await keychain("credential-read") { try vault.readCredential(id).savedAt }
        return GoogleSetupAdvice.looksLikeTestingExpiry(consentAt: savedAt, now: env.now())
            ? GoogleSetupAdvice.stillInTesting : HealthText.detail(.reauthNeeded)
    }

    @MainActor @discardableResult
    func importDevClientFile() -> Task<Void, Never>? {
        guard let url = devClientFile, let data = try? Data(contentsOf: url),
              let client = (try? OAuthConfig.parseDevFile(data))?[.google] else {
            show("The developer file has no usable Google client.", .warn)
            return nil
        }
        return saveClient(client, for: .google)
    }

    @MainActor private func saveClient(_ client: ProviderClient, for provider: Provider, source: URL? = nil,
                                       checkAfter: Bool = true) -> Task<Void, Never> {
        let store = env.clients
        return Task { @MainActor in
            do {
                try await self.keychain("client-save") { try store.save(client, for: provider) }
            } catch {
                self.show("I couldn\u{2019}t save the client to your Keychain. Unlock your Mac and try again.", .warn)
                return
            }
            await self.reloadProviderStatus()
            self.clientFileProblem = nil
            self.setupCheck = .idle
            // Offer the download to the Trash (never a file inside the app's own data folder).
            let ownFolder = self.env.storeURL.deletingLastPathComponent().standardizedFileURL.path + "/"
            if let source, !source.standardizedFileURL.path.hasPrefix(ownFolder) {
                self.importedDownload = source
            }
            self.show("Google sign-in is ready.", .good)
            if checkAfter { Task { await self.checkHealth() } }
        }
    }

    // MARK: - Health

    @MainActor func tokenManager(for id: UUID) -> TokenManager? {
        if let manager = tokenManagers[id] { return manager }
        guard let account = record(id), let provider = Provider(rawValue: account.provider),
              let client = clients[provider] else { return nil }
        let manager = TokenManager(accountId: id, provider: provider, store: env.vault,
                                   refresher: env.makeRefresher(provider, client))
        tokenManagers[id] = manager
        return manager
    }

    /// Refreshes every account (or `only`) once, without any UI, and records the outcome.
    @MainActor func checkHealth(_ only: [UUID]? = nil) async {
        let targets = accounts.filter { only?.contains($0.id) ?? true }.map(\.id)
        guard !targets.isEmpty else { return }
        checking.formUnion(targets)
        await withTaskGroup(of: Void.self) { group in
            for id in targets { group.addTask { await self.checkOne(id) } }
        }
        scheduleRetryIfNeeded()
    }

    /// Health states the next pass retries on its own ("I'll try again later").
    private static let retried: Set<HealthState> = [.offline, .keychainLocked, .failing, .unknown]

    /// A locked keychain (login, dark wake), an offline Mac or a Google hiccup clears up by itself: one
    /// pass is scheduled `env.retryDelay` later, and it schedules the next only while something is
    /// still stuck. (The sync engine adds wake/unlock/network-return triggers on top.)
    @MainActor private func scheduleRetryIfNeeded() {
        let stuck = google == .locked || !lastAdoption.unreadable.isEmpty
            || accounts.contains { Self.retried.contains($0.health) }
        guard stuck, retryTask == nil else { return }
        let delay = env.retryDelay
        retryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.retryTask = nil
            await self.retryPass()
        }
    }

    /// Re-reads the client if it wasn't readable, adopts items that were locked, re-checks stuck accounts.
    @MainActor func retryPass() async {
        if !google.isReady { await reloadProviderStatus() }
        let adopted = await adoptKeychainItems()
        if !adopted.isEmpty { reload() }
        let ids = accounts.filter {
            adopted.contains($0.id) || Self.retried.contains($0.health)
                || ($0.health == .setupNeeded && google.isReady)
        }.map(\.id)
        if ids.isEmpty {
            scheduleRetryIfNeeded()
        } else {
            await checkHealth(ids)
        }
        if env.autoLogo() {
            for id in adopted { await fetchLogo(id, quiet: true) }
        }
    }

    @MainActor private func checkOne(_ id: UUID) async {
        defer { checking.remove(id) }
        guard let account = record(id) else { return }
        guard let provider = Provider(rawValue: account.provider) else {
            applyHealth(id, .failing, "I don\u{2019}t know this kind of account.")
            return
        }
        guard let manager = tokenManager(for: id) else {
            if google == .waitingForKeychain {
                applyHealth(id, .keychainLocked, HealthText.waitingForKeychain)
            } else if google == .locked {
                applyHealth(id, .keychainLocked, HealthText.detail(.keychainLocked))
            } else {
                applyHealth(id, .setupNeeded, HealthText.detail(.setupNeeded))
            }
            return
        }
        var outcome: (HealthState, String?) = (.ok, nil)
        do {
            _ = try await manager.accessToken(forceRefresh: true)
        } catch {
            let mapped = HealthText.state(for: error, provider: provider)
            outcome = (mapped.0, mapped.1)
            if mapped.0 == .reauthNeeded, case AuthError.reauthNeeded = error { outcome.1 = await reauthDetail(id) }
        }
        applyHealth(id, outcome.0, outcome.1)
    }

    @MainActor private func applyHealth(_ id: UUID, _ state: HealthState, _ detail: String?) {
        _ = try? repo?.setHealth(id, state, detail: detail)
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].health = state
            accounts[index].healthDetail = detail
        }
        checkedAt[id] = env.now()
    }

    // MARK: - Add account / sign in again

    @MainActor func presentAdd(provider: Provider = .google) {
        cancelSignIn()
        addTarget = AddFlowTarget(provider: provider)
        addPhase = .idle
        isAddSheetPresented = true
    }

    /// Also the target of the widget's `yayacal://reauth` route.
    @MainActor func presentReauth(_ id: UUID) {
        guard let account = record(id) else { return }
        cancelSignIn()
        addTarget = AddFlowTarget(provider: Provider(rawValue: account.provider) ?? .google,
                                  reauthAccount: id, loginHint: account.email)
        addPhase = .idle
        isAddSheetPresented = true
    }

    @MainActor func dismissAddSheet() {
        cancelSignIn()
        isAddSheetPresented = false
        addPhase = .idle
    }

    /// Starts the loopback + PKCE flow. `.link` copies the consent URL instead of opening a browser and
    /// keeps listening until the user approves, cancels, or 5 minutes pass.
    @MainActor func beginSignIn(mode: SignInMode) {
        signInTask?.cancel()
        let target = addTarget
        guard let client = clients[target.provider] else {
            addPhase = .failed(.notConfigured)
            return
        }
        addPhase = .waiting(SignInWaiting(mode: mode, link: nil, deadline: env.now().addingTimeInterval(env.signInTimeout)))
        let copy = env.copyToPasteboard
        let openInBrowser = env.openInBrowser
        let opener: OAuthFlow.BrowserOpener
        switch mode {
        case .browser:
            opener = { url in
                await MainActor.run { self.linkReady(url) }
                return await openInBrowser(url)
            }
        case .link:
            opener = { url in
                await MainActor.run {
                    copy(url.absoluteString)
                    self.linkReady(url)
                }
                return true
            }
        }
        let authorize = env.authorize
        let timeout = env.signInTimeout
        signInTask = Task {
            do {
                let result = try await authorize(target.provider, client, opener, target.loginHint, timeout)
                await self.finishSignIn(result, target: target, client: client)
            } catch {
                self.signInFailed(error)
            }
        }
    }

    @MainActor private func linkReady(_ url: URL) {
        guard case .waiting(var waiting) = addPhase else { return }
        waiting.link = url
        addPhase = .waiting(waiting)
    }

    /// "Copy link again" / "Copy link instead": same URL, the listener keeps waiting.
    @MainActor func copySignInLinkAgain() {
        guard case .waiting(var waiting) = addPhase, let link = waiting.link else { return }
        env.copyToPasteboard(link.absoluteString)
        waiting.mode = .link
        addPhase = .waiting(waiting)
    }

    @MainActor func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if case .waiting = addPhase { addPhase = .idle }
        if addPhase == .finishing { addPhase = .idle }
    }

    @MainActor private func signInFailed(_ error: Error) {
        guard !Task.isCancelled else { return }
        signInTask = nil
        addPhase = .failed(AddAccountFailure(error: error))
    }

    @MainActor private func finishSignIn(_ result: AuthorizationResult, target: AddFlowTarget,
                                         client: ProviderClient) async {
        guard !Task.isCancelled else { return }
        addPhase = .finishing
        let provider = target.provider
        let revoke = env.revoke
        let budget = env.revokeBudget
        guard let refreshToken = result.grant.refreshToken else {
            addPhase = .failed(.other(code: "no refresh token"))
            return
        }
        let email = result.claims?.displayEmail?.lowercased() ?? ""
        let missing = provider.missingScopes(granted: result.grant.grantedScopes)
        if !missing.isEmpty {
            // Don't keep a half grant around: hand it back to Google and ask again. Google's revoke ends
            // the whole grant for this user + client, so never revoke when the address is already
            // connected (or unknown): that would sign out the working copy too.
            let connected = accounts.contains { $0.provider == provider.rawValue && $0.email.lowercased() == email }
            if !email.isEmpty && !connected {
                _ = await withTimeBudget(budget) { await revoke(provider, client, refreshToken) }
            }
            addPhase = .failed(.missingScopes(missing))
            return
        }
        guard !email.isEmpty else {
            addPhase = .failed(.noEmail)
            return
        }
        guard let repo else {
            addPhase = .failed(.other(code: "database"))
            return
        }
        let existing = accounts.first { $0.provider == provider.rawValue && $0.email.lowercased() == email }
        let id = existing?.id ?? UUID()
        let credential = StoredCredential(provider: provider, refreshToken: refreshToken, email: email,
                                          scopes: result.grant.grantedScopes, savedAt: env.now())
        let vault = env.vault
        do {
            try await keychain("credential-save") { try vault.saveCredential(credential, for: id) }
        } catch {
            addPhase = .failed(.keychain)
            return
        }
        if existing == nil {
            let record = Adoption.newRecord(id: id, provider: provider, email: email, createdAt: env.now(),
                                            existing: accounts)
            do {
                try repo.insert(record)
            } catch {
                _ = try? await keychain("credential-delete") { try vault.deleteCredential(id) }
                addPhase = .failed(.other(code: "database"))
                return
            }
        }
        reload()
        tokenManagers[id] = nil
        if let manager = tokenManager(for: id) { await manager.seed(result.grant) }
        applyHealth(id, .ok, nil)

        var note: String?
        if let wanted = target.reauthAccount, wanted != id, let other = record(wanted) {
            note = "That was \(email), not \(other.email). \(existing == nil ? "I added it too" : "I refreshed it instead"); \(other.tag) still needs you to sign in."
        }
        let fetchLogo = existing == nil && env.autoLogo()
        let logoDomain = fetchLogo ? AccountNaming.domain(of: email).flatMap { AccountNaming.personalDomains.contains($0) ? nil : $0 } : nil
        addPhase = .success(SignInSuccess(accountId: id, email: email, isNew: existing == nil, note: note, logoDomain: logoDomain))
        signInTask = nil
        if fetchLogo { await self.fetchLogo(id, quiet: true) }
    }

    // MARK: - Editing

    @MainActor func update(_ id: UUID, _ change: (inout AccountRecord) -> Void) {
        guard let repo, var account = record(id) else { return }
        change(&account)
        do {
            try repo.update(account)
            if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index] = account }
        } catch {
            show("I couldn\u{2019}t save that change.", .warn)
        }
    }

    @MainActor func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.displayName = String(trimmed.prefix(40)) }
    }

    @MainActor func setTag(_ id: UUID, _ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.tag = String(trimmed.prefix(10)) }
    }

    @MainActor func setColor(_ id: UUID, _ color: UInt32) { update(id) { $0.color = color } }
    @MainActor func setMailEnabled(_ id: UUID, _ on: Bool) { update(id) { $0.mailEnabled = on } }
    @MainActor func setCalendarEnabled(_ id: UUID, _ on: Bool) { update(id) { $0.calendarEnabled = on } }
    @MainActor func setIncludeInAll(_ id: UUID, _ on: Bool) { update(id) { $0.includeInAll = on } }

    @MainActor func move(_ id: UUID, by offset: Int) {
        guard let repo else { return }
        _ = try? repo.move(id, by: offset)
        reload()
    }

    @MainActor func reorder(_ ids: [UUID]) {
        guard let repo else { return }
        try? repo.reorder(ids)
        reload()
    }

    @MainActor func toggleAdminKit(_ id: UUID) {
        if adminKitOpen.contains(id) { adminKitOpen.remove(id) } else { adminKitOpen.insert(id) }
    }

    @MainActor func copyClientID() {
        guard let id = googleClientID else { return }
        env.copyToPasteboard(id)
        show("Client ID copied.", .good)
    }

    @MainActor func copyAdminMessage() {
        env.copyToPasteboard(AdminKit.message(clientID: googleClientID))
        show("Copied a message for your admin.", .good)
    }

    // MARK: - Logos

    @MainActor func fetchLogo(_ id: UUID, quiet: Bool = false) async {
        guard let account = record(id), let domain = AccountNaming.domain(of: account.email) else { return }
        if AccountNaming.personalDomains.contains(domain) {
            if !quiet { show("Personal accounts stay logo-free. Choose an image if you want one.", .info) }
            return
        }
        fetchingLogo.insert(id)
        defer { fetchingLogo.remove(id) }
        guard let png = await env.fetchLogo(domain) else {
            if !quiet { show("I couldn\u{2019}t find a logo on \(domain). Choose an image instead.", .warn) }
            return
        }
        applyLogo(png, to: id, announce: quiet ? nil : "New logo from \(domain).")
    }

    @MainActor @discardableResult
    func applyLogo(_ data: Data, to id: UUID, announce: String? = nil) -> Bool {
        do {
            let file = try logoStore.save(imageData: data, for: id)
            update(id) { $0.logoFile = file }
            logos[id] = logoStore.image(named: file)
            if let announce { show(announce, .good) }
            return true
        } catch {
            show("That image didn\u{2019}t work. Try a PNG, JPEG or SVG.", .warn)
            return false
        }
    }

    @MainActor func importLogo(from url: URL, for id: UUID) {
        do {
            let file = try logoStore.importFile(at: url, for: id)
            update(id) { $0.logoFile = file }
            logos[id] = logoStore.image(named: file)
        } catch {
            show("That image didn\u{2019}t work. Try a PNG, JPEG or SVG.", .warn)
        }
    }

    @MainActor func removeLogo(_ id: UUID) {
        logoStore.remove(id)
        update(id) { $0.logoFile = nil }
        logos[id] = nil
    }

    // MARK: - Remove

    /// Best-effort revoke (5 s), then the Keychain item, then the row and logo. If the Keychain item
    /// can't be deleted the row stays, so the next launch doesn't adopt a token the user meant to drop.
    @MainActor func remove(_ id: UUID) async {
        guard let account = record(id) else { return }
        removing.insert(id)
        defer { removing.remove(id) }
        let vault = env.vault
        if let provider = Provider(rawValue: account.provider), let client = clients[provider],
           let credential = try? await keychain("credential-read", { try vault.readCredential(id) }) {
            let revoke = env.revoke
            let token = credential.refreshToken
            _ = await withTimeBudget(env.revokeBudget) { await revoke(provider, client, token) }
        }
        do {
            try await keychain("credential-delete") { try vault.deleteCredential(id) }
        } catch {
            show("I couldn\u{2019}t remove \(account.tag) from your Keychain. Unlock your Mac and try again.", .warn)
            return
        }
        _ = try? repo?.delete(id)
        logoStore.remove(id)
        tokenManagers[id] = nil
        checkedAt[id] = nil
        adminKitOpen.remove(id)
        reload()
        show("Removed \(account.tag). Your mail and calendar are untouched.", .info)
    }

    // MARK: - Notices

    @MainActor func show(_ text: String, _ tone: AccountsNotice.Tone) {
        notice = AccountsNotice(text: text, tone: tone)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self.notice = nil
        }
    }
}
