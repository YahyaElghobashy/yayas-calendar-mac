import CryptoKit
import Foundation

/// `share/upcoming-meetings.json` for Deck, a meeting recorder on the same Mac (it names recordings and
/// links them to the right people). Schema and rules: docs/CONTRACTS.md (Deck export). Local only: a 0600 file in the app's 0700
/// folder, read by Deck on the same Mac; the change ping (`meetingsChanged`) carries no payload.
/// Settings → "Share upcoming meetings with Deck" (D-039), "… with Deck and Yaya's Murmur" (D-046): Yaya's Murmur,
/// the add-on notetaker, reads the same file under the same contract. Off unless Deck or Murmur is on this Mac: the
/// file holds meeting titles, attendees and join links, and nobody else reads it.
enum DeckExportSetting {
    static let key = "deck.shareUpcomingMeetings"

    /// The user's choice wins; until they make one, it follows whether Deck is installed.
    static func isOn(stored: Bool?, deckInstalled: Bool) -> Bool { stored ?? deckInstalled }

    /// The same switch since Yaya's Murmur reads the file too (D-046): on by default when either is installed.
    static func isOn(stored: Bool?, deckInstalled: Bool, murmurInstalled: Bool) -> Bool {
        stored ?? (deckInstalled || murmurInstalled)
    }
}

/// Which app counts as Deck when the switch has no stored choice. Any app may claim the `deck:` URL scheme and
/// any app may be called Deck, so only the bundle id decides: the handler must carry Deck's own id. The source
/// keeps the SHA-256 of that id (lowercased, UTF-8), not the id itself. Every other handler, a look-alike or a
/// fork under another id, leaves sharing off until the user turns it on.
enum DeckIdentity {
    static let bundleIdDigest = "3be91d8df53fba3d79c3397e0cdc536ba2a9c791b974e3e930364cb831fc5380"

