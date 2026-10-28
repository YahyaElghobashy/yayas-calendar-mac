import Foundation

// Notifications without UserNotifications: what to show and when, decided by pure code the data
// tests check, then handed to `NoteCenter` (the app's UNUserNotificationCenter adapter, a fake in
// tests). Nothing here logs titles, names, addresses or URLs.

/// One local notification as the app builds it.
struct LocalNote: Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var category: String
    /// Groups related notes in Notification Center (one meeting, one account's mail).
    var thread: String
    /// The intended moment. Nil = show now.
    var fireAt: Date?
    /// How the system should fire it (nil = now).
    var trigger: NoteTrigger?
    /// Only short ids and epochs, never URLs, addresses or titles (the Join action re-reads the store).
    var userInfo: [String: String]
    var sound = true

    /// Stable digest of everything the user sees plus the trigger: a pending request whose fingerprint
    /// matches is left alone, anything else is replaced under the same id.
    var fingerprint: String {
        var text = "\(id)\u{1F}\(title)\u{1F}\(body)\u{1F}\(category)\u{1F}\(thread)\u{1F}\(sound)"
        text += "\u{1F}" + (fireAt.map { String(Int64(($0.timeIntervalSince1970).rounded())) } ?? "now")
        text += "\u{1F}" + (trigger?.signature ?? "none")
        for key in userInfo.keys.sorted() { text += "\u{1F}\(key)=\(userInfo[key] ?? "")" }
        return NotifyHash.fnv(text)
    }
}

/// How the system fires a note.
enum NoteTrigger: Equatable, Sendable {
    /// Wall-clock components (year…second) in the Mac's calendar, with its time zone attached.
    case calendar(DateComponents)
    /// Seconds after it is added: used when the local wall time is ambiguous or skipped (DST), and
    /// for snoozes.
    case interval(TimeInterval)

    var signature: String {
        switch self {
        case .calendar(let c):
            let parts = [c.year, c.month, c.day, c.hour, c.minute, c.second].map { $0.map(String.init) ?? "-" }
            return "cal:" + parts.joined(separator: ".") + "@" + (c.timeZone?.identifier ?? "-")
        case .interval:
            // The absolute moment is `LocalNote.fireAt` (also fingerprinted): seconds-from-now would
            // change on every refresh and churn the request.
            return "int"
        }
    }

    /// The trigger for an absolute instant. Calendar components in the Mac's own calendar and zone
    /// (what UNCalendarNotificationTrigger documents), unless that wall time names a different
    /// instant — the repeated hour when DST ends (London, 25 Oct 2026) or the skipped hour when it starts
    /// — then a plain interval from `now`, which is immune to wall-clock games.
    static func at(_ fire: Date, now: Date, calendar: Calendar) -> NoteTrigger {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        if let back = calendar.date(from: components), abs(back.timeIntervalSince(fire)) < 1 {
            return .calendar(components)
        }
        return .interval(max(1, fire.timeIntervalSince(now).rounded()))
    }
}

/// A request already waiting in the system.
struct PendingNote: Equatable, Sendable {
    var id: String
    var fingerprint: String?
    /// From userInfo "fire" (epoch seconds).
    var fireAt: Date?
}

/// Notification permission as the system reports it (no prompt).
enum NoteAuth: Equatable, Sendable { case authorized, denied, notDetermined }

/// UNUserNotificationCenter behind a protocol (the data tests never post a real notification).
protocol NoteCenter: AnyObject, Sendable {
    /// Where permission stands, without asking.
    func authorizationStatus() async -> NoteAuth
    /// Shows the system prompt (alert + sound) when undecided; returns once the user answered, which
    /// can be never — callers don't wait on it.
    func authorize() async -> Bool
    /// This app's pending requests; nil when the system didn't answer in time (skip that plan).
    func pending() async -> [PendingNote]?
    /// Adds or replaces (same id) one request.
    func add(_ note: LocalNote) async throws
    func removePending(_ ids: [String]) async
    func removeDelivered(_ ids: [String]) async
}

/// The user's notification settings (UserDefaults in the app, memory in tests).
protocol NotifyPrefs: AnyObject, Sendable {
    /// Meeting heads-up, default ON.
    var meetingsOn: Bool { get }
    /// New-mail notices, default OFF.
    var newMailOn: Bool { get }
    /// "Pause notifications 1 h": nothing new shows before this moment.
    var pausedUntil: Date? { get }
    func reauthSentAt(_ account: UUID) -> Date?
    func setReauthSent(_ account: UUID, at date: Date)
    func clearReauthSent(_ account: UUID)
    /// Accounts with a re-auth stamp (a notice may still sit in Notification Center).
    func reauthStamped() -> [UUID]
    /// New-mail watermark: the newest inbox thread time already accounted for.
    func mailSeen(_ account: UUID) -> Date?
    func setMailSeen(_ account: UUID, _ date: Date)
}

