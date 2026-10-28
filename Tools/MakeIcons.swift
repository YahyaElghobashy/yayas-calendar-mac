// Draws Yaya's Calendar's icon assets with CoreGraphics, ImageIO and Accelerate only (no ImageMagick):
//
//   Resources/Generated/AppIcon.icns         the portal page (Resources/Brand/AppIcon-Source.png,
//                                            transparent) on the navy space tile, Apple's 824-in-1024
//                                            grid, every size from 16 to 1024 px
//   Resources/Brand/AppIcon-1024.png         the 1024 px tile, for anything that needs the icon large
//   docs/assets/icon.png                     the 256 px tile (README header)
//   Resources/Generated/MenuBarIcon.pdf      the menu bar template glyph as vector art (20 × 15 pt)
//   Resources/Generated/MenuBarIcon@2x.png   the same glyph at 40 × 30 px
//   Resources/Generated/MenuBarIcon.png      the hand-tuned 1x sprite (20 × 15 px)
//   build/icon-previews/                     review sheets (not shipped)
//
// The glyph is the BrandMark path (Sources/Shared/Widgets/BrandMark.swift), the same one the app and
// the widgets draw. Every PNG, including the ones inside the .icns, is written by Tools/lib/CleanPNG.swift
// (sRGB, critical chunks only); the PDF is written by hand with no info dictionary and no XMP.
//
// usage: Tools/make-icons.sh   (from anywhere; it compiles this file and runs it from the repo root)
import Accelerate
import AppKit

@main
enum MakeIcons {
    static func main() throws {
        try FileManager.default.createDirectory(at: path("build/icon-previews"), withIntermediateDirectories: true)
        let subject = try Subject(path("Resources/Brand/AppIcon-Source.png"))

        // App icon: every size, the .icns, the 1024 master and the README copy.
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        var tiles: [Int: CGImage] = [:]
        for px in sizes { tiles[px] = appIcon(px, subject) }
        let entries: [(String, Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
                                        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
        let icns = try writeICNS(entries.map { ($0.0, try CleanPNG.encode(tiles[$0.1]!)) })
        try icns.write(to: path("Resources/Generated/AppIcon.icns"), options: .atomic)
        try CleanPNG.write(tiles[1024]!, to: path("Resources/Brand/AppIcon-1024.png"))
        try CleanPNG.write(tiles[256]!, to: path("docs/assets/icon.png"))

        // Menu bar glyph.
        let canvas = BrandMarkGeometry.canvas
        try pdf(BrandMarkGeometry.path, canvas: canvas).write(to: path("Resources/Generated/MenuBarIcon.pdf"), options: .atomic)
        try CleanPNG.write(glyph(scale: 2), to: path("Resources/Generated/MenuBarIcon@2x.png"))
        try CleanPNG.write(Sprite.image(), to: path("Resources/Generated/MenuBarIcon.png"))

        // Previews.
        for px in [16, 32, 128, 256, 512, 1024] {
            try CleanPNG.write(tiles[px] ?? appIcon(px, subject), to: path("build/icon-previews/appicon-\(px).png"))
        }
        try CleanPNG.write(iconSheet(tiles), to: path("build/icon-previews/appicon-sheet.png"))
        try CleanPNG.write(menuBarSheet(), to: path("build/icon-previews/menubar.png"))
        print("✓ AppIcon.icns (\(entries.count) images), AppIcon-1024.png, docs/assets/icon.png,"
              + " MenuBarIcon.pdf/.png/@2x.png, previews in build/icon-previews")
    }

    static func path(_ rel: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(rel)
    }

    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    static func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CleanPNG.srgb, colors: colors as CFArray, locations: locations)!
    }

