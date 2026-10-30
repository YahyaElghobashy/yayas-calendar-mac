import Foundation

enum RouteTests {
    static func run() {
        T.section("routes: table = CONTRACTS")
        // name, params, quiet: copied from docs/CONTRACTS.md by hand, on purpose.
        let contracts: [(String, [String], Bool)] = [
            ("ping", ["probe"], true),
            ("open/app", ["section", "tab", "part"], false),
            ("page", ["w", "fam", "to"], true),
            ("day", ["w", "d"], true),
            ("month", ["w", "to"], true),
            ("range", ["w", "v"], true),
            ("sync", ["w"], true),
            ("join", ["r", "k"], true),
            ("record", ["r", "k"], true),
            ("livehelper", ["r", "k"], true),
            ("rsvp", ["r", "k", "v"], true),
            ("mail/read", ["r", "k"], true),
            ("mail/archive", ["r", "k"], true),
            ("mail/undo", ["r", "k"], true),
            ("mail/star", ["r", "k"], true),
            ("open/event", ["r", "k"], false),
            ("open/message", ["r", "k"], false),
            ("open/day", ["w", "d"], false),
            ("reauth", ["a", "k"], false),
        ]
        T.equal(RouteTable.all.count, contracts.count, "route count")
        for (name, params, quiet) in contracts {
            guard let spec = RouteTable.spec(name) else { T.check(false, "missing route \(name)"); continue }
            T.equal(spec.params, params, "\(name) params")
            T.equal(spec.quiet, quiet, "\(name) quiet")
        }
        T.equal(Set(RouteTable.all.map(\.name)).count, RouteTable.all.count, "route names are unique")

        T.section("routes: parse")
        for (name, params, quiet) in contracts {
            let url = YayaLink.url(name, params.map { ($0, "v1") })
            let route = Route.parse(url)
            T.equal(route?.name, name, "parse \(url.absoluteString)")
            T.equal(route?.quiet, quiet, "\(name) quiet after parse")
            T.equal(route?.params.count, params.count, "\(name) keeps its params")
        }
        let ping = Route.parse(URL(string: "yayacal://ping?probe=p1")!)
        T.equal(ping?.params["probe"], "p1", "ping probe")
        T.equal(ping?.isKnown, true, "ping is known")
        let open = Route.parse(URL(string: "yayacal://open/app?section=widgets")!)
        T.equal(open?.name, "open/app", "open/app name")
        T.equal(open?.params["section"], "widgets", "open/app section")
        T.equal(open?.quiet, false, "open/app is not quiet")
        T.equal(Route.parse(URL(string: "YAYACAL://Ping?probe=x")!)?.name, "ping", "scheme and host are case-insensitive")
        T.equal(Route.parse(URL(string: "yayacal:ping?probe=x")!)?.name, "ping", "no-slashes form parses")
        T.check(Route.parse(URL(string: "https://ping?probe=x")!) == nil, "other schemes are rejected")
        T.check(Route.parse(URL(string: "yayacal-test://ping")!) == nil, "another scheme is rejected")

        T.section("routes: unknown + unsafe input")
        let unknown = Route.parse(URL(string: "yayacal://launch/missiles?x=1")!)
        T.equal(unknown?.isKnown, false, "unknown route is unknown")
        T.equal(unknown?.name, "launch/missiles", "unknown name kept when short and plain")
        T.equal(unknown?.quiet, true, "unknown routes count as quiet")
        T.equal(unknown?.params.count, 0, "unknown routes carry no params")
        T.equal(Route.parse(URL(string: "yayacal://\(String(repeating: "a", count: 40))")!)?.name, "?", "long unknown name sanitized")
        T.equal(Route.parse(URL(string: "yayacal://someone@example.com/inbox")!)?.name, "example.com/inbox",
                "user info never reaches the name")
        T.equal(Route.parse(URL(string: "yayacal://Héllo%20there")!)?.name ?? "?", "?", "odd characters sanitized")
        T.check(Route.parse(URL(string: "yayacal://ping?probe=a%20b")!)?.params["probe"] == nil, "space in value dropped")
        T.check(Route.parse(URL(string: "yayacal://ping?probe=me%40example.com")!)?.params["probe"] == nil, "email-like value dropped")
        T.check(Route.parse(URL(string: "yayacal://ping?probe=\(String(repeating: "x", count: 65))")!)?.params["probe"] == nil,
                "65-char value dropped")
        T.check(Route.parse(URL(string: "yayacal://ping?probe=\(String(repeating: "x", count: 64))")!)?.params["probe"] != nil,
                "64-char value kept")
        let extra = Route.parse(URL(string: "yayacal://ping?probe=ok&email=x&probe=second")!)
        T.equal(extra?.params, ["probe": "ok"], "unknown params dropped, first value wins")
        T.check(Route.parse(URL(string: "yayacal://open/app?section=https://evil.example")!)?.params["section"] == nil,
                "URL-shaped value dropped")

        T.section("routes: builders round-trip")
        T.equal(YayaLink.openApp(.widgets).absoluteString, "yayacal://open/app?section=widgets", "open/app URL")
        T.equal(YayaLink.ping("agenda.all.L.row.3").absoluteString, "yayacal://ping?probe=agenda.all.L.row.3", "ping URL")
        let page = Route.parse(YayaLink.page(kind: "agenda.all", family: "XLP", to: 2))
        T.equal(page?.params, ["w": "agenda.all", "fam": "XLP", "to": "2"], "page params")
        let day = Route.parse(YayaLink.day(kind: "month", day: "2026-10-21"))
        T.equal(day?.params, ["w": "month", "d": "2026-10-21"], "day params")
        T.equal(Route.parse(YayaLink.openDay(kind: "month", day: "2026-10-21"))?.quiet, false, "open/day is not quiet")
        for section in AppSection.allCases {
            let route = Route.parse(YayaLink.openApp(section))
            T.equal(route?.params["section"], section.rawValue, "section \(section.rawValue) survives")
        }

        T.section("routes: widget link context")
        let monday = WidgetSample.fixedNow
        let wednesday = WidgetCalendar.current.date(byAdding: .day, value: 2, to: monday)!
        for family in Family.allCases {
            let links = WidgetLinkContext(kind: "month", family: family)
            let tap = Route.parse(links.day(wednesday))
            if family == .small {
                T.equal(tap?.name, "open/day", "Small month day tap opens the Day Peek")
                T.equal(tap?.params, ["w": "month", "d": "2026-10-21"], "Small day params")
                T.equal(tap?.quiet, false, "open/day is not quiet")
            } else {
                T.equal(tap?.name, "day", "\(family.short) month day tap")
                T.equal(tap?.params["d"], "2026-10-21", "\(family.short) day param")
            }
            T.equal(links.month(wednesday).flatMap(Route.parse)?.params["to"], "2026-10", "\(family.short) month param")
            let row = Route.parse(links.probe("join", 12))
            T.equal(row?.params["probe"], "month.\(family.short).join.12", "\(family.short) probe survives")
        }
        for spec in WidgetKinds.all {
            T.check(Route.isSafeValue(spec.kind), "kind \(spec.kind) is a safe link value")
        }

        T.section("routes: quiet batches")
        let q = Route.parse(URL(string: "yayacal://ping?probe=a")!)!
        let n = Route.parse(URL(string: "yayacal://open/app?section=inbox")!)!
        let u = Route.parse(URL(string: "yayacal://nope")!)!
        T.equal(Route.batchIsQuiet([q]), true, "[ping] is quiet")
        T.equal(Route.batchIsQuiet([q, q]), true, "[ping, ping] is quiet")
        T.equal(Route.batchIsQuiet([q, n]), false, "[ping, open/app] is not quiet")
        T.equal(Route.batchIsQuiet([u]), true, "[unknown] is quiet")
        T.equal(Route.batchIsQuiet([]), false, "an empty batch never hides")
    }
}
