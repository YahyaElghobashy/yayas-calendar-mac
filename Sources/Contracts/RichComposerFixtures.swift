// Test doubles and sample data (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench,
// --selftest and the test runners). Release builds (plain ./build.sh, --install, --release) leave them out.
#if YC_DEV_TOOLS
import AppKit
import Foundation

// Rich composer fixtures (D-042): the fictional Moonfield desk only. The four cast
// accounts as the composer's directory, their signatures (Orbital Pickle Co. has a rich one, The Quiet Comets and
// Moonfield Family plain ones, Personal none), and Juniper Vale's message the reply renders and tests answer. Dates
// come from the caller's `now`. Compiled into dev builds (-D YC_DEV_TOOLS) and the shell tests: Foundation, AppKit,
// the seam, the directory and Sources/UI/RichMail only.

enum RichComposerFixtures {
    static func directory() -> AccountDirectory {
        AccountDirectory(accounts: RichMailCast.accounts.map {
            DirectoryAccount(id: $0.id, tag: $0.tag, name: $0.name, email: $0.email, color: $0.color, logo: nil)
        })
    }

    static let orbPlainSignature = "Avery Moonfield\nOrbital Pickle Co. \u{00B7} Suite 404\norbitalpickle.example"
    static let cometsSignature = "Avery Moonfield\nThe Quiet Comets"
    static let familySignature = "Avery"

    /// Orbital Pickle Co.'s rich signature: the name in bold, the company in teal, the site linked.
    static func orbRichSignature() -> NSAttributedString {
        let d = ComposerDocument.Defaults()
        let s = NSMutableAttributedString(attributedString: ComposerDocument.plain(orbPlainSignature, defaults: d))
        let ns = s.string as NSString
        s.addAttribute(.font, value: FontChoice.sans.font(size: 14, bold: true), range: ns.range(of: "Avery Moonfield"))
        s.addAttribute(.foregroundColor, value: ComposerDocument.color(0x12808C), range: ns.range(of: "Orbital Pickle Co."))
        s.addAttribute(.font, value: FontChoice.sans.font(size: 12), range: ns.range(of: "\u{00B7} Suite 404"))
        s.addAttribute(.foregroundColor, value: ComposerDocument.color(0x5F6368), range: ns.range(of: "\u{00B7} Suite 404"))
        s.addAttribute(.link, value: "https://orbitalpickle.example", range: ns.range(of: "orbitalpickle.example"))
        return s
    }

    /// Mail preferences for the cast (memory only).
    static func prefs() -> FakeMailPreferences {
        let prefs = FakeMailPreferences(signatures: false)
        let rich: Data? = {
            if case .success(let data) = RichSignature.storable(orbRichSignature()) { return data }
            return nil
        }()
        prefs.stored[RichMailCast.orb.id] = MailAccountPrefs(primaryOnly: false, signature: orbPlainSignature, signatureRich: rich)
        prefs.stored[RichMailCast.cmt.id] = MailAccountPrefs(primaryOnly: false, signature: cometsSignature)
        prefs.stored[RichMailCast.fam.id] = MailAccountPrefs(primaryOnly: true, signature: familySignature)
        prefs.stored[RichMailCast.home.id] = MailAccountPrefs(primaryOnly: true, signature: "")
        return prefs
    }

    /// Juniper Vale's latest message in `rm-gmail-reply` (Gmail-shaped HTML, already as the sanitizer leaves it).
    static func juniperMessage(now: Date) -> MailMessage {
        let fixture = RichMailThreads.gmailReply
        let html = """
        <div dir="ltr">Hi Avery,<div><br></div><div>Love the new labels. One question before we print: are we keeping the \
        <b>teal lid</b> for the dill jars, or switching to the <span style="color:#c5221f">red</span> one from the \
        Café Nowhere tasting?</div><div><br></div><div>Proofs are due Thursday.</div><div><br></div><div>Juniper</div></div>
        """
        let text = "Hi Avery,\n\nLove the new labels. One question before we print: are we keeping the teal lid for the dill jars, "
            + "or switching to the red one from the Café Nowhere tasting?\n\nProofs are due Thursday.\n\nJuniper"
        return MailMessage(id: fixture.r + "-3", from: RichMailCast.juniper.name, fromEmail: RichMailCast.juniper.email,
                           to: [RichMailCast.orb.email], cc: [RichMailCast.milo.display],
                           date: now.addingTimeInterval(-Double(fixture.minutesAgo) * 60), subject: "Re: Pickle jar labels",
                           html: html, text: text, hasRemoteImages: false, attachments: [])
    }

    static func juniperReply(now: Date, all: Bool = false) -> ComposerRequest {
        .reply(RichMailThreads.gmailReply.thread(now: now), juniperMessage(now: now), all: all)
    }

    /// A cast message as the reader hands it to Forward (its HTML as sent; the composer only shows it read-only).
    static func message(_ body: RichMailBodies.Message, now: Date, attachments: [MailMessage.Attachment]? = nil) -> MailMessage {
        MailMessage(id: body.id, from: body.from.name, fromEmail: body.from.email, to: body.to, cc: body.cc, date: body.date(now: now),
                    subject: body.subject, html: body.html, text: body.text, hasRemoteImages: false,
                    attachments: attachments ?? body.attachments, isPlainText: body.html == nil)
    }

    /// Forward of Priya Starling's "Q4 pickle launch plan" with three of its files (plan, budget, menu photo).
    static func priyaForward(now: Date) -> ComposerRequest {
        let files = RichMailThreads.attachmentList.filter { ["2", "3", "5"].contains($0.id) }
        return .forward(RichMailThreads.attachments.thread(now: now), message(RichMailBodies.attachments, now: now, attachments: files))
    }

    /// Forward of Kofi Ember's lake-house photos: two inline photos (they stay with the quoted original) and a file.
    static func kofiForward(now: Date) -> ComposerRequest {
        .forward(RichMailThreads.inlineImages.thread(now: now), message(RichMailBodies.inlineImages, now: now))
    }
}
#endif
