import AppKit
import SwiftUI

// Reader attachments, the drawing (rich mail, D-043): the strip under a message
// ("3 attachments · 14.7 MB", Save All, a chip per file), the inline image previews, and the Mail Peek's one-row
// compact strip with a "+N" chip. Actions live in `AttachmentStripModel` (AttachmentActions.swift).

/// A message's attachments: the strip, then (full size only) the image previews. Owns the strip's model for as
/// long as the card shows this message.
struct MessageAttachments: View {
    let message: MailMessage
    let threadR: String
    var compact = false
    @Environment(\.headlessRender) private var headless
    @Environment(\.mailToasts) private var toasts
    @Local private var box = AttachmentModelBox()

    var body: some View {
        let model = box.model(threadR: threadR, message: message, headless: headless)
        Group {
            if compact {
                AttachmentStrip(model: model, compact: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    AttachmentStrip(model: model)
                    AttachmentPreviews(model: model)
                }
            }
        }
        .onAppear { model.toasts = toasts }
    }
}

/// Keeps one model per shown message (SwiftUI state holds the box; the box holds the model).
@MainActor
final class AttachmentModelBox {
    private var current: AttachmentStripModel?

    func model(threadR: String, message: MailMessage, headless: Bool) -> AttachmentStripModel {
        if let current, current.threadR == threadR, current.message.id == message.id, current.message.attachments == message.attachments {
            return current
        }
        let made = headless
            ? AttachmentStripModel(threadR: threadR, message: message, store: { EmptyStores.shared }, local: MemoryMailLocalStore())
            : AttachmentStripModel(threadR: threadR, message: message)
        current = made
        return made
    }
}

// MARK: - Strip

struct AttachmentStrip: View {
    @ObservedObject var model: AttachmentStripModel
    var compact = false

    static let compactHeight: CGFloat = 30

