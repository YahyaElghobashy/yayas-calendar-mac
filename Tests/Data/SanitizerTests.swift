import Foundation

/// HTMLSanitizer: XSS and remote-load vectors, structure, CSS, remote-image modes, plain text.
enum SanitizerTests {
    struct Vector {
        var name: String
        var html: String
        var mode: HTMLSanitizer.RemoteContent = .block
        var absent: [String]
        var present: [String] = []
        var remote: Bool? = nil
    }

    static let vectors: [Vector] = [
        Vector(name: "script element", html: "<script>alert(1)</script>hi", absent: ["script", "alert"], present: ["hi"]),
        Vector(name: "uppercase script with src", html: "<SCRIPT SRC=//x.js></SCRIPT>ok", absent: ["script", "SCRIPT", "x.js"], present: ["ok"]),
        Vector(name: "img onerror, relative src", html: "<img src=x onerror=alert(1)>", absent: ["onerror", "alert", "<img"]),
        Vector(name: "remote img with onerror (blocked)", html: "<img src=\"https://t.example/p.gif\" onerror=\"alert(1)\">",
               absent: ["onerror", "t.example"], present: ["data-yc-blocked"], remote: true),
        Vector(name: "javascript: link", html: "<a href=\"javascript:alert(1)\">x</a>", absent: ["javascript", "href"], present: [">x</a>"]),
        Vector(name: "tab inside scheme", html: "<a href=\"  jav&#x09;ascript:alert(1)\">x</a>", absent: ["alert", "href"]),
        Vector(name: "decimal entities scheme", html: "<a href=\"&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert(1)\">x</a>",
               absent: ["alert", "href"]),
        Vector(name: "entity without semicolon", html: "<a href=\"&#106avascript:alert(1)\">x</a>", absent: ["alert", "href"]),
        Vector(name: "NUL inside scheme", html: "<a href=\"java&#0000;script:alert(1)\">x</a>", absent: ["alert", "href"]),
        Vector(name: "vbscript", html: "<a href=\"vbscript:msgbox(1)\">x</a>", absent: ["vbscript", "msgbox"]),
        Vector(name: "data:text/html link", html: "<a href=\"data:text/html;base64,PHNjcmlwdD4=\">x</a>", absent: ["data:", "PHNj"]),
        Vector(name: "svg data image", html: "<img src=\"data:image/svg+xml;base64,PHN2Zz4=\">", absent: ["svg", "<img"]),
        Vector(name: "png data image kept", html: "<img src=\"data:image/png;base64,iVBORw0KGgo=\" alt=\"dot\">",
               absent: ["data-yc-blocked"], present: ["src=\"data:image/png;base64,iVBORw0KGgo=\"", "alt=\"dot\""], remote: false),
        Vector(name: "iframe", html: "<iframe src=\"https://evil.example\"></iframe>after", absent: ["iframe", "evil"], present: ["after"]),
        Vector(name: "iframe srcdoc", html: "<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>", absent: ["srcdoc", "alert", "script"]),
        Vector(name: "object/embed/applet", html: "<object data=\"x.swf\"><param name=a value=b></object><embed src=y><applet code=z></applet>ok",
               absent: ["object", "embed", "applet", "x.swf", "param"], present: ["ok"]),
        Vector(name: "svg onload", html: "<svg onload=alert(1)><circle r=1></circle></svg>after", absent: ["svg", "onload", "circle", "alert"],
               present: ["after"]),
        Vector(name: "script inside svg", html: "<svg><script>alert(1)</script></svg>after", absent: ["alert", "svg"], present: ["after"]),
        Vector(name: "math xlink", html: "<math><mi xlink:href=\"javascript:alert(1)\">x</mi></math>", absent: ["javascript", "xlink", "math"]),
        Vector(name: "form and controls", html: "<form action=\"https://evil.example\"><input name=pw><textarea>t</textarea><select><option>o</option></select><button>Go</button></form>",
               absent: ["form", "input", "action", "evil", "textarea", "select", "option"], present: ["Go"]),
        Vector(name: "meta refresh", html: "<meta http-equiv=\"refresh\" content=\"0;url=https://evil.example\">x", absent: ["meta", "refresh", "evil"]),
        Vector(name: "base href", html: "<base href=\"https://evil.example/\"><a href=\"https://ok.example/\">a</a>", absent: ["<base", "evil"],
               present: ["https://ok.example/"]),
        Vector(name: "stylesheet link", html: "<link rel=stylesheet href=\"https://evil.example/x.css\">x", absent: ["link", "evil"]),
        Vector(name: "css url javascript", html: "<div style=\"background:url(javascript:alert(1))\">x</div>", absent: ["javascript", "alert", "style="]),
        Vector(name: "css expression", html: "<div style=\"width: expression(alert(1)); color: red\">x</div>", absent: ["expression", "alert"],
               present: ["color: red"]),
        Vector(name: "css escaped expression", html: "<div style=\"w\\idth: ex\\70ression(alert(1))\">x</div>", absent: ["alert", "ression"]),
        Vector(name: "css behavior", html: "<div style=\"behavior: url(x.htc)\">x</div>", absent: ["behavior", "htc"]),
        Vector(name: "css -moz-binding", html: "<div style=\"-moz-binding: url(http://x.example/b.xml#x)\">x</div>", absent: ["binding", "b.xml"]),
        Vector(name: "style @import", html: "<style>@import url(https://evil.example/x.css); p{color:red}</style>",
               absent: ["@import", "evil"], present: ["<style>p{color: red}</style>"]),
        Vector(name: "style with expression dropped whole", html: "<style>p{width:expression(alert(1))} b{color:red}</style>x",
               absent: ["expression", "<style>", "alert"], present: ["x"]),
        Vector(name: "style escaped binding dropped whole", html: "<style>p{-moz-\\62inding:url(x)}</style>x", absent: ["<style>", "inding"]),
        Vector(name: "style remote background (blocked)", html: "<style>body{background:url(https://t.example/x.png)}</style>",
               absent: ["t.example"], present: ["background: none"], remote: true),
        Vector(name: "style remote background (allowed)", html: "<style>body{background:url(https://t.example/x.png)}</style>", mode: .allow,
               absent: [], present: ["url(\"https://t.example/x.png\")"], remote: true),
        Vector(name: "font-face remote (blocked)", html: "<style>@font-face{font-family:F;src:url(https://f.example/x.woff)}</style>",
               absent: ["f.example"], remote: true),
        Vector(name: "table background (blocked)", html: "<table background=\"https://t.example/bg.png\"><tr><td>x</td></tr></table>",
               absent: ["bg.png", "background"], present: ["<table><tr><td>x</td></tr></table>"], remote: true),
        Vector(name: "inline background-image (blocked)", html: "<div style=\"background-image: url('https://t.example/a.png'); color: blue\">x</div>",
               absent: ["t.example"], present: ["background-image: none", "color: blue"], remote: true),
        Vector(name: "inline data image background kept", html: "<div style=\"background:url(data:image/png;base64,AAAA)\">x</div>",
               absent: [], present: ["url(&quot;data:image/png;base64,AAAA&quot;)"], remote: false),
        Vector(name: "cid image placeholder", html: "<p><img src=\"cid:part1@x\" alt=\"Logo\"></p>", absent: ["cid:", "<img"],
               present: ["[image: Logo]"], remote: false),
        Vector(name: "event handlers on text", html: "<p onclick=\"x()\" onmouseover=y>t</p>", absent: ["onclick", "onmouseover"], present: ["<p>t</p>"]),
        Vector(name: "safe link kept, target dropped", html: "<a href=\"https://example.com/a?b=1&amp;c=2\" target=\"_blank\">x</a>",
               absent: ["target"], present: ["href=\"https://example.com/a?b=1&amp;c=2\"", "rel=\"noopener noreferrer\""]),
        Vector(name: "mailto and tel links", html: "<a href=\"mailto:a@b.example\">m</a> <a href=\"tel:+15550100\">t</a>", absent: [],
               present: ["href=\"mailto:a@b.example\"", "href=\"tel:+15550100\""]),
        Vector(name: "protocol-relative link dropped", html: "<a href=\"//evil.example/x\">rel</a>", absent: ["evil", "href"], present: ["rel"]),
        Vector(name: "conditional comment", html: "<!--[if mso]><script>alert(1)</script><![endif]-->ok", absent: ["alert", "mso"], present: ["ok"]),
        Vector(name: "split script tag", html: "<scr<script>ipt>alert(1)</script>", absent: ["<script", "<scr"]),
        Vector(name: "srcset dropped (allowed mode)", html: "<img src=\"https://a.example/b.png\" srcset=\"https://c.example/d.png 2x\">", mode: .allow,
               absent: ["srcset", "c.example"], present: ["src=\"https://a.example/b.png\""], remote: true),
        Vector(name: "attribute breakout attempt", html: "\"><script>alert(1)</script>", absent: ["<script"], present: ["\"&gt;"]),
        Vector(name: "quote inside attribute escaped", html: "<a href=\"https://x.example/?q=&quot;onmouseover=alert(1)\">x</a>",
               absent: ["\"onmouseover"], present: ["&quot;onmouseover"]),
        Vector(name: "encoded tag in title attribute", html: "<div title=\"&lt;script&gt;\">x</div>", absent: ["<script"],
               present: ["title=\"&lt;script&gt;\""]),
        Vector(name: "noscript mXSS", html: "<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\"></noscript>",
               absent: ["<img", "<noscript", "</noscript>"], present: ["&lt;img src=x onerror=alert(1)&gt;"]),
        Vector(name: "textarea content", html: "<textarea><img src=x onerror=alert(1)></textarea>", absent: ["onerror", "<img", "textarea"]),
        Vector(name: "title content", html: "<title><img src=x onerror=alert(1)></title>body", absent: ["onerror", "title"], present: ["body"]),
        Vector(name: "style inside svg", html: "<svg><style><img src=x onerror=alert(1)></style></svg>", absent: ["onerror", "<img", "<style"]),
        Vector(name: "slash-separated attributes", html: "<img/src=x/onerror=alert(1)>", absent: ["onerror", "<img"]),
        Vector(name: "video poster", html: "<video poster=\"https://t.example/p.png\"><source src=x></video>after", absent: ["video", "poster", "source"],
               present: ["after"]),
        Vector(name: "body handlers", html: "<body onload=alert(1) bgcolor=\"#ffffff\">x</body>", absent: ["onload", "<body"],
               present: ["<div bgcolor=\"#ffffff\">x</div>"]),
        Vector(name: "stray closing tags", html: "</div></div><b>x", absent: ["</div>"], present: ["<b>x</b>"]),
        Vector(name: "css escape smuggling a closing tag", html: "<style>p{content:\"\\3C/style\\3E<script>\"}</style>", absent: ["script", "<style>"]),
        Vector(name: "escaped text stays text", html: "&lt;b&gt;not bold&lt;/b&gt;", absent: ["<b>"], present: ["&lt;b&gt;not bold&lt;/b&gt;"]),
        Vector(name: "image element alias", html: "<image src=x onerror=alert(1)>", absent: ["onerror", "image"]),
        Vector(name: "remote tracking pixel keeps size", html: "<img src=\"http://t.example/p.gif\" width=\"1\" height=\"1\">",
               absent: ["t.example", "src="], present: ["width=\"1\"", "height=\"1\"", "data-yc-blocked=\"1\""], remote: true),
        Vector(name: "image-set in css", html: "<div style=\"background-image: image-set('https://t.example/a.png' 1x)\">x</div>", absent: ["t.example", "image-set"]),
        Vector(name: "unknown and Office tags unwrapped", html: "<o:p>office</o:p><custom-el data-x=\"1\">c</custom-el>", absent: ["o:p", "custom-el", "data-x"],
               present: ["office", "c"]),
        Vector(name: "file: and relative image", html: "<img src=\"file:///etc/passwd\"><img src=\"/local.png\">x", absent: ["file:", "passwd", "local.png"], present: ["x"]),
        Vector(name: "on* attribute with odd casing", html: "<b OnMouseOver=\"x()\" ONCLICK=y>t</b>", absent: ["mouseover", "MouseOver", "ONCLICK"], present: ["<b>t</b>"]),
    ]

