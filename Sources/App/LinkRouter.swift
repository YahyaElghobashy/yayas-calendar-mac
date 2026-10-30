import AppKit

/// Every widget tap arrives here as a `yayacal://` URL (no App Intents, D-004).
///
/// Parsing and the route table live in Shared/Routes.swift; validation, link-key checks and the
/// hide/restore rules in RouteDecisions.swift (both tested). This class performs the actions:
/// - `page` / `day` / `month` / `range` → `Services.widgetInteractions` (the data layer republishes);
/// - `sync` → `Services.calendarActions.syncNow()`; `sync?w=<kind>` (a widget's ↻) → that widget's accounts
///   re-listed in full (and its mail), then that kind republished and reloaded while the link still has
///   the agent active (the hand-back waits for it, at most `RefreshPolicy.handBackCap`); a repeat for the
///   same kind within 5 s is ignored (`RefreshDebounce`);
/// - `join` → the event's join URL, re-checked against the allowlist, opened in the browser/app;
/// - `rsvp` → `Services.calendarActions.rsvp`;
/// - `open/event` → Event Peek, `open/day` → Day Peek (at the pointer);
/// - `mail/read` / `mail/archive` / `mail/undo` / `mail/star` → `Services.mailActions` (archive tokens go in
///   MailUndoBook for 30 s), then `flushChanged()` again once the change is made; `open/message` → Mail Peek;
/// - every batch → `flushChanged()` 1.5 s later (coalesced): the tapped kind reloads at once through its
///   publish, other kinds wait so their renders don't compete with it (D-019).
/// Quiet batches hide the agent again when the link activated it and hand the front back to the app
/// the user was in — right after the work when a warm agent was just activated
/// (`HandBackPolicy`), else 250 ms later; a Peek hands the front back too but stays up; a Join that
/// opened the meeting leaves the front to the meeting app.
@MainActor
final class LinkRouter {
    var lastActivation = Date.distantPast
    private let launchedAt = Date()
    private let openMain: (AppSection?) -> Void
    private let front: FrontAppTracker
    private let peek: PeekController
    /// Other kinds' pending reloads wait this long after a tap (the tapped kind's render goes first).
    static let flushDelay: TimeInterval = 1.5
    private let deferredFlush: DeferredFlush
    private var refreshDebounce = RefreshDebounce()
    /// Kinds whose ↻ arrived in the batch being handled, and whether one was a debounced repeat.
    private var batchRefreshes: [String] = []
    private var batchDebounced = false
    /// Refreshes still holding the hand-back (a double tap's second batch leaves the front to them).
    private var refreshesInFlight = 0

    init(openMain: @escaping (AppSection?) -> Void, front: FrontAppTracker = .shared, peek: PeekController = .shared) {
        self.openMain = openMain
        deferredFlush = DeferredFlush(delay: Self.flushDelay) { Services.widgetInteractions.flushChanged() }
        self.front = front
        self.peek = peek
    }

    func handle(_ urls: [URL]) {
        let receivedAt = Trace.millis()
        let started = DispatchTime.now().uptimeNanoseconds
        let activeAtReceipt = NSApp.isActive
        let sinceActivationAtReceipt = Date().timeIntervalSince(lastActivation)
        let coldAtReceipt = Date().timeIntervalSince(launchedAt) < 4
        batchRefreshes = []
        batchDebounced = false
        var outcomes: [FrontRestorePolicy.Outcome] = []
        for url in urls {
            guard let route = Route.parse(url) else {
                Trace.app("recv-rejected", ["at": "\(receivedAt)"])
                continue
            }
            let action = RouteDecider.decide(route) { r, k in Services.widgetInteractions.verify(r: r, k: k) }
            outcomes.append(perform(action, route: route, at: receivedAt))
        }
        guard !outcomes.isEmpty else { return }
        scheduleFlush()
        let workMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let refreshes = batchRefreshes
        batchRefreshes = []

        var handBack = "-"
        switch FrontRestorePolicy.follow(outcomes) {
        case .stay:
            if !refreshes.isEmpty { refresh(refreshes, at: receivedAt, then: nil) }
        case .hideAndRestore where !refreshes.isEmpty:
            // Stay active until the tapped widget's reload is asked (free and unthrottled while active);
            // the hand-back decision is the one this batch would have made on arrival.
            handBack = "after-refresh"
            refresh(refreshes, at: receivedAt) { [weak self] in
                self?.handBackAfterQuiet(activeAtReceipt: activeAtReceipt, sinceActivation: sinceActivationAtReceipt,
                                         cold: coldAtReceipt)
            }
        case .hideAndRestore where batchDebounced && refreshesInFlight > 0:
            // A double tap on ↻: the first refresh hands the front back when its reload is asked.
            handBack = "refresh-pending"
        case .hideAndRestore:
            handBack = handBackAfterQuiet(activeAtReceipt: activeAtReceipt)
        case .restoreKeepPeek:
            if !refreshes.isEmpty { refresh(refreshes, at: receivedAt, then: nil) }
            restoreAfterPeek(activeAtReceipt: activeAtReceipt)
            handBack = "peek"
        }
        Trace.app("tap-done", ["work-ms": String(format: "%.1f", workMs), "hand-back": handBack, "at": "\(receivedAt)"])
    }

