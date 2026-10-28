import AppKit
import ImageIO

// The rich composer's own HTML serializer (D-042). Never AppKit's HTML export: that writes
// a <style> block of generated classes that Gmail and Outlook drop, absolute pt sizes, Apple font names, file://
// attachment references and duplicated list markers, and its output changes with every macOS release. This writer
// emits Gmail-shaped markup with inline styles only, deterministically (golden tests pin it), plus the
// text/plain alternative. Compiled into the app, the data tests (Mail glob) and the shell tests, so it carries its
// own escaping and link check instead of using HTMLEntities / URLPolicy (a data test proves the verdicts match).

// MARK: - Document conventions (editor ↔ writer ↔ reader)

extension NSAttributedString.Key {
    /// Bool: the range is the account's signature (the composer swaps it when From changes).
    static let ycSignature = NSAttributedString.Key("YCSignature")
    /// Int ≥ 1: the paragraph is a quote block of that depth (a bar per level, drawn by the editor).
    static let ycQuoteBlock = NSAttributedString.Key("YCQuoteBlock")
    /// String: the content-id of an inline image (on the attachment character).
    static let ycInlineImage = NSAttributedString.Key("YCInlineImage")
}

/// What the editor, the writer and the reader agree on: indent steps, list markers, quote levels and fonts.
enum MailRichText {
    /// Points per indent level outside lists (the writer emits 40 px per level, like Gmail).
    static let indentStep: CGFloat = 30
    /// Points per quote level: room for the bar the editor draws.
    static let quoteStep: CGFloat = 16
    static let maxIndent = 8
    static let maxQuote = 8
    static let maxListDepth = 8
    static let lineHeightMultiple: CGFloat = 1.15

    /// A list marker that a TextKit 1 source left in the text (TextKit 2 draws markers itself, so text ones would
    /// show twice): "\t•\t", "•\t", "\t12.\t", "3)\t"… (a single-character class would miss "12.").
    static let markerPattern = #"^\t?(?:[•◦▪‣⁃–-]|\d+[.)]?)\t"#
    private static let markerRegex = try? NSRegularExpression(pattern: markerPattern)

    /// Length of a leading list-marker run in `text` (0 = none).
    static func markerLength(_ text: String) -> Int {
        guard let regex = markerRegex else { return 0 }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: min(ns.length, 16)))?.range.length ?? 0
    }

    static let decimal = NSTextList.MarkerFormat(rawValue: "{decimal}.")

    /// Bullets change with depth (disc, circle, square), as in Apple Mail and Gmail.
    static func bulletFormat(depth: Int) -> NSTextList.MarkerFormat {
        switch depth {
        case ...1: return .disc
        case 2: return .circle
        default: return .square
        }
    }

    static func isOrdered(_ list: NSTextList) -> Bool {
        let format = list.markerFormat.rawValue.lowercased()
        return ["decimal", "roman", "alpha", "octal", "hex"].contains { format.contains($0) }
    }

    static func newList(ordered: Bool, depth: Int) -> NSTextList {
        NSTextList(markerFormat: ordered ? decimal : bulletFormat(depth: depth), options: 0)
    }

    static func quoteLevel(_ value: Any?) -> Int {
        if let n = value as? Int { return max(0, min(maxQuote, n)) }
        if let n = value as? NSNumber { return max(0, min(maxQuote, n.intValue)) }
        return 0
    }

    /// Indent level of a paragraph outside a list (its head indent less the quote's share).
    static func indentLevel(_ style: NSParagraphStyle?, quote: Int) -> Int {
        guard let style, style.textLists.isEmpty else { return 0 }
        let rest = style.headIndent - CGFloat(quote) * quoteStep
        return max(0, min(maxIndent, Int((rest / indentStep).rounded())))
    }

    /// The paragraph style for a level of indent and quote and a list path, on top of `base` (alignment, spacing).
    static func paragraphStyle(base: NSParagraphStyle?, indent: Int, quote: Int, lists: [NSTextList],
                               direction: NSWritingDirection? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if let base { style.setParagraphStyle(base) } else { style.lineHeightMultiple = lineHeightMultiple }
        style.textLists = lists
        style.textBlocks = []
        // TextKit 2 places list markers and list text by depth itself; outside lists the head indent carries
        // the indent and quote levels.
        let head = lists.isEmpty ? CGFloat(max(0, indent)) * indentStep + CGFloat(max(0, quote)) * quoteStep : CGFloat(max(0, quote)) * quoteStep
        style.headIndent = head
        style.firstLineHeadIndent = head
        if let direction { style.baseWritingDirection = direction }
        return style
    }

    /// The system font's family name as AppKit reports it.
    static let systemFamily = ".AppleSystemUIFont"

    /// A font of `family` with the traits, falling back trait by trait, then to Helvetica (never nil).
    static func font(family: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let size = max(1, size)
        if family == systemFamily || family.hasPrefix(".SF") {
            let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            guard italic else { return base }
            let traits = base.fontDescriptor.symbolicTraits.union(.italic)
            return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
        }
        for (b, i) in [(bold, italic), (bold, false), (false, italic), (false, false)] {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if b { traits.insert(.bold) }
            if i { traits.insert(.italic) }
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family]).withSymbolicTraits(traits)
            if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family { return font }
        }
        return family == "Helvetica" ? NSFont.systemFont(ofSize: size) : font(family: "Helvetica", size: size, bold: bold, italic: italic)
    }

    static func isBold(_ font: NSFont?) -> Bool { font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false }
    static func isItalic(_ font: NSFont?) -> Bool { font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false }

    /// Strong right-to-left scripts (Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic and their presentation
    /// forms). Digits, punctuation, spaces and emoji are neutral.
    static func isStrongRTL(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }

    /// The paragraph's first strong character is right-to-left.
    static func startsRTL(_ text: String) -> Bool {
        for s in text.unicodeScalars {
            if isStrongRTL(s) { return true }
            if s.properties.isAlphabetic { return false }
        }
        return false
    }
}

