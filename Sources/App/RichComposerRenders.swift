// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import SwiftUI

/// Rich composer renders (`rm-composer-*`, `rm-settings-*`) and the composer's
/// `RICHMAIL-BENCH` lines. The fictional Moonfield cast only (RichMailCast, RichComposerFixtures): memory
/// stores, a pinned clock, no network, no Keychain, no user defaults. The editor draws offscreen through
/// `RichTextSnapshot.textSnapshot` (ImageRenderer can't draw an NSTextView).
@MainActor
enum RichComposerRenders {
    /// Renders every case through `save` and returns how many it tried.
    @discardableResult
    static func run(dir: URL, now: Date, save: (AnyView, String, [String: Any]) -> Void) -> Int {
        var count = 0
        func composer(_ model: ComposerModel, _ name: String, _ state: String, mac: ColorScheme = .dark,
                      size: CGSize = CGSize(width: 640, height: 600)) {
            let view = ComposerView(model: model).frame(width: size.width, height: size.height)
                .environment(\.colorScheme, mac).environment(\.headlessRender, true)
            save(AnyView(view), "\(name).png", ["window": "rich-mail", "surface": "composer", "state": state,
                                                "mac": mac == .dark ? "dark" : "light", "height": Int(size.height),
                                                "format": model.format == .rich ? "rich" : "plain",
                                                "quote": model.quote == nil ? "none" : model.quoteExpanded ? "open" : "collapsed",
                                                "quoteCollapsed": model.quote != nil && !model.quoteExpanded])
            count += 1
        }

        for mac in [ColorScheme.light, .dark] {
            let look = mac == .dark ? "dark" : "light"
            composer(newMail(now: now), "rm-composer-new-\(look)", "new", mac: mac)
            composer(formatted(now: now), "rm-composer-formatted-\(look)", "formatted", mac: mac)
            composer(reply(now: now), "rm-composer-reply-\(look)", "reply-quote-collapsed", mac: mac)
        }
        let open = reply(now: now)
        open.quoteExpanded = true
        composer(open, "rm-composer-reply-quote-open", "reply-quote-open")
        let headerLocal = MemoryMailLocalStore()
        headerLocal.setString(MailQuoteRequest.Style.header.rawValue, RichMailSettings.quoteStyleKey)
        let header = reply(now: now, local: headerLocal)
        header.quoteExpanded = true
        composer(header, "rm-composer-reply-header-style", "reply-header-style")
        composer(reply(now: now, format: .plain), "rm-composer-plain-mode", "plain-mode")
        composer(formatted(now: now), "rm-composer-narrow", "narrow-toolbar-overflow", size: CGSize(width: 560, height: 480))

        let linking = formatted(now: now)
        let word = (linking.document.string as NSString).range(of: "tasting notes")
        linking.editorSelected(word, typing: [:])
        linking.beginLink()
        linking.linkDraft?.url = "https://cafenowhere.example/tasting"
        composer(linking, "rm-composer-link-popover", "link-popover")
        let coloring = formatted(now: now)
        coloring.editorSelected((coloring.document.string as NSString).range(of: "Q4 pickle launch"), typing: [:])
        coloring.popover = .color
        composer(coloring, "rm-composer-color-popover", "color-popover")

        // Settings → Mail: the Writing block and a rich signature.
        let settings = settingsModel()
        let card = SettingsMailCard(model: settings)
            .padding(28).frame(width: 699).fixedSize(horizontal: false, vertical: true)
            .background(AppTheme.background).environment(\.colorScheme, .dark).environment(\.headlessRender, true)
        save(AnyView(card), "rm-settings-mail-writing.png", ["window": "rich-mail", "surface": "settings", "state": "writing",
                                                            "font": settings.writing.font.rawValue, "size": settings.writing.size.rawValue])
        count += 1
        if let orb = settings.rows.first(where: { $0.id == RichMailCast.orb.id }) {
            let block = VStack(alignment: .leading, spacing: 6) {
                Text("SIGNATURE").font(AppTheme.font(10, .bold)).tracking(0.5).foregroundStyle(AppTheme.text3)
                RichSignatureEditor(model: settings, row: orb)
                HStack(spacing: 12) {
                    Button("Save signature") {}.buttonStyle(PrimaryButtonStyle())
                    Text("Undo changes").font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                }
            }
            .padding(18).frame(width: 520)
            .background(AppTheme.background).environment(\.colorScheme, .dark).environment(\.headlessRender, true)
            save(AnyView(block), "rm-settings-signature-rich.png", ["window": "rich-mail", "surface": "settings", "state": "signature-rich",
                                                                   "account": RichMailCast.orb.key])
            count += 1
        }
        print("  rich composer: \(count) PNGs")
        bench()
        count += RichSendRenders.run(dir: dir, now: now, save: save)
        return count
    }

    // MARK: Models (cast only)

