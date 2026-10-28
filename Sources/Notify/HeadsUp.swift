import Foundation

/// Meeting heads-up rules (D-020): a local notification 60 s before every upcoming meeting in
/// the next 24 h that is not declined, not all-day, and has a join link or at least two attendees.
/// Merged invites (one group id across accounts) notify once; so do copies Google didn't merge (same
/// start, same join link). Ids are `meet-<r>-<epoch start>`, so a restart, a re-sync or a moved meeting
/// replaces or removes the request instead of adding a second one.
enum HeadsUp {
    static let lead: TimeInterval = 60
    static let horizon: TimeInterval = 24 * 3600
    static let snoozeDelay: TimeInterval = 60
    /// Apple keeps at most 64 pending requests per app: 60 heads-ups, 4 slots for snoozes. Meetings past
    /// the cap are planned later: each pass wakes the coordinator again at the next fire time.
    static let maxScheduled = 60

    struct Context {
        var now: Date
        var calendar: Calendar
        var locale: Locale
        var meetingsOn: Bool
        var pausedUntil: Date?
        /// Account id → tag ("ORB"), for "ORB+FAM".
        var tags: [UUID: String]
        /// Whether a meeting on these accounts gets Join with Fathom (D-045; the app's link settings).
        var fathom: @Sendable ([UUID]) -> Bool = { _ in false }
    }

    /// What one refresh does to the pending requests.
    struct Plan: Equatable {
        var add: [LocalNote] = []
        var remove: [String] = []
        var unchanged = 0
    }

    // MARK: Rules

    static func isEligible(_ e: CalendarEvent) -> Bool {
        guard !e.allDay, e.myResponse != .declined, e.end >= e.start else { return false }
        return JoinGuard.isAllowed(e.joinURL) || e.attendees.count >= 2
    }

    /// `<r>-<epoch start>`: one meeting occurrence at one start time.
    static func key(_ e: CalendarEvent) -> String { "\(e.r)-\(epoch(e.start))" }
    static func id(_ e: CalendarEvent) -> String { NoteIds.meetingPrefix + key(e) }
    static func snoozeId(key: String) -> String { NoteIds.snoozePrefix + key }

