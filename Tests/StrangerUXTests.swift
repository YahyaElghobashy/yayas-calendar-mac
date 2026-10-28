import Foundation

/// First-run UX on the shell side: the first-run decision, Keep me running and "Move me to
/// Applications" (D-039), the Mac's 24-hour clock (D-039), the Gregorian widget calendar following the Mac's
/// time zone and the widget VoiceOver words. Pure logic, memory only.
@MainActor
enum StrangerUXTests {
    static func run() {
        firstRun()
        placement()
        clock()
        calendar()
        voiceOver()
    }

    static func firstRun() {
        T.section("First run")
        T.check(OnboardingFlow.opensOnLaunch(accounts: 0, completedAt: nil, suiteRequested: false, storeOpen: true),
                "nothing connected, guide never finished → window and guide open")
        T.check(!OnboardingFlow.opensOnLaunch(accounts: 2, completedAt: nil, suiteRequested: false, storeOpen: true),
                "accounts connected → menu bar only")
        T.check(!OnboardingFlow.opensOnLaunch(accounts: 0, completedAt: Date(), suiteRequested: false, storeOpen: true),
                "guide finished once → never again on its own")
        T.check(!OnboardingFlow.opensOnLaunch(accounts: 0, completedAt: nil, suiteRequested: true, storeOpen: true),
                "an installer's --onboarding opens it itself (no double sheet)")
        T.check(!OnboardingFlow.opensOnLaunch(accounts: 0, completedAt: nil, suiteRequested: false, storeOpen: false),
                "a store that didn't open says so elsewhere")
        var f = OnboardingFacts()
        T.check(!OnboardingFlow.finishes(f), "closed with nothing connected: not finished (opens again)")
        f.accounts = 1
        T.check(OnboardingFlow.finishes(f), "closed with an account: finished")
        T.check(OnboardingStep.notifications.detail.contains(JoinHotkey.display), "the guide mentions ⌃⌥J")
        T.check(OnboardingStep.running.title == "Keep me running", "step 6 is Keep me running")
        T.check(OnboardingStep.google.detail.contains("5 minutes"), "step 1 says how long Google setup takes")
    }

    static func placement() {
        T.section("Move me to Applications")
        let home = "/Users/you"
        let mine = BundleFacts(path: "\(home)/Downloads/Yaya's Calendar.app", version: "20261028.2", signer: "aa")
        T.equal(AppPlacement.decide(current: mine, system: nil, user: nil, home: home), .moveToApplications(replacing: false),
                "/Applications free → move there")
        let olderOurs = BundleFacts(path: "/Applications/Yaya's Calendar.app", version: "20261001.1", signer: "aa")
        T.equal(AppPlacement.decide(current: mine, system: olderOurs, user: nil, home: home), .moveToApplications(replacing: true),
                "an older copy signed the same way may be replaced")
        let theirs = BundleFacts(path: "/Applications/Yaya's Calendar.app", version: "20261001.1", signer: "bb")
        guard case .offerUserApplications(let reason) = AppPlacement.decide(current: mine, system: theirs, user: nil, home: home) else {
            T.check(false, "someone else's copy → offer ~/Applications")
            return
        }
        T.check(reason.contains("signed by someone else"), "… and say why (\(reason))")
        let newer = BundleFacts(path: "/Applications/Yaya's Calendar.app", version: "20261101.1", signer: "aa")
        if case .offerUserApplications(let why) = AppPlacement.decide(current: mine, system: newer, user: nil, home: home) {
            T.check(why.contains("newer"), "a newer copy stays (\(why))")
        } else {
            T.check(false, "a newer copy is never replaced")
        }
        var running = olderOurs
        running.running = true
        if case .offerUserApplications = AppPlacement.decide(current: mine, system: running, user: nil, home: home) {} else {
            T.check(false, "a running copy is never replaced")
        }
        let adHoc = BundleFacts(path: mine.path, version: mine.version, signer: nil)
        if case .offerUserApplications = AppPlacement.decide(current: adHoc, system: olderOurs, user: nil, home: home) {} else {
            T.check(false, "an unsigned build never replaces a signed copy")
        }
        let userNewer = BundleFacts(path: "\(home)/Applications/Yaya's Calendar.app", version: "20261201.1", signer: "aa")
        if case .notNow = AppPlacement.decide(current: mine, system: theirs, user: userNewer, home: home) {} else {
            T.check(false, "both folders taken → Not now only")
        }
        let installed = BundleFacts(path: "\(home)/Applications/Yaya's Calendar.app", version: "1", signer: "aa")
        T.equal(AppPlacement.decide(current: installed, system: theirs, user: nil, home: home), .inApplications,
                "~/Applications counts as Applications")
        T.check(AppPlacement.isNewer("20261102.3", than: "20261101.12"), "build numbers compare")
        T.check(AppPlacement.isNewer("20261102.10", than: "20261102.9"), "the day's counter compares as a number")
        T.check(!AppPlacement.isNewer("1.0", than: "1.0.0"), "equal versions are not newer")
    }

