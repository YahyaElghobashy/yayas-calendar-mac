import AppKit

/// The live side of Model Atlas on the Daily Digest widget (D-054): its one file (read here and nowhere else, never
/// logged or sent), its change ping, the box's "opened once" mark, and opening the report a tap names. Read at launch,
/// on the ping and when the day changes (the Mac may sleep through Saturday's run). No network.
@MainActor
enum ModelAtlasLive {
    private static var pingTarget: ModelAtlasPingTarget?
    private static var pending: DispatchWorkItem?
    nonisolated static let feed = LockedValue<WidgetSnapshot.Atlas?>(nil)
    private static var last: ModelAtlasDigest?

    static func install() {
        SnapshotPublisher.atlasFeed = { feed.get() }
        refresh(republish: false)
        guard pingTarget == nil else { return }
        let target = ModelAtlasPingTarget()
        DistributedNotificationCenter.default().addObserver(
            target, selector: #selector(ModelAtlasPingTarget.changed(_:)),
            name: NSNotification.Name(ModelAtlasFiles.changedNotification), object: nil, suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(target, selector: #selector(ModelAtlasPingTarget.changed(_:)),
                                               name: .NSCalendarDayChanged, object: nil)
        pingTarget = target
    }

    /// Pings within 0.3 s are read once.
    fileprivate static func pinged() {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { refresh(republish: true) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    static var fileURL: URL {
        Paths.realHome.appendingPathComponent(Profile.modelAtlasDataRoot, isDirectory: true)
            .appendingPathComponent(ModelAtlasFiles.shareFolder, isDirectory: true)
            .appendingPathComponent(ModelAtlasFiles.digestFile)
    }

    /// Re-reads the file; a changed box republishes the Daily Digest.
    static func refresh(republish: Bool) {
        let read = ModelAtlasParse.digest(readFile(fileURL.path))
        last = read.value
        let next = last.map { ModelAtlasParse.snapshot($0, seen: UserDefaults.standard.string(forKey: ModelAtlasFiles.seenKey)) }
        guard next != feed.get() else { return }
        feed.set(next)
        Trace.app("modelatlas", ["action": "read", "result": next == nil ? "none" : "ready"])
        if republish { DataServices.republishDigest(interactive: NSApp.isActive) }
    }

    /// `open/atlas`: the week's report (else the atlas) in the person's Markdown app, then the box is no longer new.
    static func open() -> Bool {
        refresh(republish: false)
        guard let d = last, let path = ModelAtlasOpen.target(d, home: Paths.realHome.path), isPlainFile(path) else {
            Trace.app("modelatlas", ["action": "open", "result": "nothing"])
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.addsToRecentItems = false
        NSWorkspace.shared.open(URL(fileURLWithPath: path), configuration: config) { _, error in
            if error != nil { DispatchQueue.main.async { Trace.app("modelatlas", ["action": "open", "result": "failed"]) } }
        }
        UserDefaults.standard.set(d.seenKey, forKey: ModelAtlasFiles.seenKey)
        refresh(republish: true)
        Trace.app("modelatlas", ["action": "open", "result": "ok"])
        return true
    }

    /// A regular file of this user, not a link.
    private static func isPlainFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
    }

    /// `open(O_NOFOLLOW)`, then `fstat` on that descriptor: a regular file of this user, at most 64 KiB, read through it.
    /// Nil when missing or refused (the parser treats nil as "no box").
    private static func readFile(_ path: String) -> Data? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        let limit = ModelAtlasFiles.fileLimit
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= Int64(limit) else { return nil }
        var data = Data(count: Int(info.st_size) + 1)
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
        guard ok, total <= limit else { return nil }
        data.count = total
        return data
    }
}

/// The ping's and the day change's selector target.
private final class ModelAtlasPingTarget: NSObject {
    @objc func changed(_ note: Notification) {
        DispatchQueue.main.async { MainActor.assumeIsolated { ModelAtlasLive.pinged() } }
    }
}
