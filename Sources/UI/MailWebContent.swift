import AppKit
import SwiftUI
import WebKit

// The reader's web view plumbing (rich mail, D-040): one configuration factory for
// the Inbox reader, the Mail Peek and headless renders; the app-world script (WKContentWorld.defaultClient: page
// JavaScript stays off, and page content can't reach its handlers) that measures the page, fits wide mail to
// the width and reports the hovered link; and the per-web-view `cid:` scheme handler, which serves only the
// shown message's own inline parts, raster types only, from the attachment cache.

enum MailWebContent {
    /// Message handler names (registered in `.defaultClient` only).
    static let heightMessage = "ycHeight"
    static let hoverMessage = "ycHover"

    /// Runs at document end in the app's content world. It reads geometry and hovered links; the only thing it
    /// writes is `documentElement.style.zoom` (fit to width: Apple Mail's way, never below 0.5). It measures the
    /// root's rect height (scrollHeight never drops below the viewport, so it can't shrink the view) inside the
    /// ResizeObserver callback: requestAnimationFrame never fires in a hidden page.
    static let script = """
    (function () {
      var de = document.documentElement, lastW = -1, lastH = -1, hovered = null;
      function post(name, value) { try { window.webkit.messageHandlers[name].postMessage(value); } catch (e) {} }
      function fit() {
        var cw = de.clientWidth;
        if (cw === lastW || cw < 40) { return; }
        lastW = cw;
        de.style.zoom = '';
        var sw = de.scrollWidth;
        if (sw > cw + 1) {
          // scrollWidth ends at the wide content: add back the sheet's right padding so it keeps its margin.
          var sheet = document.querySelector('.yc-sheet'), pad = 0;
          if (sheet) { pad += parseFloat(getComputedStyle(sheet).paddingRight) || 0; }
          pad += parseFloat(getComputedStyle(document.body).paddingRight) || 0;
          de.style.zoom = String(Math.max(0.5, cw / (sw + pad)));
        }
      }
      function measure() {
        fit();
        var h = Math.ceil(de.getBoundingClientRect().height);
        if (h !== lastH) { lastH = h; post('\(heightMessage)', h); }
      }
      try { new ResizeObserver(measure).observe(de); } catch (e) {}
      measure();
      function report(href, img) {
        var key = href + '|' + img;
        if (key === hovered) { return; }
        hovered = key;
        post('\(hoverMessage)', { href: href, img: img });
      }
      document.addEventListener('mouseover', function (e) {
        var t = e.target, a = t && t.closest ? t.closest('a[href]') : null;
        var src = t && t.tagName === 'IMG' ? (t.getAttribute('src') || '') : '';
        report(a ? a.href : '', /^cid:/i.test(src) ? src : '');
      }, true);
      document.addEventListener('mouseout', function (e) { if (!e.relatedTarget) { report('', ''); } }, true);
    })();
    """

    /// The one configuration: JavaScript off for content, no windows, no autoplay, nothing persisted, our script
    /// and handlers in `.defaultClient`, and `cid` resolved by `cid` (when WebKit doesn't own the scheme).
    @MainActor
    static func configuration(messages: WKScriptMessageHandler?, cid: MailCIDSchemeHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = true
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        if let messages {
            let weak = WeakScriptHandler(messages)
            controller.add(weak, contentWorld: .defaultClient, name: heightMessage)
            controller.add(weak, contentWorld: .defaultClient, name: hoverMessage)
        }
        // Registering a scheme WebKit handles itself raises an Objective-C exception.
        if !WKWebView.handlesURLScheme("cid") { config.setURLSchemeHandler(cid, forURLScheme: "cid") }
        return config
    }

    /// The page height, measured the same way as the script (didFinish fallback and headless renders).
    static let measureExpression = "Math.ceil(document.documentElement.getBoundingClientRect().height)"
}

