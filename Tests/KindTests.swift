import Foundation

enum KindTests {
    static func run() {
        T.section("widget kinds = CONTRACTS")
        let all: [Family] = [.small, .medium, .large, .extraLarge, .extraLargePortrait]
        // kind, gallery name, families: docs/CONTRACTS.md "Widget kinds".
        var expected: [(String, String, [Family])] = [
            ("agenda.all", "Agenda", all),
            ("day", "Day", all),
            ("upnext", "Up Next", [.small, .medium]),
            ("month", "Month", all),
            ("inbox.all", "Inbox", [.medium, .large, .extraLarge, .extraLargePortrait]),
            ("combo.all", "Agenda & Inbox", [.large, .extraLarge, .extraLargePortrait]),
            ("digest", "Daily Digest", all),
        ]
        for letter in ["a", "b", "c", "d", "e", "f"] {
            expected.append(("custom.\(letter)", "Custom Widget \(letter.uppercased())", all))
        }
        T.equal(WidgetKinds.all.count, 13, "exactly 13 kinds")
        T.equal(WidgetKinds.all.map(\.kind), expected.map(\.0), "kind strings in gallery order")
        for (kind, name, families) in expected {
            guard let spec = WidgetKinds.spec(kind) else { T.check(false, "missing \(kind)"); continue }
            T.equal(spec.galleryName, name, "\(kind) gallery name")
            T.equal(spec.families, families, "\(kind) families")
            T.check(!spec.description.isEmpty, "\(kind) has a description")
        }

        T.section("widget kinds: gallery copy = DESIGN-WIDGETS.md")
        let copy: [String: String] = [
            "agenda.all": "Your meetings from every calendar, day by day. Flip pages with the arrows.",
            "upnext": "Your next meeting, a countdown and a Join button.",
            "inbox.all": "Newest mail from all your inboxes. Tap to read, mark read or archive.",
            "combo.all": "Meetings on one side, mail on the other.",
            "month": "Tap a day on the calendar to see its meetings.",
            "day": "One day hour by hour, with overlapping meetings side by side. Flip days with the arrows.",
            "digest": "Today's mail digest from Yaya's Mail Helper, one box per mailbox. Tap to read it.",
            "custom.a": "Pick its calendars and look in Yaya's Calendar → Widgets.",
        ]
        for (kind, text) in copy { T.equal(WidgetKinds.spec(kind)?.description, text, "\(kind) description") }

        T.section("widget families")
        T.equal(Family.allCases.map(\.short), ["S", "M", "L", "XL", "XLP"], "family tokens")
        T.equal(Family.large.size, CGSize(width: 344, height: 344), "Large size")
        T.equal(Family.extraLarge.size, CGSize(width: 704, height: 344), "XL size")
        T.equal(Family.extraLargePortrait.size, CGSize(width: 344, height: 704), "XLP size")
    }
}

enum TraceTests {
    static func run() {
        T.section("trace line shape (probe scripts parse it)")
        let at = Date(timeIntervalSince1970: 1_792_404_301.234)
        let line = Trace.line(source: "app", event: "recv ping", fields: ["probe": "p1", "at": "1792404301234"], now: at)
        let fields = line.trimmingCharacters(in: .newlines).split(separator: " ").map(String.init)
        T.equal(fields.count, 7, "7 space-separated fields")
        T.check(fields[0].hasSuffix("Z") && fields[0].contains("T"), "field 1 is ISO 8601 UTC")
        T.equal(fields[1], "1792404301234", "field 2 is epoch ms")
        T.equal(Array(fields[2...6]), ["app", "recv", "ping", "probe=p1", "at=1792404301234"], "source, event, pairs")
        T.check(line.hasSuffix("\n") && line.filter { $0 == "\n" }.count == 1, "exactly one newline")
        T.equal(Trace.sanitized("a b\tc"), "a_b_c", "whitespace becomes _")
        T.equal(Trace.sanitized(""), "-", "empty becomes -")
        T.equal(Trace.sanitized(String(repeating: "x", count: 200)).count, 80, "values capped at 80")
        T.equal(Trace.appCap, 512 * 1024, "app log cap 512 KB")
    }
}
