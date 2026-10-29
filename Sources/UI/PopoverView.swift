import SwiftUI

/// What the popover's buttons do. The app wires them to the Peeks, the main window and the browser;
/// renders leave them empty.
struct PopoverActions {
    var openApp: (AppSection?) -> Void = { _ in }
    var join: (CalendarEvent) -> Void = { _ in }
    /// Join with Fathom (D-045): records at once, or the card waits for Fathom to switch accounts.
    var joinWithFathom: (CalendarEvent) -> Void = { _ in }
    /// The Join menu's choices and Join with Yaya's Murmur (D-046; `.murmur(nil)` leaves the mode to Murmur).
    var joinWith: (CalendarEvent, JoinMenu.Entry) -> Void = { _, _ in }
    var showEvent: (String) -> Void = { _ in }
    var showThread: (String) -> Void = { _ in }
}

/// The menu-bar popover, 380 × 560 in the dark app look: the next meeting with a big Join, then
/// Agenda | Inbox with account chips over a scrolling list of the widget's own rows at window scale
/// (meeting → Event Peek, conversation → Mail Peek), and a footer whose last element is MadeByFooter.
struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    var actions = PopoverActions()
    @Environment(\.headlessRender) private var headless

    static let size = CGSize(width: 380, height: 560)
    static let corner: CGFloat = 14

    static var rowStyle: WidgetStyle {
        var s = WidgetStyle()
        s.look = .ink
        s.scaleOverride = 1.06
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if model.phase != .noAccounts && model.phase != .failed && model.phase != .loading {
                    NextMeetingCard(model: model, fathom: model.fathom, actions: actions)
                }
                controls
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
            Rectangle().fill(AppTheme.stroke).frame(height: 1)
            ShellScroll {
                list.padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(AppTheme.stroke).frame(height: 1)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(AppTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Tabs + chips

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if model.showsInbox {
                    SegmentPicker(options: [(PopoverModel.Tab.agenda, "Agenda"),
                                            (.inbox, model.unread > 0 ? "Inbox · \(model.unread)" : "Inbox")],
                                  selection: Binding(get: { model.tab }, set: { model.select($0) }))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Show"))
                } else {
                    Text("COMING UP").font(AppTheme.font(10.5, .bold)).tracking(0.6).foregroundStyle(AppTheme.text3)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 6)
                syncButton
            }
            if model.chipAccounts.count > 1 { chips }
        }
    }

    private var syncButton: some View {
        Button {
            Task { await model.syncNow() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(model.syncing ? AppTheme.accent : AppTheme.text2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.syncing || model.accounts.isEmpty)
        .help(model.syncing ? "Syncing\u{2026}" : "Sync now")
        .accessibilityLabel(Text(model.syncing ? "Syncing" : "Sync now"))
    }

    @ViewBuilder
    private var chips: some View {
        let row = HStack(spacing: 6) {
            PopoverChip(title: "All", account: nil, on: model.filter.isEmpty) { model.showAll() }
            ForEach(model.chipAccounts) { account in
                PopoverChip(title: account.tag, account: account, on: model.isOn(account.id)) { model.toggle(account.id) }
            }
        }
        if headless {
            row.frame(maxWidth: .infinity, alignment: .leading).clipped()
        } else {
            ScrollView(.horizontal, showsIndicators: false) { row }.frame(height: 24)
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var list: some View {
        if model.tab == .inbox && model.showsInbox { inbox } else { agenda }
    }

    @ViewBuilder
    private var agenda: some View {
        switch model.phase {
        case .loading:
            PopoverNote(symbol: "hourglass", title: "Fetching your calendars\u{2026}", line: "This takes a moment the first time.")
        case .noAccounts:
            PopoverNote(symbol: "person.crop.circle.badge.plus", title: "No calendars connected yet",
                        line: "Connect a Google account and your meetings land here, on your widgets and in the menu bar.",
                        button: ("Connect an account", { actions.openApp(.accounts) }))
        case .failed:
            PopoverNote(symbol: "exclamationmark.triangle", title: "I couldn\u{2019}t read your calendars just now",
                        line: "Try the sync button. If it keeps happening, Accounts says which one needs you.")
        case .ready:
            if model.days.isEmpty {
                PopoverNote(symbol: "sun.max", title: "A clear week",
                            line: model.filter.isEmpty ? "Nothing booked for the next seven days." : "Nothing on these calendars this week. Try All.")
            } else {
                agendaRows
            }
        }
    }

    private var agendaRows: some View {
        var style = Self.rowStyle
        style.use24Hour = model.use24Hour
        let directory = model.accountDirectory
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.days.enumerated()), id: \.element.day) { index, day in
                DayBanner(day: day.day, continued: false, count: day.events.filter { !$0.allDay }.count,
                          now: model.now, style: style)
                    .padding(.top, index == 0 ? 0 : 12)
                    .padding(.bottom, 3)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(day.events.enumerated()), id: \.element.r) { i, event in
                    PeekRow(meeting: event.widgetMeeting(index: i + 1, directory: directory), now: model.now, style: style,
                            badges: model.badges(event.r)) {
                        actions.showEvent(event.r)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inbox: some View {
        switch model.mailPhase {
        case .loading:
            PopoverNote(symbol: "hourglass", title: "Fetching your mail\u{2026}", line: "The first sync takes a moment.")
        case .noAccounts:
            PopoverNote(symbol: "person.crop.circle.badge.plus", title: "No inboxes connected yet",
                        line: "Turn on mail for an account and your newest conversations land here.",
                        button: ("Open Accounts", { actions.openApp(.accounts) }))
        case .failed:
            PopoverNote(symbol: "exclamationmark.triangle", title: "I couldn\u{2019}t read your mail just now",
                        line: "Check your connection. If it keeps happening, Accounts says which one needs you.")
        case .ready:
            if model.threads.isEmpty {
                PopoverNote(symbol: "checkmark.seal", title: "Inbox zero",
                            line: model.filter.isEmpty ? "Nothing waiting for you. Lovely." : "Nothing in these inboxes. Try All.")
            } else {
                let directory = model.accountDirectory
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.threads) { thread in
                        ThreadRow(thread: thread, account: directory.account(thread.accountId), now: model.now,
                                  selected: false, hint: "Opens the conversation in a Peek") {
                            actions.showThread(thread.r)
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    actions.openApp(nil)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "macwindow").font(.system(size: 11, weight: .bold))
                        Text("Open Yaya\u{2019}s Calendar").font(AppTheme.font(12.5, .bold))
                    }
                    .foregroundStyle(AppTheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the main window"))
                Spacer(minLength: 8)
                Text(model.syncedText)
                    .font(AppTheme.font(11)).foregroundStyle(AppTheme.text3).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.top, 9)
            MadeByFooter(style: .inline)
                .padding(.horizontal, 8).padding(.bottom, 6)
        }
    }
}

/// The next meeting: logo, title, when, a self-updating countdown, and the one filled Join.
private struct NextMeetingCard: View {
    @ObservedObject var model: PopoverModel
    @ObservedObject var fathom: FathomSession
    let actions: PopoverActions
    @Environment(\.headlessRender) private var headless

    var body: some View {
        if let card = model.card {
            filled(card)
        } else {
            empty
        }
    }

    private func filled(_ card: PopoverModel.Card) -> some View {
        let e = card.event
        let account = e.accountIds.first.flatMap(model.accountDirectory.account)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                PeekAccountChip(account: account, size: 16)
                Spacer(minLength: 6)
                countdown(card)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title.isEmpty ? "Meeting" : e.title)
                    .font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(card.when).font(AppTheme.font(12.5, .medium)).foregroundStyle(AppTheme.text2).lineLimit(1)
                if !card.badges.isEmpty { MurmurBadgeRow(badges: card.badges).padding(.top, 3) }
            }
            .contentShape(Rectangle())
            .onTapGesture { actions.showEvent(e.r) }
            .ycAccessibleButton(A11yText.card(card).label, value: A11yText.card(card).value,
                                hint: "Opens the meeting details") { actions.showEvent(e.r) }
            // While a Join with Fathom for this meeting waits, its panel offers the plain join too.
            if card.canJoin && !fathom.isPending(e.r) {
                if card.recorder != nil { splitJoin(card) } else { joinButton(card) }
            }
            if let recorder = card.recorder {
                recorderControls(card, recorder)
            } else if let target = card.fathom.first {
                FathomControls(session: fathom, event: e, target: target, directory: model.accountDirectory,
                               height: 34, join: { actions.joinWithFathom(e) })
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(card.soon ? AppTheme.accentSoft : AppTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(card.soon ? AppTheme.accent.opacity(0.35) : AppTheme.stroke, lineWidth: 1))
    }

    /// "Starts in 12 min" pill. Live: SwiftUI keeps it current with `Text(date, style: .relative)`;
    /// renders: the same words from the pinned clock.
    @ViewBuilder
    private func countdown(_ card: PopoverModel.Card) -> some View {
        let e = card.event
        let usesClock = !headless && !e.allDay && (card.live || e.start.timeIntervalSince(model.now) < 24 * 3600)
        Group {
            if usesClock {
                (Text(card.live ? "Ends in " : "Starts in ") + Text(card.live ? e.end : e.start, style: .relative))
            } else {
                Text(card.countdown)
            }
        }
        .font(AppTheme.font(11, .bold)).monospacedDigit()
        .foregroundStyle(card.soon ? AppTheme.accent : AppTheme.text2)
        .lineLimit(1)
        .padding(.horizontal, 9).frame(height: 22)
        .background(Capsule().fill(card.soon ? AppTheme.accentSoft : Color.white.opacity(0.07)))
        .accessibilityHidden(true)
    }

    /// With Yaya's Murmur on this Mac (D-046): Join keeps its word and gains "▾", every way to join this meeting.
    private func splitJoin(_ card: PopoverModel.Card) -> some View {
        JoinSplitButton(title: card.joinTitle, filled: card.soon, height: 36, join: { actions.join(card.event) },
                        menu: { showMenu(card) })
    }

    private func showMenu(_ card: PopoverModel.Card) {
        let e = card.event
        JoinMenuPresenter.show(model.joinMenu(card)) { entry in
            if entry == .justJoin { actions.join(e) } else { actions.joinWith(e, entry) }
        }
    }

    /// The account's recorder under Join: Join with Fathom (as D-045 drew it), Join with Yaya's Murmur, or
    /// "Join and record…". A Fathom wait started from the menu shows here whatever the recorder.
    @ViewBuilder
    private func recorderControls(_ card: PopoverModel.Card, _ recorder: Recorder) -> some View {
        let e = card.event
        if (recorder == .fathom || fathom.isPending(e.r)), let target = card.fathom.first {
            FathomControls(session: fathom, event: e, target: target, directory: model.accountDirectory,
                           height: 34, join: { actions.joinWithFathom(e) })
        } else if card.canJoin && recorder == .murmur {
            MurmurJoinControls(mark: card.murmurMark, height: 34) { actions.joinWith(e, .murmur(nil)) }
        } else if card.canJoin && recorder == .ask {
            AskRecorderButton(height: 34) { showMenu(card) }
        }
    }

    private func joinButton(_ card: PopoverModel.Card) -> some View {
        Button {
            actions.join(card.event)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "video.fill").font(.system(size: 12.5, weight: .bold))
                Text(card.joinTitle).font(AppTheme.font(14, .heavy))
            }
            .foregroundStyle(card.soon ? AppTheme.accentText : AppTheme.text)
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(Capsule().fill(card.soon ? AppTheme.accent : Color.white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(card.soon ? Color.clear : AppTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Opens the call (\(JoinHotkey.display) does the same from anywhere)")
        .accessibilityLabel(Text(card.joinTitle))
        .accessibilityHint(Text("Opens the video call"))
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max").font(.system(size: 15, weight: .semibold)).foregroundStyle(AppTheme.accent)
                .frame(width: 34, height: 34).background(Circle().fill(AppTheme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text("No more meetings this week").font(AppTheme.font(14, .bold)).foregroundStyle(AppTheme.text)
                Text("Your calendar is all yours.").font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(AppTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// An account filter chip: logo (or colour dot) and tag; selected chips fill with the accent.
private struct PopoverChip: View {
    let title: String
    let account: DirectoryAccount?
    let on: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let account {
                if let logo = account.logo {
                    Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: 13, height: 13).background(AppTheme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                } else {
                    Circle().fill(Color(hex: account.color)).frame(width: 7, height: 7)
                }
            }
            Text(title).font(AppTheme.font(11.5, on ? .bold : .medium)).lineLimit(1)
        }
        .foregroundStyle(on ? AppTheme.accentText : AppTheme.text)
        .padding(.horizontal, 10).frame(height: 24)
        .background(Capsule().fill(on ? AppTheme.accent : Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(on ? Color.clear : AppTheme.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .ycAccessibleButton(A11yText.chip(title, on: on).label, value: A11yText.chip(title, on: on).value,
                            hint: account == nil ? "Shows every account" : "Shows or hides this account", selected: on, action: action)
    }
}

/// Small empty / loading / error states, in the app's voice.
private struct PopoverNote: View {
    let symbol: String
    let title: String
    let line: String
    var button: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(AppTheme.accent)
                .frame(width: 46, height: 46).background(Circle().fill(AppTheme.accentSoft))
            Text(title).font(AppTheme.font(15, .heavy)).foregroundStyle(AppTheme.text)
                .multilineTextAlignment(.center)
            Text(line).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 290)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                Button(button.0, action: button.1).buttonStyle(PrimaryButtonStyle()).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
    }
}