    static func epoch(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded()) }

    /// Heads-ups and snoozes (what this planner owns, and what quitting withdraws).
    static func isManaged(_ id: String) -> Bool {
        id.hasPrefix(NoteIds.meetingPrefix) || id.hasPrefix(NoteIds.snoozePrefix)
    }

    /// When to plan again: just after the soonest heads-up fires (a slot frees up for a meeting past
    /// the cap). Nil when nothing is scheduled.
    static func nextWake(_ desired: [LocalNote], now: Date) -> Date? {
        desired.compactMap(\.fireAt).filter { $0 > now }.min().map { $0.addingTimeInterval(1) }
    }

    /// One entry per meeting: by group id first, then by (start, join link) for separate invites to the
    /// same call. Input order wins (the store sorts by start, primary account first).
    static func dedupe(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var seenR = Set<String>()
        var seenCall = Set<String>()
        var out: [CalendarEvent] = []
        for e in events {
            guard seenR.insert(e.r).inserted else { continue }
            if let url = e.joinURL, JoinGuard.isAllowed(url) {
                guard seenCall.insert("\(epoch(e.start))|\(url.absoluteString.lowercased())").inserted else { continue }
            }
            out.append(e)
        }
        return out
    }

    /// The requests that should be pending right now.
    static func desired(_ events: [CalendarEvent], _ c: Context) -> [LocalNote] {
        guard c.meetingsOn else { return [] }
        let horizonEnd = c.now.addingTimeInterval(horizon)
        let upcoming = dedupe(events.filter(isEligible)).filter { $0.start > c.now && $0.start <= horizonEnd }
        var out: [LocalNote] = []
        for e in upcoming.sorted(by: { $0.start != $1.start ? $0.start < $1.start : $0.r < $1.r }) {
            let fire = e.start.addingTimeInterval(-lead)
            guard fire > c.now else { continue }
            if let paused = c.pausedUntil, fire < paused { continue }
            out.append(note(e, fire: fire, snooze: false, c))
            if out.count == maxScheduled { break }
        }
        return out
    }

    /// Keys of meetings that may still hold a snooze (eligible, not over).
    static func liveKeys(_ events: [CalendarEvent], _ c: Context) -> Set<String> {
        guard c.meetingsOn else { return [] }
        return Set(dedupe(events.filter(isEligible)).filter { $0.end > c.now }.map(key))
    }

    /// Diff against what the system holds: replace changed requests, add missing ones, remove meeting
    /// requests nobody wants anymore and snoozes whose meeting is gone, declined, over or paused.
    static func plan(desired: [LocalNote], pending: [PendingNote], liveKeys: Set<String>, pausedUntil: Date?) -> Plan {
        var plan = Plan()
        let wanted = Dictionary(desired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var held: [String: PendingNote] = [:]
        for p in pending { held[p.id] = p }
        for p in pending {
            if p.id.hasPrefix(NoteIds.meetingPrefix), wanted[p.id] == nil {
                plan.remove.append(p.id)
            } else if p.id.hasPrefix(NoteIds.snoozePrefix) {
                let key = String(p.id.dropFirst(NoteIds.snoozePrefix.count))
                let paused = pausedUntil.map { pause in (p.fireAt ?? .distantPast) < pause } ?? false
                if !liveKeys.contains(key) || paused { plan.remove.append(p.id) }
            }
        }
        for note in desired {
            if let p = held[note.id], p.fingerprint == note.fingerprint {
                plan.unchanged += 1
            } else {
                plan.add.append(note)
            }
        }
        plan.remove.sort()
        return plan
    }

    // MARK: Content

    /// "In 1 minute · 10:00 AM · Google Meet · ORB+FAM". Snoozes say "Starting now" / "Started 2 min ago".
    static func note(_ e: CalendarEvent, fire: Date, snooze: Bool, _ c: Context) -> LocalNote {
        let hasJoin = JoinGuard.isAllowed(e.joinURL)
        var parts = [lead(fire: fire, start: e.start), time(e.start, c)]
        if hasJoin, let name = JoinGuard.providerName(e.joinURL) { parts.append(name) }
        let tags = e.accountIds.compactMap { c.tags[$0] }.filter { !$0.isEmpty }
        if !tags.isEmpty { parts.append(tags.joined(separator: "+")) }
        let key = key(e)
        let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalNote(
            id: snooze ? snoozeId(key: key) : NoteIds.meetingPrefix + key,
            title: title.isEmpty ? "Meeting" : String(title.prefix(120)),
            body: parts.joined(separator: " \u{00B7} "),
            category: !hasJoin ? NoteIds.meetingNoLinkCategory
                : c.fathom(e.accountIds) ? NoteIds.meetingFathomCategory : NoteIds.meetingCategory,
            thread: "meet-\(e.r)",
            fireAt: fire,
            trigger: snooze ? .interval(max(1, fire.timeIntervalSince(c.now).rounded()))
                            : NoteTrigger.at(fire, now: c.now, calendar: c.calendar),
            userInfo: ["kind": snooze ? "snooze" : "meeting", "r": e.r, "start": String(epoch(e.start)),
                       "fire": String(epoch(fire))])
    }

    static func lead(fire: Date, start: Date) -> String {
        let ahead = start.timeIntervalSince(fire)
        if ahead >= 90 { return "In \(Int((ahead / 60).rounded())) minutes" }
        if ahead >= 30 { return "In 1 minute" }
        if ahead > -60 { return "Starting now" }
        let late = Int((-ahead / 60).rounded())
        return "Started \(late) min ago"
    }

    static func time(_ date: Date, _ c: Context) -> String {
        let f = DateFormatter()
        f.calendar = c.calendar
        f.timeZone = c.calendar.timeZone
        f.locale = c.locale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }
}

/// Re-auth notices: at most once per account per rolling 24 h while it needs a new sign-in.
enum ReauthNotices {
    static let interval: TimeInterval = 24 * 3600

