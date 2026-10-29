import AppKit

/// The live side of the link to Yaya's Murmur (D-046): whether Murmur is on this Mac (LaunchServices: a handler of its
/// URL scheme that carries its bundle id), its marks file (read here and nowhere else, never written, never logged or
/// sent), its change ping, and opening its links. `install()` points `MurmurSession.shared` at it; a change of presence
/// republishes the widgets (their record buttons follow, D-046).
@MainActor
enum MurmurLive {
    private static var pingTarget: PingTarget?
    private static var pending: DispatchWorkItem?

    static func install() {
        MurmurSession.shared.env = MurmurSession.Environment(
            installed: { installed() },
            marks: { marks() },
            open: { NSWorkspace.shared.open($0) },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            })
        installedFlag.set(probe())
        checkedAt = Date()
        MurmurSession.shared.refresh()
        SnapshotPublisher.liveHelperMarked = { helperEvents.get().contains($0) }
        syncHelperEvents(republish: false)
        guard pingTarget == nil else { return }
        // Murmur pings after every write of its marks (and on its uninstall). AppKit holds distributed notifications
        // for an app that isn't active, and this agent rarely is: deliver at once.
        let target = PingTarget()
        DistributedNotificationCenter.default().addObserver(
            target, selector: #selector(PingTarget.marksChanged(_:)),
            name: NSNotification.Name(MurmurMarks.changedNotification), object: nil, suspensionBehavior: .deliverImmediately)
        pingTarget = target
    }

    /// Pings within 0.3 s are read once.
    fileprivate static func pinged() {
        pending?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                checkedAt = .distantPast   // an uninstall pings too: look again
                MurmurSession.shared.refresh()
                syncHelperEvents(republish: true)
                Trace.app("murmur", ["action": "marks", "result": traceName(MurmurSession.shared.marks)])
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Presence

    /// Looked up at most every 30 s (surfaces ask on every load); a change republishes the widgets.
    private static var checkedAt = Date.distantPast
    static let recheck: TimeInterval = 30

    static func installed() -> Bool {
        guard Date().timeIntervalSince(checkedAt) >= recheck else { return installedFlag.get() }
        checkedAt = Date()
        let now = probe()
        if now != installedFlag.get() {
            installedFlag.set(now)
            Trace.app("murmur", ["action": "presence", "result": now ? "installed" : "gone"])
            // The widgets' record buttons and the heads-up categories follow (FathomLive republishes on this).
            NotificationCenter.default.post(name: FathomPrefs.changed, object: nil)
        }
        return now
    }

    /// A handler of `<murmurScheme>:` whose bundle id is Murmur's (another app claiming the scheme doesn't count).
    nonisolated static func probe() -> Bool {
        guard let url = URL(string: Profile.murmurScheme + ":") else { return false }
        let handlers = NSWorkspace.shared.urlsForApplications(toOpen: url).map { Bundle(url: $0)?.bundleIdentifier }
        return MurmurPresence.isInstalled(handlers: handlers)
    }

    /// The publisher builds snapshots off the main thread, and the Deck export switch is read off it too.
    nonisolated static let installedFlag = LockedFlag()

    /// The events Murmur marked Live Helper, for the widgets' Join with Live Helper button (D-048); empty while
    /// Murmur isn't on this Mac. Read off the main thread by the publisher.
    nonisolated static let helperEvents = LockedValue<Set<String>>([])

    /// After a read of the marks: a changed set republishes the widgets.
    static func syncHelperEvents(republish: Bool) {
        let session = MurmurSession.shared
        let next = session.installed ? Set(session.marks.marks.filter { $0.value.helper != nil }.keys) : []
        guard next != helperEvents.get() else { return }
        helperEvents.set(next)
        if republish { DataServices.republishWidgets() }
    }

    // MARK: The marks file

    static var marksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Profile.murmurDataRoot, isDirectory: true)
            .appendingPathComponent(MurmurMarks.shareFolder, isDirectory: true)
            .appendingPathComponent(MurmurMarks.fileName)
    }

    private struct Stamp: Equatable { let dev: Int32; let ino: UInt64; let size: Int64; let mtime: Int; let mtimeNs: Int }
    private static var lastStamp: Stamp?
    private static var lastState: MurmurMarks.State = .missing

    /// The marks, re-read only when the file changed (device, inode, size, modification time).
    static func marks() -> MurmurMarks.State {
        switch read(marksURL.path, stamp: lastStamp) {
        case .missing:
            lastStamp = nil; lastState = .missing
        case .unreadable:
            lastStamp = nil; lastState = .unreadable
        case .unchanged:
            break
        case .data(let data, let stamp):
            lastStamp = stamp
            lastState = MurmurMarks.parse(data)
        }
        return lastState
    }

    private enum Read { case missing, unreadable, unchanged, data(Data, Stamp) }

    /// `open(O_NOFOLLOW)`, then `fstat` on that descriptor: a regular file owned by this user, at most
    /// `MurmurMarks.fileLimit` bytes. Read through the same descriptor, so the checked file is the read one.
    private static func read(_ path: String, stamp previous: Stamp?) -> Read {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= Int64(MurmurMarks.fileLimit) else { return .unreadable }
        let stamp = Stamp(dev: info.st_dev, ino: info.st_ino, size: info.st_size,
                          mtime: info.st_mtimespec.tv_sec, mtimeNs: info.st_mtimespec.tv_nsec)
        if stamp == previous { return .unchanged }
        var data = Data(count: MurmurMarks.fileLimit + 1)
        var total = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while total < raw.count {
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: total), raw.count - total)
                if n < 0 { return false }
                if n == 0 { return true }
                total += n
            }
            return true
        }
        guard ok, total <= MurmurMarks.fileLimit else { return .unreadable }
        data.count = total
        return .data(data, stamp)
    }

    static func traceName(_ state: MurmurMarks.State) -> String {
        switch state {
        case .missing: return "missing"
        case .unreadable: return "unreadable"
        case .newer: return "newer"
        case .ready(let m, let skipped): return "ok-\(m.count)" + (skipped > 0 ? "-skipped-\(skipped)" : "")
        }
    }
}

/// The ping's selector target (DistributedNotificationCenter's `.deliverImmediately` needs the selector API).
private final class PingTarget: NSObject {
    @objc func marksChanged(_ note: Notification) {
        DispatchQueue.main.async { MainActor.assumeIsolated { MurmurLive.pinged() } }
    }
}
