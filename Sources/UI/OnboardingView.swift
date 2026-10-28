import Combine
import SwiftUI
import UserNotifications
import WidgetKit

/// What the Keep-me-running step asks of the Mac (D-039). The app uses the real login item and bundle
/// checks; renders pass fixed answers, so they never query or change the system.
struct OnboardingSystem {
    var loginItemEnabled: () -> Bool
    var setLoginItem: (Bool) -> Bool
    var placement: () -> PlacementChoice
    /// Copies this app to /Applications (or ~/Applications), opens the copy and quits. Returns a line to
    /// show when it couldn't; it never replaces a copy `AppPlacement` refused.
    var move: (_ toUserApplications: Bool) -> String?

    static func fixed(placement: PlacementChoice, loginItem: Bool = false) -> OnboardingSystem {
        OnboardingSystem(loginItemEnabled: { loginItem }, setLoginItem: { _ in loginItem },
                         placement: { placement }, move: { _ in nil })
    }
}

/// The welcome guide's state: the accounts store for the first three steps, three remembered ticks, and
/// what WidgetKit, UserNotifications and the login item say. `live` = false in renders (no system queries).
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var shown: OnboardingStep
    @Published private(set) var notifications: String
    @Published private(set) var looksConfirmed: Bool
    @Published private(set) var widgetPlaced: Bool
    @Published private(set) var widgetNote: String?
    /// Keep me running: the login item's state, "Not now", where this copy lives, and a note.
    @Published private(set) var loginItemOn: Bool
    @Published private(set) var runningDecided: Bool
    @Published private(set) var placement: PlacementChoice
    @Published private(set) var runningNote: String?

    let accounts: AccountsModel
    private let bag: PreferenceBag
    private let live: Bool
    private let system: OnboardingSystem
    private var subscriptions: Set<AnyCancellable> = []
    /// Whether the step shown was already done when it was shown: only a step that gets done while you
    /// look at it moves the guide on (opening a finished step to look at it again doesn't bounce away).
    private var shownWasDone = false

    init(accounts: AccountsModel, bag: PreferenceBag = DefaultsBag.shared, live: Bool = true,
         notifications: String = "undetermined", shown: OnboardingStep? = nil, system: OnboardingSystem? = nil) {
        self.accounts = accounts
        self.bag = bag
        self.live = live
        self.notifications = notifications
        let system = system ?? (live ? AppMover.onboardingSystem : .fixed(placement: .inApplications))
        self.system = system
        looksConfirmed = bag.object(OnboardingFlow.looksKey) as? Bool ?? false
        widgetPlaced = bag.object(OnboardingFlow.widgetKey) as? Bool ?? false
        loginItemOn = system.loginItemEnabled()
        runningDecided = bag.object(OnboardingFlow.runningKey) as? Bool ?? false
        placement = system.placement()
        self.shown = .google
        self.shown = shown ?? OnboardingFlow.resume(facts, stored: bag.object(OnboardingFlow.stepKey) as? Int)
        shownWasDone = OnboardingFlow.isDone(self.shown, facts)
        // Accounts publish in willSet: look again on the next turn, once the new value is in.
        accounts.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.advanceIfDone() } } }
            .store(in: &subscriptions)
    }

    var facts: OnboardingFacts {
        OnboardingFacts(googleReady: accounts.google.isReady, accounts: accounts.accounts.count,
                        looksConfirmed: looksConfirmed, widgetPlaced: widgetPlaced, notifications: notifications,
                        runningSettled: loginItemOn || runningDecided)
    }

    // MARK: Keep me running

    func startAtLogin() {
        loginItemOn = system.setLoginItem(true) || system.loginItemEnabled()
        runningNote = loginItemOn ? nil : "macOS didn\u{2019}t let me. System Settings \u{2192} General \u{2192} Login Items has the switch."
        Trace.app("onboarding", ["step": "running", "result": loginItemOn ? "login-item" : "refused"])
        advanceIfDone()
    }

    func notNowRunning() {
        runningDecided = true
        if live { bag.set(true, OnboardingFlow.runningKey) }
        Trace.app("onboarding", ["step": "running", "result": "not-now"])
        advanceIfDone()
    }

    /// "Move me to Applications" (or to ~/Applications when /Applications holds a copy that isn't ours).
    func move(toUserApplications: Bool) {
        if let problem = system.move(toUserApplications) { runningNote = problem }
    }

    /// Closing the guide: remember it as finished once something is connected.
    func noteClosed() {
        guard live, OnboardingFlow.finishes(facts), bag.object(OnboardingFlow.completedKey) == nil else { return }
        bag.set(Date(), OnboardingFlow.completedKey)
    }

    func show(_ step: OnboardingStep) {
        guard OnboardingFlow.isAvailable(step, facts) else { return }
        shown = step
        shownWasDone = OnboardingFlow.isDone(step, facts)
        if live { bag.set(step.rawValue, OnboardingFlow.stepKey) }
        if step == .widget && !widgetPlaced { checkWidgets() }
    }

    /// The sheet appeared: ask the system what it already knows.
    func appeared() {
        refreshNotifications()
        if !widgetPlaced { checkWidgets() }
    }

    func confirmLooks() {
        looksConfirmed = true
        if live { bag.set(true, OnboardingFlow.looksKey) }
        Trace.app("onboarding", ["step": "looks", "result": "done"])
        advanceIfDone()
    }

    func markWidgetPlaced(note: String? = nil) {
        widgetPlaced = true
        widgetNote = note
        if live { bag.set(true, OnboardingFlow.widgetKey) }
        Trace.app("onboarding", ["step": "widget", "result": "done"])
        advanceIfDone()
    }

    /// Our own widgets on the desktop, by WidgetKit's count (no titles, nothing else read).
    func checkWidgets() {
        guard live else { return }
        widgetNote = "Looking\u{2026}"
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            let count: Int? = (try? result.get()).map { infos in infos.filter { WidgetKinds.spec($0.kind) != nil }.count }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch count {
                    case .some(let n) where n > 0:
                        self.markWidgetPlaced(note: n == 1 ? "Found it on your desktop. Lovely." : "Found \(n) on your desktop. Lovely.")
                    case .some:
                        self.widgetNote = "None on the desktop yet."
                    case .none:
                        self.widgetNote = "I couldn\u{2019}t check just now. The button below works too."
                    }
                }
            }
        }
    }

    func requestNotifications() {
        guard live else { return }
        Trace.app("onboarding", ["step": "notifications", "action": "request"])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshNotifications() } }
        }
    }

    func refreshNotifications() {
        guard live else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let state = SuiteJSON.notificationState(settings.authorizationStatus)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.notifications = state
                    self?.advanceIfDone()
                }
            }
        }
    }

    private func advanceIfDone() {
        let doneNow = OnboardingFlow.isDone(shown, facts)
        defer { shownWasDone = OnboardingFlow.isDone(shown, facts) }
        guard doneNow, !shownWasDone else { return }
        let next = OnboardingFlow.advance(from: shown, facts)
        if next != shown {
            shown = next
            if live { bag.set(next.rawValue, OnboardingFlow.stepKey) }
        }
    }
}

