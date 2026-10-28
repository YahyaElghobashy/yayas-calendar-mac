import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The composer: its own window in the app's dark look. From (account chips), To / Cc / Bcc (plain
/// comma entry), Subject, and the body in an NSTextView (undo, spell check). ⌘↵ sends; for 5 s the
/// toast says "Sending… Undo". With "Ask before sending to other people" on (D-023) the footer says
/// who I'll check with you about, and Send brings up the approval card over the draft (every time).
struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    @Environment(\.headlessRender) private var headless
    @Environment(\.undoManager) private var undoManager
    @Local private var confirmPlain = false

    var body: some View {
        ZStack {
            draft
                .accessibilityHidden(model.isConfirming)
                .allowsHitTesting(!model.isConfirming)
            if let approval = model.approval {
                SendApprovalOverlay(approval: approval, account: model.fromAccount,
                                    send: { Task { await model.approveIfArmed() } }, cancel: model.cancelApproval)
                    .transition(.opacity)
            }
        }
        .animation(headless ? nil : .easeOut(duration: 0.14), value: model.isConfirming)
        .environment(\.colorScheme, .dark)
    }

    private var draft: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.title).font(AppTheme.font(18, .heavy)).foregroundStyle(AppTheme.text).lineLimit(1)
                fields.disabled(model.isConfirming)
            }
            .padding(.horizontal, 22).padding(.top, headless ? 22 : 34).padding(.bottom, model.format == .rich ? 4 : 12)
            if model.format == .rich {
                // D-042: the toolbar on the dark chrome, then the light sheet (what recipients see).
                ComposerToolbar(model: model, attach: headless ? {} : chooseFiles)
                    .padding(.horizontal, 20).padding(.bottom, 6)
                    .zIndex(1)
                ComposerSheet(model: model, editable: !model.isSending && !model.isConfirming, accessible: !model.isConfirming,
                              toggleRich: toggleRich, chooseFiles: chooseFiles, attachFiles: attachFiles)
                    .padding(.horizontal, 22)
            } else {
                PlainModeLine(enabled: !model.isSending && !model.isConfirming, useFormatting: model.togglePlainText, attach: chooseFiles)
                    .padding(.horizontal, 24).padding(.top, -4).padding(.bottom, 6)
                ComposerBody(text: Binding(get: { model.body }, set: { model.body = $0 }), editable: !model.isSending && !model.isConfirming,
                             accessible: !model.isConfirming, toggleRich: model.togglePlainText,
                             attachFiles: attachFiles, attachImage: { data, name, _ in model.attach(imageData: data, name: name, asFile: true) },
                             attachRequest: chooseFiles)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.card))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
                    .padding(.horizontal, 22)
            }
            // The files, the size it comes to, the 10 MB warning or the 25 MB problem.
            AttachmentTray(model: model, editable: !model.isSending && !model.isConfirming)
                .padding(.horizontal, 22).padding(.top, 10)
                .disabled(model.isConfirming)
            // Behind the card nothing should look pressable (a click there is Cancel): the footer steps out.
            footer.padding(.horizontal, 22).padding(.vertical, 14)
                .opacity(model.isConfirming ? 0 : 1)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(AppTheme.background)
        // A drop anywhere outside the body (the fields, the tray) always attaches.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !model.isSending, !model.isConfirming else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { attachFiles([url]) }
                }
            }
            return true
        }
        .overlay(alignment: .bottom) {
            MailToastView(center: model.toasts).padding(.bottom, 64)
        }
        .alert("Make this plain text?", isPresented: Binding(get: { confirmPlain && !headless }, set: { confirmPlain = $0 })) {
            Button("Make Plain Text") { model.togglePlainText() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bold, colours, lists and the other formatting go. The words stay.")
        }
    }

    /// 📎, ⇧⌘A, Attach Files…: several files at once; folders and packages are refused by the model.
    private func chooseFiles() {
        guard !headless, !model.isSending, !model.isConfirming else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Attach"
        panel.message = "Choose files to attach."
        panel.begin { response in
            guard response == .OK else { return }
            attachFiles(panel.urls)
        }
    }

    /// Attaches and registers Undo (adding and removing attachments are undoable on the window's undo manager).
    private func attachFiles(_ urls: [URL]) {
        let before = Set(model.attachments.map(\.id))
        model.attach(urls: urls)
        let added = model.attachments.filter { !before.contains($0.id) }.map(\.id)
        guard !added.isEmpty, let undoManager else { return }
        undoManager.registerUndo(withTarget: model) { m in for id in added { m.removeAttachment(id) } }
        undoManager.setActionName(added.count == 1 ? "Attach File" : "Attach Files")
    }

    /// ⇧⌘T: Make Plain Text asks first when formatting would be lost; Make Rich Text never does.
    private func toggleRich() {
        if model.format == .rich, model.plainSwitchLosesFormatting {
            confirmPlain = true
        } else {
            model.togglePlainText()
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldRow(label: "From") {
                HStack(spacing: 6) {
                    ForEach(model.accounts) { account in
                        FromChip(account: account, selected: model.from == account.id) { model.changeFrom(account.id) }
                    }
                    Spacer(minLength: 0)
                }
            }
            divider
            FieldRow(label: "To") {
                HStack(spacing: 8) {
                    ComposerTextField(placeholder: "name@example.com, another@example.com", text: $model.to)
                    if !model.showCcBcc {
                        Button("Cc / Bcc") { model.showCcBcc = true }
                            .buttonStyle(.plain)
                            .font(AppTheme.font(11.5, .bold)).foregroundStyle(AppTheme.accent)
                    }
                }
            }
            if model.showCcBcc {
                divider
                FieldRow(label: "Cc") { ComposerTextField(placeholder: "", text: $model.cc) }
                divider
                FieldRow(label: "Bcc") { ComposerTextField(placeholder: "", text: $model.bcc) }
            }
            divider
            FieldRow(label: "Subject") { ComposerTextField(placeholder: "What\u{2019}s it about?", text: $model.subject, bold: true) }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
    }

    private var divider: some View { Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 76) }

    private var footer: some View {
        HStack(spacing: 12) {
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.warn)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            } else if model.isSending {
                Text("On its way in a few seconds. Changed your mind? Undo.")
                    .font(AppTheme.font(12)).foregroundStyle(AppTheme.text2)
            } else if let hint = model.approvalHint {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AppTheme.accent.opacity(0.85))
                    Text("\(Text(hint).foregroundStyle(AppTheme.text2))  \(Text("\u{2318}\u{21A9} sends").font(AppTheme.font(11.5, .medium)).foregroundStyle(AppTheme.text3))")
                        .font(AppTheme.font(12))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("\u{2318}\u{21A9} sends").font(AppTheme.font(11.5, .medium)).foregroundStyle(AppTheme.text3)
            }
            Spacer(minLength: 8)
            Button("Discard") { model.onClose() }
                .buttonStyle(.plain)
                .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                .disabled(model.isSending || model.isConfirming)
                .opacity(model.isSending ? 0.4 : 1)
            Button {
                Task { await model.send() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill").font(.system(size: 11.5, weight: .bold))
                    Text(model.isSending ? "Sending\u{2026}" : "Send")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isSending || model.isConfirming)
            .opacity(model.isSending ? 0.6 : 1)
        }
    }
}

