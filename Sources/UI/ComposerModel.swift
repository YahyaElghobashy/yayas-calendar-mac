import AppKit
import Foundation

/// What opens a composer: a new message (from the Inbox header, a `mailto:` link), a reply or a forward.
struct ComposerRequest: Equatable {
    enum Kind: Equatable { case new, reply, replyAll, forward }

    var kind: Kind
    /// The thread answered (replies).
    var thread: MailThread?
    /// The message answered: the thread's latest (quoted, and its people become the recipients).
    var message: MailMessage?
    /// New mail: the From the user was looking at (the Inbox's account), if any.
    var preferredFrom: UUID?
    /// New mail from a `mailto:` link.
    var to: [String] = []

    static func new(from account: UUID? = nil, to: [String] = []) -> ComposerRequest {
        ComposerRequest(kind: .new, thread: nil, message: nil, preferredFrom: account, to: to)
    }

    static func reply(_ thread: MailThread, _ message: MailMessage?, all: Bool = false) -> ComposerRequest {
        ComposerRequest(kind: all ? .replyAll : .reply, thread: thread, message: message, preferredFrom: thread.accountId)
    }

    /// Forward (rich mail, D-042): "Fwd: …", nobody in To, the message's files re-attached.
    static func forward(_ thread: MailThread, _ message: MailMessage) -> ComposerRequest {
        ComposerRequest(kind: .forward, thread: thread, message: message, preferredFrom: thread.accountId)
    }
}

/// Why a draft can't go yet, in the persona voice. (Outside recipients aren't a problem: with the switch
/// on they get the approval card, D-023.)
enum ComposerProblem: Error, Equatable {
    case noFrom
    case noRecipients
    case badAddress(String)
    case empty
    /// Over Gmail's 25 MB with attachments (the composer's estimate).
    case tooLarge(total: Int)
    /// A forwarded original's files are still downloading.
    case attachmentsLoading
    /// An attachment can't be read anymore.
    case attachmentFailed(String)
    /// Files the user attached are still being copied into staging.
    case attachmentsCopying

    var message: String {
        switch self {
        case .noFrom: return "Pick which account this comes from."
        case .noRecipients: return "Who's it for? Add someone in To."
        case .badAddress(let a): return "\u{201C}\(a)\u{201D} doesn\u{2019}t look like an email address."
        case .empty: return "There\u{2019}s nothing to send yet. Add a subject or a few words."
        case .tooLarge(let total): return ComposerSize.tooLarge(total)
        case .attachmentsLoading: return "Still getting the forwarded attachments. Send again in a moment."
        case .attachmentFailed(let name): return "I couldn\u{2019}t read \u{201C}\(name)\u{201D}. Remove it or attach it again."
        case .attachmentsCopying: return "Still copying your files. Send again in a moment."
        }
    }
}

/// "Ask before sending to other people" (D-023): what the approval card over the composer shows for one
/// send. Built when Send is pressed with the switch on and someone other than you on the draft. The card
/// lists every one of `people` (a scrolling list when they don't all fit), and approving puts exactly
/// `outsiders` (the same people) into `MailDraft.approvedOutside`. Never remembered.
struct SendApproval: Equatable {
    /// Where someone is on the draft: the first field they appear in, To → Cc → Bcc.
    enum Field: String, Equatable { case to = "To", cc = "Cc", bcc = "Bcc" }

    struct Person: Equatable {
        /// Lowercased bare address.
        var address: String
        /// The display name the composer knows ("Juniper Vale"), if any.
        var name: String?
        var field: Field = .to

        /// What the card and VoiceOver call them: the name, else the address.
        var label: String { name ?? address }
        /// VoiceOver: "Juniper Vale, juniper@orbitalpickle.example, Bcc" (no field said for To).
        var spokenRow: String {
            ([name, address].compactMap { $0 } + (field == .to ? [] : [field.rawValue])).joined(separator: ", ")
        }
    }

    /// Return and the card's Send do nothing this long after the card appears: a ↩ still held from ⌘↩ or
    /// the second click of a double-click on Send can't approve a card nobody has read.
    static let armDelay: TimeInterval = 0.3

    /// Everyone outside your own addresses, To → Cc → Bcc, each once. All of them are on the card.
    var people: [Person]
    var fromAccount: UUID
    var fromTag: String
    var fromAddress: String
    var subject: String
    /// When the card came up (the composer's clock).
    var shownAt: Date = .distantPast

    var outsiders: [String] { people.map(\.address) }

    /// Past the arming delay (`armDelay`).
    func armed(at now: Date) -> Bool { Self.isArmed(now.timeIntervalSince(shownAt)) }

    /// `armDelay` with a millisecond of slack (Dates near 2026 carry ~0.1 µs of rounding).
    static func isArmed(_ sinceShown: TimeInterval) -> Bool { sinceShown >= armDelay - 0.001 }

    /// "Send to Juniper Vale?", "Send to theo@moonbase.example?", "Send to 7 people?"
    var title: String {
        guard people.count == 1, let one = people.first else { return "Send to \(people.count) people?" }
        return "Send to \(one.label)?"
    }

    /// "Juniper isn't one of your own addresses, so I'm checking first." One vocabulary: your own addresses
    /// and other people.
    var subtitle: String {
        guard people.count == 1, let one = people.first else {
            return "None of these are your own addresses, so I\u{2019}m checking first."
        }
        if let first = one.name.flatMap(Self.firstName) {
            return "\(first) isn\u{2019}t one of your own addresses, so I\u{2019}m checking first."
        }
        return "This address isn\u{2019}t one of yours, so I\u{2019}m checking first."
    }

    var subjectLine: String { subject.isEmpty ? "(no subject)" : subject }

    /// One line for VoiceOver when the card appears: the title, then everyone on it (one person: the
    /// address, since the title already named them), From and the subject.
    var spoken: String {
        var who = ""
        if people.count == 1, let one = people.first {
            if one.name != nil { who = " \(one.address)." }
        } else {
            who = " " + ComposerText.list(people.map { $0.field == .to ? $0.label : "\($0.label) in \($0.field.rawValue)" }) + "."
        }
        return "\(title)\(who) From \(fromTag), subject \(subjectLine). Return sends, Escape goes back."
    }

    /// "Juniper Vale" → "Juniper"; "Vale, Juniper" → "Juniper"; "Juniper" → "Juniper".
    static func firstName(_ name: String) -> String? {
        let parts = name.split(separator: ",", maxSplits: 1)
        let given = parts.count == 2 ? parts[1] : parts.first ?? ""
        return given.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}

/// What a key does while the approval card is up (the window's key monitor asks; pure for the tests).
enum ApprovalKey: Equatable {
    case approve, cancel
    /// Eaten: nothing reaches the draft underneath (⌘↩ can't send a second time).
    case swallow
    /// Menus and focus keys go on as usual (⌘W, ⌘Q, Tab, Space on a focused button).
    case pass

    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let escapeKey: UInt16 = 53
    static let periodKey: UInt16 = 47
    static let tabKey: UInt16 = 48
    static let spaceKey: UInt16 = 49

