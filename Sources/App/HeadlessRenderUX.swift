// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import SwiftUI

/// First-run UX renders (`ux-*.png`): the Google setup guide's six steps and its other states,
/// the first-run guide, Keep me running, Remove everything (confirm, working, report), the new Settings
/// rows, a disabled API on an account card and the add-account copy. The cast only; fakes behind every
/// seam; no Keychain, network, browser, login item or user defaults. `YC_RENDER_ONLY=ux` renders just these.
@MainActor
enum HeadlessRenderUX {
    typealias Save = (AnyView, String, [String: Any]) -> Void

    static func run(dir: URL, now: Date, logos: (UUID) -> NSImage?, save: Save) -> Int {
        var count = 0
        func shot<V: View>(_ view: V, _ name: String, _ info: [String: Any]) {
            save(AnyView(view.environment(\.headlessRender, true).environment(\.accountsStaticRender, true)), name, info)
            count += 1
        }
        let records = UXAccounts.records(now: now)

        // 1. The Google setup guide, one step at a time (Accounts → Sign-in setup width).
        for step in GoogleSetupStep.allCases {
            let model = UXAccounts.model(dir: dir, google: false, accounts: [], logos: logos)
            model.setupStep = step
            shot(card(ProviderSetupView(model: model)), "ux-wizard-\(step.rawValue)-\(step.slug).png",
                 ["window": "google-setup", "step": step.rawValue])
        }
        do {
            let model = UXAccounts.model(dir: dir, google: false, accounts: [], logos: logos)
            model.setupStep = .apis
            model.setupWhyOpen = true
            shot(card(ProviderSetupView(model: model)), "ux-wizard-why.png", ["window": "google-setup", "state": "why"])
        }
        for problem in [ClientFileProblem.noSecret, .webClient] {
            let model = UXAccounts.model(dir: dir, google: false, accounts: [], logos: logos)
            model.setupStep = .file
            model.clientFileProblem = problem
            shot(card(ProviderSetupView(model: model)), "ux-wizard-file-\(problem == .noSecret ? "nosecret" : "webclient").png",
                 ["window": "google-setup", "state": "problem"])
        }

        // 2. Google sign-in ready: Check my setup, Replace (confirm), Remove (confirm), the Trash offer.
        let gmailOff = GoogleSetupCheck(account: "ORB", signIn: .ok, apis: [.calendar: .ok, .gmail: .disabled])
        let allGood = GoogleSetupCheck(account: "ORB", signIn: .ok, apis: [.calendar: .ok, .gmail: .ok])
        let readyStates: [(String, (AccountsModel) -> Void)] = [
            ("ready", { _ in }),
            ("check-gmail-off", { $0.setupCheck = .done(gmailOff) }),
            ("check-all-good", { $0.setupCheck = .done(allGood) }),
            ("replace-confirm", { $0.pendingClient = PendingClientSwitch(client: UXAccounts.client, accounts: records.count, source: nil) }),
            ("remove-confirm", { $0.confirmingRemoveClient = true }),
            ("trash-offer", { $0.importedDownload = URL(fileURLWithPath: "/Users/you/Downloads/client_secret_desk.apps.json") }),
        ]
        do {
            let model = UXAccounts.model(dir: dir, google: true, accounts: [], logos: logos)
            shot(card(ProviderSetupView(model: model)), "ux-setup-ready-no-accounts.png", ["window": "google-setup", "state": "ready-no-accounts"])
        }
        for (name, setUp) in readyStates {
            let model = UXAccounts.model(dir: dir, google: true, accounts: records, logos: logos)
            setUp(model)
            shot(card(ProviderSetupView(model: model)), "ux-setup-\(name).png", ["window": "google-setup", "state": name])
        }

        // 3. An account whose project has the Gmail API off, on the Accounts screen.
        do {
            let model = UXAccounts.model(dir: dir, google: true, accounts: records, logos: logos)
            model.apiProblems[records[0].id] = [.gmail]
            shot(AccountsScreen(model: model, now: now).frame(width: 860).fixedSize(horizontal: false, vertical: true)
                    .background(AppTheme.background).environment(\.colorScheme, .dark),
                 "ux-accounts-api-off.png", ["window": "accounts", "state": "gmail-off"])
        }

        // 4. Add account: the consent copy, access_denied with the Publish hint, success with the logo line.
        let sheets: [(String, (AccountsModel) -> Void)] = [
            ("consent", { _ in }),
            ("access-denied", { $0.addPhase = .failed(.adminBlocked(code: "access_denied")) }),
            ("client-gone", { $0.addPhase = .failed(.clientRejected(code: "deleted_client")) }),
            ("success-logo", { $0.addPhase = .success(SignInSuccess(accountId: records[0].id, email: records[0].email, isNew: true,
                                                                   note: nil, logoDomain: "orbitalpickle.example")) }),
        ]
        for (name, setUp) in sheets {
            let model = UXAccounts.model(dir: dir, google: true, accounts: records, logos: logos)
            setUp(model)
            shot(AddAccountSheet(model: model, now: now).fixedSize(horizontal: false, vertical: true),
                 "ux-add-\(name).png", ["window": "add-account", "state": name])
        }

        // 5. The first-run guide (nothing connected), Keep me running in each placement, ⌃⌥J.
        do {
            let model = UXAccounts.model(dir: dir, google: false, accounts: [], logos: logos)
            let guide = OnboardingModel(accounts: model, bag: MemoryBag(), live: false, shown: .google)
            shot(OnboardingView(model: guide, accounts: model, onDone: {}), "ux-guide-first-run.png",
                 ["window": "onboarding", "state": "first-run"])
        }
        let placements: [(String, PlacementChoice, Bool)] = [
            ("in-applications", .inApplications, false),
            ("login-on", .inApplications, true),
            ("move", .moveToApplications(replacing: false), false),
            ("move-user", .offerUserApplications(reason: "The copy in Applications is signed by someone else."), false),
        ]
        for (name, placement, loginItem) in placements {
            let model = UXAccounts.model(dir: dir, google: true, accounts: records, logos: logos)
            let bag = MemoryBag([OnboardingFlow.looksKey: true, OnboardingFlow.widgetKey: true])
            let guide = OnboardingModel(accounts: model, bag: bag, live: false, notifications: "granted", shown: .running,
                                        system: .fixed(placement: placement, loginItem: loginItem))
            shot(OnboardingView(model: guide, accounts: model, onDone: {}), "ux-guide-running-\(name).png",
                 ["window": "onboarding", "step": 6, "placement": name])
        }
        do {
            let model = UXAccounts.model(dir: dir, google: true, accounts: records, logos: logos)
            let bag = MemoryBag([OnboardingFlow.looksKey: true, OnboardingFlow.widgetKey: true])
            let guide = OnboardingModel(accounts: model, bag: bag, live: false, shown: .notifications)
            shot(OnboardingView(model: guide, accounts: model, onDone: {}), "ux-guide-notifications-hotkey.png",
                 ["window": "onboarding", "step": 5])
        }

        // 6. Remove everything: the confirm, the wait, the report (clean, and with leftovers).
        let home = URL(fileURLWithPath: "/Users/you", isDirectory: true)
        let plan = UninstallPlan.make(home: home)
        var clean = UninstallReport()
        clean.revoked = 4
        clean.keychainDeleted = 6
        clean.removed = Array(repeating: "x", count: 5)
        clean.defaultsCleared = true
        clean.widgetContainer = plan.widgetContainer.path
        var leftovers = clean
        leftovers.widgetContainerExists = true
        leftovers.keychainDeleted = 4
        leftovers.keychainLeft = [UninstallIDs.keychainServices[0]: 2]
        let phases: [(String, RemoveEverythingModel.Phase)] = [
            ("confirm", .confirm), ("working", .working), ("done", .done(clean)), ("done-leftovers", .done(leftovers)),
        ]
        for (name, phase) in phases {
            let model = RemoveEverythingModel(plan: plan, accounts: records.count, phase: phase,
                                              perform: { clean }, cancel: {}, quit: {})
            shot(RemoveEverythingView(model: model).fixedSize(horizontal: false, vertical: true),
                 "ux-remove-\(name).png", ["window": "remove-everything", "state": name])
        }

        // 7. Settings, top to bottom (Applications folder, What leaves this Mac, Remove everything).
        let settings = SettingsView(menuBar: MenuBarSettingsModel(bag: MemoryBag(), mailEnabled: { true }, state: { .on }, post: {}),
                                    openGuide: {}, removeEverything: {})
            .frame(width: 900, height: 1500, alignment: .top)
            .background(AppTheme.background).environment(\.colorScheme, .dark)
        shot(settings, "ux-settings.png", ["window": "settings", "state": "full"])
        return count
    }

