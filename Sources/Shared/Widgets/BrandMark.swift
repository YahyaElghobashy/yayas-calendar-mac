import CoreGraphics
import SwiftUI

/// The Yaya's Calendar mark: a calendar page with two ring stubs, its bottom corner curled back over a
/// portal dot (the app icon's portal page, reduced to one path).
///
/// One path serves every size: `Tools/MakeIcons.swift` draws the menu bar template images from it
/// (`MenuBarIcon.pdf` and `@2x`; the 1x PNG is a hand-tuned copy), and `BrandMark` draws it in the app
/// and the widgets. It is drawn, never loaded: no `NSImage` and no file read, so a widget pays nothing
/// for it (D-019).
enum BrandMarkGeometry {
    /// The design canvas: the menu bar status image, 20 × 15 pt (macOS 27 closes the menu for bigger ones).
    static let canvas = CGSize(width: 20, height: 15)
    /// The glyph's own box inside the canvas: 16 pt wide, centred.
    static let bounds = CGRect(x: 2, y: 0.5, width: 16, height: 14)

    /// The mark in canvas points, y down (SwiftUI's orientation). The page outline, the hole and the dot
    /// never overlap, so the even-odd and non-zero rules fill it the same way.
    static let path: CGPath = make()

    private static func make() -> CGPath {
        let p = CGMutablePath()
        // Page: x 2…16, y 2.5…14.5, radius 2, a 1.5 pt outline under a solid binding band. The bottom
        // right corner is cut on the diagonal from A to B: the corner curls back there.
        let a = CGPoint(x: 11, y: 14.5), b = CGPoint(x: 16, y: 9.5)
        p.move(to: CGPoint(x: 2, y: 4.5))
        p.addArc(tangent1End: CGPoint(x: 2, y: 2.5), tangent2End: CGPoint(x: 5, y: 2.5), radius: 2)
        for x in [CGFloat(5), 11] {   // the two ring stubs, 2 pt wide, rounded tops at y 0.5
            p.addLine(to: CGPoint(x: x, y: 2.5))
            p.addLine(to: CGPoint(x: x, y: 1.5))
            p.addArc(center: CGPoint(x: x + 1, y: 1.5), radius: 1, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            p.addLine(to: CGPoint(x: x + 2, y: 2.5))
        }
        p.addArc(tangent1End: CGPoint(x: 16, y: 2.5), tangent2End: b, radius: 2)
        p.addArc(tangent1End: b, tangent2End: a, radius: 0.6)
        p.addArc(tangent1End: a, tangent2End: CGPoint(x: 2, y: 14.5), radius: 0.6)
        p.addArc(tangent1End: CGPoint(x: 2, y: 14.5), tangent2End: CGPoint(x: 2, y: 4.5), radius: 2)
        p.closeSubpath()

        // The page's open face under the band (wound the other way): x 3.5…14.5, y 6…13, minus the
        // curled flap, whose free corner at (11, 9.5) is rounded so it reads as a curl, not a fold.
        p.move(to: CGPoint(x: 4, y: 6))
        p.addArc(tangent1End: CGPoint(x: 3.5, y: 6), tangent2End: CGPoint(x: 3.5, y: 13), radius: 0.5)
        p.addArc(tangent1End: CGPoint(x: 3.5, y: 13), tangent2End: CGPoint(x: 11, y: 13), radius: 0.5)
        p.addLine(to: CGPoint(x: 11, y: 13))
        p.addArc(tangent1End: CGPoint(x: 11, y: 9.5), tangent2End: CGPoint(x: 14.5, y: 9.5), radius: 1.25)
        p.addLine(to: CGPoint(x: 14.5, y: 9.5))
        p.addArc(tangent1End: CGPoint(x: 14.5, y: 6), tangent2End: CGPoint(x: 4, y: 6), radius: 0.5)
        p.closeSubpath()

        // The portal, where the corner used to be.
        p.addEllipse(in: CGRect(x: 15, y: 11.5, width: 3, height: 3))
        return p
    }
}

/// The mark as a SwiftUI shape, aspect-fitted and centred in the frame it is given. Fill it with one
/// colour: `BrandMark().fill(palette.accent).frame(width: 12, height: 12)`.
struct BrandMark: Shape {
    /// Width over height of the glyph (16 : 14).
    static let aspect = BrandMarkGeometry.bounds.width / BrandMarkGeometry.bounds.height

    /// The glyph's size when it fits a `side` × `side` box (12 → 12 × 10.5).
    static func size(fitting side: CGFloat) -> CGSize {
        CGSize(width: side, height: side / aspect)
    }

    func path(in rect: CGRect) -> Path {
        let box = BrandMarkGeometry.bounds
        let scale = min(rect.width / box.width, rect.height / box.height)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return Path(BrandMarkGeometry.path).applying(transform)
    }
}
