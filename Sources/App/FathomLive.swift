import AppKit

/// The live side of Join with Fathom (D-045): whether Fathom is on this Mac, which account it is signed into
/// (two small local files of Fathom's, read here and nowhere else, never logged or sent), and opening its links.
/// `install()` points `FathomSession.shared` at it and republishes the widgets when a link changes.
@MainActor
enum FathomLive {
    private static var observer: NSObjectProtocol?

    static func install() {
        FathomSession.shared.env = FathomSession.Environment(
            installed: { installed() },
            signIn: { FathomSignIn.parse(config: readConfig(), manifests: manifestNames()) },
            link: { FathomPrefs.link($0) },
            open: { NSWorkspace.shared.open($0) },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            },
            every: { interval, work in
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                    MainActor.assumeIsolated { work() }
                }
                return { timer.invalidate() }
            },
            clock: { Date() })
        SnapshotPublisher.fathomOffered = { ids, hasJoin in
            installedCache.get() && FathomRouting.offered(accountIds: ids, hasJoin: hasJoin, link: { FathomPrefs.link($0) })
        }
        installedCache.set(installed())
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: FathomPrefs.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                installedCache.set(installed())
                DataServices.republishWidgets()
            }
        }
    }

    /// Fathom's Mac app, by its bundle identifier.
    static func installed() -> Bool {
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FathomURLs.bundleId) != nil
        installedCache.set(found)
        return found
    }

    // MARK: Fathom's files

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// Written by the Fathom app for its Chrome bridge: `account` holds the signed-in user's id and address.
    static var configURL: URL { home.appendingPathComponent("Library/Application Support/Fathom/bridge-config.json") }
    /// Where Fathom writes its bridge manifests, one named after the signed-in user's id.
    static var manifestsURL: URL { home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true) }

    /// The config's bytes: a regular file (not a link) of at most `FathomSignIn.configLimit`.
    static func readConfig() -> Data? {
        let url = configURL
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? .max) <= FathomSignIn.configLimit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: FathomSignIn.configLimit + 1)
    }

    /// Only the names of Fathom's own manifests.
    static func manifestNames() -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: manifestsURL.path) else { return nil }
        return names.filter { $0.hasPrefix(FathomSignIn.hostPrefix) }
    }

    /// The publisher builds snapshots off the main thread; it reads the last answer.
    nonisolated static let installedCache = LockedFlag()
}

/// A Bool shared across threads.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}
