import AppKit
import SwiftUI

// Event Peek and Day Peek: the dark app look (AppTheme, D-008) at 420 pt wide, at most ~560 tall. Plain
// SwiftUI only (no List/Form/Menu), so the live panel and the headless renders draw the same pixels.

/// The rounded card every Peek sits in.
struct PeekCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(18)
            .frame(width: PeekPlacement.width, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.background))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

struct PeekCloseButton: View {
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hover ? AppTheme.text : AppTheme.text2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Close (Esc)")
        .accessibilityLabel(Text("Close"))
    }
}

/// Logo (paper plate, so dark marks stay visible) or the account's colour, then its tag.
struct PeekAccountChip: View {
    let account: DirectoryAccount?
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            if let logo = account?.logo {
                Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .background(AppTheme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else {
                Circle().fill(Color(hex: account?.color ?? 0x8FB4C4)).frame(width: size * 0.55, height: size * 0.55)
                    .frame(width: size, height: size)
            }
            Text(account?.tag ?? "Calendar")
                .font(AppTheme.font(12, .bold)).foregroundStyle(AppTheme.text)
        }
    }
}

struct EventPeekView: View {
    @ObservedObject var model: EventPeekModel
    /// The Join with Fathom wait redraws the Peek (its panel replaces Join).
    @ObservedObject private var fathom: FathomSession
    /// Yaya's Murmur coming or going redraws the Peek (D-046).
    @ObservedObject private var murmur: MurmurSession

    init(model: EventPeekModel) {
        _model = ObservedObject(wrappedValue: model)
        _fathom = ObservedObject(wrappedValue: model.fathom)
        _murmur = ObservedObject(wrappedValue: model.murmur)
    }

    var body: some View {
        let e = model.event
        VStack(alignment: .leading, spacing: 14) {
            header(e)
            VStack(alignment: .leading, spacing: 6) {
                Text(e.title)
                    .font(AppTheme.font(19, .heavy)).foregroundStyle(AppTheme.text)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text(PeekText.when(e))
                    .font(AppTheme.font(13, .medium)).foregroundStyle(AppTheme.text2)
                if e.clashes {
                    Label("Overlaps another meeting", systemImage: "exclamationmark.triangle.fill")
                        .font(AppTheme.font(11.5, .semibold)).foregroundStyle(AppTheme.warn)
                }
            }
            if let place = e.location, !place.isEmpty {
                detailRow("mappin.and.ellipse", place)
            }
            if model.canJoin && !fathom.isPending(e.r) {
                if model.recorder != nil { splitJoin } else { joinButton }
            }
            if let recorder = model.recorder {
                recorderSection(recorder)
            } else if let target = model.fathomTarget {
                fathomSection(target)
            }
            if model.canReply {
                replyRow
            } else if model.isOrganizer {
                detailRow("person.crop.circle.badge.checkmark", "You\u{2019}re the organiser")
            }
            if !model.guests.isEmpty { guestsSection }
            if let notes = PeekText.notesPreview(e.notes) { notesSection(notes) }
            if e.webURL != nil { footer }
        }
        .overlay(alignment: .bottom) { toast }
    }

    private func header(_ e: CalendarEvent) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let back = model.onBack {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text(model.backTitle ?? "Back").font(AppTheme.font(12, .semibold))
                    }
                    .foregroundStyle(AppTheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            PeekAccountChip(account: e.accountIds.first.flatMap(model.directory.account))
            if let also = model.alsoOn {
                Text(also).font(AppTheme.font(11.5, .semibold)).foregroundStyle(AppTheme.text2).lineLimit(1)
            } else {
                Text(e.calendarName).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            PeekCloseButton(action: model.onClose)
        }
    }

