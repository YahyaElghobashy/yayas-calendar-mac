// PNG encoding for every image this repo commits (Tools/strip-image-meta.swift, Tools/MakeIcons.swift).
//
// The pixels are drawn into an 8-bit sRGB RGBA bitmap, ImageIO encodes them with no properties, and
// the file is then cut down to its critical chunks: IHDR, PLTE (never written for RGBA), IDAT and
// IEND. No text, time, colour profile, physical size or any other ancillary chunk survives, so nothing
// about the machine or the program that made a file travels with it. Untagged PNG pixels are read as
// sRGB, which is what they are.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CleanPNG {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let critical: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND"]
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// An empty 8-bit sRGB RGBA canvas, `width` × `height` pixels, origin bottom left.
    static func canvas(_ width: Int, _ height: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        return ctx
    }

    /// `image` colour-matched into an 8-bit sRGB RGBA bitmap of the same size.
    static func srgbImage(_ image: CGImage) -> CGImage {
        let ctx = canvas(image.width, image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    /// The first image of a file, decoded by ImageIO (any format it reads).
    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "cannot decode \(url.lastPathComponent)")
        }
        return image
    }

    /// PNG bytes for `image`: sRGB, critical chunks only.
    static func encode(_ image: CGImage) throws -> Data {
        let pixels = srgbImage(image)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "ImageIO has no PNG encoder")
        }
        CGImageDestinationAddImage(dest, pixels, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure(description: "PNG encoding failed") }
        return try criticalChunksOnly(out as Data)
    }

    /// Writes `image` to `url` as a clean PNG and reads it back to prove it.
    static func write(_ image: CGImage, to url: URL) throws {
        let png = try encode(image)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        let back = try Data(contentsOf: url)
        let types = try chunkTypes(back)
        guard Set(types).isSubset(of: critical) else { throw Failure(description: "\(url.lastPathComponent): ancillary chunk left") }
        let decoded = try read(url)
        guard decoded.width == image.width, decoded.height == image.height else {
            throw Failure(description: "\(url.lastPathComponent): size changed on the way out")
        }
    }

    /// The chunk types of a PNG, in file order.
    static func chunkTypes(_ png: Data) throws -> [String] {
        try chunks(png).map(\.type)
    }

    /// `png` with every ancillary chunk removed (critical chunks are copied byte for byte, CRC included).
    static func criticalChunksOnly(_ png: Data) throws -> Data {
        var out = Data(signature)
        for chunk in try chunks(png) where critical.contains(chunk.type) {
            out.append(png.subdata(in: chunk.range))
        }
        return out
    }

    private struct Chunk {
        let type: String
        /// Length, type, data and CRC.
        let range: Range<Int>
    }

    private static func chunks(_ png: Data) throws -> [Chunk] {
        let bytes = [UInt8](png)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { throw Failure(description: "not a PNG") }
        var result: [Chunk] = []
        var at = 8
        while at < bytes.count {
            guard at + 12 <= bytes.count else { throw Failure(description: "truncated PNG chunk") }
            let length = bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[at + 4..<at + 8], as: UTF8.self)
            let end = at + 12 + length
            guard end <= bytes.count else { throw Failure(description: "truncated PNG chunk \(type)") }
            result.append(Chunk(type: type, range: at..<end))
            at = end
            if type == "IEND" { break }
        }
        guard result.first?.type == "IHDR", result.last?.type == "IEND" else { throw Failure(description: "malformed PNG") }
        return result
    }
}
