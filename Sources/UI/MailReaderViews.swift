import AppKit
import SwiftUI
import WebKit

// The paper-card reader shared by the Inbox section and the Mail Peek. Mail draws in a WKWebView on a
// white sheet (rich mail, D-040) that is locked down three ways: JavaScript off (WKWebpagePreferences), a
// WKContentRuleList that blocks every remote load unless the sender is allowed (MailContentPolicy), and a
// matching CSP. Plain-text mail arrives as our own escaped HTML (MailPlainText) and draws the same way.
// It never navigates: links open in the default browser, `mailto:` opens the composer, same-document
// anchors scroll. Our app-world script (MailWebContent) keeps the height right, fits wide mail to the
// width and reports the hovered link. Headless renders draw a web snapshot (`\.webSnapshots`), else text.

enum PaperTheme {
    static let surface = Color(hex: 0xF8F5F0)
    static let text = Color(hex: 0x1D1B20)
    static let text2 = Color(hex: 0x5A5560)
    static let text3 = Color(hex: 0x8C8590)
    static let rule = Color(hex: 0xE7E1D8)
    static let band = Color(hex: 0xEFE9E0)
    static let accent = Color(hex: 0x14937F)
    static let nsSurface = NSColor(red: 0xF8 / 255, green: 0xF5 / 255, blue: 0xF0 / 255, alpha: 1)
    // Rich mail (D-040): the message sheet, its hairline, the quote bars (cycling by depth), the "•••" pill.
    static let sheet = Color(hex: 0xFFFFFF)
    static let sheetRule = Color(hex: 0xE7E1D8)
    static let quoteBar1 = Color(hex: 0xC9BFB2)
    static let quoteBar2 = Color(hex: 0xA9C3B9)
    static let quoteBar3 = Color(hex: 0xB9B2D0)
    static let pill = Color(hex: 0xECE6DC)
}

// MARK: - Content rule lists

/// The two compiled rule lists (remote blocked / images allowed), compiled once per launch. Headless renders
/// use their own store in the render folder (never the app's WebKit data).
@MainActor
final class MailRuleLists {
    static let shared = MailRuleLists()

    private let store: WKContentRuleListStore
    private var lists: [Bool: WKContentRuleList] = [:]
    private var waiting: [Bool: [(WKContentRuleList?) -> Void]] = [:]

    init(store: WKContentRuleListStore = .default()) { self.store = store }

    func list(allowRemote: Bool, _ done: @escaping (WKContentRuleList?) -> Void) {
        if let list = lists[allowRemote] { done(list); return }
        if waiting[allowRemote] != nil { waiting[allowRemote]?.append(done); return }
        waiting[allowRemote] = [done]
        store.compileContentRuleList(
            forIdentifier: MailContentPolicy.ruleListIdentifier(allowRemote: allowRemote),
            encodedContentRuleList: MailContentPolicy.rules(allowRemote: allowRemote)) { list, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let list { self.lists[allowRemote] = list }
                    let callbacks = self.waiting.removeValue(forKey: allowRemote) ?? []
                    for callback in callbacks { callback(list) }
                }
            }
        }
    }
}

// MARK: - Web view

/// Hands vertical scroll-wheel events to the enclosing scroll view when the page is sized to its content, so
/// the reader scrolls as one column; sideways scrolls stay in the page (wide tables, monospace blocks). The
/// context menu loses everything that would open, download or reload and gains our own link and image
/// items.
final class MailWKWebView: WKWebView {
    var fitsContent = true
    /// Our own items for the current pointer position (link: Open Link in Browser, Copy Link; cid image: Copy Image).
    var extraMenuItems: () -> [NSMenuItem] = { [] }