    private func detailRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.text3)
                .frame(width: 16)
            Text(text).font(AppTheme.font(13)).foregroundStyle(AppTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var joinButton: some View {
        Button { model.join() } label: {
            HStack(spacing: 8) {
                Image(systemName: "video.fill").font(.system(size: 13, weight: .bold))
                Text(model.joinProvider.map { "Join \($0)" } ?? "Join meeting").font(AppTheme.font(14.5, .heavy))
            }
            .foregroundStyle(AppTheme.accentText)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Capsule().fill(AppTheme.accent))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the video call"))
    }

    /// With Yaya's Murmur on this Mac (D-046): Join keeps its word and gains "▾", every way to join this meeting.
    private var splitJoin: some View {
        JoinSplitButton(title: model.joinProvider.map { "Join \($0)" } ?? "Join meeting", filled: true, height: 40,
                        fontSize: 14.5, join: { model.join() }, menu: { showMenu() })
    }

    private func showMenu() {
        JoinMenuPresenter.show(model.joinMenu) { model.perform($0) }
    }

    /// The account's recorder under Join; a Fathom wait started from the menu shows here whatever the recorder.
    @ViewBuilder
    private func recorderSection(_ recorder: Recorder) -> some View {
        if (recorder == .fathom || fathom.isPending(model.event.r)), let target = model.fathomTarget {
            fathomSection(target)
        } else if model.canJoin && recorder == .murmur {
            MurmurJoinControls(mark: model.murmurMark, height: 38) { model.joinWithMurmur(nil) }
        } else if model.canJoin && recorder == .ask {
            AskRecorderButton(height: 38) { showMenu() }
        }
    }

    /// Join with Fathom and, for a meeting on more than one linked account, "Records to" (D-045).
    private func fathomSection(_ target: FathomTarget) -> some View {
        let targets = model.fathomTargets
        let picker = targets.count > 1 && !fathom.isPending(model.event.r)
        return VStack(alignment: .leading, spacing: 8) {
            FathomControls(session: model.fathom, event: model.event, target: target, directory: model.directory,
                           height: 38, showStatus: !(picker && fathom.check(target) == .ready),
                           join: { model.joinWithFathom() }, after: { model.fathomDone($0) })
            if picker {
                FathomRecordsTo(targets: targets, chosen: target) { model.fathomChoice = $0 }
            }
        }
    }

    private var replyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Going?").font(AppTheme.font(13, .bold)).foregroundStyle(AppTheme.text)
                Spacer()
                Text(model.sending != nil ? "Sending your reply…" : PeekText.responseWord(model.response))
                    .font(AppTheme.font(11.5, .medium)).foregroundStyle(AppTheme.text3)
            }
            HStack(spacing: 8) {
                replyButton("Yes", .accepted, "checkmark")
                replyButton("Maybe", .tentative, "questionmark")
                replyButton("No", .declined, "xmark")
            }
        }
    }

    private func replyButton(_ title: String, _ value: CalendarEvent.Response, _ symbol: String) -> some View {
        let selected = model.response == value
        return Button {
            Task { await model.rsvp(value) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .heavy))
                Text(title).font(AppTheme.font(13, .bold))
            }
            .foregroundStyle(selected ? AppTheme.accentText : AppTheme.text)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(Capsule().fill(selected ? AppTheme.accent : Color.white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : AppTheme.stroke, lineWidth: 1))
            .opacity(model.sending == value ? 0.7 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.sending != nil)
        .accessibilityLabel(Text("Going: \(title)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(Text(selected ? "Your current answer" : "Sends this answer to the organiser"))
    }

    private var guestsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.guests.count == 1 ? "1 guest" : "\(model.guests.count) guests")
                .font(AppTheme.font(11, .bold)).tracking(0.5).foregroundStyle(AppTheme.text3)
            ForEach(Array(model.guestsShown.enumerated()), id: \.offset) { _, guest in
                HStack(spacing: 8) {
                    responseIcon(guest.response)
                    Text(guest.name ?? guest.email).font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text).lineLimit(1)
                    if guest.isOrganizer {
                        Text("organiser").font(AppTheme.font(10.5, .semibold)).foregroundStyle(AppTheme.text3)
                    }
                    Spacer(minLength: 0)
                }
            }
            if model.moreGuests > 0 {
                Text("and \(model.moreGuests) more").font(AppTheme.font(12, .medium)).foregroundStyle(AppTheme.text2)
                    .padding(.leading, 24)
            }
        }
    }

    private func responseIcon(_ r: CalendarEvent.Response) -> some View {
        let (symbol, color): (String, Color) = {
            switch r {
            case .accepted: return ("checkmark.circle.fill", AppTheme.good)
            case .tentative: return ("questionmark.circle.fill", AppTheme.warn)
            case .declined: return ("xmark.circle.fill", AppTheme.bad)
            case .needsAction: return ("circle.dashed", AppTheme.text3)
            }
        }()
        return Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).frame(width: 16)
    }

    private func notesSection(_ notes: String) -> some View {
        Text(notes)
            .font(AppTheme.font(12.5)).foregroundStyle(AppTheme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private var footer: some View {
        Button { model.openInGoogle() } label: {
            HStack(spacing: 5) {
                Text("Open in Google Calendar").font(AppTheme.font(12.5, .bold))
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(AppTheme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the event in your browser"))
    }

    @ViewBuilder
    private var toast: some View {
        if let text = model.toast {
            Text(text)
                .font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(AppTheme.bad.opacity(0.92)))
                .padding(.bottom, -6)
                .onTapGesture { model.toast = nil }
        }
    }
}

struct DayPeekView: View {
    @ObservedObject var model: DayPeekModel
    let onSelect: (CalendarEvent) -> Void
    let onClose: () -> Void

    static var rowStyle: WidgetStyle {
        var s = WidgetStyle()
        s.look = .ink
        s.scaleOverride = 1.12
        return s
    }

    var body: some View {
        let style = Self.rowStyle
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.title).font(AppTheme.font(19, .heavy)).foregroundStyle(DayName.title(model.day, now: model.now) == "Today" ? AppTheme.accent : AppTheme.text)
                Text(model.subtitle).font(AppTheme.font(14, .semibold)).foregroundStyle(AppTheme.text2)
                Spacer(minLength: 8)
                PeekCloseButton(action: onClose)
            }
            Text(model.failed ? "I couldn\u{2019}t read that day just now." : model.countText)
                .font(AppTheme.font(12, .medium)).foregroundStyle(AppTheme.text3)
            if model.events.isEmpty {
                Text("A clear day. Enjoy it.")
                    .font(AppTheme.font(13)).foregroundStyle(AppTheme.text2)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(zip(model.events, model.rows()).enumerated()), id: \.offset) { _, pair in
                        PeekRow(meeting: pair.1, now: model.now, style: style) { onSelect(pair.0) }
                    }
                }
            }
        }
    }
}

/// A widget meeting row at window scale, clickable as a whole (opens the Event Peek).
struct PeekRow: View {
    let meeting: WidgetMeeting
    let now: Date
    let style: WidgetStyle
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        WidgetMeetingRow(meeting: meeting, now: now, style: style)
            .environment(\.plainLinks, true)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hover = $0 }
            .ycAccessibleButton(A11yText.meeting(meeting, now: now, use24Hour: style.use24Hour).label,
                                value: A11yText.meeting(meeting, now: now, use24Hour: style.use24Hour).value,
                                hint: "Opens the meeting details", action: action)
    }
}
