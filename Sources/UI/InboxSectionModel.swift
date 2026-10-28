import Combine
import Foundation

/// One thread's messages for the reader pane and the Mail Peek: oldest first, the latest expanded,
/// remote images decided per message (MailContentPolicy).
final class ThreadReaderModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed }

    let thread: MailThread
    @Published private(set) var messages: [MailMessage] = []
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var expanded: Set<String> = []
    /// "Load images" this session (message ids).
    @Published private(set) var loadedOnce: Set<String> = []
    /// "Always for this sender" this session (also saved in preferences).
    @Published private(set) var allowedNow: Set<String> = []
    @Published var problem: String?
    /// The link under the pointer in any open message (the reader shows its real destination, D-040).
    @Published var hoveredLink: URL?

    private let store: () -> MailStore
    private let prefs: () -> MailPreferencesStore
    private let local: MailLocalStore
    /// The data layer blocks remote images inside the HTML it hands over, so "Load images" has to
    /// re-fetch the thread unblocked. The app installs `DataServices.messages(threadR:loadImages:)` here
    /// at launch (MailIntegration.swift); renders and tests leave it nil.
    static var imageFetcher: ((String) async throws -> [MailMessage])?
    var fetchWithImages: ((String) async throws -> [MailMessage])? = ThreadReaderModel.imageFetcher

    init(thread: MailThread, store: @escaping () -> MailStore = { Services.mail },
         prefs: @escaping () -> MailPreferencesStore = { Services.mailPreferences },
         local: MailLocalStore = DefaultsMailLocalStore.shared) {
        self.thread = thread
        self.store = store
        self.prefs = prefs
        self.local = local
    }

    /// Renders and tests: messages already in hand.
    convenience init(thread: MailThread, messages: [MailMessage], prefs: @escaping () -> MailPreferencesStore = { Services.mailPreferences },
                     local: MailLocalStore = MemoryMailLocalStore()) {
        self.init(thread: thread, prefs: prefs, local: local)
        fetchWithImages = nil
        apply(messages)
    }

    @MainActor
    func load() async {
        phase = .loading
        do {
            apply(try await store().messages(threadR: thread.r))
        } catch {
            phase = .failed
        }
    }

    private func apply(_ list: [MailMessage]) {
        messages = list.sorted { $0.date < $1.date }
        expanded = Set(messages.last.map { [$0.id] } ?? [])
        phase = .ready
    }

    var latest: MailMessage? { messages.last }
    var older: [MailMessage] { Array(messages.dropLast()) }

    func isExpanded(_ m: MailMessage) -> Bool { expanded.contains(m.id) }

    func toggle(_ m: MailMessage) {
        guard m.id != messages.last?.id else { return }   // the latest always stays open
        if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) }
    }

    func expandAll() { expanded = Set(messages.map(\.id)) }

    func decision(for m: MailMessage) -> MailContentPolicy.Decision {
        let sender = m.fromEmail.lowercased()
        let allowed = allowedNow.contains(sender) || prefs().allowsImages(from: sender, accountId: thread.accountId)
        return MailContentPolicy.decide(m, senderAllowed: allowed, loadedOnce: loadedOnce.contains(m.id))
    }

    /// "Load images": this message, this time only.
    func loadImages(_ m: MailMessage) {
        loadedOnce.insert(m.id)
        guard let fetch = fetchWithImages else { return }
        let r = thread.r
        Task { @MainActor in
            if let list = try? await fetch(r) { self.replaceKeepingState(list) }
        }
    }

    /// Re-applies fetched messages without collapsing what the user expanded.
    @MainActor
    private func replaceKeepingState(_ list: [MailMessage]) {
        let open = expanded
        messages = list.sorted { $0.date < $1.date }
        expanded = open.union(Set(messages.last.map { [$0.id] } ?? []))
    }

    /// "Always for this sender": saved to the allow list (Settings can remove it).
    func alwaysAllow(_ m: MailMessage) {
        let sender = m.fromEmail.lowercased()
        do {
            try MailImageSenders.allow(sender, prefs: prefs(), local: local)
            allowedNow.insert(sender)
            // The sender is allowed now, so a normal fetch comes back with images.
            Task { @MainActor in
                if let list = try? await self.store().messages(threadR: self.thread.r) { self.replaceKeepingState(list) }
            }
        } catch {
            loadedOnce.insert(m.id)
            problem = "I loaded them this time, but couldn\u{2019}t remember that sender. Try again in Settings."
        }
    }
}

