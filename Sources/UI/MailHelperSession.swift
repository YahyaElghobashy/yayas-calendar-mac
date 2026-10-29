import Combine
import Foundation

// Yaya's Mail Helper on the app's surfaces (D-050): the session (the helper's files, its commands and answers), the
// Mail helper page's model (accounts, the hand-over card, the backlog, Review, suggestions, activity, VIPs, Needs reply,
// your voice, the digest) and the composer's "Draft with AI". Free of AppKit: the live pieces come in through
// `MailHelperSession.Environment` (MailHelperLive.swift) and `MailHelperModel.Live`.

// MARK: - The session

/// One shared instance in the app (its live side is `MailHelperLive`); renders and tests make their own with fakes.
@MainActor
final class MailHelperSession: ObservableObject {
    static var shared = MailHelperSession(publishesInbox: true)

    struct Environment {
        var installed: () -> Bool = { false }
        /// The helper's files as last read (the live side re-reads a file when it changed).
        var state: () -> MailHelperRead<MailHelperState> = { .missing }
        var digest: () -> MailHelperRead<MailHelperDigest?> = { .missing }
        /// Writes the command file (0600, atomically) in the calendar's own folder; false = not written.
        var write: (UUID, Data) -> Bool = { _, _ in false }
        var open: (URL) -> Bool = { _ in false }
        /// The helper's answer to a command, read and then deleted; nil = not there yet.
        var answer: (UUID) -> MailHelperResult? = { _ in nil }
        var clock: () -> Date = { Date() }
        var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { _, _ in }
    }

    /// No answer after this long: most commands. The writer may take up to 5 minutes (its own timeout).
    static let answerTimeout: TimeInterval = 120
    static let draftTimeout: TimeInterval = 330
    static let pollEvery: TimeInterval = 1.5

    @Published private(set) var installed = false
    @Published private(set) var stateRead: MailHelperRead<MailHelperState> = .missing
    @Published private(set) var digestRead: MailHelperRead<MailHelperDigest?> = .missing
    /// Commands sent and not answered yet.
    @Published private(set) var waiting: Set<UUID> = []
    var env: Environment

    private struct Pending {
        let kind: String
        let deadline: Date
        let done: (@MainActor (MailHelperResult) -> Void)?
    }
    private var pending: [UUID: Pending] = [:]
    private var polling = false
    /// Only the app's own session sets the inbox's labels (renders and tests keep theirs to themselves).
    private let publishesInbox: Bool

    init(env: Environment = Environment(), publishesInbox: Bool = false) {
        self.env = env
        self.publishesInbox = publishesInbox
    }

    var state: MailHelperState? { installed ? stateRead.value : nil }
    var digest: MailHelperDigest? { installed ? (digestRead.value ?? nil) : nil }

    /// Reads presence and the files again (surfaces call it when they load; the live side after a ping), then any
    /// answers that arrived.
    func refresh() {
        let now = env.installed()
        if now != installed { installed = now }
        let s: MailHelperRead<MailHelperState> = now ? env.state() : .missing
        if s != stateRead { stateRead = s }
        let d: MailHelperRead<MailHelperDigest?> = now ? env.digest() : .missing
        if d != digestRead { digestRead = d }
        publishInbox()
        collect()
    }

    /// The inbox's Priority-first order follows the helper's labels (nothing while it isn't installed or has none).
    private func publishInbox() {
        guard publishesInbox else { return }
        let next = installed ? MailHelperInboxLabels(stateRead.value) : nil
        guard next != MailHelperInbox.current.get() else { return }
        MailHelperInbox.current.set(next)
        NotificationCenter.default.post(name: MailHelperInbox.changed, object: nil)
    }

    // MARK: Commands

    static let notInstalled = "Yaya\u{2019}s Mail Helper isn\u{2019}t on this Mac."

