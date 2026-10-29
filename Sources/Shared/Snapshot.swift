import Foundation

// The app seam (D-014). The data layer writes one file per widget kind, `widget/<kind>.json`; the
// UI layer only reads it (widget extension, the app's gallery and renders). Frozen: change it
// only with a DECISIONS entry and a bumped `version`.
//
// Rules the file obeys (docs/CONTRACTS.md, D-014):
// - No time-relative text. "in 12 min", "free after 4 PM", highlights and "synced 3 min ago" are
//   computed by the widget from the timeline entry's date, so the content hash stays stable.
// - `generatedAt` is excluded from the content hash; the publisher writes atomically and only when
//   the hash changes.
// - Caps: 120 meetings, 96 mail rows, 192 KB per file.
// - No PII in links: every row carries `r` (stable local id) and `k` (link key); the agent resolves
//   join URLs, message ids and addresses from its own database.

struct WidgetSnapshot: Codable, Equatable {
    static let version = 1
    static let maxMeetings = 120
    static let maxMail = 96
    static let maxBytes = 192 * 1024

    var v: Int = WidgetSnapshot.version
    var kind: String
    var generatedAt: Date
    /// What to draw. Custom slots carry the type chosen in Widget Studio.
    var content: Content
    /// Custom slots: the name chosen in Widget Studio ("Work", "ORB only"). Nil = gallery name.
    var title: String?
    var style: Style
    /// Accounts included in this widget, in the user's order (logos: `widget/logos/<id>.png`).
    var accounts: [Account]
    var health: Health

    var meetings: [Meeting]
    var mail: [Mail]
    /// Unread threads across included accounts (Gmail `labels.get INBOX`), nil when the widget shows no mail.
    var unreadCount: Int?

    /// Per family short name ("S", "M", "L", "XL", "XLP") → page. The widget shows page 1 once
    /// `pageResetAt` has passed.
    var pages: [String: Int]
    var pageResetAt: Date?
    /// Month and Day: picked day `YYYY-MM-DD` (nil = today; reset at midnight). Month: month shown `YYYY-MM`.
    var selectedDay: String?
    var monthShown: String?
    /// Month dots: days in the sync window with at least one meeting, `YYYY-MM-DD`.
    var busyDays: [String]
    /// Sync window (Month arrows clamp to it), `YYYY-MM-DD`.
    var windowStart: String
    var windowEnd: String
    /// Agenda range in days (1, 2 or 7).
    var rangeDays: Int

    enum Content: String, Codable {
        case agenda, upNext, month, inbox, combo
        /// One day as an hour grid (D-022). The day shown is `selectedDay` (nil = today).
        case day
        /// Custom slot not configured yet.
        case setup
        /// Mail-backed content while mail is off ("Mail is off", MailOffCopy). The app keeps mail on (D-029);
        /// only the data tests' mail-off seam publishes it.
        case mailComingSoon
    }

    struct Style: Codable, Equatable {
        enum Look: String, Codable { case auto, paper, ink }
        var look: Look = .auto
        var typeface: String = "system"     // system | rounded | serif
        var textSize: String = "standard"   // small | standard | large
        var showLogos = true
        var use24Hour = Style.defaultUse24Hour

        /// What a widget nobody styled uses (`WidgetClockDefaults.refresh()` sets it from the Mac).
        nonisolated(unsafe) static var defaultUse24Hour = false
    }

    struct Account: Codable, Equatable {
        var id: String          // account UUID
        var tag: String         // "ORB", "Personal"
        var name: String
        var color: Int          // 0xRRGGBB
        var hasLogo: Bool
    }

    struct Health: Codable, Equatable {
        enum State: String, Codable { case ok, noAccounts, stale, reauth }
        var state: State = .ok
        /// Account needing attention (reauth), for the amber chip and `yayacal://reauth?a=&k=`.
        var accountId: String?
        var k: String?
        /// Last successful sync; the widget renders it relatively.
        var syncedAt: Date?
    }

    struct Meeting: Codable, Equatable {
        enum Reply: String, Codable { case accepted, maybe, needsReply }
        var r: String               // stable local id (merged invites: the group id)
        var k: String               // link key for r
        var accountIds: [String]    // every account that has it ("ORB+FAM"); first = primary
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var place: String?
        var hasJoin: Bool
        var reply: Reply
        var clashes: Bool
        /// Join with Fathom is offered (D-045): one of its accounts records with Fathom on this Mac. Optional and
        /// left out when nil, so version-1 files without it still decode and unchanged meetings hash the same.
        var rec: Bool? = nil
        /// Which recorder that button joins with (D-046): "murmur" (Yaya's Murmur) or "ask" (the Event Peek's Join menu);
        /// nil = Fathom, as before. Optional and left out when nil, like `rec`.
        var recBy: String? = nil
    }

    struct Mail: Codable, Equatable {
        var r: String               // thread id (local)
        var k: String
        var accountId: String
        var sender: String
        var subject: String
        var at: Date
        var unread: Bool
        var starred: Bool
        /// Set for 30 s after an archive/trash from a widget: the row shows "Archived · Undo"
        /// (`mail/undo?r&k`) until then. Optional, so version-1 files without it still decode.
        var archivedAt: Date? = nil
    }
}

extension WidgetSnapshot {
    static func url(kind: String) -> URL { Paths.widget.appendingPathComponent("\(kind).json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The widget's read. Nil when missing, unreadable or from a newer version.
    static func read(kind: String) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url(kind: kind)),
              let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.v <= version else { return nil }
        return snapshot
    }

    /// Hash of everything except `generatedAt`: the publisher writes only when this changes. FNV-1a
    /// 64 over the sorted-key JSON — stable across launches (Swift's `hashValue` is reseeded per run).
    var contentHash: UInt64 {
        var copy = self
        copy.generatedAt = Date(timeIntervalSince1970: 0)
        guard let data = try? Self.encoder.encode(copy) else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}