    static func due(_ accounts: [AccountRecord], now: Date, paused: Bool, sentAt: (UUID) -> Date?) -> [AccountRecord] {
        guard !paused else { return [] }
        return accounts.filter { a in
            guard a.health == .reauthNeeded else { return false }
            guard let last = sentAt(a.id) else { return true }
            return now.timeIntervalSince(last) >= interval || last > now.addingTimeInterval(60)
        }
    }

    static func id(_ account: UUID) -> String { NoteIds.reauthPrefix + account.uuidString }

    /// "ORB signed me out." / "One click to fix." — opens Accounts.
    static func note(_ a: AccountRecord) -> LocalNote {
        let name = label(a)
        return LocalNote(id: id(a.id), title: "\(name) signed me out.", body: "One click to fix.",
                         category: NoteIds.reauthCategory, thread: "reauth", fireAt: nil, trigger: nil,
                         userInfo: ["kind": "reauth", "a": a.id.uuidString])
    }

    static func label(_ a: AccountRecord) -> String {
        let tag = a.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty { return String(tag.prefix(24)) }
        let name = a.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "An account" : String(name.prefix(24))
    }
}

/// New-mail notices (setting OFF by default): one note per account per mail pass, for inbox threads
/// that are unread and newer than the account's watermark. The first pass after launch or after the
/// account appears only sets the watermark (no flood of old mail).
enum MailNotices {
    static let fetchLimit = 50
    static let namesShown = 2

    struct Outcome: Equatable {
        var note: LocalNote?
        /// The watermark to store: at once when `note` is nil, only after the note was shown otherwise
        /// (nil = keep the old one; a held batch is batched again on the next pass).
        var seen: Date?
        var newCount = 0
    }

    /// Setting off → the watermark moves (turning it on later doesn't dump old mail). Paused, not
    /// permitted or a failed add → it stays, so the same threads come in the next batch.
    static func batch(account a: AccountRecord, threads: [MailThread], seen: Date?, now: Date,
                      enabled: Bool, paused: Bool) -> Outcome {
        let newest = threads.map(\.at).max()
        // First look: remember where the inbox stands (an empty inbox starts 5 min back, so mail that
        // was already on its way still counts as new on the next pass).
        guard let seen else { return Outcome(note: nil, seen: newest ?? now.addingTimeInterval(-300)) }
        let fresh = threads.filter { $0.unread && $0.at > seen }.sorted { $0.at > $1.at }
        let mark = max(seen, newest ?? seen)
        var out = Outcome(note: nil, seen: mark > seen ? mark : nil, newCount: fresh.count)
        guard enabled, let top = fresh.first else { return out }
        guard !paused else {
            out.seen = nil
            return out
        }
        var names: [String] = []
        for t in fresh {
            let name = firstName(t)
            if !names.contains(name) { names.append(name) }
        }
        var who = names.prefix(namesShown).joined(separator: ", ")
        if names.count > namesShown { who += ", \u{2026}" }
        let subject = top.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        out.note = LocalNote(id: NoteIds.mailPrefix + "\(a.id.uuidString)-\(HeadsUp.epoch(top.at))",
                             title: "\(ReauthNotices.label(a)) \u{00B7} \(fresh.count) new: \(who)",
                             body: subject.isEmpty ? "(No subject)" : String(subject.prefix(160)),
                             category: NoteIds.mailCategory, thread: "mail-\(a.id.uuidString)", fireAt: nil, trigger: nil,
                             userInfo: ["kind": "mail", "a": a.id.uuidString])
        return out
    }

    /// "Juniper Vale" → "Juniper"; an address → its local part.
    static func firstName(_ t: MailThread) -> String {
        let display = t.sender.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        let source = display.isEmpty ? t.senderEmail : display
        if source.contains("@"), !source.contains(" ") {
            return String(source.split(separator: "@").first ?? "Someone").prefix(24).description
        }
        return String((source.split(separator: " ").first.map(String.init) ?? "Someone").prefix(24))
    }
}
