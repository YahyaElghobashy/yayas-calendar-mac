#if !YC_DATA_TESTS
import AppKit
import Combine
import Foundation

/// AccountsModel as the sync engine's accounts source: its token managers (single flight, never
/// prompt) and its health state ("Sign in again"). AccountsModel itself is not changed; this only
/// calls its existing API.
final class AccountsModelSource: SyncAccountsSource, @unchecked Sendable {
    let model: AccountsModel

    init(model: AccountsModel) {
        self.model = model
    }

    func tokenSource(for accountId: UUID) async -> AccessTokenSource? {
        await MainActor.run { model.tokenManager(for: accountId) }
    }

    func markReauthNeeded(_ accountId: UUID) async {
        let model = self.model
        await MainActor.run {
            guard model.record(accountId)?.health != .reauthNeeded else { return }
            model.update(accountId) {
                $0.health = .reauthNeeded
                $0.healthDetail = HealthText.detail(.reauthNeeded)
            }
            // About a week after consent: the user's Google app is likely still in Testing (D-038).
            Task { @MainActor in
                let detail = await model.reauthDetail(accountId)
                guard detail != HealthText.detail(.reauthNeeded), model.record(accountId)?.health == .reauthNeeded else { return }
                model.update(accountId) { $0.healthDetail = detail }
            }
        }
    }

    func apiAvailability(_ accountId: UUID, api: String, available: Bool) async {
        guard let kind = GoogleAPIKind(rawValue: api) else { return }
        let model = self.model
        await MainActor.run {
            if available { model.noteAPIWorking(accountId, kind) } else { model.noteAPIDisabled(accountId, kind) }
        }
    }
}

/// Keeps the live hooks alive: wake/unlock/network triggers and the accounts observer.
@MainActor
final class DataLiveHooks {
    private let wake: WakeTriggers
    private var accountsWatch: AnyCancellable?

    init(model: AccountsModel, engine: DataEngine) {
        wake = WakeTriggers { Task.detached { engine.wake() } }
        wake.start()
        accountsWatch = model.$accounts
            .map { rows in
                rows.map { "\($0.id)|\($0.health.rawValue)|\($0.calendarEnabled)|\($0.mailEnabled)|\($0.includeInAll)|\($0.tag)|\($0.color)|\($0.displayName)|\($0.logoFile ?? "-")|\($0.sortOrder)" }
            }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in Task.detached { engine.accountsChanged() } }
    }

    func stop() {
        wake.stop()
        accountsWatch = nil
    }
}

extension DataServices {
    @MainActor private static var hooks: DataLiveHooks?
    @MainActor private static var starting = false

    /// The app's one call (AppDelegate, right after `AccountsModel.shared.start()`): waits for the
    /// accounts store to open (it shares that SQLite connection, so migrations run exactly once), then
    /// starts the engine with the real Keychain link key, `HTTP.shared` and WidgetKit reloads.
    @MainActor
    static func start(accounts model: AccountsModel) {
        guard engine == nil, !starting else { return }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            var database = model.repo?.db
            var waited = 0
            while database == nil && waited < 200 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
                database = model.repo?.db
            }
            guard let database else {
                Trace.app("data-start", ["result": "no-store"])
                return
            }
            var env = DataEnvironment(database: database, source: AccountsModelSource(model: model),
                                      transport: HTTP.shared, linkKeys: KeychainLinkKeyStore(),
                                      reloader: WidgetKitReloader(), widgetDirectory: Paths.widget,
                                      logosDirectory: Paths.logos)
            env.labsMail = { true }   // mail is on (D-029); the seam stays for the data tests' mail-off runs
            env.labsSafeSend = { Labs.safeSend }
            env.mailCacheDirectory = Paths.root.appendingPathComponent("mailcache", isDirectory: true)
            env.attachmentDirectory = Paths.attachments
            env.outboxDirectory = Paths.outbox
            env.imagesFromCorrespondents = { RichMailSettings(local: DefaultsMailLocalStore.shared).imagesFromCorrespondents }
            env.trace = { event, detail in Trace.app(event, ["detail": detail]) }
            let engine = Task.detached { DataServices.start(environment: env) }
            hooks = DataLiveHooks(model: model, engine: await engine.value)
        }
    }
}
#endif