    /// Writes the command file and opens the helper's link; `done` hears the answer (or why there won't be one).
    @discardableResult
    func send(_ command: MailHelperCommand?, timeout: TimeInterval = MailHelperSession.answerTimeout,
              done: (@MainActor (MailHelperResult) -> Void)? = nil) -> Bool {
        guard let command else {
            done?(.failure(UUID(), "That isn\u{2019}t something I can ask the helper for."))
            return false
        }
        guard installed else {
            trace(command.kind, "not-installed")
            done?(.failure(command.id, Self.notInstalled))
            return false
        }
        guard let data = command.encoded() else {
            trace(command.kind, "too-large")
            done?(.failure(command.id, "That request is too large for the helper."))
            return false
        }
        guard env.write(command.id, data) else {
            trace(command.kind, "write-failed")
            done?(.failure(command.id, "I couldn\u{2019}t write the request for Yaya\u{2019}s Mail Helper."))
            return false
        }
        guard let link = MailHelperLinks.command(command.id), env.open(link) else {
            trace(command.kind, "link-failed")
            done?(.failure(command.id, "I couldn\u{2019}t reach Yaya\u{2019}s Mail Helper. Is it still installed?"))
            return false
        }
        pending[command.id] = Pending(kind: command.kind, deadline: env.clock().addingTimeInterval(timeout), done: done)
        waiting.insert(command.id)
        trace(command.kind, "sent")
        collect()
        poll()
        return true
    }

    /// `send`, awaited.
    func run(_ command: MailHelperCommand?, timeout: TimeInterval = MailHelperSession.answerTimeout) async -> MailHelperResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<MailHelperResult, Never>) in
            send(command, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// Stops waiting for a command (its answer, if it comes, is read and dropped).
    func stopWaiting(_ id: UUID) {
        guard let p = pending[id] else { return }
        pending[id] = Pending(kind: p.kind, deadline: p.deadline, done: nil)
    }

    /// The link to a command didn't open: that command ends now.
    func linkFailed(_ url: URL) {
        let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }
        guard let id = item?.value.flatMap(UUID.init(uuidString:)) else { return }
        finish(id, .failure(id, "I couldn\u{2019}t reach Yaya\u{2019}s Mail Helper. Is it still installed?"))
    }

    /// Reads the answers that arrived; a command past its time gets "no answer".
    func collect() {
        guard !pending.isEmpty else { return }
        let now = env.clock()
        for (id, p) in pending {
            if let answer = env.answer(id) {
                finish(id, answer)
            } else if now >= p.deadline {
                finish(id, .failure(id, "No answer from Yaya\u{2019}s Mail Helper. Is it running?"))
            }
        }
    }

    private func finish(_ id: UUID, _ result: MailHelperResult) {
        guard let p = pending.removeValue(forKey: id) else { return }
        waiting.remove(id)
        trace(p.kind, result.ok ? "ok" : "error")
        p.done?(result)
    }

    /// While anything is waiting, look for answers every 1.5 s too (a ping can be missed).
    private func poll() {
        guard !polling, !pending.isEmpty else { return }
        polling = true
        env.after(Self.pollEvery) { [weak self] in
            guard let self else { return }
            self.polling = false
            self.collect()
            self.poll()
        }
    }

    /// Outcomes only: never an address, a subject or a token.
    private func trace(_ kind: String, _ result: String) {
        Trace.app("mailhelper", ["action": kind, "result": result])
    }

    // MARK: Status

    /// The status line at the top of the page: paired, reachable, last update, error.
    var statusLine: (text: String, tone: MailHelperText.Tone) {
        guard installed else { return (Self.notInstalled, .quiet) }
        switch stateRead {
        case .missing: return ("Installed. Waiting for its first report.", .quiet)
        case .unreadable: return ("Installed, but I can\u{2019}t read its report.", .warn)
        case .newer: return ("Installed, with a newer report than I understand. Update Yaya\u{2019}s Calendar.", .warn)
        case .ready(let s):
            let now = env.clock()
            if !s.lab.paired {
                return ("Not paired with your mail server yet. Pair it in Yaya\u{2019}s Mail Helper\u{2019}s own window.", .warn)
            }
            if !s.lab.reachable {
                let since = s.lab.lastOkAt.map { " Last heard from \(MailHelperText.ago($0, now: now))." } ?? ""
                return ("Your mail server is out of reach.\(since)" + (s.lab.error.map { " \($0)" } ?? ""), .bad)
            }
            let update = s.updatedAt.map { "last update \(MailHelperText.ago($0, now: now))" } ?? "no update yet"
            return ("Paired and reachable \u{00B7} \(update)" + (s.lab.error.map { " \u{00B7} \($0)" } ?? ""), .good)
        }
    }
}

// MARK: - The Mail helper page

/// Rows of Needs reply (contract v1.1, `needs_reply` → `data.threads`).
struct MailHelperNeedsReply: Equatable, Identifiable {
    var account: String
    var threadId: String
    var sender: String
    var subject: String
    var priority: Bool
    var decidedAt: Date?
    var id: String { account + "/" + threadId }

