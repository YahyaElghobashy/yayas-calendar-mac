// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import Foundation
import Security

/// `--selftest`: headless checks of what the build must be able to do on this Mac, then one JSON line
/// and exit 0 (pass) or 1. No UI, no network. Runs before NSApplication exists.
///
///   dirs        data folders exist and are 0700
///   keychain    add + read + delete a generic password (service …oauth, account "selftest"), every
///               query non-interactive (kSecUseAuthenticationUIFail only; never
///               SecKeychainSetUserInteractionAllowed, docs/CONTRACTS.md)
///   widgetFile  write + read + delete a JSON file in the widget folder (what the widget will read)
enum SelfTest {
    static let keychainService = Profile.keychainOAuth
    static let keychainAccount = "selftest"

    static func run() -> Int32 {
        let started = Date()
        var checks: [(name: String, ok: Bool)] = []
        var failures: [String: String] = [:]

        func record(_ name: String, _ result: Result<Void, CheckError>) {
            switch result {
            case .success: checks.append((name, true))
            case .failure(let error): checks.append((name, false)); failures[name] = error.code
            }
        }
        record("dirs", dirs())
        record("keychain", keychain())
        record("widgetFile", widgetFile())

        let millis = Int(Date().timeIntervalSince(started) * 1000)
        print(SuiteJSON.selftest(checks: checks, failures: failures, millis: millis))
        fflush(stdout)
        return checks.allSatisfy(\.ok) ? 0 : 1
    }

    struct CheckError: Error {
        let code: String
        init(_ code: String) { self.code = code }
    }

    static func dirs() -> Result<Void, CheckError> {
        do {
            for url in try DataFolders.ensure() {
                guard let mode = DataFolders.mode(url) else { return .failure(CheckError("missing:\(url.lastPathComponent)")) }
                guard mode & 0o777 == 0o700 else {
                    return .failure(CheckError("mode:\(url.lastPathComponent):\(String(mode & 0o777, radix: 8))"))
                }
            }
            return .success(())
        } catch {
            return .failure(CheckError("create"))
        }
    }

    static func keychain() -> Result<Void, CheckError> {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        SecItemDelete(base as CFDictionary)   // a leftover from an interrupted run

        let payload = Data("yayascalendar selftest \(UUID().uuidString)".utf8)
        var add = base
        add.removeValue(forKey: kSecUseAuthenticationUI as String)   // not an add attribute
        add[kSecValueData as String] = payload
        add[kSecAttrLabel as String] = "Yaya\u{2019}s Calendar self-test"
        var status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { return .failure(CheckError("add:\(status)")) }

        var read = base
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        status = SecItemCopyMatching(read as CFDictionary, &item)
        guard status == errSecSuccess else {
            SecItemDelete(base as CFDictionary)
            return .failure(CheckError("read:\(status)"))
        }
        guard (item as? Data) == payload else {
            SecItemDelete(base as CFDictionary)
            return .failure(CheckError("read:mismatch"))
        }

        status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess else { return .failure(CheckError("delete:\(status)")) }
        item = nil
        status = SecItemCopyMatching(read as CFDictionary, &item)
        guard status == errSecItemNotFound else { return .failure(CheckError("still-there:\(status)")) }
        return .success(())
    }

    static func widgetFile() -> Result<Void, CheckError> {
        struct Probe: Codable, Equatable { var v = 1; var kind = "selftest"; var token = UUID().uuidString }
        let url = Paths.widget.appendingPathComponent("selftest.json")
        let probe = Probe()
        do {
            try JSONEncoder().encode(probe).write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }
            let back = try JSONDecoder().decode(Probe.self, from: Data(contentsOf: url))
            guard back == probe else { return .failure(CheckError("mismatch")) }
            if let mode = DataFolders.mode(url), mode & 0o077 != 0 {
                return .failure(CheckError("mode:\(String(mode & 0o777, radix: 8))"))
            }
            return .success(())
        } catch {
            return .failure(CheckError("io"))
        }
    }
}
#endif
