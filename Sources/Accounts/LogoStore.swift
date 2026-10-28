import AppKit
import Foundation
import ImageIO

/// Per-account logos as 128×128 PNGs in `Paths.logos/<uuid>.png` (inside the widget's readable folder,
/// so widgets can draw them). Any image the user picks, drops or the fetcher finds is normalised here.
struct LogoStore: Sendable {
    static let side = 128

    let directory: URL

    func fileName(for id: UUID) -> String { "\(id.uuidString).png" }
    func url(for id: UUID) -> URL { directory.appendingPathComponent(fileName(for: id)) }

    /// Normalises `data` (PNG, JPEG, ICO, SVG, TIFF…) and writes it atomically. Returns the file name.
    @discardableResult
    func save(imageData data: Data, for id: UUID) throws -> String {
        guard let png = Self.normalizedPNG(from: data)?.png else { throw LogoError.notAnImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: url(for: id), options: .atomic)
        return fileName(for: id)
    }

    @discardableResult
    func importFile(at file: URL, for id: UUID) throws -> String {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 20 << 20 else { throw LogoError.tooLarge }
        return try save(imageData: Data(contentsOf: file), for: id)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    func image(named file: String?) -> NSImage? {
        guard let file, !file.contains("/") else { return nil }
        return NSImage(contentsOf: directory.appendingPathComponent(file))
    }

    enum LogoError: Error { case notAnImage, tooLarge }

    // MARK: - Normalising

    /// Aspect-fits any decodable image into a transparent `side`×`side` PNG. `sourcePixels` is the
    /// largest bitmap edge in the source, or `Int.max` for vector images (SVG, PDF).
    static func normalizedPNG(from data: Data, side: Int = LogoStore.side) -> (png: Data, sourcePixels: Int)? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              !image.representations.isEmpty else { return nil }
        let bitmapEdges = image.representations.compactMap { rep -> Int? in
            rep.pixelsWide > 0 ? max(rep.pixelsWide, rep.pixelsHigh) : nil
        }
        let sourcePixels = bitmapEdges.max() ?? Int.max

        let aspect = image.size.width / image.size.height
        let fit = aspect >= 1
            ? CGSize(width: CGFloat(side), height: max(1, CGFloat(side) / aspect))
            : CGSize(width: max(1, CGFloat(side) * aspect), height: CGFloat(side))
        var proposed = CGRect(origin: .zero, size: fit)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        let rect = CGRect(x: (CGFloat(side) - fit.width) / 2, y: (CGFloat(side) - fit.height) / 2,
                          width: fit.width, height: fit.height)
        context.draw(cg, in: rect)
        guard let output = context.makeImage() else { return nil }

        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (png as Data, sourcePixels)
    }
}