    /// Lowercase hex SHA-256 of the lowercased id.
    static func digest(_ bundleId: String) -> String {
        SHA256.hash(data: Data(bundleId.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `bundleId` is Deck's (`expected` stands in for the stored digest in tests).
    static func isDeck(bundleId: String?, expected: String = bundleIdDigest) -> Bool {
        guard let id = bundleId, !id.isEmpty, id == id.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return digest(id) == expected
    }
}

struct DeckExport: Codable, Equatable {
    static let version = 1
    static let fileName = "upcoming-meetings.json"
    /// Posted (DistributedNotificationCenter, no object, no userInfo) after every write.
    static let changedNotification = Profile.scoped("meetingsChanged")

    var v: Int = DeckExport.version
    var generatedAt: Date
    /// Email domains of the connected accounts, lowercased, sorted.
    var myDomains: [String]
    var meetings: [Meeting]

    struct Meeting: Codable, Equatable {
        /// Stable local id (`r`; merged invites share one).
        var id: String
        /// Tags of every account that has it ("ORB", "FAM"), primary first.
        var accounts: [String]
        var provider: String
        var start: Date
        var end: Date
        var title: String
        /// Allowlisted https join link, or null.
        var joinURL: String?
        var organizer: Person?
        var attendees: [Attendee]
        /// Any attendee (or the organizer) outside the user's own domains.
        var isExternal: Bool

        // Explicit nulls: Deck can tell "no link" from "older file without the key".
        enum CodingKeys: String, CodingKey { case id, accounts, provider, start, end, title, joinURL, organizer, attendees, isExternal }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(accounts, forKey: .accounts)
            try c.encode(provider, forKey: .provider)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encode(title, forKey: .title)
            try c.encode(joinURL, forKey: .joinURL)
            try c.encode(organizer, forKey: .organizer)
            try c.encode(attendees, forKey: .attendees)
            try c.encode(isExternal, forKey: .isExternal)
        }
    }

    struct Person: Codable, Equatable {
        var name: String?
        var email: String
        enum CodingKeys: String, CodingKey { case name, email }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(email, forKey: .email)
        }
    }

    struct Attendee: Codable, Equatable {
        var name: String?
        var email: String
        /// accepted | tentative | declined | needsAction
        var response: String
        enum CodingKeys: String, CodingKey { case name, email, response }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(email, forKey: .email)
            try c.encode(response, forKey: .response)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The bytes that decide "changed": everything but `generatedAt`.
    var comparable: Data? {
        var copy = self
        copy.generatedAt = Date(timeIntervalSince1970: 0)
        return try? Self.encoder.encode(copy)
    }
}

enum DeckExportBuilder {
    /// Meetings overlapping [now − 15 min, now + 48 h): the ±15 min recording match plus two days ahead.
    static let before: TimeInterval = 15 * 60
    static let after: TimeInterval = 48 * 3600
    static let maxMeetings = 300

    /// Webmail domains: sharing one with a connected account doesn't make someone a colleague, so for
    /// these only the connected addresses themselves count as "mine".
    static let publicDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com",
        "mac.com", "yahoo.com", "ymail.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "zoho.com",
    ]

    static func build(events: [CalendarEvent], accounts: [AccountRecord], now: Date) -> DeckExport {
        let addresses = Set(accounts.map { $0.email.lowercased() }.filter { $0.contains("@") })
        let domains = Set(addresses.compactMap(domain))
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let from = now.addingTimeInterval(-before), to = now.addingTimeInterval(after)
        var seen = Set<String>()
        /// "<epoch start>|<join link>" → index: separate invites to one call are one meeting.
        var calls: [String: Int] = [:]
        var meetings: [DeckExport.Meeting] = []
        let sorted = events.sorted { $0.start != $1.start ? $0.start < $1.start : $0.r < $1.r }
        for e in sorted where !e.allDay && e.myResponse != .declined {
            guard e.start < to, max(e.end, e.start.addingTimeInterval(1)) > from, seen.insert(e.r).inserted else { continue }
            let tags = e.accountIds.compactMap { byId[$0].map(tag) }
            let join = JoinGuard.isAllowed(e.joinURL) ? e.joinURL?.absoluteString : nil
            if let join {
                let call = "\(Int64(e.start.timeIntervalSince1970.rounded()))|\(join.lowercased())"
                if let index = calls[call] {
                    for t in tags where !meetings[index].accounts.contains(t) { meetings[index].accounts.append(t) }
                    continue
                }
                calls[call] = meetings.count
            }
            let provider = e.accountIds.first.flatMap { byId[$0]?.provider } ?? "google"
            meetings.append(DeckExport.Meeting(
                id: e.r, accounts: tags, provider: provider, start: e.start, end: e.end, title: e.title,
                joinURL: join,
                organizer: e.organizer.map { DeckExport.Person(name: clean($0.name), email: $0.email.lowercased()) },
                attendees: e.attendees.map { DeckExport.Attendee(name: clean($0.name), email: $0.email.lowercased(),
                                                                 response: $0.response.rawValue) },
                isExternal: isExternal(e, myDomains: domains, myAddresses: addresses)))
            if meetings.count == maxMeetings { break }
        }
        return DeckExport(generatedAt: now, myDomains: domains.sorted(), meetings: meetings)
    }

    /// Someone (attendee or organizer, not the user) whose address is neither a connected address nor
    /// on a connected, non-webmail domain. Google calendar ids (rooms, groups: `…calendar.google.com`)
    /// are not people and never count.
    static func isExternal(_ e: CalendarEvent, myDomains: Set<String>, myAddresses: Set<String>) -> Bool {
        var people = e.attendees.filter { !$0.isSelf }
        if let organizer = e.organizer, !organizer.isSelf { people.append(organizer) }
        for person in people {
            let email = person.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = domain(email) else { continue }
            if host == "calendar.google.com" || host.hasSuffix(".calendar.google.com") { continue }
            if myAddresses.contains(email) { continue }
            if myDomains.contains(host) && !publicDomains.contains(host) { continue }
            return true
        }
        return false
    }

    /// The account's tag ("ORB"), or its name when it has no tag.
    static func tag(_ a: AccountRecord) -> String {
        let tag = a.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? a.displayName.trimmingCharacters(in: .whitespacesAndNewlines) : tag
    }

    static func domain(_ email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let host = email[email.index(after: at)...].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return host.isEmpty ? nil : host
    }

    private static func clean(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}

/// Posts the change ping (DistributedNotificationCenter in the app, a counter in tests).
protocol DeckChangePoster: AnyObject, Sendable {
    func post()
}

/// Writes the export atomically (0600), only when its content changed, then pings Deck.
final class DeckExporter: @unchecked Sendable {
    let directory: URL
    let poster: DeckChangePoster
    private let lock = NSLock()
    private var last: Data?

    init(directory: URL, poster: DeckChangePoster) {
        self.directory = directory
        self.poster = poster
    }

    var fileURL: URL { directory.appendingPathComponent(DeckExport.fileName) }

    /// True when the file was (re)written and the ping sent.
    @discardableResult
    func publish(_ export: DeckExport) throws -> Bool {
        guard let comparable = export.comparable else { throw CocoaError(.coderInvalidValue) }
        lock.lock(); defer { lock.unlock() }
        if last == nil {
            last = onDisk()
            sweepTemps()
        }
        if last == comparable, isHealthy() { return false }
        let data = try DeckExport.encoder.encode(export)
        try SecureFile.writeAtomically(data, to: fileURL)
        last = comparable
        poster.post()
        return true
    }

    /// Takes the export away (uninstall): the file goes, then the ping, so Deck reads "no calendar data".
    @discardableResult
    func withdraw() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let removed = unlink(fileURL.path) == 0
        last = nil
        poster.post()
        return removed
    }

    /// What the file on disk says, as comparable bytes (after a restart: no rewrite, no ping, when
    /// nothing changed).
    private func onDisk() -> Data? {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? DeckExport.decoder.decode(DeckExport.self, from: data) else { return nil }
        return decoded.comparable
    }

    /// Temp files a crash left between create and rename (first publish of a run).
    private func sweepTemps() {
        let prefix = ".\(DeckExport.fileName)."
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            unlink(directory.appendingPathComponent(name).path)
        }
    }

    /// The file exists, is a regular file and is 0600 (otherwise rewrite it).
    private func isHealthy() -> Bool {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && (info.st_mode & 0o777) == 0o600
    }
}

/// Private files: a temp file created 0600 with O_EXCL|O_NOFOLLOW next to the target, fsync, rename(2).
/// Readers see the old file or the new one, never a half-written one.
enum SecureFile {
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var ok = fchmod(fd, mode) == 0
        if ok {
            ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        guard ok, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
