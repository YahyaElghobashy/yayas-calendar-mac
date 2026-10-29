import AppKit

/// Joining with a meeting's recorder from the places that have no menu: the Up Next record button, ⌃⌥J and the
/// heads-up (D-046). `.inactive` while Murmur isn't on this Mac: the caller keeps its Join with Fathom path (D-045).
@MainActor
enum RecorderDispatch {
    /// The widgets' record button and the heads-up's second action follow each account's recorder (D-046; D-045's
    /// Fathom button while Murmur isn't on this Mac). The publisher and the notifier call it off the main thread.
    static func install() {
        SnapshotPublisher.recorderKind = { ids, hasJoin in
            RecorderRouting.offeredKind(accountIds: ids, hasJoin: hasJoin, murmurInstalled: MurmurLive.installedFlag.get(),
                                        fathomInstalled: FathomLive.installedCache.get(),
                                        link: { FathomPrefs.link($0) }, choice: { RecorderPrefs.choice($0) })
        }
    }

    enum Result: Equatable {
        case inactive
        /// The recorder's link and the meeting opened.
        case recorded
        /// Join with Fathom waits for Fathom to switch accounts: show the Event Peek.
        case waiting
        /// "Ask each time": show the Event Peek, where the Join menu is.
        case ask
        /// The meeting opened, nothing records (Off, or the recorder isn't there).
        case joined
        /// No allowlisted link: nothing opened.
        case blocked
    }

    static func recorder(for event: CalendarEvent) -> Recorder? {
        FathomSession.shared.refresh()
        MurmurSession.shared.refresh()
        return RecorderRouting.meeting(accountIds: event.accountIds, murmurInstalled: MurmurSession.shared.installed,
                                       fathomInstalled: FathomSession.shared.installed,
                                       link: FathomSession.shared.env.link, choice: { RecorderPrefs.choice($0) })
    }

    static func join(_ event: CalendarEvent, via: String) -> Result {
        guard let recorder = recorder(for: event) else { return .inactive }
        let result: Result
        switch recorder {
        case .fathom:
            switch FathomSession.shared.join(event, directory: AccountDirectory.current(), via: via) {
            case .started: result = .recorded
            case .waiting: result = .waiting
            case .blocked: result = .blocked
            case .notLinked: result = plain(event)
            }
        case .murmur:
            switch MurmurSession.shared.join(event, mode: nil, via: via) {
            case .started, .joinedOnly: result = .recorded
            case .blocked: result = .blocked
            case .notInstalled: result = plain(event)
            }
        case .ask:
            result = .ask
        case .off:
            result = plain(event)
        }
        Trace.app("recorder-join", ["via": via, "recorder": recorder.rawValue, "result": "\(result)"])
        return result
    }

    /// The meeting only, its link re-checked.
    static func plain(_ event: CalendarEvent) -> Result {
        guard let url = event.joinURL, JoinPolicy.isAllowed(url) else { return .blocked }
        return NSWorkspace.shared.open(url) ? .joined : .blocked
    }
}