// MARK: - Approval card (D-023)

/// The dimmed draft and, on top, the approval card. A click on the dimmed part is Cancel.
struct SendApprovalOverlay: View {
    let approval: SendApproval
    let account: DirectoryAccount?
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.62)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: cancel)
                    .accessibilityHidden(true)
                // Never taller than the window (the composer goes down to 480 pt): when everyone doesn't fit,
                // the people list scrolls and Send stays in view.
                SendApprovalCard(approval: approval, account: account, send: send, cancel: cancel)
                    .frame(maxHeight: max(0, proxy.size.height - 48))
                    .padding(24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// "Send to Juniper Vale?": everyone other than you who gets it (all of them: a scrolling list when they
/// don't fit, Cc and Bcc tagged), From and the subject, Cancel and Send. Return sends, Esc goes back (the
/// composer window's key monitor; the shortcuts here are the fallback). In the Peek card's look: navy
/// gradient, 18 pt corners, hairline, soft shadow.
struct SendApprovalCard: View {
    let approval: SendApproval
    let account: DirectoryAccount?
    let send: () -> Void
    let cancel: () -> Void
    /// VoiceOver lands on the title when the card appears.
    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(\.headlessRender) private var headless

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(AppTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(AppTheme.accentSoft))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    // ImageRenderer drops a view carrying `.accessibilityFocused` (the window draws it): headless
                    // renders get the plain title.
                    if headless {
                        title
                    } else {
                        title.accessibilityFocused($titleFocused)
                    }
                    Text(approval.subtitle)
                        .font(AppTheme.font(12.5, .medium)).foregroundStyle(AppTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // Everyone fits → a plain list; otherwise the list takes the room that's left and scrolls.
            ViewThatFits(in: .vertical) {
                people(scrolls: false)
                people(scrolls: true)
            }
            details
            buttons
        }
        .padding(22)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.background))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AppTheme.strokeStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { titleFocused = true }
    }

    private var title: some View {
        Text(approval.title)
            .font(AppTheme.font(19, .heavy)).foregroundStyle(AppTheme.text)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func people(scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("WHO GETS IT")
                    .font(AppTheme.font(10.5, .bold)).tracking(0.5).foregroundStyle(AppTheme.text3)
                Spacer(minLength: 8)
                if scrolls {
                    Text("Scroll to see all \(approval.people.count)")
                        .font(AppTheme.font(10.5, .semibold)).foregroundStyle(AppTheme.text3)
                        .accessibilityHidden(true)
                }
            }
            Group {
                if scrolls {
                    // The last rows fade out at the bottom edge: there's more below.
                    ShellScroll { rows.padding(.bottom, 14) }
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.84),
                                                     .init(color: .black.opacity(0), location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                } else {
                    rows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(approval.people.enumerated()), id: \.offset) { index, person in
                if index > 0 { Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 46) }
                PersonRow(person: person)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            detail("From") {
                HStack(spacing: 6) {
                    MailLogoBadge(account: account, size: 15)
                    Text(approval.fromTag).font(AppTheme.font(12.5, .bold)).foregroundStyle(AppTheme.text)
                    Text(approval.fromAddress).font(AppTheme.font(12)).foregroundStyle(AppTheme.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("From \(approval.fromTag), \(approval.fromAddress)"))
            }
            Rectangle().fill(AppTheme.stroke).frame(height: 1).padding(.leading, 76)
            detail("Subject") {
                Text(approval.subjectLine).font(AppTheme.font(12.5, .semibold))
                    .foregroundStyle(approval.subject.isEmpty ? AppTheme.text3 : AppTheme.text)
                    .lineLimit(1).truncationMode(.tail)
                    .accessibilityLabel(Text("Subject \(approval.subjectLine)"))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.stroke, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detail<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3)
                .frame(width: 54, alignment: .leading)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(minHeight: 36)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Text("Return sends  \u{00B7}  Esc goes back")
                .font(AppTheme.font(11.5, .medium)).foregroundStyle(AppTheme.text3)
                .lineLimit(1)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Button("Cancel", action: cancel)
                .buttonStyle(.plain)
                .font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text2)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint(Text("Keeps your draft as it is"))
            Button(action: send) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill").font(.system(size: 11.5, weight: .bold))
                    Text("Send")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(Text(approval.people.count == 1 ? "Send to \(approval.people[0].label)"
                                                                : "Send to \(approval.people.count) people"))
            .accessibilityHint(Text("Sends now; you can undo for 5 seconds"))
        }
        .padding(.top, 2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Initial in a soft circle, the name (bold) over the address, or the address alone; Cc / Bcc tagged.
    private struct PersonRow: View {
        let person: SendApproval.Person

        var body: some View {
            HStack(spacing: 10) {
                Text(initial)
                    .font(AppTheme.font(11.5, .heavy)).foregroundStyle(AppTheme.accent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(AppTheme.accentSoft))
                VStack(alignment: .leading, spacing: 1) {
                    if let name = person.name {
                        Text(name).font(AppTheme.font(12.5, .semibold)).foregroundStyle(AppTheme.text).lineLimit(1)
                        Text(person.address).font(AppTheme.font(11.5)).foregroundStyle(AppTheme.text3)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(person.address).font(AppTheme.font(12.5, .medium)).foregroundStyle(AppTheme.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if person.field != .to {
                    Text(person.field.rawValue)
                        .font(AppTheme.font(10, .bold)).foregroundStyle(AppTheme.text2)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                        .overlay(Capsule().strokeBorder(AppTheme.stroke, lineWidth: 1))
                }
            }
            .padding(.horizontal, 12).frame(minHeight: person.name == nil ? 34 : 40)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(person.spokenRow))
        }

        private var initial: String {
            person.label.first.map { String($0).uppercased() } ?? "?"
        }
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3)
                .frame(width: 54, alignment: .leading)
            content
        }
        .padding(.horizontal, 12).frame(minHeight: 38)
    }
}

private struct FromChip: View {
    let account: DirectoryAccount
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            MailLogoBadge(account: account, size: 15)
            Text(account.tag).font(AppTheme.font(12, selected ? .bold : .medium))
        }
        .foregroundStyle(selected ? AppTheme.accentText : AppTheme.text)
        .padding(.leading, 5).padding(.trailing, 11).frame(height: 26)
        .background(Capsule().fill(selected ? AppTheme.accent : Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(selected ? Color.clear : AppTheme.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .help(account.email)
    }
}

/// A plain text field in the app; its text (or placeholder) in headless renders.
private struct ComposerTextField: View {
    let placeholder: String
    @Binding var text: String
    var bold = false
    @Environment(\.headlessRender) private var headless

    var body: some View {
        if headless {
            Text(text.isEmpty ? placeholder : text)
                .font(AppTheme.font(13, bold ? .semibold : .regular))
                .foregroundStyle(text.isEmpty ? AppTheme.text3 : AppTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(AppTheme.font(13, bold ? .semibold : .regular))
                .foregroundStyle(AppTheme.text)
        }
    }
}

/// The plain body (plain-text-only mode): today's dark NSTextView (undo, continuous spell check, plain text),
/// now the composer's own text view in plain mode so ⇧⌘T (Make Rich Text) reaches it. Headless: the text.
struct ComposerBody: View {
    @Binding var text: String
    var editable = true
    /// False while the approval card is up: VoiceOver skips the text view (SwiftUI's accessibilityHidden
    /// doesn't reach the AppKit view inside).
    var accessible = true
    var toggleRich: (() -> Void)?
    /// Attachments still work in plain mode (files and pictures become chips).
    var attachFiles: (([URL]) -> Void)?
    var attachImage: ((Data, String?, Bool) -> Void)?
    var attachRequest: (() -> Void)?
    @Environment(\.headlessRender) private var headless

    var body: some View {
        if headless {
            Text(text.isEmpty ? " " : text)
                .font(AppTheme.font(13.5)).foregroundStyle(AppTheme.text).lineSpacing(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            PlainBodyTextView(text: $text, editable: editable, accessible: accessible, toggleRich: toggleRich,
                              attachFiles: attachFiles, attachImage: attachImage, attachRequest: attachRequest)
        }
    }
}

private struct PlainBodyTextView: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var accessible = true
    var toggleRich: (() -> Void)?
    var attachFiles: (([URL]) -> Void)?
    var attachImage: ((Data, String?, Bool) -> Void)?
    var attachRequest: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = ComposerTextView.make(mode: .plain)
        view.string = text
        view.delegate = context.coordinator
        view.onToggleRich = toggleRich
        view.onAttachFiles = attachFiles
        view.onImage = attachImage
        view.onAttachRequest = attachRequest
        view.updateDragTypeRegistration()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerTextView else { return }
        view.isEditable = editable
        view.onToggleRich = toggleRich
        if view.isAccessibilityElement() != accessible {
            view.setAccessibilityElement(accessible)
            scroll.setAccessibilityElement(accessible)
        }
        if view.string != text { view.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// Plain mode's quiet line where the toolbar would be: "Plain text · Use formatting" (⇧⌘T).
private struct PlainModeLine: View {
    var enabled = true
    let useFormatting: () -> Void
    var attach: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.alignleft").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(AppTheme.text3)
            Text("Plain text").font(AppTheme.font(12, .semibold)).foregroundStyle(AppTheme.text3)
            Text("\u{00B7}").font(AppTheme.font(12)).foregroundStyle(AppTheme.text3)
            Button("Use formatting", action: useFormatting)
                .buttonStyle(.plain)
                .font(AppTheme.font(12, .bold)).foregroundStyle(AppTheme.accent)
                .disabled(!enabled)
                .help("Make Rich Text (\u{21E7}\u{2318}T)")
            Spacer(minLength: 0)
            if let attach {
                Button(action: attach) {
                    Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.text2)
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help("Attach files (\u{21E7}\u{2318}A)")
                .accessibilityLabel(Text("Attach files"))
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }
}

/// The light sheet (D-042): white, 12 pt corners, the rich editor on top and a reply's original under it.
/// Headless renders draw the editor offscreen (`RichTextSnapshot.textSnapshot`).
struct ComposerSheet: View {
    @ObservedObject var model: ComposerModel
    var editable = true
    var accessible = true
    var toggleRich: () -> Void = {}
    var chooseFiles: () -> Void = {}
    var attachFiles: ([URL]) -> Void = { _ in }
    @Environment(\.headlessRender) private var headless

    static let paper = Color.white
    static let corner: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                editor(width: proxy.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let quote = model.quote {
                    // The open original never squeezes your own text below ~120 pt.
                    QuotedOriginalView(model: model, quote: quote, width: proxy.size.width,
                                       previewHeight: min(QuotedOriginalView.expandedHeight,
                                                          max(90, proxy.size.height - QuotedOriginalView.collapsedHeight - 120)))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).fill(Self.paper)
            .shadow(color: .black.opacity(0.28), radius: 12, y: 4))
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func editor(width: CGFloat) -> some View {
        if headless {
            GeometryReader { inner in
                Image(nsImage: RichTextSnapshot.textSnapshot(model.document, width: width, height: max(40, inner.size.height),
                                                             selection: model.popover == nil ? nil : model.selection))
                    .resizable()
                    .frame(width: width, height: max(40, inner.size.height))
            }
        } else {
            RichTextEditor(document: model.document, revision: model.documentRevision, mode: .rich, defaults: model.defaults,
                           editable: editable, accessible: accessible, focusOnAppear: true,
                           onChange: { model.editorChanged($0) },
                           onSelection: { model.editorSelected($0, typing: $1) },
                           onRequestLink: { model.beginLink() },
                           onToggleRich: toggleRich,
                           formatting: { model.formatting },
                           onAttachFiles: attachFiles,
                           onImage: { data, name, asFile in model.attach(imageData: data, name: name, asFile: asFile) },
                           onSendAsAttachment: { model.sendAsAttachment(contentId: $0) },
                           onAttachRequest: chooseFiles,
                           register: { model.editor = $0 })
        }
    }
}

// MARK: - Windows

/// The app is an LSUIElement agent: it becomes a regular app while any of its windows is open (the
/// main window or a composer) and goes back to the menu bar when the last one closes.
@MainActor
enum WindowPresence {
    private static var open = Set<ObjectIdentifier>()

    static func opened(_ owner: AnyObject) {
        open.insert(ObjectIdentifier(owner))
        NSApp.setActivationPolicy(.regular)
    }

    static func closed(_ owner: AnyObject) {
        open.remove(ObjectIdentifier(owner))
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

/// One window per composer (several can be open). Closing it discards the draft; a send already in its
/// 5 s window still leaves. While the approval card is up (D-023) the window's keys belong to the card:
/// Return sends (a fresh press, after the card's arming delay: never a held or auto-repeating ↩), Esc goes
/// back, ⌘↩ and typing are eaten (nothing reaches the draft underneath), menu keys pass; the focused field
/// and its cursor come back when the card goes (else the body, so something always has focus).
@MainActor
final class ComposerWindowController: NSObject, NSWindowDelegate {
    private static var controllers: [ComposerWindowController] = []

    let model: ComposerModel
    private var window: NSWindow?
    private var approvalWatch: AnyCancellable?
    private var keyMonitor: Any?
    private weak var focusedView: NSView?
    private var focusedRange: NSRange?

    static func open(_ request: ComposerRequest) {
        let accounts = AccountDirectory.current().accounts
        let model = ComposerModel(request: request, accounts: accounts, staging: ComposeStaging())
        let controller = ComposerWindowController(model: model)
        controllers.append(controller)
        controller.show()
        Trace.app("composer", ["kind": "\(request.kind)"])
        // A forward's original files download in the background (first paint doesn't wait for them).
        if request.kind == .forward { Task { await model.loadForwardedAttachments() } }
    }

    private init(model: ComposerModel) {
        self.model = model
        super.init()
    }

    private func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = model.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x0C / 255, green: 0x16 / 255, blue: 0x1D / 255, alpha: 1)
        window.contentMinSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: ComposerView(model: model))
        host.sizingOptions = []
        window.contentView = host
        model.onClose = { [weak window] in window?.close() }
        approvalWatch = model.$approval.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] up in
            MainActor.assumeIsolated { self?.approvalChanged(up) }
        }
        // Cascade from the last composer so several don't stack exactly.
        if let last = Self.controllers.dropLast().last?.window {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 26, y: last.frame.maxY - 26))
        } else {
            window.center()
        }
        self.window = window
        WindowPresence.opened(self)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        approvalWatch = nil
        // Staged copies go; a queued send already holds its bytes in the outbox.
        model.discardStaging()
        WindowPresence.closed(self)
        Self.controllers.removeAll { $0 === self }
    }

    // MARK: Approval card keys and focus

    private func approvalChanged(_ up: Bool) {
        guard let window else { return }
        if up {
            saveFocus(in: window)
            window.makeFirstResponder(nil)
            installKeyMonitor()
            if let line = model.approval?.spoken {
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        } else {
            removeKeyMonitor()
            // After SwiftUI has re-enabled the fields (the change is published before it applies).
            DispatchQueue.main.async { [weak self] in self?.restoreFocus() }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window, self.model.isConfirming else { return event }
                let flags = event.modifierFlags
                switch ApprovalKey.decide(keyCode: event.keyCode, command: flags.contains(.command),
                                          option: flags.contains(.option), control: flags.contains(.control),
                                          isRepeat: event.isARepeat, sinceShown: self.model.sinceApprovalShown) {
                case .approve:
                    Task { await self.model.approveSend() }
                    return nil
                case .cancel:
                    self.model.cancelApproval()
                    return nil
                case .swallow:
                    return nil
                case .pass:
                    return event
                }
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The text field (not its shared field editor) or the body, and where the cursor was.
    private func saveFocus(in window: NSWindow) {
        focusedView = nil
        focusedRange = nil
        guard let text = window.firstResponder as? NSTextView else {
            focusedView = window.firstResponder as? NSView
            return
        }
        if text.isFieldEditor, let field = text.delegate as? NSTextField {
            focusedView = field
        } else {
            focusedView = text
        }
        focusedRange = text.selectedRange()
    }

    /// SwiftUI re-enables the fields on its next update, not on a fixed run-loop turn: if the field won't
    /// take focus yet, try once more 50 ms later, then fall back to the body so typing never goes nowhere.
    private func restoreFocus(retry: Bool = true) {
        guard let window, !model.isConfirming else { return }
        if let view = focusedView, view.window === window, window.makeFirstResponder(view) {
            if let range = focusedRange {
                if let text = view as? NSTextView {
                    text.setSelectedRange(Self.clamp(range, to: (text.string as NSString).length))
                } else if let field = view as? NSTextField, let editor = field.currentEditor() {
                    editor.selectedRange = Self.clamp(range, to: (field.stringValue as NSString).length)
                }
            }
        } else if retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.restoreFocus(retry: false) }
            return
        } else if let body = Self.bodyTextView(in: window.contentView) {
            window.makeFirstResponder(body)
        }
        focusedView = nil
        focusedRange = nil
    }

    /// The composer's body (the one editable NSTextView that isn't a field editor).
    private static func bodyTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, !text.isFieldEditor, text.isEditable { return text }
        for sub in view.subviews { if let found = bodyTextView(in: sub) { return found } }
        return nil
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
}
