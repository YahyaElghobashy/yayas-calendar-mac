import AppKit
import WebKit

// Headless snapshots of rich content for `--render`: ImageRenderer can't draw a
// WKWebView, so the reader's renders draw an image of the real web view instead. `webSnapshot` builds the
// web view with the app's own configuration (MailWebContent: JavaScript off for content, our app-world
// script, the cid handler, the CSP, the rule lists) and no window at all (takeSnapshot works
// window-less). In a hidden page requestAnimationFrame never fires and the ResizeObserver is late, so it
// measures with evaluateJavaScript after didFinish instead of waiting for `ycHeight`. The caller spins the
// main run loop while it waits (the render harness is synchronous).

@MainActor
enum RichTextSnapshot {
    // The web snapshot is for the render harness only (D-035): compiled with -D YC_DEV_TOOLS, left out of release
    // builds. `textSnapshot` (RichTextSnapshot+Text.swift) stays: the composer and Settings draw it when headless.
#if YC_DEV_TOOLS
    struct Options {
        /// Open the "•••" quoted history (renders of the expanded state).
        var expandQuotes = false
        /// Cut the image at this height (Mail Peek, pathological mail).
        var maxHeight: CGFloat = 20_000
        /// The Mac's appearance around the page; the sheet stays light either way (color-scheme: light).
        var dark = false
        var timeout: TimeInterval = 15
    }

    struct Result {
        var image: NSImage
        /// The measured page height (before `maxHeight`), in points.
        var pageHeight: CGFloat
        var seconds: Double
    }

    /// `html` is the reader's fragment (sanitized + MailQuote, or MailPlainText); the document is built exactly
    /// as the reader builds it. `store` backs `cid:` (FakeMailAttachments in renders); `rules` compiles the
    /// content rule lists (a store in the render folder, never the app's).
    static func webSnapshot(html: String, allowRemote: Bool, plain: Bool, width: CGFloat, threadR: String, messageId: String,
                            inline: [MailMessage.Attachment], store: MailAttachmentStore, rules: MailRuleLists,
                            options: Options = Options()) async -> Result? {
        let started = Date()
        let cid = MailCIDSchemeHandler(store: { store })
        cid.update(threadR: threadR, messageId: messageId, inline: inline)
        let config = MailWebContent.configuration(messages: nil, cid: cid)
        let list: WKContentRuleList? = await withCheckedContinuation { done in
            rules.list(allowRemote: allowRemote) { done.resume(returning: $0) }
        }
        if let list { config.userContentController.add(list) }
        let view = MailWKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 600), configuration: config)
        view.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        view.underPageBackgroundColor = PaperTheme.nsSurface
        let loader = Loader()
        view.navigationDelegate = loader
        var fragment = html
        if options.expandQuotes {
            fragment = fragment.replacingOccurrences(of: MailQuote.openTag, with: "<details class=\"yc-quote\" open>")
        }
        view.loadHTMLString(MailContentPolicy.document(fragment, allowRemote: allowRemote && list != nil, plain: plain), baseURL: nil)
        let deadline = started.addingTimeInterval(options.timeout)
        while !loader.finished, Date() < deadline { try? await Task.sleep(nanoseconds: 15_000_000) }
        guard loader.finished, !loader.failed else { return nil }
        guard let value = try? await view.evaluateJavaScript(MailWebContent.measureExpression, in: nil, contentWorld: .defaultClient),
              let measured = (value as? NSNumber).map({ CGFloat($0.doubleValue) }), measured > 0 else { return nil }
        let height = min(max(measured, 40), options.maxHeight)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        try? await Task.sleep(nanoseconds: 40_000_000)   // one layout pass at the new size
        let shot = WKSnapshotConfiguration()
        shot.rect = view.bounds
        shot.afterScreenUpdates = false
        guard let image = try? await view.takeSnapshot(configuration: shot) else { return nil }
        image.size = NSSize(width: width, height: height)
        return Result(image: image, pageHeight: measured, seconds: Date().timeIntervalSince(started))
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        var finished = false
        var failed = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = true; failed = true }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finished = true
            failed = true
        }
    }
#endif
}