/// A font choice as the writer sees it: the editor family and the CSS stack recipients' clients get.
struct FontChoiceCSS: Equatable {
    var key: String
    /// Family name in the editor (NSFont.familyName).
    var family: String
    var stack: String

    static let sans = FontChoiceCSS(key: "sans", family: "Helvetica", stack: "Helvetica, Arial, sans-serif")
    static let system = FontChoiceCSS(key: "system", family: MailRichText.systemFamily,
                                      stack: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, Helvetica, Arial, sans-serif")
    static let serif = FontChoiceCSS(key: "serif", family: "Georgia", stack: "Georgia, \"Times New Roman\", serif")
    static let times = FontChoiceCSS(key: "times", family: "Times New Roman", stack: "\"Times New Roman\", Times, serif")
    static let verdana = FontChoiceCSS(key: "verdana", family: "Verdana", stack: "Verdana, Geneva, sans-serif")
    static let trebuchet = FontChoiceCSS(key: "trebuchet", family: "Trebuchet MS", stack: "\"Trebuchet MS\", sans-serif")
    static let mono = FontChoiceCSS(key: "mono", family: "Menlo", stack: "Menlo, Monaco, Consolas, \"Courier New\", monospace")

    static let all: [FontChoiceCSS] = [sans, system, serif, times, verdana, trebuchet, mono]

    static func choice(key: String) -> FontChoiceCSS? { all.first { $0.key == key } }

    static func choice(family: String) -> FontChoiceCSS? {
        if family.hasPrefix(".SF") { return system }
        return all.first { $0.family.caseInsensitiveCompare(family) == .orderedSame }
    }

    /// The CSS stack for any family: ours for the seven choices; otherwise the family by name (quoted when it
    /// needs it) and a generic fallback chosen from the font's traits.
    static func stack(family: String, font: NSFont?) -> String {
        if let known = choice(family: family) { return known.stack }
        let clean = String(family.unicodeScalars.filter { $0.value >= 0x20 && !"\"'\\;<>{}".unicodeScalars.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return sans.stack }
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let generic: String
        if traits.contains(.monoSpace) {
            generic = "monospace"
        } else {
            // The font class lives in the top four bits (NSFontDescriptorClassMask): 1–7 are serif classes, 10 scripts.
            switch (traits.rawValue >> 28) & 0xF {
            case 1, 2, 3, 4, 5, 7: generic = "serif"
            case 10: generic = "cursive"
            default: generic = "sans-serif"
            }
        }
        let simple = clean.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0 == "-") }
        return (simple ? clean : "\"\(clean)\"") + ", " + generic
    }
}

// MARK: - Writer

enum MailHTMLWriter {
    struct Output: Equatable {
        var html: String
        var text: String
        var inlineImages: [InlineImage]
    }

    struct InlineImage: Equatable {
        var contentId: String
        var mimeType: String
        var data: Data
        var filename: String
    }

    /// Inline images are capped at this display width (aspect ratio kept).
    static let maxImageWidth: CGFloat = 600
    static let quoteStyle = "margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex"
    static let indentStyle = "margin-left:40px"
    static let signatureOpen = "<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">"

    static func newContentId() -> String { UUID().uuidString.lowercased() + "@yayascalendar.local" }

    /// HTML and text/plain for a composer document. `font`/`size` are the document defaults (Settings → Writing):
    /// the wrapper carries them, so runs in the default face need no span. Content-ids for inline images without one
    /// come from `contentId` (tests pass a counter).
    static func render(_ doc: NSAttributedString, font: FontChoiceCSS, size: Int,
                       contentId: @escaping () -> String = MailHTMLWriter.newContentId) -> Output {
        var writer = Writer(doc: doc, font: font, size: size, contentId: contentId)
        writer.run()
        return Output(html: "<div dir=\"auto\" style=\"font-family:\(escape(font.stack));font-size:\(size)px\">" + writer.html + "</div>",
                      text: writer.text, inlineImages: writer.images)
    }

