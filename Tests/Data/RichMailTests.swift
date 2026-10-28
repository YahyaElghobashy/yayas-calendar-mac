import Foundation
import SQLite3

/// Rich mail, pure data-side tests: store migration v6, quiet tables,
/// repos, the account cascade, and the seam additions. Cast data only (D-028).
enum RichMailTests {
    static func run() {
        migratesFromV5()
        freshSchemaV6()
        quietTablesMoveNoGeneration()
        attachmentCacheRepo()
        correspondentRepo()
        accountRemovalCascades()
        richSignaturePrefs()
        seamDefaults()
    }

    static let orb = UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!

    /// A v5 database with `mail_prefs` rows opens as v6 with the signature kept, `signature_rich` NULL and the
    /// new tables present; reopening runs nothing twice.
    static func migratesFromV5() {
        let dir = DataTests.folder("richmail-v5")
        let url = dir.appendingPathComponent("store.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { expect(false, "v5 file opens"); return }
        for version in 0..<5 { for sql in AppDatabase.migrations[version] { sqlite3_exec(handle, sql, nil, nil, nil) } }
        sqlite3_exec(handle, "PRAGMA user_version = 5", nil, nil, nil)
        sqlite3_exec(handle, """
            INSERT INTO accounts(id, provider, email, display_name, tag, color, created_at)
            VALUES ('\(orb.uuidString)', 'google', 'avery@orbitalpickle.example', 'Orbital Pickle Co.', 'ORB', 1, 1000)
            """, nil, nil, nil)
        sqlite3_exec(handle, """
            INSERT INTO mail_prefs(account_id, primary_only, signature)
            VALUES ('\(orb.uuidString)', 0, 'Avery' || char(10) || 'Orbital Pickle Co.')
            """, nil, nil, nil)
        sqlite3_exec(handle, "INSERT INTO image_allow(sender) VALUES ('news@quietcomets.example')", nil, nil, nil)
        sqlite3_close(handle)

        guard let db = try? AppDatabase(url: url) else { expect(false, "v5 store migrates"); return }
        expect(db.schemaVersion == 6, "rich mail: v5 → v6")
        let prefs = try? MailRepo(db: db).prefs(accountId: orb)
        expect(prefs?.signature == "Avery\nOrbital Pickle Co." && prefs?.primaryOnly == false, "rich mail: v5 signature kept")
        expect(prefs != nil && prefs?.signatureRich == nil, "rich mail: signature_rich is NULL after the migration")
        expect((try? MailRepo(db: db).allowsImages(sender: "news@quietcomets.example")) == true, "rich mail: v5 image allow list kept")
        let tables = Set((try? db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.string(0) }) ?? [])
        expect(tables.isSuperset(of: ["attachment_cache", "mail_correspondents"]), "rich mail: v6 tables exist")
        let indexes = Set((try? db.query("SELECT name FROM sqlite_master WHERE type = 'index'") { $0.string(0) }) ?? [])
        expect(indexes.contains("attachment_cache_lru"), "rich mail: LRU index exists")
        expect((try? AppDatabase(url: url))?.schemaVersion == 6, "rich mail: reopen stays v6")
    }

    static func freshSchemaV6() {
        let (db, _) = Seed.database("richmail-fresh")
        func columns(_ table: String) -> [String] { (try? db.query("PRAGMA table_info(\(table))") { $0.string(1) }) ?? [] }
        expect(columns("mail_prefs") == ["account_id", "primary_only", "signature", "signature_rich"], "rich mail: mail_prefs columns")
        expect(columns("attachment_cache") == ["account_id", "message_id", "part_id", "file", "bytes", "mime_type", "sha256",
                                               "accessed_at"], "rich mail: attachment_cache columns")
        expect(columns("mail_correspondents") == ["account_id", "address", "last_at"], "rich mail: mail_correspondents columns")
        expect(AppDatabase.quietTables == ["attachment_cache", "mail_correspondents"], "rich mail: quiet tables")
        expect(AppDatabase.quietTables.isDisjoint(with: AppDatabase.mailTables.union(AppDatabase.widgetTables)),
               "rich mail: quiet tables are neither mail nor widget tables")
    }

    static func entry(_ account: UUID, _ message: String, _ part: String, bytes: Int, at: TimeInterval) -> AttachmentCacheEntry {
        AttachmentCacheEntry(accountId: account, messageId: message, partId: part, file: "\(message)-\(part).bin", bytes: bytes,
                             mimeType: "application/pdf", sha256: String(repeating: "a", count: 64),
                             accessedAt: Date(timeIntervalSince1970: at))
    }