    static func model(_ request: ComposerRequest, now: Date, local: MailLocalStore = MemoryMailLocalStore(),
                      format: ComposerFormat? = nil) -> ComposerModel {
        let actions = FakeMailActions(store: FakeMailStore())
        let prefs = RichComposerFixtures.prefs()
        return ComposerModel(request: request, accounts: RichComposerFixtures.directory().accounts, safeSend: true,
                             actions: { actions }, prefs: { prefs }, local: local, clock: { now }, schedule: { _, _ in },
                             toasts: MailToastCenter(clock: { now }, schedule: { _, _ in }), format: format)
    }

    static func newMail(now: Date) -> ComposerModel {
        let m = model(.new(from: RichMailCast.orb.id), now: now)
        m.to = RichMailCast.juniper.display
        m.subject = "Pickle jar labels"
        m.body = "Hi Juniper,\n\nThe proofs for the dill jars are attached. Teal or red for the lid?\n" + m.body
        m.editorSelected(NSRange(location: 11, length: 0), typing: [:])
        return m
    }

    static func reply(now: Date, local: MailLocalStore = MemoryMailLocalStore(), format: ComposerFormat? = nil) -> ComposerModel {
        let m = model(RichComposerFixtures.juniperReply(now: now), now: now, local: local, format: format)
        m.body = "Teal it is. Proofs back to you by Wednesday.\n" + m.body
        return m
    }

    /// Bold, italic, a colour, a highlight, a bulleted list with a nested item, a numbered list, a quote block and a
    /// link, built through the same operations the toolbar uses.
    static func formatted(now: Date) -> ComposerModel {
        let m = model(.new(from: RichMailCast.orb.id), now: now)
        m.to = RichMailCast.priya.display + ", " + RichMailCast.milo.display
        m.subject = "Q4 pickle launch: the plan"
        m.body = """
        Hi Priya and Milo,

        Here is the Q4 pickle launch plan, short version:
        Labels printed by Thursday
        Teal lids for dill
        Red lids for chili
        Tasting at Café Nowhere with our tasting notes
        Budget review in Suite 404
        Send proofs
        Book the van
        Juniper's note: keep the jars under 400 g so they ship in one box.

        """ + m.body
        func range(_ text: String) -> NSRange { (m.document.string as NSString).range(of: text) }
        func at(_ text: String) -> NSRange { NSRange(location: range(text).location, length: 0) }
        m.apply(.bold, range: range("Priya"))
        m.apply(.bold, range: range("Milo"))
        m.apply(.bold, range: range("Q4 pickle launch"))
        m.apply(.color(0x1967D2), range: range("Q4 pickle launch"))
        m.apply(.italic, range: range("short version"))
        m.apply(.list(.bullet), range: NSRange(location: range("Labels printed").location,
                                               length: NSMaxRange(range("Budget review in Suite 404")) - range("Labels printed").location))
        m.apply(.indent, range: NSRange(location: range("Teal lids").location, length: NSMaxRange(range("Red lids for chili")) - range("Teal lids").location))
        m.apply(.highlight(0xFFF475), range: range("Thursday"))
        m.apply(.link("https://cafenowhere.example"), range: range("Café Nowhere"))
        m.apply(.list(.number), range: NSRange(location: range("Send proofs").location, length: NSMaxRange(range("Book the van")) - range("Send proofs").location))
        m.apply(.quote, range: at("Juniper's note"))
        m.apply(.underline, range: range("under 400 g"))
        m.editorSelected(range("Q4 pickle launch"), typing: [:])
        return m
    }

    static func settingsModel() -> SettingsMailModel {
        let local = MemoryMailLocalStore()
        var writing = RichMailSettings()
        writing.font = .sans
        writing.size = .normal
        writing.save(to: local)
        let prefs = RichComposerFixtures.prefs()
        let model = SettingsMailModel(prefs: { prefs }, directory: { RichComposerFixtures.directory() }, local: local,
                                      safeSend: { true }, setSafeSend: { _ in })
        model.load()
        return model
    }

    // MARK: RICHMAIL-BENCH (the optimised -O dev build that --render runs)