/// The Inbox section: Unified Inbox, one mailbox per account, Starred; a 360 pt thread list driven by
/// Gmail's keys; the reader pane; undo toasts for every action.
final class InboxSectionModel: ObservableObject {
    enum Mailbox: Hashable { case unified, account(UUID), starred }
    enum Phase: Equatable { case loading, ready, noAccounts, failed }

    static let limit = 150

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var mailbox: Mailbox = .unified
    @Published private(set) var threads: [MailThread] = []
    @Published private(set) var accounts: [DirectoryAccount] = []
    @Published private(set) var unread: [Mailbox: Int] = [:]
    @Published private(set) var starredCount = 0
    @Published private(set) var selection: String?
    @Published private(set) var reader: ThreadReaderModel?
    @Published private(set) var now: Date
    let toasts: MailToastCenter

    private let store: () -> MailStore
    private let actions: () -> MailActions
    private let prefs: () -> MailPreferencesStore
    private let directory: () -> AccountDirectory
    private let clock: () -> Date
    private let undoBook: MailUndoBook
    private let local: MailLocalStore
    /// Opens a composer window (the app) or records the request (tests).
    var compose: (ComposerRequest) -> Void

    init(store: @escaping () -> MailStore = { Services.mail },
         actions: @escaping () -> MailActions = { Services.mailActions },
         prefs: @escaping () -> MailPreferencesStore = { Services.mailPreferences },
         directory: @escaping () -> AccountDirectory = { AccountDirectory.current() },
         clock: @escaping () -> Date = { Date() },
         undoBook: MailUndoBook = .shared,
         local: MailLocalStore = DefaultsMailLocalStore.shared,
         toasts: MailToastCenter? = nil,
         compose: @escaping (ComposerRequest) -> Void = { _ in }) {
        self.store = store
        self.actions = actions
        self.prefs = prefs
        self.directory = directory
        self.clock = clock
        self.undoBook = undoBook
        self.local = local
        self.toasts = toasts ?? MailToastCenter(clock: clock)
        self.compose = compose
        now = clock()
    }

    var directoryNow: AccountDirectory { AccountDirectory(accounts: accounts) }
    var selectedThread: MailThread? { selection.flatMap { r in threads.first { $0.r == r } } }
    var mailboxAccount: UUID? { if case .account(let id) = mailbox { return id } else { return nil } }

    var title: String {
        switch mailbox {
        case .unified: return "Unified Inbox"
        case .starred: return "Starred"
        case .account(let id): return accounts.first { $0.id == id }?.name ?? "Inbox"
        }
    }

    var subtitle: String {
        let n = unread[mailbox] ?? 0
        switch mailbox {
        case .starred:
            return starredCount == 1 ? "1 starred conversation" : "\(starredCount) starred conversations"
        case .unified:
            let across = accounts.count == 1 ? "1 account" : "\(accounts.count) accounts"
            return n == 0 ? "All read across \(across)" : "\(n) unread across \(across)"
        case .account:
            return n == 0 ? "All read" : "\(n) unread"
        }
    }

    /// Empty mailbox, in the persona voice.
    var emptyNote: (title: String, line: String) {
        switch mailbox {
        case .unified:
            let n = accounts.count
            return ("Nothing waiting", "Inbox zero across \(n == 1 ? "1 account" : "\(n) accounts"). Screenshot it.")
        case .account(let id):
            let tag = accounts.first { $0.id == id }?.tag ?? "this inbox"
            return ("Nothing new in \(tag)", "Enjoy the quiet while it lasts.")
        case .starred:
            return ("Nothing starred yet", "Press S on anything worth keeping close.")
        }
    }

