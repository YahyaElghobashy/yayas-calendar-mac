import Foundation

/// Rich mail viewer, shell tests: the reader's document (white sheet, quote CSS,
/// plain-text CSS, unchanged CSP), same-document anchors, the trimmed context menu, the hovered-link label and the
/// 2 MB clip. Cast data only.
@MainActor
enum RichMailViewerSurfaceTests {
    static func run() {
        document()
        anchors()
        contextMenu()
        hoverLabel()
        clip()
    }

    static func document() {
        T.section("Rich mail: reader document")
        let doc = MailContentPolicy.document("<p>Hi Avery</p>", allowRemote: false)
        T.check(doc.contains("<body><div class=\"yc-sheet\"><p>Hi Avery</p></div></body>"), "the message sits on the white sheet")
        T.check(doc.contains(".yc-sheet{background:#FFFFFF") && doc.contains("box-shadow:0 0 0 1px #E7E1D8") && doc.contains("border-radius:10px"),
                "sheet: white, 1 pt #E7E1D8 hairline, 10 pt corners")
        T.check(doc.contains("html{background:#F8F5F0}"), "the paper stays around it")
        T.check(doc.contains("<meta name=\"color-scheme\" content=\"light\">"), "light only (no dark adaptation in 1.0)")
        T.check(!doc.contains("table{max-width:100%"), "fixed-width tables aren't squeezed (fit to width instead)")
        T.check(doc.contains("img:not([width]){max-width:100%;height:auto}"), "only images without a width shrink")
        T.check(doc.contains("details.yc-quote>summary{list-style:none;display:inline-block") && doc.contains("background:#ECE6DC")
                && doc.contains("details.yc-quote[open]>summary{background:#E2DCD2}"), "the \u{2022}\u{2022}\u{2022} pill and its open state")
        T.check(doc.contains("summary.yc-more{display:inline-block!important;visibility:visible!important"), "the pill is defended against sender CSS")
        T.check(doc.contains("blockquote[type=cite],blockquote.gmail_quote,.yc-q{margin:0 0 0 .3em;padding-left:.9em;border-left:2px solid #C9BFB2"),
                "quote bars")
        T.check(doc.contains("{border-left-color:#A9C3B9}") && doc.contains("{border-left-color:#B9B2D0}"), "nested bars cycle colours")
        T.check(doc.contains("font:14px/1.5 -apple-system") && !doc.contains("body{font"), "our font sits on the sheet only")
        T.check(!doc.contains(".yc-plain{"), "no plain-text CSS for HTML mail")
        let plain = MailContentPolicy.document("<div class=\"yc-plain\">x</div>", allowRemote: false, plain: true)
        T.check(plain.contains(".yc-plain{white-space:pre-wrap;font:14px/1.55") && plain.contains("overflow-wrap:anywhere")
                && plain.contains(".yc-pre{font:12.5px/1.45 Menlo,monospace;white-space:pre;overflow-x:auto")
                && plain.contains(".yc-sig{color:#8C8590}"), "plain text: proportional, monospace blocks scroll, dimmed signature")
        T.check(!MailContentPolicy.document("x", allowRemote: true, plain: true).contains("display:none"), "allowed: nothing hidden")
        T.equal(MailContentPolicy.csp(allowRemote: false),
                "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; style-src 'unsafe-inline'; font-src data:; img-src data: cid:",
                "CSP unchanged (cid: images allowed, scripts never)")
        T.check(doc.contains(MailContentPolicy.csp(allowRemote: false)), "the document carries it")
    }

    static func anchors() {
        T.section("Rich mail: same-document anchors")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "about:blank#tour-dates"), isUserAction: true), .allowAnchor,
                "a newsletter's table of contents scrolls")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "about:blank#tour-dates"), isUserAction: false), .allowInitialLoad,
                "not user-activated: only our own load")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "about:blank#"), isUserAction: true), .ignore, "an empty fragment is ignored")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "about:blank"), isUserAction: true), .ignore, "about:blank itself is ignored")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "about:srcdoc#x"), isUserAction: true), .ignore, "other about: pages are ignored")
        T.equal(MailContentPolicy.linkAction(url: URL(string: "cid:comets-logo@quietcomets.example"), isUserAction: true), .ignore,
                "cid: clicks are ignored")
    }

    static func contextMenu() {
        T.section("Rich mail: context menu")
        for id in ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
                   "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierOpenFrameInNewWindow",
                   "WKMenuItemIdentifierReload", "WKMenuItemIdentifierDownloadMedia"] {
            T.check(!MailContentPolicy.keepsMenuItem(id), "removed: \(id)")
        }
        for id in ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate",
                   "WKMenuItemIdentifierSpeechMenu", "WKMenuItemIdentifierShareMenu", nil] as [String?] {
            T.check(MailContentPolicy.keepsMenuItem(id), "kept: \(id ?? "unidentified")")
        }
    }

    static func hoverLabel() {
        T.section("Rich mail: hovered link")
        let label = MailContentPolicy.hoverLabel(URL(string: "https://Tickets.QuietComets.example/tour/2026?city=lake-house#dates")!)
        T.equal(label?.host, "tickets.quietcomets.example", "the real host, lowercased")
        T.equal(label?.rest, "/tour/2026?city=lake-house#dates", "then the path, query and fragment")
        let long = MailContentPolicy.hoverLabel(URL(string: "https://quietcomets.example/" + String(repeating: "verylongpath/", count: 12) + "end")!)
        T.check(long.map { $0.host.count + $0.rest.count <= 60 && $0.rest.contains("\u{2026}") && $0.rest.hasSuffix("end") } == true,
                "middle-truncated to 60 characters")
        T.equal(MailContentPolicy.hoverLabel(URL(string: "https://quietcomets.example/")!)?.rest, "", "a bare host shows no slash")
        T.equal(MailContentPolicy.hoverLabel(URL(string: "mailto:theo@quill.example?subject=Set")!)?.host, "theo@quill.example", "mailto: the address")
        T.check(MailContentPolicy.hoverLabel(URL(string: "javascript:alert(1)")!) == nil, "javascript: never shown")
        T.check(MailContentPolicy.hoverLabel(URL(string: "https://user:pw@quill.example/")!) == nil, "user:password URLs never shown")
        T.equal(MailContentPolicy.middle("abcdefghij", 7), "abc\u{2026}hij", "middle truncation")
    }

    static func clip() {
        T.section("Rich mail: 2 MB clip")
        T.check(MailContentPolicy.clip("<div>small</div>") == nil, "small bodies aren't clipped")
        let row = "<div>Comets Weekly \u{00B7} tour row with caf\u{00E9} text</div>"
        let big = String(repeating: row, count: 2_000)
        let cut = MailContentPolicy.clip(big, limit: 10_000)
        T.check(cut.map { $0.utf8.count <= 10_000 && $0.hasSuffix("</div>") && $0.hasPrefix("<div>") } == true, "cut at a block end, within the limit")
        T.check(cut.map { $0.utf8.count > 9_000 } == true, "…close to the limit")
        T.equal(MailContentPolicy.clipLimit, 2 << 20, "the limit is 2 MB")
    }
}