    /// `flushChanged()` once taps settle (each new batch pushes it back).
    private func scheduleFlush() {
        deferredFlush.schedule()
    }

    /// The app is quitting: a flush still waiting for its delay runs now (D-019).
    func flushNow() {
        if deferredFlush.runPending() { Trace.app("flush", ["when": "quit"]) }
    }

    /// A widget's ↻: sync that widget's accounts off the main thread, then (on main, while the agent is
    /// still active) republish and reload the tapped kinds and hand the front back (`then`). A sync slower
    /// than `RefreshPolicy.handBackCap` hands back at the cap and reloads again when it finishes. Other
    /// kinds the sync changed go out with the deferred flush afterwards.
    private func refresh(_ kinds: [String], at receivedAt: Int64, then handBack: (@MainActor () -> Void)?) {
        let started = DispatchTime.now().uptimeNanoseconds
        let work = Task.detached { await DataServices.refreshWidgets(kinds) }
        refreshesInFlight += 1
        Task { @MainActor [weak self] in
            let report = await TimeBox.wait(RefreshPolicy.handBackCap, for: work)
            DataServices.finishRefresh(kinds)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let result: String
            switch report {
            case .none: result = "timeout"
            case .some(.none): result = "no-engine"
            case .some(.some(let done)): result = done.traceResult
            }
            Trace.app("refresh-done", [
                "w": kinds.joined(separator: ","), "ms": String(format: "%.0f", ms), "result": result, "at": "\(receivedAt)",
            ])
            handBack?()
            self?.refreshesInFlight -= 1
            if report == nil {
                let late = await work.value
                DataServices.finishRefresh(kinds)
                Trace.app("refresh-done", ["w": kinds.joined(separator: ","), "result": late?.traceResult ?? "no-engine",
                                           "late": "1", "at": "\(receivedAt)"])
            }
            self?.scheduleFlush()
        }
    }

    /// A quiet batch is done: hand the front back now (warm agent the link just activated) or check in
    /// 250 ms. Returns how, for the trace. `sinceActivation`: as of the batch's arrival (a refresh hands
    /// back seconds later, when "just activated" no longer reads true of the clock).
    @discardableResult
    private func handBackAfterQuiet(activeAtReceipt: Bool, sinceActivation: TimeInterval? = nil, cold: Bool? = nil) -> String {
        let cold = cold ?? (Date().timeIntervalSince(launchedAt) < 4)
        let since = sinceActivation ?? Date().timeIntervalSince(lastActivation)
        let when = HandBackPolicy.when(isActive: NSApp.isActive, cold: cold, activeAtReceipt: activeAtReceipt,
                                       sinceActivation: since)
        guard when == .now else {
            hideIfLinkActivated(activeAtReceipt: activeAtReceipt, sinceActivation: sinceActivation, cold: cold)
            return "later"
        }
        // The tapped kind's reload is already with WidgetKit (WidgetKitReloader calls it on the spot from
        // the main thread), so it was asked while active; hand the front back, then hide our windows.
        let restored = front.restore(reason: "quiet")
        NSApp.hide(nil)
        Trace.app("hide-check", ["hid": "1", "activeAtRecv": activeAtReceipt ? "1" : "0", "cold": "0", "when": "now"])
        return restored == nil ? "hide" : "now"
    }

