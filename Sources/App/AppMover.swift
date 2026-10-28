import AppKit
import CryptoKit
import Security

/// "Move me to Applications" (D-039): facts about the copies on disk for `AppPlacement`, and the move
/// itself. It copies this bundle to /Applications (or ~/Applications), opens the copy and quits. It never
/// replaces a copy `AppPlacement` refused (signed by someone else, newer, or running); an older copy of
/// ours goes to the Trash, never a delete. Only the user's click runs it; tests use the decision alone.
@MainActor
enum AppMover {
    static var systemApplications: URL { URL(fileURLWithPath: "/Applications", isDirectory: true) }
    static var userApplications: URL { Paths.realHome.appendingPathComponent("Applications", isDirectory: true) }

    static var onboardingSystem: OnboardingSystem {
        OnboardingSystem(loginItemEnabled: { LoginItem.isEnabled },
                         setLoginItem: { LoginItem.set($0) },
                         placement: { placement() },
                         move: { move(toUserApplications: $0) })
    }

    static func placement() -> PlacementChoice {
        let current = Bundle.main.bundleURL
        guard let mine = facts(at: current) else { return .inApplications }
        let name = current.lastPathComponent
        return AppPlacement.decide(current: mine,
                                   system: facts(at: systemApplications.appendingPathComponent(name)),
                                   user: facts(at: userApplications.appendingPathComponent(name)),
                                   home: Paths.realHome.path)
    }

    /// Nil when no app bundle is there.
    static func facts(at url: URL) -> BundleFacts? {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path),
              let bundle = Bundle(url: url) else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle.bundleIdentifier ?? "-")
            .contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        return BundleFacts(path: url.path, version: version, signer: signer(of: url), running: running)
    }

    /// SHA-256 of the leaf signing certificate; nil for ad-hoc or unsigned bundles.
    static func signer(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256Hex.of(data)
    }

    /// Returns a line to show when it couldn't move; on success the new copy opens and this one quits.
    static func move(toUserApplications: Bool) -> String? {
        let choice = placement()
        let replacing: Bool
        switch (choice, toUserApplications) {
        case (.moveToApplications(let r), false): replacing = r
        case (.offerUserApplications, true): replacing = false
        default: return "I left everything where it is."
        }
        let fm = FileManager.default
        let folder = toUserApplications ? userApplications : systemApplications
        let source = Bundle.main.bundleURL
        let target = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                // ~/Applications: only an older copy of ours (checked again here).
                if toUserApplications, let mine = facts(at: source), let there = facts(at: target),
                   AppPlacement.refusal(current: mine, existing: there) != nil {
                    return "Your Applications folder already has a copy I shouldn\u{2019}t replace."
                }
                guard replacing || toUserApplications else { return "I left everything where it is." }
                try fm.trashItem(at: target, resultingItemURL: nil)
            }
            try fm.copyItem(at: source, to: target)
        } catch {
            Trace.app("move-to-applications", ["result": "error"])
            return "macOS didn\u{2019}t let me copy myself there. Drag me into Applications in Finder instead."
        }
        Trace.app("move-to-applications", ["result": "copied", "user": toUserApplications ? "1" : "0"])
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, _ in
            guard app != nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return nil
    }
}

/// Hex SHA-256 of a certificate (compared, never shown).
enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