    override func scrollWheel(with event: NSEvent) {
        if fitsContent, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items where !MailContentPolicy.keepsMenuItem(item.identifier?.rawValue) { menu.removeItem(item) }
        let extra = extraMenuItems()
        if !extra.isEmpty {
            if menu.items.first.map({ !$0.isSeparatorItem }) ?? false { menu.insertItem(.separator(), at: 0) }
            for (i, item) in extra.enumerated() { menu.insertItem(item, at: i) }
        }
        // No separators at the ends or twice in a row.
        var previousSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousSeparator { menu.removeItem(item) } else { previousSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}

struct MailWebView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    /// Our own plain-text HTML (MailPlainText): adds the plain-text CSS.
    var plain = false
    /// The load key and the `cid` handler's scope: this message's own inline parts only.
    var messageId = ""
    var threadR = ""
    var inline: [MailMessage.Attachment] = []
    /// Inbox reader: the view grows to the page's height. Mail Peek: fixed height, scrolls inside.
    var fitsContent = true
    @Binding var height: CGFloat
    var onCompose: (String) -> Void = { _ in }
    /// The link under the pointer (web and mailto only), nil when it leaves.
    var onHover: (URL?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MailWKWebView {
        let coordinator = context.coordinator
        let view = MailWKWebView(frame: .zero, configuration: MailWebContent.configuration(messages: coordinator, cid: coordinator.cid))
        view.fitsContent = fitsContent
        view.underPageBackgroundColor = PaperTheme.nsSurface
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.allowsLinkPreview = false
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.extraMenuItems = { [weak coordinator] in coordinator?.menuItems() ?? [] }
        coordinator.parent = self
        coordinator.load(into: view, self)
        return view
    }

    func updateNSView(_ view: MailWKWebView, context: Context) {
        context.coordinator.parent = self
        view.fitsContent = fitsContent && !context.coordinator.measureFailed
        context.coordinator.load(into: view, self)
    }

    static func dismantleNSView(_ view: MailWKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: MailWebView?
        let cid = MailCIDSchemeHandler()
        /// The page is taller than 20,000 pt or couldn't be measured: the view keeps a fixed height and scrolls inside.
        var measureFailed = false
        private var loadedKey: String?
        private var hoveredLink: URL?
        private var hoveredImage: String?
        private weak var view: MailWKWebView?

        static let maxHeight: CGFloat = 20_000
        static let fallbackHeight: CGFloat = 480

        /// Keyed on message id + images + length: never hashes the page on a SwiftUI update; the data layer
        /// hands over a new message when content changes, and the length catches the image re-fetch.
        func load(into view: MailWKWebView, _ p: MailWebView) {
            self.view = view
            let key = "\(p.messageId)|\(p.allowRemote)|\(p.html.utf8.count)|\(p.plain)"
            guard key != loadedKey else { return }
            loadedKey = key
            cid.update(threadR: p.threadR, messageId: p.messageId, inline: p.inline)
            hoveredLink = nil
            hoveredImage = nil
            let (html, allowRemote, plain) = (p.html, p.allowRemote, p.plain)
            MailRuleLists.shared.list(allowRemote: allowRemote) { list in
                let controller = view.configuration.userContentController
                controller.removeAllContentRuleLists()
                // Fail closed: without a compiled list, remote stays blocked by the CSP alone.
                let remote = allowRemote && list != nil
                if let list { controller.add(list) }
                view.loadHTMLString(MailContentPolicy.document(html, allowRemote: remote, plain: plain), baseURL: nil)
            }
        }

        // MARK: Our script's messages (app world only)

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.world == .defaultClient else { return }
            switch message.name {
            case MailWebContent.heightMessage:
                if let h = (message.body as? NSNumber)?.doubleValue { apply(height: CGFloat(h)) }
            case MailWebContent.hoverMessage:
                let body = message.body as? [String: Any]
                let link = (body?["href"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                let shown = link.flatMap { MailContentPolicy.hoverLabel($0) == nil ? nil : $0 }
                hoveredImage = (body?["img"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if shown != hoveredLink {
                    hoveredLink = shown
                    parent?.onHover(shown)
                }
            default:
                break
            }
        }

        private func apply(height h: CGFloat) {
            guard let parent, parent.fitsContent, !measureFailed, h > 0 else { return }
            if h > Self.maxHeight {
                fallback()
                return
            }
            let target = max(h, 40)
            if abs(target - parent.height) >= 1 { parent.height = target }
        }

        private func fallback() {
            measureFailed = true
            view?.fitsContent = false
            parent?.height = Self.fallbackHeight
        }

        // MARK: Context menu

        func menuItems() -> [NSMenuItem] {
            var items: [NSMenuItem] = []
            if let link = hoveredLink {
                if case .openInBrowser(let url) = MailContentPolicy.linkAction(url: link, isUserAction: true) {
                    items.append(ClosureMenuItem(title: "Open Link in Browser", key: "") { NSWorkspace.shared.open(url) })
                }
                let text = link.scheme?.lowercased() == "mailto" ? String(link.absoluteString.dropFirst(7)) : link.absoluteString
                items.append(ClosureMenuItem(title: link.scheme?.lowercased() == "mailto" ? "Copy Address" : "Copy Link", key: "") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                })
            }
            if let src = hoveredImage, let image = cid.cachedImage(src: src) {
                items.append(ClosureMenuItem(title: "Copy Image", key: "") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                })
            }
            return items
        }

        // MARK: Navigation (the reader never navigates)

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let user = navigationAction.navigationType == .linkActivated
            let isMain = navigationAction.targetFrame?.isMainFrame ?? true
            switch MailContentPolicy.linkAction(url: navigationAction.request.url, isUserAction: user) {
            case .allowInitialLoad where isMain, .allowAnchor where isMain:
                return .allow
            case .openInBrowser(let url):
                NSWorkspace.shared.open(url)
                Trace.app("mail-link", ["result": "browser"])
                return .cancel
            case .compose(let address):
                parent?.onCompose(address)
                return .cancel
            default:
                return .cancel
            }
        }

        /// `target="_blank"` links: same rules, never a new web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if case .openInBrowser(let url) = MailContentPolicy.linkAction(url: navigationAction.request.url, isUserAction: true) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        /// One measurement after the load, as a fallback for the ResizeObserver (same expression).
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard parent?.fitsContent == true else { return }
            webView.evaluateJavaScript(MailWebContent.measureExpression, in: nil, in: .defaultClient) { [weak self] result in
                var measured: CGFloat?
                if case .success(let value) = result, let h = (value as? NSNumber)?.doubleValue, h > 0 { measured = CGFloat(h) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let measured { self.apply(height: measured) } else { self.fallback() }
                }
            }
        }
    }
}

/// "→ example.com/path…" at the card's bottom-left while a link is under the pointer (anti-phishing): the real
/// destination after `URLPolicy`, host in bold.
struct HoverURLCapsule: View {
    let url: URL

