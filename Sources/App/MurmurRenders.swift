// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import Foundation
import SwiftUI

/// Yaya's Murmur and recording per account renders (D-046), each with and without Murmur on the Mac: the popover
/// (the card per recorder, badges on the card and the rows), the Event Peek (Join with its "▾", the recorder, badges,
/// Live Helper), the account card's recording rows, Settings → Yaya's Murmur, Up Next Medium's record button and Join
/// with Live Helper on Up Next (D-048) and the popover card (D-049). The
/// Moonfield cast only: fake Murmur and Fathom sessions (no files read, nothing opened), memory bags, a pinned clock.
@MainActor
enum MurmurRenders {
    static func murmur(installed: Bool, marks: [String: MurmurMark]) -> MurmurSession {
        let s = MurmurSession(env: MurmurSession.Environment(
            installed: { installed }, marks: { .ready(marks, skipped: 0) }, open: { _ in true }, after: { _, _ in }))
        s.refresh()
        return s
    }

    static func fathom(installed: Bool, signIn: FathomSignIn, bag: PreferenceBag) -> FathomSession {
        let s = FathomSession(env: FathomSession.Environment(
            installed: { installed }, signIn: { signIn }, link: { FathomPrefs.link($0, bag) }, open: { _ in true },
            after: { _, _ in }, every: { _, _ in {} }, clock: { WidgetSample.fixedNow }))
        s.refresh()
        return s
    }