    // MARK: Loading

    func load() {
        now = clock()
        accounts = directory().accounts.filter(\.mailEnabled)
        guard !accounts.isEmpty else {
            threads = []
            selection = nil
            reader = nil
            phase = .noAccounts
            return
        }
        if let id = mailboxAccount, !accounts.contains(where: { $0.id == id }) { mailbox = .unified }
        do {
            let s = store()
            var counts: [Mailbox: Int] = [.unified: try s.unreadCount(accounts: nil)]
            for a in accounts { counts[.account(a.id)] = try s.unreadCount(accounts: [a.id]) }
            unread = counts
            let inbox = try s.threads(accounts: nil, limit: Self.limit)
            starredCount = inbox.filter(\.starred).count
            switch mailbox {
            case .unified: threads = inbox
            case .starred: threads = inbox.filter(\.starred)
            case .account(let id): threads = try s.threads(accounts: [id], limit: Self.limit)
            }
            phase = .ready
            if let selection, !threads.contains(where: { $0.r == selection }) {
                self.selection = nil
                reader = nil
            }
        } catch {
            threads = []
            phase = .failed
        }
    }

    func select(mailbox: Mailbox) {
        guard mailbox != self.mailbox else { return }
        self.mailbox = mailbox
        selection = nil
        reader = nil
        load()
    }

    /// Opens a thread in the reader and marks it read (Gmail does the same on open).
    @MainActor
    func select(r: String) async {
        guard let thread = threads.first(where: { $0.r == r }) else { return }
        if selection == r, reader != nil { return }
        selection = r
        let reader = ThreadReaderModel(thread: thread, store: store, prefs: prefs, local: local)
        self.reader = reader
        if thread.unread { await setUnread(r, false, toast: false) }
        await reader.load()
    }

    // MARK: Keyboard + toolbar

    @MainActor
    func perform(_ command: InboxCommand) async {
        switch command {
        case .next: await move(1)
        case .previous: await move(-1)
        case .open:
            if let r = selection ?? threads.first?.r { await select(r: r) }
        case .archive: if let r = selection { await archive(r) }
        case .trash: if let r = selection { await trash(r) }
        case .toggleUnread: if let t = selectedThread { await setUnread(t.r, !t.unread, toast: true) }
        case .toggleStar: if let t = selectedThread { await setStarred(t.r, !t.starred) }
        case .reply: reply(all: false)
        case .forward: forward()
        }
    }

    @MainActor
    private func move(_ step: Int) async {
        guard !threads.isEmpty else { return }
        let index = selection.flatMap { r in threads.firstIndex { $0.r == r } }
        let next = index.map { min(max($0 + step, 0), threads.count - 1) } ?? 0
        await select(r: threads[next].r)
    }

    /// After a thread leaves the list: the one below it, else the one above.
    private func neighbour(of r: String) -> String? {
        guard let i = threads.firstIndex(where: { $0.r == r }) else { return nil }
        if i + 1 < threads.count { return threads[i + 1].r }
        return i > 0 ? threads[i - 1].r : nil
    }

    @MainActor
    func archive(_ r: String) async { await remove(r, kind: .archive) }

    @MainActor
    func trash(_ r: String) async { await remove(r, kind: .trash) }

    @MainActor
    private func remove(_ r: String, kind: MailUndoBook.Kind) async {
        guard let index = threads.firstIndex(where: { $0.r == r }) else { return }
        let thread = threads[index]
        let next = neighbour(of: r)
        let wasSelected = selection == r
        let previousReader = reader
        threads.remove(at: index)
        if wasSelected {
            selection = nil
            reader = nil
        }
        do {
            let token = kind == .archive ? try await actions().archive(r: r) : try await actions().trash(r: r)
            undoBook.record(r: r, token: token, kind: kind, at: clock())
            adjustCounts(thread, removed: true)
            toasts.show(kind == .archive ? "Archived" : "Moved to Trash") { [weak self] in await self?.undo(r: r, thread: thread) }
            Trace.app("inbox-\(kind.rawValue)", ["result": "ok"])
        } catch {
            threads.insert(thread, at: min(index, threads.count))
            if wasSelected, selection == nil {
                selection = r
                reader = previousReader
            }
            toasts.error(kind == .archive ? "I couldn\u{2019}t archive that. Check your connection and try again."
                                          : "I couldn\u{2019}t move that to Trash. Check your connection and try again.")
            Trace.app("inbox-\(kind.rawValue)", ["result": "error"])
            return
        }
        if let next, selection == nil { await select(r: next) }
    }

