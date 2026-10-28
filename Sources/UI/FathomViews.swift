import SwiftUI

// Join with Fathom on the app's own surfaces (D-045): the button and the line under it, the Event Peek's
// "Records to" picker, and the panel that waits for Fathom to switch accounts. The popover and the Peek both
// draw `FathomControls`; the logic lives in FathomModels.swift.

/// The button, its status line and, while a Join with Fathom for this meeting waits, the switch panel.
struct FathomControls: View {
    @ObservedObject var session: FathomSession
    let event: CalendarEvent
    let target: FathomTarget
    let directory: AccountDirectory
    /// The button's height: 34 in the popover card, 38 in the Peek.
    var height: CGFloat = 36
    /// The line under the button (the Peek's "Records to" says it instead when it shows the same account ready).
    var showStatus = true
    let join: () -> Void
    /// One of the panel's own buttons ends or restarts the wait, just before the session acts (the Peek closes or
    /// measures itself again).
    var after: (FathomDone) -> Void = { _ in }

    var body: some View {
        if let pending = session.pending, pending.r == event.r {
            FathomWaitPanel(session: session, pending: pending, directory: directory, after: after)
        } else {
            VStack(spacing: 5) {
                FathomJoinButton(height: height, action: join)
                if showStatus {
                    let status = FathomText.status(target, session.check(target)) { session.label($0, directory: directory) }
                    FathomStatusLine(text: status.text, tone: status.tone)
                }
            }
        }
    }
}

struct FathomJoinButton: View {
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(AppTheme.bad).frame(width: 9, height: 9)
                Text("Join with Fathom").font(AppTheme.font(14, .heavy))
            }
            .foregroundStyle(AppTheme.text)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(Capsule().fill(Color.white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(AppTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Opens the call and asks Fathom on this Mac to record it")
        .accessibilityLabel(Text("Join with Fathom"))
        .accessibilityHint(Text("Opens the video call and starts Fathom"))
    }
}

struct FathomStatusLine: View {
    let text: String
    let tone: FathomText.Tone

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tone == .ok ? "checkmark" : tone == .warn ? "exclamationmark.triangle.fill" : "questionmark.circle")
                .font(.system(size: 10, weight: .bold))
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(AppTheme.font(11.5, .medium))
        .foregroundStyle(tone == .ok ? AppTheme.text2 : tone == .warn ? AppTheme.warn : AppTheme.text3)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// "Switch Fathom to ORB": what is wrong, Open Fathom, and the wait's countdown; after a timeout, Try again.
struct FathomWaitPanel: View {
    @ObservedObject var session: FathomSession
    let pending: FathomSession.Pending
    let directory: AccountDirectory
    var after: (FathomDone) -> Void = { _ in }
    @Environment(\.headlessRender) private var headless

    var body: some View {
        let words = FathomText.wait(pending, current: { session.label($0, directory: directory) })
        VStack(alignment: .leading, spacing: 8) {
            Text(words.title).font(AppTheme.font(14, .heavy)).foregroundStyle(AppTheme.text)
            Text(words.body).font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            primary(words)
            HStack(spacing: 8) {
                // `after` goes first: the Peek must know the wait ends by this button before the session ends it.
                secondary("Join without recording") {
                    after(.joined)
                    session.joinWithoutRecording()
                }
                secondary("Cancel") {
                    after(.cancelled)
                    session.cancelWait()
                }
            }
            if pending.phase == .waiting { countdown }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.warn.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func primary(_ words: FathomText.Wait) -> some View {
        Button {
            switch words.primary {
            case "Try again":
                after(.resized)
                session.retry()
            case "Record anyway":
                after(.recorded)
                session.recordAnyway()
            default:
                session.openFathom()
            }
        } label: {
            Text(words.primary).font(AppTheme.font(13.5, .heavy)).foregroundStyle(AppTheme.accentText)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Capsule().fill(AppTheme.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(AppTheme.stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var countdown: some View {
        HStack(spacing: 5) {
            Image(systemName: "hourglass").font(.system(size: 10, weight: .bold))
            Text("Waiting for Fathom\u{2026}")
            if headless {
                Text(FathomText.left(pending.deadline.timeIntervalSince(session.env.clock())))
            } else {
                Text(timerInterval: Date()...max(Date(), pending.deadline), countsDown: true).monospacedDigit()
                Text("left")
            }
        }
        .font(AppTheme.font(11.5, .medium)).foregroundStyle(AppTheme.text3)
        .frame(maxWidth: .infinity)
    }
}

/// The Event Peek's "Records to ORB · address ⌄": a menu when the meeting is on more than one linked account.
struct FathomRecordsTo: View {
    let targets: [FathomTarget]
    let chosen: FathomTarget
    let choose: (FathomTarget) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Records to").foregroundStyle(AppTheme.text3)
            Spacer(minLength: 6)
            Button {
                AccountsKit.MenuPresenter.show(targets.map { t in
                    AccountsKit.PopUpMenuButton.Item(title: "\(t.tag) \u{00B7} \(t.email)") { choose(t) }
                })
            } label: {
                HStack(spacing: 4) {
                    Text("\(chosen.tag) \u{00B7} \(chosen.email)").lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(AppTheme.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Records to \(chosen.tag)"))
            .accessibilityHint(Text("Choose which account\u{2019}s Fathom records this meeting"))
        }
        .font(AppTheme.font(11.5, .medium))
    }
}
