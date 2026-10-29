import AppKit
import Foundation

/// A decoded `widget/<kind>.json` (D-014), mapped once into the shared design models and then resolved
/// for any timeline entry date. The snapshot holds no time-relative text: "in 12 min", "Now", "free
/// after", the highlight, "Last synced …", the effective page and the picked day all come from `now`.
struct SnapshotModel {
    let snapshot: WidgetSnapshot
    /// Accounts by id (UUID string), logos already loaded.
    let accounts: [String: WidgetAccount]
    /// Accounts in the user's order.
    let accountList: [WidgetAccount]
    let meetings: [WidgetMeeting]
    let mail: [WidgetMail]
    /// Entry-independent parts of `data(at:)`, parsed once per snapshot (every entry shares the model).
    let busyDays: Set<String>
    let windowStart: Date?
    let windowEnd: Date?
    let pickedDay: Date?
    let pickedMonth: Date?
    let snapshotDay: Date
    let title: String?
    let health: WidgetHealthInfo

    /// `logo(id)` loads an account's badge; the widget passes `SnapshotModel.logoFile(in: Paths.logos)`.
    init(_ snapshot: WidgetSnapshot, logo: (String) -> NSImage? = SnapshotModel.logoFile(in: Paths.logos)) {
        self.snapshot = snapshot
        var byId: [String: WidgetAccount] = [:]
        var list: [WidgetAccount] = []
        for a in snapshot.accounts {
            let account = WidgetAccount(id: a.id, short: a.tag, name: a.name,
                                        logo: a.hasLogo ? logo(a.id) : nil, color: a.color)
            if byId[a.id] == nil { list.append(account) }
            byId[a.id] = account
        }
        accounts = byId
        accountList = list

        func account(_ id: String?) -> WidgetAccount {
            guard let id else { return WidgetAccount(id: "", short: "", name: "", logo: nil) }
            return byId[id] ?? WidgetAccount(id: id, short: "", name: "", logo: nil)
        }
        meetings = snapshot.meetings.enumerated().map { index, m in
            var meeting = WidgetMeeting(id: index + 1, account: account(m.accountIds.first), title: m.title,
                                        start: m.start, end: max(m.end, m.start), place: m.place,
                                        hasLink: m.hasJoin, reply: Self.reply(m.reply), clashes: m.clashes)
            meeting.r = m.r
            meeting.k = m.k
            meeting.also = m.accountIds.dropFirst().map { account($0) }
            meeting.allDay = m.allDay
            meeting.rec = m.rec ?? false
            meeting.recBy = m.recBy
            return meeting
        }
        mail = snapshot.mail.enumerated().map { index, m in
            var row = WidgetMail(id: index + 1, account: account(m.accountId), sender: m.sender, subject: m.subject,
                                 at: m.at, unread: m.unread)
            row.r = m.r
            row.k = m.k
            row.starred = m.starred
            row.archivedAt = m.archivedAt
            return row
        }
        busyDays = Set(snapshot.busyDays)
        windowStart = DayName.parseDay(snapshot.windowStart)
        windowEnd = DayName.parseDay(snapshot.windowEnd)
        pickedDay = DayName.parseDay(snapshot.selectedDay)
        pickedMonth = DayName.parseMonth(snapshot.monthShown)
        snapshotDay = WidgetCalendar.current.startOfDay(for: snapshot.generatedAt)
        title = snapshot.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        health = Self.health(snapshot, accounts: byId)
    }

    static func reply(_ r: WidgetSnapshot.Meeting.Reply) -> WidgetMeeting.Reply {
        switch r {
        case .accepted: return .accepted
        case .maybe: return .maybe
        case .needsReply: return .needsReply
        }
    }

    /// `<folder>/<id>.png` (LogoStore's naming). Ids that are not plain file names load nothing. Images
    /// come from `LogoCache` (decoded once per file version, not once per timeline).
    static func logoFile(in folder: URL?) -> (String) -> NSImage? {
        { id in
            guard let folder, !id.isEmpty, Route.isSafeValue(id), !id.hasPrefix(".") else { return nil }
            return LogoCache.shared.image(at: folder.appendingPathComponent("\(id).png"))
        }
    }

    // MARK: - Resolution for one entry date

    func style(dark: Bool) -> WidgetStyle { WidgetStyle.from(snapshot.style, dark: dark) }

    /// What the kind draws: the snapshot's content (custom slots carry the Studio choice).
    var content: WidgetContent? {
        switch snapshot.content {
        case .agenda: return .agenda
        case .upNext: return .upNext
        case .month: return .month
        case .inbox: return .inbox
        case .combo: return .combo
        case .day: return .day
        case .setup, .mailComingSoon: return nil
        }
    }