    /// An inline image's bytes and type, as the writer sends them: its own PNG/JPEG/GIF bytes once `stripMetadata`
    /// vouches for them, else a new PNG drawn from its pixels. Never the original bytes with their metadata.
    static func imageData(_ attachment: NSTextAttachment) -> (Data, String)? { Writer.imageData(attachment) }

    // MARK: Picture metadata

    /// The picture with nothing about where, when, who or with what it was made, or nil when that can't be made sure
    /// of (the writer then redraws it from its pixels, so the original bytes never go out with their metadata).
    /// - PNG and JPEG: the bytes as they are when neither ImageIO (`hasPrivateMetadata`) nor a walk through the file
    ///   (`PictureFile.hasExtras`: comments, text chunks, unknown segments, bytes after the end) finds anything to
    ///   remove; else the same encoded pixels with the metadata dropped (lossless); else re-encoded from the first
    ///   picture (PNG stays lossless with its alpha, JPEG at 0.92, the orientation kept). Each result is checked again.
    /// - GIF: comment blocks, application blocks other than the loop count and the colour profile, unknown extensions
    ///   and bytes after the end are dropped; every frame stays as it was. Checked again.
    /// - Anything else, or bytes ImageIO can't read: nil.
    static func stripMetadata(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source).map({ $0 as String }) else { return nil }
        let frames = CGImageSourceGetCount(source)
        guard frames >= 1 else { return nil }
        func clean(_ out: Data, frames expected: Int = 1) -> Data? {
            guard let check = CGImageSourceCreateWithData(out as CFData, nil), CGImageSourceGetCount(check) == expected,
                  !(0..<expected).contains(where: { hasPrivateMetadata(check, at: $0) }), !PictureFile.hasExtras(out) else { return nil }
            return out
        }
        if type == "com.compuserve.gif" { return PictureFile.strippedGIF(data).flatMap { clean($0, frames: frames) } }
        guard type == "public.jpeg" || type == "public.png" else { return nil }
        if frames == 1 {
            if let same = clean(data) { return same }
            // Lossless: the same encoded pixels with the metadata replaced by none.
            let copied = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(copied, type as CFString, 1, nil) {
                let options: [CFString: Any] = [kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                                                kCGImageDestinationMergeMetadata: false,
                                                kCGImageMetadataShouldExcludeGPS: true,
                                                kCGImageMetadataShouldExcludeXMP: true]
                if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil), let out = clean(copied as Data) { return out }
            }
        }
        // Re-encoded from the first (or only) picture with only the orientation.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var keep: [CFString: Any] = [:]
        if let orientation = props[kCGImagePropertyOrientation] { keep[kCGImagePropertyOrientation] = orientation }
        if type == "public.jpeg" { keep[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        let encoded = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(encoded, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, keep as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return clean(encoded as Data)
    }

    /// A new PNG of the picture's first image, turned upright: fresh pixels, so nothing else comes along. Nil when
    /// ImageIO can't read it.
    static func redrawn(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1)] as CFDictionary)
        else { return nil }
        return freshPNG(image)
    }

    /// The same for an image AppKit holds (an attachment without file contents).
    static func redrawn(_ image: NSImage) -> Data? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(freshPNG)
    }

    private static func freshPNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest), let check = CGImageSourceCreateWithData(out, nil), !hasPrivateMetadata(check),
              !PictureFile.hasExtras(out as Data) else { return nil }
        return out as Data
    }

    /// Anything about where, when, who or with what the picture was made: GPS, IPTC, maker notes, EXIF or TIFF fields
    /// beyond the encoder's own (colour space, pixel size, resolution, orientation), PNG text, or XMP beyond those.
    static func hasPrivateMetadata(_ source: CGImageSource, at index: Int = 0) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return false }
        let alwaysPrivate: [CFString] = [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary,
                                         kCGImageProperty8BIMDictionary, kCGImagePropertyMakerAppleDictionary,
                                         kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
                                         kCGImagePropertyMakerMinoltaDictionary, kCGImagePropertyMakerFujiDictionary,
                                         kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary]
        if alwaysPrivate.contains(where: { props[$0] != nil }) { return true }
        let exif = (props[kCGImagePropertyExifDictionary] as? [String: Any]).map { Set($0.keys) } ?? []
        let tiff = (props[kCGImagePropertyTIFFDictionary] as? [String: Any]).map { Set($0.keys) } ?? []
        let png = (props[kCGImagePropertyPNGDictionary] as? [String: Any]).map { Set($0.keys) } ?? []
        if !exif.subtracting(benignExif).isEmpty || !tiff.subtracting(benignTIFF).isEmpty || !png.isDisjoint(with: pngText) { return true }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return false }
        return tags.contains { tag in
            let prefix = CGImageMetadataTagCopyPrefix(tag).map { $0 as String } ?? ""
            let name = CGImageMetadataTagCopyName(tag).map { $0 as String } ?? ""
            return !benignXMP.contains(prefix + ":" + name)
        }
    }

    /// What an encoder writes on its own: colour space, pixel size, versions, resolution, orientation.
    private static let benignExif = Set([kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                                         kCGImagePropertyExifVersion, kCGImagePropertyExifFlashPixVersion,
                                         kCGImagePropertyExifComponentsConfiguration].map { $0 as String })
    private static let benignTIFF = Set([kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                                         kCGImagePropertyTIFFResolutionUnit].map { $0 as String })
    private static let pngText = Set([kCGImagePropertyPNGAuthor, kCGImagePropertyPNGComment, kCGImagePropertyPNGCopyright,
                                      kCGImagePropertyPNGCreationTime, kCGImagePropertyPNGDescription, kCGImagePropertyPNGDisclaimer,
                                      kCGImagePropertyPNGModificationTime, kCGImagePropertyPNGSoftware, kCGImagePropertyPNGSource,
                                      kCGImagePropertyPNGTitle, kCGImagePropertyPNGWarning].map { $0 as String })
    /// XMP mirrors of the benign EXIF and TIFF fields.
    private static let benignXMP: Set<String> = ["exif:ColorSpace", "exif:PixelXDimension", "exif:PixelYDimension", "exif:ExifVersion",
                                                 "exif:FlashpixVersion", "exif:ComponentsConfiguration", "tiff:Orientation",
                                                 "tiff:XResolution", "tiff:YResolution", "tiff:ResolutionUnit"]

    /// "image/png", "image/jpeg" or "image/gif" from the first bytes, else nil.
    static func sniffImage(_ data: Data) -> String? { Writer.sniff(data) }

    /// The plain text alone (rich → plain switch, `body` of a rich draft).
    static func text(_ doc: NSAttributedString, font: FontChoiceCSS = .sans, size: Int = 14) -> String {
        render(doc, font: font, size: size, contentId: { "x" }).text
    }

    // MARK: Escaping and links

    /// `&`, `<`, `>`, `"`; C0 controls other than tab and newline are dropped.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" { continue }
                if scalar.value == 0x7F { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The link target to emit, or nil (the text goes out unlinked). The same normalization as the sanitizer's
    /// `URLPolicy.classify` (tab/LF/CR removed anywhere, C0 controls and spaces trimmed), then only http, https,
    /// mailto and tel pass.
    static func linkVerdict(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for c in raw.unicodeScalars where !(c == "\t" || c == "\n" || c == "\r") { scalars.append(c) }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: Unicode.Scalar(UInt8(0))...Unicode.Scalar(UInt8(0x20))))
        guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
        var scheme = ""
        for c in value.unicodeScalars {
            if c == ":" { break }
            if c == "/" || c == "?" || c == "#" { return nil }
            scheme.unicodeScalars.append(c)
        }
        guard scheme.count < value.count, !scheme.isEmpty,
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return nil }
        return ["http", "https", "mailto", "tel"].contains(scheme.lowercased()) ? value : nil
    }

    /// A `.link` attribute's value (URL or String) as the target to emit, or nil.
    static func linkTarget(_ value: Any?) -> String? {
        if let url = value as? URL { return linkVerdict(url.absoluteString) }
        if let url = value as? NSURL { return url.absoluteString.flatMap(linkVerdict) }
        if let string = value as? String { return linkVerdict(string) }
        return nil
    }

    // MARK: Colours

    /// `#rrggbb` for an explicit colour, or nil when it should not be written: catalog and dynamic colours
    /// (`textColor`, `labelColor`…) and anything within ΔE 3 of black or the sheet's text colour #1D1B20.
    static func cssColor(_ value: Any?) -> String? {
        guard let rgb = rgb(value) else { return nil }
        if deltaE(rgb, (0, 0, 0)) < 3 || deltaE(rgb, (0x1D, 0x1B, 0x20)) < 3 { return nil }
        return hex(rgb)
    }

    /// Highlight: catalog colours and near-white (on a white sheet it is no highlight) are not written.
    static func cssBackground(_ value: Any?) -> String? {
        guard let rgb = rgb(value), deltaE(rgb, (0xFF, 0xFF, 0xFF)) >= 3 else { return nil }
        return hex(rgb)
    }

    static func hex(_ rgb: (Int, Int, Int)) -> String { String(format: "#%02x%02x%02x", rgb.0, rgb.1, rgb.2) }

    /// sRGB 0–255 components of an explicit colour; nil for catalog/dynamic colours and transparent ones.
    static func rgb(_ value: Any?) -> (Int, Int, Int)? {
        guard let color = value as? NSColor, color.type == .componentBased, let srgb = color.usingColorSpace(.sRGB),
              srgb.alphaComponent > 0.02 else { return nil }
        func c(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return (c(srgb.redComponent), c(srgb.greenComponent), c(srgb.blueComponent))
    }

    /// CIE76 colour difference in Lab (D65).
    static func deltaE(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Double {
        let la = lab(a), lb = lab(b)
        return ((la.0 - lb.0) * (la.0 - lb.0) + (la.1 - lb.1) * (la.1 - lb.1) + (la.2 - lb.2) * (la.2 - lb.2)).squareRoot()
    }

    private static func lab(_ c: (Int, Int, Int)) -> (Double, Double, Double) {
        func lin(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.0), g = lin(c.1), b = lin(c.2)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    // MARK: The pass

    private enum Container: Equatable {
        case signature
        case quote(Int)
        case indent(Int)
        case list(ObjectIdentifier, ordered: Bool, start: Int)

        var open: String {
            switch self {
            case .signature: return MailHTMLWriter.signatureOpen
            case .quote: return "<blockquote style=\"\(MailHTMLWriter.quoteStyle)\">"
            case .indent: return "<div style=\"\(MailHTMLWriter.indentStyle)\">"
            case .list(_, let ordered, let start):
                return ordered ? (start == 1 ? "<ol>" : "<ol start=\"\(start)\">") : "<ul>"
            }
        }

        var close: String {
            switch self {
            case .signature, .indent: return "</div>"
            case .quote: return "</blockquote>"
            case .list(_, let ordered, _): return ordered ? "</ol>" : "</ul>"
            }
        }
    }

    private enum Tag: Equatable {
        case a(String), b, i, u, s, sup, sub, span(String)

        var open: String {
            switch self {
            case .a(let href): return "<a href=\"\(MailHTMLWriter.escape(href))\">"
            case .b: return "<b>"
            case .i: return "<i>"
            case .u: return "<u>"
            case .s: return "<s>"
            case .sup: return "<sup>"
            case .sub: return "<sub>"
            case .span(let style): return "<span style=\"\(MailHTMLWriter.escape(style))\">"
            }
        }

        var close: String {
            switch self {
            case .a: return "</a>"
            case .b: return "</b>"
            case .i: return "</i>"
            case .u: return "</u>"
            case .s: return "</s>"
            case .sup: return "</sup>"
            case .sub: return "</sub>"
            case .span: return "</span>"
            }
        }
    }

    private struct Writer {
        let doc: NSAttributedString
        let ns: NSString
        let font: FontChoiceCSS
        let size: Int
        let contentId: () -> String
        var html = ""
        var text = ""
        var images: [InlineImage] = []
        private var open: [Container] = []
        private var listCounters: [ObjectIdentifier: Int] = [:]
        private var inSignature = false

        init(doc: NSAttributedString, font: FontChoiceCSS, size: Int, contentId: @escaping () -> String) {
            self.doc = doc
            ns = doc.string as NSString
            self.font = font
            self.size = size
            self.contentId = contentId
            html.reserveCapacity(doc.length * 2)
        }

        mutating func run() {
            var paragraphs: [(content: NSRange, enclosing: NSRange)] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
                paragraphs.append((range, enclosing))
            }
            for p in paragraphs { paragraph(p.content, p.enclosing) }
            close(to: 0)
        }

        private mutating func close(to depth: Int) {
            while open.count > depth {
                let top = open.removeLast()
                html += top.close
                if case .list(let id, _, _) = top { listCounters[id] = nil }
            }
        }

        private func attributes(_ content: NSRange, _ enclosing: NSRange) -> [NSAttributedString.Key: Any] {
            if content.length > 0 { return doc.attributes(at: content.location, effectiveRange: nil) }
            if enclosing.length > 0, enclosing.location < doc.length { return doc.attributes(at: enclosing.location, effectiveRange: nil) }
            return [:]
        }

        private mutating func paragraph(_ content: NSRange, _ enclosing: NSRange) {
            let attrs = attributes(content, enclosing)
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            let lists = Array((style?.textLists ?? []).prefix(MailRichText.maxListDepth))
            let quote = MailRichText.quoteLevel(attrs[.ycQuoteBlock])
            let indent = MailRichText.indentLevel(style, quote: quote)
            let signature = (attrs[.ycSignature] as? Bool) == true || (attrs[.ycSignature] as? NSNumber)?.boolValue == true

            var range = content
            if !lists.isEmpty {
                let strip = MailRichText.markerLength(ns.substring(with: range))
                range = NSRange(location: range.location + strip, length: range.length - strip)
            }
            let string = ns.substring(with: range)

            // Containers: signature ⊃ quote levels ⊃ indent levels (outside lists) ⊃ list levels.
            var path: [Container] = []
            if signature { path.append(.signature) }
            if quote > 0 { for level in 1...quote { path.append(.quote(level)) } }
            if lists.isEmpty, indent > 0 { for level in 1...indent { path.append(.indent(level)) } }
            for list in lists {
                path.append(.list(ObjectIdentifier(list), ordered: MailRichText.isOrdered(list), start: max(1, list.startingItemNumber)))
            }
            var common = 0
            while common < open.count, common < path.count, open[common] == path[common] { common += 1 }
            close(to: common)
            for container in path[common...] {
                html += container.open
                open.append(container)
            }

            // text/plain: the signature after "-- " (RFC 3676); quote levels as "> "; list markers.
            if signature && !inSignature { text += "-- \n" }
            inSignature = signature
            let quotePrefix = String(repeating: "> ", count: quote)
            var prefix = quotePrefix
            if lists.isEmpty {
                prefix += String(repeating: "    ", count: indent)
            } else if let list = lists.last {
                let id = ObjectIdentifier(list)
                let n = (listCounters[id] ?? 0) + 1
                listCounters[id] = n
                prefix += String(repeating: "   ", count: lists.count - 1)
                prefix += MailRichText.isOrdered(list) ? "\(max(1, list.startingItemNumber) + n - 1). " : "\u{2022} "
            }
            let continuation = quotePrefix + String(repeating: " ", count: max(0, prefix.count - quotePrefix.count))

            let rtl = style?.baseWritingDirection == .rightToLeft || MailRichText.startsRTL(string)
            let element = lists.isEmpty ? "div" : "li"
            html += rtl ? "<\(element) dir=\"rtl\">" : "<\(element)>"
            text += prefix
            if range.length == 0 {
                html += "<br>"
            } else {
                runs(range, continuation: continuation)
            }
            html += "</\(element)>"
            text += "\n"
        }

        /// Spaces that must be &nbsp; so a browser keeps them: every other one in a run of two or more, and a
        /// space at the start or end of a line.
        private func hardSpaces(_ range: NSRange) -> Set<Int> {
            var out = Set<Int>()
            let n = range.location + range.length
            var i = range.location
            func isBreak(_ k: Int) -> Bool { k < range.location || k >= n || ns.character(at: k) == 0x2028 }
            while i < n {
                guard ns.character(at: i) == 0x20 else { i += 1; continue }
                var j = i
                while j < n, ns.character(at: j) == 0x20 { j += 1 }
                let atStart = isBreak(i - 1), atEnd = isBreak(j)
                if j - i >= 2 || atStart || atEnd {
                    for k in i..<j where (atStart ? (k - i) % 2 == 0 : (k - i) % 2 == 1) { out.insert(k) }
                    if atEnd { out.insert(j - 1) }
                }
                i = j
            }
            return out
        }

        private mutating func runs(_ range: NSRange, continuation: String) {
            let hard = hardSpaces(range)
            var tags: [Tag] = []
            let lastIndex = range.location + range.length - 1
            // text/plain: a link's text is collected across its runs, then "text <url>" when they differ.
            var link: String?
            var linkText = ""
            func flushLink() {
                guard let target = link else { return }
                let shown = linkText.trimmingCharacters(in: .whitespaces)
                let bare = target.lowercased().hasPrefix("mailto:") ? String(target.dropFirst(7)) : target
                // "Juniper <juniper@vale.example>": an address reads without its mailto: (as Gmail writes it).
                if !shown.isEmpty, shown != target, shown != bare { text += " <\(bare)>" }
                link = nil
                linkText = ""
            }
            doc.enumerateAttributes(in: range, options: []) { attrs, run, _ in
                let wanted = self.tags(for: attrs)
                var common = 0
                while common < tags.count, common < wanted.count, tags[common] == wanted[common] { common += 1 }
                for tag in tags[common...].reversed() { html += tag.close }
                for tag in wanted[common...] { html += tag.open }
                tags = wanted

                let target = attrs[.attachment] == nil ? MailHTMLWriter.linkTarget(attrs[.link]) : nil
                if target != link {
                    flushLink()
                    link = target
                }
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    for _ in 0..<run.length { image(attachment, cid: attrs[.ycInlineImage] as? String) }
                    return
                }
                var k = run.location
                var runText = ""
                for scalar in ns.substring(with: run).unicodeScalars {
                    let at = k
                    k += scalar.utf16.count
                    switch scalar {
                    case " ":
                        html += hard.contains(at) ? "&nbsp;" : " "
                        runText += " "
                    case "\t":
                        html += "&nbsp;&nbsp;&nbsp;&nbsp;"
                        runText += "\t"
                    case "\u{2028}":
                        // A line break inside the paragraph; one at its very end needs a second <br> to show.
                        html += at == lastIndex ? "<br><br>" : "<br>"
                        runText += "\n" + continuation
                    case "\u{FFFC}":
                        continue
                    case "&": html += "&amp;"; runText += "&"
                    case "<": html += "&lt;"; runText += "<"
                    case ">": html += "&gt;"; runText += ">"
                    case "\"": html += "&quot;"; runText += "\""
                    default:
                        if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                        html.unicodeScalars.append(scalar)
                        runText.unicodeScalars.append(scalar)
                    }
                }
                text += runText
                if link != nil { linkText += runText }
            }
            flushLink()
            for tag in tags.reversed() { html += tag.close }
        }

        private func tags(for attrs: [NSAttributedString.Key: Any]) -> [Tag] {
            var out: [Tag] = []
            if attrs[.attachment] == nil, let href = MailHTMLWriter.linkTarget(attrs[.link]) { out.append(.a(href)) }
            let font = attrs[.font] as? NSFont
            if MailRichText.isBold(font) { out.append(.b) }
            if MailRichText.isItalic(font) { out.append(.i) }
            if let u = attrs[.underlineStyle] as? Int, u != 0 { out.append(.u) }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { out.append(.s) }
            let script = (attrs[.superscript] as? Int) ?? (attrs[.superscript] as? NSNumber)?.intValue ?? 0
            if script > 0 { out.append(.sup) } else if script < 0 { out.append(.sub) }
            var css: [String] = []
            if let font {
                let family = font.familyName ?? self.font.family
                if family != self.font.family { css.append("font-family:" + FontChoiceCSS.stack(family: family, font: font)) }
                let px = Int(font.pointSize.rounded())
                if px != size { css.append("font-size:\(px)px") }
            }
            if let color = MailHTMLWriter.cssColor(attrs[.foregroundColor]) { css.append("color:" + color) }
            if let background = MailHTMLWriter.cssBackground(attrs[.backgroundColor]) { css.append("background-color:" + background) }
            if !css.isEmpty { out.append(.span(css.joined(separator: ";"))) }
            return out
        }

        private mutating func image(_ attachment: NSTextAttachment, cid existing: String?) {
            guard let (data, mime) = Self.imageData(attachment) else { return }
            let cid = (existing?.isEmpty == false ? existing! : contentId())
            var size = attachment.bounds.size
            if size.width <= 0 || size.height <= 0 { size = attachment.image?.size ?? NSImage(data: data)?.size ?? .zero }
            guard size.width > 0, size.height > 0 else { return }
            if size.width > MailHTMLWriter.maxImageWidth {
                size = CGSize(width: MailHTMLWriter.maxImageWidth, height: size.height * MailHTMLWriter.maxImageWidth / size.width)
            }
            let w = Int(size.width.rounded()), h = Int(max(1, size.height.rounded()))
            html += "<img src=\"cid:\(MailHTMLWriter.escape(cid))\" width=\"\(w)\" height=\"\(h)\" alt=\"\" style=\"max-width:100%\">"
            let ext = mime == "image/jpeg" ? "jpg" : mime == "image/gif" ? "gif" : "png"
            let name = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename ?? "image-\(images.count + 1).\(ext)"
            if !images.contains(where: { $0.contentId == cid }) {
                images.append(InlineImage(contentId: cid, mimeType: mime, data: data, filename: name))
            }
            text += "[image: \(name)]"
        }

        /// The attachment's bytes and type: its own PNG, JPEG or GIF contents once `stripMetadata` vouches for them; any
        /// other picture, or one whose metadata can't be removed, redrawn from its pixels as a new PNG; nil without one.
        static func imageData(_ attachment: NSTextAttachment) -> (Data, String)? {
            let contents = attachment.contents ?? attachment.fileWrapper?.regularFileContents
            if let data = contents, let mime = sniff(data), let clean = MailHTMLWriter.stripMetadata(data) { return (clean, mime) }
            if let data = contents, let png = MailHTMLWriter.redrawn(data) { return (png, "image/png") }
            if let image = attachment.image, let png = MailHTMLWriter.redrawn(image) { return (png, "image/png") }
            return nil
        }

        static func sniff(_ data: Data) -> String? {
            let head = [UInt8](data.prefix(4))
            if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
            if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
            if head.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
            return nil
        }
    }
}

