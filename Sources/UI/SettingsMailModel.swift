import AppKit

extension Notification.Name {
    /// Settings → Mail turned "Ask before sending to other people" on or off (open composers redraw).
    static let ycAskBeforeSendingChanged = Notification.Name(Profile.scoped("ask-before-sending-changed"))
}

/// Settings → Mail: per account "Primary inbox only" and its signature (Services.mailPreferences), the
/// senders allowed to load images (remove one), and "Ask before sending to other people" (`Labs.safeSend`,
/// D-023: on by default; off, mail goes straight out with the usual 5 s undo).
final class SettingsMailModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: UUID { account.id }
        let account: DirectoryAccount
        var primaryOnly: Bool
        var signature: String
        var savedSignature: String
        /// The rich signature being edited (lazy migration: the plain one in the default font until saved rich).
        var signatureRich = NSAttributedString()
        var savedRichSignature = NSAttributedString()
        /// What's stored (`MailAccountPrefs.signatureRich`), kept when other settings save.
        var savedRichData: Data?
        /// Bumped when the model replaces the editor's text (load, Undo changes).
        var richRevision = 0
        var isDirty: Bool { signature != savedSignature || !RichSignature.same(signatureRich, savedRichSignature) }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var senders: [String] = []
    @Published private(set) var status: String?
    @Published private(set) var failed = false
    /// "Ask before sending to other people".
    @Published private(set) var askBeforeSending: Bool
    /// Settings → Writing (font, size, plain text only, quote style; D-042).
    @Published private(set) var writing: RichMailSettings

    private let prefs: () -> MailPreferencesStore
    private let directory: () -> AccountDirectory
    private let local: MailLocalStore
    let safeSend: () -> Bool
    private let setSafeSend: (Bool) -> Void

    init(prefs: @escaping () -> MailPreferencesStore = { Services.mailPreferences },
         directory: @escaping () -> AccountDirectory = { AccountDirectory.current() },
         local: MailLocalStore = DefaultsMailLocalStore.shared,
         safeSend: @escaping () -> Bool = { Labs.safeSend },
         setSafeSend: @escaping (Bool) -> Void = { Labs.safeSend = $0 }) {
        self.prefs = prefs
        self.directory = directory
        self.local = local
        self.safeSend = safeSend
        self.setSafeSend = setSafeSend
        askBeforeSending = safeSend()
        writing = RichMailSettings(local: local)
    }

    static let askTitle = "Ask before sending to other people"

    func load() {
        let store = prefs()
        rows = directory().accounts.filter(\.mailEnabled).map { account in
            let p = store.prefs(account: account.id)
            let rich = RichSignature.load(p, defaults: writing.documentDefaults)
            return Row(account: account, primaryOnly: p.primaryOnly, signature: p.signature, savedSignature: p.signature,
                       signatureRich: rich, savedRichSignature: rich, savedRichData: p.signatureRich)
        }
        senders = MailImageSenders.list(prefs: store, local: local)
        askBeforeSending = safeSend()
    }

    /// Under the row title. The switch beside it shows on or off, so the line just says what happens.
    var safeSendLine: String {
        askBeforeSending ? "I\u{2019}ll check with you before anything goes to someone other than you."
                         : "Mail goes straight out. You still get 5 seconds to undo."
    }

    /// The switch applies at once: composers read it on every Send, and open ones redraw their footer
    /// (`.ycAskBeforeSendingChanged`).
    func setAskBeforeSending(_ on: Bool) {
        setSafeSend(on)
        askBeforeSending = safeSend()
        NotificationCenter.default.post(name: .ycAskBeforeSendingChanged, object: nil)
    }

    func setPrimaryOnly(_ id: UUID, _ on: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let previous = rows[i].primaryOnly
        rows[i].primaryOnly = on
        do {
            try prefs().save(account: id, MailAccountPrefs(primaryOnly: on, signature: rows[i].savedSignature,
                                                           signatureRich: rows[i].savedRichData))
            say(on ? "\(rows[i].account.tag) now shows Primary only." : "\(rows[i].account.tag) now shows every tab.")
        } catch {
            rows[i].primaryOnly = previous
            say("I couldn\u{2019}t save that. Try again in a moment.", failed: true)
        }
    }

    /// The plain form (the rich editor follows: the text in the default font).
    func editSignature(_ id: UUID, _ text: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].signature = String(text.prefix(2_000))
        rows[i].signatureRich = ComposerDocument.plain(rows[i].signature, defaults: writing.documentDefaults)
        rows[i].richRevision += 1
        status = nil
    }

    /// The rich editor changed; the plain rendition follows (2,000 characters at most).
    func editRichSignature(_ id: UUID, _ rich: NSAttributedString) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].signatureRich = rich
        rows[i].signature = RichSignature.plainText(rich)
        status = nil
    }

    /// Saves both forms: the plain text, and RTFD only when the signature has formatting (a plain one stays lazy).
    /// Over 512 KB is refused.
    func saveSignature(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let data: Data?
        switch RichSignature.storable(rows[i].signatureRich, defaults: writing.documentDefaults) {
        case .failure(let problem):
            say(problem.message, failed: true)
            return
        case .success(let stored):
            data = stored
        }
        do {
            try prefs().save(account: id, MailAccountPrefs(primaryOnly: rows[i].primaryOnly, signature: rows[i].signature,
                                                           signatureRich: data))
            rows[i].savedSignature = rows[i].signature
            rows[i].savedRichSignature = rows[i].signatureRich
            rows[i].savedRichData = data
            say("Saved \(rows[i].account.tag)\u{2019}s signature.")
        } catch {
            say("I couldn\u{2019}t save that signature. Try again in a moment.", failed: true)
        }
    }

    func revertSignature(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].signature = rows[i].savedSignature
        rows[i].signatureRich = rows[i].savedRichSignature
        rows[i].richRevision += 1
    }

    // MARK: Writing (D-042)

    func setWritingFont(_ font: FontChoice) { updateWriting { $0.font = font } }
    func setWritingSize(_ size: SizeChoice) { updateWriting { $0.size = size } }
    func setPlainTextOnly(_ on: Bool) { updateWriting { $0.plainTextOnly = on } }
    func setQuoteStyle(_ style: MailQuoteRequest.Style) { updateWriting { $0.quoteStyle = style } }
    /// "Images from people you've written to" (off by default; the data layer reads the key each time). Off also
    /// forgets everyone it recorded, in every account, after the key is saved off (so a sync finishing now records
    /// nothing behind it); turned on again, it starts empty. Should the clear fail, the engine retries at its next start.
    func setImagesFromCorrespondents(_ on: Bool) {
        updateWriting { $0.imagesFromCorrespondents = on }
        guard !on, let store = prefs() as? MailCorrespondentForgetting else { return }
        do {
            try store.forgetCorrespondents()
        } catch {
            say("I couldn\u{2019}t clear that list just now. I\u{2019}ll clear it the next time I start.", failed: true)
        }
    }

    static let correspondentsTitle = "Images from people you\u{2019}ve written to"
    static let correspondentsLine = "Senders in conversations you\u{2019}ve replied in, and everyone you send to from here."

    /// Applies at once and is read by every composer that opens afterwards.
    private func updateWriting(_ change: (inout RichMailSettings) -> Void) {
        var next = writing
        change(&next)
        guard next != writing else { return }
        next.save(to: local)
        writing = next
    }

    func removeSender(_ sender: String) {
        do {
            try MailImageSenders.remove(sender, prefs: prefs(), local: local)
            senders = MailImageSenders.list(prefs: prefs(), local: local)
            say("Images from \(sender) stay hidden again.")
        } catch {
            say("I couldn\u{2019}t change that. Try again in a moment.", failed: true)
        }
    }

    private func say(_ text: String, failed: Bool = false) {
        status = text
        self.failed = failed
    }
}
