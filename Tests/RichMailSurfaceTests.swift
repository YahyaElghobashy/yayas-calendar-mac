import AppKit
import Foundation

/// Rich mail, shell tests: the seam defaults, the empty attachment store,
/// the Moonfield cast (D-028) (fictional, `.example` only) and the generated attachment bytes renders will use.
@MainActor
enum RichMailSurfaceTests {
    static func run() async {
        seam()
        await emptyAttachmentStore()
        cast()
        await fakeAttachments()
    }

    static func seam() {
        T.section("Rich mail: seam")
        let a = MailMessage.Attachment(name: "Launch plan.pdf", bytes: 2_400_000)
        T.check(a.id.isEmpty && a.mimeType.isEmpty && a.contentId == nil && !a.isInline, "Attachment(name:bytes:) keeps its meaning")
        let draft = MailDraft(from: RichMailCast.orb.id, to: ["juniper@vale.example"], subject: "Labels", body: "Hi\n", replyTo: nil)
        T.check(draft.html == nil && draft.attachments.isEmpty && draft.quote == nil && !draft.signatureIncluded,
                "MailDraft defaults: plain text, no files, no quote, signature not included")
        let file = MailDraftAttachment(filename: "Launch plan.pdf", mimeType: "application/pdf",
                                       file: URL(fileURLWithPath: "/dev/null"), bytes: 1, contentId: nil)
        var rich = draft
        rich.html = "<div>Hi</div>"
        rich.attachments = [file]
        rich.quote = MailQuoteRequest(threadR: "rm-gmail-reply", messageId: "m1", kind: .reply)
        rich.signatureIncluded = true
        T.check(rich != draft && rich.quote?.style == .bar, "rich draft fields are part of equality; quote style defaults to bar")
        T.equal([MailQuoteRequest.Kind.reply, .forward].map(\.rawValue), ["reply", "forward"], "quote kinds")
        T.check(MailAccountPrefs(primaryOnly: true, signature: "Avery").signatureRich == nil, "MailAccountPrefs.signatureRich defaults to nil")
    }

    static func emptyAttachmentStore() async {
        T.section("Rich mail: empty attachment store")
        T.check(Services.mailAttachments is EmptyStores, "Services.mailAttachments starts as EmptyStores")
        let store: MailAttachmentStore = EmptyStores.shared
        var message = ""
        do {
            _ = try await store.file(threadR: "rm-attachments", messageId: "m1", partId: "2")
        } catch {
            message = "\(error)"
        }
        T.equal(message, "not wired", "file() before wiring")
        T.check(store.cachedFile(threadR: "rm-attachments", messageId: "m1", partId: "2") == nil, "nothing cached")
        T.check(store.usage() == (0, 0), "usage (0, 0)")
        T.check((try? store.clear()) != nil, "clear() is a no-op")
    }

    static func cast() {
        T.section("Rich mail: cast (D-028)")
        T.check(RichMailCast.allAddresses.allSatisfy { $0.hasSuffix(".example") && $0.contains("@") }, "every address is under .example")
        T.equal(RichMailCast.accounts.map(\.key), ["orb", "cmt", "fam", "home"], "account keys")
        T.equal(RichMailCast.accounts.map { $0.id.uuidString.suffix(2) }.map(String.init), ["E1", "E2", "E3", "E4"], "E-series UUIDs")
        T.equal(Set(RichMailCast.accounts.map(\.id)).count, 4, "distinct account ids")
        let names = Set(RichMailCast.people.map(\.name) + [RichMailCast.comets.name, RichMailCast.owner])
        T.check(RichMailThreads.all.allSatisfy { names.contains($0.sender.name) }, "every thread sender is in the cast")
        T.equal(RichMailThreads.all.map(\.r), ["rm-newsletter", "rm-gmail-reply", "rm-outlook-reply", "rm-apple-reply", "rm-plain",
                                              "rm-attachments", "rm-inline-images"], "thread fixtures")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let threads = RichMailThreads.threads(now: now)
        T.check(threads.allSatisfy { $0.at < now } && threads.map(\.at) == threads.map(\.at).sorted(by: >),
                "threads are newest first, before the harness now")
        T.equal(RichMailThreads.longName.count, 120, "long attachment name length")
        T.check(RichMailThreads.bidiName.unicodeScalars.contains("\u{202E}"), "bidi-override name carries U+202E")
        let ids = RichMailThreads.attachmentList.map(\.id)
        T.equal(Set(ids).count, ids.count, "attachment part ids are unique")
        T.check(RichMailThreads.attachmentList.allSatisfy { !$0.isInline && !$0.mimeType.isEmpty }, "file attachments are not inline")
        T.equal(RichMailThreads.inlineImageList.filter(\.isInline).compactMap(\.contentId),
                ["dock-1@moonfield-family.example", "dock-2@moonfield-family.example"], "inline cid photos")
    }

    static func fakeAttachments() async {
        T.section("Rich mail: generated attachment bytes")
        let folder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("richmail-scratch", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let store = FakeMailAttachments(folder: folder)
        let r = RichMailThreads.attachments.r
        let pdf = try? await store.file(threadR: r, messageId: r + "-1", partId: "2")
        let size = pdf.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.intValue }
        T.equal(size, 2_400_000, "filler has the declared size")
        T.check(pdf.map { !$0.lastPathComponent.contains("Launch") && $0.path.hasPrefix(folder.path) } == true,
                "files land in the caller's folder under a name with no sender text")
        let jpg = try? await store.file(threadR: r, messageId: r + "-1", partId: "5")
        T.check(jpg.flatMap { NSImage(contentsOf: $0) }.map { $0.size.width > 0 } == true, "image parts decode as images")
        let logo = RichMailThreads.newsletter.r
        let png = try? await store.file(threadR: logo, messageId: logo + "-1", partId: "1.2")
        let rep = png.flatMap { try? Data(contentsOf: $0) }.flatMap { NSBitmapImageRep(data: $0) }
        T.check(rep?.pixelsWide == 240 && rep?.pixelsHigh == 64, "the newsletter logo is a 240 × 64 PNG")
        _ = try? await store.file(threadR: r, messageId: r + "-1", partId: "2")
        T.equal(store.requests.count, 4, "every call is logged")
        T.check(store.cachedFile(threadR: r, messageId: r + "-1", partId: "2") == pdf, "cachedFile returns the written file")
        T.equal(store.usage().files, 3, "usage counts written files")
        var failed = false
        do { _ = try await store.file(threadR: r, messageId: r + "-1", partId: "99") } catch { failed = true }
        T.check(failed, "an unknown part throws")
        try? store.clear()
        T.check(store.usage() == (0, 0) && pdf.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "clear removes the files")
        try? FileManager.default.removeItem(at: folder)
    }
}
