// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import Foundation
import SwiftUI

/// Join with Fathom renders (D-045): the popover card (Fathom on the meeting's account, on another one, the wait,
/// can't tell), the Event Peek (a merged invite with "Records to", the wait, the timeout), Up Next Medium with its
/// Fathom button, Settings → Fathom and the account card's row. The Moonfield cast only: a fake Fathom (no files
/// read, nothing opened), memory bags, a pinned clock.
@MainActor
enum FathomRenders {
    final class Clock { var now: Date; init(_ now: Date) { self.now = now } }

    static func session(_ signIn: FathomSignIn, clock: Clock, bag: PreferenceBag = MemoryBag()) -> FathomSession {
        let s = FathomSession(env: FathomSession.Environment(
            installed: { true }, signIn: { signIn }, link: { FathomPrefs.link($0, bag) }, open: { _ in true },
            after: { _, _ in }, every: { _, _ in {} }, clock: { clock.now }))
        s.refresh()
        return s
    }

    @discardableResult
    static func run(dir: URL, now: Date, directory: AccountDirectory, logo: @escaping (String) -> NSImage?,
                    save: (AnyView, String, [String: Any]) -> Void) -> Int {
        var count = 0
        let events = SnapshotFixtures.events()
        let cmt = Cast.cmt.email, home = Cast.home.email, orb = Cast.orb.email
        let backdrop = Color(hex: 0x3A4A55)

        // 1. The popover's card ("The Comets weekly sync", CMT, in 12 minutes).
        func popover(_ name: String, _ signIn: FathomSignIn, join: Bool = false) {
            let clock = Clock(now)
            let s = session(signIn, clock: clock)
            let store = FakeCalendarStore(events: events)
            let model = PopoverModel(store: { store }, actions: { store }, mail: { FakeMailStore() }, directory: { directory },
                                     clock: { now }, syncedAt: { now.addingTimeInterval(-180) }, use24Hour: { false }, fathom: s)
            model.load()
            if join, let e = model.card?.event { _ = s.join(e, directory: directory, via: "render") }
            clock.now = now.addingTimeInterval(9)
            let view = PopoverView(model: model).environment(\.headlessRender, true)
            save(AnyView(view.padding(24).background(backdrop)), "\(name).png",
                 ["window": "popover", "feature": "fathom", "state": name, "card": model.card?.event.title ?? "",
                  "targets": model.card?.fathom.count ?? 0, "pending": s.pending != nil,
                  "width": Int(PopoverView.size.width), "height": Int(PopoverView.size.height)])
            count += 1
        }
        popover("fathom-popover-ready", .signedIn(cmt))
        popover("fathom-popover-other-account", .signedIn(home))
        popover("fathom-popover-wait", .signedIn(home), join: true)
        popover("fathom-popover-unknown", .unknown, join: true)

        // 2. The Event Peek: a merged invite (ORB + CMT) with "Records to", the wait, the timeout.
        let merged = events.first { $0.title == "Pickle \u{00D7} Comets jingle weekly" } ?? events[0]
        func peek(_ name: String, _ signIn: FathomSignIn, join: Bool = false, timeout: Bool = false) {
            let clock = Clock(now)
            let s = session(signIn, clock: clock)
            let model = EventPeekModel(event: merged, directory: directory, actions: FakeCalendarStore(), open: { _ in true }, fathom: s)
            if join { _ = s.join(merged, directory: directory, via: "render") }
            if timeout {
                clock.now = now.addingTimeInterval(FathomSession.waitLimit)
                s.tick()
            } else {
                clock.now = now.addingTimeInterval(9)
            }
            let view = PeekCard { EventPeekView(model: model) }.fixedSize(horizontal: false, vertical: true)
                .environment(\.headlessRender, true)
            let natural = NSHostingView(rootView: view).fittingSize.height
            save(AnyView(view.padding(24).background(backdrop)), "\(name).png",
                 ["window": "peek", "feature": "fathom", "state": name, "targets": model.fathomTargets.count,
                  "naturalHeight": Int(natural.rounded()), "scrolls": natural > PeekPlacement.maxHeight])
            count += 1
        }
        peek("fathom-peek-merged-ready", .signedIn(orb))
        peek("fathom-peek-wait", .signedIn(home), join: true)
        peek("fathom-peek-timed-out", .signedIn(home), join: true, timeout: true)

        // 3. Up Next Medium with Fathom beside Join (snapshot `rec`).
        for (look, lookName) in [(WidgetSnapshot.Style.Look.paper, "light"), (.ink, "dark")] {
            var snapshot = SnapshotFixtures.named("busy", kind: WidgetKinds.upNext.kind)
            snapshot.style.look = look
            snapshot.meetings = snapshot.meetings.map { m in
                var m = m
                m.rec = m.hasJoin ? true : nil
                return m
            }
            guard let decoded = SnapshotFixtures.decode(SnapshotFixtures.json(snapshot)) else { continue }
            let model = SnapshotModel(decoded, logo: logo)
            let view = KindView(spec: WidgetKinds.upNext, family: .medium, data: model.data(at: now),
                                style: model.style(dark: look == .ink), page: 1)
                .environment(\.plainLinks, true)
            save(AnyView(view), "fathom-widget-upnext-M-\(lookName).png",
                 ["kind": "upnext", "family": "M", "look": lookName, "feature": "fathom"])
            count += 1
        }

        // 4. Settings → Fathom and the account card's row (own address and signed in, another address, off).
        let bag = MemoryBag()
        let clock = Clock(now)
        let s = session(.signedIn(orb), clock: clock, bag: bag)
        let links = FathomLinksModel(bag: bag, session: s, post: {})
        FathomPrefs.setHotkeyRecords(true, bag)
        FathomPrefs.setLink(.address("recordings@quietcomets.example"), for: Cast.cmt.id, bag)
        FathomPrefs.setLink(.off, for: Cast.fam.id, bag)
        s.refresh()
        let settings = SettingsFathomCard(model: links, directory: { directory })
            .frame(width: 640).padding(28).background(AppTheme.background)
            .environment(\.colorScheme, .dark).environment(\.headlessRender, true)
        save(AnyView(settings), "fathom-settings.png", ["window": "settings-fathom", "feature": "fathom"])
        count += 1
        let rows = VStack(alignment: .leading, spacing: 14) {
            ForEach([Cast.orb, Cast.cmt, Cast.fam], id: \.id) { account in
                ShellCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(account.tag) \u{00B7} \(account.email)").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2)
                        FathomAccountRow(model: links, accountId: account.id, email: account.email)
                    }
                }
            }
        }
        .frame(width: 640).padding(28).background(AppTheme.background)
        .environment(\.colorScheme, .dark).environment(\.headlessRender, true)
        save(AnyView(rows), "fathom-account-rows.png", ["window": "accounts", "feature": "fathom"])
        count += 1
        return count
    }
}
#endif
