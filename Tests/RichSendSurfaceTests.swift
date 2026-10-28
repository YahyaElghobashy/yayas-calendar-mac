import AppKit
import Foundation

/// Rich mail sending, composer side (attaching): the forward
/// request, its subject and pre-attached files, the tray (attach, staging, remove, inline images both ways), the size
/// estimate with its warning and problem, and the D-023 card over a draft with attachments. Cast data only; files go
/// under Tests/.out.
@MainActor
enum RichSendSurfaceTests {
    static func run() async {
        forwardSubjects()
        await forward()
        await attaching()
        inlineImages()
        sizes()
        await approvalWithAttachments()
        signatureLogo()
        keys()
    }

    static let now = Date(timeIntervalSince1970: 1_792_400_000)

    static var outFolder: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("rich-send", isDirectory: true)
    }

    static func model(_ request: ComposerRequest, format: ComposerFormat? = nil, staging: ComposeStaging? = nil, safeSend: Bool = true,
                      actions: FakeMailActions = FakeMailActions(store: FakeMailStore()),
                      store: MailAttachmentStore? = nil) -> ComposerModel {
        let prefs = RichComposerFixtures.prefs()
        let files = store ?? FakeMailAttachments(folder: outFolder.appendingPathComponent("cache", isDirectory: true))
        return ComposerModel(request: request, accounts: RichComposerFixtures.directory().accounts, safeSend: safeSend,
                             actions: { actions }, prefs: { prefs }, local: MemoryMailLocalStore(), clock: { now }, schedule: { _, _ in },
                             toasts: MailToastCenter(clock: { now }, schedule: { _, _ in }), format: format, staging: staging,
                             attachmentStore: { files })
    }

    static func png(_ w: Int, _ h: Int, alpha: Bool = false) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (alpha ? NSColor.clear : NSColor(srgbRed: 0.5, green: 0.65, blue: 0.85, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor(srgbRed: 0.85, green: 0.62, blue: 0.4, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func posix(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: Forward

    static func forwardSubjects() {
        T.section("Rich mail: Forward subjects")
        T.equal(ComposerText.forwardSubject("Q4 pickle launch plan"), "Fwd: Q4 pickle launch plan", "Fwd: x")
        T.equal(ComposerText.forwardSubject("Fwd: Q4 pickle launch plan"), "Fwd: Q4 pickle launch plan", "never Fwd: Fwd:")
        T.equal(ComposerText.forwardSubject("fwd: tour dates"), "Fwd: tour dates", "fwd: counts")
        T.equal(ComposerText.forwardSubject("FW: Set list"), "Fwd: Set list", "Fw: (Outlook) counts")
        T.equal(ComposerText.forwardSubject("Re: Pickle jar labels"), "Fwd: Re: Pickle jar labels", "a reply's subject keeps its Re:")
        T.equal(ComposerText.forwardSubject("   "), "Fwd: (no subject)", "no subject")
        let text = ComposerText.forwardQuote(RichComposerFixtures.juniperMessage(now: now))
        T.check(text.hasPrefix("---------- Forwarded message ---------\nFrom: Juniper Vale <juniper@vale.example>\nDate: ")
                && text.contains("\nSubject: Re: Pickle jar labels\nTo: avery@orbitalpickle.example\nCc: Milo Brightwater <milo@brightwater.example>\n\nHi Avery,"),
                "plain forward: Gmail's header, then the text")
    }

    static func forward() async {
        T.section("Rich mail: Forward")
        let request = RichComposerFixtures.kofiForward(now: now)
        let m = model(request)
        T.equal(m.title, "Forward", "title")
        T.equal(m.subject, "Fwd: Photos from the lake house", "subject")
        T.check(m.to.isEmpty && m.cc.isEmpty && !m.showCcBcc, "To and Cc start empty")
        T.equal(m.from, RichMailCast.fam.id, "From: the account that got it")
        T.equal(m.attachments.map(\.filename), ["Lake house.heic"], "the original's files are pre-attached; inline photos are not")
        T.check(m.attachments.allSatisfy { $0.isLoading && $0.forwardedPart == "2" }, "pre-attached files load in the background")
        T.check(m.quote?.isForward == true && m.quote?.spoken(expanded: false) == "Forwarded message from Kofi Ember, collapsed",
                "the original shows under the editor as a forwarded message")
        m.to = RichMailCast.ines.email
        guard case .failure(.attachmentsLoading) = m.draft() else { T.check(false, "send while loading → .attachmentsLoading"); return }
        T.equal(ComposerProblem.attachmentsLoading.message, "Still getting the forwarded attachments. Send again in a moment.", "loading text")
        await m.loadForwardedAttachments()
        T.check(m.attachments.first?.state == .ready && m.attachments.first?.file != nil, "the forwarded file arrives (cache file, no staging)")
        guard case .success(let draft) = m.draft() else { T.check(false, "forward draft"); return }
        T.equal(draft.quote, MailQuoteRequest(threadR: RichMailThreads.inlineImages.r, messageId: "rm-inline-images-1", kind: .forward, style: .bar),
                "the draft asks the data layer for the forwarded original")
        T.equal(draft.replyTo, RichMailThreads.inlineImages.r, "replyTo carries the thread (threading as for replies)")
        T.check(draft.attachments.map(\.filename) == ["Lake house.heic"] && draft.attachments.allSatisfy { $0.contentId == nil },
                "the draft carries the file, not the inline photos")
        T.check(draft.signatureIncluded && draft.html != nil && !draft.html!.contains("Forwarded message"),
                "the forwarded original is not in the editable HTML (the data layer adds it)")
        // A file Gmail no longer has.
        let gone = model(RichComposerFixtures.priyaForward(now: now), store: FakeMailAttachments(folder: outFolder.appendingPathComponent("cache2"), parts: []))
        gone.to = RichMailCast.ines.email
        await gone.loadForwardedAttachments()
        T.check(gone.attachments.count == 3 && gone.attachments.allSatisfy { $0.failure == "Gmail no longer has that attachment." }, "a missing original fails its chip")
        guard case .failure(.attachmentFailed("Launch plan.pdf")) = gone.draft() else { T.check(false, "send with a failed chip → .attachmentFailed"); return }
        T.equal(ComposerProblem.attachmentFailed("Launch plan.pdf").message,
                "I couldn\u{2019}t read \u{201C}Launch plan.pdf\u{201D}. Remove it or attach it again.", "failed text")
        for a in gone.attachments { gone.removeAttachment(a.id) }
        if case .success(let d) = gone.draft() { T.check(d.attachments.isEmpty, "removed chips aren't sent") } else { T.check(false, "draft after removing") }
        // Plain mode: the forward's header and text in the body, files still attached.
        let plain = model(request, format: .plain)
        T.check(plain.body.contains("---------- Forwarded message ---------\nFrom: Kofi Ember <kofi@ember.example>") && plain.quote == nil
                && plain.attachments.count == 1, "plain forward: header and text in the body, the file in the tray")
        // Staging: forwarded files are copied into the composer's own folder.
        let root = outFolder.appendingPathComponent("staging-root", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let staging = ComposeStaging(root: root)
        let staged = model(request, staging: staging)
        await staged.loadForwardedAttachments()
        let file = staged.attachments.first?.file
        T.check(file?.path.hasPrefix(staging.folder.path + "/") == true && file.map(posix) == 0o600 && posix(staging.folder) == 0o700,
                "forwarded files are staged (0600 in a 0700 folder)")
        staged.discardStaging()
        T.check(!FileManager.default.fileExists(atPath: staging.folder.path), "closing the window removes the staging folder")
    }

    // MARK: Attaching

    static func attaching() async {
        T.section("Rich mail: composer attaching")
        let fm = FileManager.default
        let folder = outFolder.appendingPathComponent("user-files", isDirectory: true)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let plan = folder.appendingPathComponent("Launch plan.pdf")
        try? Data(repeating: 0x25, count: 24_000).write(to: plan)
        let app = folder.appendingPathComponent("Pickle Printer.app", isDirectory: true)
        try? fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let root = outFolder.appendingPathComponent("staging-attach", isDirectory: true)
        try? fm.removeItem(at: root)
        let staging = ComposeStaging(root: root)
        let m = model(.new(from: RichMailCast.orb.id), staging: staging)
        m.to = RichMailCast.juniper.email
        T.equal(m.attach(urls: [folder, app]), 0, "folders and apps are refused")
        T.equal(m.problem, "Folders and apps can\u{2019}t be attached. Zip them first.", "with one line")
        T.equal(m.attach(urls: [plan]), 1, "a file is attached")
        await m.attachmentsCopied()   // the copy into staging runs off the main actor
        let chip = m.attachments.first
        T.check(chip?.filename == "Launch plan.pdf" && chip?.mimeType == "application/pdf" && chip?.bytes == 24_000 && m.problem == nil,
                "the chip: name, type, size; the refusal line clears")
        T.check(chip?.file?.path.hasPrefix(staging.folder.path + "/") == true && chip?.file.map(posix) == 0o600, "attached files are staged copies (0600)")
        T.equal(chip?.spoken, "Launch plan.pdf, PDF document, 24 kilobytes", "VoiceOver reads the chip")
        try? fm.removeItem(at: plan)
        guard case .success(let draft) = m.draft() else { T.check(false, "draft with a file"); return }
        T.check(draft.attachments.count == 1 && draft.attachments[0].file == chip?.file && draft.attachments[0].contentId == nil
                && (try? Data(contentsOf: draft.attachments[0].file))?.count == 24_000,
                "the draft reads the staged copy, even after the original was deleted")
        T.check(m.estimatedSize > 24_000 * 4 / 3, "the estimate counts the file")
        let saved = chip!
        m.removeAttachment(saved.id)
        T.check(m.attachments.isEmpty, "× removes the chip")
        m.restoreAttachment(saved, at: 0)
        T.check(m.attachments.map(\.id) == [saved.id], "Undo puts it back")
        // Attachments only (no words, no subject) can be sent.
        let only = model(.new(from: RichMailCast.orb.id))
        only.to = RichMailCast.juniper.email
        only.body = ""
        only.attach(imageData: png(20, 20), name: "label.png", asFile: true)
        if case .success(let d) = only.draft() { T.check(d.attachments.count == 1, "a draft with only an attachment goes") } else { T.check(false, "attachments-only draft") }
        staging.removeAll()
        let left = outFolder.appendingPathComponent("staging-sweep", isDirectory: true)
        try? fm.createDirectory(at: left.appendingPathComponent("compose/old", isDirectory: true), withIntermediateDirectories: true)
        T.equal(ComposeStaging.sweep(root: left), 1, "launch sweeps leftover staging folders")
    }

    static func inlineImages() {
        T.section("Rich mail: inline images")
        let m = model(.new(from: RichMailCast.orb.id))
        m.to = RichMailCast.juniper.email
        m.editorSelected(NSRange(location: 0, length: 0), typing: [:])
        let photo = png(3200, 1600)
        T.check(m.attach(imageData: photo, name: "Dock.png"), "a pasted image up to 5 MB goes inline")
        let images = ComposerImages.inlineImages(m.document)
        T.check(images.count == 1 && !images[0].contentId.isEmpty && m.attachments.isEmpty, "it sits in the body with a content id, not in the tray")
        if let prepared = ComposerImages.prepare(photo) {
            T.check(prepared.mimeType == "image/jpeg" && prepared.pixels == CGSize(width: 2560, height: 1280),
                    "photos: JPEG, at most 2560 px on the long edge")
        } else { T.check(false, "prepare a photo") }
        T.check(ComposerImages.prepare(png(300, 200, alpha: true))?.mimeType == "image/png", "images with transparency stay PNG")
        T.check(ComposerImages.prepare(Data("not an image".utf8)) == nil, "not an image → nil")
        guard case .success(let draft) = m.draft() else { T.check(false, "draft with an inline image"); return }
        let inline = draft.attachments.filter { $0.contentId != nil }
        T.check(inline.count == 1 && inline[0].contentId == images[0].contentId && inline[0].data != nil && inline[0].mimeType == "image/jpeg"
                && (draft.html ?? "").contains("src=\"cid:\(images[0].contentId)\""), "the draft: an inline part the HTML draws by cid (in memory without staging)")
        m.sendAsAttachment(contentId: images[0].contentId)
        T.check(ComposerImages.inlineImages(m.document).isEmpty && m.attachments.count == 1 && m.attachments[0].isImage,
                "Send as Attachment: out of the body, into the tray")
        m.placeInMessage(m.attachments[0].id)
        T.check(ComposerImages.inlineImages(m.document).count == 1 && m.attachments.isEmpty, "Place in Message: back into the body")
        let big = Data(count: ComposerImages.inlineLimit + 1)
        T.check(!m.attach(imageData: big, name: "huge.png") && m.attachments.count == 1, "over 5 MB: a chip, not inline")
        let plain = model(.new(from: RichMailCast.orb.id), format: .plain)
        T.check(!plain.attach(imageData: png(40, 40), name: "label.png") && plain.attachments.count == 1, "plain mode: pictures become chips")
        plain.to = RichMailCast.juniper.email
        if case .success(let d) = plain.draft() { T.check(d.html == nil && d.attachments.count == 1, "plain mode: text/plain with files") }
        else { T.check(false, "plain draft with a file") }
        // Staged inline images at send time.
        let root = outFolder.appendingPathComponent("staging-inline", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let staged = model(.new(from: RichMailCast.orb.id), staging: ComposeStaging(root: root))
        staged.to = RichMailCast.juniper.email
        staged.attach(imageData: png(64, 48), name: "logo.png")
        if case .success(let d) = staged.draft(), let part = d.attachments.first {
            T.check(part.data == nil && part.file.path.hasPrefix(root.path) && (try? Data(contentsOf: part.file)) != nil,
                    "with staging, inline images are written there for the data layer")
        } else { T.check(false, "staged inline draft") }
        staged.discardStaging()
    }

    // MARK: Size

    static func sizes() {
        T.section("Rich mail: size estimate")
        T.equal(MailSize.estimate(text: 1_000, html: 2_000, attachments: [57, 1_000_000], names: 20, headers: 50), 1_378_926, "estimate table: mixed")
        T.equal(MailSize.estimate(text: 0, html: 0, attachments: []), 4_096 + 4 * 400, "estimate table: empty")
        T.equal(MailSize.estimate(text: 100, html: 0, attachments: [25_000_000]), 4_096 + 105 + 34_210_566 + 5 * 400, "estimate table: 25 MB file")
        T.equal([MailSize.qpWeight("abc"), MailSize.qpWeight("Caf\u{00E9}"), MailSize.qpWeight("a\nb"), MailSize.qpWeight("a=b"),
                 MailSize.qpWeight(".x"), MailSize.qpWeight("a \n")], [3, 9, 4, 5, 4, 6], "QP weights")
        T.equal(ComposerSize.warning(10_000_001), "Some mail servers refuse messages over 10 MB.", "warning over 10 MB")
        T.check(ComposerSize.warning(10_000_000) == nil, "no warning at 10 MB")
        T.equal(ComposerProblem.tooLarge(total: 27_400_000).message,
                "This comes to 27.4 MB with attachments. Gmail takes up to 25 MB, so remove something.", "the 25 MB problem text")
        T.equal(ComposerSize.total(count: 3, estimate: 14_700_000), "3 attachments \u{00B7} 14.7 MB", "the tray's total line")
        let m = model(.new(from: RichMailCast.orb.id))
        m.to = RichMailCast.juniper.email
        m.attach(imageData: Data(count: 6_000_000), name: "Moodboard.zip", asFile: true)
        T.check(m.sizeWarning == nil && m.sizeProblem == nil, "8 MB encoded: no warning")
        m.attach(imageData: Data(count: 2_000_000), name: "Budget Q4.xlsx", asFile: true)
        T.check(m.sizeWarning == "Some mail servers refuse messages over 10 MB." && m.sizeProblem == nil, "over 10 MB: the warning")
        m.attach(imageData: Data(count: 11_000_000), name: "Tour footage.mov", asFile: true)
        T.check(m.sizeWarning == nil && m.sizeProblem?.hasPrefix("This comes to 26.") == true, "over 25 MB: the problem, no warning")
        guard case .failure(.tooLarge(let total)) = m.draft() else { T.check(false, "draft over 25 MB → .tooLarge"); return }
        T.check(total > MailSize.limit && total == m.estimatedSize, ".tooLarge carries the estimate")
        m.removeAttachment(m.attachments[2].id)
        if case .success = m.draft() { T.check(true, "removing a file brings it back under") } else { T.check(false, "under the limit again") }
    }

    // MARK: D-023 over a draft with attachments

    static func approvalWithAttachments() async {
        T.section("Rich mail: the approval card with attachments (D-023)")
        let actions = FakeMailActions(store: FakeMailStore())
        let m = model(.new(from: RichMailCast.orb.id), actions: actions)
        m.to = RichMailCast.juniper.display
        m.subject = "Label proofs"
        m.attach(imageData: png(30, 30), name: "proof.png", asFile: true)
        await m.send()
        T.check(m.approval?.outsiders == [RichMailCast.juniper.email] && actions.sent.isEmpty, "Send with someone outside: the card, nothing sent")
        await m.approveSend()
        let sent = actions.sent.last
        T.check(sent?.approvedOutside == [RichMailCast.juniper.email] && sent?.attachments.count == 1 && sent?.attachments.first?.filename == "proof.png",
                "approved: exactly the listed people, with the attachment")
    }

    // MARK: Signature logos

    static func signatureLogo() {
        T.section("Rich mail: signature logos")
        guard case .success(let run) = SignatureLogo.attachment(png(240, 64, alpha: true), name: "Orbital Pickle logo.png") else {
            T.check(false, "a small PNG logo is accepted"); return
        }
        let cid = run.attribute(.ycInlineImage, at: 0, effectiveRange: nil) as? String
        T.check(run.length == 1 && cid?.hasSuffix("@yayascalendar.local") == true, "the logo is an inline image with a content id")
        let doc = NSMutableAttributedString(attributedString: ComposerDocument.plain("Avery Moonfield\n", defaults: ComposerDocument.Defaults()))
        doc.append(run)
        let out = MailHTMLWriter.render(doc, font: .sans, size: 14)
        T.check(out.inlineImages.count == 1 && out.inlineImages[0].mimeType == "image/png" && out.html.contains("src=\"cid:\(cid ?? "?")\""),
                "the writer sends the logo byte for byte as a cid part")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 420, pixelsHigh: 420, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var x: UInt32 = 12345
        if let p = rep.bitmapData {
            for i in 0..<(420 * 420 * 4) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; p[i] = UInt8(truncatingIfNeeded: x) }
        }
        let noisy = rep.representation(using: .png, properties: [:])!
        if case .failure(let why) = SignatureLogo.attachment(noisy, name: "big.png") {
            T.check(why.description.hasSuffix("KB. Logos can be up to 200 KB.") && noisy.count > SignatureLogo.maxBytes, "over 200 KB is refused")
        } else { T.check(false, "over 200 KB is refused") }
        if case .failure(let why) = SignatureLogo.attachment(Data("GIF89a....".utf8), name: "a.gif") {
            T.equal(why.description, "Logos can be PNG or JPEG pictures.", "GIFs and other files are refused")
        } else { T.check(false, "a GIF is refused") }
    }

    static func keys() {
        T.section("Rich mail: Forward key")
        T.equal(InboxCommand.from(characters: "f", keyCode: 3, commandKeys: false), .forward, "F forwards")
        T.equal(InboxCommand.from(characters: "f", keyCode: 3, commandKeys: true), nil, "⌘F belongs to menus")
    }
}
