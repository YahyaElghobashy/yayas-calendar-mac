// Re-encodes images for the repo: decode, colour-match to sRGB, write a PNG with no metadata.
//
// Every image that gets committed or published (brand masters, cast logos, docs assets) goes through
// this first, then `Tools/check-public.sh --images`. The output keeps the pixels and nothing else: no
// text, time, profile, physical-size, provenance or any other ancillary chunk (Tools/lib/CleanPNG.swift).
//
// usage: Tools/make-icons.sh --strip <input> <output.png> [<input> <output.png> …]
//        (or build it yourself: swiftc -parse-as-library Tools/strip-image-meta.swift Tools/lib/CleanPNG.swift)
import Foundation

@main
enum StripImageMeta {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty, args.count % 2 == 0 else {
            FileHandle.standardError.write(Data("usage: strip-image-meta <input> <output.png> [<input> <output.png> …]\n".utf8))
            exit(2)
        }
        var failed = 0
        for i in stride(from: 0, to: args.count, by: 2) {
            let input = URL(fileURLWithPath: args[i]), output = URL(fileURLWithPath: args[i + 1])
            do {
                guard output.pathExtension.lowercased() == "png" else {
                    throw CleanPNG.Failure(description: "\(output.lastPathComponent): the output must be a .png")
                }
                guard input.standardizedFileURL != output.standardizedFileURL else {
                    throw CleanPNG.Failure(description: "\(output.lastPathComponent): write to a new file, never over the input")
                }
                let image = try CleanPNG.read(input)
                try CleanPNG.write(image, to: output)
                let chunks = try CleanPNG.chunkTypes(Data(contentsOf: output))
                // Never print anything read from the input's metadata: only the output's facts.
                print("✓ \(output.lastPathComponent)  \(image.width)×\(image.height)  chunks: \(Set(chunks).sorted().joined(separator: " "))")
            } catch {
                FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
                failed += 1
            }
        }
        exit(failed == 0 ? 0 : 1)
    }
}