    var body: some View {
        if compact { compactRow } else { full }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "paperclip").font(.system(size: 10.5, weight: .bold)).foregroundStyle(PaperTheme.text3)
                    .accessibilityHidden(true)
                Text(AttachmentNames.summary(model.files)).font(AppTheme.font(11.5, .bold)).foregroundStyle(PaperTheme.text2)
                Spacer(minLength: 8)
                if model.files.contains(where: { !$0.id.isEmpty }) {
                    Button {
                        model.saveAll(askFolder: NSEvent.modifierFlags.contains(.option))
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 11, weight: .semibold))
                            Text("Save All").font(AppTheme.font(11.5, .bold))
                        }
                        .foregroundStyle(PaperTheme.accent)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(PaperTheme.pill))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Save every attachment to \(model.saveFolder.title). Hold Option to choose a folder.")
                    .accessibilityLabel("Save all attachments to \(model.saveFolder.title)")
                }
            }
            ChipGrid(spacing: 8) {
                ForEach(Array(model.files.enumerated()), id: \.offset) { _, a in
                    AttachmentChip(model: model, attachment: a)
                }
            }
        }
    }

    /// The Mail Peek: one row; what doesn't fit becomes "+N" (opens the thread in the app).
    private var compactRow: some View {
        GeometryReader { g in
            let layout = Self.compactLayout(width: g.size.width, count: model.files.count)
            HStack(spacing: Self.gap) {
                ForEach(Array(model.files.prefix(layout.shown).enumerated()), id: \.offset) { _, a in
                    AttachmentChip(model: model, attachment: a, compact: true).frame(width: layout.chipWidth)
                }
                if layout.shown < model.files.count {
                    MoreAttachmentsChip(count: model.files.count - layout.shown) { AttachmentStripModel.openThread?(model.threadR) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.compactHeight)
    }

    static let gap: CGFloat = 6
    static let moreWidth: CGFloat = 46
    static let compactMin: CGFloat = 140
    static let compactMax: CGFloat = 200

    /// How many compact chips fit in `width` (at least one), and how wide each is.
    static func compactLayout(width: CGFloat, count: Int) -> (shown: Int, chipWidth: CGFloat) {
        guard count > 0, width > 0 else { return (0, compactMin) }
        let all = (width - gap * CGFloat(count - 1)) / CGFloat(count)
        if all >= compactMin { return (count, min(compactMax, all)) }
        let room = width - moreWidth - gap
        let shown = max(1, Int((room + gap) / (compactMin + gap)))
        let chip = min(compactMax, (room - gap * CGFloat(shown - 1)) / CGFloat(shown))
        return (min(shown, count), max(100, chip))
    }
}

/// One file: Finder's icon (type badge, a shield when it can run code), the name (middle-truncated, so the
/// extension stays visible), "PDF document · 2.4 MB", and a ring while it downloads.
struct AttachmentChip: View {
    @ObservedObject var model: AttachmentStripModel
    let attachment: MailMessage.Attachment
    var compact = false
    @Environment(\.headlessRender) private var headless

    var body: some View {
        let name = model.name(attachment)
        let focused = !attachment.id.isEmpty && model.focused == attachment.id
        let height: CGFloat = compact ? AttachmentStrip.compactHeight : 44
        HStack(spacing: compact ? 7 : 9) {
            AttachmentIconView(name: name, mimeType: attachment.mimeType, size: compact ? 20 : 28, badge: !compact)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(AppTheme.font(compact ? 11.5 : 12.5, .semibold)).foregroundStyle(PaperTheme.text)
                    .lineLimit(1).truncationMode(.middle)
                if !compact {
                    // "PDF document · 2.4 MB": the kind gives way first, the size always shows.
                    HStack(spacing: 0) {
                        Text(AttachmentNames.kindName(name, mimeType: attachment.mimeType)).lineLimit(1).truncationMode(.tail)
                        Text(" \u{00B7} " + MailText.size(attachment.bytes)).lineLimit(1).fixedSize()
                    }
                    .font(AppTheme.font(11)).foregroundStyle(attachment.bytes > AttachmentNames.maxFetchBytes ? AppTheme.bad : PaperTheme.text3)
                }
            }
            Spacer(minLength: 0)
            if model.fetching.contains(attachment.id) {
                ProgressView().progressViewStyle(.circular).controlSize(.small).scaleEffect(0.75).frame(width: 16, height: 16)
            }
        }
        .padding(.leading, compact ? 7 : 9).padding(.trailing, compact ? 8 : 10)
        .frame(minWidth: compact ? nil : 180, maxWidth: compact ? .infinity : 260, minHeight: height, maxHeight: height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
            .strokeBorder(focused ? PaperTheme.accent : PaperTheme.rule, lineWidth: focused ? 2 : 1))
        .overlay {
            if !headless { AttachmentChipInteraction(model: model, attachment: attachment, compact: compact) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AttachmentNames.accessibilityLabel(attachment))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open") { model.open(attachment) }
        .accessibilityAction(named: "Quick Look") { model.quickLook(attachment) }
        .accessibilityAction(named: "Save") { model.save(attachment) }
    }
}

/// Chips in equal columns (Apple Mail's tidy grid): as many as fit at `minWidth` (220, so "PDF document · 2.4 MB"
/// reads in full; chips themselves stay 180-260 pt), each at most `maxWidth`.
struct ChipGrid: Layout {
    var spacing: CGFloat = 8
    var minWidth: CGFloat = 220
    var maxWidth: CGFloat = 260

    func columns(_ width: CGFloat?, count: Int) -> (count: Int, width: CGFloat) {
        guard let width, width.isFinite, width > 0 else { return (max(1, count), maxWidth) }
        let columns = max(1, min(count, Int((width + spacing) / (minWidth + spacing))))
        return (columns, min(maxWidth, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)))
    }

    private func rowHeights(_ subviews: Subviews, columns: Int, width: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let grid = columns(proposal.width, count: subviews.count)
        let rows = rowHeights(subviews, columns: grid.count, width: grid.width)
        let used = CGFloat(min(grid.count, subviews.count)) * grid.width + spacing * CGFloat(min(grid.count, subviews.count) - 1)
        return CGSize(width: proposal.width.map { min($0, used) } ?? used,
                      height: rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let grid = columns(bounds.width, count: subviews.count)
        let rows = rowHeights(subviews, columns: grid.count, width: grid.width)
        var y = bounds.minY
        for (row, height) in rows.enumerated() {
            for column in 0..<grid.count {
                let index = row * grid.count + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.width + spacing), y: y),
                                      proposal: ProposedViewSize(width: grid.width, height: height))
            }
            y += height + spacing
        }
    }
}