    static func run() {
        for v in vectors {
            let result = HTMLSanitizer.sanitize(v.html, remote: v.mode)
            let lower = result.html
            for bad in v.absent where lower.range(of: bad, options: .caseInsensitive) != nil {
                expect(false, "sanitizer [\(v.name)]: output contains \(bad.debugDescription): \(result.html.debugDescription)")
            }
            for good in v.present where !result.html.contains(good) {
                expect(false, "sanitizer [\(v.name)]: output lacks \(good.debugDescription): \(result.html.debugDescription)")
            }
            if let remote = v.remote {
                expect(result.hasRemoteImages == remote, "sanitizer [\(v.name)]: hasRemoteImages == \(remote)")
            }
            expect(true, "sanitizer vector: \(v.name)")
        }
        expect(vectors.count >= 40, "sanitizer corpus has ≥ 40 vectors (\(vectors.count))")
        structure()
        modes()
        plainText()
    }

    static func structure() {
        let email = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>News</title>
            <style>.btn{color:#fff;background:#3CCBB4} @media (max-width:600px){.col{width:100%!important}}</style></head>
            <body style="margin:0"><table width="600" cellpadding="0"><tr><td class="col" align="center">
            <h1>Hello</h1><p>Read <a href="https://example.com/x">more</a>.</p></td></tr></table></body></html>
            """
        let out = HTMLSanitizer.sanitize(email, remote: .block)
        expect(out.html.contains("<style>.btn{color: #fff; background: #3CCBB4}@media (max-width:600px){.col{width: 100%!important}}</style>"),
               "safe <style> rebuilt rule by rule, @media kept (\(out.html))")
        expect(out.html.contains("<div style=\"margin: 0\">") && out.html.contains("<table width=\"600\" cellpadding=\"0\">"),
               "body → div, table attributes kept")
        expect(!out.html.contains("News") && !out.html.contains("<meta") && !out.html.contains("<html"), "head-only content dropped")
        expect(out.html.hasSuffix("</div>") && !out.hasRemoteImages, "body div closed; no remote content")

        let twice = HTMLSanitizer.sanitize(out.html, remote: .block)
        expect(twice.html == out.html, "sanitizing is idempotent")

        var deep = ""
        for _ in 0..<600 { deep += "<div>" }
        deep += "x"
        let deepOut = HTMLSanitizer.sanitize(deep, remote: .block).html
        expect(deepOut.contains("x") && deepOut.components(separatedBy: "<div>").count - 1 == deepOut.components(separatedBy: "</div>").count - 1,
               "600 nested divs: every emitted div is closed (depth capped at 400)")
        let big = String(repeating: "<p>paragraph &amp; text</p>", count: 20_000)
        let started = Date()
        let bigOut = HTMLSanitizer.sanitize(big, remote: .block)
        let elapsed = Date().timeIntervalSince(started)
        expect(bigOut.html.count == big.count && elapsed < 3, "540 KB of HTML sanitized in \(String(format: "%.2f", elapsed)) s")
    }

    static func modes() {
        let html = "<p><img src=\"https://cdn.example/hero.jpg\" alt=\"Hero\" width=\"600\"></p><div style=\"background:url(https://cdn.example/bg.png)\">x</div>"
        let allowed = HTMLSanitizer.sanitize(html, remote: .allow)
        expect(allowed.hasRemoteImages && allowed.html.contains("src=\"https://cdn.example/hero.jpg\"")
               && allowed.html.contains("url(&quot;https://cdn.example/bg.png&quot;)"), "allow mode keeps remote images")
        let blocked = HTMLSanitizer.sanitize(allowed.html, remote: .block)
        expect(blocked.hasRemoteImages && !blocked.html.contains("cdn.example") && blocked.html.contains("alt=\"Hero\"")
               && blocked.html.contains("width=\"600\""), "block pass over the cached (allowed) HTML removes every remote load")
        let none = HTMLSanitizer.sanitize("<p>No images</p>", remote: .block)
        expect(!none.hasRemoteImages && none.cidImages == 0, "no remote content → flag off")
    }

    static func plainText() {
        let text = HTMLSanitizer.text(fromHTML: """
            <div>Hi&nbsp;there,</div><p>Line   with   spaces<br>next line</p>
            <table><tr><td>A</td><td>B</td></tr></table><pre>keep   this
              indent</pre><script>var x = 1;</script><img alt="Logo" src="x">
            """)
        expect(text == "Hi there,\n\nLine with spaces\nnext line\n\nA B\nkeep   this\n  indent\nLogo", "HTML → text (\(text.debugDescription))")
        expect(HTMLSanitizer.text(fromHTML: "") == "", "empty HTML → empty text")
        expect(HTMLSanitizer.html(fromText: "a < b\nc") == "<div style=\"white-space: pre-wrap\">a &lt; b\nc</div>", "text → HTML escapes")
    }
}
