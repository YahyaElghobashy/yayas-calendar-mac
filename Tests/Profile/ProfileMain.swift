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
        // Yaya's Murmur's release names (D-046): its own contract, so pinned here as well.
        "murmurBundleId": "com.yahyaelghobashy.yayasmurmur",
        "murmurScheme": "yayamurmur",
        "murmurDataRoot": "Library/Application Support/YayasMurmur",
        // Yaya's Mail Helper's release names (D-050): its own contract, so pinned here as well.
        "mailHelperBundleId": "com.yahyaelghobashy.yayasmailhelper",
        "mailHelperScheme": "yayamail",
        "mailHelperDataRoot": "Library/Application Support/YayasMailHelper",
        // Model Atlas's release names (D-054): its own contract, so pinned here as well.
        "modelAtlasId": "com.yahyaelghobashy.modelatlas",
        "modelAtlasDataRoot": "Library/Application Support/ModelAtlas",
    ]

    static var table: [(String, String)] {
        [("name", Profile.name), ("bundleId", Profile.bundleId), ("widgetBundleId", Profile.widgetBundleId),
         ("displayName", Profile.displayName), ("urlScheme", Profile.urlScheme), ("dataRoot", Profile.dataRoot),
         ("suiteHandoffDir", Profile.suiteHandoffDir), ("keychainOAuth", Profile.keychainOAuth),
         ("keychainClient", Profile.keychainClient), ("keychainLinkKey", Profile.keychainLinkKey),
         ("widgetEntitlements", Profile.widgetEntitlements), ("murmurBundleId", Profile.murmurBundleId),
         ("murmurScheme", Profile.murmurScheme), ("murmurDataRoot", Profile.murmurDataRoot),
         ("mailHelperBundleId", Profile.mailHelperBundleId), ("mailHelperScheme", Profile.mailHelperScheme),
         ("mailHelperDataRoot", Profile.mailHelperDataRoot), ("modelAtlasId", Profile.modelAtlasId),
         ("modelAtlasDataRoot", Profile.modelAtlasDataRoot)]
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
        // Yaya's Murmur's release names (D-046): a dev calendar talks to a dev Murmur only.
        let murmur = release["murmurBundleId"]!
        var murmurRest = value
        for devName in [murmur + ".dev.", murmur + ".dev"] { murmurRest = murmurRest.replacingOccurrences(of: devName, with: "§") }
        if murmurRest.contains(murmur) { return true }
        let murmurRoot = release["murmurDataRoot"]!
        if value.replacingOccurrences(of: murmurRoot + "Dev", with: "§").contains(murmurRoot) { return true }
        if value == release["murmurScheme"]! || value.contains(release["murmurScheme"]! + "://") { return true }
        // Yaya's Mail Helper's release names (D-050): a dev calendar talks to a dev helper only.
        let helper = release["mailHelperBundleId"]!
        var helperRest = value
        for devName in [helper + ".dev.", helper + ".dev"] { helperRest = helperRest.replacingOccurrences(of: devName, with: "§") }
        if helperRest.contains(helper) { return true }
        let helperRoot = release["mailHelperDataRoot"]!
        if value.replacingOccurrences(of: helperRoot + "Dev", with: "§").contains(helperRoot) { return true }
        if value == release["mailHelperScheme"]! || value.contains(release["mailHelperScheme"]! + "://") { return true }
        // Model Atlas's release names (D-054): a dev calendar reads a dev feed only.
        let atlas = release["modelAtlasId"]!
        var atlasRest = value
        for devName in [atlas + ".dev.", atlas + ".dev"] { atlasRest = atlasRest.replacingOccurrences(of: devName, with: "§") }
        if atlasRest.contains(atlas) { return true }
        let atlasRoot = release["modelAtlasDataRoot"]!
        if value.replacingOccurrences(of: atlasRoot + "Dev", with: "§").contains(atlasRoot) { return true }
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
        check(Profile.murmurScheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil, "Murmur's scheme is RFC 3986 lowercase")
        check(!Profile.murmurDataRoot.hasPrefix("/") && Profile.murmurDataRoot.hasPrefix("Library/Application Support/"),
              "Murmur's data root is home-relative")
        check(Profile.murmurBundleId != Profile.bundleId && !Profile.murmurBundleId.hasPrefix(Profile.bundleId),
              "Murmur's bundle id is not under this app's")
        check(Profile.mailHelperScheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil,
              "the Mail helper's scheme is RFC 3986 lowercase")
        check(!Profile.mailHelperDataRoot.hasPrefix("/") && Profile.mailHelperDataRoot.hasPrefix("Library/Application Support/"),
              "the Mail helper's data root is home-relative")
        check(Profile.mailHelperBundleId != Profile.bundleId && !Profile.mailHelperBundleId.hasPrefix(Profile.bundleId),
              "the Mail helper's bundle id is not under this app's")

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
        check(Profile.murmurBundleId == release["murmurBundleId"]! + ".dev", "dev Murmur bundle id = release + .dev")
        check(Profile.murmurScheme == release["murmurScheme"]! + "-dev", "dev Murmur scheme = release + -dev")
        check(Profile.murmurDataRoot == release["murmurDataRoot"]! + "Dev", "dev Murmur data root = release + Dev")
        check(Profile.mailHelperBundleId == release["mailHelperBundleId"]! + ".dev", "dev Mail helper bundle id = release + .dev")
        check(Profile.mailHelperScheme == release["mailHelperScheme"]! + "-dev", "dev Mail helper scheme = release + -dev")
        check(Profile.mailHelperDataRoot == release["mailHelperDataRoot"]! + "Dev", "dev Mail helper data root = release + Dev")
        check(Profile.modelAtlasId == release["modelAtlasId"]! + ".dev", "dev Model Atlas id = release + .dev")
        check(Profile.modelAtlasDataRoot == release["modelAtlasDataRoot"]! + "Dev", "dev Model Atlas data root = release + Dev")
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