extension NotifyPrefs {
    func isPaused(at now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }
}

/// UserDefaults keys (the app's own domain). `pausedUntil` is a Date; a number is read as epoch seconds,
/// so another surface (the popover) may write either. Writers other than `Notifier.pause/resume`
/// are picked up through UserDefaults.didChangeNotification.
enum NotifyKeys {
    static let meetings = "notifications.meetings"
    static let newMail = "notifications.newMail"
    static let pausedUntil = "notifications.pausedUntil"
    static let reauthSent = "notifications.reauthSent"
    static let mailSeen = "notifications.mailSeen"
}

/// Identifiers shared by the planner and the app's UNUserNotificationCenter adapter.
enum NoteIds {
    static let meetingPrefix = "meet-"
    static let snoozePrefix = "snooze-"
    static let reauthPrefix = "reauth-"
    static let mailPrefix = "mail-"

    static let meetingCategory = "yc.meeting"
    /// Same, plus Join with Fathom (D-045): one of the meeting's accounts records with Fathom.
    static let meetingFathomCategory = "yc.meeting.fathom"
    /// Same, without Join (no allowlisted link).
    static let meetingNoLinkCategory = "yc.meeting.nolink"
    static let reauthCategory = "yc.reauth"
    static let mailCategory = "yc.mail"

    static let joinAction = "yc.join"
    static let fathomAction = "yc.join.fathom"
    static let snoozeAction = "yc.snooze"
    static let fixAction = "yc.fix"

    /// Row ids are "g"/"e" + 22 base64url characters; anything else in a notification's userInfo is
    /// ignored.
    static func isSafeRowId(_ r: String) -> Bool {
        !r.isEmpty && r.count <= 64 && r.unicodeScalars.allSatisfy { s in
            (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "-" || s == "_"
        }
    }
}

/// UserDefaults-backed settings (the app). Keys: `NotifyKeys`.
final class DefaultsNotifyPrefs: NotifyPrefs, @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var meetingsOn: Bool {
        get { defaults.object(forKey: NotifyKeys.meetings) as? Bool ?? true }
        set { defaults.set(newValue, forKey: NotifyKeys.meetings) }
    }

    var newMailOn: Bool {
        get { defaults.object(forKey: NotifyKeys.newMail) as? Bool ?? false }
        set { defaults.set(newValue, forKey: NotifyKeys.newMail) }
    }

    var pausedUntil: Date? {
        get { Self.date(defaults.object(forKey: NotifyKeys.pausedUntil)) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: NotifyKeys.pausedUntil)
            } else {
                defaults.removeObject(forKey: NotifyKeys.pausedUntil)
            }
        }
    }

    /// A stored moment: a Date, or a number of epoch seconds.
    static func date(_ value: Any?) -> Date? {
        switch value {
        case let date as Date: return date
        case let number as NSNumber: return Date(timeIntervalSince1970: number.doubleValue)
        default: return nil
        }
    }

    func reauthSentAt(_ account: UUID) -> Date? { stamp(NotifyKeys.reauthSent, account) }
    func setReauthSent(_ account: UUID, at date: Date) { setStamp(NotifyKeys.reauthSent, account, date) }
    func reauthStamped() -> [UUID] {
        (defaults.dictionary(forKey: NotifyKeys.reauthSent) ?? [:]).keys.compactMap(UUID.init(uuidString:))
    }

    func clearReauthSent(_ account: UUID) {
        var map = defaults.dictionary(forKey: NotifyKeys.reauthSent) ?? [:]
        map[account.uuidString] = nil
        defaults.set(map, forKey: NotifyKeys.reauthSent)
    }
    func mailSeen(_ account: UUID) -> Date? { stamp(NotifyKeys.mailSeen, account) }
    func setMailSeen(_ account: UUID, _ date: Date) { setStamp(NotifyKeys.mailSeen, account, date) }

    private func stamp(_ key: String, _ account: UUID) -> Date? {
        Self.date(defaults.dictionary(forKey: key)?[account.uuidString])
    }

    private func setStamp(_ key: String, _ account: UUID, _ date: Date) {
        var map = defaults.dictionary(forKey: key) ?? [:]
        map[account.uuidString] = date.timeIntervalSince1970
        defaults.set(map, forKey: key)
    }
}

enum NotifyHash {
    /// FNV-1a 64, hex: stable across launches (Swift's `hashValue` is reseeded per run).
    static func fnv(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