    static func parse(_ data: MailHelperJSON) -> [MailHelperNeedsReply] {
        (data["threads"]?.array ?? []).compactMap { t in
            guard let account = t["account"]?.string, MailHelperIDs.isAccount(account),
                  let thread = t["thread_id"]?.string, MailHelperIDs.isThread(thread) else { return nil }
            return MailHelperNeedsReply(account: account, threadId: thread,
                                        sender: MailHelperPlain.clean(t["sender"]?.string, 254) ?? "",
                                        subject: MailHelperPlain.clean(t["subject"]?.string, 300) ?? "",
                                        priority: (t["priority"]?.int ?? 0) != 0 || t["priority"]?.bool == true,
                                        decidedAt: t["decided_at"]?.date)
        }
    }
}

/// One account's "Your voice" card.
struct MailHelperVoice: Equatable {
    enum Phase: Equatable { case loading, ready, building, saving, failed(String) }
    var phase: Phase = .loading
    var card: String?
    var samples = 0
    /// While editing: the text in the field.
    var draft: String?
    var useClaude: Bool
}

/// A digest section's "read" as this window knows it.
enum MailHelperDigestMark: Equatable {
    case sending, marked, undoing, undone
    case failed(String)
}

/// Why a hand-over couldn't read the sign-in (the live side maps Keychain and store errors to these).
enum MailHelperSignInError: Error, Equatable {
    /// No sign-in for this account on this Mac (reconnect it in Accounts).
    case notConnected
    /// No Google client in the Keychain (Provider Setup).
    case noClient
    /// The Keychain is waiting for a click, or locked.
    case keychainWaiting
    case failed
}

