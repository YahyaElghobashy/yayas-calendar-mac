import Foundation

// Model Atlas's weekly report on the Daily Digest widget (D-054), free of AppKit so the test binary checks it. Model
// Atlas is the owner's own inventory of the AI models on their machines; it writes one small file and pings, and the
// calendar only reads it (its docs/DIGEST-CONTRACT.md). The same reader rules as Yaya's Mail Helper's files (D-050):
// `O_NOFOLLOW`, `fstat` (a regular file of this user, here at most 64 KiB), `version` 1 only, every field checked on its
// own, text cleaned of control and direction characters and capped. A missing file = no box. `ModelAtlasLive` reads it.

enum ModelAtlasFiles {
    static let shareFolder = "share"
    static let digestFile = "digest.json"
    static let fileLimit = 64 * 1024
    /// Posted by Model Atlas (DistributedNotificationCenter, no object, no userInfo) after it rewrote the file.
    static var changedNotification: String { Profile.modelAtlasId + ".changed" }
    /// UserDefaults: the report (or scan) the person last opened from the widget; the box is "new" until then.
    static let seenKey = "modelatlas.seen"
}

/// The parsed feed.
struct ModelAtlasDigest: Equatable {
    var report: String?
    var scan: String
    var lines: [WidgetSnapshot.Atlas.Line]
    var alerts: [String]
    var models: Int?
    /// The files a tap may open, as the feed names them (checked again by `ModelAtlasOpen` before anything opens).
    var atlasPath: String?
    var reportPath: String?

    /// What "opened once" remembers: the report's date, else the scan.
    var seenKey: String { report ?? scan }
}

enum ModelAtlasParse {
    static func digest(_ data: Data?) -> MailHelperRead<ModelAtlasDigest> {
        guard let data else { return .missing }
        guard data.count <= ModelAtlasFiles.fileLimit, let j = MailHelperJSON.parse(data), j.object != nil,
              let v = j["version"]?.int else { return .unreadable }
        if v > 1 { return .newer }
        guard v == 1 else { return .unreadable }
        let report = j["report"]?.string.flatMap { DayName.parseDay($0) != nil ? $0 : nil }
        let lines: [WidgetSnapshot.Atlas.Line] = (j["lines"]?.array ?? []).compactMap { l in
            guard let text = MailHelperPlain.clean(l["text"]?.string, WidgetSnapshot.Digest.maxText), !text.isEmpty else { return nil }
            let kind = MailHelperPlain.clean(l["kind"]?.string, 24)?.lowercased() ?? ""
            return WidgetSnapshot.Atlas.Line(text: text, kind: kind)
        }
        let alerts = (j["alerts"]?.array ?? []).compactMap { MailHelperPlain.clean($0.string, WidgetSnapshot.Digest.maxText) }
            .filter { !$0.isEmpty }
        let models = j["counts"]?["models"]?.int.flatMap { $0 >= 0 ? $0 : nil }
        return .ready(ModelAtlasDigest(
            report: report, scan: MailHelperPlain.clean(j["scan"]?.string, 40) ?? "",
            lines: Array(lines.prefix(WidgetSnapshot.Atlas.maxLines)),
            alerts: Array(alerts.prefix(WidgetSnapshot.Atlas.maxAlerts)), models: models,
            atlasPath: j["open"]?["atlas"]?.string, reportPath: j["open"]?["report"]?.string))
    }

    /// The widget's box: the feed plus whether this report was opened yet.
    static func snapshot(_ d: ModelAtlasDigest, seen: String?) -> WidgetSnapshot.Atlas {
        WidgetSnapshot.Atlas(report: d.report, lines: d.lines, alerts: d.alerts, models: d.models,
                             fresh: seen == d.seenKey ? nil : true)
    }
}

/// Which file a tap may open. Only Markdown files of Model Atlas's own shape, inside the person's home: the atlas
/// (`…/Model Atlas/ATLAS.md`) or a weekly report (`…/Model Atlas/landscape/YYYY-MM-DD.md`). Anything else the feed names
/// is ignored, so the file can't make the calendar open something else. `ModelAtlasLive` also checks the file itself.
enum ModelAtlasOpen {
    static func allowed(_ path: String?, home: String) -> String? {
        guard let path, path.hasPrefix("/"), path.count <= 1024, !path.contains("/../"), !path.contains("/./"),
              !path.hasSuffix("/.."), !path.contains("//") else { return nil }
        let homeDir = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(homeDir) else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        let name = parts[parts.count - 1], parent = parts[parts.count - 2]
        if name == "ATLAS.md", parent == "Model Atlas" { return path }
        if parent == "landscape", parts[parts.count - 3] == "Model Atlas", name.hasSuffix(".md"),
           DayName.parseDay(String(name.dropLast(3))) != nil { return path }
        return nil
    }

    /// The report when there is one (and it may be opened), else the atlas.
    static func target(_ d: ModelAtlasDigest, home: String) -> String? {
        allowed(d.reportPath, home: home) ?? allowed(d.atlasPath, home: home)
    }
}