    static func benchDocument(pages: Int, imageEvery: Int = 0) -> NSAttributedString {
        let d = ComposerDocument.Defaults()
        let doc = NSMutableAttributedString()
        let paragraphsPerPage = 16
        var images = 0
        for k in 0..<(pages * paragraphsPerPage) {
            let start = doc.length
            doc.append(ComposerDocument.plain("Paragraph \(k): the Comets tour, the pickle launch at Café Nowhere and the rehearsal at the lake house, "
                                              + "with a bold word and a link to the set list that wraps over a few lines of the editor.\n", defaults: d))
            let p = NSRange(location: start, length: doc.length - start)
            let ns = doc.string as NSString
            let bold = ns.range(of: "bold word", options: [], range: p)
            ComposerDocument.apply(.bold, to: doc, selection: bold, defaults: d)
            let link = ns.range(of: "set list", options: [], range: p)
            ComposerDocument.apply(.link("https://quietcomets.example/setlist/\(k)"), to: doc, selection: link, defaults: d)
            if k % 7 == 3 { ComposerDocument.apply(.color(0x1967D2), to: doc, selection: ns.range(of: "pickle launch", options: [], range: p), defaults: d) }
            if k % 11 == 5 { ComposerDocument.apply(.list(.bullet), to: doc, selection: NSRange(location: start, length: 0), defaults: d) }
            if imageEvery > 0, k % imageEvery == imageEvery / 2, images < 3 {
                let data = FakeMailAttachments.image(FakeMailAttachments.Part(threadR: "bench", messageId: "bench", partId: "\(k)",
                                                                              mimeType: "image/png", bytes: 0, pixels: (480, 320)), type: .png) ?? Data()
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = "photo-\(k).png"
                let attachment = NSTextAttachment(fileWrapper: wrapper)
                attachment.bounds = CGRect(x: 0, y: 0, width: 480, height: 320)
                doc.insert(NSAttributedString(attachment: attachment), at: start)
                images += 1
            }
        }
        return doc
    }

    static func bench() {
        // Keystroke latency: a 20-page rich document in an offscreen editor; each key = insert, the model update the
        // editor sends (copy + toolbar state), layout of the visible part and drawing it.
        let big = benchDocument(pages: 20)
        let m = model(.new(from: RichMailCast.orb.id), now: Date())
        let (_, view) = ComposerTextView.make(mode: .rich)
        view.frame = NSRect(x: 0, y: 0, width: 596, height: 700)
        view.textContainer?.containerSize = NSSize(width: 596, height: CGFloat.greatestFiniteMagnitude)
        view.load(big)
        view.textLayoutManager.map { $0.ensureLayout(for: $0.documentRange) }
        let caret = big.length / 2
        view.setSelectedRange(NSRange(location: caret, length: 0))
        let used = view.textLayoutManager?.usageBoundsForTextContainer.height ?? 700
        view.frame = NSRect(x: 0, y: 0, width: 596, height: used + 24)
        let caretY = view.textLayoutManager.flatMap { tlm -> CGFloat? in
            guard let location = tlm.location(tlm.documentRange.location, offsetBy: caret) else { return nil }
            return tlm.textLayoutFragment(for: location)?.layoutFragmentFrame.minY
        } ?? 0
        let visible = NSRect(x: 0, y: max(0, caretY - 300), width: 596, height: 600)
        let rep = view.bitmapImageRepForCachingDisplay(in: visible)
        var times: [Double] = []
        for _ in 0..<60 {
            let t0 = Date()
            view.insertText("a", replacementRange: view.selectedRange())
            m.editorChanged(NSAttributedString(attributedString: view.textStorage!))
            m.editorSelected(view.selectedRange(), typing: view.typingAttributes)
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            if let rep { view.cacheDisplay(in: visible, to: rep) }
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
        times.sort()
        let median = times[times.count / 2], p95 = times[Int(Double(times.count) * 0.95)]
        print(String(format: "RICHMAIL-BENCH composer-keystroke median=%.2fms p95=%.2fms budget=16ms chars=%d %@",
                     median, p95, big.length, p95 < 16 ? "pass" : "OVER"))

        // MailHTMLWriter: 10 pages, ~200 runs, 3 images.
        let ten = benchDocument(pages: 10, imageEvery: 30)
        var runs = 0
        ten.enumerateAttributes(in: NSRange(location: 0, length: ten.length)) { _, _, _ in runs += 1 }
        var writer: [Double] = []
        var images = 0
        for _ in 0..<5 {
            let t0 = Date()
            images = MailHTMLWriter.render(ten, font: .sans, size: 14).inlineImages.count
            writer.append(Date().timeIntervalSince(t0) * 1000)
        }
        writer.sort()
        print(String(format: "RICHMAIL-BENCH writer-render median=%.2fms budget=30ms runs=%d images=%d chars=%d %@",
                     writer[2], runs, images, ten.length, writer[2] <= 30 ? "pass" : "OVER"))

        // Toolbar state on a selection change in the 20-page document (caret, and a 3-paragraph selection).
        let ns = big.string as NSString
        let three = ns.paragraphRange(for: NSRange(location: caret, length: 400))
        var state: [Double] = []
        for k in 0..<40 {
            let range = k % 2 == 0 ? NSRange(location: caret + k, length: 0) : three
            let t0 = Date()
            _ = ComposerDocument.formatting(big, selection: range, typing: [:], defaults: ComposerDocument.Defaults())
            state.append(Date().timeIntervalSince(t0) * 1000)
        }
        state.sort()
        let statep95 = state[Int(Double(state.count) * 0.95)]
        print(String(format: "RICHMAIL-BENCH toolbar-state p95=%.3fms budget=4ms %@", statep95, statep95 <= 4 ? "pass" : "OVER"))
    }
}
#endif