    /// `isRepeat`: the key is auto-repeating (held since before the card came up); `sinceShown`: seconds
    /// since the card appeared. Return approves only when pressed fresh, after `SendApproval.armDelay`.
    static func decide(keyCode: UInt16, command: Bool, option: Bool = false, control: Bool = false,
                       isRepeat: Bool = false, sinceShown: TimeInterval = .infinity) -> ApprovalKey {
        switch keyCode {
        case returnKey, enterKey:
            if command || option || control { return .swallow }
            return isRepeat || !SendApproval.isArmed(sinceShown) ? .swallow : .approve
        case escapeKey: return .cancel
        case periodKey where command: return .cancel
        case tabKey, spaceKey: return command || option || control ? .swallow : .pass
        default: return command ? .pass : .swallow
        }
    }
}

/// Reply text, quoting and recipients: pure, so the tests pin every rule.
enum ComposerText {
    static let quoteLineLimit = 200

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The composer's quiet footer line with the switch on, in the persona's voice: "I'll check with you
    /// before this goes to Juniper Vale and 2 others." The first person by name when the composer knows it.
    static func approvalHint(_ people: [SendApproval.Person]) -> String? {
        guard let first = people.first else { return nil }
        let others = people.count - 1
        let tail = others == 0 ? "" : others == 1 ? " and 1 other" : " and \(others) others"
        return "I\u{2019}ll check with you before this goes to \(first.name.map(shortName) ?? short(first.address))\(tail)."
    }

    static let shortLimit = 34

    /// Addresses past 34 characters keep their domain (it says which organisation it goes to) and lose the
    /// end of the name part: "a.very.long…@a-long-domain.example". A domain too long for that keeps a
    /// few letters of the name: "theo…@moonbase-holdings-international.example".
    static func short(_ address: String) -> String {
        guard address.count > shortLimit, let at = address.lastIndex(of: "@") else { return address }
        let local = address[..<at], domain = address[address.index(after: at)...]
        let room = max(5, shortLimit - domain.count - 2)
        guard local.count > room else { return address }
        let kept = String(local.prefix(room)).trimmingCharacters(in: CharacterSet(charactersIn: ".-_+"))
        return kept + "\u{2026}@" + domain
    }

    /// Names past 34 characters: cut with "…".
    static func shortName(_ name: String) -> String {
        name.count > shortLimit ? String(name.prefix(shortLimit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : name
    }

    /// "Fwd: Subject" once: never "Fwd: Fwd:", and "Fw:" or "fwd:" from other clients count as already forwarded.
    static func forwardSubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        for prefix in ["fwd:", "fw:"] where lower.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? "Fwd:" : "Fwd: \(rest)"
        }
        return trimmed.isEmpty ? "Fwd: (no subject)" : "Fwd: \(trimmed)"
    }

    /// Plain mode's forwarded message: Gmail's header ("---------- Forwarded message ---------", From, Date, Subject,
    /// To, Cc), a blank line, then the text (at most 200 lines).
    static func forwardQuote(_ m: MailMessage) -> String {
        let header = MailAttribution.forwardHeader(name: m.from, address: m.fromEmail, date: m.date, to: m.to, cc: m.cc, subject: m.subject)
        var lines = m.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let clipped = lines.count > quoteLineLimit
        return ([MailAttribution.forwardLine] + header.map { "\($0.0): \($0.1)" } + [""] + lines.prefix(quoteLineLimit)
            + (clipped ? ["\u{2026}"] : [])).joined(separator: "\n")
    }

    /// "Re: Subject" once (never "Re: Re:").
    static func replySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("re:") { return trimmed }
        return trimmed.isEmpty ? "Re: (no subject)" : "Re: \(trimmed)"
    }

    /// "On Monday 19 October 2026 at 9:41 AM, Juniper Vale <juniper@orbitalpickle.example> wrote:" and the text,
    /// each line behind "> " (at most 200 lines).
    static func quote(_ m: MailMessage) -> String {
        let header = MailAttribution.line(name: m.from, address: m.fromEmail, date: m.date)
        var lines = m.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let clipped = lines.count > quoteLineLimit
        let quoted = lines.prefix(quoteLineLimit).map { $0.isEmpty ? ">" : "> \($0)" }
        return ([header] + quoted + (clipped ? ["> …"] : [])).joined(separator: "\n")
    }

    /// The body a composer opens with: room to type on top, then the signature, then the quote.
    static func initialBody(signature: String, quote: String?) -> String {
        let sig = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = "\n\n"
        if !sig.isEmpty { body += sig + "\n" }
        if let quote { body += "\n" + quote + "\n" }
        return body
    }

    /// Reply: the sender (or, replying to your own message, its recipients). Reply all: everyone on it
    /// except you; Cc keeps its Cc.
    static func recipients(for m: MailMessage, all: Bool, own: Set<String>) -> (to: [String], cc: [String]) {
        let sender = MailText.bareAddress(m.fromEmail)
        let to = m.to.map(MailText.bareAddress), cc = m.cc.map(MailText.bareAddress)
        var primary: [String] = own.contains(sender) ? to.filter { !own.contains($0) } : [sender]
        if primary.isEmpty { primary = [sender] }
        guard all else { return (dedupe(primary), []) }
        let others = to.filter { !own.contains($0) && !primary.contains($0) }
        let copies = cc.filter { !own.contains($0) && !primary.contains($0) && !others.contains($0) }
        return (dedupe(primary + others), dedupe(copies))
    }

    /// The From a composer starts with: the account that got the thread; for new mail the Inbox's
    /// account, else the last one used, else the first. Only accounts that still have mail on count.
    static func defaultFrom(_ request: ComposerRequest, accounts: [DirectoryAccount], lastUsed: UUID?) -> UUID? {
        let ids = accounts.map(\.id)
        for candidate in [request.thread?.accountId, request.preferredFrom, lastUsed] {
            if let candidate, ids.contains(candidate) { return candidate }
        }
        return ids.first
    }

