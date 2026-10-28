import AppKit
import Foundation

/// The fictional cast every sample, fixture, render and test draws from: the Moonfield desk. Its owner,
/// Avery Moonfield, keeps a work calendar, a band, a family calendar and a personal one. Every name is
/// invented, every address uses a reserved `.example` domain (RFC 2606), and the badges are drawn here
/// in code, so a gallery, a render or a test never reads a logo file from disk.
enum Cast {
    struct Account {
        /// Stable sample key (`WidgetAccount.id` of the sample week).
        let key: String
        /// The tag on rows and chips.
        let tag: String
        let name: String
        let email: String
        /// 0xRRGGBB, one of the Accounts swatches.
        let color: UInt32
        /// The fixture account's id (snapshots, the seams' fakes).
        let id: UUID
    }

    static let ownerName = "Avery Moonfield"
    static let ownerFirstName = "Avery"

    static let orb = Account(key: "orb", tag: "ORB", name: "Orbital Pickle Co.", email: "avery@orbitalpickle.example",
                             color: 0x8DBA74, id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!)
    static let cmt = Account(key: "cmt", tag: "CMT", name: "The Quiet Comets", email: "avery@quietcomets.example",
                             color: 0x7F96E8, id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!)
    static let fam = Account(key: "fam", tag: "FAM", name: "Moonfield Family", email: "avery@moonfield-family.example",
                             color: 0xE07A80, id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A3")!)
    /// Personal: no badge, by design.
    static let home = Account(key: "home", tag: "Personal", name: "Personal", email: "avery@home.example",
                              color: 0xD2A6C6, id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A0")!)

    /// In the order the Accounts list shows them.
    static let accounts = [orb, cmt, fam, home]

    static func account(key: String) -> Account? { accounts.first { $0.key == key } }
    static func account(id: UUID) -> Account? { accounts.first { $0.id == id } }

    /// The built-in badge of a cast account, drawn in code at 128 px: a pickle wearing a planet ring
    /// (ORB), a comet (CMT), a little house (FAM). Nil for Personal and for anything outside the cast.
    static func badge(key: String) -> NSImage? {
        guard key == orb.key || key == cmt.key || key == fam.key else { return nil }
        let side = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let s = CGFloat(side)
        func colour(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        func rotated(_ path: NSBezierPath, _ degrees: CGFloat) -> NSBezierPath {
            var t = AffineTransform()
            t.translate(x: s / 2, y: s / 2)
            t.rotate(byDegrees: degrees)
            path.transform(using: t)
            return path
        }
        let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: s * 0.22, yRadius: s * 0.22)
        switch key {
        case orb.key:
            colour(0x23402A).setFill(); tile.fill()
            let pickle = rotated(NSBezierPath(roundedRect: NSRect(x: -s * 0.15, y: -s * 0.33, width: s * 0.30, height: s * 0.66),
                                              xRadius: s * 0.15, yRadius: s * 0.15), -35)
            colour(0x8DBA74).setFill(); pickle.fill()
            for (dx, dy) in [(-0.04, 0.12), (0.05, -0.02), (-0.03, -0.16)] {
                let bump = rotated(NSBezierPath(ovalIn: NSRect(x: s * dx - s * 0.03, y: s * dy - s * 0.03, width: s * 0.06, height: s * 0.06)), -35)
                colour(0x5E8F4C).setFill(); bump.fill()
            }
            let ring = rotated(NSBezierPath(ovalIn: NSRect(x: -s * 0.40, y: -s * 0.11, width: s * 0.80, height: s * 0.22)), 18)
            ring.lineWidth = s * 0.055
            colour(0xF2D479).setStroke(); ring.stroke()
        case cmt.key:
            colour(0x1E2148).setFill(); tile.fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: s * 0.62, y: s * 0.74))
            tail.line(to: NSPoint(x: s * 0.16, y: s * 0.20))
            tail.line(to: NSPoint(x: s * 0.76, y: s * 0.56))
            tail.close()
            colour(0x7F96E8).setFill(); tail.fill()
            colour(0xF4ECC8).setFill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.56, y: s * 0.56, width: s * 0.26, height: s * 0.26)).fill()
        default:
            colour(0x5B2D33).setFill(); tile.fill()
            let house = NSBezierPath()
            house.move(to: NSPoint(x: s * 0.50, y: s * 0.80))
            house.line(to: NSPoint(x: s * 0.82, y: s * 0.52))
            house.line(to: NSPoint(x: s * 0.72, y: s * 0.52))
            house.line(to: NSPoint(x: s * 0.72, y: s * 0.20))
            house.line(to: NSPoint(x: s * 0.28, y: s * 0.20))
            house.line(to: NSPoint(x: s * 0.28, y: s * 0.52))
            house.line(to: NSPoint(x: s * 0.18, y: s * 0.52))
            house.close()
            colour(0xF6E3D3).setFill(); house.fill()
            colour(0xE07A80).setFill()
            NSBezierPath(roundedRect: NSRect(x: s * 0.43, y: s * 0.20, width: s * 0.14, height: s * 0.20),
                         xRadius: s * 0.03, yRadius: s * 0.03).fill()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }
}