    /// A Provider Setup card on the window's background, at the Accounts column's width.
    private static func card<V: View>(_ view: V) -> some View {
        view.padding(24).frame(width: 640).fixedSize(horizontal: false, vertical: true)
            .background(AppTheme.background).environment(\.colorScheme, .dark)
    }
}

private extension GoogleSetupStep {
    var slug: String {
        switch self {
        case .project: return "project"
        case .apis: return "apis"
        case .branding: return "branding"
        case .audience: return "audience"
        case .client: return "client"
        case .file: return "file"
        }
    }
}

/// Accounts stores for these renders: fakes behind every seam, files under `<dir>/scratch-ux` (never
/// opened), no Keychain, no network, no browser.
@MainActor
private enum UXAccounts {
    struct Vault: AccountVault {
        func items() throws -> [VaultItem] { [] }
        func deleteCredential(_ accountId: UUID) throws -> Bool { false }
        func readCredential(_ accountId: UUID) throws -> StoredCredential { throw AuthError.cancelled }
        func saveCredential(_ credential: StoredCredential, for accountId: UUID) throws {}
    }

    struct Clients: ProviderClientStore {
        func load(_ provider: Provider) throws -> ProviderClient? { nil }
        func save(_ client: ProviderClient, for provider: Provider) throws {}
    }