    static func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CleanPNG.canvas(w, h)
        draw(ctx)
        return ctx.makeImage()!
    }

    // MARK: - App icon

    /// Brand colours (brand/BRAND.md).
    static let navy: UInt32 = 0x0E1A22, navyTop: UInt32 = 0x14232C, teal: UInt32 = 0x3CCBB4

    /// The tile, in 1024 units with the origin bottom left: Apple's macOS grid (824 px, corner radius 185).
    static let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

    /// Where the subject sits on the tile at a given pixel size: which part of the cut-out, how wide
    /// (1024 units) and where its centre goes. From 64 px up the whole scene shows, the envelope's flight
    /// inside the tile with air around it. At 16 and 32 px the envelope would be a stray pixel outside the
    /// tile, so those sizes crop to the page and its portal and draw them as large as the tile allows.
    static func subjectLayout(_ px: Int) -> (part: Subject.Part, width: CGFloat, center: CGPoint) {
        switch px {
        case ...16: return (.page, 740, CGPoint(x: 512, y: 508))
        case ...32: return (.page, 780, CGPoint(x: 512, y: 510))
        case ...64: return (.whole, 770, CGPoint(x: 516, y: 510))
        default: return (.whole, 720, CGPoint(x: 516, y: 510))
        }
    }

    static func appIcon(_ px: Int, _ subject: Subject) -> CGImage {
        bitmap(px, px) { ctx in
            let s = CGFloat(px) / 1024
            let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
            ctx.scaleBy(x: s, y: s)

            // Drop shadow under the tile, as macOS icons have. Shadow sizes ignore the CTM: scale them.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: rgb(0x000000, 0.35))
            ctx.addPath(tilePath); ctx.setFillColor(rgb(navy)); ctx.fillPath()
            ctx.restoreGState()

            let layout = subjectLayout(px)
            let box = subject.box(layout.part)
            let rect = subject.rect(box, width: layout.width, center: layout.center)
            let portal = subject.portal(box, in: rect)

            ctx.saveGState()
            ctx.addPath(tilePath); ctx.clip()
            // Navy space, lighter at the top.
            ctx.drawLinearGradient(gradient([rgb(navyTop), rgb(navy)], [0, 1]),
                                   start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
            // Teal glow around the portal.
            ctx.drawRadialGradient(gradient([rgb(teal, 0.42), rgb(teal, 0.13), rgb(teal, 0)], [0, 0.42, 1]),
                                   startCenter: portal, startRadius: 0, endCenter: portal, endRadius: 430, options: [])
            if px >= 64 {
                stars(ctx)
                for t in twinkles { sparkle(ctx, t.0, t.1, t.2) }
            }
            // Soft top sheen.
            ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)], [0, 1]),
                                   start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
            ctx.restoreGState()

            // The portal page, with a soft shadow of its own.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 26 * s, color: rgb(0x000000, 0.45))
            let device = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
            let snapped = device.integral
            ctx.scaleBy(x: 1 / s, y: 1 / s)
            ctx.draw(subject.resampled(box, Int(snapped.width), Int(snapped.height)), in: snapped)
            ctx.restoreGState()

            // Hairline edge, so the tile separates from dark wallpapers.
            if px >= 64 {
                ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(2); ctx.strokePath()
            }
        }
    }

    /// A fixed scatter of stars (the same sky at every size).
    static func stars(_ ctx: CGContext) {
        var seed: UInt64 = 0x0E1A_2214_232C_3CCB
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
        }
        for _ in 0..<52 {
            let p = CGPoint(x: 116 + next() * 792, y: 116 + next() * 792)
            let r = 1.3 + next() * 2.5
            ctx.setFillColor(rgb(next() < 0.18 ? 0xBFF3EA : 0xFFFFFF, 0.28 + next() * 0.5))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    /// Four-point twinkles in the open sky around the page: centre, radius, colour.
    static let twinkles: [(CGPoint, CGFloat, UInt32)] = [
        (CGPoint(x: 214, y: 806), 22, 0xFFFFFF),
        (CGPoint(x: 846, y: 790), 15, 0xBFF3EA),
        (CGPoint(x: 172, y: 262), 13, 0xFFFFFF),
        (CGPoint(x: 838, y: 196), 18, 0xFFFFFF),
        (CGPoint(x: 724, y: 862), 9, 0xFFFFFF),
    ]

    static func sparkle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: UInt32) {
        let p = CGMutablePath()
        let tips = (0..<4).map { i -> CGPoint in
            let a = CGFloat(i) * .pi / 2 + .pi / 2
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        p.move(to: tips[0])
        for i in 0..<4 {
            let next = tips[(i + 1) % 4]
            let mid = CGFloat(i) * .pi / 2 + .pi / 2 + .pi / 4
            p.addQuadCurve(to: next, control: CGPoint(x: c.x + r * 0.14 * cos(mid), y: c.y + r * 0.14 * sin(mid)))
        }
        p.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: r * 0.6, color: rgb(color, 0.7))
        ctx.addPath(p); ctx.setFillColor(rgb(color, 0.9)); ctx.fillPath()
        ctx.restoreGState()
    }

    /// The cut-out: its opaque box, its portal, and Lanczos resampling to any pixel size.
    struct Subject {
        enum Part { case whole, page }
        let image: CGImage
        /// The opaque box, in image pixels (y down).
        let whole: CGRect
        /// The portal's centre in image pixels (y down): the bright core of the swirl, measured once.
        let portalPixel = CGPoint(x: 681, y: 667)
        /// The page and its portal end here (image pixels); the speed lines and the envelope lie beyond.
        let pageRight: CGFloat = 790

        init(_ url: URL) throws {
            image = CleanPNG.srgbImage(try CleanPNG.read(url))
            let w = image.width, h = image.height
            let ctx = CleanPNG.canvas(w, h)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var minX = w, minY = h, maxX = 0, maxY = 0
            for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 16 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            guard maxX > minX, maxY > minY else { throw CleanPNG.Failure(description: "AppIcon-Source.png is empty") }
            whole = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        func box(_ part: Part) -> CGRect {
            switch part {
            case .whole: return whole
            case .page: return CGRect(x: whole.minX, y: whole.minY, width: pageRight - whole.minX, height: whole.height)
            }
        }

        /// `box` scaled to `width` (1024 units) around `center`, origin bottom left.
        func rect(_ box: CGRect, width: CGFloat, center: CGPoint) -> CGRect {
            let height = width * box.height / box.width
            return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        }

        /// The portal's centre once `box` is placed at `rect` (1024 units, origin bottom left).
        func portal(_ box: CGRect, in rect: CGRect) -> CGPoint {
            CGPoint(x: rect.minX + (portalPixel.x - box.minX) / box.width * rect.width,
                    y: rect.maxY - (portalPixel.y - box.minY) / box.height * rect.height)
        }

        /// `box` resampled to `w` × `h` pixels (Lanczos, premultiplied, so edges stay clean).
        func resampled(_ box: CGRect, _ w: Int, _ h: Int) -> CGImage {
            let cropped = image.cropping(to: box)!
            var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                                              colorSpace: Unmanaged.passUnretained(CleanPNG.srgb),
                                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                              version: 0, decode: nil, renderingIntent: .defaultIntent)
            var src = vImage_Buffer(), dst = vImage_Buffer()
            defer { free(src.data); free(dst.data) }
            precondition(vImageBuffer_InitWithCGImage(&src, &format, nil, cropped, vImage_Flags(kvImageNoFlags)) == kvImageNoError)
            precondition(vImageBuffer_Init(&dst, vImagePixelCount(h), vImagePixelCount(w), 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError)
            precondition(vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError)
            var error = vImage_Error(kvImageNoError)
            let out = vImageCreateCGImageFromBuffer(&dst, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)
            precondition(error == kvImageNoError)
            return out!.takeRetainedValue()
        }
    }

    // MARK: - .icns

    /// An icns file whose every member is one of our clean PNGs, byte for byte (no iconutil re-encode).
    static func writeICNS(_ members: [(String, Data)]) throws -> Data {
        func be32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) } }
        var body = Data()
        for (type, png) in members {
            precondition(type.utf8.count == 4)
            body.append(Data(type.utf8)); body.append(be32(png.count + 8)); body.append(png)
        }
        var file = Data("icns".utf8)
        file.append(be32(body.count + 8)); file.append(body)
        return file
    }

    // MARK: - Menu bar glyph

    /// The vector glyph on its 20 × 15 pt canvas at `scale`, black on clear (a template image).
    static func glyph(scale: Int, color: CGColor = rgb(0x000000)) -> CGImage {
        let c = BrandMarkGeometry.canvas
        return bitmap(Int(c.width) * scale, Int(c.height) * scale) { ctx in
            ctx.translateBy(x: 0, y: c.height * CGFloat(scale))
            ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))   // the path is y down
            ctx.addPath(BrandMarkGeometry.path)
            ctx.setFillColor(color)
            ctx.fillPath()
        }
    }

    /// A one-page PDF of `path` (y down) filled black: catalog, pages, page, content stream, xref. No
    /// info dictionary, no XMP, no dates, so it names no person, machine or program.
    static func pdf(_ path: CGPath, canvas: CGSize) -> Data {
        func n(_ v: CGFloat) -> String {
            var s = String(format: "%.4f", Double(v))
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s == "-0" ? "0" : s
        }
        var ops = "1 0 0 -1 0 \(n(canvas.height)) cm\n0 g\n"
        var current = CGPoint.zero
        path.applyWithBlock { element in
            let e = element.pointee, pts = e.points
            switch e.type {
            case .moveToPoint:
                ops += "\(n(pts[0].x)) \(n(pts[0].y)) m\n"; current = pts[0]
            case .addLineToPoint:
                ops += "\(n(pts[0].x)) \(n(pts[0].y)) l\n"; current = pts[0]
            case .addQuadCurveToPoint:
                let c1 = CGPoint(x: current.x + 2 / 3 * (pts[0].x - current.x), y: current.y + 2 / 3 * (pts[0].y - current.y))
                let c2 = CGPoint(x: pts[1].x + 2 / 3 * (pts[0].x - pts[1].x), y: pts[1].y + 2 / 3 * (pts[0].y - pts[1].y))
                ops += "\(n(c1.x)) \(n(c1.y)) \(n(c2.x)) \(n(c2.y)) \(n(pts[1].x)) \(n(pts[1].y)) c\n"; current = pts[1]
            case .addCurveToPoint:
                ops += "\(n(pts[0].x)) \(n(pts[0].y)) \(n(pts[1].x)) \(n(pts[1].y)) \(n(pts[2].x)) \(n(pts[2].y)) c\n"
                current = pts[2]
            case .closeSubpath:
                ops += "h\n"
            @unknown default:
                break
            }
        }
        ops += "f\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(canvas.width)) \(n(canvas.height))] /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(ops.utf8.count) >>\nstream\n\(ops)endstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// The 1x glyph, placed by hand on the 20 × 15 px grid: the vector shape moved down half a pixel
    /// so its outline lands on whole pixels, with 1 px strokes, a 3 px band and a 3 px portal dot.
    /// `#` full ink, `o` 70 %, `+` 45 %, `.` 20 %, space clear.
    enum Sprite {
        static let rows = [
            "                    ",
            "     oo    oo       ",
            "     ##    ##       ",
            "  o############o    ",
            "  ##############    ",
            "  ##############    ",
            "  #            #    ",
            "  #            #    ",
            "  #            #    ",
            "  #            #    ",
            "  #        o###+    ",
            "  #        ###+     ",
            "  #        ##+ o#o  ",
            "  #        #+  ###  ",
            "  o########+   o#o  ",
        ]

        static func image() -> CGImage {
            precondition(rows.count == 15 && rows.allSatisfy { $0.count == 20 })
            return bitmap(20, 15) { ctx in
                for (y, row) in rows.enumerated() {
                    for (x, ch) in row.enumerated() {
                        let alpha: CGFloat
                        switch ch {
                        case "#": alpha = 1
                        case "o": alpha = 0.7
                        case "+": alpha = 0.45
                        case ".": alpha = 0.2
                        default: continue
                        }
                        ctx.setFillColor(rgb(0x000000, alpha))
                        ctx.fill(CGRect(x: x, y: 14 - y, width: 1, height: 1))
                    }
                }
            }
        }
    }

    // MARK: - Preview sheets

    /// Each size at 1x on a light and a dark desktop, then 16 and 32 px magnified 8× and 4×.
    static func iconSheet(_ tiles: [Int: CGImage]) -> CGImage {
        bitmap(1200, 560) { ctx in
            for (i, bg) in [UInt32(0xE9E6E1), 0x1C1C1E].enumerated() {
                let y = CGFloat(i) * 280
                ctx.setFillColor(rgb(bg)); ctx.fill(CGRect(x: 0, y: y, width: 1200, height: 280))
                var x: CGFloat = 24
                for px in [16, 32, 64, 128, 256] {
                    ctx.draw(tiles[px]!, in: CGRect(x: x, y: y + 12, width: CGFloat(px), height: CGFloat(px)))
                    x += CGFloat(px) + 24
                }
                ctx.interpolationQuality = .none
                ctx.draw(tiles[16]!, in: CGRect(x: 640, y: y + 12, width: 128, height: 128))
                ctx.draw(tiles[32]!, in: CGRect(x: 800, y: y + 12, width: 128, height: 128))
                ctx.interpolationQuality = .high
            }
        }
    }

    /// A template image recoloured: its alpha, filled with `color`.
    static func tinted(_ image: CGImage, _ color: CGColor) -> CGImage {
        bitmap(image.width, image.height) { ctx in
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            ctx.draw(image, in: rect)
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(color); ctx.fill(rect)
        }
    }

    /// Light and dark menu bars: the hand-tuned 1x sprite, the vector at 1x (for comparison) and the
    /// @2x glyph, magnified 12×, 12× and 6×; then the sprite and the @2x glyph at size, 1 pt = 1 px.
    static func menuBarSheet() -> CGImage {
        bitmap(1000, 400) { ctx in
            for (i, (bar, ink)) in [(UInt32(0xECECEC), UInt32(0x000000)), (0x1E1E1E, 0xFFFFFF)].enumerated() {
                let y = CGFloat(i) * 200
                let one = tinted(Sprite.image(), rgb(ink)), vector1 = tinted(glyph(scale: 1), rgb(ink))
                let two = tinted(glyph(scale: 2), rgb(ink))
                ctx.setFillColor(rgb(bar)); ctx.fill(CGRect(x: 0, y: y, width: 1000, height: 200))
                ctx.interpolationQuality = .none
                ctx.draw(one, in: CGRect(x: 20, y: y + 10, width: 240, height: 180))
                ctx.draw(vector1, in: CGRect(x: 280, y: y + 10, width: 240, height: 180))
                ctx.draw(two, in: CGRect(x: 540, y: y + 10, width: 240, height: 180))
                ctx.draw(one, in: CGRect(x: 820, y: y + 92, width: 20, height: 15))
                ctx.draw(two, in: CGRect(x: 880, y: y + 92, width: 20, height: 15))
                ctx.interpolationQuality = .high
            }
        }
    }
}
