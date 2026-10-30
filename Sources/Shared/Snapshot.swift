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
    /// Daily Digest (D-053): Yaya's Mail Helper's latest digest, one box per mailbox. Nil on every other kind, and on
    /// the digest kind while the helper has none; optional and left out when nil, so older files decode and hash the same.
    var digest: Digest? = nil
    /// Daily Digest (D-054): Model Atlas's weekly report, one more box after the mailboxes. Nil when its file is missing
    /// (and on every other kind); optional and left out when nil, like `digest`.
    var atlas: Atlas? = nil

    enum Content: String, Codable {
        case agenda, upNext, month, inbox, combo
        /// One day as an hour grid (D-022). The day shown is `selectedDay` (nil = today).
        case day
        /// Custom slot not configured yet.
        case setup
        /// Mail-backed content while mail is off ("Mail is off", MailOffCopy). The app keeps mail on (D-029);
        /// only the data tests' mail-off seam publishes it.
        case mailComingSoon
        /// Daily Digest (D-053): `digest` carries it; nil = the helper is installed but has no digest yet.
        case digest
        /// Daily Digest while Yaya's Mail Helper isn't on this Mac (DigestCopy).
        case mailHelperOff
    }

    /// Model Atlas's weekly report on the Daily Digest (D-054): not mail, so it never adds to the unread badge. "Week of
    /// …" and the dimming after eight days come from `report` and the entry date.
    struct Atlas: Codable, Equatable {
        static let maxLines = 5
        static let maxAlerts = 3

        /// `YYYY-MM-DD` of the report the lines come from; nil = none yet.
        var report: String?
        var lines: [Line]
        /// What the scan found on its own (a node not reached, backups growing); shown first.
        var alerts: [String]
        /// Models across the owner's machines; nil when the feed has none.
        var models: Int? = nil
        /// Not opened since this report arrived: the box's "New" mark. `true` or left out.
        var fresh: Bool? = nil

        struct Line: Codable, Equatable {
            /// Plain text, already led by its word ("New:", "Try:", "Waiting on you:"…).
            var text: String
            /// That word in lower case, or "" (a display hint only).
            var kind: String
        }
    }

    /// The Daily Digest (D-053), as the app distils it from the helper's `digest.json` and its accounts. No
    /// time-relative text: "Today" and "Yesterday" come from `day` and the entry date. Unread counts come from `read`.
    struct Digest: Codable, Equatable {
        static let maxBoxes = 12
        static let maxSections = 8
        static let maxLines = 3
        static let maxText = 140

        var id: Int
        /// `YYYY-MM-DD`, the day the digest covers.
        var day: String
        /// Emails in the digest (the helper's count).
        var total: Int
        var sections: [Section]
        /// One per mailbox the helper has, in the calendar's account order (empty boxes included).
        var boxes: [Box]

        struct Section: Codable, Equatable {
            /// The helper's key (`[A-Za-z0-9_-]{1,64}`), also the `part` of the tap.
            var key: String
            var title: String
            var count: Int
            var read: Bool
        }

        struct Box: Codable, Equatable {
            /// The account's UUID string: `accounts` carries its tag, name and logo when the calendar has it.
            var account: String
            /// What to call a mailbox the calendar doesn't know (the helper's address for it); nil otherwise.
            var label: String? = nil
            /// Section key → this mailbox's items in it.
            var counts: [String: Int]
            /// Up to 3 lines: summaries' headlines (worth opening first), then subjects, unread sections first.
            var top: [Line]
        }

        struct Line: Codable, Equatable {
            var text: String
            var section: String
            /// The helper marked it worth opening; `true` or left out.
            var pick: Bool? = nil
        }
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
        /// Yaya's Murmur marked this meeting Live Helper and it has a join link (D-048): Up Next Medium's button joins
        /// with Live Helper. `true` or left out, like `rec`.
        var lh: Bool? = nil
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