    /// A client-shaped value for the confirm card (never saved; the suffix is split for the secret scanner).
    static let client = ProviderClient(clientId: "000000000000-k3m9qz" + ".apps." + "googleusercontent" + ".com", clientSecret: "render")

    static func model(dir: URL, google: Bool, accounts: [AccountRecord], logos: (UUID) -> NSImage?) -> AccountsModel {
        let scratch = dir.appendingPathComponent("scratch-ux", isDirectory: true)
        let env = AccountsEnvironment(
            storeURL: scratch.appendingPathComponent("store.sqlite"),
            logosDirectory: scratch.appendingPathComponent("logos", isDirectory: true),
            vault: Vault(), clients: Clients(),
            authorize: { _, _, _, _, _ in throw AuthError.cancelled },
            makeRefresher: { _, _ in { _ in throw AuthError.cancelled } },
            revoke: { _, _, _ in false },
            fetchLogo: { _ in nil },
            copyToPasteboard: { _ in },
            openInBrowser: { _ in false },
            findDeveloperClient: { nil },
            now: { WidgetSample.fixedNow })
        let model = AccountsModel(environment: env)
        model.google = google ? .ready(clientIDHint: AccountsModel.clientHint(client.clientId)) : .missing
        model.accounts = accounts
        var images: [UUID: NSImage] = [:]
        for a in accounts { if let image = logos(a.id) { images[a.id] = image } }
        model.logos = images
        return model
    }

    static func records(now: Date) -> [AccountRecord] {
        FixtureAccounts.all.enumerated().map { i, a in
            AccountRecord(id: a.id, provider: "google", email: a.email, displayName: a.name, tag: a.tag, color: a.color,
                          logoFile: nil, sortOrder: i, health: .ok, createdAt: now)
        }
    }
}
#endif
