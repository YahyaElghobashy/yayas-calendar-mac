#if !YC_DATA_TESTS
import SwiftUI
import UserNotifications

/// Settings → Notifications: meeting heads-up (default ON), new mail (default OFF), pause for an hour.
/// Renders show the defaults (no UserDefaults reads), so they stay deterministic.
struct NotificationSettingsCard: View {
    /// The new-mail switch shows only while mail is on (the shell's `mailEnabled`; Settings passes it).
    var showMail = true
    @Environment(\.headlessRender) private var headless
    @Local private var meetings = true
    @Local private var newMail = false
    @Local private var pausedUntil: Date?
    @Local private var denied = false
    @Local private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Notifications").font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                Text("A nudge before calls, a word when an account needs you. Nothing else unless you ask.")
                    .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
            }
            .padding(.top, 8)
            ShellCard(padding: 0) {
                VStack(spacing: 0) {
                    row(title: "Meeting heads-up",
                        detail: "60 seconds before calls with a link or other people, with Join and Snooze 1 min.") {
                        ShellSwitch(isOn: Binding(get: { meetings }, set: { setMeetings($0) }))
                    }
                    if showMail {
                        divider
                        row(title: "New mail",
                            detail: "One note per account after each sync, like \u{201C}Work \u{00B7} 3 new: Juniper, Milo, \u{2026}\u{201D}.") {
                            ShellSwitch(isOn: Binding(get: { newMail }, set: { setNewMail($0) }))
                        }
                    }
                    divider
                    row(title: "Pause notifications", detail: pauseDetail) {
                        Button(isPaused ? "Resume" : "Pause 1 h") { togglePause() }
                            .buttonStyle(.plain).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.accent)
                    }
                    if denied {
                        divider
                        Label("Notifications are off for Yaya\u{2019}s Calendar in System Settings \u{2192} Notifications.",
                              systemImage: "bell.slash.fill")
                            .font(AppTheme.font(11.5, .semibold)).foregroundStyle(AppTheme.warn)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    private var pauseDetail: String {
        guard let until = pausedUntil, until > Date() else { return "An hour of quiet. Heads-ups due in it are skipped; a sign-in notice waits until it ends." }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return "Paused until \(f.string(from: until)). Heads-ups after that still come."
    }

    private func load() {
        guard !headless, !loaded else { return }
        loaded = true
        let prefs = Notifier.prefs
        meetings = prefs.meetingsOn
        newMail = prefs.newMailOn
        pausedUntil = prefs.pausedUntil
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            denied = settings.authorizationStatus == .denied
        }
    }

    private func setMeetings(_ on: Bool) {
        Notifier.prefs.meetingsOn = on
        meetings = on
        Trace.app("notify-setting", ["meetings": on ? "on" : "off"])
        Notifier.settingsChanged()
    }

    private func setNewMail(_ on: Bool) {
        Notifier.prefs.newMailOn = on
        newMail = on
        Trace.app("notify-setting", ["newMail": on ? "on" : "off"])
        Notifier.settingsChanged()
    }

    private func togglePause() {
        if isPaused { Notifier.resume() } else { Notifier.pause(for: 3600) }
        pausedUntil = Notifier.prefs.pausedUntil
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 18)
    }

    private func row<Trailing: View>(title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTheme.font(13.5, .semibold)).foregroundStyle(AppTheme.text)
                Text(detail).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
#endif
