// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import Foundation

/// Finds a developer's gitignored client file (`Config/oauth.local.json`, shaped like
/// `Config/oauth.local.example.json`; CONTRIBUTING.md) so Provider Setup can offer "Import from developer file"
/// when the app runs from inside a checkout. The file only ever seeds the Keychain; the app never reads the client
/// from it at runtime. A copy outside a checkout finds nothing and hides the button.
enum DevClientFile {
    static let relativePath = "Config/oauth.local.json"
    static let environmentKey = "YAYACAL_DEV_OAUTH"
    /// How far up the tree to look (a worktree sits two levels below the repository root).
    static let maxDepth = 12

    /// `YAYACAL_DEV_OAUTH` first (a file, or a folder to walk up from), then upward from the executable.
    static func locate(environment: [String: String], executable: URL?,
                       fileManager: FileManager = .default) -> URL? {
        var starts: [URL] = []
        if let value = environment[environmentKey], !value.isEmpty {
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue { return url.pathExtension.lowercased() == "json" ? url : nil }
                starts.append(url)
            }
        }
        if let executable { starts.append(executable.deletingLastPathComponent()) }

        for start in starts {
            var folder = start.standardizedFileURL
            for _ in 0..<maxDepth {
                let candidate = folder.appendingPathComponent(relativePath)
                if fileManager.isReadableFile(atPath: candidate.path) { return candidate }
                let parent = folder.deletingLastPathComponent()
                if parent.path == folder.path { break }
                folder = parent
            }
        }
        return nil
    }
}
#endif
