import Foundation

/// Every path the app and the widget share. The widget is sandboxed, so `NSHomeDirectory()` is its
/// container there; `realHome` reads the user's real home from the password database instead.
enum Paths {
    // The identifiers come from the profile table (Profile.swift, D-034).
    static let bundleId = Profile.bundleId
    static let widgetBundleId = Profile.widgetBundleId
    static let urlScheme = Profile.urlScheme

    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/YayasCalendar (0700; the dev profile's YayasCalendarDev). Owned by the app.
    static var root: URL { realHome.appendingPathComponent(Profile.dataRoot, isDirectory: true) }
    static var store: URL { root.appendingPathComponent("store.sqlite") }
    /// The only folder the widget may read (and write its trace into): sandbox temporary exception.
    static var widget: URL { root.appendingPathComponent("widget", isDirectory: true) }
    static var widgetTrace: URL { widget.appendingPathComponent("trace.log") }
    /// Account logos, copied here so the widget can draw them: widget/logos/<account-uuid>.png
    static var logos: URL { widget.appendingPathComponent("logos", isDirectory: true) }
    static var share: URL { root.appendingPathComponent("share", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    static var appLog: URL { logs.appendingPathComponent("app.log") }
    /// Rich mail (D-043, D-044): fetched attachments and mail waiting to go out. The composer's staged files
    /// (`compose/`) and the copies Open hands to other apps (`Mail Downloads/`) sit here too.
    static var attachments: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    static var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    static var suiteHandoff: URL {
        realHome.appendingPathComponent(Profile.suiteHandoffDir, isDirectory: true)
    }
}