/// Breaks the retain cycle configuration → handler → coordinator → web view → configuration.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// `cid:` for one web view: resolves only the shown message's own inline parts (Content-ID → Gmail part id),
/// from the attachment cache (fetching on a miss), and answers only with bytes that really are a raster image
/// (PNG, JPEG, GIF, WebP, BMP, ICO, HEIC/AVIF; never HTML, SVG or PDF). No path is derived from the id.
@MainActor
final class MailCIDSchemeHandler: NSObject, WKURLSchemeHandler {
    struct Part: Equatable {
        var partId: String
        var mimeType: String
    }

    static let maxBytes = 50 << 20

    private(set) var threadR = ""
    private(set) var messageId = ""
    private(set) var parts: [String: Part] = [:]
    private let store: () -> MailAttachmentStore
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped: Set<ObjectIdentifier> = []

    init(store: @escaping () -> MailAttachmentStore = { Services.mailAttachments }) {
        self.store = store
    }

    /// The message now shown in this web view (its inline parts only).
    func update(threadR: String, messageId: String, inline: [MailMessage.Attachment]) {
        self.threadR = threadR
        self.messageId = messageId
        var map: [String: Part] = [:]
        for a in inline where a.isInline && !a.id.isEmpty {
            guard let id = a.contentId.flatMap(MailCID.normalize), map[id] == nil else { continue }
            map[id] = Part(partId: a.id, mimeType: a.mimeType)
        }
        parts = map
    }

    func part(for src: String) -> Part? { MailCID.normalize(src).flatMap { parts[$0] } }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        guard let url = task.request.url, let part = part(for: url.absoluteString), MailCID.isImageType(part.mimeType) else {
            task.didFailWithError(Self.refused)
            return
        }
        let store = self.store()
        let (threadR, messageId) = (self.threadR, self.messageId)
        running[key] = Task { @MainActor [weak self] in
            var file = store.cachedFile(threadR: threadR, messageId: messageId, partId: part.partId)
            if file == nil { file = try? await store.file(threadR: threadR, messageId: messageId, partId: part.partId) }
            let data = await Self.read(file)
            guard let self else { return }
            self.running[key] = nil
            if self.stopped.remove(key) != nil { return }   // WebKit stopped the task: never touch it again
            guard let data, let type = MailCID.rasterType(data) else {
                task.didFailWithError(Self.refused)
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        guard let job = running.removeValue(forKey: key) else { return }
        stopped.insert(key)
        job.cancel()
    }

    /// The cached image under `src` (the context menu's Copy Image); no network.
    func cachedImage(src: String) -> NSImage? {
        guard let part = part(for: src),
              let file = store().cachedFile(threadR: threadR, messageId: messageId, partId: part.partId),
              let data = try? Data(contentsOf: file), data.count <= Self.maxBytes, MailCID.rasterType(data) != nil else { return nil }
        return NSImage(data: data)
    }

    private static func read(_ file: URL?) async -> Data? {
        guard let file else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= maxBytes else { return nil }
            return try? Data(contentsOf: file, options: .mappedIfSafe)
        }.value
    }

    static let refused = NSError(domain: "YayasCalendar.cid", code: 404,
                                 userInfo: [NSLocalizedDescriptionKey: "That image isn\u{2019}t part of this message."])
}

// MARK: - Headless renders

private struct WebSnapshotsKey: EnvironmentKey { static let defaultValue: [String: NSImage] = [:] }

extension EnvironmentValues {
    /// Headless renders: message id → a snapshot of its web content (`RichTextSnapshot.webSnapshot`). ImageRenderer
    /// can't draw a WKWebView, so `MessageBody` draws this image instead; missing → the text fallback.
    var webSnapshots: [String: NSImage] {
        get { self[WebSnapshotsKey.self] }
        set { self[WebSnapshotsKey.self] = newValue }
    }
}

/// Headless renders only: the width each message body was laid out at (a first pass records it, then the
/// snapshot is made at exactly that width).
@MainActor
enum HeadlessWebProbe {
    static var widths: [String: CGFloat] = [:]
}
