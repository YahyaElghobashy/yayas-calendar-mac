// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import SwiftUI
import WidgetKit

/// `--render <dir>`: PNGs of every widget kind × family × look drawn from JSON snapshot fixtures (the
/// widget's own read path: encode → decode → SnapshotModel), every state fixture, the accented and
/// vibrant variants composited the way macOS draws them (`GlassComposite`, D-047), the Peeks, Widget Studio, the Calendar section and the Inbox section,
/// the reader, the composer, the Mail Peek and Settings → Mail, plus `render-manifest.json` with row
/// counts. ImageRenderer only: never a window, no Keychain, no network, no user defaults written; traces
/// go to `<dir>/trace/`. Dates are pinned (Monday 19 October 2026, 9:48 AM, London) so renders are
/// deterministic; mail surfaces render with mail on (D-029) and a few with the `mailEnabled` seam off for comparison.
///
/// Everything drawn is the fictional cast (`Cast`): its accounts, people and inbox, and its badges, drawn
/// in code. No logo file is read, so a render shows the same thing on every Mac.
@MainActor
enum HeadlessRender {
    static func run(to dir: URL) -> Int32 {
        WidgetCalendar.current = WidgetCalendar.fixed
        let now = WidgetSample.fixedNow
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("fixtures"), withIntermediateDirectories: true)
        } catch {
            print("✗ cannot create \(dir.path)")
            return 1
        }
        // A render must never write the real app log or widget trace. Anything the surfaces
        // trace while drawing lands in <dir>/trace/ instead.
        Trace.folderOverride = dir.appendingPathComponent("trace", isDirectory: true)
        // YC_RENDER_SCALE (1…6, default 2): larger PNGs of the same renders, for promo plates.
        let renderScale = ProcessInfo.processInfo.environment["YC_RENDER_SCALE"].flatMap(Double.init)
            .map { min(6, max(1, $0)) } ?? 2
        let logos = RenderLogos.load()
        let directory = FixtureAccounts.directory(logo: { logos.image(for: $0) })
        FixtureServices.install(events: SnapshotFixtures.events(), directory: directory)
        FixtureServices.installMail()

        var manifest: [[String: Any]] = []
        var failures = 0
        let started = Date()

        func save<V: View>(_ view: V, _ name: String, _ info: [String: Any]) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = renderScale
            write(renderer.cgImage, name, info)
        }

        func write(_ image: CGImage?, _ name: String, _ info: [String: Any]) {
            let url = dir.appendingPathComponent(name)
            guard let image,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? png.write(to: url)) != nil else {
                print("  ✗ \(name)")
                failures += 1
                return
            }
            var entry = info
            entry["file"] = name
            entry["px"] = "\(image.width)x\(image.height)"
            manifest.append(entry)
        }

        // First-run UX (HeadlessRenderUX): first, so YC_RENDER_ONLY=ux can stop right after.
        let uxCount = HeadlessRenderUX.run(dir: dir, now: now, logos: { logos.image(for: $0) }) { view, name, info in
            save(view, name, info)
        }
        print("  stranger UX: \(uxCount) PNGs")
        if ProcessInfo.processInfo.environment["YC_RENDER_ONLY"] == "ux" {
            print("RENDERED \(manifest.count) PNGs → \(dir.path) (\(failures) failed)")
            return failures == 0 ? 0 : 1
        }

        let looks: [(WidgetSnapshot.Style.Look, String)] = [(.paper, "light"), (.ink, "dark")]

        // Accented maps a logo's brightness onto its opacity (`.widgetAccentedRenderingMode(.desaturated)`,
        // which ImageRenderer ignores): the logos are handed over already converted.
        var accentedLogos: [String: NSImage] = [:]
        func logo(_ id: String, _ tone: WidgetStyle.Tone) -> NSImage? {
            guard tone == .accented else { return logos.image(forId: id) }
            if let done = accentedLogos[id] { return done }
            let out = logos.image(forId: id).flatMap(GlassComposite.accentedLogo)
            accentedLogos[id] = out
            return out
        }

        /// One widget image from a fixture, through JSON like the widget reads it. A monochrome `tone` draws
        /// it the way the extension does (`widgetRenderingMode` → `widgetTone`), then composites it as the
        /// system would over a dimmed desktop's glass; `ink` in the manifest is the share of the card drawn
        /// strongly (D-047: 0 = the blank panel, near 1 = a solid sheet).
        func widget(_ fixture: String, _ spec: WidgetKindSpec, _ family: Family, _ look: WidgetSnapshot.Style.Look,
                    _ lookName: String, prefix: String, tone: WidgetStyle.Tone = .color) {
            var info: [String: Any] = ["kind": spec.kind, "family": family.short, "look": lookName, "fixture": fixture,
                                       "mode": tone == .color ? "fullColor" : tone.rawValue]
            let data: WidgetData, style: WidgetStyle, page: Int
            if fixture == "noSnapshot" {
                data = .card(.noSnapshot, now: now)
                var s = WidgetStyle(); s.look = look == .ink ? .ink : .paper
                style = s
                page = 1
            } else {
                var snapshot = SnapshotFixtures.named(fixture, kind: spec.kind)
                snapshot.style.look = look
                let json = SnapshotFixtures.json(snapshot)
                if spec.kind == WidgetKinds.agenda.kind || fixture == "busy" && spec.kind == WidgetKinds.month.kind
                    || spec.kind == WidgetKinds.inbox.kind || spec.kind == WidgetKinds.day.kind {
                    try? json.write(to: dir.appendingPathComponent("fixtures/\(fixture)-\(spec.kind).json"))
                }
                guard let decoded = SnapshotFixtures.decode(json) else {
                    print("  ✗ \(fixture) \(spec.kind) does not decode")
                    failures += 1
                    return
                }
                let model = SnapshotModel(decoded, logo: { logo($0, tone) })
                let fixtureNow = fixture == "dst" ? SnapshotFixtures.dstNow : now
                data = model.data(at: fixtureNow)
                style = model.style(dark: look == .ink)
                page = model.page(family: family, at: fixtureNow)
            }
            info["state"] = "\(data.state)"
            info["page"] = page
            if let rows = KindView.meetingRows(spec: spec, family: family, data: data, style: style, page: page) { info["meetingRows"] = rows }
            if let rows = KindView.mailRows(spec: spec, family: family, data: data, style: style, page: page) { info["mailRows"] = rows }
            let pages = KindView.pageCount(spec: spec, family: family, data: data, style: style)
            if pages > 0 { info["pages"] = pages }
            let view = KindView(spec: spec, family: family, data: data, style: style, page: page)
                .environment(\.plainLinks, true)
            let name = "\(prefix)-\(spec.kind)-\(family.short)-\(lookName).png"
            guard tone != .color else { return save(view, name, info) }
            let renderer = ImageRenderer(content: RenderingModeBridge(content: view)
                .environment(\.widgetRenderingMode, tone == .accented ? .accented : .vibrant))
            renderer.scale = renderScale
            guard let drawn = renderer.cgImage, let glass = GlassComposite.apply(drawn, tone: tone, scale: renderScale) else {
                print("  ✗ \(name)")
                failures += 1
                return
            }
            info["ink"] = (glass.ink * 1000).rounded() / 1000
            write(glass.image, name, info)
        }

        // 1. Busy week: every kind × family × look (Inbox / Agenda & Inbox: the live sample inbox).
        for spec in WidgetKinds.all {
            for family in spec.families {
                for (look, lookName) in looks { widget("busy", spec, family, look, lookName, prefix: "widget") }
            }
        }
        let busyCount = manifest.count
        print("  busy week: \(busyCount) PNGs (12 kinds × families × light/dark)")

        // 2. States.
        let agenda = WidgetKinds.agenda, month = WidgetKinds.month, upNext = WidgetKinds.upNext, day = WidgetKinds.day
        let custom = { (letter: String) in WidgetKinds.spec("custom.\(letter)")! }
        let all = Family.allCases
        let states: [(String, [(WidgetKindSpec, [Family])])] = [
            ("busyPage2", [(agenda, [.large, .extraLarge, .extraLargePortrait])]),
            ("sparse", [(agenda, all), (month, [.medium, .large]), (day, all)]),
            ("dst", [(agenda, all), (month, [.large, .extraLarge]), (day, all)]),
            ("empty", [(agenda, all), (month, [.small, .large]), (upNext, [.small, .medium]), (day, all)]),
            ("noAccounts", [(agenda, all), (month, [.small, .large]), (day, [.small, .large])]),
            ("stale", [(agenda, all), (month, [.large]), (day, all)]),
            ("reauth", [(agenda, all), (month, [.large]), (upNext, [.small, .medium]), (day, all)]),
            ("mailComingSoon", [(WidgetKinds.inbox, WidgetKinds.inbox.families), (WidgetKinds.combo, WidgetKinds.combo.families)]),
            ("setup", [(custom("e"), all)]),
            ("customTitle", [(custom("a"), all)]),
            ("noSnapshot", [(agenda, all), (month, [.small]), (day, [.medium])]),
            ("mailArchived", [(WidgetKinds.inbox, WidgetKinds.inbox.families), (WidgetKinds.combo, WidgetKinds.combo.families)]),
            ("inboxZero", [(WidgetKinds.inbox, [.medium, .large]), (WidgetKinds.combo, [.large])]),
            ("justSynced", [(agenda, all), (month, [.small, .medium]), (upNext, [.small, .medium]),
                            (WidgetKinds.inbox, [.medium]), (WidgetKinds.combo, [.extraLarge]), (day, all)]),
            ("longMonth", [(month, all)]),
            // Day widget (D-022): the 20-meeting day, another day picked with ‹ › ("Today" chip), and
            // Custom F set to Day.
            ("busyDay", [(day, all)]),
            ("dayPicked", [(day, all)]),
            ("customDay", [(custom("f"), all)]),
        ]
        var stateCount = 0
        for (fixture, targets) in states {
            for (spec, families) in targets {
                for family in families {
                    for (look, lookName) in looks {
                        widget(fixture, spec, family, look, lookName, prefix: "state-\(fixture)")
                        stateCount += 1
                    }
                }
            }
        }
        print("  states: \(stateCount) PNGs (\(states.count) fixtures)")

        // 3. Accented and vibrant (a desktop not in focus, D-047) over the busy week, composited as macOS
        // draws them, and the whole-card and strip states on glass.
        var accentedCount = 0, vibrantCount = 0, glassStateCount = 0
        for spec in WidgetKinds.all {
            for family in spec.families {
                for (look, lookName) in looks {
                    widget("busy", spec, family, look, lookName, prefix: "accented", tone: .accented)
                    accentedCount += 1
                    widget("busy", spec, family, look, lookName, prefix: "vibrant", tone: .vibrant)
                    vibrantCount += 1
                }
            }
        }
        let glassStates: [(String, [(WidgetKindSpec, [Family])])] = [
            ("noSnapshot", [(agenda, all)]),
            ("noAccounts", [(day, all)]),
            ("setup", [(custom("e"), all)]),
            ("stale", [(day, all)]),
            ("reauth", [(agenda, all)]),
            ("empty", [(day, all), (month, [.small, .large])]),
            ("justSynced", [(upNext, [.small, .medium])]),
            ("mailArchived", [(WidgetKinds.inbox, [.medium, .large]), (WidgetKinds.combo, [.extraLargePortrait])]),
            ("inboxZero", [(WidgetKinds.inbox, [.large])]),
            ("busyDay", [(day, [.large, .extraLargePortrait])]),
        ]
        for (fixture, targets) in glassStates {
            for (spec, families) in targets {
                for family in families {
                    for tone in [WidgetStyle.Tone.accented, .vibrant] {
                        widget(fixture, spec, family, .paper, "light", prefix: "glass-\(tone.rawValue)-\(fixture)", tone: tone)
                        glassStateCount += 1
                    }
                }
            }
        }
        print("  accented: \(accentedCount) PNGs, vibrant: \(vibrantCount) PNGs, glass states: \(glassStateCount) PNGs")

        // 4. Windows: every section, Calendar states, Studio, the gallery, onboarding.
        var windowCount = 0
        let mailFixture = MailRenderFixture(now: now, directory: directory)
        func shell(_ section: AppSection, look: WidgetStyle.Look = .paper, calendar: CalendarSectionModel? = nil,
                   studio: WidgetStudioModel? = nil, inbox: InboxSectionModel? = nil, mail: Bool = true) -> ShellModel {
            let cal = calendar ?? CalendarSectionModel(clock: { now })
            if calendar == nil { cal.load() }
            let settingsMail = mailFixture.settings()
            return ShellModel(section: section, galleryLook: look, calendar: cal,
                              studio: studio ?? WidgetStudioModel(mailEnabled: { mail }),
                              inbox: inbox ?? mailFixture.inbox(), settingsMail: settingsMail,
                              menuBar: MenuBarSettingsModel(bag: MemoryBag(), mailEnabled: { mail }, state: { .on }, post: {}),
                              mailEnabled: { mail }, fixedNow: now)
        }
        func window(_ model: ShellModel, _ name: String, _ info: [String: Any]) {
            save(MainView(shell: model).frame(width: 1100, height: 740).environment(\.headlessRender, true), name, info)
            windowCount += 1
        }
        for section in AppSection.allCases where section != .inbox {
            window(shell(section), "window-\(section.rawValue).png", ["window": section.rawValue])
        }
        window(shell(.widgets, look: .ink), "window-widgets-dark.png", ["window": "widgets", "look": "dark"])

        let emptyStore = FakeCalendarStore(events: [])
        let empty = CalendarSectionModel(store: { emptyStore }, clock: { now }); empty.load()
        window(shell(.calendar, calendar: empty), "window-calendar-empty.png", ["window": "calendar", "state": "empty"])
        let none = CalendarSectionModel(directory: { AccountDirectory(accounts: []) }, clock: { now }); none.load()
        window(shell(.calendar, calendar: none), "window-calendar-noaccounts.png", ["window": "calendar", "state": "noAccounts"])
        let loading = CalendarSectionModel(clock: { now })
        window(shell(.calendar, calendar: loading), "window-calendar-loading.png", ["window": "calendar", "state": "loading"])
        let filtered = CalendarSectionModel(clock: { now }); filtered.load(); filtered.toggle(FixtureAccounts.cmt)
        window(shell(.calendar, calendar: filtered), "window-calendar-cmt.png", ["window": "calendar", "state": "filtered"])

        // Inbox section: reader with the remote-images bar, plain text, a mailbox, Starred, every state.
        var inboxCount = 0
        func inboxWindow(_ model: InboxSectionModel, _ name: String, _ state: String, mail: Bool = true) {
            window(shell(.inbox, inbox: model, mail: mail), "\(name).png", ["window": "inbox", "state": state])
            inboxCount += 1
        }
        inboxWindow(mailFixture.inbox(select: "th-milo"), "window-inbox", "reader-remote-images")
        inboxWindow(mailFixture.inbox(select: "th-milo", loadImages: true), "window-inbox-images-loaded", "reader-images-loaded")
        inboxWindow(mailFixture.inbox(select: "th-rafa"), "window-inbox-plain", "reader-plain-text")
        inboxWindow(mailFixture.inbox(mailbox: .account(FixtureAccounts.cmt), select: "th-lantern"), "window-inbox-cmt", "mailbox-cmt")
        inboxWindow(mailFixture.inbox(mailbox: .starred), "window-inbox-starred", "starred")
        inboxWindow(mailFixture.inbox(select: "th-sasha", archive: "th-jingle"), "window-inbox-toast", "archived-undo-toast")
        inboxWindow(mailFixture.inbox(threads: []), "window-inbox-zero", "inbox-zero")
        inboxWindow(mailFixture.inbox(load: false), "window-inbox-loading", "loading")
        inboxWindow(mailFixture.inbox(directory: AccountDirectory(accounts: [])), "window-inbox-noaccounts", "noAccounts")
        inboxWindow(mailFixture.inbox(failing: true), "window-inbox-failed", "failed")
        inboxWindow(mailFixture.inbox(), "window-inbox-labs-off", "labs-off", mail: false)
        print("  inbox: \(inboxCount) PNGs")

        // The paper card alone (reader width), and Settings → Mail in full.
        let milo = mailFixture.reader("th-milo")
        if let latest = milo.latest {
            let card = PaperMessageCard(message: latest, reader: milo, account: directory.account(FixtureAccounts.cmt),
                                        own: Set(FixtureMail.ownAddresses))
                .padding(22).frame(width: 560).fixedSize(horizontal: false, vertical: true)
                .background(AppTheme.background).environment(\.colorScheme, .dark).environment(\.headlessRender, true)
            save(card, "reader-remote-images.png", ["window": "reader", "state": "remote-images-bar"])
        }
        let sasha = mailFixture.reader("th-sasha")
        if let latest = sasha.latest {
            let card = PaperMessageCard(message: latest, reader: sasha, account: directory.account(FixtureAccounts.fam),
                                        own: Set(FixtureMail.ownAddresses))
                .padding(22).frame(width: 560).fixedSize(horizontal: false, vertical: true)
                .background(AppTheme.background).environment(\.colorScheme, .dark).environment(\.headlessRender, true)
            save(card, "reader-attachments.png", ["window": "reader", "state": "plain-text-attachments"])
        }
        // Settings → Mail with "Ask before sending to other people" on (the default) and off (D-023).
        for ask in [true, false] {
            let settingsMail = mailFixture.settings(ask: ask)
            let mailCard = SettingsMailCard(model: settingsMail)
                .padding(28).frame(width: 699).fixedSize(horizontal: false, vertical: true)
                .background(AppTheme.background).environment(\.colorScheme, .dark).environment(\.headlessRender, true)
            save(mailCard, ask ? "settings-mail.png" : "settings-mail-ask-off.png",
                 ["window": "settings-mail", "senders": settingsMail.senders.count, "askBeforeSending": ask])
        }

        // Composer windows: new, reply (quote + signature + the "I'll check with you" hint), reply all with the
        // hint naming two people, the approval card (D-023: one person, seven people, all listed with Cc / Bcc
        // tags; under a Light and a Dark Mac: the composer stays in the app's dark look, D-008; at the minimum
        // 560 × 480 the list scrolls, and a 60-character name wraps the title), the data layer's refusal,
        // "Sending… Undo", and the switch off.
        var composerCount = 0
        func composer(_ model: ComposerModel, _ name: String, _ state: String, mac: ColorScheme = .dark,
                      size: CGSize = CGSize(width: 640, height: 600)) {
            let view = ComposerView(model: model).frame(width: size.width, height: size.height)
                .environment(\.colorScheme, mac).environment(\.headlessRender, true)
            save(view, "\(name).png", ["window": "composer", "state": state, "mac": mac == .dark ? "dark" : "light",
                                        "height": Int(size.height)])
            composerCount += 1
        }
        composer(mailFixture.composer(.new(from: FixtureAccounts.orb)), "composer-new", "new")
        composer(mailFixture.composer(mailFixture.replyRequest("th-milo")), "composer-reply", "reply-quote-signature-hint")
        composer(mailFixture.composer(mailFixture.replyRequest("th-milo", all: true)), "composer-hint", "approval-hint")
        for mac in [ColorScheme.dark, .light] {
            let look = mac == .dark ? "dark" : "light"
            let single = mailFixture.composer(mailFixture.replyRequest("th-milo"))
            single.body = "Thanks Milo, all three are fixed. I\u{2019}ll send the updated flow before Tuesday.\n" + single.body
            mailFixture.settle { await single.send() }
            composer(single, "composer-approve-single-\(look)", "approval-single", mac: mac)
            let multi = mailFixture.composer(.new(from: FixtureAccounts.orb))
            multi.to = "Theo Quill <theo@moonbase.example>, ines@lanternhall.example, avery@quietcomets.example"
            multi.cc = "Juniper Vale <juniper@orbitalpickle.example>"
            multi.bcc = "ops@moonbase.example, finance@moonbase.example, legal@moonbase.example, bea@lanternhall.example"
            multi.showCcBcc = true
            multi.subject = "Q4 launch plan"
            multi.body = "Hi all, the plan is attached. Shout if anything looks off.\n" + multi.body
            mailFixture.settle { await multi.send() }
            composer(multi, "composer-approve-multi-\(look)", "approval-multi", mac: mac)
            if mac == .dark {
                // The composer at its minimum size (560 × 480): the people list scrolls (all seven on it), Send in view.
                composer(multi, "composer-approve-multi-compact", "approval-multi-compact", size: CGSize(width: 560, height: 480))
                // …and one person whose 60-character name wraps the title to two lines.
                let long = mailFixture.composer(.new(from: FixtureAccounts.orb))
                long.to = "Bartholomew Fernhollow-Copperpotsworth of Moon Base Holdings <bartholomew.fc@moonbase-holdings.example>"
                long.subject = "Contract renewal, signed copy"
                long.body = "Hi Bartholomew, the signed copy is attached.\n" + long.body
                mailFixture.settle { await long.send() }
                composer(long, "composer-approve-single-long", "approval-single-long-name", size: CGSize(width: 560, height: 480))
            }
        }
        // The data layer's refusal (the switch went on in Settings between the composer's check and the
        // send): an address outside your own, as the message says.
        let refused = mailFixture.composer(.new(from: FixtureAccounts.cmt), safeSend: false, refusal: true)
        refused.to = "milo@quietcomets.example"
        refused.subject = "Re: Mix notes before Tuesday"
        refused.body = "Thanks Milo, the updated flow is attached.\n\n" + refused.body
        mailFixture.settle { await refused.send() }
        composer(refused, "composer-refused", "send-refused")
        let sending = mailFixture.composer(.new(from: FixtureAccounts.home))
        sending.to = FixtureAccounts.all[1].email
        sending.subject = "[YC-TEST] Lunch notes"
        sending.body = "Café Nowhere was great. Same time next week?\n" + sending.body
        mailFixture.settle { await sending.send() }
        composer(sending, "composer-sending", "sending-undo")
        let open = mailFixture.composer(mailFixture.replyRequest("th-lantern"), safeSend: false)
        composer(open, "composer-safe-off", "safe-send-off")
        print("  composer: \(composerCount) PNGs")

        // Studio: a set-up custom slot, a fresh one, Month, a saved change.
        let settings = Services.widgetSettings as! FakeWidgetSettingsStore
        try? settings.save(WidgetSettings(kind: "custom.a", style: WidgetSnapshot.Style(look: .ink, typeface: "rounded"),
                                          title: "Work", customContent: .agenda,
                                          accountIds: [FixtureAccounts.orb, FixtureAccounts.fam], rangeDays: 2))
        func studio(_ kind: String, mail: Bool = true, _ edit: (WidgetStudioModel) -> Void = { _ in }) -> WidgetStudioModel {
            let m = WidgetStudioModel(kind: kind, mailEnabled: { mail })
            edit(m)
            return m
        }
        let studios: [(String, WidgetStudioModel)] = [
            ("studio-custom-a", studio("custom.a")),
            ("studio-custom-setup", studio("custom.e")),
            ("studio-custom-setup-labs-off", studio("custom.e", mail: false)),
            ("studio-month", studio("month") { $0.setLook(.ink); $0.setFont("serif") }),
            ("studio-agenda-saved", studio("agenda.all") { $0.setTextSize("large"); $0.save() }),
            ("studio-upnext-dirty", studio("upnext") { $0.setUse24Hour(true); $0.previewFamily = .medium }),
            ("studio-inbox", studio("inbox.all")),
            ("studio-custom-inbox", studio("custom.f") { $0.setName("Mail"); $0.setContent(.inbox); $0.previewFamily = .extraLarge }),
            ("studio-combo-dark", studio("combo.all") { $0.setLook(.ink); $0.previewFamily = .extraLarge }),
            ("studio-day", studio("day")),
            ("studio-custom-day", studio("custom.f") { $0.setName("Today"); $0.setContent(.day); $0.previewFamily = .medium }),
        ]
        for (name, model) in studios {
            // The Studio part only (the gallery below it is in gallery-full-*.png).
            let studioOnly = VStack(alignment: .leading) { WidgetStudioView(model: model, now: now) }
                .padding(28).frame(width: 899).fixedSize(horizontal: false, vertical: true)
                .background(AppTheme.background).environment(\.colorScheme, .dark).environment(\.headlessRender, true)
            save(studioOnly, "\(name).png", ["window": "studio", "kind": model.selectedKind])
            windowCount += 1
        }
        for (look, lookName) in [(WidgetStyle.Look.paper, "light"), (.ink, "dark")] {
            let gallery = WidgetsGalleryContent(shell: shell(.widgets, look: look))
                .frame(width: 899)
                .fixedSize(horizontal: false, vertical: true)
                .background(AppTheme.background)
                .environment(\.colorScheme, .dark)
                .environment(\.headlessRender, true)
            save(gallery, "gallery-full-\(lookName).png", ["window": "widgets-full", "look": lookName])
            windowCount += 1
        }
        let fresh = RenderAccounts.model(dir: dir, google: false, accounts: [], logos: logos)
        save(OnboardingView(model: OnboardingModel(accounts: fresh, bag: MemoryBag(), live: false), accounts: fresh, onDone: {})
                .environment(\.headlessRender, true), "sheet-onboarding.png", ["window": "onboarding", "step": 1])
        windowCount += 1
        print("  windows + studio: \(windowCount) PNGs")

        // 5. Peeks.
        var peekCount = 0
        let events = SnapshotFixtures.events()
        func event(_ title: String) -> CalendarEvent { events.first { $0.title == title }! }
        func peek(_ e: CalendarEvent, _ name: String, toast: String? = nil, back: String? = nil) {
            let model = EventPeekModel(event: e, directory: directory, actions: FakeCalendarStore(), open: { _ in true })
            model.toast = toast
            if let back { model.backTitle = back; model.onBack = {} }
            let view = PeekCard { EventPeekView(model: model) }.fixedSize(horizontal: false, vertical: true)
                .environment(\.headlessRender, true)
            let natural = NSHostingView(rootView: view).fittingSize.height
            save(view.padding(24).background(Color(hex: 0x3A4A55)), "\(name).png",
                 ["window": "peek", "event": e.r, "naturalHeight": Int(natural.rounded()), "scrolls": natural > PeekPlacement.maxHeight])
            peekCount += 1
        }
        peek(event("Pickle × Comets jingle weekly"), "peek-event-merged")
        peek(event("Album artwork walkthrough"), "peek-event-reply")
        peek(event("Lunch with Rafa"), "peek-event-personal")
        peek(event("Family day out"), "peek-event-allday")
        peek(event("The Comets weekly sync"), "peek-event-toast",
             toast: "I couldn\u{2019}t send your reply. Check your connection and try again.")
        peek(event("Mix notes with Milo"), "peek-event-from-day", back: "Back to Tuesday")
        let tuesday = WidgetCalendar.current.date(byAdding: .day, value: 1, to: WidgetCalendar.current.startOfDay(for: now))!
        let saturday = WidgetCalendar.current.date(byAdding: .day, value: 5, to: WidgetCalendar.current.startOfDay(for: now))!
        for (day, name) in [(tuesday, "peek-day"), (saturday, "peek-day-empty"), (WidgetCalendar.current.startOfDay(for: now), "peek-day-today")] {
            let model = DayPeekModel(kind: "month", day: day, directory: directory, now: now)
            let view = PeekCard { DayPeekView(model: model, onSelect: { _ in }, onClose: {}) }
                .fixedSize(horizontal: false, vertical: true).environment(\.headlessRender, true)
            save(view.padding(24).background(Color(hex: 0x3A4A55)), "\(name).png", ["window": "dayPeek", "events": model.events.count])
            peekCount += 1
        }
        // Mail Peek (`open/message`): a three-message thread with the images bar, plain text, attachments,
        // after Archive (toast with Undo).
        func mailPeek(_ model: MailPeekModel, _ name: String, _ state: String) {
            let view = PeekCard { MailPeekView(model: model) }.fixedSize(horizontal: false, vertical: true)
                .environment(\.headlessRender, true)
            let natural = NSHostingView(rootView: PeekCard { MailPeekView(model: model, measuring: true) }
                .fixedSize(horizontal: false, vertical: true)).fittingSize.height
            save(view.padding(24).background(Color(hex: 0x3A4A55)), "\(name).png",
                 ["window": "mailPeek", "state": state, "naturalHeight": Int(natural.rounded()), "fits": natural <= PeekPlacement.maxHeight])
            peekCount += 1
        }
        mailPeek(mailFixture.peek("th-milo"), "peek-mail", "thread-remote-images")
        mailPeek(mailFixture.peek("th-rafa"), "peek-mail-plain", "plain-text")
        mailPeek(mailFixture.peek("th-mom"), "peek-mail-attachments", "attachments")
        let gone = mailFixture.peek("th-juniper")
        mailFixture.settle { await gone.archive() }
        mailPeek(gone, "peek-mail-archived", "archived-undo")
        print("  peeks: \(peekCount) PNGs")

        // 6. The menu-bar popover, the status title, the welcome guide.
        var menuBarCount = 0
        func popover(_ model: PopoverModel, _ name: String, _ state: String, tab: PopoverModel.Tab = .agenda) {
            model.load()
            model.select(tab)
            let view = PopoverView(model: model).environment(\.headlessRender, true)
            save(view.padding(24).background(Color(hex: 0x3A4A55)), "\(name).png",
                 ["window": "popover", "state": state, "tab": tab.rawValue, "rows": model.eventCount, "threads": model.threads.count,
                  "card": model.card?.event.title ?? "", "width": Int(PopoverView.size.width), "height": Int(PopoverView.size.height)])
            menuBarCount += 1
        }
        let mailStores = FixtureServices.installMail()
        func popoverModel(events: [CalendarEvent] = SnapshotFixtures.events(), at time: Date = now, mail: Bool = true,
                          directory accountsDir: AccountDirectory? = nil, threads: [FixtureThread]? = nil, clock24: Bool = false) -> PopoverModel {
            let store = FakeCalendarStore(events: events)
            let mailStore = threads.map { FakeMailStore(threads: $0) } ?? mailStores.0
            let shownDirectory = accountsDir ?? directory
            return PopoverModel(store: { store }, actions: { store }, mail: { mailStore }, directory: { shownDirectory },
                                clock: { time }, mailEnabled: { mail }, syncedAt: { time.addingTimeInterval(-3 * 60) },
                                use24Hour: { clock24 })
        }
        popover(popoverModel(), "popover-agenda", "agenda-next-in-12-min")
        let during = WidgetCalendar.current.date(bySettingHour: 10, minute: 10, second: 0, of: now)!
        popover(popoverModel(at: during), "popover-agenda-live", "agenda-meeting-in-progress")
        let cmtOnly = popoverModel()
        cmtOnly.load(); cmtOnly.toggle(FixtureAccounts.cmt)
        popover(cmtOnly, "popover-agenda-cmt", "agenda-filtered-cmt")
        popover(popoverModel(clock24: true), "popover-agenda-24h", "agenda-24-hour-clock")
        popover(popoverModel(), "popover-inbox", "inbox", tab: .inbox)
        popover(popoverModel(threads: []), "popover-inbox-zero", "inbox-zero", tab: .inbox)
        popover(popoverModel(events: []), "popover-empty", "clear-week")
        popover(popoverModel(directory: AccountDirectory(accounts: [])), "popover-noaccounts", "no-accounts")
        popover(popoverModel(mail: false), "popover-labs-off", "mail-in-labs")
        // Join with Fathom (D-045): popover, Peek, Up Next Medium, Settings and the account card, a fake Fathom.
        let fathomCount = FathomRenders.run(dir: dir, now: now, directory: directory, logo: { logos.image(forId: $0) }) { view, name, info in
            save(view, name, info)
        }
        print("  fathom: \(fathomCount) PNGs")
        // Yaya's Murmur and recording per account (D-046): popover, Peek, account rows, Settings, Up Next; with and
        // without Murmur, fake sessions.
        let murmurCount = MurmurRenders.run(dir: dir, now: now, directory: directory, logo: { logos.image(forId: $0) }) { view, name, info in
            save(view, name, info)
        }
        print("  murmur: \(murmurCount) PNGs")
        // Yaya's Mail Helper (D-050): the section (Overview, Digest, the hand-over card), the Inbox's Priority chips and the
        // composer's Draft with AI; a fake session over the fixture files.
        let mailHelperCount = MailHelperRenders.run(dir: dir, now: now, directory: directory) { view, name, info in
            save(view, name, info)
        }
        print("  mail helper: \(mailHelperCount) PNGs")

        // The status item: glyph + title in a strip of menu bar, light and dark, for every title shape.
        let glyph = StatusItemController.glyph()
        let glyphSize = glyph.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none"
        func meeting(_ title: String, start: Date, minutes: Double) -> CalendarEvent {
            var e = SnapshotFixtures.events().first!
            e.r = "status-\(title.count)"
            e.title = title
            e.start = start
            e.end = start.addingTimeInterval(minutes * 60)
            e.allDay = false
            e.myResponse = .accepted
            return e
        }
        let nextUp = MeetingFocus.pick(SnapshotFixtures.events(), now: now)
        let titles: [(String, String, String)] = [
            ("icon", "Icon only", StatusTitle.text(mode: .icon, focus: nextUp, unread: nil, mailEnabled: true, now: now)),
            ("next", "Next meeting, 12 min away (fixture)", StatusTitle.text(mode: .next, focus: nextUp, unread: nil, mailEnabled: true, now: now)),
            ("during", "During it (10:10)", StatusTitle.text(mode: .next, focus: nextUp, unread: nil, mailEnabled: true, now: during)),
            ("short", "Short title", StatusTitle.countdown(meeting("Standup", start: now.addingTimeInterval(7 * 60), minutes: 15), now: now) ?? ""),
            ("left", "Short title, during", StatusTitle.countdown(meeting("Standup", start: now.addingTimeInterval(-3 * 60), minutes: 15), now: now) ?? ""),
            ("rtl", "Right-to-left title", StatusTitle.countdown(meeting("\u{05E4}\u{05D2}\u{05D9}\u{05E9}\u{05EA} \u{05E6}\u{05D5}\u{05D5}\u{05EA}", start: now.addingTimeInterval(7 * 60), minutes: 30), now: now) ?? ""),
            ("multiday", "Runs past 24 h", StatusTitle.countdown(meeting("Offsite", start: now.addingTimeInterval(-3600), minutes: 33 * 60), now: now) ?? ""),
            ("unread", "Unread count", StatusTitle.text(mode: .unread, focus: nil, unread: FixtureMail.unread, mailEnabled: true, now: now)),
        ]
        var strips: [AnyView] = []
        for (key, label, text) in titles {
            let strip = StatusStrip(glyph: glyph, title: text)
            save(strip.environment(\.headlessRender, true), "status-\(key).png",
                 ["window": "statusItem", "variant": key, "title": text, "chars": text.count, "glyph": glyphSize])
            menuBarCount += 1
            strips.append(AnyView(HStack(spacing: 14) {
                Text(label).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text2).frame(width: 220, alignment: .leading)
                strip
            }))
        }
        let sheetOfStrips = VStack(alignment: .leading, spacing: 10) { ForEach(0..<strips.count, id: \.self) { strips[$0] } }
            .padding(20).background(AppTheme.background).environment(\.colorScheme, .dark)
        save(sheetOfStrips, "status-titles.png", ["window": "statusItem", "variant": "all", "glyph": glyphSize])
        menuBarCount += 1

        // The welcome guide at each step, then all done.
        let records = RenderAccounts.records(now: now)
        let guides: [(String, Bool, [AccountRecord], OnboardingStep, Bool, Bool, String)] = [
            ("onboarding-1-google", false, [], .google, false, false, "undetermined"),
            ("onboarding-2-accounts", true, [], .accounts, false, false, "undetermined"),
            ("onboarding-3-looks", true, records, .looks, false, false, "undetermined"),
            ("onboarding-4-widget", true, records, .widget, true, false, "undetermined"),
            ("onboarding-5-notifications", true, records, .notifications, true, true, "undetermined"),
            ("onboarding-done", true, records, .notifications, true, true, "granted"),
        ]
        for (name, google, accounts, step, looks, widget, notes) in guides {
            let model = RenderAccounts.model(dir: dir, google: google, accounts: accounts, logos: logos)
            let bag = MemoryBag([OnboardingFlow.looksKey: looks, OnboardingFlow.widgetKey: widget,
                                 OnboardingFlow.runningKey: name == "onboarding-done"])
            let guide = OnboardingModel(accounts: model, bag: bag, live: false, notifications: notes, shown: step)
            save(OnboardingView(model: guide, accounts: model, onDone: {}).environment(\.headlessRender, true), "\(name).png",
                 ["window": "onboarding", "step": step.rawValue, "done": OnboardingFlow.doneCount(guide.facts)])
            menuBarCount += 1
        }
        for (state, menuBar) in [("on", MenuBarSettingsModel(bag: MemoryBag(), mailEnabled: { true }, state: { .on }, post: {})),
                                 ("taken", MenuBarSettingsModel(bag: MemoryBag(), mailEnabled: { true }, state: { .taken }, post: {}))] {
            let card = SettingsMenuBarCard(model: menuBar, openGuide: {})
                .padding(28).frame(width: 699).fixedSize(horizontal: false, vertical: true)
                .background(AppTheme.background).environment(\.colorScheme, .dark).environment(\.headlessRender, true)
            save(card, "settings-menubar\(state == "on" ? "" : "-taken").png", ["window": "settings-menubar", "hotkey": state])
            menuBarCount += 1
        }
        print("  Menu bar (popover, status title, welcome guide): \(menuBarCount) PNGs")

        // Checks the gate also reads back from the manifest.
        let large = manifest.first { ($0["fixture"] as? String) == "busy" && ($0["kind"] as? String) == "agenda.all"
            && ($0["family"] as? String) == "L" && ($0["look"] as? String) == "light" && ($0["mode"] as? String) == "fullColor" }
        let largeRows = large?["meetingRows"] as? Int ?? 0
        print("CHECK busy agenda.all L page 1 meetingRows=\(largeRows) (need ≥10) \(largeRows >= 10 ? "pass" : "FAIL")")
        if largeRows < 10 { failures += 1 }
        let inboxLarge = manifest.first { ($0["fixture"] as? String) == "busy" && ($0["kind"] as? String) == "inbox.all"
            && ($0["family"] as? String) == "L" && ($0["look"] as? String) == "light" && ($0["mode"] as? String) == "fullColor" }
        let inboxRows = inboxLarge?["mailRows"] as? Int ?? 0
        print("CHECK busy inbox.all L page 1 mailRows=\(inboxRows) (need ≥10) \(inboxRows >= 10 ? "pass" : "FAIL")")
        if inboxRows < 10 { failures += 1 }

        RichMailRenders.run(dir: dir, now: now, save: save)
        RichComposerRenders.run(dir: dir, now: now) { save($0, $1, $2) }
        let manifestURL = dir.appendingPathComponent("render-manifest.json")
        let document: [String: Any] = [
            "app": "yayascalendar",
            "build": AppInfo.build,
            "now": ISO8601DateFormatter().string(from: now),
            "timeZone": WidgetCalendar.current.timeZone.identifier,
            "logos": logos.source,
            "counts": ["busy": busyCount, "states": stateCount, "accented": accentedCount, "vibrant": vibrantCount,
                       "glassStates": glassStateCount, "windows": windowCount, "peeks": peekCount,
                       "inbox": inboxCount, "composer": composerCount, "menuBar": menuBarCount],
            "images": manifest,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: manifestURL)
        } else {
            failures += 1
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        print("RENDERED \(manifest.count) PNGs in \(seconds) s → \(dir.path) (\(failures) failed)")
        return failures == 0 ? 0 : 1
    }
}