    static func clock() {
        T.section("The 24-hour clock follows the Mac")
        T.check(!WidgetClockDefaults.macUses24Hour(locale: Locale(identifier: "en_US")), "en_US: 12-hour")
        T.check(WidgetClockDefaults.macUses24Hour(locale: Locale(identifier: "en_GB")), "en_GB: 24-hour")
        T.check(WidgetClockDefaults.macUses24Hour(locale: Locale(identifier: "de_DE")), "de_DE: 24-hour")
        let saved = WidgetSnapshot.Style.defaultUse24Hour
        WidgetClockDefaults.refresh(locale: Locale(identifier: "en_GB"))
        T.check(WidgetSnapshot.Style().use24Hour, "an unstyled widget follows the Mac")
        WidgetClockDefaults.refresh(locale: Locale(identifier: "en_US"))
        T.check(!WidgetSnapshot.Style().use24Hour, "… both ways")
        WidgetSnapshot.Style.defaultUse24Hour = saved
        var styled = WidgetSnapshot.Style()
        styled.use24Hour = true
        let data = try? WidgetSnapshot.encoder.encode(styled)
        let back = data.flatMap { try? JSONDecoder().decode(WidgetSnapshot.Style.self, from: $0) }
        T.check(back?.use24Hour == true, "a saved Studio choice still wins")
    }

    static func calendar() {
        T.section("Gregorian widget calendar that follows the Mac")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.firstWeekday = 2
        let newYork = TimeZone(identifier: "America/New_York")!
        let c = WidgetCalendar.system(mac: buddhist, timeZone: newYork)
        T.equal(c.identifier, .gregorian, "a Buddhist Mac still gets Gregorian widget dates")
        T.equal(c.firstWeekday, 2, "… with its first weekday")
        T.equal(c.timeZone.identifier, "America/New_York", "… and its time zone")

        let saved = WidgetCalendar.current
        let center = NotificationCenter()
        WidgetCalendar.stopFollowing()
        WidgetCalendar.followSystemChanges(center: center, queue: nil)
        WidgetCalendar.current = WidgetCalendar.fixed
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        T.equal(WidgetCalendar.current.timeZone.identifier, TimeZone.current.identifier, "a time-zone change rebuilds the calendar")
        WidgetCalendar.current = WidgetCalendar.fixed
        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        T.equal(WidgetCalendar.current.timeZone.identifier, TimeZone.current.identifier, "so does a region change")
        T.equal(WidgetCalendar.current.identifier, .gregorian, "… still Gregorian")
        WidgetCalendar.stopFollowing(center: center)
        WidgetCalendar.current = saved
        WidgetSnapshot.Style.defaultUse24Hour = false   // reset() re-reads the Mac; tests stay on the 12-hour default
    }

    static func voiceOver() {
        T.section("Widget VoiceOver words")
        T.equal(WidgetA11y.previousPage, "Previous page", "pager back")
        T.equal(WidgetA11y.nextPage, "Next page", "pager forward")
        T.equal(WidgetA11y.page(2, of: 3), "Page 2 of 3", "pager position")
        let nov = WidgetCalendar.fixed.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        T.equal(WidgetA11y.month(forward: true, to: nov), "Next month, November", "month arrow names the month")
        T.equal(WidgetA11y.archive("Launch checklist"), "Archive Launch checklist", "archive names the message")
        T.equal(WidgetA11y.markRead(""), "Mark No subject read", "mark read without a subject")
        T.equal(WidgetA11y.starred, "Starred", "star")
        let row = WidgetA11y.mail(sender: "Juniper Vale", subject: "Launch checklist", unread: true, starred: true, when: "9:41 am")
        T.equal(row.label, "Unread, Juniper Vale, Launch checklist", "mail row label")
        T.equal(row.value, "9:41 am, starred", "mail row value")
        T.equal(WidgetA11y.spokenDuration(90 * 60), StatusTitle.spokenDuration(90 * 60), "one spoken-duration rule for app and widget")
        let dir = FixtureAccounts.directory()
        let hub = SnapshotFixtures.events().first { $0.title == "The Comets weekly sync" }!
        let m = hub.widgetMeeting(index: 1, directory: dir)
        T.check(WidgetA11y.meeting(m, now: WidgetSample.fixedNow) == A11yText.meeting(m, now: WidgetSample.fixedNow),
                "the widget row says what the app's rows say")
    }
}