/// The welcome guide: a resumable 540 × 640 sheet with six numbered steps (`OnboardingStep`), done in any order.
/// "Let's go" closes it at any point; under `--onboarding` it also writes the installer's handoff marker (SuiteFlags). While an
/// account is being added, the add-account sheet takes the guide's place, then hands it back.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var accounts: AccountsModel
    let onDone: () -> Void
    @Environment(\.headlessRender) private var headless

    static let size = CGSize(width: 540, height: 640)

    var body: some View {
        Group {
            if accounts.isAddSheetPresented && !headless {
                AddAccountSheet(model: accounts)
                    .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
            } else {
                guide
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(AppTheme.background)
        .environment(\.colorScheme, .dark)
        // Provider Setup's drop zone is an AppKit drop target: headless renders draw it without one.
        .environment(\.accountsStaticRender, headless)
    }

    private var guide: some View {
        let facts = model.facts
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Every inbox and calendar, one desk.")
                        .font(AppTheme.font(23, .heavy)).foregroundStyle(AppTheme.text)
                    Spacer(minLength: 8)
                    Text(OnboardingFlow.progress(facts))
                        .font(AppTheme.font(11, .bold)).foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(AppTheme.accentSoft))
                }
                Text("\(OnboardingFlow.countWord) short steps, in any order. Close me whenever you like; I remember where you got to.")
                    .font(AppTheme.font(13)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 14)
            ShellScroll {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(OnboardingStep.allCases) { step in
                        stepRow(step, facts)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            Rectangle().fill(AppTheme.stroke).frame(height: 1)
            HStack {
                Text("This guide lives in Settings if you want it again.")
                    .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                Spacer()
                Button("Let\u{2019}s go", action: onDone)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
    }

    // MARK: Steps

    private func stepRow(_ step: OnboardingStep, _ facts: OnboardingFacts) -> some View {
        let done = OnboardingFlow.isDone(step, facts)
        let available = OnboardingFlow.isAvailable(step, facts)
        let open = model.shown == step && available
        return HStack(alignment: .top, spacing: 14) {
            marker(step, done: done, available: available)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(AppTheme.font(14.5, .bold))
                    .foregroundStyle(available ? AppTheme.text : AppTheme.text3)
                    .padding(.top, done && !open ? 4 : 0)
                // Finished steps fold to their title, so the open one sits higher up.
                if open || !done {
                    Text(available ? step.detail : waitingLine(step))
                        .font(AppTheme.font(12.5)).foregroundStyle(available ? AppTheme.text2 : AppTheme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if open {
                    stepBody(step).padding(.top, 10)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, done && !open ? 8 : 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(open ? AppTheme.card : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(open ? AppTheme.stroke : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if !open { model.show(step) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Step \(step.rawValue): \(step.title)"))
        .accessibilityValue(Text(done ? "Done" : (available ? (open ? "Open" : "To do") : "Waiting for an earlier step")))
        .accessibilityAction(named: Text("Open this step")) { model.show(step) }
    }

    private func marker(_ step: OnboardingStep, done: Bool, available: Bool) -> some View {
        Group {
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy)).foregroundStyle(AppTheme.accentText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AppTheme.good))
            } else {
                StepNumber(number: step.rawValue, size: 28).opacity(available ? 1 : 0.4)
            }
        }
        .accessibilityHidden(true)
    }

    private func waitingLine(_ step: OnboardingStep) -> String {
        switch step {
        case .accounts: return "Right after Google sign-in (step 1)."
        case .looks: return "Once an account is connected (step 2)."
        default: return step.detail
        }
    }

    @ViewBuilder
    private func stepBody(_ step: OnboardingStep) -> some View {
        switch step {
        case .google: googleBody
        case .accounts: accountsBody
        case .looks: looksBody
        case .widget: widgetBody
        case .notifications: notificationsBody
        case .running: runningBody
        }
    }

    @ViewBuilder
    private var runningBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch model.placement {
            case .inApplications:
                if model.loginItemOn {
                    doneLine("I\u{2019}ll start with your Mac, quietly in the menu bar.")
                } else {
                    HStack(spacing: 10) {
                        Button("Start me at login") { model.startAtLogin() }.buttonStyle(PrimaryButtonStyle())
                        Button("Not now") { model.notNowRunning() }.buttonStyle(AccountsKit.SecondaryButton())
                    }
                    Text("Change it any time in Settings.").font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                }
            case .moveToApplications(let replacing):
                runningLine("Login items only work from Applications, and I\u{2019}m somewhere else right now.")
                HStack(spacing: 10) {
                    Button("Move me to Applications") { model.move(toUserApplications: false) }.buttonStyle(PrimaryButtonStyle())
                    Button("Not now") { model.notNowRunning() }.buttonStyle(AccountsKit.SecondaryButton())
                }
                Text(replacing ? "Your older copy there goes to the Trash, and I reopen from Applications."
                               : "I copy myself there and reopen from Applications.")
                    .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            case .offerUserApplications(let reason):
                runningLine("Login items only work from an Applications folder. \(reason) I\u{2019}ll leave that one alone.")
                HStack(spacing: 10) {
                    Button("Move me to my Applications folder") { model.move(toUserApplications: true) }.buttonStyle(PrimaryButtonStyle())
                    Button("Not now") { model.notNowRunning() }.buttonStyle(AccountsKit.SecondaryButton())
                }
                Text("That\u{2019}s ~/Applications, just for you.").font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
            case .notNow(let reason):
                runningLine("\(reason) I\u{2019}ll leave both copies alone.")
                Button("Not now") { model.notNowRunning() }.buttonStyle(AccountsKit.SecondaryButton())
            }
            if let note = model.runningNote {
                Text(note).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runningLine(_ text: String) -> some View {
        Text(text).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var googleBody: some View {
        if accounts.google.isReady {
            doneLine("Google sign-in is ready. On to your accounts.")
        } else {
            ProviderSetupView(model: accounts)
        }
    }

    private var accountsBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if accounts.accounts.isEmpty {
                Text("Nothing connected yet.").font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text3)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(accounts.accounts) { account in
                        HStack(spacing: 8) {
                            AccountsKit.LogoBadge(image: accounts.logos[account.id], size: 22)
                            Text(account.tag).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text)
                            Text(account.email).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Button {
                accounts.presentAdd()
            } label: {
                Label(accounts.accounts.isEmpty ? "Add a Google account" : "Add another", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var looksBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(accounts.accounts) { account in
                HStack(spacing: 10) {
                    AccountsKit.LogoBadge(image: accounts.logos[account.id], size: 28,
                                          busy: accounts.fetchingLogo.contains(account.id))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(account.tag).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text)
                            if accounts.logos[account.id] == nil && !AccountNaming.isPersonal(email: account.email) {
                                Button("Find its logo") { Task { await accounts.fetchLogo(account.id) } }
                                    .buttonStyle(AccountsKit.LinkButton())
                            }
                        }
                        AccountsKit.SwatchPicker(selected: account.color) { accounts.setColor(account.id, $0) }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Looks good") { model.confirmLooks() }.buttonStyle(PrimaryButtonStyle())
                Text("Drop your own logo on a card in Accounts any time.")
                    .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
            }
            .padding(.top, 2)
        }
    }

    private var widgetBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            miniStep(1, "Right-click an empty spot on the desktop and choose Edit Widgets\u{2026}")
            miniStep(2, "Type \u{201C}Yaya\u{201D} in the search field.")
            miniStep(3, "Drag Agenda (or Month, or Up Next) onto your desktop. Done.")
            HStack(spacing: 10) {
                Button("I\u{2019}ve added one") { model.markWidgetPlaced() }.buttonStyle(PrimaryButtonStyle())
                Button("Check for me") { model.checkWidgets() }.buttonStyle(AccountsKit.SecondaryButton(compact: true))
                if let note = model.widgetNote {
                    Text(note).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2).lineLimit(2)
                }
            }
            .padding(.top, 3)
        }
    }

    private func miniStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(n)").font(AppTheme.font(10.5, .heavy)).foregroundStyle(AppTheme.accent)
                .frame(width: 18, height: 18).background(Circle().fill(AppTheme.accentSoft))
            Text(text).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var notificationsBody: some View {
        switch model.notifications {
        case "granted":
            doneLine("Notifications are on. Pause them for an hour from the menu-bar icon (control-click). \(JoinHotkey.display) joins your next meeting from anywhere.")
        case "denied":
            Text("They\u{2019}re off for now. System Settings \u{2192} Notifications \u{2192} Yaya\u{2019}s Calendar turns them on.")
                .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Button("Allow notifications") { model.requestNotifications() }.buttonStyle(PrimaryButtonStyle())
                Text("macOS asks once. You can change your mind in System Settings.")
                    .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
            }
        }
    }

    private func doneLine(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.good)
            .fixedSize(horizontal: false, vertical: true)
    }
}