    var body: some View {
        if let label = MailContentPolicy.hoverLabel(url) {
            (Text("\u{2192} ").foregroundColor(PaperTheme.text3)
             + Text(label.host).font(AppTheme.font(11.5, .bold)).foregroundColor(PaperTheme.text)
             + Text(label.rest).foregroundColor(PaperTheme.text2))
                .font(AppTheme.font(11.5, .medium))
                .lineLimit(1)
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().strokeBorder(PaperTheme.sheetRule, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Pieces of a message card

/// Logo (paper plate) or the account's colour dot, then its tag, for paper surfaces.
struct PaperAccountChip: View {
    let account: DirectoryAccount?
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 5) {
            if let logo = account?.logo {
                Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(PaperTheme.rule, lineWidth: 0.5))
            } else {
                Circle().fill(Color(hex: account?.color ?? 0x8FB4C4)).frame(width: size * 0.55, height: size * 0.55)
                    .frame(width: size, height: size)
            }
            if let tag = account?.tag, !tag.isEmpty {
                Text(tag).font(AppTheme.font(11, .bold)).foregroundStyle(PaperTheme.text2)
            }
        }
    }
}

/// "Remote images are hidden. Load images · Always for this sender".
struct RemoteImagesBar: View {
    /// Mail Peek width: the words on one line, the two choices under them.
    var compact = false
    let onLoad: () -> Void
    let onAlways: () -> Void

    static let height: CGFloat = 32
    static let compactHeight: CGFloat = 50

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 3) {
                    label
                    HStack(spacing: 8) { choices; Spacer(minLength: 0) }.padding(.leading, 20)
                }
                .frame(height: Self.compactHeight)
            } else {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 6)
                    choices
                }
                .frame(height: Self.height)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(PaperTheme.band))
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PaperTheme.text2).frame(width: 12)
            Text("Remote images are hidden.").font(AppTheme.font(12, .semibold)).foregroundStyle(PaperTheme.text2)
        }
    }

    private var choices: some View {
        HStack(spacing: 8) {
            PaperLinkButton(title: "Load images", action: onLoad)
            Text("·").font(AppTheme.font(12, .bold)).foregroundStyle(PaperTheme.text3)
            PaperLinkButton(title: "Always for this sender", action: onAlways)
        }
    }
}

