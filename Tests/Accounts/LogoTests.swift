import AppKit
import Foundation

enum LogoTests {
    static func run() {
        policy()
        budget()
        htmlLinks()
        normalising()
        store()
    }

    static func policy() {
        expect(LogoFetcher.validDomain(" OrbitalPickle.EXAMPLE ") == "orbitalpickle.example", "domain normalised")
        expect(LogoFetcher.validDomain("localhost") == nil, "single label rejected")
        expect(LogoFetcher.validDomain("192.168.1.1") == nil, "IP address rejected")
        expect(LogoFetcher.validDomain("evil.example/path") == nil, "path characters rejected")
        expect(LogoFetcher.validDomain("-bad.com") == nil, "leading hyphen rejected")
        expect(LogoFetcher.validDomain("a..com") == nil, "empty label rejected")

        let d = "orbitalpickle.example"
        func ok(_ s: String) -> Bool { URL(string: s).map { LogoFetcher.isAllowed($0, domain: d) } ?? false }
        expect(ok("https://orbitalpickle.example/apple-touch-icon.png"), "own domain allowed")
        expect(ok("https://www.orbitalpickle.example/logo.svg"), "www allowed")
        expect(ok("https://orbitalpickle.example:443/x.png"), "explicit 443 and mixed case allowed")
        expect(!ok("http://orbitalpickle.example/x.png"), "plain http refused")
        expect(!ok("https://evil.example/x.png"), "other host refused")
        expect(!ok("https://orbitalpickle.example.evil.com/x.png"), "suffix trick refused")
        expect(!ok("https://cdn.orbitalpickle.example/x.png"), "other subdomain refused")
        expect(!ok("https://orbitalpickle.example:8443/x.png"), "other port refused")
        expect(!ok("https://user@orbitalpickle.example/x.png"), "userinfo refused")
        expect(!ok("ftp://orbitalpickle.example/x.png"), "other scheme refused")

        expect(LogoFetcher.staticCandidates(domain: d).map(\.absoluteString) == [
            "https://orbitalpickle.example/apple-touch-icon.png", "https://orbitalpickle.example/", "https://orbitalpickle.example/favicon.ico",
        ], "candidate order: apple-touch-icon, home page links, favicon.ico")
        expect(LogoFetcher.maxBytes == 512 * 1024 && LogoFetcher.timeout == 8, "512 KB cap, 8 s timeout")
    }

    /// "Seven at most" (Settings, the success screen, PRIVACY.md): every request of one fetch counts, redirects included.
    static func budget() {
        let d = "orbitalpickle.example"
        let www = URL(string: "https://www.orbitalpickle.example/apple-touch-icon.png")
        let elsewhere = URL(string: "https://cdn.example/apple-touch-icon.png")
        expect(LogoFetcher.maxRequests == 7 && LogoFetcher.maxRedirects == 3, "seven requests a fetch, three redirects an address")
        let addresses = 1 + 1 + LogoFetcher.maxLinkCandidates + 1
        expect(addresses == LogoFetcher.maxRequests, "the candidates alone fill the budget: icon, home page, four links, favicon.ico")

        let b = LogoFetcher.RequestBudget()
        expect(b.take(), "first request")
        expect(b.redirect(task: 1, to: www, domain: d) && b.redirect(task: 1, to: www, domain: d) && b.redirect(task: 1, to: www, domain: d),
               "three same-site redirects of one address are followed")
        expect(!b.redirect(task: 1, to: www, domain: d), "a fourth is refused")
        expect(b.count == 4, "the redirects counted as requests (\(b.count))")
        expect(!b.redirect(task: 2, to: elsewhere, domain: d) && b.count == 4, "a redirect off the site is refused and costs nothing")
        expect(!b.redirect(task: 2, to: nil, domain: d), "a redirect without an address is refused")
        expect(b.take() && b.take() && b.redirect(task: 2, to: www, domain: d), "room for three more")
        expect(!b.take() && !b.redirect(task: 3, to: www, domain: d) && b.count == 7, "then nothing: seven in all, however the site redirects")
    }

    static func htmlLinks() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/site.css">
        <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
        <LINK REL="icon" href='https://www.example.com/brand/logo.svg'>
        <link rel="shortcut icon" href="/favicon.ico">
        <link rel="icon" sizes="192x192" href="/icons/icon-192.png?v=2&amp;x=1">
        <link rel="icon" href="https://cdn.example.net/icon.png">
        <link rel="mask-icon" href="/safari-pinned.svg" color="#000">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link href="/apple-touch-icon-180.png" rel="apple-touch-icon" sizes="180x180">
        <link rel=icon href=//evil.example.org/i.png>
        </head></html>
        """
        let base = URL(string: "https://www.example.com/home")!
        let links = LogoFetcher.iconLinks(inHTML: html, base: base, domain: "example.com").map(\.absoluteString)
        expect(links == [
            "https://www.example.com/apple-touch-icon-180.png",
            "https://www.example.com/brand/logo.svg",
            "https://www.example.com/icons/icon-192.png?v=2&x=1",
            "https://www.example.com/favicon-32.png",
        ], "icon links: touch icon, SVG, PNG by size; other hosts, ICO, mask and data URIs dropped")
        expect(LogoFetcher.iconLinks(inHTML: "<p>no links</p>", base: base, domain: "example.com").isEmpty, "no links")
    }

    static func pngData(width: Int, height: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func normalising() {
        guard let wide = pngData(width: 300, height: 150) else { expect(false, "synthetic PNG"); return }
        let result = LogoStore.normalizedPNG(from: wide)
        let rep = result.flatMap { NSBitmapImageRep(data: $0.png) }
        expect(rep?.pixelsWide == 128 && rep?.pixelsHigh == 128, "normalised to 128×128")
        expect(result?.sourcePixels == 300, "source size reported")
        // Aspect fit: the top rows of a 2:1 image stay transparent.
        expect(rep?.colorAt(x: 64, y: 2)?.alphaComponent ?? 1 < 0.01, "letterboxed, not stretched")
        expect(rep?.colorAt(x: 64, y: 64)?.alphaComponent ?? 0 > 0.99, "image drawn in the middle")

        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 40 40"><circle cx="20" cy="20" r="18" fill="#3CCBB4"/></svg>"##
        let vector = LogoStore.normalizedPNG(from: Data(svg.utf8))
        expect(vector != nil, "SVG rasterised")
        expect(vector?.sourcePixels == Int.max, "SVG counts as vector (always good enough)")
        expect(LogoStore.normalizedPNG(from: Data("not an image".utf8)) == nil, "garbage rejected")
        if let tiny = pngData(width: 16, height: 16) {
            expect(LogoStore.normalizedPNG(from: tiny)?.sourcePixels == 16, "tiny favicon reported as 16 px")
        }
    }

    static func store() {
        let dir = AccountsTests.folder("logos").appendingPathComponent("widget/logos", isDirectory: true)
        let logos = LogoStore(directory: dir)
        let id = UUID()
        guard let png = pngData(width: 64, height: 64) else { return }
        let name = try? logos.save(imageData: png, for: id)
        expect(name == "\(id.uuidString).png", "logo file named <uuid>.png")
        expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id.uuidString).png").path),
               "logo written into the widget's logos folder")
        expect(logos.image(named: name)?.size.width == 128, "logo reads back at 128 pt")
        expect(logos.image(named: "../escape.png") == nil, "path traversal refused")
        expect((try? logos.save(imageData: Data("nope".utf8), for: UUID())) == nil, "non-image refused")
        logos.remove(id)
        expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(id.uuidString).png").path), "logo removed")
    }
}
