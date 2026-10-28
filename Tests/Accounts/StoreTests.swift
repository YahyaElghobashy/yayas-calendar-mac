import Foundation

enum StoreTests {
    static func run() {
        migrationsFromEmpty()
        crud()
        reorder()
        settingsAndTransactions()
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    static func record(_ email: String, tag: String, sort: Int = 0, created: TimeInterval = 1_000) -> AccountRecord {
        AccountRecord(id: UUID(), provider: "google", email: email, displayName: tag, tag: tag, color: 0x8FB4C4,
                      logoFile: nil, sortOrder: sort, createdAt: Date(timeIntervalSince1970: created))
    }

    static func migrationsFromEmpty() {
        let dir = AccountsTests.folder("store-migrate").appendingPathComponent("nested/YayasCalendar", isDirectory: true)
        let url = dir.appendingPathComponent("store.sqlite")
        guard let db = try? AppDatabase(url: url) else { expect(false, "store opens on an empty folder"); return }
        expect(db.schemaVersion == AppDatabase.migrations.count, "user_version = number of migrations")
        let tables = (try? db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { $0.string(0) }) ?? []
        expect(Set(tables).isSuperset(of: ["accounts", "settings"]), "accounts + settings tables exist")
        let columns = (try? db.query("PRAGMA table_info(accounts)") { $0.string(1) }) ?? []
        expect(columns == ["id", "provider", "email", "display_name", "tag", "color", "logo_file", "include_in_all",
                           "mail_enabled", "calendar_enabled", "sort_order", "health", "health_detail", "created_at"],
               "accounts columns match the contract")
        let journal = (try? db.query("PRAGMA journal_mode") { $0.string(0) })?.first
        expect(journal == "wal", "WAL journal")
        try? AccountRepo(db: db).insert(record("a@x.example", tag: "XA"))
        expect(mode(url) == 0o600, "store file is 0600")
        expect(mode(URL(fileURLWithPath: url.path + "-wal")) == 0o600, "WAL file is 0600")
        expect(mode(dir) == 0o700, "store folder is 0700")

        // Reopening runs no migration twice and keeps the data.
        guard let again = try? AppDatabase(url: url) else { expect(false, "store reopens"); return }
        expect(again.schemaVersion == AppDatabase.migrations.count, "reopen keeps user_version")
        expect((try? AccountRepo(db: again).count()) == 1, "reopen keeps rows")

        // An existing file with loose permissions is tightened.
        let loose = AccountsTests.folder("store-loose").appendingPathComponent("store.sqlite")
        FileManager.default.createFile(atPath: loose.path, contents: nil, attributes: [.posixPermissions: 0o644])
        _ = try? AppDatabase(url: loose)
        expect(mode(loose) == 0o600, "existing 0644 store tightened to 0600")
    }

    static func crud() {
        guard let db = try? AppDatabase(url: AccountsTests.folder("store-crud").appendingPathComponent("s.sqlite")) else {
            expect(false, "crud store opens"); return
        }
        let repo = AccountRepo(db: db)
        var a = record("one@orb.example", tag: "ORB", sort: 0, created: 100)
        a.color = 0xD2A6C6
        a.logoFile = "\(a.id.uuidString).png"
        a.includeInAll = false
        a.calendarEnabled = false
        a.health = .reauthNeeded
        a.healthDetail = "Sign in again"
        let b = record("two@cmt.example", tag: "CMT", sort: 1, created: 50)
        expect((try? repo.insert(a)) != nil && (try? repo.insert(b)) != nil, "insert two rows")
        expect((try? repo.insert(a)) == nil, "duplicate id rejected")
        expect((try? repo.get(a.id)) == a, "get round-trips every column (bools, colour, nulls, date)")
        expect((try? repo.all())?.map(\.tag) == ["ORB", "CMT"], "all() orders by sort_order")
        expect((try? repo.count()) == 2, "count")

        var changed = b
        changed.displayName = "The Quiet Comets"
        changed.mailEnabled = false
        changed.logoFile = nil
        expect((try? repo.update(changed)) == true, "update existing row")
        expect((try? repo.get(b.id))?.displayName == "The Quiet Comets" && (try? repo.get(b.id))?.mailEnabled == false,
               "update persisted")
        expect((try? repo.update(record("ghost@x.example", tag: "G"))) == false, "update of missing row reports false")

        expect((try? repo.setHealth(b.id, .adminBlocked, detail: "Blocked by your admin")) == true, "setHealth")
        let blocked = try? repo.get(b.id)
        expect(blocked?.health == .adminBlocked && blocked?.healthDetail == "Blocked by your admin", "health persisted")
        _ = try? repo.setHealth(b.id, .ok, detail: nil)
        expect((try? repo.get(b.id))?.healthDetail == nil, "health detail cleared")

        _ = try? db.run("UPDATE accounts SET health = 'mystery' WHERE id = ?", [b.id.uuidString])
        expect((try? repo.get(b.id))?.health == .unknown, "unknown stored health reads as .unknown")

        expect((try? repo.delete(a.id)) == true, "delete")
        expect((try? repo.delete(a.id)) == false, "delete twice reports false")
        expect((try? repo.get(a.id)) == nil, "deleted row is gone")
    }

    static func reorder() {
        guard let db = try? AppDatabase(url: AccountsTests.folder("store-order").appendingPathComponent("s.sqlite")) else {
            expect(false, "order store opens"); return
        }
        let repo = AccountRepo(db: db)
        expect((try? repo.nextSortOrder()) == 0, "nextSortOrder on empty table")
        let rows = ["A", "B", "C", "D"].enumerated().map { record("\($0.element)@x.example", tag: $0.element, sort: $0.offset) }
        rows.forEach { try? repo.insert($0) }
        expect((try? repo.nextSortOrder()) == 4, "nextSortOrder after four rows")
        func tags() -> [String] { (try? repo.all())?.map(\.tag) ?? [] }

        try? repo.reorder([rows[2].id, rows[0].id])
        expect(tags() == ["C", "A", "B", "D"], "reorder puts listed ids first, keeps the rest in order")
        expect((try? repo.all())?.map(\.sortOrder) == [0, 1, 2, 3], "reorder renumbers 0…n-1")
        try? repo.reorder([UUID(), rows[3].id, rows[3].id])
        expect(tags() == ["D", "C", "A", "B"], "reorder ignores unknown and repeated ids")

        _ = try? repo.move(rows[1].id, by: -1)
        expect(tags() == ["D", "C", "B", "A"], "move up one")
        _ = try? repo.move(rows[3].id, by: -1)
        expect(tags() == ["D", "C", "B", "A"], "move up at the top is clamped")
        _ = try? repo.move(rows[3].id, by: 10)
        expect(tags() == ["C", "B", "A", "D"], "move far down is clamped to the end")
    }

    static func settingsAndTransactions() {
        guard let db = try? AppDatabase(url: AccountsTests.folder("store-settings").appendingPathComponent("s.sqlite")) else {
            expect(false, "settings store opens"); return
        }
        expect((try? db.setting("missing")) == nil, "missing setting is nil")
        try? db.setSetting("look", "ink")
        try? db.setSetting("look", "paper")
        expect((try? db.setting("look")) == "paper", "setting upserts")
        expect((try? db.removeSetting("look")) == true && (try? db.setting("look")) == nil, "setting removed")

        struct Boom: Error {}
        let repo = AccountRepo(db: db)
        _ = try? db.transaction {
            try repo.insert(record("t@x.example", tag: "T"))
            throw Boom()
        }
        expect((try? repo.count()) == 0, "a throwing transaction rolls back")

        let kept = record("kept@x.example", tag: "K")
        let dropped = record("dropped@x.example", tag: "D")
        _ = try? db.transaction {
            try repo.insert(kept)
            _ = try? db.transaction {
                try repo.insert(dropped)
                throw Boom()
            }
        }
        expect((try? repo.get(kept.id)) != nil && (try? repo.get(dropped.id)) == nil,
               "nested transaction is a savepoint: inner rollback keeps the outer work")
    }
}
