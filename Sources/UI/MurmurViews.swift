import SwiftUI

// Yaya's Murmur on the app's own surfaces (D-046): Join with its "▾" menu, Join with Yaya's Murmur, "Join and
// record…", the badges from Murmur's marks, the Event Peek's Live Helper row, the account card's "Record with" and
// Settings → Yaya's Murmur. Nothing here draws while Murmur isn't on this Mac. The logic lives in MurmurModels.swift
// and RecorderModels.swift.

// MARK: - Join and its menu

enum JoinMenuPresenter {
    /// The Join menu at the pointer (a real NSMenu, with Murmur's Home lab / MacBook as a submenu).
    @MainActor
    static func show(_ items: [JoinMenu.Item], perform: @escaping (JoinMenu.Entry) -> Void) {
        AccountsKit.MenuPresenter.show(items.map { convert($0, perform) })
    }

    @MainActor
    private static func convert(_ item: JoinMenu.Item, _ perform: @escaping (JoinMenu.Entry) -> Void) -> AccountsKit.PopUpMenuButton.Item {
        if item.isSeparator { return .separator }
        let entry = item.entry
        return AccountsKit.PopUpMenuButton.Item(title: item.title, action: { if let entry { perform(entry) } },
                                                children: item.children.map { convert($0, perform) })
    }
}

/// Join with a "▾" beside it: the main part joins (as Join always did), the "▾" offers every recorder for this one
/// meeting.
struct JoinSplitButton: View {
    let title: String
    /// The popover's loud Join (within 30 min) and the Peek's Join are filled with the accent.
    var filled: Bool
    var height: CGFloat = 36
    var fontSize: CGFloat = 14
    let join: () -> Void
    let menu: () -> Void

    var body: some View {
        let fg = filled ? AppTheme.accentText : AppTheme.text
        HStack(spacing: 0) {
            Button(action: join) {
                HStack(spacing: 8) {
                    Image(systemName: "video.fill").font(.system(size: fontSize - 1.5, weight: .bold))
                    Text(title).font(AppTheme.font(fontSize, .heavy)).lineLimit(1)
                }
                .frame(maxWidth: .infinity).frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Opens the call (\(JoinHotkey.display) does the same from anywhere)")
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text("Opens the video call"))
            Rectangle().fill(fg.opacity(0.28)).frame(width: 1, height: height * 0.5)
            Button(action: menu) {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .heavy))
                    .frame(width: 42).frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("More ways to join: with Fathom, with Yaya\u{2019}s Murmur, or just join")
            .accessibilityLabel(Text("More ways to join"))
        }
        .foregroundStyle(fg)
        .background(Capsule().fill(filled ? AppTheme.accent : Color.white.opacity(0.09)))
        .overlay(Capsule().strokeBorder(filled ? Color.clear : AppTheme.stroke, lineWidth: 1))
        .clipShape(Capsule())
    }
}

/// Join with Yaya's Murmur and the line under it.
struct MurmurJoinControls: View {
    let mark: MurmurMark?
    var height: CGFloat = 36
    /// The popover card draws the line itself when the button shares its row with "✦ Live Helper" (D-049).
    var showsStatus = true
    let join: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            RecorderJoinButton(title: RecorderText.joinTitle(.murmur), height: height, glyph: .murmur, action: join)
                .help("Opens the call and asks Yaya\u{2019}s Murmur on this Mac to listen")
                .accessibilityHint(Text("Opens the video call and arms Yaya\u{2019}s Murmur for it"))
            if showsStatus { RecorderStatusLine(symbol: "waveform", text: RecorderText.murmurStatus(mark)) }
        }
    }
}

/// The line under a recorder's button (Join with Yaya's Murmur, Join with Live Helper).
struct RecorderStatusLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(AppTheme.font(11.5, .medium)).foregroundStyle(AppTheme.text2)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// "✦ Join with Live Helper" and the line under it (D-049): the popover card's recorder button for a meeting Yaya's
/// Murmur marked Live Helper, in Join with Fathom's quiet capsule with the badge's lime symbol.
struct LiveHelperJoinControls: View {
    let mark: MurmurMark?
    var height: CGFloat = 36
    let join: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            RecorderJoinButton(title: RecorderText.liveHelperJoin, height: height, glyph: .liveHelper, action: join)
                .help("Opens the call; Yaya\u{2019}s Murmur listens on this MacBook and brings this meeting\u{2019}s Live Helper chat")
                .accessibilityHint(Text("Opens the video call with Yaya\u{2019}s Murmur and this meeting\u{2019}s Live Helper chat"))
            RecorderStatusLine(symbol: "waveform", text: RecorderText.liveHelperStatus(mark))
        }
    }
}