/// Finder's icon for the type, with the real extension as a small badge ("EXE" for "invoice‮fdp.exe") and a shield
/// for types that can run code.
struct AttachmentIconView: View {
    let name: String
    let mimeType: String
    var size: CGFloat = 28
    var badge = true

    var body: some View {
        let risky = AttachmentNames.isRisky(name, mimeType: mimeType)
        let ext = AttachmentNames.badge(name, mimeType: mimeType)
        ZStack(alignment: .bottom) {
            Image(nsImage: AttachmentIcons.icon(name, mimeType: mimeType)).resizable().interpolation(.high)
                .frame(width: size, height: size)
            if badge, !ext.isEmpty {
                Text(ext).font(.system(size: 7, weight: .heavy)).foregroundStyle(Color.white)
                    .padding(.horizontal, 3).frame(height: 10)
                    .background(RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(risky ? AppTheme.bad : Color(hex: 0x5A5560)))
                    .offset(y: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if risky {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(AppTheme.warn)
                    .background(Circle().fill(Color.white).padding(-1))
                    .offset(x: size * 0.18, y: -size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The Peek's "+3": the rest of the files, in the app.
private struct MoreAttachmentsChip: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("+\(count)").font(AppTheme.font(12, .heavy)).foregroundStyle(PaperTheme.text2)
                .frame(width: AttachmentStrip.moreWidth, height: AttachmentStrip.compactHeight)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PaperTheme.pill))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open this conversation to see every attachment")
        .accessibilityLabel("\(count) more attachments. Opens the conversation.")
    }
}

// MARK: - Previews

/// Photos sent as files, drawn under the strip (full card width, at most 320 pt tall, in a white frame): the first
/// 6 within 10 MB each and 20 MB in all when the card appears, the rest on "Show image previews". Click is Quick
/// Look, double-click is Open.
struct AttachmentPreviews: View {
    @ObservedObject var model: AttachmentStripModel
    @Environment(\.headlessRender) private var headless
    @Environment(\.attachmentPreviewImages) private var rendered

    static let maxHeight: CGFloat = 320

    var body: some View {
        let plan = model.previewPlan
        let shown = plan.auto + (model.showsDeferred ? plan.deferred : [])
        if !shown.isEmpty || !plan.deferred.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, a in
                    if let image = headless ? rendered["\(model.message.id)/\(a.id)"] : model.previews[a.id] {
                        preview(image, a)
                    } else if !headless, !model.failedPreviews.contains(a.id) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white)
                            .overlay(ProgressView().controlSize(.small))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PaperTheme.rule, lineWidth: 1))
                            .frame(height: 120)
                    }
                }
                if !plan.deferred.isEmpty, !model.showsDeferred {
                    Button { model.showDeferredPreviews() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 11, weight: .semibold))
                            Text(plan.deferred.count == 1 ? "Show image preview" : "Show image previews (\(plan.deferred.count))")
                                .font(AppTheme.font(12, .bold))
                        }
                        .foregroundStyle(PaperTheme.accent)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(PaperTheme.pill))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .onAppear { if !headless { model.loadPreviews() } }
        }
    }

    private func preview(_ image: NSImage, _ a: MailMessage.Attachment) -> some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(maxWidth: image.size.width, maxHeight: Self.maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PaperTheme.rule, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.open(a) }
            .onTapGesture { model.quickLook(a) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Picture: \(model.name(a))")
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: "Quick Look") { model.quickLook(a) }
    }
}
