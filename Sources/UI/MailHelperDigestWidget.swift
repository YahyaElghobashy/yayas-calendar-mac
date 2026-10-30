import Foundation

/// The Daily Digest widget's data (D-053): the helper's digest distilled into `WidgetSnapshot.Digest`, one box per
/// mailbox. Free of AppKit, so the test binary checks it. The mailboxes are every account the helper has (its
/// `status.accounts`) and any other account an item names, in the calendar's account order, then the helper's;
/// a mailbox with nothing in today's digest keeps its box. Everything it copies was already cleaned by
/// `MailHelperParse` (control and direction characters out, capped); here it is capped again to the widget's limits.
enum MailHelperDigestWidget {
    struct Mailbox: Equatable {
        var id: String
        var email: String
    }

    /// The helper's accounts as mailboxes (its ids and addresses).
    static func mailboxes(_ state: MailHelperState?) -> [Mailbox] {
        (state?.accounts ?? []).map { Mailbox(id: $0.id, email: $0.email) }
    }

    /// `known`: the calendar's accounts in its order; a mailbox it doesn't know is labelled with the helper's address.
    static func snapshot(_ d: MailHelperDigest, mailboxes: [Mailbox], known: [UUID]) -> WidgetSnapshot.Digest {
        typealias Digest = WidgetSnapshot.Digest
        let sections = d.sections.prefix(Digest.maxSections).map {
            Digest.Section(key: $0.key, title: cap($0.title, 60), count: max(0, $0.count), read: d.read[$0.key] ?? false)
        }
        let readKeys = Set(sections.filter(\.read).map(\.key))
        let order = Dictionary(sections.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })

        // Every mailbox: the helper's, then any account an item names (normalised to the calendar's UUID spelling).
        var ids: [String] = []
        var emails: [String: String] = [:]
        func add(_ raw: String, email: String?) {
            let id = norm(raw)
            if !ids.contains(id) { ids.append(id) }
            if let email, !email.isEmpty, emails[id] == nil { emails[id] = email }
        }
        for m in mailboxes { add(m.id, email: m.email) }
        for s in d.sections.prefix(Digest.maxSections) {
            for item in s.items {
                add(item.account, email: item.accountEmail)
                for t in item.threads { add(t.account, email: nil) }
            }
        }
        let rank = Dictionary(known.enumerated().map { ($1.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = ids.enumerated().sorted { a, b in
            (rank[a.element] ?? Int.max, a.offset) < (rank[b.element] ?? Int.max, b.offset)
        }.map(\.element)

        let boxes = sorted.prefix(Digest.maxBoxes).map { id -> Digest.Box in
            var counts: [String: Int] = [:]
            var candidates: [(rank: (Int, Int, Int, Int), line: Digest.Line)] = []
            for s in d.sections.prefix(Digest.maxSections) {
                let read = readKeys.contains(s.key) ? 1 : 0
                let sectionIndex = order[s.key] ?? 0
                for item in s.items {
                    if item.isGroup {
                        let mine = item.threads.filter { norm($0.account) == id }.count
                        guard mine > 0 else { continue }
                        counts[s.key, default: 0] += mine
                        let service = item.service ?? ""
                        let first = item.subjects.first.map { " \u{00B7} \($0)" } ?? ""
                        let text = mine > 1 ? "\(service): \(mine) updates\(first)" : "\(service)\(first)"
                        candidates.append(((read, 3, sectionIndex, item.index), Digest.Line(text: cap(text), section: s.key)))
                    } else {
                        guard norm(item.account) == id else { continue }
                        counts[s.key, default: 0] += 1
                        let headline = item.headline.flatMap { $0.isEmpty ? nil : $0 }
                        let text = headline ?? (item.subject.isEmpty ? item.sender : item.subject)
                        guard !text.isEmpty else { continue }
                        let kind = headline == nil ? 2 : (item.worthOpening ? 0 : 1)
                        candidates.append(((read, kind, sectionIndex, item.index),
                                           Digest.Line(text: cap(text), section: s.key, pick: item.worthOpening && headline != nil ? true : nil)))
                    }
                }
            }
            let top = candidates.sorted { $0.rank < $1.rank }.prefix(Digest.maxLines).map(\.line)
            let label = rank[id] == nil ? emails[id].map { cap($0, 80) } : nil
            return Digest.Box(account: id, label: label, counts: counts, top: Array(top))
        }
        return Digest(id: d.id, day: d.day, total: max(0, d.total), sections: Array(sections), boxes: Array(boxes))
    }

    /// The calendar spells account ids as `UUID.uuidString` (upper case); the helper may not.
    static func norm(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? id }

    static func cap(_ text: String, _ limit: Int = WidgetSnapshot.Digest.maxText) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