    /// Undo an archive/trash (the toast's button): the thread comes back and is selected again.
    @MainActor
    func undo(r: String, thread: MailThread? = nil) async {
        guard let entry = undoBook.take(r: r, now: clock()) else {
            toasts.error("Too late to undo that one.")
            return
        }
        do {
            try await actions().undo(entry.token)
            load()
            if threads.contains(where: { $0.r == r }) {
                selection = nil
                await select(r: r)
            } else if let thread, mailbox == .unified || mailboxAccount == thread.accountId {
                // The store hasn't caught up yet: put it back in place locally.
                threads.append(thread)
                threads.sort { $0.at > $1.at }
            }
        } catch {
            toasts.error("I couldn\u{2019}t undo that. Check your connection and try again.")
        }
    }

    @MainActor
    func setUnread(_ r: String, _ unread: Bool, toast: Bool) async {
        guard let i = threads.firstIndex(where: { $0.r == r }), threads[i].unread != unread else { return }
        threads[i].unread = unread
        let thread = threads[i]
        adjustUnread(thread.accountId, unread ? 1 : -1)
        do {
            try await actions().markRead(r: r, !unread)
            if toast {
                toasts.show(unread ? "Marked unread" : "Marked read") { [weak self] in
                    await self?.setUnread(r, !unread, toast: false)
                }
            }
        } catch {
            if let j = threads.firstIndex(where: { $0.r == r }) { threads[j].unread = !unread }
            adjustUnread(thread.accountId, unread ? -1 : 1)
            if toast { toasts.error("I couldn\u{2019}t change that. Check your connection and try again.") }
        }
    }

    @MainActor
    func setStarred(_ r: String, _ starred: Bool, toast: Bool = true) async {
        guard let i = threads.firstIndex(where: { $0.r == r }), threads[i].starred != starred else { return }
        threads[i].starred = starred
        starredCount += starred ? 1 : -1
        do {
            try await actions().star(r: r, starred)
            if mailbox == .starred, !starred {
                threads.removeAll { $0.r == r }
                if selection == r { selection = nil; reader = nil }
            }
            if toast {
                toasts.show(starred ? "Starred" : "Unstarred") { [weak self] in
                    guard let self else { return }
                    if self.mailbox == .starred, starred == false { self.load() }
                    await self.setStarred(r, !starred, toast: false)
                }
            }
        } catch {
            if let j = threads.firstIndex(where: { $0.r == r }) { threads[j].starred = !starred }
            starredCount += starred ? -1 : 1
            toasts.error("I couldn\u{2019}t change that. Check your connection and try again.")
        }
    }

    // MARK: Compose

    func reply(all: Bool) {
        guard let thread = selectedThread else { return }
        let message = reader?.thread.r == thread.r ? reader?.latest : nil
        compose(.reply(thread, message, all: all))
    }

    /// Forward (F, the reader's Forward capsule): the open thread's latest message, its files re-attached.
    func forward() {
        guard let thread = selectedThread, reader?.thread.r == thread.r, let message = reader?.latest else { return }
        compose(.forward(thread, message))
    }

    func newMessage() { compose(.new(from: mailboxAccount)) }

    // MARK: Counts

    private func adjustCounts(_ thread: MailThread, removed: Bool) {
        if thread.unread { adjustUnread(thread.accountId, removed ? -1 : 1) }
        if thread.starred { starredCount += removed ? -1 : 1 }
    }

