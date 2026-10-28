import Foundation

/// Append-only trace files (the widget's unified log can't be read from a terminal). One line per event,
/// the shape probe scripts parse:
///
///     2026-10-19T10:05:01.234Z 1792404301234 app recv ping probe=p1 at=1792404301234
///
/// Field 1 ISO 8601 (UTC, ms), field 2 epoch ms, field 3 source (`app` / `widget`), then the event and
/// `key=value` pairs. Never log PII: callers pass route names and validated parameters only.
enum Trace {
    static let appCap = 512 * 1024
    static let widgetCap = 256 * 1024

    /// Headless runs (`--render`) point both traces into their own output folder, so a render never
    /// writes the real `logs/app.log` or `widget/trace.log`. Nil = the real files.
    static var folderOverride: URL?

    /// "Remove everything" sets this before it deletes the data folder: a trace written afterwards
    /// would create the folder again.
    nonisolated(unsafe) static var muted = false

    static var appLogURL: URL { folderOverride?.appendingPathComponent("app.log") ?? Paths.appLog }
    static var widgetTraceURL: URL { folderOverride?.appendingPathComponent("trace.log") ?? Paths.widgetTrace }

    static func app(_ event: String, _ fields: KeyValuePairs<String, String> = [:]) {
        append(line(source: "app", event: event, fields: fields), to: appLogURL, cap: appCap)
    }

    static func widget(_ event: String, _ fields: KeyValuePairs<String, String> = [:]) {
        append(line(source: "widget", event: event, fields: fields), to: widgetTraceURL, cap: widgetCap)
    }

    static func millis(_ date: Date = Date()) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func line(source: String, event: String, fields: KeyValuePairs<String, String>, now: Date = Date()) -> String {
        var line = "\(iso.string(from: now)) \(millis(now)) \(source) \(event)"
        for (key, value) in fields { line += " \(key)=\(sanitized(value))" }
        return line + "\n"
    }

    /// One whitespace-free token, at most 80 characters, so `awk` field splitting holds.
    static func sanitized(_ value: String) -> String {
        guard !value.isEmpty else { return "-" }
        return String(value.prefix(80).map { $0.isWhitespace || $0.isNewline ? "_" : $0 })
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// O_APPEND + one write(2): two processes appending short lines never interleave mid-line. Past the
    /// cap the file rolls to `<name>.1` (one generation). Files are 0600; the folder is made if missing
    /// (the sandboxed widget may not be allowed to, which is fine: then it simply doesn't trace).
    private static func append(_ line: String, to url: URL, cap: Int) {
        guard !muted else { return }
        let path = url.path
        var info = stat()
        if stat(path, &info) == 0 {
            if info.st_size > cap { _ = rename(path, path + ".1") }
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var bytes = Array(line.utf8)
        _ = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