    /// Writes to quiet tables move neither write generation; a mail_prefs write still does.
    static func quietTablesMoveNoGeneration() {
        let (db, _) = Seed.database("richmail-quiet")
        let a = Seed.account(db, email: "avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let cache = AttachmentCacheRepo(db: db)
        let people = CorrespondentRepo(db: db)
        let g0 = db.generations
        try? cache.put(entry(a.id, "m1", "2", bytes: 10, at: 100))
        try? cache.put(entry(a.id, "m1", "2", bytes: 12, at: 101))
        try? cache.touch(accountId: a.id, messageId: "m1", partId: "2", at: Date(timeIntervalSince1970: 200))
        try? people.add(accountId: a.id, addresses: ["juniper@vale.example"], at: Date(timeIntervalSince1970: 300))
        try? cache.delete(accountId: a.id, messageId: "m1", partId: "2")
        try? cache.put(entry(a.id, "m2", "3", bytes: 5, at: 400))
        try? cache.deleteAll()
        expect(db.generations == g0, "rich mail: attachment cache and correspondent writes move no generation")
        expect(AppDatabase.writtenTable("INSERT INTO attachment_cache(account_id) VALUES (?)") == "attachment_cache"
               && AppDatabase.writtenTable("UPDATE attachment_cache SET accessed_at = ?") == "attachment_cache"
               && AppDatabase.writtenTable("DELETE FROM mail_correspondents") == "mail_correspondents",
               "rich mail: quiet-table statements are recognised")
        try? MailRepo(db: db).savePrefs(accountId: a.id, MailPrefsRecord(primaryOnly: false, signature: "Avery"))
        let g1 = db.generations
        expect(g1.mail == g0.mail + 1 && g1.calendar == g0.calendar, "rich mail: mail_prefs stays a mail table")
    }

    static func attachmentCacheRepo() {
        let (db, _) = Seed.database("richmail-cache")
        let a = Seed.account(db, email: "avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let repo = AttachmentCacheRepo(db: db)
        try? repo.put(entry(a.id, "m1", "2", bytes: 2_400_000, at: 300))
        try? repo.put(entry(a.id, "m1", "3", bytes: 186_000, at: 100))
        try? repo.put(entry(a.id, "m2", "1.2", bytes: 24_000, at: 200))
        var updated = entry(a.id, "m1", "2", bytes: 2_400_001, at: 350)
        updated.mimeType = "application/zip"
        try? repo.put(updated)
        let got = try? repo.get(accountId: a.id, messageId: "m1", partId: "2")
        expect(got == updated, "rich mail: put replaces the row for (account, message, part)")
        expect((try? repo.get(accountId: a.id, messageId: "m1", partId: "9")) == nil, "rich mail: unknown part → nil")
        expect((try? repo.bytes()) == 2_400_001 + 186_000 + 24_000, "rich mail: bytes sums the index")
        expect((try? repo.files()) == ["m1-2.bin", "m1-3.bin", "m2-1.2.bin"], "rich mail: files lists every row")
        expect((try? repo.oldest(limit: 2))?.map(\.partId) == ["3", "1.2"], "rich mail: oldest = least recently opened first")
        try? repo.touch(accountId: a.id, messageId: "m1", partId: "3", at: Date(timeIntervalSince1970: 999))
        expect((try? repo.oldest(limit: 1))?.first?.partId == "1.2", "rich mail: touch moves a row to the back")
        try? repo.delete(accountId: a.id, messageId: "m2", partId: "1.2")
        expect((try? repo.files()) == ["m1-2.bin", "m1-3.bin"], "rich mail: delete removes one row")
        expect((try? repo.deleteAll()) == 2 && (try? repo.bytes()) == 0, "rich mail: deleteAll clears the index")
    }

    static func correspondentRepo() {
        let (db, _) = Seed.database("richmail-people")
        let a = Seed.account(db, email: "avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let b = Seed.account(db, email: "avery@moonfield-family.example", tag: "FAM", sort: 1)
        let repo = CorrespondentRepo(db: db)
        let n = (try? repo.add(accountId: a.id, addresses: [" Juniper@Vale.example ", "juniper@vale.example", "not an address",
                                                             "@vale.example", "milo@", "priya@starling.example"],
                               at: Date(timeIntervalSince1970: 500))) ?? -1
        expect(n == 2, "rich mail: add trims, lowercases, dedupes and skips invalid addresses")
        expect((try? repo.contains("JUNIPER@vale.example")) == true, "rich mail: contains ignores case")
        expect((try? repo.contains("juniper@vale.example", accountId: a.id)) == true
               && (try? repo.contains("juniper@vale.example", accountId: b.id)) == false, "rich mail: contains per account")
        expect((try? repo.contains("theo@quill.example")) == false && (try? repo.contains("nope")) == false,
               "rich mail: unknown and invalid addresses are not correspondents")
        try? repo.add(accountId: a.id, addresses: ["juniper@vale.example"], at: Date(timeIntervalSince1970: 100))
        let last = (try? db.query("SELECT last_at FROM mail_correspondents WHERE address = 'juniper@vale.example'") { $0.double(0) })?.first
        expect(last == 500, "rich mail: an older sighting keeps the newest last_at")
        try? repo.add(accountId: a.id, addresses: ["juniper@vale.example"], at: Date(timeIntervalSince1970: 900))
        let newer = (try? db.query("SELECT last_at FROM mail_correspondents WHERE address = 'juniper@vale.example'") { $0.double(0) })?.first
        expect(newer == 900, "rich mail: a newer sighting moves last_at")
    }

    /// Removing an account removes its attachment rows and correspondents (FK cascade).
    static func accountRemovalCascades() {
        let (db, _) = Seed.database("richmail-cascade")
        let a = Seed.account(db, email: "avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let b = Seed.account(db, email: "avery@home.example", tag: "Personal", sort: 1)
        let cache = AttachmentCacheRepo(db: db)
        try? cache.put(entry(a.id, "m1", "2", bytes: 10, at: 1))
        try? cache.put(entry(b.id, "m9", "2", bytes: 20, at: 2))
        try? CorrespondentRepo(db: db).add(accountId: a.id, addresses: ["juniper@vale.example"], at: Date(timeIntervalSince1970: 1))
        try? MailRepo(db: db).savePrefs(accountId: a.id, MailPrefsRecord(primaryOnly: false, signature: "Avery", signatureRich: "cnRmZA=="))
        _ = try? AccountRepo(db: db).delete(a.id)
        expect((try? cache.files()) == ["m9-2.bin"], "rich mail: account removal cascades its attachment rows only")
        expect((try? CorrespondentRepo(db: db).contains("juniper@vale.example")) == false, "rich mail: correspondents cascade")
        expect((try? MailRepo(db: db).prefs(accountId: a.id)) == nil, "rich mail: prefs (with signature_rich) cascade")
    }

    /// `mail_prefs.signature_rich` through the repo, and `MailAccountPrefs.signatureRich` (RTFD bytes) through the
    /// mail store as base64 text.
    static func richSignaturePrefs() {
        let (db, dir) = Seed.database("richmail-signature")
        let a = Seed.account(db, email: "avery@orbitalpickle.example", tag: "ORB", sort: 0)
        let repo = MailRepo(db: db)
        try? repo.savePrefs(accountId: a.id, MailPrefsRecord(primaryOnly: true, signature: "Avery", signatureRich: "AAEC"))
        expect((try? repo.prefs(accountId: a.id)) == MailPrefsRecord(primaryOnly: true, signature: "Avery", signatureRich: "AAEC"),
               "rich mail: signature_rich round-trips through MailRepo")
        try? repo.savePrefs(accountId: a.id, MailPrefsRecord(primaryOnly: true, signature: "Avery"))
        expect((try? repo.prefs(accountId: a.id))?.signatureRich == nil, "rich mail: saving without a rich signature clears it")

        let store = LocalMailStore(db: db, cacheDirectory: dir.appendingPathComponent("mailcache"), now: { Date(timeIntervalSince1970: 0) })
        let rtfd = Data([0x72, 0x74, 0x66, 0x64, 0x00, 0xFF, 0x10])
        do {
            try store.save(account: a.id, MailAccountPrefs(primaryOnly: true, signature: "Avery\nOrbital Pickle Co.", signatureRich: rtfd))
        } catch {
            expect(false, "rich mail: prefs with a rich signature save (\(error))")
        }
        let back = store.prefs(account: a.id)
        expect(back.signatureRich == rtfd && back.signature == "Avery\nOrbital Pickle Co.",
               "rich mail: MailAccountPrefs.signatureRich round-trips through the mail store")
        expect((try? repo.prefs(accountId: a.id))?.signatureRich == rtfd.base64EncodedString(), "rich mail: stored as base64 text")
        try? store.save(account: a.id, MailAccountPrefs(primaryOnly: true, signature: "Avery"))
        expect(store.prefs(account: a.id).signatureRich == nil, "rich mail: prefs without signatureRich store NULL")
    }

    /// Every addition is defaulted, so existing initializers compile and mean what they meant.
    static func seamDefaults() {
        let attachment = MailMessage.Attachment(name: "Launch plan.pdf", bytes: 2_400_000)
        expect(attachment.id == "" && attachment.mimeType == "" && attachment.contentId == nil && !attachment.isInline,
               "rich mail: Attachment(name:bytes:) defaults")
        let message = MailMessage(id: "m1", from: "Priya Starling", fromEmail: "priya@starling.example", to: [], cc: [],
                                  date: Date(timeIntervalSince1970: 0), subject: "Q4 pickle launch plan", html: nil, text: "Hi",
                                  hasRemoteImages: false, attachments: [attachment])
        expect(!message.isPlainText, "rich mail: MailMessage.isPlainText defaults to false")
        let draft = MailDraft(from: orb, to: ["juniper@vale.example"], subject: "Labels", body: "Hi\n", replyTo: nil)
        expect(draft.html == nil && draft.attachments.isEmpty && draft.quote == nil && !draft.signatureIncluded
               && draft.approvedOutside.isEmpty, "rich mail: MailDraft additions default to plain, no files, no quote")
        let quote = MailQuoteRequest(threadR: "rm-gmail-reply", messageId: "m1", kind: .forward)
        expect(quote.style == .bar && quote.kind.rawValue == "forward", "rich mail: MailQuoteRequest defaults to the bar style")
        expect(MailAccountPrefs(primaryOnly: false, signature: "").signatureRich == nil, "rich mail: MailAccountPrefs default")
    }
}