    /// Performs one action; returns what it left on screen.
    private func perform(_ action: RouteAction, route: Route, at: Int64) -> FrontRestorePolicy.Outcome {
        let ms = "\(at)"
        switch action {
        case .ping(let probe):
            Trace.app("recv ping", ["probe": probe, "at": ms])
            return .quiet
        case .openApp(let section):
            Trace.app("recv open/app", ["section": section?.rawValue ?? "-", "at": ms])
            openMain(section)
            return .window
        case .openDigest(let part):
            // The Daily Digest widget (D-053): the Digest tab, scrolled to the tapped section.
            Trace.app("recv open/app", ["section": AppSection.mailHelper.rawValue, "tab": "digest", "part": part == nil ? "-" : "1",
                                        "at": ms])
            ShellModel.shared.mailHelper.showDigest(part: part)
            openMain(.mailHelper)
            return .window
        case .reauth:
            // The account card's own "Sign in again" lives in Accounts.
            Trace.app("recv reauth", ["at": ms])
            openMain(.accounts)
            return .window
        case .page(let kind, let family, let to):
            Trace.app("recv page", ["w": kind, "fam": family, "to": "\(to)", "at": ms])
            Services.widgetInteractions.page(kind: kind, family: family, to: to)
            return .quiet
        case .selectDay(let kind, let day):
            Trace.app("recv day", ["w": kind, "d": day, "at": ms])
            Services.widgetInteractions.selectDay(kind: kind, day: day)
            return .quiet
        case .showMonth(let kind, let month):
            Trace.app("recv month", ["w": kind, "to": month, "at": ms])
            Services.widgetInteractions.showMonth(kind: kind, month: month)
            return .quiet
        case .setRange(let kind, let days):
            Trace.app("recv range", ["w": kind, "v": "\(days)", "at": ms])
            Services.widgetInteractions.setRange(kind: kind, days: days)
            return .quiet
        case .sync(nil):
            Trace.app("recv sync", ["at": ms])
            Task { await Services.calendarActions.syncNow() }
            return .quiet
        case .sync(let kind?):
            guard refreshDebounce.admit(kind, at: Date()) else {
                Trace.app("recv sync", ["w": kind, "debounced": "1", "at": ms])
                batchDebounced = true
                return .quiet
            }
            Trace.app("recv sync", ["w": kind, "at": ms])
            // The Daily Digest (D-053) shows the helper's files: read them again before its republish.
            if kind == WidgetKinds.digest.kind { MailHelperLive.refreshForWidget() }
            if !batchRefreshes.contains(kind) { batchRefreshes.append(kind) }
            return .quiet
        case .join(let r):
            return join(r: r, at: ms) ? .handedOff : .quiet
        case .record(let r):
            return record(r: r, at: ms)
        case .liveHelper(let r):
            return liveHelper(r: r, at: ms)
        case .rsvp(let r, let response):
            Trace.app("recv rsvp", ["v": response.rawValue, "at": ms])
            Task {
                do {
                    try await Services.calendarActions.rsvp(r: r, response: response)
                    Trace.app("rsvp", ["result": "ok", "v": response.rawValue])
                } catch {
                    Trace.app("rsvp", ["result": "error", "v": response.rawValue])
                }
            }
            return .quiet
        case .openEvent(let r):
            Trace.app("recv open/event", ["at": ms])
            return peek.showEvent(r: r) ? .peek : .nothing
        case .openDay(let kind, let day):
            Trace.app("recv open/day", ["w": kind, "d": day, "at": ms])
            guard let date = DayName.parseDay(day) else { return .nothing }
            return peek.showDay(kind: kind, day: date) ? .peek : .nothing
        case .mailRead(let r):
            Trace.app("recv mail/read", ["at": ms])
            mail("read") { try await Services.mailActions.markRead(r: r, true) }
            return .quiet
        case .mailArchive(let r):
            Trace.app("recv mail/archive", ["at": ms])
            mail("archive") {
                let token = try await Services.mailActions.archive(r: r)
                MailUndoBook.shared.record(r: r, token: token, kind: .archive, at: Date())
            }
            return .quiet
        case .mailUndo(let r):
            guard let entry = MailUndoBook.shared.take(r: r, now: Date()) else {
                Trace.app("recv mail/undo", ["result": "expired", "at": ms])
                return .quiet
            }
            Trace.app("recv mail/undo", ["kind": entry.kind.rawValue, "at": ms])
            mail("undo") { try await Services.mailActions.undo(entry.token) }
            return .quiet
        case .mailStar(let r):
            Trace.app("recv mail/star", ["at": ms])
            mail("star") {
                let starred = (try? Services.mail.thread(r: r))?.starred ?? false
                try await Services.mailActions.star(r: r, !starred)
            }
            return .quiet
        case .openMessage(let r):
            Trace.app("recv open/message", ["at": ms])
            return peek.showMessage(r: r) ? .peek : .nothing
        case .unhandled(let name):
            Trace.app("recv \(name)", ["handled": "0", "at": ms])
            return .quiet
        case .ignore(let name, let reason):
            Trace.app("recv-ignored", ["route": name, "reason": reason, "at": ms])
            return .nothing
        }
    }

