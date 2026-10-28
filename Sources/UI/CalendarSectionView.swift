import SwiftUI

/// Calendar section: every calendar on one scrolling agenda (today → +60 days), drawn with the widget's
/// own day banners and rows at window size. Click a meeting for its Event Peek.
struct CalendarSectionView: View {
    @ObservedObject var model: CalendarSectionModel
    @Environment(\.headlessRender) private var headless

    static var rowStyle: WidgetStyle {
        var s = WidgetStyle()
        s.look = .ink
        s.scaleOverride = 1.16
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 14)
            ShellScroll {
                content
                    .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .onAppear { if !headless { model.load() } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if !headless { model.load() }
        }
        // Accounts load asynchronously at launch (and change in Accounts): redraw the chips and list.
        .onReceive(AccountsModel.shared.$accounts.dropFirst()) { _ in
            if !headless { DispatchQueue.main.async { model.load() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                PageTitle(title: "Calendar", subtitle: "Every calendar on one page, from today to the next two months.")
                Spacer(minLength: 16)
                Button {
                    Task { await model.syncNow() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11.5, weight: .bold))
                        Text(model.syncing ? "Syncing…" : "Sync now")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.syncing || model.phase == .noAccounts)
                .opacity(model.phase == .noAccounts ? 0.45 : 1)
                .padding(.top, 4)
            }
            if !model.accounts.isEmpty { chips }
        }
    }

    /// One row of account chips; with many accounts it scrolls sideways instead of squeezing.
    @ViewBuilder
    private var chips: some View {
        if headless {
            chipRow
        } else {
            ScrollView(.horizontal, showsIndicators: false) { chipRow.padding(.vertical, 1) }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            CalendarFilterChip(title: "All", account: nil, on: model.filter.isEmpty) { model.showAll() }
            ForEach(model.accounts) { account in
                CalendarFilterChip(title: account.tag, account: account, on: !model.filter.isEmpty && model.filter.contains(account.id)) {
                    model.toggle(account.id)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            CalendarNote(symbol: "hourglass", title: "Fetching your calendars…", line: "This takes a moment the first time.")
        case .noAccounts:
            CalendarNote(symbol: "person.crop.circle.badge.plus", title: "No calendars connected yet",
                         line: "Connect a Google account and every meeting lands here, and on your widgets.",
                         button: ("Connect an account", { MainWindowController.openAccounts() }))
        case .failed:
            CalendarNote(symbol: "exclamationmark.triangle", title: "I couldn\u{2019}t read your calendars just now",
                         line: "Try Sync now. If it keeps happening, the Accounts page says which account needs you.")
        case .ready:
            if model.days.isEmpty {
                CalendarNote(symbol: "sun.max", title: "Nothing booked for two months",
                             line: model.filter.isEmpty ? "Suspicious. Enjoy it while it lasts." : "Nothing on these calendars. Try All.")
            } else {
                agenda
            }
        }
    }

    private var agenda: some View {
        let style = Self.rowStyle
        let directory = model.accountDirectory
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.days.enumerated()), id: \.element.day) { index, day in
                DayBanner(day: day.day, continued: false, count: day.events.filter { !$0.allDay }.count,
                          now: model.now, style: style)
                    .padding(.top, index == 0 ? 0 : 14)
                    .padding(.bottom, 4)
                ForEach(Array(day.events.enumerated()), id: \.element.r) { i, event in
                    PeekRow(meeting: event.widgetMeeting(index: i + 1, directory: directory), now: model.now, style: style) {
                        PeekController.shared.showEvent(r: event.r)
                    }
                    .opacity(event.end <= model.now ? 0.45 : 1)
                }
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
    }
}

private struct CalendarFilterChip: View {
    let title: String
    let account: DirectoryAccount?
    let on: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let account {
                if let logo = account.logo {
                    Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: 15, height: 15).background(AppTheme.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Circle().fill(Color(hex: account.color)).frame(width: 8, height: 8)
                }
            }
            Text(title).font(AppTheme.font(12, on ? .bold : .medium))
        }
        .foregroundStyle(on ? AppTheme.accentText : AppTheme.text)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(on ? AppTheme.accent : Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(on ? Color.clear : AppTheme.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: action)
    }
}

/// Empty / loading / no-accounts / error states, in the app's voice.
private struct CalendarNote: View {
    let symbol: String
    let title: String
    let line: String
    var button: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(AppTheme.accent)
                .frame(width: 64, height: 64).background(Circle().fill(AppTheme.accentSoft))
            Text(title).font(AppTheme.font(18, .heavy)).foregroundStyle(AppTheme.text)
            Text(line).font(AppTheme.font(13)).foregroundStyle(AppTheme.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 400)
            if let button {
                Button(button.0, action: button.1).buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}
