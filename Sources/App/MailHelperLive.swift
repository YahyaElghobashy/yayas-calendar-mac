import AppKit

/// The live side of the link to Yaya's Mail Helper (D-050): whether the helper is on this Mac (LaunchServices: a
/// handler of its URL scheme that carries its bundle id), its two files and its answers (read here and nowhere else,
/// never logged or sent), its change ping, the command files this app writes in its own data folder and the one link
/// that announces them, the hand-over's Keychain read, opening the threads it names, and the meeting people it is sent
/// once a day. No network: the helper is the one that talks to the owner's mail server.
@MainActor
enum MailHelperLive {
    private static var pingTarget: MailHelperPingTarget?
    private static var pending: DispatchWorkItem?
    private static var timer: Timer?

    static func install() {
        MailHelperSession.shared.env = MailHelperSession.Environment(
            installed: { installed() },
            state: { readState() },
            digest: { readDigest() },
            write: { id, data in writeCommand(id, data) },
            open: { open($0) },
            answer: { readAnswer($0) },
            clock: { Date() },
            after: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            })
        installedFlag.set(probe())
        checkedAt = Date()
        MailHelperDraftModel.threadIdLookup = { DataServices.gmailThreadId(r: $0) }
        ShellModel.shared.mailHelper.live = MailHelperModel.Live(
            credentials: { id in try await credentials(id) },
            personalDomains: AccountNaming.personalDomains,
            openThread: { account, thread in openThread(account, thread) },
            reply: { account, thread in reply(account, thread) })
        removeStaleCommands()
        installVoice()
        SnapshotPublisher.digestFeed = { digestFeed.get() }
        MailHelperSession.shared.refresh()
        afterRefresh()
        guard pingTarget == nil else { return }
        // The helper pings after each write of its files (and on its uninstall). AppKit holds distributed notifications
        // for an app that isn't active, and this agent rarely is: deliver at once.
        let target = MailHelperPingTarget()
        DistributedNotificationCenter.default().addObserver(
            target, selector: #selector(MailHelperPingTarget.changed(_:)),
            name: NSNotification.Name(MailHelperFiles.changedNotification), object: nil, suspensionBehavior: .deliverImmediately)
        pingTarget = target
        // Meeting people once a day (MailHelperMeetings.due), checked every hour.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { syncMeetingPeople() }
        }
    }

    /// Pings within 0.3 s are read once.
    fileprivate static func pinged() {
        pending?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                checkedAt = .distantPast   // an uninstall pings too: look again
                MailHelperSession.shared.refresh()
                afterRefresh()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private static var wasInstalled = false

    /// After a read: the helper (re)appeared → its meeting people go now.
    private static func afterRefresh() {
        let now = MailHelperSession.shared.installed
        if now != wasInstalled {
            wasInstalled = now
            meetingsSent = [:]
            Trace.app("mailhelper", ["action": "presence", "result": now ? "installed" : "gone"])
        }
        syncDigestFeed()
        syncMeetingPeople()
    }

    // MARK: The Daily Digest widget (D-053)

    nonisolated static let digestFeed = LockedValue<SnapshotPublisher.DigestFeed>(.off)

    /// The widget's digest from what the session read; a change republishes that one kind.
    static func syncDigestFeed() {
        let session = MailHelperSession.shared
        let next: SnapshotPublisher.DigestFeed
        if !session.installed {
            next = .off
        } else if let digest = session.digest {
            let known = AccountDirectory.current().accounts.map(\.id)
            next = .ready(MailHelperDigestWidget.snapshot(digest, mailboxes: MailHelperDigestWidget.mailboxes(session.state),
                                                          known: known))
        } else {
            next = .none
        }
        guard next != digestFeed.get() else { return }
        digestFeed.set(next)
        Trace.app("mailhelper", ["action": "digest-widget", "result": {
            switch next { case .off: return "off"; case .none: return "none"; case .ready: return "ready" }
        }()])
        DataServices.republishDigest(interactive: NSApp.isActive)
    }

    /// The Daily Digest's ↻ (`sync?w=digest`): read the helper's files now and ask it for fresh numbers.
    static func refreshForWidget() {
        checkedAt = .distantPast
        MailHelperSession.shared.refresh()
        afterRefresh()
        if MailHelperSession.shared.installed { MailHelperSession.shared.send(.refresh()) }
    }

    // MARK: Presence

    /// Looked up at most every 30 s (surfaces ask on every load).
    private static var checkedAt = Date.distantPast
    static let recheck: TimeInterval = 30
    nonisolated static let installedFlag = LockedFlag()

    static func installed() -> Bool {
        guard Date().timeIntervalSince(checkedAt) >= recheck else { return installedFlag.get() }
        checkedAt = Date()
        let now = probe()
        if now != installedFlag.get() { installedFlag.set(now) }
        return now
    }

    nonisolated static func probe() -> Bool {
        guard let url = URL(string: Profile.mailHelperScheme + ":") else { return false }
        let handlers = NSWorkspace.shared.urlsForApplications(toOpen: url).map { Bundle(url: $0)?.bundleIdentifier }
        return MailHelperPresence.isInstalled(handlers: handlers)
    }

    /// Opens the command link without bringing the helper forward; a failure ends that command's wait at once.
    static func open(_ url: URL) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Trace.app("mailhelper", ["action": "link", "result": "failed"])
                    MailHelperSession.shared.linkFailed(url)
                }
            }
        }
        return true
    }

    // MARK: The helper's files

    static var shareURL: URL {
        Paths.realHome.appendingPathComponent(Profile.mailHelperDataRoot, isDirectory: true)
            .appendingPathComponent(MailHelperFiles.shareFolder, isDirectory: true)
    }

    private struct Stamp: Equatable { let dev: Int32; let ino: UInt64; let size: Int64; let mtime: Int; let mtimeNs: Int }
    private static var stateStamp: Stamp?
    private static var stateLast: MailHelperRead<MailHelperState> = .missing
    private static var digestStamp: Stamp?
    private static var digestLast: MailHelperRead<MailHelperDigest?> = .missing

    static func readState() -> MailHelperRead<MailHelperState> {
        switch read(shareURL.appendingPathComponent(MailHelperFiles.stateFile).path, stamp: stateStamp) {
        case .missing: stateStamp = nil; stateLast = .missing
        case .unreadable: stateStamp = nil; stateLast = .unreadable
        case .unchanged: break
        case .data(let data, let stamp): stateStamp = stamp; stateLast = MailHelperParse.state(data)
        }
        return stateLast
    }

    static func readDigest() -> MailHelperRead<MailHelperDigest?> {
        switch read(shareURL.appendingPathComponent(MailHelperFiles.digestFile).path, stamp: digestStamp) {
        case .missing: digestStamp = nil; digestLast = .missing
        case .unreadable: digestStamp = nil; digestLast = .unreadable
        case .unchanged: break
        case .data(let data, let stamp): digestStamp = stamp; digestLast = MailHelperParse.digest(data)
        }
        return digestLast
    }

    /// The answer to one command: read, then deleted (the contract has the calendar delete what it read).
    static func readAnswer(_ id: UUID) -> MailHelperResult? {
        let path = shareURL.appendingPathComponent(MailHelperFiles.resultsFolder, isDirectory: true)
            .appendingPathComponent(MailHelperFiles.resultName(id)).path
        switch read(path, stamp: nil) {
        case .missing, .unchanged:
            return nil
        case .unreadable:
            unlink(path)
            return .failure(id, "Yaya\u{2019}s Mail Helper answered in a way I can\u{2019}t read.")
        case .data(let data, _):
            unlink(path)
            return MailHelperParse.result(data, id: id)
        }
    }

    private enum Read { case missing, unreadable, unchanged, data(Data, Stamp) }

    /// `open(O_NOFOLLOW)`, then `fstat` on that descriptor: a regular file owned by this user, at most 4 MiB. Read
    /// through the same descriptor, so the checked file is the read one.
    private static func read(_ path: String, stamp previous: Stamp?) -> Read {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
        defer { close(fd) }
        var info = stat()
        let limit = MailHelperFiles.fileLimit
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= Int64(limit) else { return .unreadable }
        let stamp = Stamp(dev: info.st_dev, ino: info.st_ino, size: info.st_size,
                          mtime: info.st_mtimespec.tv_sec, mtimeNs: info.st_mtimespec.tv_nsec)
        if let previous, stamp == previous { return .unchanged }
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
        guard ok, total <= limit, total <= Int(info.st_size) else { return .unreadable }
        data.count = total
        return .data(data, stamp)
    }

    // MARK: Command files

    /// `<data root>/share/mailhelper/` (0700): never a symbolic link, always this user's.
    static var commandFolder: URL { Paths.share.appendingPathComponent(MailHelperFiles.commandFolder, isDirectory: true) }

    private static func ensureFolder() -> Bool {
        for url in [Paths.root, Paths.share, commandFolder] {
            if mkdir(url.path, 0o700) != 0, errno != EEXIST { return false }
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
        }
        return chmod(commandFolder.path, 0o700) == 0
    }

    /// `cmd-<uuid>.json`, written to a temporary name (O_EXCL, O_NOFOLLOW, 0600), synced, then renamed into place.
    static func writeCommand(_ id: UUID, _ data: Data) -> Bool {
        guard data.count <= MailHelperFiles.commandLimit else { return false }
        return writeShared(data, final: MailHelperFiles.commandName(id), temp: "." + MailHelperFiles.commandName(id) + ".tmp")
    }

    /// A file in the share folder the way commands are written: temporary name, O_EXCL, O_NOFOLLOW, 0600, fsync, rename.
    static func writeShared(_ data: Data, final finalName: String, temp tempName: String) -> Bool {
        guard ensureFolder() else { return false }
        let final = commandFolder.appendingPathComponent(finalName).path
        let temp = commandFolder.appendingPathComponent(tempName).path
        let fd = Darwin.open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            ok = data.withUnsafeBytes { raw -> Bool in
                var done = 0
                while done < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                    if n <= 0 { return false }
                    done += n
                }
                return true
            }
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temp, final) == 0 else {
            unlink(temp)
            return false
        }
        return true
    }

    /// Commands and voice notes the helper never picked up (it deletes each one it reads) go after an hour.
    private static func removeStaleCommands() {
        removeStale(in: commandFolder, suffix: nil)
    }

    /// Regular files older than an hour in `folder` (`suffix` nil: commands, temporaries and voice notes).
    static func removeStale(in folder: URL, suffix: String?) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where suffix.map({ name.hasSuffix($0) }) ?? (name.hasSuffix(".json") || name.hasSuffix(".tmp") || name.hasSuffix(".wav")) {
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff else { continue }
            unlink(path)
        }
    }

    // MARK: The hand-over's sign-in

    /// The account's refresh token and the Google client, off the main thread through the Keychain gate. They exist
    /// only in memory until the model seals them.
    nonisolated static func credentials(_ id: UUID) async throws -> MailHelperSignIn {
        let fallbackEmail = await MainActor.run { AccountDirectory.current().account(id)?.email ?? "" }
        return try await Task.detached(priority: .userInitiated) { () throws -> MailHelperSignIn in
            let credential: StoredCredential
            do {
                credential = try TokenVault().read(id)
            } catch let e as KeychainError {
                throw e == .notFound ? MailHelperSignInError.notConnected
                    : (e.isTransient ? MailHelperSignInError.keychainWaiting : MailHelperSignInError.failed)
            }
            guard credential.provider == .google, !credential.refreshToken.isEmpty else { throw MailHelperSignInError.notConnected }
            let client: ProviderClient?
            do {
                client = try OAuthConfig.load(.google)
            } catch let e as KeychainError where e.isTransient {
                throw MailHelperSignInError.keychainWaiting
            } catch {
                throw MailHelperSignInError.noClient
            }
            guard let client, let secret = client.clientSecret, !secret.isEmpty else { throw MailHelperSignInError.noClient }
            return MailHelperSignIn(refreshToken: credential.refreshToken, clientId: client.clientId, clientSecret: secret,
                                    email: credential.email ?? fallbackEmail)
        }.value
    }

    // MARK: Threads it names

    /// The app's own reader (the Mail Peek) for a thread of the digest, Review or the backlog's samples.
    static func openThread(_ account: UUID, _ thread: String) {
        Task { @MainActor in
            do {
                let t = try await DataServices.mailThread(accountId: account, threadId: thread)
                if !PeekController.shared.showMessage(r: t.r) {
                    ShellModel.shared.mailHelper.toasts.error("I couldn\u{2019}t open that email just now.")
                }
            } catch {
                ShellModel.shared.mailHelper.toasts.error("I couldn\u{2019}t open that email: \(MailHelperLive.words(error))")
            }
        }
    }

    /// Needs reply → Reply: the app's reply composer for that thread, its latest message quoted.
    static func reply(_ account: UUID, _ thread: String) {
        Task { @MainActor in
            do {
                let t = try await DataServices.mailThread(accountId: account, threadId: thread)
                let messages = (try? await Services.mail.messages(threadR: t.r)) ?? []
                ComposerWindowController.open(.reply(t, messages.max { $0.date < $1.date }))
            } catch {
                ShellModel.shared.mailHelper.toasts.error("I couldn\u{2019}t open a reply: \(MailHelperLive.words(error))")
            }
        }
    }

    nonisolated static func words(_ error: Error) -> String {
        (error as? ServiceError)?.description ?? "check your connection and try again."
    }

    // MARK: Meeting people

    private static var meetingsSent: [UUID: Date] = [:]

    /// Each handed-over account's meeting people (last 60 / next 30 days), once a day and when the helper appears.
    /// Accounts not handed over send nothing; an account without meetings sends nothing (its list stays as it was).
    static func syncMeetingPeople() {
        let session = MailHelperSession.shared
        guard session.installed, let state = session.state, state.lab.paired else { return }
        let now = Date()
        let directory = AccountDirectory.current()
        let own = Set(directory.accounts.map { $0.email.lowercased() })
        for a in directory.accounts {
            guard let lab = state.account(a.id), lab.hasSignIn,
                  MailHelperMeetings.due(last: meetingsSent[a.id], now: now, calendar: .current) else { continue }
            let events = (try? Services.calendar.events(from: now.addingTimeInterval(-MailHelperMeetings.back),
                                                         to: now.addingTimeInterval(MailHelperMeetings.ahead), accounts: [a.id])) ?? []
            let addresses = MailHelperMeetings.addresses(events, account: a.id, own: own, now: now)
            guard !addresses.isEmpty else { continue }
            meetingsSent[a.id] = now
            session.send(.people(.meeting, addresses: addresses, account: a.id, limit: MailHelperMeetings.cap))
        }
    }
}

/// The ping's selector target (DistributedNotificationCenter's `.deliverImmediately` needs the selector API).
private final class MailHelperPingTarget: NSObject {
    @objc func changed(_ note: Notification) {
        DispatchQueue.main.async { MainActor.assumeIsolated { MailHelperLive.pinged() } }
    }
}
