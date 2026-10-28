import Foundation

/// Sign-in setup on the data layer: a Google API turned off in the user's project is named on the account
/// (D-038, never a silently skipped calendar), and the Deck export follows its Settings switch (D-039).
enum SetupErrorTests {
    static func run() async {
        disabledParse()
        await disabledCalendarPass()
        deckSetting()
        await deckSwitchOff()
    }

    /// Google's 403 for a turned-off API: `accessNotConfigured` in `errors`, `SERVICE_DISABLED` in `details`.
    static let disabledBody = #"{"error":{"code":403,"message":"Google Calendar API is disabled.","errors":[{"message":"disabled","domain":"usageLimits","reason":"accessNotConfigured"}],"status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","domain":"googleapis.com","metadata":{"service":"calendar-json.googleapis.com"}}]}}"#

    static func disabledParse() {
        let full = GoogleAPIError(response: HTTPResponse(status: 403, headers: [:], body: Data(disabledBody.utf8)))
        expect(full == .forbidden(reason: "accessNotConfigured") && full.isServiceDisabled, "403 accessNotConfigured → service disabled (\(full))")
        let detailsOnly = #"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED"}]}}"#
        let fromDetails = GoogleAPIError(response: HTTPResponse(status: 403, headers: [:], body: Data(detailsOnly.utf8)))
        expect(fromDetails.isServiceDisabled, "SERVICE_DISABLED in details alone counts too")
        let other = GoogleAPIError(response: HTTPResponse(status: 403, headers: [:], body: Data(#"{"error":{"errors":[{"reason":"forbidden"}]}}"#.utf8)))
        expect(!other.isServiceDisabled && other == .forbidden(reason: "forbidden"), "an ordinary 403 is not a disabled API")
        expect(!GoogleAPIError.rateLimited(retryAfter: nil).isServiceDisabled, "rate limits are not a disabled API")
        expect(SyncOutcome(error: full).code == "forbidden_accessNotConfigured", "the pass outcome names the reason")
    }

    /// A calendar pass whose events list answers "API disabled": the pass fails (not a skip) and the
    /// accounts source hears which API; the next good pass clears it.
    static func disabledCalendarPass() async {
        let h = Harness("setup-disabled-api")
        let (orb, _) = h.account("avery@orbitalpickle.example", tag: "ORB", sort: 0)
        h.google.inject("/events", status: 403, body: disabledBody, times: 50)
        let outcome = await h.engine.syncAccount(orb.id, force: true)
        expect(outcome == .failed("forbidden_accessNotConfigured"), "disabled Calendar API fails the pass (\(outcome))")
        expect(h.source.apiReports.value.contains { $0.id == orb.id && $0.api == "calendar" && !$0.available },
               "the accounts source is told the Calendar API is off")
        h.google.clearInjected()
        let again = await h.engine.syncAccount(orb.id, force: true)
        expect(again == .ok, "with the API on again the pass succeeds (\(again))")
        expect(h.source.apiReports.value.last.map { $0.api == "calendar" && $0.available } ?? false,
               "… and the source hears it works again")
    }

    static func deckSetting() {
        expect(DeckExportSetting.isOn(stored: nil, deckInstalled: false) == false, "no Deck, no choice: off")
        expect(DeckExportSetting.isOn(stored: nil, deckInstalled: true), "Deck installed, no choice: on")
        expect(DeckExportSetting.isOn(stored: false, deckInstalled: true) == false, "the user's off wins over Deck")
        expect(DeckExportSetting.isOn(stored: true, deckInstalled: false), "the user's on wins too")
    }

    static func deckSwitchOff() async {
        let clock = TestClock(TestCal.labNow)
        let data = StubNotifyData()
        let orb = N.account("avery@orb.example", tag: "ORB")
        data.people.value = [orb]
        data.rows.value = [N.event("d1", "Next", start: clock.now.addingTimeInterval(3600), accounts: [orb.id])]
        let poster = FakeDeckPoster()
        let deck = DeckExporter(directory: DataTests.folder("deck-switch"), poster: poster)
        let on = Locked(false)
        let c = NotifyCoordinator(data: data, center: FakeNoteCenter(), prefs: MemoryNotifyPrefs(), deck: deck,
                                  deckEnabled: { on.value }, now: clock.closure, calendar: { TestCal.lab },
                                  locale: N.posix, debounce: 0)
        await c.refresh()
        expect(!FileManager.default.fileExists(atPath: deck.fileURL.path) && poster.posts.value == 0,
               "switched off: no meetings file, no ping")
        on.value = true
        await c.refresh()
        expect(FileManager.default.fileExists(atPath: deck.fileURL.path) && poster.posts.value == 1,
               "switched on: the next pass writes it")
    }
}
