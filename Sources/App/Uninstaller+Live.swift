import Foundation
import Security
import WebKit

/// The real seams of `Uninstaller` and the headless flags (docs/CONTRACTS.md, installer flags):
///
///   --uninstall                     drop the login item, this app's notifications and the Deck export
///   --uninstall --purge             … and everything in `UninstallPlan` (revoke, Keychain, folders, prefs)
///   --purge                         the same as --uninstall --purge
///   --purge --dry-run               print the paths and Keychain service names it would remove; exit
extension Uninstaller {
    static func run(purge: Bool, dryRun: Bool = false) -> String {
        let plan = UninstallPlan.make(home: Paths.realHome)
        if dryRun {
            return plan.dryRun { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard purge else {
            LoginItem.unregisterIfNeeded()
            NotifyCleanup.removeAll()   // no heads-up fires for a removed app; Deck stops seeing meetings
            return "Yaya's Calendar: login item, this app's notifications and the Deck export removed. Accounts, Keychain items and the rest of the data kept."
        }
        // No trace after this point: writing one would recreate the data folder.
        Trace.muted = true
        let report = offMain { removeEverything(plan: plan, steps: .live) }
        return report.summary
    }

    /// The mail reader's compiled content rule lists, through WebKit's own API (in the app only; the
    /// folder `~/Library/WebKit/<bundle id>` goes with the plan either way). At most 2 s.
    @MainActor static func removeWebKitRuleLists() async {
        guard let store = WKContentRuleListStore.default() else { return }
        for allowRemote in [false, true] {
            let id = MailContentPolicy.ruleListIdentifier(allowRemote: allowRemote)
            let done = LockedValue(false)
            store.removeContentRuleList(forIdentifier: id) { _ in done.set(true) }
            for _ in 0..<20 where !done.get() { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
    }

    /// Read-only use of the accounts code's vault and client (Sources/Auth). Anything locked or missing
    /// is skipped: the items are still deleted, the provider just keeps an orphaned grant.
    static func revokeGoogleTokens(budget: TimeInterval) -> Int {
        guard let client = try? OAuthConfig.load(.google) else { return 0 }
        let vault = TokenVault()
        let tokens: [String] = ((try? vault.accountIDs()) ?? []).compactMap { id in
            guard let credential = try? vault.read(id), credential.provider == .google else { return nil }
            return credential.refreshToken
        }
        guard !tokens.isEmpty else { return 0 }
        let flow = OAuthFlow(provider: .google, client: client)
        let confirmed = LockedValue(0)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Bool.self) { group in
                for token in tokens { group.addTask { await flow.revoke(token) } }
                for await ok in group where ok { confirmed.update { $0 += 1 } }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + budget)
        return confirmed.get()
    }

    /// Deletes every generic-password item under `service`; returns how many went.
    static func deleteAll(service: String) -> Int {
        let before = count(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var attempts = 0
        while attempts < 64, SecItemDelete(query as CFDictionary) == errSecSuccess { attempts += 1 }
        return max(0, before - count(service: service))
    }

    /// Attributes only: never prompts.
    static func count(service: String) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return 0 }
        if let items = result as? [[String: Any]] { return items.count }
        return result == nil ? 0 : 1
    }
}

extension UninstallSteps {
    /// This Mac, this user. Only `--uninstall --purge` and Settings → "Remove everything and quit" use it.
    static var live: UninstallSteps {
        UninstallSteps(
            revoke: { Uninstaller.revokeGoogleTokens(budget: $0) },
            deleteKeychain: { Uninstaller.deleteAll(service: $0) },
            countKeychain: { Uninstaller.count(service: $0) },
            removeDefaults: { domain in
                UserDefaults.standard.removePersistentDomain(forName: domain)
                return CFPreferencesAppSynchronize(domain as CFString)
            },
            loginItemOff: { LoginItem.unregisterIfNeeded() },
            clearNotifications: { NotifyCleanup.removeAll() })
    }
}
