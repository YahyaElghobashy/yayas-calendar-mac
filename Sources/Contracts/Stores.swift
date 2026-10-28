import Foundation

// The app seam on the app side (D-014). The data layer implements these; the UI layer (Peek,
// Calendar section, Inbox, Widget Studio, router) only calls them through `Services`. Frozen: change
// only with a DECISIONS entry.

// MARK: - Calendar

struct CalendarEvent: Equatable, Identifiable {
    enum Response: String, Codable { case accepted, tentative, declined, needsAction }

    struct Attendee: Equatable {
        var name: String?
        var email: String
        var response: Response
        var isSelf: Bool
        var isOrganizer: Bool
    }

    var id: String { r }
    /// Stable local id. Merged invites (same meeting in several accounts) share one group id.
    var r: String
    /// Every account that has this meeting; the first is the primary copy.
    var accountIds: [UUID]
    var calendarName: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    /// Only hosts on the join allowlist (Meet, Zoom, Teams, Webex, Whereby, Slack, GoTo, Chime, Jitsi).
    var joinURL: URL?
    /// "Open in Google Calendar" (the event's htmlLink).
    var webURL: URL?
    /// Description as plain text.
    var notes: String?
    var organizer: Attendee?
    var attendees: [Attendee]
    /// The user's own response (on the primary copy; RSVP updates every copy still pending).
    var myResponse: Response
    var clashes: Bool
}

protocol CalendarStore: AnyObject {
    /// Events overlapping [from, to), sorted by start. `accounts` nil = every account with calendar on.
    func events(from: Date, to: Date, accounts: Set<UUID>?) throws -> [CalendarEvent]
    func event(r: String) throws -> CalendarEvent?
}

protocol CalendarActions: AnyObject {
    /// RSVP for this occurrence on every copy still pending (fresh GET → PATCH with If-Match).
    func rsvp(r: String, response: CalendarEvent.Response) async throws
    /// Sync every account now (wake, unlock, `yayacal://sync`, "Sync now").
    func syncNow() async
}

// MARK: - Mail

struct MailThread: Equatable, Identifiable {
    var id: String { r }
    var r: String
    var accountId: UUID
    var sender: String
    var senderEmail: String
    var subject: String
    var snippet: String
    var at: Date
    var unread: Bool
    var starred: Bool
    var messageCount: Int
}

struct MailMessage: Equatable, Identifiable {
    struct Attachment: Equatable {
        var name: String
        var bytes: Int
        /// Gmail part id ("1", "1.2"); "" = can't be fetched (fixtures, raw parses).
        var id: String = ""
        var mimeType: String = ""
        /// Inline parts: the Content-ID without <>.
        var contentId: String? = nil
        /// Drawn in the body via cid:, not a chip.
        var isInline: Bool = false
    }
    var id: String
    var from: String
    var fromEmail: String
    var to: [String]
    var cc: [String]
    var date: Date
    var subject: String
    /// Sanitized HTML (no script, no remote loads unless allowed) or nil for plain-text mail.
    var html: String?
    var text: String
    var hasRemoteImages: Bool
    var attachments: [Attachment]
    /// `html` was generated from the text part (MailPlainText); never has remote images.
    var isPlainText: Bool = false
}

/// A file the composer attached (rich mail, D-041): the data layer reads `file` while building the MIME.
struct MailDraftAttachment: Equatable, Sendable {
    var filename: String
    var mimeType: String
    /// The staged copy (compose staging), never the user's original.
    var file: URL
    var bytes: Int
    /// Inline image referenced by `MailDraft.html` (cid:); nil = a file attachment.
    var contentId: String?
    /// The bytes in memory when the composer has no staging folder (tests, renders); the data layer reads these
    /// instead of `file` when set. Production composers always stage, so this stays nil there.
    var data: Data? = nil
}

/// Reply or forward in rich mode: the data layer composes the quoted original from its own sanitized cache, so
/// surfaces never hand another sender's HTML back for sending (D-041).
struct MailQuoteRequest: Equatable, Sendable {
    enum Kind: String, Sendable { case reply, forward }
    enum Style: String, Sendable { case bar, header }
    var threadR: String
    var messageId: String
    var kind: Kind
    var style: Style = .bar
}

struct MailDraft: Equatable {
    var from: UUID
    var to: [String]
    var cc: [String] = []
    var bcc: [String] = []
    var subject: String
    var body: String
    /// Reply or forward: the thread answered (sets In-Reply-To/References).
    var replyTo: String?
    /// D-023: the outside addresses (not one of the user's own accounts) the user approved for THIS send
    /// in the composer's approval card, lowercased. While `Labs.safeSend` is on, the data layer refuses a
    /// send with any outside recipient missing from this list. Never remembered between sends.
    var approvedOutside: [String] = []
    /// The composer already placed the account's signature in `body` (the user may have edited or removed
    /// it there), so the send path never appends it again. False for callers that send a bare body.
    var signatureIncluded: Bool = false
    /// The text/html part (MailHTMLWriter output); nil = plain text only (`body` is always the text/plain part).
    var html: String? = nil
    var attachments: [MailDraftAttachment] = []
    /// Reply/forward in rich mode: the data layer appends the quoted original (sanitized, from its cache).
    var quote: MailQuoteRequest? = nil
}