    /// Runs one mail action off the click; once the change is made the data layer republishes, so flush
    /// again (the batch's own flush ran before the action finished).
    private func mail(_ action: String, _ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
                Trace.app("mail", ["action": action, "result": "ok"])
            } catch {
                Trace.app("mail", ["action": action, "result": "error"])
            }
            Services.widgetInteractions.flushChanged()
        }
    }

    /// Join: the store's URL, re-checked (https + allowlisted host) before anything opens it. Returns
    /// whether the meeting opened (its app then takes the front: no restore, no flush race).
    private func join(r: String, at ms: String) -> Bool {
        let event = (try? Services.calendar.event(r: r)) ?? nil
        guard let url = event?.joinURL, JoinPolicy.isAllowed(url) else {
            Trace.app("recv join", ["result": event == nil ? "missing" : "blocked", "at": ms])
            return false
        }
        let opened = NSWorkspace.shared.open(url)
        Trace.app("recv join", ["result": opened ? "opened" : "failed", "at": ms])
        return opened
    }

    /// Up Next's record button. With Yaya's Murmur on this Mac it joins with the meeting's recorder (D-046): Fathom or
    /// Murmur leave the front to the meeting; a Fathom wait or "Ask each time" shows the Event Peek; Off joins.
    /// Without Murmur, Join with Fathom (D-045): records with the meeting's Fathom account and leaves the front to the
    /// meeting, or shows the Event Peek with the switch panel while Fathom is on another account. A meeting whose
    /// accounts no longer record with Fathom joins as usual.
    private func record(r: String, at ms: String) -> FrontRestorePolicy.Outcome {
        guard let event = (try? Services.calendar.event(r: r)) ?? nil else {
            Trace.app("recv record", ["result": "missing", "at": ms])
            return .quiet
        }
        let routed = RecorderDispatch.join(event, via: "widget")
        if routed != .inactive {
            Trace.app("recv record", ["result": "\(routed)", "at": ms])
            switch routed {
            case .recorded, .joined: return .handedOff
            case .waiting, .ask: return peek.showEvent(r: r) ? .peek : .nothing
            case .blocked, .inactive: return .quiet
            }
        }
        let outcome = FathomSession.shared.join(event, directory: AccountDirectory.current(), via: "widget")
        Trace.app("recv record", ["result": "\(outcome)", "at": ms])
        switch outcome {
        case .started: return .handedOff
        case .waiting: return peek.showEvent(r: r) ? .peek : .nothing
        case .notLinked: return join(r: r, at: ms) ? .handedOff : .quiet
        case .blocked: return .quiet
        }
    }

    /// Up Next's Live Helper button (D-048): Yaya's Murmur joins a meeting it marked Live Helper, whatever the
    /// account's recorder, and Murmur attaches that meeting's chat. A meeting no longer marked (or Murmur gone) is the
    /// record button's.
    private func liveHelper(r: String, at ms: String) -> FrontRestorePolicy.Outcome {
        guard let event = (try? Services.calendar.event(r: r)) ?? nil else {
            Trace.app("recv livehelper", ["result": "missing", "at": ms])
            return .quiet
        }
        // The popover card's Join with Live Helper takes the same path (D-049).
        guard let outcome = MurmurSession.shared.joinLiveHelper(event, via: "widget") else {
            Trace.app("recv livehelper", ["result": "unmarked", "at": ms])
            return record(r: r, at: ms)
        }
        Trace.app("recv livehelper", ["result": "\(outcome)", "at": ms])
        switch outcome {
        case .started, .joinedOnly: return .handedOff
        case .notInstalled: return record(r: r, at: ms)
        case .blocked: return .quiet
        }
    }

    /// If the link woke us (cold launch, or we only just became active), hide 250 ms later and give
    /// the front back. `open -g` never activates the app, so probe-driven links log `hid=0`.
    /// `sinceActivation`: fixed at the batch's arrival for a refresh (see `handBackAfterQuiet`).
    private func hideIfLinkActivated(activeAtReceipt: Bool, sinceActivation: TimeInterval? = nil, cold: Bool? = nil) {
        let cold = cold ?? (Date().timeIntervalSince(launchedAt) < 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let hid = HidePolicy.shouldHide(isActive: NSApp.isActive, cold: cold, activeAtReceipt: activeAtReceipt,
                                            sinceActivation: sinceActivation ?? Date().timeIntervalSince(self.lastActivation))
            Trace.app("hide-check", [
                "hid": hid ? "1" : "0",
                "activeAtRecv": activeAtReceipt ? "1" : "0",
                "cold": cold ? "1" : "0",
                "when": "250ms",
            ])
            guard hid else { return }
            // Hand the front back first (while we still own the activation), then hide our windows.
            self.front.restore(reason: "quiet")
            NSApp.hide(nil)
        }
    }

    /// A Peek is up after a link: deactivate (give the front back) so desktop widgets regain their
    /// colour; the non-activating panel stays visible and clickable.
    private func restoreAfterPeek(activeAtReceipt: Bool) {
        let cold = Date().timeIntervalSince(launchedAt) < 4
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let activated = HidePolicy.shouldHide(isActive: NSApp.isActive, cold: cold, activeAtReceipt: activeAtReceipt,
                                                  sinceActivation: Date().timeIntervalSince(self.lastActivation))
            // Already in front before the tap (the user is in our window): leave the front alone.
            guard activated else { return }
            self.front.restore(reason: "peek")
        }
    }
}
