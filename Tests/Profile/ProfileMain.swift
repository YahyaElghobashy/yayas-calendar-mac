import Foundation

/// The identifier table's own test (D-034), compiled twice by Tests/Profile/run.sh: once as the release
/// profile, once with -D YC_PROFILE_DEV. `--print` lists the table as `key=value` lines so run.sh can
/// compare it with build.sh's reading of Profile.swift.
@main
enum ProfileMain {
    /// The release identifiers, pinned (D-001, D-027: never renamed). Renaming one orphans Keychain items, placed
    /// widgets, the designated requirement and an installer's handoff folder, so it must be a deliberate edit here too.
    static let release: [String: String] = [
        "name": "release",
        "bundleId": "com.yahyaelghobashy.yayascalendar",
        "widgetBundleId": "com.yahyaelghobashy.yayascalendar.widget",
        "displayName": "Yaya's Calendar",
        "urlScheme": "yayacal",
        "dataRoot": "Library/Application Support/YayasCalendar",
        "suiteHandoffDir": "Library/Application Support/YayaSuite/handoff",
        "keychainOAuth": "com.yahyaelghobashy.yayascalendar.oauth",
        "keychainClient": "com.yahyaelghobashy.yayascalendar.client",
        "keychainLinkKey": "com.yahyaelghobashy.yayascalendar.linkkey",
        "widgetEntitlements": "Resources/Widget.entitlements",
    ]

    static var table: [(String, String)] {
        [("name", Profile.name), ("bundleId", Profile.bundleId), ("widgetBundleId", Profile.widgetBundleId),
         ("displayName", Profile.displayName), ("urlScheme", Profile.urlScheme), ("dataRoot", Profile.dataRoot),
         ("suiteHandoffDir", Profile.suiteHandoffDir), ("keychainOAuth", Profile.keychainOAuth),
         ("keychainClient", Profile.keychainClient), ("keychainLinkKey", Profile.keychainLinkKey),
         ("widgetEntitlements", Profile.widgetEntitlements)]
    }

    /// Every string the uninstaller would act on.
    static var uninstallNames: [String] {
        Profile.Uninstall.keychainServices + Profile.Uninstall.systemFolders
            + [Profile.Uninstall.dataRoot, Profile.Uninstall.defaultsDomain, Profile.Uninstall.widgetContainer,
               Profile.Uninstall.suiteHandoffMarker]
    }

    /// True when `value` names something of the release app: its bundle id namespace (anything not under
    /// `….dev`), its scheme, its data folder or the installer handoff folder.
    static func reachesRelease(_ value: String) -> Bool {
        let base = release["bundleId"]!
        var rest = value
        for devName in [base + ".dev.", base + ".dev"] { rest = rest.replacingOccurrences(of: devName, with: "§") }
        if rest.contains(base) { return true }
        let root = release["dataRoot"]!
        if value.replacingOccurrences(of: root + "Dev", with: "§").contains(root) { return true }
        if value.contains(release["suiteHandoffDir"]!) || value.contains("Application Support/YayaSuite") { return true }
        if value == release["urlScheme"]! || value.contains(release["urlScheme"]! + "://") { return true }
        return false
    }

    static func main() {
        if CommandLine.arguments.contains("--print") {
            for (key, value) in table { print("\(key)=\(value)") }
            exit(0)
        }
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ what: String) {
            if ok { passed += 1 } else { failed += 1; print("  ✗ \(what)") }
        }
        print("▸ Profile (\(Profile.name))")

        // Both profiles: the derivation rules every caller relies on.
        check(Profile.widgetBundleId == Profile.bundleId + ".widget", "widget id = <bundle id>.widget (extensions nest under the app)")
        check(Profile.keychainOAuth == Profile.bundleId + ".oauth", "oauth service = <bundle id>.oauth")
        check(Profile.keychainClient == Profile.bundleId + ".client", "client service = <bundle id>.client")
        check(Profile.keychainLinkKey == Profile.bundleId + ".linkkey", "link-key service = <bundle id>.linkkey")
        check(Profile.Uninstall.keychainServices == [Profile.keychainOAuth, Profile.keychainClient, Profile.keychainLinkKey],
              "the uninstall list names all three Keychain services")
        check(Profile.Uninstall.defaultsDomain == Profile.bundleId, "defaults domain = bundle id")
        check(Profile.Uninstall.widgetContainer == "Library/Containers/" + Profile.widgetBundleId, "widget container path")
        check(Profile.Uninstall.suiteHandoffMarker == Profile.suiteHandoffDir + "/yayascalendar.done", "handoff marker")
        check(Profile.scoped("x") == Profile.bundleId + ".x", "scoped names sit under the bundle id")
        check(Profile.dataRootForDisplay == "~/" + Profile.dataRoot, "data folder for display")
        check(!Profile.dataRoot.hasPrefix("/") && Profile.dataRoot.hasPrefix("Library/"), "data root is home-relative")
        check(Profile.urlScheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil, "URL scheme is RFC 3986 lowercase")

        #if YC_PROFILE_DEV
        check(Profile.isDev, "isDev")
        for (key, value) in table where key != "name" {
            check(value != release[key], "dev \(key) differs from release (\(value))")
            check(!reachesRelease(value), "dev \(key) reaches no release identifier (\(value))")
        }
        for value in uninstallNames { check(!reachesRelease(value), "dev uninstall entry stays in the dev namespace (\(value))") }
        check(Profile.bundleId == release["bundleId"]! + ".dev", "dev bundle id = release + .dev")
        check(Profile.dataRoot == release["dataRoot"]! + "Dev", "dev data root = release + Dev")
        check(Profile.suiteHandoffDir.hasPrefix(Profile.dataRoot + "/"), "dev handoff marker stays inside the dev data folder")
        check(Profile.displayName.hasSuffix(" Dev"), "dev display name says Dev")
        check(Profile.widgetEntitlements == "Resources/Widget.dev.entitlements", "dev widget entitlements")
        // The test's own guard must catch the release values.
        for (key, value) in release where key != "name" && key != "displayName" && key != "widgetEntitlements" {
            check(reachesRelease(value), "the guard recognises release \(key)")
        }
        #else
        check(!Profile.isDev, "!isDev")
        for (key, value) in table { check(value == release[key], "release \(key) is pinned (\(value))") }
        #endif

        print("TESTS passed=\(passed) failed=\(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
