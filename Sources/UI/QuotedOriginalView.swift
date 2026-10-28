import AppKit
import SwiftUI

// A rich reply's original (D-041, D-042): read-only and collapsible under the
// editor, inside the sheet, keeping the original's layout. Collapsed: a 32 pt "•••" bar with who and when; expanded:
// a 220 pt read-only web view of the original (remote content blocked, JavaScript off). × removes it (Undo puts it
// back); "Edit quoted text" (asks first) turns it into an editable quote block at the end of your message, with
// simpler formatting. The data layer composes the real quote from its own cache at send time.

struct QuotedOriginalView: View {
    @ObservedObject var model: ComposerModel
    let quote: QuotedOriginal
    var width: CGFloat = 560
    /// The open preview's height (220 pt, less in a short window so your own text keeps room).
    var previewHeight: CGFloat = QuotedOriginalView.expandedHeight
    @Environment(\.headlessRender) private var headless
    @Environment(\.undoManager) private var undoManager
    @Local private var askingToEdit = false
    @Local private var height: CGFloat = 220

    static let collapsedHeight: CGFloat = 32
    static let expandedHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color(hex: 0xE7E1D8)).frame(height: 1)
            bar
            if model.quoteExpanded {
                preview
                    .frame(height: previewHeight)
                    .clipped()
            }
        }
        .confirmationDialog("Edit the quoted text?", isPresented: Binding(get: { askingToEdit && !headless }, set: { askingToEdit = $0 })) {
            Button("Edit quoted text") { editQuote() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It becomes part of your message, and some of its formatting gets simpler.")
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Button { model.quoteExpanded.toggle() } label: {
                Text("\u{2022}\u{2022}\u{2022}")
                    .font(.system(size: 11, weight: .heavy)).tracking(1)
                    .foregroundStyle(Color(hex: 0x5A5560))
                    .frame(width: 30, height: 18)
                    .background(Capsule().fill(Color(hex: model.quoteExpanded ? 0xE2DCD2 : 0xEFE9E0)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(quote.spoken(expanded: model.quoteExpanded)))
            .accessibilityAddTraits(.isButton)
            .help(model.quoteExpanded ? "Hide the quoted text" : "Show the quoted text")
            Text("\(Text("\(quote.isForward ? "Forwarded message" : "Quoted text") from \(quote.senderName)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x5A5560)))\(Text("  \u{00B7}  " + summary).font(.system(size: 12)).foregroundStyle(Color(hex: 0x8C8590)))")
                .lineLimit(1).truncationMode(.tail)
                .accessibilityHidden(true)
            Spacer(minLength: 6)
            if model.quoteExpanded {
                Button("Edit quoted text") { askingToEdit = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x14937F))
                    .help("Make the quoted text editable (some formatting gets simpler)")
            }
            Button {
                model.removeQuote()
                undoManager?.registerUndo(withTarget: model) { $0.restoreQuote() }
                undoManager?.setActionName("Remove Quoted Text")
            } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color(hex: 0x8C8590))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color(hex: 0xEFE9E0)))
            }
            .buttonStyle(.plain)
            .help("Remove the quoted text")
            .accessibilityLabel(Text("Remove the quoted text"))
        }
        .padding(.horizontal, 12)
        .frame(height: Self.collapsedHeight)
        .background(Color(hex: 0xFBF9F6))
        .contentShape(Rectangle())
    }

    /// After "Quoted text from Juniper Vale": when it was sent (bar style), or that a header goes above it.
    private var summary: String {
        if quote.isForward { return DayName.format("EEE d MMM, h:mm a", quote.message.date) }
        switch quote.style {
        case .bar: return DayName.format("EEE d MMM, h:mm a", quote.message.date)
        case .header: return "With a header \u{00B7} " + DayName.format("EEE d MMM, h:mm a", quote.message.date)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if headless {
            Image(nsImage: Self.headlessPreview(quote, width: width, height: previewHeight))
                .resizable().interpolation(.high)
                .frame(width: width, height: previewHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            MailWebView(html: MailContentPolicy.document(Self.previewHTML(quote), allowRemote: false), allowRemote: false,
                        fitsContent: false, height: $height)
        }
    }

    /// The original as recipients will see it under your reply: Gmail's bar, or Outlook's header block.
    static func previewHTML(_ quote: QuotedOriginal) -> String {
        let original = quote.message.html ?? HTMLSanitizer.html(fromText: quote.message.text)
        if quote.isForward {
            let lines = quote.forwardHeader.map { "\(MailHTMLWriter.escape($0.0)): \(MailHTMLWriter.escape($0.1))" }.joined(separator: "<br>")
            return "<div style=\"color:#5a5560;font-size:12px;margin:0 0 6px\">\(MailHTMLWriter.escape(MailAttribution.forwardLine))<br>\(lines)</div>"
                + "<div><br></div>\(original)"
        }
        switch quote.style {
        case .bar:
            return "<div style=\"color:#5a5560;font-size:12px;margin:0 0 6px\">\(MailHTMLWriter.escape(quote.attribution))</div>"
                + "<blockquote style=\"\(MailHTMLWriter.quoteStyle)\">\(original)</blockquote>"
        case .header:
            let lines = quote.header.map { "<b>\(MailHTMLWriter.escape($0.0)):</b> \(MailHTMLWriter.escape($0.1))" }.joined(separator: "<br>")
            return "<hr style=\"border:none;border-top:1px solid #e1e1e1\"><div style=\"font-size:12px\">\(lines)</div><div><br></div>\(original)"
        }
    }

    /// Headless: the same preview through our own reader, drawn by the editor (ImageRenderer can't draw a web view).
    @MainActor
    static func headlessDocument(_ quote: QuotedOriginal) -> NSAttributedString {
        MailHTMLReader.attributedString(HTMLSanitizer.sanitize(previewHTML(quote), remote: .block).html, font: .sans, size: 13)
    }

    @MainActor
    static func headlessPreview(_ quote: QuotedOriginal, width: CGFloat, height: CGFloat) -> NSImage {
        RichTextSnapshot.textSnapshot(headlessDocument(quote), width: width, height: height)
    }

    private func editQuote() {
        let html = quote.message.html.map { HTMLSanitizer.sanitize($0, remote: .block).html }
            ?? HTMLSanitizer.html(fromText: quote.message.text)
        let converted = MailHTMLReader.attributedString(html, font: model.writing.font.css, size: model.writing.size.points)
        model.makeQuoteEditable(converted)
    }
}