    /// Display names from the thread answered: its sender and the people on the message (lowercased
    /// address → name). Your own addresses are left out.
    static func names(_ request: ComposerRequest, own: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ name: String?, _ address: String) {
            let key = MailText.bareAddress(address)
            guard !own.contains(key), out[key] == nil, let name = MailText.cleanName(name, address: key) else { return }
            out[key] = name
        }
        if let m = request.message {
            add(m.from, m.fromEmail)
            for entry in m.to + m.cc { add(MailText.displayName(entry), entry) }
        }
        if let t = request.thread { add(t.sender, t.senderEmail) }
        return out
    }

    /// Names typed into the fields ("Theo Quill <theo@moonbase.example>").
    static func names(fields: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for field in fields {
            for entry in field.components(separatedBy: CharacterSet(charactersIn: ",;\n")) {
                let key = MailText.bareAddress(entry)
                if out[key] == nil, let name = MailText.cleanName(MailText.displayName(entry), address: key) { out[key] = name }
            }
        }
        return out
    }

    static func dedupe(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

// MARK: - Rich composer (D-042)

/// Rich text on a light sheet (the default), or exactly today's plain composer (Settings → Writing → "Send plain
/// text only", or ⇧⌘T per message).
enum ComposerFormat: Equatable { case rich, plain }

/// The message a rich reply answers, shown read-only under the editor (never part of the editable document: the data
/// layer composes the quote from its own sanitized cache at send time, D-041).
struct QuotedOriginal: Equatable {
    var message: MailMessage
    var threadR: String
    var style: MailQuoteRequest.Style
    /// A reply's quote, or a forwarded message (Gmail's forward header, never collapsed by recipients).
    var kind: MailQuoteRequest.Kind = .reply

    var senderName: String { message.from.isEmpty ? message.fromEmail : message.from }
    var isForward: Bool { kind == .forward }
    /// "On Monday 19 October 2026 at 9:41 AM, Juniper Vale <juniper@vale.example> wrote:"
    var attribution: String { MailAttribution.line(name: message.from, address: message.fromEmail, date: message.date) }
    /// Header style: From, Sent, To, Cc, Subject.
    var header: [(String, String)] {
        MailAttribution.header(name: message.from, address: message.fromEmail, date: message.date, to: message.to, cc: message.cc,
                               subject: message.subject)
    }
    /// Forward: Gmail's header lines (From, Date, Subject, To, Cc).
    var forwardHeader: [(String, String)] {
        MailAttribution.forwardHeader(name: message.from, address: message.fromEmail, date: message.date, to: message.to,
                                      cc: message.cc, subject: message.subject)
    }
    /// The plain composer's `>` quote, or a forward's header and text (the `body` bridge appends it, so `body` reads as
    /// the plain composer has it).
    var plainQuote: String { isForward ? ComposerText.forwardQuote(message) : ComposerText.quote(message) }
    /// VoiceOver: "Quoted message from Juniper Vale, collapsed"; "Forwarded message from Priya Starling, expanded".
    func spoken(expanded: Bool) -> String {
        "\(isForward ? "Forwarded" : "Quoted") message from \(senderName), \(expanded ? "expanded" : "collapsed")"
    }

    static func == (a: QuotedOriginal, b: QuotedOriginal) -> Bool {
        a.message == b.message && a.threadR == b.threadR && a.style == b.style && a.kind == b.kind
    }
}

/// The link popover's fields (⌘K or the toolbar): the text shown and where it goes.
struct ComposerLinkDraft: Equatable {
    var text: String
    var url: String
    /// The selection it applies to.
    var range: NSRange
    /// The selection already had a link (the popover offers Remove).
    var existing: Bool

    static let problem = "Links can go to web pages (http, https) or email addresses."
}

/// Which toolbar popover is open (model state, so renders can draw one).
enum ComposerPopover: Equatable { case link, color, font, size }

/// The editor the model drives (the text view registers itself so operations land in its undo stack).
@MainActor
protocol ComposerEditing: AnyObject {
    func perform(_ op: ComposerDocument.Op)
    func select(_ range: NSRange)
    func focusEditor()
    /// Inserts at the selection as one undoable change (inline images).
    func insert(_ text: NSAttributedString, actionName: String)
    /// Removes the inline image carrying this content id (Send as Attachment), undoable.
    func removeInlineImage(_ contentId: String)
}

/// The composer window's brain: fields, the draft it builds, the approval card for outside recipients
/// ("Ask before sending to other people", D-023), and the 5 s undo send.
final class ComposerModel: ObservableObject {
    enum Phase: Equatable {
        case editing
        /// Handed to `send`; it leaves when the 5 s are up unless Undo.
        case sending(until: Date)
        case sent
    }

    static let lastFromKey = "mail.lastFrom"

    @Published var from: UUID?
    @Published var to: String
    @Published var cc: String
    @Published var bcc: String
    @Published var subject: String
    /// Plain mode's body as typed (rich mode keeps its text in `document`; `body` bridges both).
    @Published private var plainBody: String
    @Published var showCcBcc: Bool
    @Published private(set) var format: ComposerFormat
    /// Rich mode: the editable part (your text and the signature). The quoted original is not in it.
    @Published private(set) var document: NSAttributedString
    /// Bumped when the model replaces `document` itself (From switch, `body` set, Edit quoted text, Make Rich Text):
    /// the editor then loads it as one undoable change. Edits typed in the editor don't bump it.
    @Published private(set) var documentRevision = 0
    /// Reply in rich mode: the original, read-only under the editor (nil after Remove).
    @Published private(set) var quote: QuotedOriginal?
    @Published var quoteExpanded = false
    /// The toolbar's state for the editor's selection.
    @Published private(set) var formatting = FormattingState()
    @Published var linkDraft: ComposerLinkDraft?
    @Published var popover: ComposerPopover?
    /// The editor's selection and typing attributes (the toolbar reads them; operations without an editor use them).
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var typingAttributes: [NSAttributedString.Key: Any] = [:]
    weak var editor: ComposerEditing?
    /// Settings → Writing at the time the composer opened.
    let writing: RichMailSettings
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var problem: String?
    /// The approval card, while it is up (Send pressed, switch on, someone outside your accounts on it).
    @Published private(set) var approval: SendApproval?
    /// The tray: files attached by the button, drag and drop or paste, and a forward's original files.
    @Published private(set) var attachments: [ComposerAttachment] = []
    /// The raw MIME this draft will come to (an estimate): text, HTML, inline images, files and the quoted original.
    /// Recomputed when the attachments change, and 250 ms after the document stops changing.
    @Published private(set) var estimatedSize = 0

    let request: ComposerRequest
    let accounts: [DirectoryAccount]
    let toasts: MailToastCenter
    var onClose: () -> Void = {}

    private let actions: () -> MailActions
    private let prefs: () -> MailPreferencesStore
    private let local: MailLocalStore
    private let clock: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let safeSendSwitch: () -> Bool
    /// Stable copies of attachments (production: `<data root>/compose/<id>`); nil = kept in memory (tests, renders).
    let staging: ComposeStaging?
    private let attachmentStore: () -> MailAttachmentStore
    /// Copies into staging still running (off the main actor), and those that finished after their chip was removed
    /// (Undo puts the chip back with its copy).
    private var copying: [Task<Void, Never>] = []
    private var finishedCopies: [UUID: Result<URL, Error>] = [:]
    private var estimateGeneration = 0
    private var signatureInBody: String
    /// Rich mode: the signature as inserted (marked `.ycSignature`), for the From switch's string fallback.
    private var richSignature: NSAttributedString
    /// The reply's original while plain mode carries it as `>` text (Make Rich Text puts it back under the editor).
    private var stashedQuote: QuotedOriginal?
    private var token: UndoToken?
    private var sendGeneration = 0
    /// Display names the composer knows from the thread answered (lowercased address → "Juniper Vale").
    private let knownNames: [String: String]
    /// Settings → Mail flipped the switch: redraw (the footer hint follows at once, not on the next keystroke).
    private var switchObserver: NSObjectProtocol?

    /// `safeSend` is read when it matters (each Send, each footer draw), so Settings applies at once. `format` nil =
    /// Settings → Writing ("Send plain text only" → plain, else rich).
    init(request: ComposerRequest, accounts: [DirectoryAccount], safeSend: @autoclosure @escaping () -> Bool = Labs.safeSend,
         actions: @escaping () -> MailActions = { Services.mailActions },
         prefs: @escaping () -> MailPreferencesStore = { Services.mailPreferences },
         local: MailLocalStore = DefaultsMailLocalStore.shared, clock: @escaping () -> Date = { Date() },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         toasts: MailToastCenter? = nil, format: ComposerFormat? = nil, staging: ComposeStaging? = nil,
         attachmentStore: @escaping () -> MailAttachmentStore = { Services.mailAttachments }) {
        self.request = request
        self.staging = staging
        self.attachmentStore = attachmentStore
        self.accounts = accounts.filter(\.mailEnabled)
        self.safeSendSwitch = safeSend
        self.actions = actions
        self.prefs = prefs
        self.local = local
        self.clock = clock
        self.schedule = schedule
        self.toasts = toasts ?? MailToastCenter(clock: clock, schedule: schedule)
        let writing = RichMailSettings(local: local)
        self.writing = writing
        let format = format ?? (writing.plainTextOnly ? .plain : .rich)
        self.format = format
        let last = local.string(Self.lastFromKey).flatMap(UUID.init(uuidString:))
        let from = ComposerText.defaultFrom(request, accounts: self.accounts, lastUsed: last)
        self.from = from
        let own = Set(self.accounts.map { $0.email.lowercased() })
        knownNames = ComposerText.names(request, own: own)
        let accountPrefs = from.map { prefs().prefs(account: $0) }
        let signature = accountPrefs?.signature.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        signatureInBody = signature
        let rich = accountPrefs.map { ComposerDocument.marked(RichSignature.load($0, defaults: writing.documentDefaults)) }
            ?? NSAttributedString()
        richSignature = rich
        var toText = "", ccText = "", subjectText = "", bodyText = ""
        var original: QuotedOriginal?
        var forwarded: [ComposerAttachment] = []
        switch request.kind {
        case .new:
            toText = request.to.joined(separator: ", ")
            bodyText = ComposerText.initialBody(signature: signature, quote: nil)
        case .reply, .replyAll:
            let people = request.message.map { ComposerText.recipients(for: $0, all: request.kind == .replyAll, own: own) }
                ?? (to: request.thread.map { [$0.senderEmail.lowercased()] } ?? [], cc: [])
            toText = people.to.joined(separator: ", ")
            ccText = people.cc.joined(separator: ", ")
            subjectText = ComposerText.replySubject(request.message?.subject ?? request.thread?.subject ?? "")
            bodyText = ComposerText.initialBody(signature: signature, quote: request.message.map(ComposerText.quote))
            original = request.message.map { QuotedOriginal(message: $0, threadR: request.thread?.r ?? "", style: writing.quoteStyle) }
        case .forward:
            subjectText = ComposerText.forwardSubject(request.message?.subject ?? request.thread?.subject ?? "")
            bodyText = ComposerText.initialBody(signature: signature, quote: request.message.map(ComposerText.forwardQuote))
            original = request.message.map { QuotedOriginal(message: $0, threadR: request.thread?.r ?? "", style: .bar, kind: .forward) }
            // The original's files come along (downloaded in the background into staging); inline images stay with the
            // quoted original, which the data layer sends with their own Content-IDs.
            forwarded = (request.message?.attachments ?? []).filter { !$0.isInline }.map {
                ComposerAttachment(filename: AttachmentNames.display($0.name, mimeType: $0.mimeType),
                                   mimeType: $0.mimeType.isEmpty ? ComposerAttachRules.mimeType(name: $0.name) : $0.mimeType,
                                   bytes: $0.bytes, state: .loading, forwardedPart: $0.id)
            }
        }
        to = toText
        cc = ccText
        bcc = ""
        subject = subjectText
        // Rich: room to type, the signature (marked), a last empty line; the original stays outside the document.
        // `body` then reads exactly as `initialBody` (the bridge appends the quote).
        let doc = NSMutableAttributedString(attributedString: ComposerDocument.plain("\n\n", defaults: writing.documentDefaults))
        if rich.length > 0 {
            doc.append(rich)
            doc.append(ComposerDocument.plain("\n", defaults: writing.documentDefaults))
        }
        document = doc
        if format == .rich {
            plainBody = ""
            quote = original
        } else {
            plainBody = bodyText
            quote = nil
            stashedQuote = original
        }
        typingAttributes = ComposerDocument.defaultAttributes(writing.documentDefaults)
        showCcBcc = !ccText.isEmpty
        switchObserver = NotificationCenter.default.addObserver(forName: .ycAskBeforeSendingChanged, object: nil, queue: nil) {
            [weak self] _ in self?.objectWillChange.send()
        }
        formatting = ComposerDocument.formatting(document, selection: selection, typing: typingAttributes, defaults: writing.documentDefaults)
        attachments = forwarded
        estimatedSize = computeEstimate()
    }

    deinit {
        if let switchObserver { NotificationCenter.default.removeObserver(switchObserver) }
    }

    var title: String {
        switch request.kind {
        case .new: return "New message"
        case .reply, .replyAll:
            let name = request.message.map { $0.from } ?? request.thread?.sender ?? ""
            return name.isEmpty ? "Reply" : "Reply to \(name)"
        case .forward:
            return "Forward"
        }
    }

    var ownAddresses: Set<String> { Set(accounts.map { $0.email.lowercased() }) }
    var fromAccount: DirectoryAccount? { from.flatMap { id in accounts.first { $0.id == id } } }
    var isSending: Bool { if case .sending = phase { return true } else { return false } }
    var isConfirming: Bool { approval != nil }
    /// "Ask before sending to other people" (`Labs.safeSend`), read live.
    var safeSend: Bool { safeSendSwitch() }

    /// Everyone on the draft (To → Cc → Bcc) who isn't one of your own addresses, each once, lowercased.
    /// Only complete addresses count (a half-typed one isn't anyone yet).
    var outsiders: [String] {
        let everyone = MailText.addresses(to) + MailText.addresses(cc) + MailText.addresses(bcc)
        let own = ownAddresses
        return ComposerText.dedupe(everyone.filter { MailText.isAddress($0) && !own.contains($0) })
    }

    /// The quiet footer line while editing with the switch on and someone other than you on the draft.
    var approvalHint: String? {
        guard safeSend, phase == .editing, approval == nil else { return nil }
        let names = self.names
        return ComposerText.approvalHint(outsiders.map { SendApproval.Person(address: $0, name: names[$0]) })
    }

    /// Seconds since the approval card came up (the key monitor's arming check).
    var sinceApprovalShown: TimeInterval {
        approval.map { clock().timeIntervalSince($0.shownAt) } ?? .infinity
    }

    /// Names typed into the fields win over the ones known from the thread answered.
    private var names: [String: String] {
        knownNames.merging(ComposerText.names(fields: [to, cc, bcc])) { _, typed in typed }
    }

    /// The text in either mode, as the plain composer always had it: rich mode reads the document's text and, while
    /// the original is shown, today's `>` quote after it (byte-identical to `ComposerText.initialBody`). Setting it in
    /// rich mode drops that exact quote suffix and puts the rest in the default font (the signature re-marked at its
    /// last occurrence).
    var body: String {
        get {
            switch format {
            case .plain: return plainBody
            case .rich: return document.string + (quote.map { "\n" + $0.plainQuote + "\n" } ?? "")
            }
        }
        set {
            switch format {
            case .plain:
                plainBody = newValue
            case .rich:
                var text = newValue
                if let quote {
                    let suffix = "\n" + quote.plainQuote + "\n"
                    if text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
                }
                replaceDocument(documentFromPlain(text))
            }
        }
    }

    var defaults: ComposerDocument.Defaults { writing.documentDefaults }

    /// Plain text in the default font, with the rich signature put back where its text last appears.
    private func documentFromPlain(_ text: String) -> NSAttributedString {
        let doc = NSMutableAttributedString(attributedString: ComposerDocument.plain(text, defaults: defaults))
        if richSignature.length > 0 {
            let found = (text as NSString).range(of: richSignature.string, options: .backwards)
            if found.location != NSNotFound { doc.replaceCharacters(in: found, with: richSignature) }
        }
        return doc
    }

    /// The model replaces the document (the editor loads it as one undoable change).
    private func replaceDocument(_ doc: NSAttributedString) {
        document = doc
        documentRevision += 1
        selection = ComposerDocument.clamp(selection, doc.length)
        updateFormatting()
    }

    /// Switching From swaps the signature: rich mode replaces the `.ycSignature` range (robust to typing around it),
    /// else the old signature's text; plain mode swaps the text when the body still has it.
    func changeFrom(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }), id != from else { return }
        let nextPrefs = prefs().prefs(account: id)
        let next = nextPrefs.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case .plain:
            if !signatureInBody.isEmpty, let range = plainBody.range(of: signatureInBody) {
                plainBody.replaceSubrange(range, with: next)
            } else if signatureInBody.isEmpty, !next.isEmpty, plainBody.hasPrefix("\n\n") {
                plainBody.insert(contentsOf: next + "\n", at: plainBody.index(plainBody.startIndex, offsetBy: 2))
            }
        case .rich:
            let nextRich = ComposerDocument.marked(RichSignature.load(nextPrefs, defaults: defaults))
            let doc = NSMutableAttributedString(attributedString: document)
            let ns = doc.string as NSString
            if let range = ComposerDocument.signatureRange(doc) {
                doc.replaceCharacters(in: range, with: nextRich)
            } else if richSignature.length > 0, case let found = ns.range(of: richSignature.string, options: .backwards), found.location != NSNotFound {
                doc.replaceCharacters(in: found, with: nextRich)
            } else if richSignature.length == 0, nextRich.length > 0, doc.string.hasPrefix("\n\n") {
                let insert = NSMutableAttributedString(attributedString: nextRich)
                insert.append(ComposerDocument.plain("\n", defaults: defaults))
                doc.insert(insert, at: 2)
            }
            richSignature = nextRich
            replaceDocument(doc)
        }
        signatureInBody = next
        from = id
        problem = nil
    }

    /// The draft to hand to `send`, or why not yet. `approvedOutside` stays empty here: only `approveSend`
    /// fills it, with exactly what the card listed. Rich mode: `body` is the text/plain part and `html` the
    /// text/html part (MailHTMLWriter); a reply's original travels as `quote` for the data layer to append.
    func draft() -> Result<MailDraft, ComposerProblem> {
        guard let from, accounts.contains(where: { $0.id == from }) else { return .failure(.noFrom) }
        let to = MailText.addresses(self.to), cc = MailText.addresses(self.cc), bcc = MailText.addresses(self.bcc)
        let everyone = to + cc + bcc
        guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty else { return .failure(.noRecipients) }
        if let bad = everyone.first(where: { !MailText.isAddress($0) }) { return .failure(.badAddress(bad)) }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let subj = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !subj.isEmpty || !attachments.isEmpty else { return .failure(.empty) }
        // Attachments (D-043/D-044): forwarded files must have arrived, every file must still be readable, and the whole
        // message must stay within Gmail's 25 MB.
        if attachments.contains(where: { $0.isLoading && !$0.isCopying }) { return .failure(.attachmentsLoading) }
        if attachments.contains(where: \.isCopying) { return .failure(.attachmentsCopying) }
        if let broken = attachments.first(where: { $0.failure != nil || ($0.file == nil && $0.data == nil) }) {
            return .failure(.attachmentFailed(broken.filename))
        }
        let size = computeEstimate()
        if size != estimatedSize { estimatedSize = size }
        if size > MailSize.limit { return .failure(.tooLarge(total: size)) }
        let files = attachments.compactMap { $0.draftAttachment() }
        let replyTo = request.kind == .new ? nil : request.thread?.r
        switch format {
        case .plain:
            var draft = MailDraft(from: from, to: ComposerText.dedupe(to), cc: ComposerText.dedupe(cc),
                                  bcc: ComposerText.dedupe(bcc), subject: subj, body: body,
                                  replyTo: replyTo, signatureIncluded: true)
            draft.attachments = files
            return .success(draft)
        case .rich:
            let out = rendered()
            var draft = MailDraft(from: from, to: ComposerText.dedupe(to), cc: ComposerText.dedupe(cc),
                                  bcc: ComposerText.dedupe(bcc), subject: subj, body: out.text,
                                  replyTo: replyTo, signatureIncluded: true)
            draft.html = out.html
            draft.quote = quoteRequest
            var inline: [MailDraftAttachment] = []
            for image in out.inlineImages {
                // Staged so the data layer reads stable bytes; in memory without staging (tests, renders).
                if let staging {
                    guard let file = try? staging.stage(data: image.data) else { return .failure(.attachmentFailed(image.filename)) }
                    inline.append(MailDraftAttachment(filename: image.filename, mimeType: image.mimeType, file: file, bytes: image.data.count,
                                                      contentId: image.contentId))
                } else {
                    inline.append(MailDraftAttachment(filename: image.filename, mimeType: image.mimeType, file: URL(fileURLWithPath: "/dev/null"),
                                                      bytes: image.data.count, contentId: image.contentId, data: image.data))
                }
            }
            draft.attachments = files + inline
            return .success(draft)
        }
    }

    /// The writer's output for the document (html, text/plain, inline images) in Settings → Writing's defaults.
    func rendered() -> MailHTMLWriter.Output {
        MailHTMLWriter.render(document, font: writing.font.css, size: writing.size.rawValue)
    }

    /// The original the data layer appends to a rich reply (nil after Remove, in plain mode, or for new mail).
    var quoteRequest: MailQuoteRequest? {
        guard let quote, !quote.threadR.isEmpty else { return nil }
        return MailQuoteRequest(threadR: quote.threadR, messageId: quote.message.id, kind: quote.kind, style: quote.style)
    }

    // MARK: Attachments

    /// Over 10 MB: the footer's quiet warning (nil once it's over 25 MB: the problem says it then).
    var sizeWarning: String? {
        estimatedSize > MailSize.limit ? nil : ComposerSize.warning(estimatedSize)
    }

    /// Over 25 MB right now (the tray shows it before Send is pressed).
    var sizeProblem: String? { estimatedSize > MailSize.limit ? ComposerSize.tooLarge(estimatedSize) : nil }

    /// The 📎 button, ⇧⌘A, a drop or a paste of files: each becomes a chip. Refused with one line, before anything is
    /// copied: folders and packages (a symlink to one too), links to nothing, and files too big for any message. A symlink
    /// attaches its target's bytes. With staging the stable copy is made off the main actor: the chip shows at once
    /// ("Copying…") and is ready when its copy is. Returns how many were attached.
    @discardableResult
    func attach(urls: [URL]) -> Int {
        var added = 0
        var refused = false
        var copies: [(id: UUID, file: URL)] = []
        for url in urls {
            let name = AttachmentNames.display(url.lastPathComponent)
            if ComposerAttachRules.isFolderOrPackage(url) {
                problem = ComposerAttachRules.folderRefused
                refused = true
                continue
            }
            guard let file = try? ComposerAttachRules.regularFile(url) else {
                problem = ComposerProblem.attachmentFailed(name).message
                refused = true
                continue
            }
            let bytes = ComposerAttachRules.size(file)
            guard ComposerAttachRules.fitsAlone(bytes) else {
                problem = ComposerAttachRules.tooLargeAlone(name, bytes: bytes)
                refused = true
                continue
            }
            var chip = ComposerAttachment(filename: name, mimeType: ComposerAttachRules.mimeType(url), bytes: bytes, file: staging == nil ? file : nil)
            if staging != nil {
                chip.state = .loading
                copies.append((chip.id, file))
            }
            attachments.append(chip)
            added += 1
        }
        if added > 0, !refused { problem = nil }
        attachmentsChanged()
        if let staging, !copies.isEmpty { copyInBackground(copies, into: staging) }
        return added
    }

    /// The copies into staging, off the main actor; each chip turns ready (or failed) when its copy is done.
    private func copyInBackground(_ files: [(id: UUID, file: URL)], into staging: ComposeStaging) {
        let task = Task { @MainActor [weak self] in
            let results: [(UUID, Result<URL, Error>)] = await Task.detached(priority: .userInitiated) {
                files.map { item in (item.id, Result { try staging.stage(item.file) }) }
            }.value
            self?.finishCopies(results)
        }
        copying.append(task)
    }

    @MainActor
    private func finishCopies(_ results: [(UUID, Result<URL, Error>)]) {
        for (id, result) in results {
            if let index = attachments.firstIndex(where: { $0.id == id }) {
                applyCopy(result, at: index)
            } else {
                finishedCopies[id] = result
            }
        }
        if problem == ComposerProblem.attachmentsCopying.message { problem = nil }
        attachmentsChanged()
    }

    private func applyCopy(_ result: Result<URL, Error>, at index: Int) {
        switch result {
        case .success(let file):
            attachments[index].file = file
            let bytes = ComposerAttachRules.size(file)
            if bytes > 0 { attachments[index].bytes = bytes }
            attachments[index].state = .ready
        case .failure:
            attachments[index].state = .failed("I couldn\u{2019}t copy it.")
        }
    }

    /// Waits for the copies into staging still running (tests and renders; Send asks the chips instead).
    @MainActor
    func attachmentsCopied() async {
        while !copying.isEmpty {
            let task = copying.removeFirst()
            await task.value
        }
    }

    /// Image bytes (a paste or a drop): inline in a rich body when at most 5 MB, else (plain mode, bigger, or `asFile`)
    /// a chip. Returns true when it went inline.
    @MainActor
    @discardableResult
    func attach(imageData data: Data, name: String? = nil, asFile: Bool = false) -> Bool {
        if !asFile, format == .rich, data.count <= ComposerImages.inlineLimit, let image = ComposerImages.prepare(data, name: name) {
            let run = ComposerImages.attachment(image, contentId: MailHTMLWriter.newContentId(), defaults: typingAttributes)
            if let editor {
                editor.insert(run, actionName: "Insert Image")
            } else {
                let doc = NSMutableAttributedString(attributedString: document)
                let at = ComposerDocument.clamp(selection, doc.length)
                doc.replaceCharacters(in: at, with: run)
                selection = NSRange(location: at.location + run.length, length: 0)
                replaceDocument(doc)
            }
            scheduleEstimate()
            return true
        }
        let filename = name.map { AttachmentNames.display($0) } ?? "image.png"
        let mime = MailHTMLWriter.sniffImage(data) ?? ComposerAttachRules.mimeType(name: filename)
        if let staging {
            guard let file = try? staging.stage(data: data) else {
                problem = ComposerProblem.attachmentFailed(filename).message
                return false
            }
            attachments.append(ComposerAttachment(filename: filename, mimeType: mime, bytes: data.count, file: file))
        } else {
            attachments.append(ComposerAttachment(filename: filename, mimeType: mime, bytes: data.count, data: data))
        }
        attachmentsChanged()
        return false
    }

    /// × on a chip (the tray registers Undo → `restoreAttachment`).
    func removeAttachment(_ id: UUID) {
        guard attachments.contains(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        if problem == ComposerProblem.attachmentsLoading.message || problem == ComposerProblem.attachmentsCopying.message
            || problem?.hasPrefix(ComposerSize.problemPrefix) == true { problem = nil }
        attachmentsChanged()
    }

    func restoreAttachment(_ attachment: ComposerAttachment, at index: Int) {
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
        let at = min(max(0, index), attachments.count)
        attachments.insert(attachment, at: at)
        // Removed while its copy ran: the finished copy comes back with it.
        if let result = finishedCopies.removeValue(forKey: attachment.id) { applyCopy(result, at: at) }
        attachmentsChanged()
    }

    /// Right-click an image chip → "Place in Message": it moves into the body as an inline image.
    @MainActor
    func placeInMessage(_ id: UUID) {
        guard format == .rich, let a = attachments.first(where: { $0.id == id }), a.isImage, a.state == .ready,
              let data = a.data ?? a.file.flatMap({ try? Data(contentsOf: $0) }), data.count <= ComposerImages.inlineLimit else { return }
        if attach(imageData: data, name: a.filename) { removeAttachment(id) }
    }

    /// Right-click an inline image → "Send as Attachment": out of the body, into the tray.
    @MainActor
    func sendAsAttachment(contentId: String) {
        var found: (Data, String, String)?
        document.enumerateAttribute(.ycInlineImage, in: NSRange(location: 0, length: document.length)) { value, range, stop in
            guard (value as? String) == contentId, let attachment = document.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                  let (data, mime) = MailHTMLWriter.imageData(attachment) else { return }
            let name = attachment.fileWrapper?.preferredFilename ?? "image." + (mime == "image/jpeg" ? "jpg" : "png")
            found = (data, mime, name)
            stop.pointee = true
        }
        guard let (data, _, name) = found else { return }
        if let editor {
            editor.removeInlineImage(contentId)
        } else {
            let doc = NSMutableAttributedString(attributedString: document)
            for (cid, range) in ComposerImages.inlineImages(doc).reversed() where cid == contentId { doc.deleteCharacters(in: range) }
            replaceDocument(doc)
        }
        attach(imageData: data, name: name, asFile: true)
    }

    /// The forward's original files: fetched through the attachment cache (cached, 50 MB at most), then staged. Send
    /// while any is still on its way returns `.attachmentsLoading`. The window calls this once it is up.
    @MainActor
    func loadForwardedAttachments() async {
        guard let thread = request.thread, let message = request.message else { return }
        let pending = attachments.filter { $0.isLoading && $0.forwardedPart != nil }
        guard !pending.isEmpty else { return }
        let store = attachmentStore()
        let staging = self.staging
        await withTaskGroup(of: (UUID, Result<(URL, Int), Error>).self) { group in
            for a in pending {
                let part = a.forwardedPart ?? ""
                group.addTask {
                    do {
                        guard !part.isEmpty else { throw ServiceError(description: "That attachment can\u{2019}t be downloaded.") }
                        let cached = try await store.file(threadR: thread.r, messageId: message.id, partId: part)
                        let file = try staging?.stage(cached) ?? cached
                        return (a.id, .success((file, ComposerAttachRules.size(file))))
                    } catch {
                        return (a.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                guard let index = attachments.firstIndex(where: { $0.id == id }) else { continue }
                switch result {
                case .success(let (file, bytes)):
                    attachments[index].file = file
                    if bytes > 0 { attachments[index].bytes = bytes }
                    attachments[index].state = .ready
                case .failure(let error):
                    let why = (error as? ServiceError)?.description ?? "I couldn\u{2019}t download it."
                    attachments[index].state = .failed(why)
                }
            }
        }
        if problem == ComposerProblem.attachmentsLoading.message { problem = nil }
        attachmentsChanged()
    }

    /// The window closed: staged copies go (a queued send's outbox file already holds the bytes).
    func discardStaging() { staging?.removeAll() }

    private func attachmentsChanged() {
        estimatedSize = computeEstimate()
    }

    /// Debounced (250 ms) after the document changes.
    private func scheduleEstimate() {
        estimateGeneration += 1
        let generation = estimateGeneration
        schedule(0.25) { [weak self] in
            guard let self, generation == self.estimateGeneration else { return }
            let size = self.computeEstimate()
            if size != self.estimatedSize { self.estimatedSize = size }
        }
    }

    /// Recomputes the estimate now (tests and renders, whose scheduler never fires).
    func refreshEstimate() { estimatedSize = computeEstimate() }

    /// Text and HTML (with the quoted original the data layer adds), every file and inline image as base64.
    func computeEstimate() -> Int {
        var text = 0, html = 0
        var parts: [Int] = attachments.map(\.bytes)
        var names = attachments.reduce(0) { $0 + $1.filename.utf8.count }
        switch format {
        case .plain:
            text = MailSize.qpWeight(body)
        case .rich:
            let out = MailHTMLWriter.render(document, font: writing.font.css, size: writing.size.rawValue, contentId: { "x@yayascalendar.local" })
            text = MailSize.qpWeight(out.text)
            html = MailSize.qpWeight(out.html)
            for image in out.inlineImages {
                parts.append(image.data.count)
                names += image.filename.utf8.count
            }
            if let quote {
                text += MailSize.qpWeight(quote.plainQuote) + 64
                html += MailSize.qpWeight(quote.message.html ?? quote.message.text) + 1_024
                for a in quote.message.attachments where a.isInline {
                    parts.append(a.bytes)
                    names += a.name.utf8.count
                }
            }
        }
        let headers = (to + cc + bcc + subject).utf8.count
        return MailSize.estimate(text: text, html: html, attachments: parts, names: names, headers: headers)
    }

    // MARK: Rich editing

    /// The editor typed or changed attributes (no revision bump: the editor already shows it).
    func editorChanged(_ doc: NSAttributedString) {
        document = doc
        updateFormatting()
        scheduleEstimate()
    }

    /// The editor's selection or typing attributes moved: the toolbar follows.
    func editorSelected(_ range: NSRange, typing: [NSAttributedString.Key: Any]) {
        selection = range
        typingAttributes = typing
        updateFormatting()
    }

    func updateFormatting() {
        let next = ComposerDocument.formatting(document, selection: selection, typing: typingAttributes, defaults: defaults)
        if next != formatting { formatting = next }
    }

    /// A toolbar or menu operation: through the editor when there is one (one named undo group), else on the
    /// model's own document (tests, renders).
    @MainActor
    func perform(_ op: ComposerDocument.Op) {
        guard format == .rich else { return }
        if let editor { editor.perform(op) } else { apply(op, range: selection) }
    }

    /// Applies `op` to the document for `range` without an editor; returns the new selection.
    @discardableResult
    func apply(_ op: ComposerDocument.Op, range: NSRange) -> NSRange {
        let doc = NSMutableAttributedString(attributedString: document)
        let result = ComposerDocument.apply(op, to: doc, selection: range, typing: typingAttributes, defaults: defaults)
        if let typing = result.typing { typingAttributes = typing }
        selection = result.selection
        replaceDocument(doc)
        return result.selection
    }

    // MARK: Link popover

    /// ⌘K / the Link button: the popover opens with the selection's text and link.
    @MainActor
    func beginLink() {
        guard format == .rich else { return }
        let sel = ComposerDocument.clamp(selection, document.length)
        let text = (document.string as NSString).substring(with: sel)
        var existing: String?
        if sel.length > 0 {
            existing = MailHTMLWriter.linkTarget(document.attribute(.link, at: sel.location, effectiveRange: nil))
        } else if let link = formatting.link {
            existing = link
        }
        let shown = text.contains("\n") ? "" : text
        let looksLikeLink = ComposerDocument.composerLink(shown) != nil && shown.contains(".") && !shown.contains(" ")
        linkDraft = ComposerLinkDraft(text: shown, url: existing ?? (looksLikeLink ? shown : ""), range: sel, existing: existing != nil)
        popover = .link
    }

    /// The popover's Add: nil when done, else the line to show (only http, https and mailto links).
    @MainActor
    func commitLink(text: String, url: String) -> String? {
        guard let draft = linkDraft else { return nil }
        guard let target = ComposerDocument.composerLink(url) else { return ComposerLinkDraft.problem }
        let shown = text.trimmingCharacters(in: .newlines)
        selection = draft.range
        editor?.select(draft.range)
        let current = (document.string as NSString).substring(with: ComposerDocument.clamp(draft.range, document.length))
        if draft.range.length > 0, shown.isEmpty || shown == current {
            perform(.link(target))
        } else {
            perform(.insertLink(text: shown.isEmpty ? target.replacingOccurrences(of: "mailto:", with: "") : shown, url: target))
        }
        linkDraft = nil
        popover = nil
        editor?.focusEditor()
        return nil
    }

    @MainActor
    func removeLink() {
        guard let draft = linkDraft else { return }
        selection = draft.range
        editor?.select(draft.range)
        if draft.range.length > 0 { perform(.link(nil)) }
        linkDraft = nil
        popover = nil
        editor?.focusEditor()
    }

    // MARK: Quoted original

    /// × on the quote bar (the view registers Undo → `restoreQuote`).
    func removeQuote() {
        guard quote != nil else { return }
        stashedQuote = quote
        quote = nil
        quoteExpanded = false
    }

    func restoreQuote() {
        guard format == .rich, quote == nil, let stashed = stashedQuote else { return }
        quote = stashed
        stashedQuote = nil
    }

    /// "Edit quoted text": the original, read by `MailHTMLReader` (the view does that: the reader isn't part of the
    /// model's compile set), goes to the end of the document as an editable quote block under its attribution line;
    /// the read-only block goes away. Formatting is simplified to what the composer can write.
    func makeQuoteEditable(_ converted: NSAttributedString) {
        guard let original = quote else { return }
        let doc = NSMutableAttributedString(attributedString: document)
        if doc.length > 0, !doc.string.hasSuffix("\n") { doc.append(ComposerDocument.plain("\n", defaults: defaults)) }
        // A reply's attribution line; a forward's "Forwarded message" header (and no quote bar, as Gmail sends it).
        let lead = original.isForward
            ? ([MailAttribution.forwardLine] + original.forwardHeader.map { "\($0.0): \($0.1)" }).joined(separator: "\n") + "\n"
            : original.attribution
        doc.append(ComposerDocument.plain("\n" + lead + "\n", defaults: defaults))
        let body = NSMutableAttributedString(attributedString: ComposerDocument.normalize(converted, defaults: defaults))
        if body.length > 0, !body.string.hasSuffix("\n") { body.append(ComposerDocument.plain("\n", defaults: defaults)) }
        // One quote level deeper for every paragraph (the original's own quotes nest inside).
        let ns = body.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, e, _ in
            guard e.length > 0 else { return }
            let attrs = body.attributes(at: r.length > 0 ? r.location : e.location, effectiveRange: nil)
            let level = min(MailRichText.maxQuote, MailRichText.quoteLevel(attrs[.ycQuoteBlock]) + (original.isForward ? 0 : 1))
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            let indent = MailRichText.indentLevel(style, quote: level - 1)
            body.addAttribute(.paragraphStyle, value: MailRichText.paragraphStyle(base: style, indent: indent, quote: level, lists: style?.textLists ?? []), range: e)
            body.addAttribute(.ycQuoteBlock, value: level, range: e)
            body.removeAttribute(.ycSignature, range: e)
        }
        doc.append(body)
        quote = nil
        stashedQuote = nil
        quoteExpanded = false
        replaceDocument(doc)
    }

    // MARK: Plain text ⇄ rich

    /// Make Plain Text would lose formatting (the view asks first).
    var plainSwitchLosesFormatting: Bool { format == .rich && ComposerDocument.hasFormatting(document, defaults: defaults) }

    /// ⇧⌘T: rich → plain flattens through the writer's text (the reply's `>` quote joins the body, as in today's
    /// composer); plain → rich puts the text in the default font and the original back under the editor.
    func togglePlainText() {
        switch format {
        case .rich:
            let unmarked = NSMutableAttributedString(attributedString: document)
            unmarked.removeAttribute(.ycSignature, range: NSRange(location: 0, length: unmarked.length))
            var text = MailHTMLWriter.text(unmarked, font: writing.font.css, size: writing.size.rawValue)
            if document.length > 0, !document.string.hasSuffix("\n"), text.hasSuffix("\n") { text.removeLast() }
            if let quote { text += "\n" + quote.plainQuote + "\n" }
            stashedQuote = quote ?? stashedQuote
            quote = nil
            quoteExpanded = false
            plainBody = text
            format = .plain
            popover = nil
            linkDraft = nil
        case .plain:
            var text = plainBody
            var restored: QuotedOriginal?
            if let stashed = stashedQuote {
                let suffix = "\n" + stashed.plainQuote + "\n"
                if text.hasSuffix(suffix) {
                    text = String(text.dropLast(suffix.count))
                    restored = stashed
                }
            }
            format = .rich
            quote = restored
            if restored != nil { stashedQuote = nil }
            replaceDocument(documentFromPlain(text))
        }
    }

    /// ⌘↵ / Send. With the switch on and anyone outside your own accounts on the draft, the approval card
    /// comes up instead (every time); otherwise the send is queued: 5 s of "Sending… Undo" before it leaves.
    @MainActor
    func send() async {
        guard phase == .editing, approval == nil else { return }
        switch draft() {
        case .failure(let p):
            problem = p.message
        case .success(let draft):
            problem = nil
            if safeSend, let card = makeApproval(for: draft) {
                approval = card
                Trace.app("mail-send", ["result": "asked", "outside": "\(card.people.count)"])
                return
            }
            await queue(draft)
        }
    }

    /// The card's Send button: ignored for `SendApproval.armDelay` after the card appears (the second
    /// click of a double-click on the draft's Send must not approve it). Return is armed by the key monitor.
    @MainActor
    func approveIfArmed() async {
        guard let card = approval, card.armed(at: clock()) else { return }
        await approveSend()
    }

    /// "Send" on the card (or Return): exactly the addresses it listed are approved, for this send only.
    /// If the draft changed underneath (it can't while the card is up; belt and braces) the card is rebuilt.
    @MainActor
    func approveSend() async {
        guard let card = approval, phase == .editing else { return }
        approval = nil
        switch draft() {
        case .failure(let p):
            problem = p.message
        case .success(var draft):
            guard let current = makeApproval(for: draft), current.outsiders == card.outsiders,
                  current.fromAccount == card.fromAccount else {
                approval = safeSend ? makeApproval(for: draft) : nil
                if approval == nil { await queue(draft) }
                return
            }
            draft.approvedOutside = card.outsiders
            Trace.app("mail-send", ["result": "approved", "outside": "\(card.people.count)"])
            await queue(draft)
        }
    }

    /// "Cancel", Esc or a click outside the card: back to the draft, every field as it was.
    func cancelApproval() {
        guard approval != nil else { return }
        approval = nil
        Trace.app("mail-send", ["result": "not-approved"])
    }

    /// Everyone on the draft who isn't one of your own addresses, To → Cc → Bcc, each once (in the first
    /// field they appear in), with the name the composer knows. Shown at the composer's clock.
    private func makeApproval(for draft: MailDraft) -> SendApproval? {
        let own = ownAddresses
        let names = self.names
        var seen = Set<String>()
        var people: [SendApproval.Person] = []
        for (field, list) in [(SendApproval.Field.to, draft.to), (.cc, draft.cc), (.bcc, draft.bcc)] {
            for address in list.map({ $0.lowercased() }) where !own.contains(address) && seen.insert(address).inserted {
                people.append(SendApproval.Person(address: address, name: names[address], field: field))
            }
        }
        guard !people.isEmpty, let account = accounts.first(where: { $0.id == draft.from }) else { return nil }
        return SendApproval(people: people, fromAccount: account.id, fromTag: account.tag, fromAddress: account.email,
                            subject: draft.subject, shownAt: clock())
    }

    /// Hands the draft to `send`: 5 s of "Sending… Undo" before it leaves.
    @MainActor
    private func queue(_ draft: MailDraft) async {
        phase = .sending(until: clock().addingTimeInterval(MailToastCenter.sendDuration))
        do {
            let token = try await actions().send(draft)
            self.token = token
            sendGeneration += 1
            let generation = sendGeneration
            local.setString(draft.from.uuidString, Self.lastFromKey)
            toasts.show("Sending\u{2026}", duration: MailToastCenter.sendDuration) { [weak self] in await self?.undoSend() }
            schedule(MailToastCenter.sendDuration) { [weak self] in self?.finishSending(generation: generation) }
            Trace.app("mail-send", ["result": "queued"])
        } catch {
            phase = .editing
            problem = Self.friendly(error)
            Trace.app("mail-send", ["result": "refused"])
        }
    }

    /// The 5 s are up: the mail has left; the window closes.
    func finishSending(generation: Int? = nil) {
        guard isSending, token != nil, generation == nil || generation == sendGeneration else { return }
        phase = .sent
        token = nil
        onClose()
    }

    /// Undo within the 5 s: the draft comes back, nothing leaves.
    @MainActor
    func undoSend() async {
        guard isSending, let token else { return }
        self.token = nil
        do {
            try await actions().cancelSend(token)
            phase = .editing
            toasts.dismiss()
            problem = nil
            Trace.app("mail-send", ["result": "undone"])
        } catch {
            // Too late: it has gone.
            phase = .sent
            onClose()
        }
    }

    /// The data layer's refusals (an unapproved outside address, offline…) are already friendly `ServiceError`s.
    static func friendly(_ error: Error) -> String {
        if let e = error as? ServiceError, !e.description.isEmpty, e.description != "not wired" { return e.description }
        return "I couldn\u{2019}t send that. Check your connection and try again; your draft is still here."
    }
}