/// Returned by reversible actions; pass back to `undo` within its window.
struct UndoToken: Equatable, Hashable { var id: String }

protocol MailStore: AnyObject {
    /// Inbox threads, newest first. `accounts` nil = every account with mail on.
    func threads(accounts: Set<UUID>?, limit: Int) throws -> [MailThread]
    func thread(r: String) throws -> MailThread?
    func messages(threadR: String) async throws -> [MailMessage]
    func unreadCount(accounts: Set<UUID>?) throws -> Int
}

protocol MailActions: AnyObject {
    func markRead(r: String, _ read: Bool) async throws
    func star(r: String, _ starred: Bool) async throws
    func archive(r: String) async throws -> UndoToken
    func trash(r: String) async throws -> UndoToken
    func undo(_ token: UndoToken) async throws
    /// Queues the send; it leaves after the 5 s undo window unless `cancelSend` is called.
    func send(_ draft: MailDraft) async throws -> UndoToken
    func cancelSend(_ token: UndoToken) async throws
}

// MARK: - Mail preferences

struct MailAccountPrefs: Equatable {
    /// Gmail: inbox shows Primary only (category:primary). Default on for personal gmail.com accounts.
    var primaryOnly: Bool
    /// Appended to new mail and replies sent from this account (plain text).
    var signature: String
    /// RTFD of the rich signature; nil = use `signature` in the default font.
    var signatureRich: Data? = nil
}

protocol MailPreferencesStore: AnyObject {
    func prefs(account: UUID) -> MailAccountPrefs
    func save(account: UUID, _ prefs: MailAccountPrefs) throws
    /// Remote images in mail from this sender load without asking.
    func allowsImages(from sender: String) -> Bool
    /// The same for a message in `accountId` (rich mail): the allow list, or a correspondent of that account while
    /// "Images from people you've written to" is on. Defaults to the allow list alone.
    func allowsImages(from sender: String, accountId: UUID) -> Bool
    func setAllowsImages(from sender: String, _ allowed: Bool) throws
}

extension MailPreferencesStore {
    func allowsImages(from sender: String, accountId: UUID) -> Bool { allowsImages(from: sender) }
}

// MARK: - Mail attachments (rich mail, D-043)

/// Attachment bytes as local files: a cache under the data root, never reachable from the widget.
protocol MailAttachmentStore: AnyObject {
    /// The attachment's bytes as a local file (fetching if needed). Never callable from the widget.
    func file(threadR: String, messageId: String, partId: String) async throws -> URL
    /// Already cached? (no network)
    func cachedFile(threadR: String, messageId: String, partId: String) -> URL?
    /// Bytes on disk and Clear (Settings).
    func usage() -> (files: Int, bytes: Int)
    func clear() throws
}

// MARK: - Widgets

struct WidgetSettings: Equatable {
    var kind: String
    var style = WidgetSnapshot.Style()
    /// Custom slots only: the name shown in the widget header.
    var title: String?
    /// Custom slots only: what the slot shows (agenda, day, upNext, month, inbox, combo). Nil = not set up.
    var customContent: WidgetSnapshot.Content?
    /// Accounts shown. Nil = every account marked "Include in All" (picks up future accounts).
    var accountIds: [UUID]?
    var rangeDays = 7
}

protocol WidgetSettingsStore: AnyObject {
    func settings(kind: String) -> WidgetSettings
    /// Saves and republishes that kind's snapshot.
    func save(_ settings: WidgetSettings) throws
}

/// Route state changes from widget taps (the data layer owns state + publishing, D-014). Each call
/// updates state, republishes the kind and reloads its timeline (unthrottled: the agent is active).
protocol WidgetInteractions: AnyObject {
    func page(kind: String, family: String, to page: Int)
    func selectDay(kind: String, day: String)
    func showMonth(kind: String, month: String)
    func setRange(kind: String, days: Int)
    /// Window or popover opened, or any Link tap: flush every kind whose content changed.
    func flushChanged()
    /// Resolve a row's link key. False = stale or forged link (ignore it).
    func verify(r: String, k: String) -> Bool
}

// MARK: - Wiring

/// The one place surfaces get their stores. The data layer installs the real implementations at
/// launch (`Services.install…`); until then everything is empty, so the app runs without data.
enum Services {
    static var calendar: CalendarStore = EmptyStores.shared
    static var calendarActions: CalendarActions = EmptyStores.shared
    static var mail: MailStore = EmptyStores.shared
    static var mailActions: MailActions = EmptyStores.shared
    static var widgetSettings: WidgetSettingsStore = EmptyStores.shared
    static var widgetInteractions: WidgetInteractions = EmptyStores.shared
    static var mailPreferences: MailPreferencesStore = EmptyStores.shared
    static var mailAttachments: MailAttachmentStore = EmptyStores.shared
}

