import Foundation

/// The one identifier table (D-034). Every name that ties a build to a place on the Mac lives here: the
/// bundle ids, the display name, the URL scheme, the data folder, the Keychain services and the installer
/// handoff folder, and the names of the two add-ons this profile talks to: Yaya's Murmur (D-046) and Yaya's Mail
/// Helper (D-050). `Paths`, `RouteTable`, `TokenVault`, `OAuthConfig`, `KeychainLinkKeyStore`, the uninstaller, the
/// Murmur link and the Mail helper link read it; nothing else spells these names out.
///
/// Two profiles, chosen at compile time so a binary only ever contains one of them:
/// - release (default): the identifiers every shipped and installed copy uses (D-001, D-027: never renamed).
/// - dev (`-D YC_PROFILE_DEV`, `./build.sh --dev`): a separate app on the same Mac. Its own bundle ids,
///   scheme, data folder and Keychain services, so a dev build never reads or writes the real ones.
///
/// build.sh reads the `static let … = "…"` lines of each branch (Tools/lib/common.zsh, `yc_profile`),
/// so keep every table entry on one line as a plain string literal. Tests/Profile proves the two
/// readings agree and that no release identifier is reachable from the dev table.
enum Profile {
    #if YC_PROFILE_DEV
    static let name = "dev"
    static let bundleId = "com.yahyaelghobashy.yayascalendar.dev"
    static let widgetBundleId = "com.yahyaelghobashy.yayascalendar.dev.widget"
    static let displayName = "Yaya's Calendar Dev"
    static let urlScheme = "yayacal-dev"
    /// Relative to the user's real home.
    static let dataRoot = "Library/Application Support/YayasCalendarDev"
    /// Where `--onboarding` drops its "done" marker. Dev keeps it inside its own folder: the release
    /// handoff folder belongs to the installer that reads it.
    static let suiteHandoffDir = "Library/Application Support/YayasCalendarDev/suite-handoff"
    static let keychainOAuth = "com.yahyaelghobashy.yayascalendar.dev.oauth"
    static let keychainClient = "com.yahyaelghobashy.yayascalendar.dev.client"
    static let keychainLinkKey = "com.yahyaelghobashy.yayascalendar.dev.linkkey"
    /// The widget's sandbox entitlements (its one exception is `<dataRoot>/widget/`).
    static let widgetEntitlements = "Resources/Widget.dev.entitlements"
    /// Yaya's Murmur, the add-on notetaker on the same Mac (D-046): the app this profile talks to. A dev calendar only
    /// ever finds and reads a dev Murmur, so it never sees a real Murmur's marks.
    static let murmurBundleId = "com.yahyaelghobashy.yayasmurmur.dev"
    static let murmurScheme = "yayamurmur-dev"
    /// Relative to the user's real home. Read only: the calendar never writes there.
    static let murmurDataRoot = "Library/Application Support/YayasMurmurDev"
    /// Yaya's Mail Helper, the add-on that sorts mail on the owner's own server (D-050): the same rule as Murmur's, so
    /// a dev calendar only ever finds a dev helper, reads its files and writes commands for it.
    static let mailHelperBundleId = "com.yahyaelghobashy.yayasmailhelper.dev"
    static let mailHelperScheme = "yayamail-dev"
    /// Relative to the user's real home. Read only: the calendar never writes there (it deletes the answers it read).
    static let mailHelperDataRoot = "Library/Application Support/YayasMailHelperDev"
    #else
    static let name = "release"
    static let bundleId = "com.yahyaelghobashy.yayascalendar"
    static let widgetBundleId = "com.yahyaelghobashy.yayascalendar.widget"
    static let displayName = "Yaya's Calendar"
    static let urlScheme = "yayacal"
    /// Relative to the user's real home.
    static let dataRoot = "Library/Application Support/YayasCalendar"
    /// Where `--onboarding` drops its "done" marker for an installer (docs/CONTRACTS.md, installer flags).
    static let suiteHandoffDir = "Library/Application Support/YayaSuite/handoff"
    static let keychainOAuth = "com.yahyaelghobashy.yayascalendar.oauth"
    static let keychainClient = "com.yahyaelghobashy.yayascalendar.client"
    static let keychainLinkKey = "com.yahyaelghobashy.yayascalendar.linkkey"
    /// The widget's sandbox entitlements (its one exception is `<dataRoot>/widget/`).
    static let widgetEntitlements = "Resources/Widget.entitlements"
    /// Yaya's Murmur, the add-on notetaker on the same Mac (D-046): its bundle id, URL scheme and data folder
    /// (its docs/CONTRACTS.md, "Calendar link").
    static let murmurBundleId = "com.yahyaelghobashy.yayasmurmur"
    static let murmurScheme = "yayamurmur"
    /// Relative to the user's real home. Read only: the calendar never writes there.
    static let murmurDataRoot = "Library/Application Support/YayasMurmur"
    /// Yaya's Mail Helper, the add-on that sorts mail on the owner's own server (D-050): its bundle id, URL scheme and
    /// data folder (its docs/CONTRACT.md, "Helper ⇄ Calendar").
    static let mailHelperBundleId = "com.yahyaelghobashy.yayasmailhelper"
    static let mailHelperScheme = "yayamail"
    /// Relative to the user's real home. Read only: the calendar never writes there (it deletes the answers it read).
    static let mailHelperDataRoot = "Library/Application Support/YayasMailHelper"
    #endif

    static var isDev: Bool { name == "dev" }

    /// The data folder as people read it ("~/Library/Application Support/…").
    static var dataRootForDisplay: String { "~/" + dataRoot }

    /// A name scoped to this profile (notification names, queue labels): `<bundleId>.<suffix>`.
    static func scoped(_ suffix: String) -> String { bundleId + "." + suffix }

    /// Everything this profile may leave on a Mac, as data for "Remove everything", `--purge` and
    /// `--purge --dry-run` (D-037). Paths are relative to the user's real home; the uninstaller decides
    /// what it can remove and reports the rest. Names only: never a value.
    enum Uninstall {
        /// Generic-password services in the login keychain (refresh tokens, the Google client, the
        /// widget-link key).
        static var keychainServices: [String] { [keychainOAuth, keychainClient, keychainLinkKey] }
        /// The data folder, including the widget's shared `widget/` folder, logs and the Deck export.
        static var dataRoot: String { Profile.dataRoot }
        /// Mail's folders inside the data folder (D-043, D-044): the attachment cache, unsent mail, the
        /// composer's staged files, the copies Open hands to other apps. Removed with it; the dry run names them.
        static var dataRootMailFolders: [String] { ["attachments", "outbox", "compose", "Mail Downloads"] }
        /// The UserDefaults domain (`defaults delete <domain>`).
        static var defaultsDomain: String { bundleId }
        /// The widget extension's sandbox container (see D-037 on the "access data from other apps" prompt).
        static var widgetContainer: String { "Library/Containers/" + widgetBundleId }
        /// The marker `--onboarding` writes for an installer.
        static var suiteHandoffMarker: String { suiteHandoffDir + "/yayascalendar.done" }
        /// Folders macOS and WebKit create for this bundle id on first use (caches, the reader's WebKit
        /// rule store, saved window state). Any of them may be missing.
        static var systemFolders: [String] {
            ["Library/Caches/" + bundleId,
             "Library/WebKit/" + bundleId,
             "Library/HTTPStorages/" + bundleId,
             "Library/Saved Application State/" + bundleId + ".savedState"]
        }
    }
}
