// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import SwiftUI
import WebKit

/// The reader's `rm-*` renders (the viewer). Each message of a cast thread goes through the data layer's
/// own path: a Gmail `format=full` message is built from `RichMailBodies`, parsed and sanitized by
/// `CachedMessage.parsed`, then marked (quotes) or converted (plain text) by `CachedMessage.message(blockRemote:)`.
/// The card is drawn twice: once to learn the width each body is laid out at, then with a web snapshot of that
/// body at exactly that width. Inline images come from `FakeMailAttachments` (bytes generated in code, in
/// `<dir>/scratch`), rule lists compile into `<dir>/scratch` too. No window, no network: renders that show
/// "images loaded" swap the two remote URLs for generated data: images (`remoteImages: simulated-local`).
@MainActor
enum RichMailReaderRenders {
    typealias Save = (AnyView, String, [String: Any]) -> Void

    static func run(dir: URL, now: Date, save: @escaping Save) {
        let started = Date()
        let scratch = dir.appendingPathComponent("scratch/rich-mail", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let r = Renderer(now: now, save: save, attachments: FakeMailAttachments(folder: scratch.appendingPathComponent("attachments")),
                         rules: MailRuleLists(store: WKContentRuleListStore(url: scratch.appendingPathComponent("rules", isDirectory: true))))
        bench()
        r.reader()
        r.peeks()
        RichMailAttachmentRenders.run(save: save, attachments: r.attachments)
        r.window()
        // The hovered link's real destination, where the reader shows it: the pane's visible bottom-left.
        r.window(RichMailThreads.gmailReply, name: "rm-reader-hover-url", state: "hover-url",
                 hover: URL(string: "https://proofs.orbitalpickle.example/labels/v3?print=thursday"))
        let snaps = r.snapshotSeconds
        let average = snaps.isEmpty ? 0 : snaps.reduce(0, +) / Double(snaps.count)
        print(String(format: "RICHMAIL-BENCH web snapshot %.0f ms average over %d (headless, no budget)", average * 1000, snaps.count))
        print(String(format: "  rich mail (reader): %d PNGs, %d web snapshots, %d text fallbacks (%.1f s)", r.count, snaps.count,
                     r.fallbacks, Date().timeIntervalSince(started)))
    }

    // MARK: Budgets (the gate allows 2×)

    static func bench() {
        func median(_ runs: Int, _ work: () -> Void) -> Double {
            var times: [Double] = []
            for _ in 0..<runs {
                let t = Date()
                work()
                times.append(Date().timeIntervalSince(t) * 1000)
            }
            return times.sorted()[times.count / 2]
        }
        func line(_ label: String, _ ms: Double, _ budget: Double) {
            print(String(format: "RICHMAIL-BENCH %@ %.1f ms (budget %.0f, gate %.0f) %@", label, ms, budget, budget * 2,
                         ms <= budget * 2 ? "pass" : "FAIL"))
        }
        let quote = "<div class=\"gmail_quote\"><div class=\"gmail_attr\">On Mon, Juniper Vale wrote:</div><blockquote class=\"gmail_quote\">"
            + RichMailBodies.tourRows + "</blockquote></div>"
        var newsletter = ""
        while newsletter.utf8.count < 200_000 { newsletter += RichMailBodies.newsletterHTML }
        newsletter = "<div>Thanks for the dates!</div>" + newsletter + quote
        let cids: Set<String> = ["comets-logo@quietcomets.example"]
        line("sanitize+mark 200KB newsletter", median(5) {
            _ = MailQuote.mark(HTMLSanitizer.sanitize(newsletter, remote: .block, cids: cids).html)
        }, 40)
        let unit = "<div style=\"color:#2A1B4A;font-size:13px;padding:2px\" class=\"row x\" id=\"r\"><span><b>Caf\u{00E9} Nowhere</b> &amp; "
            + "Suite 404</span> <a href=\"https://tickets.quietcomets.example/?a=1&amp;b=2\">tickets</a><img src=\"cid:comets-logo@quietcomets.example\" "
            + "width=\"12\" height=\"12\" alt=\"\"><table><tr><td bgcolor=\"#EDE7F6\">\u{2022}</td></tr></table></div>"
        var pathological = "<div>Reply first.</div><div class=\"gmail_quote\">"
        while pathological.utf8.count < 2_000_000 { pathological += unit }
        pathological += "</div>"
        line("sanitize+mark 2MB pathological", median(3) {
            _ = MailQuote.mark(HTMLSanitizer.sanitize(pathological, remote: .block, cids: cids).html)
        }, 450)
        var text = ""
        while text.utf8.count < 100_000 { text += RichMailBodies.plainText + "\n\n" }
        line("MailPlainText.html 100KB", median(5) { _ = MailPlainText.html(text, flowed: true, delsp: false) }, 20)
    }

    // MARK: Renderer

    @MainActor
    final class Renderer {
        let now: Date
        let save: Save
        let attachments: FakeMailAttachments
        let rules: MailRuleLists
        let directory: AccountDirectory
        var count = 0
        var fallbacks = 0
        var snapshotSeconds: [Double] = []

        init(now: Date, save: @escaping Save, attachments: FakeMailAttachments, rules: MailRuleLists) {
            self.now = now
            self.save = save
            self.attachments = attachments
            self.rules = rules
            directory = AccountDirectory(accounts: RichMailCast.accounts.map {
                DirectoryAccount(id: $0.id, tag: $0.tag, name: $0.name, email: $0.email, color: $0.color, logo: nil)
            })
        }

        var own: Set<String> { Set(RichMailCast.accounts.map(\.email)) }

        // MARK: Messages through the data layer

        /// A Gmail `format=full` message as the API would send it: text (or related[html, inline images]) inside
        /// mixed with the files, Gmail part ids as in the fixtures.
        func gmail(_ m: RichMailBodies.Message) -> GMessage {
            let files = m.attachments.filter { !$0.isInline }
            let inline = m.attachments.filter(\.isInline)
            func data(_ s: String) -> GMessagePartBody { GMessagePartBody(size: s.utf8.count, data: Data(s.utf8).base64URLString, attachmentId: nil) }
            func header(_ name: String, _ value: String) -> GHeader { GHeader(name: name, value: value) }
            var text: GMessagePart
            if let html = m.html {
                text = GMessagePart(partId: "", mimeType: "text/html", filename: "", headers: [header("Content-Type", "text/html; charset=utf-8")],
                                    body: data(html), parts: nil)
            } else {
                let type = "text/plain; charset=utf-8" + (m.flowed ? "; format=flowed" : "")
                text = GMessagePart(partId: "", mimeType: "text/plain", filename: "", headers: [header("Content-Type", type)], body: data(m.text), parts: nil)
            }
            var body = text
            if !inline.isEmpty {
                text.partId = "1.1"
                let images = inline.map { a in
                    GMessagePart(partId: a.id, mimeType: a.mimeType, filename: a.name,
                                 headers: [header("Content-Type", a.mimeType), header("Content-ID", "<\(a.contentId ?? "")>"),
                                           header("Content-Disposition", "inline; filename=\"\(a.name)\"")],
                                 body: GMessagePartBody(size: a.bytes, data: nil, attachmentId: "fixture-\(a.id)"), parts: nil)
                }
                body = GMessagePart(partId: "1", mimeType: "multipart/related", filename: "",
                                    headers: [header("Content-Type", "multipart/related; boundary=\"r\"")], body: nil, parts: [text] + images)
            }
            var root = body
            if !files.isEmpty {
                body.partId = "1"
                let parts = files.map { a in
                    GMessagePart(partId: a.id, mimeType: a.mimeType, filename: a.name,
                                 headers: [header("Content-Type", a.mimeType), header("Content-Disposition", "attachment; filename=\"\(a.name)\"")],
                                 body: GMessagePartBody(size: a.bytes, data: nil, attachmentId: "fixture-\(a.id)"), parts: nil)
                }
                root = GMessagePart(partId: "", mimeType: "multipart/mixed", filename: "",
                                    headers: [header("Content-Type", "multipart/mixed; boundary=\"m\"")], body: nil, parts: [body] + parts)
            }
            root.partId = ""
            root.headers = (root.headers ?? []) + [
                header("From", m.from.email.isEmpty ? m.from.name : "\(m.from.name) <\(m.from.email)>"),
                header("To", m.to.joined(separator: ", ")), header("Subject", m.subject),
            ] + (m.cc.isEmpty ? [] : [header("Cc", m.cc.joined(separator: ", "))])
            let millis = Int64(m.date(now: now).timeIntervalSince1970 * 1000)
            return GMessage(id: m.id, threadId: m.id, labelIds: ["INBOX"], snippet: "", historyId: "1", internalDate: String(millis), payload: root)
        }

        /// The thread's messages as the reader receives them. `allowed`: the sender is on the allow list (remote
        /// images not blocked); `simulateRemote`: the remote images swapped for local data: images.
        func messages(_ fixture: RichMailThreads.Fixture, allowed: Bool, simulateRemote: Bool = false) -> [MailMessage] {
            RichMailBodies.messages(fixture).map { body in
                var m = CachedMessage.parsed(gmail(body)).message.message(blockRemote: !allowed)
                if simulateRemote, let html = m.html { m.html = Self.localImages(html) }
                return m
            }
        }

        static func localImages(_ html: String) -> String {
            func uri(_ part: FakeMailAttachments.Part, _ type: NSBitmapImageRep.FileType, _ mime: String) -> String {
                "data:\(mime);base64," + (FakeMailAttachments.image(part, type: type)?.base64EncodedString() ?? "")
            }
            let hero = FakeMailAttachments.Part(threadR: "", messageId: "", partId: "", mimeType: "image/jpeg", bytes: 0,
                                                pixels: (1200, 440), color: 0x6E56B8)
            let pixel = FakeMailAttachments.Part(threadR: "", messageId: "", partId: "", mimeType: "image/png", bytes: 0,
                                                 pixels: (1, 1), color: 0xFFFFFF)
            return html.replacingOccurrences(of: RichMailBodies.heroURL, with: uri(hero, .jpeg, "image/jpeg"))
                .replacingOccurrences(of: RichMailBodies.pixelURL, with: uri(pixel, .png, "image/png"))
        }

        func prefs(allowing senders: [RichMailCast.Person]) -> FakeMailPreferences {
            let prefs = FakeMailPreferences(signatures: false)
            prefs.allowed = Set(senders.map { $0.email.lowercased() })
            return prefs
        }

        // MARK: Two passes: learn the body width, snapshot at that width, draw

        struct Shot {
            var expand = false
            var maxHeight: CGFloat = 20_000
            var dark = false
        }

        func render<V: View>(_ view: V, _ name: String, _ info: [String: Any], messages: [MailMessage], threadR: String,
                             reader: ThreadReaderModel, shot: Shot = Shot()) {
            HeadlessWebProbe.widths = [:]
            let probe = ImageRenderer(content: view)
            probe.scale = 1
            _ = probe.cgImage
            var images: [String: NSImage] = [:]
            var wanted = 0
            for m in messages {
                let decision = reader.decision(for: m)
                guard decision.html, let width = HeadlessWebProbe.widths[m.id], width > 0 else { continue }
                wanted += 1
                let html = MailContentPolicy.clip(m.html ?? "") ?? m.html ?? ""
                let store = attachments, ruleLists = self.rules
                let options = RichTextSnapshot.Options(expandQuotes: shot.expand, maxHeight: shot.maxHeight, dark: shot.dark)
                var result: RichTextSnapshot.Result?
                Self.settle {
                    result = await RichTextSnapshot.webSnapshot(html: html, allowRemote: decision.allowRemote, plain: m.isPlainText, width: width,
                                                                threadR: threadR, messageId: m.id, inline: m.attachments.filter(\.isInline),
                                                                store: store, rules: ruleLists, options: options)
                }
                if let result {
                    images[m.id] = result.image
                    snapshotSeconds.append(result.seconds)
                }
            }
            var entry = info
            entry["window"] = entry["window"] ?? "rich-mail"
            entry["web"] = wanted > 0 && images.count == wanted ? "snapshot" : "text-fallback"
            if images.count < wanted { fallbacks += 1 }
            save(AnyView(view.environment(\.webSnapshots, images)), name + ".png", entry)
            count += 1
        }

        /// Runs async main-actor work to completion while the main run loop turns (the render is synchronous).
        static func settle(_ work: @escaping @MainActor () async -> Void) {
            final class Box { var done = false }
            let box = Box()
            Task { @MainActor in
                await work()
                box.done = true
            }
            let limit = Date().addingTimeInterval(40)
            while !box.done, Date() < limit { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }

        /// The previews the card draws when it appears (the app decodes them the same way, from the cache).
        func previewImages(_ message: MailMessage, threadR: String) -> [String: NSImage] {
            var out: [String: NSImage] = [:]
            let store = attachments
            for a in AttachmentNames.previewPlan(message.attachments.filter { !$0.isInline }).auto {
                var url: URL?
                Self.settle { url = try? await store.file(threadR: threadR, messageId: message.id, partId: a.id) }
                let hint = AttachmentNames.type(a.name, mimeType: a.mimeType).identifier
                if let url, let image = AttachmentPreviewDecoder.image(url, typeHint: hint) { out["\(message.id)/\(a.id)"] = image }
            }
            return out
        }

        // MARK: Reader cards

        func card(_ fixture: RichMailThreads.Fixture, _ name: String, state: String, mac: ColorScheme = .dark, allowed: Bool = false,
                  simulateRemote: Bool = false, width: CGFloat = 640, expand: Bool = false, messages given: [MailMessage]? = nil,
                  maxHeight: CGFloat = 20_000) {
            let senders = RichMailBodies.messages(fixture).map(\.from)
            let allow = prefs(allowing: allowed ? senders : [])
            let list = given ?? messages(fixture, allowed: allowed, simulateRemote: simulateRemote)
            let thread = fixture.thread(now: now)
            let reader = ThreadReaderModel(thread: thread, messages: list, prefs: { allow })
            guard let latest = reader.latest else { return }
            let previews = previewImages(latest, threadR: fixture.r)
            let view = PaperMessageCard(message: latest, reader: reader, account: directory.account(fixture.account.id), own: own)
                .padding(22).frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(AppTheme.background).environment(\.colorScheme, mac).environment(\.headlessRender, true)
                .environment(\.attachmentPreviewImages, previews)
            let decision = reader.decision(for: latest)
            let collapsed = latest.html?.contains(MailQuote.openTag) ?? false
            var info: [String: Any] = ["state": state, "thread": fixture.r, "mac": mac == .dark ? "dark" : "light",
                                       "quoteCollapsed": collapsed && !expand, "quoteExpanded": collapsed && expand,
                                       "chips": latest.attachments.filter { !$0.isInline }.count, "previews": previews.count,
                                       "inlineImages": latest.attachments.filter(\.isInline).count,
                                       "imagesBar": decision.showImagesBar, "plain": latest.isPlainText]
            if simulateRemote { info["remoteImages"] = "simulated-local" }
            render(view, name, info, messages: [latest], threadR: fixture.r, reader: reader,
                   shot: Shot(expand: expand, maxHeight: maxHeight, dark: mac == .dark))
        }

        func reader() {
            let t = RichMailThreads.self
            for mac in [ColorScheme.light, .dark] {
                let look = mac == .dark ? "dark" : "light"
                card(t.newsletter, "rm-reader-html-\(look)", state: "html-images-loaded", mac: mac, allowed: true, simulateRemote: true)
                card(t.plain, "rm-reader-plain-\(look)", state: "plain-text", mac: mac)
                card(t.gmailReply, "rm-reader-quoted-collapsed-\(look)", state: "quoted-collapsed", mac: mac)
                card(t.gmailReply, "rm-reader-quoted-expanded-\(look)", state: "quoted-expanded", mac: mac, expand: true)
                card(t.attachments, "rm-reader-attachments-\(look)", state: "attachments", mac: mac)
                card(t.inlineImages, "rm-reader-inline-images-\(look)", state: "inline-images", mac: mac)
            }
            // The Mail Peek's body width (420 − 2×18 − 2×14 = 356): the 600 px newsletter fits by zoom.
            card(t.newsletter, "rm-reader-html-narrow", state: "fit-to-width", allowed: true, simulateRemote: true, width: 436)
            card(t.newsletter, "rm-reader-remote-blocked", state: "remote-blocked-cid-shown")
            card(t.outlookReply, "rm-reader-quoted-outlook", state: "quoted-outlook")
            card(t.appleReply, "rm-reader-quoted-apple", state: "quoted-apple")
            // Over 2 MB after sanitizing: the first 2 MB (taller than 20,000 pt: a fixed box that scrolls inside) and the button.
            var big = messages(t.newsletter, allowed: false)
            if var last = big.popLast(), let html = last.html {
                var huge = html
                let rows = "<table width=\"600\" style=\"width:600px\">" + RichMailBodies.tourRows + "</table>"
                while huge.utf8.count <= MailContentPolicy.clipLimit + 400_000 { huge += rows }
                last.html = huge
                big.append(last)
            }
            card(t.newsletter, "rm-reader-large-clipped", state: "large-clipped", messages: big, maxHeight: MailWebView.Coordinator.fallbackHeight)
        }

        // MARK: Mail Peek

        func peeks() {
            func peek(_ fixture: RichMailThreads.Fixture, _ name: String, state: String, allowed: Bool, simulateRemote: Bool = false) {
                let senders = RichMailBodies.messages(fixture).map(\.from)
                let allow = prefs(allowing: allowed ? senders : [])
                let list = messages(fixture, allowed: allowed, simulateRemote: simulateRemote)
                let thread = fixture.thread(now: now)
                let reader = ThreadReaderModel(thread: thread, messages: list, prefs: { allow })
                let store = FakeMailStore(threads: [FixtureThread(thread: thread, messages: list)])
                let toasts = MailToastCenter(clock: { [now] in now }, schedule: { _, _ in })
                let model = MailPeekModel(thread: thread, directory: directory, reader: reader, actions: { FakeMailActions(store: store) },
                                          clock: { [now] in now }, undoBook: MailUndoBook(), toasts: toasts)
                let view = PeekCard { MailPeekView(model: model) }.fixedSize(horizontal: false, vertical: true)
                    .environment(\.headlessRender, true)
                    .padding(24).background(Color(hex: 0x3A4A55))
                guard let latest = reader.latest else { return }
                var info: [String: Any] = ["window": "rich-mail", "surface": "mailPeek", "state": state, "thread": fixture.r,
                                           "quoteCollapsed": latest.html?.contains(MailQuote.openTag) ?? false,
                                           "chips": latest.attachments.filter { !$0.isInline }.count, "previews": 0]
                if simulateRemote { info["remoteImages"] = "simulated-local" }
                render(view, name, info, messages: [latest], threadR: fixture.r, reader: reader, shot: Shot(maxHeight: 900))
            }
            peek(RichMailThreads.newsletter, "rm-peek-mail-rich", state: "html-fit-to-width", allowed: true, simulateRemote: true)
            peek(RichMailThreads.gmailReply, "rm-peek-mail-quoted", state: "quoted-collapsed", allowed: false)
            peek(RichMailThreads.attachments, "rm-peek-mail-attachments", state: "attachments-compact", allowed: false)
        }

        // MARK: The Inbox window

        func window(_ fixture: RichMailThreads.Fixture = RichMailThreads.newsletter, name: String = "rm-window-inbox-rich",
                    state: String = "reader-newsletter", hover: URL? = nil) {
            let threads = RichMailThreads.all.map { f in
                FixtureThread(thread: f.thread(now: now), messages: messages(f, allowed: f.r == fixture.r, simulateRemote: f.r == fixture.r))
            }
            let store = FakeMailStore(threads: threads)
            let actions = FakeMailActions(store: store)
            let allow = prefs(allowing: [RichMailCast.comets])
            let dir = self.directory
            let clock = self.now
            let inbox = InboxSectionModel(store: { store }, actions: { actions }, prefs: { allow }, directory: { dir }, clock: { clock },
                                          undoBook: MailUndoBook(), local: MemoryMailLocalStore(),
                                          toasts: MailToastCenter(clock: { clock }, schedule: { _, _ in }), compose: { _ in })
            inbox.load()
            Self.settle { await inbox.select(r: fixture.r) }
            guard let reader = inbox.reader else { return }
            reader.hoveredLink = hover
            let shell = ShellModel(section: .inbox, galleryLook: .paper, calendar: CalendarSectionModel(clock: { clock }),
                                   studio: WidgetStudioModel(mailEnabled: { true }), inbox: inbox,
                                   settingsMail: SettingsMailModel(prefs: { allow }, directory: { dir }, local: MemoryMailLocalStore(),
                                                                   safeSend: { true }, setSafeSend: { _ in }),
                                   menuBar: MenuBarSettingsModel(bag: MemoryBag(), mailEnabled: { true }, state: { .on }, post: {}),
                                   mailEnabled: { true }, fixedNow: clock)
            let view = MainView(shell: shell).frame(width: 1100, height: 740).environment(\.headlessRender, true)
            var info: [String: Any] = ["window": "rich-mail", "surface": "inbox", "state": state, "thread": fixture.r,
                                       "quoteCollapsed": reader.latest?.html?.contains(MailQuote.openTag) ?? false]
            if fixture.r == RichMailThreads.newsletter.r { info["remoteImages"] = "simulated-local" }
            if let hover { info["hover"] = hover.host ?? "" }
            render(view, name, info, messages: reader.messages, threadR: fixture.r, reader: reader)
        }
    }
}
#endif