@MainActor
final class MailHelperModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case overview, digest
        var id: String { rawValue }
        var title: String { self == .overview ? "Overview" : "Digest" }
    }

    enum Confirm: Equatable {
        case undoAll(run: String, tag: String)
        case undoToday
        case forget(UUID, tag: String)
    }

    enum Loadable<T: Equatable>: Equatable {
        case idle, loading
        case ready(T)
        case failed(String)
    }

    /// An account as its card draws it: the calendar's account, and what the helper says about it.
    struct Card: Identifiable, Equatable {
        let account: DirectoryAccount
        let lab: MailHelperState.Account?
        let backfill: MailHelperState.Backfill?
        var id: UUID { account.id }
        var handedOver: Bool { (lab?.hasSignIn ?? false) && lab?.state != "disconnected" }
        var state: (text: String, tone: MailHelperText.Tone) { MailHelperText.accountState(lab, handedOver: handedOver) }
    }

    /// The app's pieces (the Keychain, the reader, the composer); renders and tests pass fakes.
    struct Live {
        /// The account's refresh token and the Google client, read off the main thread (the Keychain gate).
        var credentials: (UUID) async throws -> MailHelperSignIn = { _ in throw MailHelperSignInError.notConnected }
        /// Consumer Google domains (the app's own list): their accounts default to "personal".
        var personalDomains: Set<String> = []
        /// Opens a thread in the app's reader (account, Gmail thread id).
        var openThread: (UUID, String) -> Void = { _, _ in }
        /// Opens the reply composer for a thread (account, Gmail thread id).
        var reply: (UUID, String) -> Void = { _, _ in }
    }

    static let vipKey = "mailhelper.vip."
    static let vipDomainKey = "mailhelper.vipDomains."

    let session: MailHelperSession
    let toasts: MailToastCenter
    var live: Live
    private let directory: () -> AccountDirectory
    private let bag: PreferenceBag
    private let clock: () -> Date
    private var changes: AnyCancellable?

    @Published var page: Page = .overview
    @Published private(set) var handover: MailHelperHandover?
    @Published private(set) var handoverBusy = false
    @Published private(set) var handoverProblem: String?
    @Published var confirm: Confirm?
    /// Buttons whose command is on its way ("pause:<account>", "proposal:<id>", …): drawn as busy.
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var vipEditing: UUID?
    @Published var vipPeople = ""
    @Published var vipDomains = ""
    @Published private(set) var needsReply: Loadable<[MailHelperNeedsReply]> = .idle
    @Published private(set) var voices: [UUID: MailHelperVoice] = [:]
    @Published private(set) var marks: [String: MailHelperDigestMark] = [:]
    /// Folded parts the person opened ("voice:<account>", "groups:<run>", "activity", …).
    @Published var expanded: Set<String> = []
    /// Read = done: the page was scrolled by the person, and which section ends are on screen.
    private(set) var digestScrolled = false
    private var endsOnScreen: Set<String> = []

    init(session: MailHelperSession? = nil, directory: @escaping () -> AccountDirectory = { AccountDirectory.current() },
         bag: PreferenceBag = DefaultsBag.shared, live: Live = Live(), clock: @escaping () -> Date = { Date() },
         toasts: MailToastCenter? = nil) {
        let session = session ?? .shared
        self.session = session
        self.directory = directory
        self.bag = bag
        self.live = live
        self.clock = clock
        self.toasts = toasts ?? MailToastCenter(clock: clock)
        // The page redraws when the helper's files change.
        changes = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var installed: Bool { session.installed }
    var state: MailHelperState? { session.state }
    var digest: MailHelperDigest? { session.digest }
    var now: Date { clock() }
    var rootLabel: String { state?.rootLabel ?? "Sorted" }

    var cards: [Card] {
        let s = state
        return directory().accounts.map { a in
            Card(account: a, lab: s?.account(a.id), backfill: s?.backfill(a.id))
        }
    }

    func accountId(_ helperId: String) -> UUID? { UUID(uuidString: helperId) }
    func account(_ helperId: String) -> DirectoryAccount? { accountId(helperId).flatMap { directory().account($0) } }

    /// Sending a command for a button: it shows busy until the answer, then a toast says how it went.
    private func act(_ key: String, _ command: MailHelperCommand?, ok: String? = nil, then: (@MainActor (MailHelperResult) -> Void)? = nil) {
        busy.insert(key)
        session.send(command) { [weak self] result in
            guard let self else { return }
            self.busy.remove(key)
            if result.ok {
                if let ok { self.toasts.show(ok, action: nil, duration: 4) }
            } else {
                self.toasts.error(result.error ?? "That didn\u{2019}t work.")
            }
            then?(result)
        }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }
    func toggle(_ key: String) { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } }

    func refreshNow() { act("refresh", .refresh()) }

    // MARK: Accounts

    func setPaused(_ paused: Bool, _ id: UUID) {
        act("pause:\(id)", .setPaused(paused, account: id), ok: paused ? "Paused. Nothing moves until you resume." : "Sorting again.")
    }

    func setPolicy(_ policy: MailAIPolicy, _ id: UUID) {
        act("policy:\(id)", .setPolicy(policy, account: id), ok: "AI for this account: \(policy.title).")
    }

    func setCredential(_ name: String?, _ id: UUID) {
        act("credential:\(id)", .setCredential(name, account: id), ok: name.map { "Claude credential: \($0)." } ?? "No Claude credential.")
    }

    // MARK: Hand-over (the approval card)

    /// "Hand over sign-in": the card names the account and the server's fingerprint. Nothing is read or sent yet.
    func beginHandover(_ id: UUID) {
        handoverProblem = nil
        guard let s = state, let a = directory().account(id) else { return }
        guard let key = s.sealKey, let fp = s.sealFingerprint else {
            toasts.error("Pair Yaya\u{2019}s Mail Helper with your mail server first.")
            return
        }
        guard fp == MailHelperSeal.fingerprint(key) else {
            toasts.error("The helper\u{2019}s key doesn\u{2019}t match its fingerprint, so I won\u{2019}t hand anything over.")
            return
        }
        handover = MailHelperHandover(account: id, tag: a.tag, name: a.name, email: a.email, fingerprint: fp,
                                      kind: MailHelperHandover.defaultKind(email: a.email, personalDomains: live.personalDomains),
                                      shownAt: clock())
    }

    func setHandoverKind(_ kind: String) {
        guard kind == "personal" || kind == "work" else { return }
        handover?.kind = kind
    }

    func cancelHandover() {
        guard !handoverBusy else { return }
        handover = nil
        handoverProblem = nil
    }

    var handoverArmed: Bool {
        guard let h = handover else { return false }
        return clock().timeIntervalSince(h.shownAt) >= MailHelperHandover.armDelay
    }

    /// Approve: reads the sign-in (off the main thread), seals it for the server's key and sends it. The refresh token
    /// exists only inside the sealed envelope in the command file (0600, deleted by the helper).
    func approveHandover() async {
        guard let h = handover, handoverArmed, !handoverBusy else { return }
        guard let s = state else { handoverProblem = MailHelperSession.notInstalled; return }
        handoverBusy = true
        handoverProblem = nil
        defer { handoverBusy = false }
        let envelope: [String: MailHelperJSON]
        do {
            let signIn = try await live.credentials(h.account)
            envelope = try MailHelperSeal.gmail(signIn, account: h.account, state: s)
        } catch let e as MailHelperSignInError {
            handoverProblem = Self.words(e)
            return
        } catch MailHelperSealError.fingerprintMismatch {
            handoverProblem = "The helper\u{2019}s key changed while this card was open. Nothing was handed over."
            return
        } catch {
            handoverProblem = "I couldn\u{2019}t seal the sign-in. Nothing was handed over."
            return
        }
        let result = await session.run(.handover(account: h.account, kind: h.kind, envelope: envelope))
        if result.ok {
            handover = nil
            toasts.show("Handed over. Your mail server takes a first look; nothing moves until you approve its plan.",
                        action: nil, duration: 6)
        } else {
            handoverProblem = result.error ?? "The helper couldn\u{2019}t take the sign-in."
        }
    }

    static func words(_ e: MailHelperSignInError) -> String {
        switch e {
        case .notConnected: return "This Mac has no sign-in for that account. Reconnect it in Accounts, then try again."
        case .noClient: return "Your Google client isn\u{2019}t set up on this Mac (Accounts \u{2192} Google setup)."
        case .keychainWaiting: return "Waiting for Keychain access. Allow it, then try again."
        case .failed: return "I couldn\u{2019}t read the sign-in. Nothing was handed over."
        }
    }

    func askForget(_ id: UUID) {
        confirm = .forget(id, tag: directory().account(id)?.tag ?? "this account")
    }

    // MARK: Backlog

    func backfillStart(_ id: UUID) { act("backfill-start:\(id)", .backfillStart(account: id), ok: "Dry run started. Nothing in Gmail changes.") }
    func backfillApply(_ run: String) { act("apply:\(run)", .backfill(.apply, run: run), ok: "Moving mail in batches. You can stop at any time.") }
    func backfillStop(_ run: String) { act("stop:\(run)", .backfill(.stop, run: run), ok: "Stopping after this batch.") }

    func askUndoAll(_ run: String, tag: String) { confirm = .undoAll(run: run, tag: tag) }

    func move(run: String, sender: String, to category: MailCategory) {
        act("move:\(run):\(sender)", .backfillOverride(run: run, sender: sender, category: category),
            ok: "\(sender) \u{2192} \(category.title). The plan is updated.")
    }

    // MARK: Review, suggestions, activity

    func review(_ t: MailHelperState.ReviewThread, as category: MailCategory, onlyThisThread: Bool = false) {
        act("review:\(t.id)", .review(account: t.account, thread: t.threadId, category: category, onlyThisThread: onlyThisThread),
            ok: onlyThisThread ? "Moved to \(category.title)." : "Moved to \(category.title). Their next emails follow.")
    }

    func decide(_ p: MailHelperState.Proposal, accept: Bool) {
        act("proposal:\(p.id)", .proposal(p.id, accept: accept))
    }

    func undo(_ a: MailHelperState.Action) {
        act("undo:\(a.id)", .undo(actions: [a.id]), ok: "Undone.")
    }

    func askUndoToday() { confirm = .undoToday }

    /// Local midnight today (the clock's calendar).
    func startOfToday(_ calendar: Calendar = WidgetCalendar.current) -> Date { calendar.startOfDay(for: clock()) }

    /// The confirmation's "yes".
    func confirmed() {
        guard let c = confirm else { return }
        confirm = nil
        switch c {
        case .undoAll(let run, _):
            act("undo-all:\(run)", .backfill(.undo, run: run), ok: "Undoing: every conversation goes back where it was.")
        case .undoToday:
            act("undo-today", .undo(since: startOfToday()), ok: "Undoing everything sorted today.")
        case .forget(let id, _):
            act("forget:\(id)", .forget(account: id), ok: "Taken back: your mail server forgot this sign-in.")
        }
    }

    // MARK: VIPs (the whole list is sent each time; this Mac keeps the copy the helper was given)

    func vips(_ id: UUID) -> (people: [String], domains: [String]) {
        ((bag.object(Self.vipKey + id.uuidString) as? [String]) ?? [], (bag.object(Self.vipDomainKey + id.uuidString) as? [String]) ?? [])
    }

    func editVIPs(_ id: UUID) {
        let v = vips(id)
        vipPeople = v.people.joined(separator: "\n")
        vipDomains = v.domains.joined(separator: "\n")
        vipEditing = id
    }

    func cancelVIPs() { vipEditing = nil }

    /// Sends both lists; this Mac remembers them once the helper took them.
    func saveVIPs() {
        guard let id = vipEditing else { return }
        let people = MailHelperPeople.split(vipPeople).filter(MailHelperPeople.isAddress)
        let domains = MailHelperPeople.split(vipDomains).filter(MailHelperPeople.isDomain)
        vipEditing = nil
        act("vip:\(id)", .people(.vip, addresses: people, account: id, limit: 5000)) { [weak self] r in
            guard let self, r.ok else { return }
            self.bag.set(Array(Set(people)).sorted(), Self.vipKey + id.uuidString)
            self.act("vip-domains:\(id)", .people(.vipDomain, addresses: domains, account: id, limit: 5000), ok: "VIPs saved.") { r in
                guard r.ok else { return }
                self.bag.set(Array(Set(domains)).sorted(), Self.vipDomainKey + id.uuidString)
            }
        }
    }

    // MARK: Needs reply

    func loadNeedsReply() {
        guard installed, needsReply != .loading else { return }
        needsReply = .loading
        session.send(.needsReply()) { [weak self] r in
            guard let self else { return }
            self.needsReply = r.ok ? .ready(MailHelperNeedsReply.parse(r.data)) : .failed(r.error ?? "The list didn\u{2019}t come.")
        }
    }

    func reply(_ row: MailHelperNeedsReply) {
        guard let id = accountId(row.account) else { return }
        live.reply(id, row.threadId)
    }

    // MARK: Your voice

    func voice(_ id: UUID) -> MailHelperVoice? { voices[id] }

    /// Claude for the style card: on for personal accounts, off for work (the helper's kind, else the address).
    func defaultUseClaude(_ id: UUID) -> Bool {
        if let kind = state?.account(id)?.kind { return kind == "personal" }
        let email = directory().account(id)?.email ?? ""
        return MailHelperHandover.defaultKind(email: email, personalDomains: live.personalDomains) == "personal"
    }

    func loadVoice(_ id: UUID) {
        var v = voices[id] ?? MailHelperVoice(useClaude: defaultUseClaude(id))
        v.phase = .loading
        voices[id] = v
        session.send(.voiceGet(account: id)) { [weak self] r in
            guard let self, var v = self.voices[id] else { return }
            if r.ok {
                v.card = MailHelperVoice.clean(r.data["card"]?.string)
                v.samples = max(0, r.data["samples"]?.int ?? 0)
                v.phase = .ready
            } else {
                v.phase = .failed(r.error ?? "The style card didn\u{2019}t come.")
            }
            self.voices[id] = v
        }
    }

    func editVoice(_ id: UUID) {
        guard var v = voices[id] else { return }
        v.draft = v.card ?? ""
        voices[id] = v
    }

    func setVoiceDraft(_ text: String, _ id: UUID) {
        guard var v = voices[id] else { return }
        v.draft = String(text.prefix(MailHelperCommand.voiceCardLimit))
        voices[id] = v
    }

    func cancelVoiceEdit(_ id: UUID) {
        guard var v = voices[id] else { return }
        v.draft = nil
        voices[id] = v
    }

    func saveVoice(_ id: UUID) {
        guard var v = voices[id], let text = v.draft else { return }
        v.phase = .saving
        voices[id] = v
        session.send(.voicePut(account: id, card: text)) { [weak self] r in
            guard let self, var v = self.voices[id] else { return }
            if r.ok {
                v.card = text
                v.draft = nil
                v.phase = .ready
                self.toasts.show("Style card saved.", action: nil, duration: 4)
            } else {
                v.phase = .failed(r.error ?? "It didn\u{2019}t save.")
            }
            self.voices[id] = v
        }
    }

    func setVoiceUsesClaude(_ on: Bool, _ id: UUID) {
        var v = voices[id] ?? MailHelperVoice(phase: .ready, useClaude: on)
        v.useClaude = on
        voices[id] = v
    }

    func buildVoice(_ id: UUID) {
        var v = voices[id] ?? MailHelperVoice(phase: .ready, useClaude: defaultUseClaude(id))
        let useClaude = v.useClaude
        v.phase = .building
        voices[id] = v
        session.send(.voiceBuild(account: id, useClaude: useClaude)) { [weak self] r in
            guard let self, var v = self.voices[id] else { return }
            if r.ok {
                self.toasts.show("Building your style card from your sent mail. It takes a few minutes; check again then.",
                                 action: nil, duration: 6)
            } else {
                v.phase = .failed(r.error ?? "It didn\u{2019}t start.")
                self.voices[id] = v
            }
        }
    }

    // MARK: Digest

    func open(_ ref: MailHelperDigest.ThreadRef) {
        guard let id = accountId(ref.account) else { return }
        live.openThread(id, ref.threadId)
    }

    func open(account: String, thread: String) { open(MailHelperDigest.ThreadRef(account: account, threadId: thread)) }

    func buildDigest() { act("digest-build", .digestBuild(), ok: "Building today\u{2019}s digest. It appears here when it\u{2019}s ready.") }

    /// What a section shows: this window's own mark, else the helper's "read".
    func mark(_ section: String) -> MailHelperDigestMark? {
        if let m = marks[section] { return m }
        return digest?.read[section] == true ? .marked : nil
    }

    /// "Mark section read" (and "Mark all read" with nil): the helper marks those emails read in Gmail.
    func markRead(_ section: String?) {
        guard let d = digest else { return }
        let key = section ?? "all"
        if let m = marks[key], m == .sending || m == .marked { return }
        marks[key] = .sending
        if section == nil { for s in d.sections where mark(s.key) == nil { marks[s.key] = .sending } }
        session.send(.digestRead(d.id, section: section)) { [weak self] r in
            guard let self else { return }
            let next: MailHelperDigestMark = r.ok ? .marked : .failed(r.error ?? "Couldn\u{2019}t mark them read.")
            self.marks[key] = next
            if section == nil { for s in d.sections where self.marks[s.key] == .sending { self.marks[s.key] = next } }
        }
    }

    /// "Marked read · Undo": the same emails unread again (the helper's own batch for that read).
    func undoRead(_ section: String?) {
        guard let d = digest else { return }
        let key = section ?? "all"
        marks[key] = .undoing
        session.send(.undo(batch: d.batch(section))) { [weak self] r in
            guard let self else { return }
            self.marks[key] = r.ok ? .undone : .failed(r.error ?? "Couldn\u{2019}t undo that.")
        }
    }

    /// The page moved under the person's hand: every section whose end is on screen counts as read.
    func digestDidScroll() {
        guard !digestScrolled else { return }
        digestScrolled = true
        for key in endsOnScreen.sorted() { autoMark(key) }
    }

    /// A section's end came on screen (or left it).
    func sectionEnd(_ key: String, visible: Bool) {
        if visible { endsOnScreen.insert(key) } else { endsOnScreen.remove(key) }
        if visible, digestScrolled { autoMark(key) }
    }

    private func autoMark(_ key: String) {
        guard mark(key) == nil, digest?.sections.contains(where: { $0.key == key }) == true else { return }
        markRead(key)
    }
}