/// App switches that started as labs flags (D-014). Mail itself is on and has no switch (D-029); the
/// name stays so the send guard's callers read as they did (D-023).
enum Labs {
    /// "Ask before sending to other people" (SAFE_SEND, D-023): while on, every send to an address that
    /// isn't one of the user's own connected accounts needs the user's approval in the composer, each
    /// time. Default ON; Settings → Mail turns it off. Key `mail.askBeforeSendingOutside` (D-029;
    /// `MailSettingsMigration` moves an old `labs.safeSend` there once, at launch).
    static var safeSend: Bool {
        get { MailSettingsMigration.askBeforeSendingOutside(in: UserDefaults.standard) }
        set { UserDefaults.standard.set(newValue, forKey: MailSettingsMigration.askKey) }
    }
}

/// The few calls the mail settings migration needs; `UserDefaults` has them, tests use a dictionary.
protocol SettingsKeyValues: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: SettingsKeyValues {}

/// D-029: mail leaves `labs.*`. Runs once at launch (`applicationWillFinishLaunching`, after the installer probes
/// have answered), before anything reads the switch:
/// - an old `labs.safeSend` (written by a build before 1.0, so the user's latest choice) is copied to
///   `mail.askBeforeSendingOutside` and deleted; absent, nothing is written and the switch reads ON;
/// - the old `labs.mail` gate is deleted (mail is always on; the per-account mail toggle stays).
/// A second launch finds neither old key and changes nothing.
enum MailSettingsMigration {
    static let askKey = "mail.askBeforeSendingOutside"
    static let oldAskKey = "labs.safeSend"
    static let oldMailKey = "labs.mail"

    /// "Ask before sending to other people": the stored value, ON when there is none (or it isn't a switch).
    static func askBeforeSendingOutside(in store: SettingsKeyValues) -> Bool {
        store.object(forKey: askKey) as? Bool ?? true
    }

    /// Returns true when it changed anything.
    @discardableResult
    static func run(_ store: SettingsKeyValues) -> Bool {
        var changed = false
        if let old = store.object(forKey: oldAskKey) {
            if let on = old as? Bool { store.set(on, forKey: askKey) }
            store.removeObject(forKey: oldAskKey)
            changed = true
        }
        if store.object(forKey: oldMailKey) != nil {
            store.removeObject(forKey: oldMailKey)
            changed = true
        }
        return changed
    }
}

struct ServiceError: Error, Equatable, CustomStringConvertible {
    let description: String
}

/// Do-nothing implementations used before the data layer wires real ones (and by headless runs).
final class EmptyStores: CalendarStore, CalendarActions, MailStore, MailActions, WidgetSettingsStore, WidgetInteractions, MailPreferencesStore,
                         MailAttachmentStore {
    static let shared = EmptyStores()

    func events(from: Date, to: Date, accounts: Set<UUID>?) throws -> [CalendarEvent] { [] }
    func event(r: String) throws -> CalendarEvent? { nil }
    func rsvp(r: String, response: CalendarEvent.Response) async throws { throw ServiceError(description: "not wired") }
    func syncNow() async {}

    func threads(accounts: Set<UUID>?, limit: Int) throws -> [MailThread] { [] }
    func thread(r: String) throws -> MailThread? { nil }
    func messages(threadR: String) async throws -> [MailMessage] { [] }
    func unreadCount(accounts: Set<UUID>?) throws -> Int { 0 }
    func markRead(r: String, _ read: Bool) async throws {}
    func star(r: String, _ starred: Bool) async throws {}
    func archive(r: String) async throws -> UndoToken { UndoToken(id: "none") }
    func trash(r: String) async throws -> UndoToken { UndoToken(id: "none") }
    func undo(_ token: UndoToken) async throws {}
    func send(_ draft: MailDraft) async throws -> UndoToken { throw ServiceError(description: "not wired") }
    func cancelSend(_ token: UndoToken) async throws {}

    func settings(kind: String) -> WidgetSettings { WidgetSettings(kind: kind) }
    func save(_ settings: WidgetSettings) throws {}

    func page(kind: String, family: String, to page: Int) {}
    func selectDay(kind: String, day: String) {}
    func showMonth(kind: String, month: String) {}
    func setRange(kind: String, days: Int) {}
    func flushChanged() {}
    func verify(r: String, k: String) -> Bool { false }

    func prefs(account: UUID) -> MailAccountPrefs { MailAccountPrefs(primaryOnly: false, signature: "") }
    func save(account: UUID, _ prefs: MailAccountPrefs) throws {}
    func allowsImages(from sender: String) -> Bool { false }
    func setAllowsImages(from sender: String, _ allowed: Bool) throws {}

    func file(threadR: String, messageId: String, partId: String) async throws -> URL { throw ServiceError(description: "not wired") }
    func cachedFile(threadR: String, messageId: String, partId: String) -> URL? { nil }
    func usage() -> (files: Int, bytes: Int) { (0, 0) }
    func clear() throws {}
}
