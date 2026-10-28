import Foundation

/// Mail defaults (D-029): mail is on with no labs gate, "Ask before sending to other people" leaves
/// `labs.*` for `mail.askBeforeSendingOutside` with a one-time migration, the mail-off copy promises nothing
/// for later, and rich mail's folders sit in the profile's data folder. Memory only: no user defaults.
@MainActor
enum MailDefaultsTests {
    static func run() {
        migration()
        defaults()
        copy()
        folders()
    }

    /// A dictionary standing in for UserDefaults.
    final class MemoryKeyValues: SettingsKeyValues {
        var values: [String: Any] = [:]
        func object(forKey defaultName: String) -> Any? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
        func removeObject(forKey defaultName: String) { values[defaultName] = nil }
        var keys: [String] { values.keys.sorted() }
    }

    static func migration() {
        T.section("Mail settings migration (D-029)")
        let ask = MailSettingsMigration.askKey, oldAsk = MailSettingsMigration.oldAskKey, oldMail = MailSettingsMigration.oldMailKey
        T.equal(ask, "mail.askBeforeSendingOutside", "the new key")
        T.check(!ask.hasPrefix("labs."), "the new key is out of labs.*")

        for old in [true, false] {
            let kv = MemoryKeyValues()
            kv.values = [oldAsk: old, oldMail: true, "mail.compose.fontSize": 14]
            T.check(MailSettingsMigration.run(kv), "old \(old): the first launch changes something")
            T.equal(kv.values[ask] as? Bool, old, "old \(old) → new \(old)")
            T.equal(MailSettingsMigration.askBeforeSendingOutside(in: kv), old, "old \(old): the switch reads \(old)")
            T.check(kv.object(forKey: oldAsk) == nil, "old \(old): labs.safeSend deleted")
            T.check(kv.object(forKey: oldMail) == nil, "old \(old): labs.mail deleted")
            T.equal(kv.values["mail.compose.fontSize"] as? Int, 14, "old \(old): other settings untouched")
            let before = kv.keys
            T.check(!MailSettingsMigration.run(kv), "old \(old): a second launch changes nothing")
            T.equal(kv.keys, before, "old \(old): same keys after the second launch")
            T.equal(kv.values[ask] as? Bool, old, "old \(old): same value after the second launch")
        }

        let absent = MemoryKeyValues()
        T.check(!MailSettingsMigration.run(absent), "absent: nothing to migrate")
        T.check(absent.values.isEmpty, "absent: nothing written (a Mac that never had the setting)")
        T.check(MailSettingsMigration.askBeforeSendingOutside(in: absent), "absent → ON")

        let gateOnly = MemoryKeyValues()
        gateOnly.values = [oldMail: false]
        T.check(MailSettingsMigration.run(gateOnly), "only labs.mail: deleted")
        T.check(gateOnly.values.isEmpty && MailSettingsMigration.askBeforeSendingOutside(in: gateOnly),
                "only labs.mail: nothing else written, the switch reads ON")

        let junk = MemoryKeyValues()
        junk.values = [oldAsk: "maybe"]
        MailSettingsMigration.run(junk)
        T.check(junk.object(forKey: oldAsk) == nil && junk.object(forKey: ask) == nil, "a non-switch old value: deleted, not copied")
        T.check(MailSettingsMigration.askBeforeSendingOutside(in: junk), "a non-switch old value → ON")

        let newOnly = MemoryKeyValues()
        newOnly.values = [ask: false]
        T.check(!MailSettingsMigration.run(newOnly), "already migrated: nothing changes")
        T.equal(MailSettingsMigration.askBeforeSendingOutside(in: newOnly), false, "already migrated: the user's off stays off")

        let latest = MemoryKeyValues()
        latest.values = [ask: true, oldAsk: false]
        MailSettingsMigration.run(latest)
        T.equal(latest.values[ask] as? Bool, false, "an old key written after the new one (a pre-1.0 build ran again) wins once")
        T.check(latest.object(forKey: oldAsk) == nil, "…and is deleted")
    }

    static func defaults() {
        T.section("Mail on by default (D-029)")
        T.check(WidgetStudioModel(kind: WidgetKinds.inbox.kind, store: { EmptyStores.shared }).mailAvailable,
                "Widget Studio: Inbox kinds available by default")
        let calendar = FakeCalendarStore(events: [])
        T.check(PopoverModel(store: { calendar }, actions: { calendar }, mail: { FakeMailStore() }, directory: { FixtureAccounts.directory() },
                             clock: { Date() }, syncedAt: { nil }, use24Hour: { false }).showsInbox,
                "popover: the Inbox tab shows by default")
        T.check(MenuBarSettingsModel(bag: MemoryBag(), state: { .on }, post: {}).modes.contains(.unread),
                "menu bar: the unread count is offered by default")
        let r = "th-milo", k = FixtureLinkKeys.k("th-milo")
        if let route = Route.parse(URL(string: "yayacal://mail/read?r=\(r)&k=\(k)")!) {
            T.equal(RouteDecider.decide(route) { FixtureLinkKeys.verify(r: $0, k: $1) }, .mailRead(r: r), "links: mail links work by default")
        } else {
            T.check(false, "links: the mail/read route parses")
        }
        let settings = SettingsMailModel(prefs: { EmptyStores.shared }, directory: { FixtureAccounts.directory() },
                                         local: MemoryMailLocalStore(), safeSend: { true }, setSafeSend: { _ in })
        T.equal(SettingsMailModel.askTitle, "Ask before sending to other people", "the switch's title (D-023)")
        T.check(settings.askBeforeSending, "the switch shows the stored value")
    }

    static func copy() {
        T.section("Mail copy: nothing promised for later")
        let banned = ["while we test", "for now", "check-in", "next update", "on its way", "arrive", "coming", "labs", "soon", "later"]
        let settings = SettingsMailModel(prefs: { EmptyStores.shared }, directory: { FixtureAccounts.directory() },
                                         local: MemoryMailLocalStore(), safeSend: { true }, setSafeSend: { _ in })
        var strings = MailOffCopy.all + [SettingsMailModel.askTitle, settings.safeSendLine,
                                         SettingsMailModel.correspondentsTitle, SettingsMailModel.correspondentsLine]
        settings.setAskBeforeSending(false)
        strings.append(settings.safeSendLine)
        for s in strings {
            let lower = s.lowercased()
            T.check(!banned.contains { lower.contains($0) }, "no testing or later-version words: \(s)")
        }
        T.check(MailOffCopy.widgetTitle == "Mail is off", "the widget's mail-off title")
    }

    static func folders() {
        T.section("Rich mail's folders are the profile's own")
        let mail = Profile.Uninstall.dataRootMailFolders
        T.check(mail.contains(ComposeStaging.folderName) && mail.contains(AttachmentFiles.downloadsFolderName)
                && mail.contains(Paths.attachments.lastPathComponent) && mail.contains(Paths.outbox.lastPathComponent),
                "Remove everything names every mail folder")
        let root = Paths.root.path
        T.equal(ComposeStaging().folder.deletingLastPathComponent().deletingLastPathComponent().path, root, "compose/ in the data folder")
        T.equal(AttachmentFiles.downloads(root: Paths.root).deletingLastPathComponent().path, root, "Mail Downloads/ in the data folder")
        T.equal(Paths.attachments.deletingLastPathComponent().path, root, "attachments/ in the data folder")
        T.equal(Paths.outbox.deletingLastPathComponent().path, root, "outbox/ in the data folder")
        T.check(root.hasSuffix(Profile.dataRoot), "the data folder is the profile's (\(Profile.name))")
    }
}