// MARK: - Voice text

extension MailHelperVoice {
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !(($0.properties.generalCategory == .control) || $0.properties.generalCategory == .format) }
        let s = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(MailHelperCommand.voiceCardLimit))
    }
}

// MARK: - The composer's "Draft with AI"

/// The writer (contract v1.1): a draft of a reply in the owner's voice, from the model and thinking level picked here
/// (remembered per account). It never sends: the text lands in the composer, and Send still goes through the usual
/// path and its approval card.
@MainActor
final class MailHelperDraftModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(since: Date)
        case failed(String)
    }

    static func modelKey(_ id: UUID) -> String { "mailhelper.draft.model." + id.uuidString }
    static func effortKey(_ id: UUID) -> String { "mailhelper.draft.effort." + id.uuidString }
    /// The longest draft the composer takes.
    static let textLimit = 20_000

    let account: UUID
    let threadR: String
    let session: MailHelperSession
    @Published var open = false
    @Published var instruction = ""
    @Published var model: MailDraftModel
    @Published var effort: MailDraftEffort
    @Published private(set) var phase: Phase = .idle
    /// The composer's insertion (the body setter, or at the cursor when there's text already).
    var insert: @MainActor (String) -> Void
    private let threadId: (String) -> String?
    private let bag: PreferenceBag
    private let clock: () -> Date
    private var generation = 0
    private var sent: UUID?
    private var changes: AnyCancellable?

    /// Row id → Gmail thread id (the app installs the data layer's lookup at launch; renders and tests pass their own).
    nonisolated(unsafe) static var threadIdLookup: (String) -> String? = { _ in nil }

    /// The composer's button: only for a reply, only while the helper is installed.
    static func make(for request: ComposerRequest, composer: ComposerModel, session: MailHelperSession? = nil) -> MailHelperDraftModel? {
        let session = session ?? .shared
        guard session.installed, request.kind == .reply || request.kind == .replyAll, let thread = request.thread else { return nil }
        return MailHelperDraftModel(account: thread.accountId, threadR: thread.r, session: session,
                                    insert: { [weak composer] text in composer?.insertDraft(text) })
    }

    init(account: UUID, threadR: String, session: MailHelperSession? = nil,
         threadId: @escaping (String) -> String? = { MailHelperDraftModel.threadIdLookup($0) },
         bag: PreferenceBag = DefaultsBag.shared, clock: @escaping () -> Date = { Date() }, insert: @escaping @MainActor (String) -> Void = { _ in }) {
        self.account = account
        self.threadR = threadR
        let session = session ?? .shared
        self.session = session
        self.threadId = threadId
        self.bag = bag
        self.clock = clock
        self.insert = insert
        model = (bag.object(Self.modelKey(account)) as? String).flatMap(MailDraftModel.init) ?? .local
        effort = (bag.object(Self.effortKey(account)) as? String).flatMap(MailDraftEffort.init) ?? .low
        changes = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isWorking: Bool { if case .working = phase { return true } else { return false } }
    var isFailed: Bool { if case .failed = phase { return true } else { return false } }
    /// The model's clock (the pop-over's "Writing… 1 min 35 s" ticks against it).
    var now: Date { clock() }

    /// A word before the person asks: the account isn't with the helper yet, or Claude is off for it.
    var note: String? {
        guard let s = session.state else { return MailHelperSession.notInstalled }
        guard let a = s.account(account), a.hasSignIn else {
            return "This account isn\u{2019}t handed over to your mail server yet (Mail helper \u{2192} Hand over sign-in)."
        }
        if model.usesClaude, a.aiPolicy != .localClaude || a.claudeCredential == nil {
            return "Claude is off for this account, so the helper will say no. Pick Local, or turn Claude on in Mail helper."
        }
        return nil
    }

    func elapsed(_ now: Date) -> String {
        guard case .working(let since) = phase else { return "" }
        let s = Int(max(0, now.timeIntervalSince(since)))
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }

    func draft() {
        guard !isWorking else { return }
        bag.set(model.rawValue, Self.modelKey(account))
        bag.set(effort.rawValue, Self.effortKey(account))
        guard let thread = threadId(threadR), let command = MailHelperCommand.draft(
            account: account, thread: thread, model: model, effort: effort, instruction: instruction) else {
            phase = .failed("I can\u{2019}t find this conversation in Gmail yet. Try again after the next sync.")
            return
        }
        generation += 1
        let mine = generation
        phase = .working(since: clock())
        sent = command.id
        session.send(command, timeout: MailHelperSession.draftTimeout) { [weak self] r in
            guard let self, self.generation == mine else { return }
            self.sent = nil
            if r.ok, let text = r.data["draft"]?.string, let clean = Self.clean(text) {
                self.phase = .idle
                self.open = false
                self.insert(clean)
            } else {
                self.phase = .failed(r.ok ? "The helper sent back an empty draft." : (r.error ?? "No draft this time."))
            }
        }
    }

    /// Cancel: stop waiting (the helper may still finish; its answer is dropped).
    func cancel() {
        generation += 1
        if let sent { session.stopWaiting(sent) }
        sent = nil
        phase = .idle
    }

    /// Plain text: control characters out (newlines and tabs stay), at most 20,000 characters.
    static func clean(_ text: String) -> String? {
        let kept = text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !($0.properties.generalCategory == .control || $0.properties.generalCategory == .format) }
        let s = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(textLimit))
    }
}

// MARK: - Inserting a draft into the composer

extension ComposerModel {
    /// Whether anything is written above the signature and the quoted original. Rich: the text before the signature's
    /// marked range; plain: the body no longer opens with the composer's two empty lines.
    var hasOwnText: Bool {
        switch format {
        case .rich:
            let text = document.string as NSString
            let end = ComposerDocument.signatureRange(document)?.location ?? text.length
            return !text.substring(to: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .plain:
            return !body.hasPrefix("\n\n")
        }
    }

    /// A draft from the writer: through the body setter when nothing is written yet (the draft, then the blank line,
    /// the signature and the quote as they were), else at the cursor (one undoable change in rich mode).
    @MainActor
    func insertDraft(_ text: String) {
        guard !text.isEmpty else { return }
        if !hasOwnText {
            body = text + body
            return
        }
        switch format {
        case .rich:
            if let editor {
                editor.insert(ComposerDocument.plain(text, defaults: defaults), actionName: "Insert Draft")
                return
            }
        case .plain:
            if let insertAtCursor, insertAtCursor(text) { return }
        }
        body = text + "\n\n" + body
    }
}