    /// Setup and "mail is off" win over everything (they're about the slot itself); then a
    /// Mac with no accounts; then the design.
    var cardState: WidgetCardState {
        switch snapshot.content {
        case .setup: return .setup
        case .mailComingSoon: return .mailComingSoon
        default: return snapshot.health.state == .noAccounts ? .noAccounts : .content
        }
    }

    /// The page to show: page 1 once `pageResetAt` has passed.
    func page(family: Family, at now: Date) -> Int {
        if let reset = snapshot.pageResetAt, now >= reset { return 1 }
        return max(1, snapshot.pages[family.short] ?? 1)
    }

    /// True once the entry date is on a later day than the snapshot: midnight resets the picked day and
    /// month (the data layer republishes, but entries already scheduled must not wait for it).
    func pastMidnight(_ now: Date) -> Bool {
        WidgetCalendar.current.startOfDay(for: now) > snapshotDay
    }

    /// Month: the picked day; nil (or a new day) = today.
    func selectedDay(at now: Date) -> Date {
        let today = WidgetCalendar.current.startOfDay(for: now)
        guard !pastMidnight(now), let day = pickedDay else { return today }
        return day
    }

    /// Month: the month shown; nil = the picked day's month.
    func monthShown(at now: Date) -> Date {
        if !pastMidnight(now), let month = pickedMonth { return month }
        return selectedDay(at: now)
    }

    static func health(_ snapshot: WidgetSnapshot, accounts: [String: WidgetAccount]) -> WidgetHealthInfo {
        let h = snapshot.health
        var info = WidgetHealthInfo(syncedAt: h.syncedAt, markedStale: h.state == .stale)
        if h.state == .reauth {
            let tag = h.accountId.flatMap { accounts[$0]?.short }.flatMap { $0.isEmpty ? nil : $0 }
            info.reauthTag = tag ?? "An account"
            if let key = WidgetLinkContext.keyed(h.accountId, h.k) {
                info.reauthLink = YayaLink.reauth(a: key.r, k: key.k)
            }
        }
        return info
    }

    /// Mail rows as of `now`: a row archived from a widget shows "Archived · Undo" for 30 s, then goes.
    func mail(at now: Date) -> [WidgetMail] {
        mail.filter { row in row.archivedAt.map { now < $0.addingTimeInterval(MailUndo.window) } ?? true }
    }

    /// When the "Archived · Undo" rows end (timeline entries, so the row leaves without the app).
    var undoEnds: [Date] { mail.compactMap { $0.archivedAt?.addingTimeInterval(MailUndo.window) } }

    func data(at now: Date) -> WidgetData {
        var data = WidgetData(now: now, meetings: meetings, mail: mail(at: now), selectedDay: selectedDay(at: now))
        data.monthShown = monthShown(at: now)
        data.busyDays = busyDays
        data.windowStart = windowStart
        data.windowEnd = windowEnd
        data.rangeDays = [1, 2, 7].contains(snapshot.rangeDays) ? snapshot.rangeDays : 7
        data.title = title
        data.accounts = accountList
        data.health = health
        data.unreadCount = snapshot.unreadCount
        data.content = content
        data.state = cardState
        return data
    }
}

/// Account logos decoded once per file version. A version is the file's identity (inode), size,
/// modification time and status-change time (`stat`, nanoseconds): LogoStore's atomic rewrite makes a
/// new inode, an in-place write moves the modification time, and a modification date put back (a
/// restore, `cp -p`, a sync tool) still moves the status-change time, which no process can set. So a
/// changed logo is read again even at the same size within the same second; an unchanged one is not.
/// The widget extension keeps its process between timelines, so repeat reloads skip the disk and the
/// PNG decode. The images are the files' own pixels (nothing is resized here).
final class LogoCache: @unchecked Sendable {
    static let shared = LogoCache()

    struct Version: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: [Int]
        let changed: [Int]

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = [Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)]
            changed = [Int(info.st_ctimespec.tv_sec), Int(info.st_ctimespec.tv_nsec)]
        }
    }

    private struct Entry {
        let version: Version
        let image: NSImage
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Files decoded so far (tests).
    private(set) var loads = 0

    func image(at url: URL) -> NSImage? {
        let path = url.path
        guard let version = Version(path: path) else {
            lock.lock(); entries[path] = nil; lock.unlock()
            return nil
        }
        lock.lock()
        if let cached = entries[path], cached.version == version {
            lock.unlock()
            return cached.image
        }
        lock.unlock()
        guard let image = NSImage(contentsOf: url) else { return nil }
        lock.lock()
        if entries.count >= 64 { entries.removeAll() }
        entries[path] = Entry(version: version, image: image)
        loads += 1
        lock.unlock()
        return image
    }

    func removeAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