/// The compact "✦ Live Helper" (D-049) beside the popover card's recorder button for a meeting Murmur hasn't marked:
/// opens Murmur's helper setup for it. Murmur owns the mark; the card turns into Join with Live Helper on its ping.
struct LiveHelperSetUpButton: View {
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: MurmurBadge.liveHelper.symbol).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(hex: MurmurBadge.lime))
                Text(RecorderText.liveHelperSetUp).font(AppTheme.font(12.5, .bold)).lineLimit(1)
            }
            .foregroundStyle(AppTheme.text)
            .padding(.horizontal, 12).frame(height: height)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(AppTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Set up a Live Helper for this meeting in Yaya\u{2019}s Murmur")
        .accessibilityLabel(Text("Set up Live Helper"))
        .accessibilityHint(Text("Opens this meeting\u{2019}s Live Helper in Yaya\u{2019}s Murmur"))
    }
}

/// The second button's shape (as Join with Fathom's): a quiet capsule with the recorder's glyph.
struct RecorderJoinButton: View {
    enum Glyph { case murmur, ask, liveHelper }
    let title: String
    var height: CGFloat = 36
    let glyph: Glyph
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                switch glyph {
                case .murmur: RingedPlanet(color: AppTheme.accent).frame(width: 16, height: 12)
                case .ask: Image(systemName: "record.circle").font(.system(size: 12.5, weight: .bold)).foregroundStyle(AppTheme.accent)
                case .liveHelper:
                    Image(systemName: MurmurBadge.liveHelper.symbol).font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color(hex: MurmurBadge.lime))
                }
                // Beside "✦ Live Helper" (D-049) the row is narrower: a long title shrinks a little rather than cut.
                Text(title).font(AppTheme.font(14, .heavy)).lineLimit(1).minimumScaleFactor(0.82)
                if glyph == .ask {
                    Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(AppTheme.text2)
                }
            }
            .foregroundStyle(AppTheme.text)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(Capsule().fill(Color.white.opacity(0.09)))
            .overlay(Capsule().strokeBorder(AppTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

/// "Join and record…" for an account that asks each time: the Join menu.
struct AskRecorderButton: View {
    var height: CGFloat = 36
    let menu: () -> Void

    var body: some View {
        RecorderJoinButton(title: RecorderText.joinTitle(.ask), height: height, glyph: .ask, action: menu)
            .help("Choose how this meeting is recorded")
            .accessibilityHint(Text("Shows the ways to join and record this meeting"))
    }
}

// MARK: - Badges

/// One badge: Murmur's lime or pink, used for these badges only.
struct MurmurBadgeChip: View {
    let badge: MurmurBadge

    var body: some View {
        let tint = Color(hex: badge.hex)
        HStack(spacing: 3) {
            Image(systemName: badge.symbol).font(.system(size: 8.5, weight: .bold))
            Text(badge.title).font(AppTheme.font(10, .bold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).frame(height: 17)
        .background(Capsule().fill(tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.42), lineWidth: 0.7))
    }
}

struct MurmurBadgeRow: View {
    let badges: [MurmurBadge]

    var body: some View {
        if !badges.isEmpty {
            HStack(spacing: 5) {
                ForEach(badges) { MurmurBadgeChip(badge: $0) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Yaya\u{2019}s Murmur: " + badges.map(\.title).joined(separator: ", ")))
        }
    }
}

// MARK: - The Event Peek's Live Helper

/// "Live Helper for this meeting": the switch shows Murmur's mark; flipping it, or Set up…, opens Murmur's helper
/// setup for this event, where Murmur makes the change (it owns the marks; the Peek redraws on its ping).
struct LiveHelperRow: View {
    let mark: MurmurMark?
    let openHelper: () -> Void
    let openNotes: () -> Void

    var body: some View {
        let on = mark?.helper != nil
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.text3)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Helper for this meeting").font(AppTheme.font(13, .semibold)).foregroundStyle(AppTheme.text)
                    Text(on ? "\(mark?.helper?.title ?? "On") \u{00B7} set in Yaya\u{2019}s Murmur" : "Off \u{00B7} Yaya\u{2019}s Murmur sets it up")
                        .font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button("Set up\u{2026}", action: openHelper)
                    .buttonStyle(AccountsKit.LinkButton())
                    .accessibilityHint(Text("Opens this meeting\u{2019}s Live Helper in Yaya\u{2019}s Murmur"))
                ShellSwitch(isOn: Binding(get: { on }, set: { _ in openHelper() }), label: "Live Helper for this meeting")
            }
            if mark?.status == .notesReady {
                Button(action: openNotes) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text").font(.system(size: 10.5, weight: .bold))
                        Text("Open the notes in Yaya\u{2019}s Murmur").font(AppTheme.font(12, .semibold))
                    }
                    .foregroundStyle(AppTheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 25)
            }
        }
    }
}

// MARK: - Accounts

/// The account card's recording rows (shown under the switches): "Record with" while Murmur is on this Mac, then the
/// Fathom account link while Fathom is (D-045). Without Murmur it is exactly the Fathom row it was.
struct AccountRecorderSection: View {
    @ObservedObject var recorders: RecorderChoicesModel
    @ObservedObject var links: FathomLinksModel
    @ObservedObject private var murmur: MurmurSession
    let accountId: UUID
    let email: String

    init(recorders: RecorderChoicesModel, links: FathomLinksModel, accountId: UUID, email: String) {
        _recorders = ObservedObject(wrappedValue: recorders)
        _links = ObservedObject(wrappedValue: links)
        _murmur = ObservedObject(wrappedValue: recorders.murmur)
        self.accountId = accountId
        self.email = email
    }

    var body: some View {
        if murmur.installed {
            VStack(alignment: .leading, spacing: 12) {
                RecorderAccountRow(model: recorders, links: links, accountId: accountId)
                FathomAccountRow(model: links, accountId: accountId, email: email, title: "Fathom account")
            }
        } else {
            FathomAccountRow(model: links, accountId: accountId, email: email)
        }
    }
}

/// "Record with: Fathom / Yaya's Murmur / Ask each time / Off".
struct RecorderAccountRow: View {
    @ObservedObject var model: RecorderChoicesModel
    let links: FathomLinksModel
    let accountId: UUID

    var body: some View {
        let resolved = model.resolved(accountId)
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(AppTheme.stroke).frame(height: 1)
            HStack(alignment: .center, spacing: 10) {
                // The Fathom row's dot column (8 pt), so both rows' words line up; the planet overhangs it a little.
                glyph(resolved).frame(width: 14, height: 11).frame(width: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record with").font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text)
                    Text(model.detail(accountId)).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { showMenu() } label: {
                    HStack(spacing: 4) {
                        Text(resolved.title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(AccountsKit.SecondaryButton(compact: true, tint: AppTheme.text))
                .accessibilityLabel(Text("Record with: \(resolved.title)"))
            }
        }
    }

    @ViewBuilder private func glyph(_ r: Recorder) -> some View {
        switch r {
        case .fathom: Circle().fill(AppTheme.bad).frame(width: 8, height: 8)
        case .murmur: RingedPlanet(color: AppTheme.accent)
        case .ask: Image(systemName: "record.circle").font(.system(size: 10, weight: .bold)).foregroundStyle(AppTheme.accent)
        case .off: Circle().fill(AppTheme.text3).frame(width: 8, height: 8)
        }
    }

    private func showMenu() {
        let id = accountId
        AccountsKit.MenuPresenter.show([
            AccountsKit.PopUpMenuButton.Item(title: "Fathom", enabled: model.fathom.installed) {
                model.set(.fathom, for: id, links: links)
            },
            AccountsKit.PopUpMenuButton.Item(title: "Yaya\u{2019}s Murmur") { model.set(.murmur, for: id) },
            AccountsKit.PopUpMenuButton.Item(title: "Ask each time") { model.set(.ask, for: id) },
            .separator,
            AccountsKit.PopUpMenuButton.Item(title: "Off") { model.set(.off, for: id) },
        ])
    }
}

// MARK: - Settings

/// Settings → Yaya's Murmur (D-046), shown while Murmur is on this Mac: what it reads, Murmur's state, and the
/// ⌃⌥J switch (here instead of the Fathom card, since it now follows each account's recorder).
struct SettingsMurmurCard: View {
    @ObservedObject var recorders: RecorderChoicesModel
    @ObservedObject var links: FathomLinksModel
    @ObservedObject private var murmur: MurmurSession
    @Environment(\.headlessRender) private var headless

    init(recorders: RecorderChoicesModel, links: FathomLinksModel) {
        _recorders = ObservedObject(wrappedValue: recorders)
        _links = ObservedObject(wrappedValue: links)
        _murmur = ObservedObject(wrappedValue: recorders.murmur)
    }

    var body: some View {
        if murmur.installed {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Yaya\u{2019}s Murmur").font(AppTheme.font(17, .heavy)).foregroundStyle(AppTheme.text)
                    Text("Join with Yaya\u{2019}s Murmur opens the call and asks Yaya\u{2019}s Murmur on this Mac to listen. Each account picks its recorder on its card in Accounts, and the \u{25BE} beside Join offers every recorder for one meeting. The badges come from a small file Yaya\u{2019}s Murmur keeps on this Mac; I only read it, and nothing leaves this Mac.")
                        .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                ShellCard(padding: 0) {
                    VStack(spacing: 0) {
                        row(title: "Yaya\u{2019}s Murmur on this Mac", detail: murmur.statusLine) {
                            Button("Check again") { recorders.refresh() }.buttonStyle(AccountsKit.LinkButton())
                        }
                        Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 18)
                        row(title: "\(JoinHotkey.display) records with the account\u{2019}s recorder",
                            detail: "On, \(JoinHotkey.display) joins with the recorder the meeting\u{2019}s account chose: Fathom or Yaya\u{2019}s Murmur, and \u{201C}Ask each time\u{201D} opens the meeting to ask. Off, it only joins.") {
                            ShellSwitch(isOn: Binding(get: { links.hotkeyRecords }, set: { links.setHotkeyRecords($0) }),
                                        label: "Control Option J records with the meeting\u{2019}s recorder")
                        }
                    }
                }
            }
            .onAppear { if !headless { recorders.refresh() } }
        }
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