// MARK: - Picture files, block by block

/// What ImageIO's properties don't show: comments, text chunks, unknown segments and blocks, bytes after the end.
/// Walks PNG chunks, JPEG segments and GIF blocks; pixels are never decoded here.
enum PictureFile {
    /// True when the file holds anything beyond pixels, colour, size, timing and orientation (EXIF is
    /// `MailHTMLWriter.hasPrivateMetadata`'s to check), XMP included. Other types, and files that don't parse, count
    /// as true.
    static func hasExtras(_ data: Data) -> Bool {
        let b = [UInt8](data)
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return pngExtras(b) }
        if b.starts(with: [0xFF, 0xD8]) { return jpegExtras(b) }
        return gif(b)?.dropped ?? true
    }

    /// The GIF without comment blocks, application blocks other than the loop count (NETSCAPE2.0, ANIMEXTS1.0) and the
    /// colour profile (ICCRGBG1012), unknown extensions or bytes after the end; every frame byte for byte. Nil when it
    /// doesn't parse.
    static func strippedGIF(_ data: Data) -> Data? { gif([UInt8](data)).map { Data($0.out) } }

    /// PNG chunks that hold pixels, colour, size, timing or orientation (Apple's iDOT holds decoding offsets; eXIf is
    /// ImageIO's to check). Anything else, including text (XMP too) and time chunks, is extra.
    static let pngChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP",
                                         "mDCv", "cLLi", "bKGD", "hIST", "pHYs", "sPLT", "acTL", "fcTL", "fdAT", "iDOT", "eXIf"]

    private static func pngExtras(_ b: [UInt8]) -> Bool {
        var i = 8
        while i + 12 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let end = i + 12 + length
            guard end <= b.count else { return true }
            if !pngChunks.contains(type) { return true }
            if type == "IEND" { return end != b.count }
            i = end
        }
        return true
    }

    private static func jpegExtras(_ b: [UInt8]) -> Bool {
        func tagged(_ payload: ArraySlice<UInt8>, _ tags: [String]) -> Bool { tags.contains { payload.starts(with: Array($0.utf8)) } }
        var i = 2
        while i + 1 < b.count {
            guard b[i] == 0xFF else { return true }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }                                        // fill byte
            if marker == 0xD9 { return i + 2 != b.count }                                 // end of image: nothing may follow
            if (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }      // no length
            guard i + 3 < b.count else { return true }
            let end = i + 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
            guard end >= i + 4, end <= b.count else { return true }
            let payload = b[(i + 4)..<end]
            switch marker {
            case 0xE0: if !tagged(payload, ["JFIF\0", "JFXX\0"]) { return true }
            case 0xE1: if !tagged(payload, ["Exif\0\0"]) { return true }                // XMP and the rest are extra
            case 0xE2: if !tagged(payload, ["ICC_PROFILE\0", "MPF\0"]) { return true }
            case 0xED: if !plainPhotoshop(payload) { return true }
            case 0xEE: if !tagged(payload, ["Adobe"]) { return true }
            case 0xE3...0xEC, 0xEF, 0xFE: return true                                   // other application segments, comments
            default: break
            }
            i = end
            if marker == 0xDA {                                                           // scan data, up to the next marker
                while i + 1 < b.count, !(b[i] == 0xFF && b[i + 1] != 0x00 && !(0xD0...0xD7).contains(b[i + 1])) { i += 1 }
            }
        }
        return true
    }

    /// Photoshop's APP13 as AppKit writes it: resolution, an empty IPTC block and that empty block's digest, nothing else.
    private static func plainPhotoshop(_ payload: ArraySlice<UInt8>) -> Bool {
        let p = Array(payload), tag = Array("Photoshop 3.0\0".utf8), resource = Array("8BIM".utf8)
        let emptyDigest: [UInt8] = [0xD4, 0x1D, 0x8C, 0xD9, 0x8F, 0x00, 0xB2, 0x04, 0xE9, 0x80, 0x09, 0x98, 0xEC, 0xF8, 0x42, 0x7E]
        guard p.starts(with: tag) else { return false }
        var i = tag.count
        while i < p.count {
            guard i + 7 <= p.count, p[i..<(i + 4)].elementsEqual(resource) else { return false }
            let id = Int(p[i + 4]) << 8 | Int(p[i + 5])
            let name = Int(p[i + 6]) + 1, sizeAt = i + 6 + name + name % 2           // a Pascal name, padded to even
            guard sizeAt + 4 <= p.count else { return false }
            let size = Int(p[sizeAt]) << 24 | Int(p[sizeAt + 1]) << 16 | Int(p[sizeAt + 2]) << 8 | Int(p[sizeAt + 3])
            let data = sizeAt + 4, next = data + size + size % 2
            guard next <= p.count else { return false }
            switch id {
            case 0x03ED: break                                                            // resolution
            case 0x0404: guard size == 0 else { return false }                            // IPTC, empty
            case 0x0425: guard p[data..<(data + size)].elementsEqual(emptyDigest) else { return false }
            default: return false
            }
            i = next
        }
        return true
    }

    private static func gif(_ b: [UInt8]) -> (out: [UInt8], dropped: Bool)? {
        guard b.count >= 13, b.starts(with: Array("GIF87a".utf8)) || b.starts(with: Array("GIF89a".utf8)) else { return nil }
        func table(_ packed: UInt8) -> Int { packed & 0x80 != 0 ? 3 << (Int(packed & 7) + 1) : 0 }
        func blocksEnd(_ from: Int) -> Int? {                                             // the index after the terminator
            var j = from
            while j < b.count { if b[j] == 0 { return j + 1 }; j += Int(b[j]) + 1 }
            return nil
        }
        var i = 13 + table(b[10])
        guard i <= b.count else { return nil }
        var out = Array(b[0..<i]), dropped = false
        while i < b.count {
            switch b[i] {
            case 0x3B:
                out.append(0x3B)
                return (out, dropped || i + 1 != b.count)
            case 0x21:
                guard i + 2 < b.count, let end = blocksEnd(i + 2) else { return nil }
                var keep = b[i + 1] == 0xF9 || b[i + 1] == 0x01                              // frame timing, plain text
                if b[i + 1] == 0xFF, b[i + 2] == 11, i + 14 <= b.count {
                    keep = ["NETSCAPE2.0", "ANIMEXTS1.0", "ICCRGBG1012"].contains(String(decoding: b[(i + 3)..<(i + 14)], as: UTF8.self))
                }
                if keep { out += b[i..<end] } else { dropped = true }
                i = end
            case 0x2C:
                guard i + 10 <= b.count else { return nil }
                let codeSize = i + 10 + table(b[i + 9])
                guard codeSize < b.count, let end = blocksEnd(codeSize + 1) else { return nil }
                out += b[i..<end]
                i = end
            default:
                return nil
            }
        }
        return nil
    }
}