    @discardableResult
    static func run(dir: URL, now: Date, directory: AccountDirectory, logo: @escaping (String) -> NSImage?,
                    save: (AnyView, String, [String: Any]) -> Void) -> Int {
        var count = 0
        let events = SnapshotFixtures.events()
        let backdrop = Color(hex: 0x3A4A55)
        let cmtMail = Cast.cmt.email
        let card = events.first { $0.title == "The Comets weekly sync" } ?? events[0]
        let merged = events.first { $0.title == "Pickle \u{00D7} Comets jingle weekly" } ?? events[0]
        // Marks on a few of the week's meetings, by the calendar's own row ids.
        var marks: [String: MurmurMark] = [
            card.r: MurmurMark(helper: .clientMeeting, mode: .homelab, consent: .explicit),
            merged.r: MurmurMark(helper: .interview, mode: .macbook, consent: .notice, status: .notesReady),
        ]
        for e in events.filter({ !$0.allDay && $0.r != card.r && $0.r != merged.r }).prefix(2) {
            marks[e.r] = MurmurMark(mode: .macbook, status: .meOnly)
        }

        // 1. The popover: the card per recorder (CMT's choice), with and without Murmur. The card's meeting has a mark
        // without a Live Helper here, so each recorder's button shows with "✦ Live Helper" beside it (D-049).
        var unmarked = marks
        unmarked[card.r] = MurmurMark(mode: .homelab, consent: .explicit)
        func popover(_ name: String, murmurInstalled: Bool, fathomInstalled: Bool, cmt choice: RecorderChoice,
                     marks shown: [String: MurmurMark]? = nil, light: Bool = false) {
            let bag = MemoryBag()
            RecorderPrefs.setChoice(choice, for: Cast.cmt.id, bag)
            let ms = murmur(installed: murmurInstalled, marks: shown ?? marks)
            let fs = fathom(installed: fathomInstalled, signIn: .signedIn(cmtMail), bag: bag)
            let store = FakeCalendarStore(events: events)
            let model = PopoverModel(store: { store }, actions: { store }, mail: { FakeMailStore() }, directory: { directory },
                                     clock: { now }, syncedAt: { now.addingTimeInterval(-180) }, use24Hour: { false },
                                     fathom: fs, murmur: ms, recorderChoice: { RecorderPrefs.choice($0, bag) })
            model.load()
            let view = PopoverView(model: model).environment(\.headlessRender, true)
            var info: [String: Any] = ["window": "popover", "feature": "murmur", "state": name, "murmur": murmurInstalled,
                                       "fathom": fathomInstalled, "recorder": model.card?.recorder?.rawValue ?? "none",
                                       "badges": model.card?.badges.map(\.rawValue) ?? [],
                                       "width": Int(PopoverView.size.width), "height": Int(PopoverView.size.height)]
            if let offer = model.card?.liveHelper { info["liveHelper"] = offer == .join ? "join" : "setUp" }
            if light {
                // The popover keeps the app's dark look (D-008) under a light menu bar: a light desktop behind it.
                info["appearance"] = "light"
                save(AnyView(view.padding(24).background(Color(hex: 0xDCE3E8)).environment(\.colorScheme, .light)), "\(name).png", info)
            } else {
                save(AnyView(view.padding(24).background(backdrop)), "\(name).png", info)
            }
            count += 1
        }
        popover("murmur-popover-murmur", murmurInstalled: true, fathomInstalled: false, cmt: .automatic, marks: unmarked)
        popover("murmur-popover-fathom", murmurInstalled: true, fathomInstalled: true, cmt: .automatic, marks: unmarked)
        popover("murmur-popover-ask", murmurInstalled: true, fathomInstalled: true, cmt: .ask, marks: unmarked)
        popover("murmur-popover-off", murmurInstalled: true, fathomInstalled: true, cmt: .off, marks: unmarked)
        popover("murmur-popover-without-murmur", murmurInstalled: false, fathomInstalled: true, cmt: .murmur)
        // Join with Live Helper on the card (D-049): the meeting marked Live Helper, its account on Fathom (light and
        // dark desktops) and on Yaya's Murmur; Live Helper takes the recorder's button's place.
        popover("murmur-popover-livehelper-light", murmurInstalled: true, fathomInstalled: true, cmt: .automatic, light: true)
        popover("murmur-popover-livehelper-dark", murmurInstalled: true, fathomInstalled: true, cmt: .automatic)
        popover("murmur-popover-livehelper-murmur", murmurInstalled: true, fathomInstalled: false, cmt: .automatic)

        // 2. The Event Peek: Join with "▾", the recorder, badges and Live Helper; with and without Murmur.
        func peek(_ name: String, event: CalendarEvent, murmurInstalled: Bool, fathomInstalled: Bool,
                  choice: RecorderChoice, peekMarks: [String: MurmurMark]? = nil) {
            let bag = MemoryBag()
            for a in event.accountIds { RecorderPrefs.setChoice(choice, for: a, bag) }
            let ms = murmur(installed: murmurInstalled, marks: peekMarks ?? marks)
            let fs = fathom(installed: fathomInstalled, signIn: .signedIn(Cast.orb.email), bag: bag)
            let model = EventPeekModel(event: event, directory: directory, actions: FakeCalendarStore(), open: { _ in true },
                                       fathom: fs, murmur: ms, recorderChoice: { RecorderPrefs.choice($0, bag) })
            let view = PeekCard { EventPeekView(model: model) }.fixedSize(horizontal: false, vertical: true)
                .environment(\.headlessRender, true)
            let natural = NSHostingView(rootView: view).fittingSize.height
            save(AnyView(view.padding(24).background(backdrop)), "\(name).png",
                 ["window": "peek", "feature": "murmur", "state": name, "murmur": murmurInstalled,
                  "recorder": model.recorder?.rawValue ?? "none", "badges": model.badges.map(\.rawValue),
                  "liveHelper": model.showsLiveHelper, "naturalHeight": Int(natural.rounded()),
                  "scrolls": natural > PeekPlacement.maxHeight])
            count += 1
        }
        peek("murmur-peek-murmur", event: merged, murmurInstalled: true, fathomInstalled: false, choice: .murmur)
        peek("murmur-peek-fathom", event: merged, murmurInstalled: true, fathomInstalled: true, choice: .automatic)
        peek("murmur-peek-ask-helper-off", event: card, murmurInstalled: true, fathomInstalled: true, choice: .ask,
             peekMarks: [:])
        peek("murmur-peek-without-murmur", event: merged, murmurInstalled: false, fathomInstalled: true, choice: .murmur)

        // 3. The account card's recording rows: with Murmur (Record with, then the Fathom account) and without.
        func rows(_ name: String, murmurInstalled: Bool) {
            let bag = MemoryBag()
            RecorderPrefs.setChoice(.murmur, for: Cast.cmt.id, bag)
            RecorderPrefs.setChoice(.ask, for: Cast.fam.id, bag)
            RecorderPrefs.setChoice(.off, for: Cast.home.id, bag)
            let fs = fathom(installed: true, signIn: .signedIn(Cast.orb.email), bag: bag)
            let ms = murmur(installed: murmurInstalled, marks: [:])
            let links = FathomLinksModel(bag: bag, session: fs, post: {})
            let recorders = RecorderChoicesModel(bag: bag, fathom: fs, murmur: ms, post: {})
            let view = VStack(alignment: .leading, spacing: 14) {
                ForEach([Cast.orb, Cast.cmt, Cast.fam, Cast.home], id: \.id) { account in
                    ShellCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(account.tag) \u{00B7} \(account.email)").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2)
                            AccountRecorderSection(recorders: recorders, links: links, accountId: account.id, email: account.email)
                        }
                    }
                }
            }
            .frame(width: 640).padding(28).background(AppTheme.background)
            .environment(\.colorScheme, .dark).environment(\.headlessRender, true)
            save(AnyView(view), "\(name).png", ["window": "accounts", "feature": "murmur", "murmur": murmurInstalled])
            count += 1
        }
        rows("murmur-account-rows", murmurInstalled: true)
        rows("murmur-account-rows-without-murmur", murmurInstalled: false)

        // 4. Settings → Yaya's Murmur (with the Fathom card above it, its ⌃⌥J row moved here).
        do {
            let bag = MemoryBag()
            let fs = fathom(installed: true, signIn: .signedIn(Cast.orb.email), bag: bag)
            let ms = murmur(installed: true, marks: marks)
            let links = FathomLinksModel(bag: bag, session: fs, post: {})
            let recorders = RecorderChoicesModel(bag: bag, fathom: fs, murmur: ms, post: {})
            let view = VStack(alignment: .leading, spacing: 18) {
                SettingsFathomCard(model: links, directory: { directory }, showsHotkey: false)
                SettingsMurmurCard(recorders: recorders, links: links)
            }
            .frame(width: 640).padding(28).background(AppTheme.background)
            .environment(\.colorScheme, .dark).environment(\.headlessRender, true)
            save(AnyView(view), "murmur-settings.png", ["window": "settings-murmur", "feature": "murmur"])
            count += 1
        }

        // 5. Up Next Medium with Murmur's record button (snapshot `recBy`), light and dark.
        for (look, lookName) in [(WidgetSnapshot.Style.Look.paper, "light"), (.ink, "dark")] {
            var snapshot = SnapshotFixtures.named("busy", kind: WidgetKinds.upNext.kind)
            snapshot.style.look = look
            snapshot.meetings = snapshot.meetings.map { m in
                var m = m
                m.rec = m.hasJoin ? true : nil
                m.recBy = m.hasJoin ? "murmur" : nil
                return m
            }
            guard let decoded = SnapshotFixtures.decode(SnapshotFixtures.json(snapshot)) else { continue }
            let model = SnapshotModel(decoded, logo: logo)
            let view = KindView(spec: WidgetKinds.upNext, family: .medium, data: model.data(at: now),
                                style: model.style(dark: look == .ink), page: 1)
                .environment(\.plainLinks, true)
            save(AnyView(view), "murmur-widget-upnext-M-\(lookName).png",
                 ["kind": "upnext", "family": "M", "look": lookName, "feature": "murmur"])
            count += 1
        }

        // 6. Up Next Medium with Join with Live Helper (snapshot `lh`, D-048), light and dark.
        for (look, lookName) in [(WidgetSnapshot.Style.Look.paper, "light"), (.ink, "dark")] {
            var snapshot = SnapshotFixtures.named("busy", kind: WidgetKinds.upNext.kind)
            snapshot.style.look = look
            snapshot.meetings = snapshot.meetings.map { m in
                var m = m
                m.rec = m.hasJoin ? true : nil
                m.recBy = m.hasJoin ? "murmur" : nil
                m.lh = m.hasJoin ? true : nil
                return m
            }
            guard let decoded = SnapshotFixtures.decode(SnapshotFixtures.json(snapshot)) else { continue }
            let model = SnapshotModel(decoded, logo: logo)
            let view = KindView(spec: WidgetKinds.upNext, family: .medium, data: model.data(at: now),
                                style: model.style(dark: look == .ink), page: 1)
                .environment(\.plainLinks, true)
            save(AnyView(view), "murmur-widget-upnext-livehelper-M-\(lookName).png",
                 ["kind": "upnext", "family": "M", "look": lookName, "feature": "livehelper"])
            count += 1
        }
        return count
    }
}
#endif