/// Maps `widgetRenderingMode` onto the shared views' `widgetTone` (what the extension's entry view
/// does), so `.environment(\.widgetRenderingMode, .accented)` renders the accented glass palette.
private struct RenderingModeBridge<Content: View>: View {
    @Environment(\.widgetRenderingMode) private var mode
    let content: Content

    var body: some View { content.environment(\.widgetTone, WidgetStyle.Tone(mode)) }
}

/// What macOS makes of a widget it draws accented or vibrant (D-047), for renders. The container background
/// is gone and the content lies on the desktop's glass. Accented paints every pixel white and keeps its
/// opacity; vibrant desaturates and keeps its brightness ("maps greyscale content into a material"): one
/// strength `k` per pixel, over a mid-grey glass. `ink` is the share of the card at k ≥ 0.5, the parts the
/// system draws strongly: 1.0.0's widgets came out near 1 accented (their paper sheet became one white
/// panel over the text) and near 0 vibrant on Light (dark text has no brightness left to keep).
enum GlassComposite {
    static let glass: (r: Double, g: Double, b: Double) = (0.30, 0.34, 0.37)

    static func apply(_ image: CGImage, tone: WidgetStyle.Tone, scale: Double) -> (image: CGImage, ink: Double)? {
        let w = image.width, h = image.height
        guard var px = rgba(image) else { return nil }
        let radius = 24 * scale
        var strong = 0, inside = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard inCard(Double(x) + 0.5, Double(y) + 0.5, w: Double(w), h: Double(h), r: radius) else {
                    px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
                    continue
                }
                let a = Double(px[i + 3]) / 255
                let k: Double
                if tone == .accented {
                    k = a
                } else {
                    // Premultiplied: luminance × alpha straight from the stored channels.
                    k = (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
                }
                inside += 1
                if k >= 0.5 { strong += 1 }
                px[i] = UInt8(((glass.r + (1 - glass.r) * k) * 255).rounded())
                px[i + 1] = UInt8(((glass.g + (1 - glass.g) * k) * 255).rounded())
                px[i + 2] = UInt8(((glass.b + (1 - glass.b) * k) * 255).rounded())
                px[i + 3] = 255
            }
        }
        guard let out = make(px, w: w, h: h) else { return nil }
        return (out, inside > 0 ? Double(strong) / Double(inside) : 0)
    }

    /// `.widgetAccentedRenderingMode(.desaturated)`: white, with the logo's brightness as its opacity.
    static func accentedLogo(_ logo: NSImage) -> NSImage? {
        guard let cg = logo.cgImage(forProposedRect: nil, context: nil, hints: nil), var px = rgba(cg) else { return nil }
        for i in stride(from: 0, to: px.count, by: 4) {
            let k = (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
            let v = UInt8((k * 255).rounded())
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = v
        }
        return make(px, w: cg.width, h: cg.height).map { NSImage(cgImage: $0, size: logo.size) }
    }

    private static func inCard(_ x: Double, _ y: Double, w: Double, h: Double, r: Double) -> Bool {
        let cx = min(max(x, r), w - r), cy = min(max(y, r), h - r)
        return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
    }

    /// Premultiplied RGBA8 in sRGB.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    private static func make(_ px: [UInt8], w: Int, h: Int) -> CGImage? {
        var copy = px
        return copy.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

/// Badges for the fixture accounts: the cast's own, drawn in code (`Cast.badge`). Renders never read a
/// logo file, so every Mac draws the same PNGs and they carry only the fictional cast.
private struct RenderLogos {
    var images: [UUID: NSImage] = [:]
    var source = "cast badges (drawn in code)"

    static func load() -> RenderLogos {
        var out = RenderLogos()
        for account in Cast.accounts {
            if let image = Cast.badge(key: account.key) { out.images[account.id] = image }
        }
        return out
    }

    func image(for id: UUID) -> NSImage? { images[id] }
    func image(forId id: String) -> NSImage? { UUID(uuidString: id).flatMap { images[$0] } }
}

/// Fixture-backed mail models for renders: fakes behind every seam, memory instead of user defaults,
/// pinned clock, toasts that never expire mid-render, async work settled on the main run loop.
@MainActor
private struct MailRenderFixture {
    let now: Date
    let directory: AccountDirectory

    final class Box { var done = false }

    /// Runs async work to completion on the main actor (the render is synchronous).
    func settle(_ work: @escaping @MainActor () async -> Void) {
        let box = Box()
        Task { @MainActor in
            await work()
            box.done = true
        }
        let limit = Date().addingTimeInterval(5)
        while !box.done, Date() < limit { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    func toasts() -> MailToastCenter { MailToastCenter(clock: { now }, schedule: { _, _ in }) }

    func stores(threads: [FixtureThread]? = nil, failing: Bool = false) -> (FakeMailStore, FakeMailActions, FakeMailPreferences) {
        let store = FakeMailStore(threads: threads ?? FixtureMail.threads(now: now))
        if failing { store.loadError = ServiceError(description: "offline") }
        let prefs = FakeMailPreferences()
        prefs.allowed = ["team@orbitalpickle.example", "noreply@photovault.example"]
        return (store, FakeMailActions(store: store), prefs)
    }

    func inbox(mailbox: InboxSectionModel.Mailbox = .unified, select: String? = nil, loadImages: Bool = false,
               archive: String? = nil, threads: [FixtureThread]? = nil, directory: AccountDirectory? = nil,
               failing: Bool = false, load: Bool = true) -> InboxSectionModel {
        let (store, actions, prefs) = stores(threads: threads, failing: failing)
        let dir = directory ?? self.directory
        let model = InboxSectionModel(store: { store }, actions: { actions }, prefs: { prefs }, directory: { dir },
                                      clock: { now }, undoBook: MailUndoBook(), local: MemoryMailLocalStore(),
                                      toasts: toasts(), compose: { _ in })
        guard load else { return model }
        model.load()
        if mailbox != .unified { model.select(mailbox: mailbox) }
        if let archive { settle { await model.archive(archive) } }
        if let select { settle { await model.select(r: select) } }
        if loadImages, let reader = model.reader, let latest = reader.latest { reader.loadImages(latest) }
        return model
    }

    func reader(_ r: String) -> ThreadReaderModel {
        let fixture = FixtureMail.threads(now: now).first { $0.thread.r == r }!
        let prefs = FakeMailPreferences()
        return ThreadReaderModel(thread: fixture.thread, messages: fixture.messages, prefs: { prefs })
    }

    func replyRequest(_ r: String, all: Bool = false) -> ComposerRequest {
        let fixture = FixtureMail.threads(now: now).first { $0.thread.r == r }!
        return .reply(fixture.thread, fixture.messages.max { $0.date < $1.date }, all: all)
    }

    func composer(_ request: ComposerRequest, safeSend: Bool = true, refusal: Bool = false) -> ComposerModel {
        let (_, actions, prefs) = stores()
        if refusal {
            actions.sendError = ServiceError(description: MailActionService.safeSendMessage)
        }
        let local = MemoryMailLocalStore()
        return ComposerModel(request: request, accounts: directory.accounts, safeSend: safeSend, actions: { actions },
                             prefs: { prefs }, local: local, clock: { now }, schedule: { _, _ in }, toasts: toasts())
    }

    func peek(_ r: String) -> MailPeekModel {
        let fixture = FixtureMail.threads(now: now).first { $0.thread.r == r }!
        let (_, actions, prefs) = stores()
        let reader = ThreadReaderModel(thread: fixture.thread, messages: fixture.messages, prefs: { prefs })
        return MailPeekModel(thread: fixture.thread, directory: directory, reader: reader, actions: { actions },
                             clock: { now }, undoBook: MailUndoBook(), toasts: toasts())
    }

    func settings(ask: Bool = true) -> SettingsMailModel {
        let prefs = FakeMailPreferences()
        prefs.allowed = ["team@orbitalpickle.example", "noreply@photovault.example"]
        let model = SettingsMailModel(prefs: { prefs }, directory: { directory }, local: MemoryMailLocalStore(), safeSend: { ask },
                                      setSafeSend: { _ in })
        model.load()
        return model
    }
}

/// A strip of menu bar with the status item as macOS draws it: the template glyph, then the title in the
/// menu-bar font with even digits. Light and dark menu bars side by side.
private struct StatusStrip: View {
    let glyph: NSImage?
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            bar(dark: false)
            bar(dark: true)
        }
    }

    private func bar(dark: Bool) -> some View {
        let ink = dark ? Color.white : Color.black.opacity(0.85)
        return HStack(spacing: 4) {
            if let glyph {
                Image(nsImage: glyph).renderingMode(.template).foregroundStyle(ink)
                    .frame(width: glyph.size.width, height: glyph.size.height)
            }
            if !title.isEmpty {
                Text(title).font(Font(StatusItemController.titleFont as CTFont)).foregroundStyle(ink).fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(dark ? Color(hex: 0x1E1E22) : Color(hex: 0xECECEE))
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Accounts stores for the guide's renders: fakes behind every seam, files under `<dir>/scratch`
/// (never opened: nothing here loads or saves), no Keychain, no network.
@MainActor
private enum RenderAccounts {
    struct Vault: AccountVault {
        func items() throws -> [VaultItem] { [] }
        func deleteCredential(_ accountId: UUID) throws -> Bool { false }
        func readCredential(_ accountId: UUID) throws -> StoredCredential { throw AuthError.cancelled }
        func saveCredential(_ credential: StoredCredential, for accountId: UUID) throws {}
    }

    struct Clients: ProviderClientStore {
        func load(_ provider: Provider) throws -> ProviderClient? { nil }
        func save(_ client: ProviderClient, for provider: Provider) throws {}
    }

    static func model(dir: URL, google: Bool, accounts: [AccountRecord], logos: RenderLogos) -> AccountsModel {
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        let env = AccountsEnvironment(
            storeURL: scratch.appendingPathComponent("store.sqlite"),
            logosDirectory: scratch.appendingPathComponent("logos", isDirectory: true),
            vault: Vault(), clients: Clients(),
            authorize: { _, _, _, _, _ in throw AuthError.cancelled },
            makeRefresher: { _, _ in { _ in throw AuthError.cancelled } },
            revoke: { _, _, _ in false },
            fetchLogo: { _ in nil },
            copyToPasteboard: { _ in },
            openInBrowser: { _ in false },
            findDeveloperClient: { nil },
            now: { WidgetSample.fixedNow })
        let model = AccountsModel(environment: env)
        model.google = google ? .ready(clientIDHint: "\u{2026}apps.googleusercontent.com") : .missing
        model.accounts = accounts
        var images: [UUID: NSImage] = [:]
        for a in accounts { if let image = logos.image(for: a.id) { images[a.id] = image } }
        model.logos = images
        return model
    }

    static func records(now: Date) -> [AccountRecord] {
        FixtureAccounts.all.enumerated().map { i, a in
            AccountRecord(id: a.id, provider: "google", email: a.email, displayName: a.name, tag: a.tag, color: a.color,
                          logoFile: nil, sortOrder: i, health: .ok, createdAt: now)
        }
    }
}
#endif