    private func adjustUnread(_ account: UUID, _ delta: Int) {
        unread[.unified] = max(0, (unread[.unified] ?? 0) + delta)
        unread[.account(account)] = max(0, (unread[.account(account)] ?? 0) + delta)
    }
}

/// The Mail Peek (`open/message?r&k`): one thread on the paper card, the latest message open, and
/// Reply, Archive, Star, Trash, Mark unread. Opening it marks the thread read.
final class MailPeekModel: ObservableObject {
    @Published private(set) var thread: MailThread
    @Published private(set) var gone: MailUndoBook.Kind?
    let reader: ThreadReaderModel
    let toasts: MailToastCenter
    let directory: AccountDirectory
    var onClose: () -> Void = {}
    var onReply: (ComposerRequest) -> Void = { _ in }

    private let actions: () -> MailActions
    private let clock: () -> Date
    private let undoBook: MailUndoBook
    private var readerChanges: AnyCancellable?

    init(thread: MailThread, directory: AccountDirectory, reader: ThreadReaderModel? = nil,
         actions: @escaping () -> MailActions = { Services.mailActions },
         clock: @escaping () -> Date = { Date() }, undoBook: MailUndoBook = .shared, toasts: MailToastCenter? = nil) {
        self.thread = thread
        self.directory = directory
        self.reader = reader ?? ThreadReaderModel(thread: thread)
        self.actions = actions
        self.clock = clock
        self.undoBook = undoBook
        self.toasts = toasts ?? MailToastCenter(clock: clock)
        // The Peek redraws when its messages arrive.
        readerChanges = self.reader.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var account: DirectoryAccount? { directory.account(thread.accountId) }

    @MainActor
    func open() async {
        if reader.phase != .ready { await reader.load() }
        if thread.unread {
            thread.unread = false
            do { try await actions().markRead(r: thread.r, true) } catch { thread.unread = true }
        }
    }

    func reply(all: Bool = false) {
        onReply(.reply(thread, reader.latest, all: all))
        onClose()
    }

    /// Forward the latest message in a new composer window (its files come along).
    func forward() {
        guard let latest = reader.latest else { return }
        onReply(.forward(thread, latest))
        onClose()
    }

    @MainActor
    func archive() async { await remove(.archive) }

    @MainActor
    func trash() async { await remove(.trash) }

    @MainActor
    private func remove(_ kind: MailUndoBook.Kind) async {
        guard gone == nil else { return }
        do {
            let r = thread.r
            let token = kind == .archive ? try await actions().archive(r: r) : try await actions().trash(r: r)
            undoBook.record(r: r, token: token, kind: kind, at: clock())
            gone = kind
            toasts.show(kind == .archive ? "Archived" : "Moved to Trash") { [weak self] in await self?.undo() }
        } catch {
            toasts.error(kind == .archive ? "I couldn\u{2019}t archive that. Check your connection and try again."
                                          : "I couldn\u{2019}t move that to Trash. Check your connection and try again.")
        }
    }

    @MainActor
    func undo() async {
        guard let entry = undoBook.take(r: thread.r, now: clock()) else { return }
        do {
            try await actions().undo(entry.token)
            gone = nil
        } catch {
            toasts.error("I couldn\u{2019}t undo that. Check your connection and try again.")
        }
    }

    @MainActor
    func toggleStar() async {
        let starred = !thread.starred
        thread.starred = starred
        do { try await actions().star(r: thread.r, starred) } catch {
            thread.starred = !starred
            toasts.error("I couldn\u{2019}t change that. Check your connection and try again.")
        }
    }

    @MainActor
    func markUnread() async {
        do {
            try await actions().markRead(r: thread.r, false)
            thread.unread = true
            toasts.show("Marked unread") { [weak self] in
                guard let self else { return }
                try? await self.actions().markRead(r: self.thread.r, true)
                self.thread.unread = false
            }
        } catch {
            toasts.error("I couldn\u{2019}t change that. Check your connection and try again.")
        }
    }
}