struct PaperLinkButton: View {
    let title: String
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(AppTheme.font(12, .bold)).foregroundStyle(PaperTheme.accent)
                .underline(hover)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The body of one message: the locked web view (HTML mail, or plain text as our own HTML), else SwiftUI
/// text. Bodies over 2 MB show their first 2 MB and a button for the rest. Headless: the message's web
/// snapshot when the render made one (`\.webSnapshots`), else the text part.
struct MessageBody: View {
    let message: MailMessage
    let decision: MailContentPolicy.Decision
    /// The thread shown (scopes the `cid` handler with the message id).
    var threadR = ""
    /// Mail Peek: a fixed-height box that scrolls inside.
    var fixedHeight: CGFloat? = nil
    var onCompose: (String) -> Void = { _ in }
    var onHover: (URL?) -> Void = { _ in }
    @Environment(\.headlessRender) private var headless
    @Environment(\.webSnapshots) private var snapshots
    @Local private var height: CGFloat = 120
    @Local private var showWhole = false

    var body: some View {
        if decision.html {
            let full = message.html ?? ""
            let clipped = showWhole ? nil : MailContentPolicy.clip(full)
            VStack(alignment: .leading, spacing: 10) {
                if headless {
                    headlessBody
                } else {
                    MailWebView(html: clipped ?? full, allowRemote: decision.allowRemote, plain: message.isPlainText,
                                messageId: message.id, threadR: threadR, inline: message.attachments.filter(\.isInline),
                                fitsContent: fixedHeight == nil, height: $height, onCompose: onCompose, onHover: onHover)
                        .frame(height: fixedHeight ?? height)
                }
                if clipped != nil {
                    ShowWholeButton(bytes: full.utf8.count) { showWhole = true }
                }
            }
        } else if let fixedHeight {
            ScrollableText(text: message.text, height: fixedHeight)
        } else {
            plainText
        }
    }

    @ViewBuilder
    private var headlessBody: some View {
        if let image = snapshots[message.id] {
            let shown = Image(nsImage: image).resizable().frame(width: image.size.width, height: image.size.height)
            if let fixedHeight {
                shown.frame(height: fixedHeight, alignment: .top).clipped()
            } else {
                shown
            }
        } else {
            Group {
                if let fixedHeight { ScrollableText(text: message.text, height: fixedHeight) } else { plainText }
            }
            .background(GeometryReader { g -> Color in
                // Headless only: the width this body is laid out at (the render then snapshots at exactly that width).
                let (id, width) = (message.id, g.size.width)
                MainActor.assumeIsolated { HeadlessWebProbe.widths[id] = width }
                return Color.clear
            })
        }
    }

    private var plainText: some View {
        Text(MessageBody.trimmed(message.text))
            .font(AppTheme.font(13.5)).foregroundStyle(PaperTheme.text)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// "Show the rest of this message (3.4 MB)" under a clipped body.
private struct ShowWholeButton: View {
    let bytes: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.system(size: 11, weight: .semibold))
                Text("Show the rest of this message (\(MailText.size(bytes)))").font(AppTheme.font(12, .bold))
            }
            .foregroundStyle(PaperTheme.accent)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(PaperTheme.pill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Plain text in a fixed box (Mail Peek): scrolls in the app, clipped from the top in renders.
private struct ScrollableText: View {
    let text: String
    let height: CGFloat
    @Environment(\.headlessRender) private var headless

    var body: some View {
        let content = Text(MessageBody.trimmed(text))
            .font(AppTheme.font(13)).foregroundStyle(PaperTheme.text).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        if headless {
            content.frame(height: height, alignment: .top).clipped()
        } else {
            ScrollView(.vertical) { content.textSelection(.enabled) }.frame(height: height)
        }
    }
}

// MARK: - Toast

/// The bottom toast: "Archived · Undo" (30 s), "Sending… Undo" (5 s), or a friendly error.
struct MailToastView: View {
    @ObservedObject var center: MailToastCenter

    var body: some View {
        if let toast = center.toast {
            HStack(spacing: 10) {
                Text(toast.text).font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text)
                    .multilineTextAlignment(.leading)
                if let action = toast.action {
                    Text("·").font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text3)
                    Button {
                        Task { await center.performUndo() }
                    } label: {
                        Text(action).font(AppTheme.font(12.5, .heavy)).foregroundStyle(AppTheme.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(action == "Undo" ? KeyboardShortcut("z", modifiers: .command) : nil)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(toast.isError ? AppTheme.bad.opacity(0.94) : Color(hex: 0x23343E)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .onTapGesture { if toast.isError { center.dismiss() } }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
