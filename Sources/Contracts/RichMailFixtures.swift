// Test doubles and sample data (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench,
// --selftest and the test runners). Release builds (plain ./build.sh, --install, --release) leave them out.
#if YC_DEV_TOOLS
import AppKit
import Foundation

// Rich-mail fixtures (D-040 to D-044): the fictional Moonfield desk only.
// Every address is under `.example`; every name comes from the cast below. Dates come from the caller's `now`
// (the render harness or a test clock): nothing here pins a time zone or an offset. `RichMailBodies` holds the
// messages as their senders sent them (raw HTML or plain text, Gmail part ids); the render harness puts them
// through the real pipeline (parser, sanitizer, MailQuote, MailPlainText). Compiled into dev builds (-D YC_DEV_TOOLS)
// and the shell tests, so this file uses only Foundation, AppKit and the seam (Stores.swift): no Sources/Mail code.

// MARK: - Cast

enum RichMailCast {
    static let owner = "Avery Moonfield"

    struct Account: Equatable {
        var key: String
        var id: UUID
        var tag: String
        var name: String
        var email: String
        /// The cast swatch (Shared/Widgets/Cast.swift, brand/BRAND.md).
        var color: UInt32
    }

    static let orb = Account(key: "orb", id: UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!, tag: "ORB",
                             name: "Orbital Pickle Co.", email: "avery@orbitalpickle.example", color: 0x8DBA74)
    static let cmt = Account(key: "cmt", id: UUID(uuidString: "00000000-0000-4000-8000-0000000000E2")!, tag: "CMT",
                             name: "The Quiet Comets", email: "avery@quietcomets.example", color: 0x7F96E8)
    static let fam = Account(key: "fam", id: UUID(uuidString: "00000000-0000-4000-8000-0000000000E3")!, tag: "FAM",
                             name: "Moonfield Family", email: "avery@moonfield-family.example", color: 0xE07A80)
    static let home = Account(key: "home", id: UUID(uuidString: "00000000-0000-4000-8000-0000000000E4")!, tag: "Personal",
                              name: "Personal", email: "avery@home.example", color: 0xD2A6C6)
    static let accounts = [orb, cmt, fam, home]

    struct Person: Equatable {
        var name: String
        var email: String
        var display: String { "\(name) <\(email)>" }
    }

    static let juniper = Person(name: "Juniper Vale", email: "juniper@vale.example")
    static let milo = Person(name: "Milo Brightwater", email: "milo@brightwater.example")
    static let priya = Person(name: "Priya Starling", email: "priya@starling.example")
    static let theo = Person(name: "Theo Quill", email: "theo@quill.example")
    static let ines = Person(name: "Ines Marlowe", email: "ines@marlowe.example")
    static let kofi = Person(name: "Kofi Ember", email: "kofi@ember.example")
    static let mom = Person(name: "Mom", email: "mom@moonfield-family.example")
    /// The band's newsletter sender (remote images live on cdn.quietcomets.example).
    static let comets = Person(name: "The Quiet Comets", email: "news@quietcomets.example")
    static let people = [juniper, milo, priya, theo, ines, kofi, mom]

    static let places = ["Café Nowhere", "Suite 404", "The lake house"]

    /// Every account address and every sender, for the gate's cast-only check.
    static var allAddresses: [String] { accounts.map(\.email) + people.map(\.email) + [comets.email] }
}

// MARK: - Threads

enum RichMailThreads {
    struct Fixture: Equatable {
        var r: String
        var account: RichMailCast.Account
        var sender: RichMailCast.Person
        var subject: String
        var snippet: String
        /// Minutes before the harness `now`.
        var minutesAgo: Int
        var messageCount: Int
        var unread = false
        /// What the render shows.
        var usedFor: String

        func thread(now: Date) -> MailThread {
            MailThread(r: r, accountId: account.id, sender: sender.name, senderEmail: sender.email, subject: subject,
                       snippet: snippet, at: now.addingTimeInterval(-Double(minutesAgo) * 60), unread: unread,
                       starred: false, messageCount: messageCount)
        }
    }

    static let newsletter = Fixture(
        r: "rm-newsletter", account: RichMailCast.cmt, sender: RichMailCast.comets, subject: "Comets Weekly \u{00B7} Tour dates",
        snippet: "Three new dates, a rehearsal at the lake house and a new merch table.", minutesAgo: 18, messageCount: 1,
        unread: true, usedFor: "HTML, blocked images + cid still shown, fit-to-width")
    static let gmailReply = Fixture(
        r: "rm-gmail-reply", account: RichMailCast.orb, sender: RichMailCast.juniper, subject: "Re: Pickle jar labels",
        snippet: "Love the new labels. One question about the lid colour before we print.", minutesAgo: 42, messageCount: 3,
        unread: true, usedFor: "quoted history collapsed / expanded (two gmail_quote levels)")
    static let outlookReply = Fixture(
        r: "rm-outlook-reply", account: RichMailCast.orb, sender: RichMailCast.milo, subject: "RE: Moving into Suite 404",
        snippet: "Keys are ready on Thursday. The whiteboard stays.", minutesAgo: 95, messageCount: 2,
        usedFor: "Outlook detection (#divRplyFwdMsg + <hr>)")
    static let appleReply = Fixture(
        r: "rm-apple-reply", account: RichMailCast.fam, sender: RichMailCast.mom, subject: "Re: Sunday at the lake house",
        snippet: "Bring the big blanket. I'll make the lemon cake.", minutesAgo: 130, messageCount: 2,
        usedFor: "Apple detection (blockquote type=cite + On … wrote:)")
    static let plain = Fixture(
        r: "rm-plain", account: RichMailCast.home, sender: RichMailCast.theo, subject: "Notes from Café Nowhere",
        snippet: "Here are the notes, plus the link to the set list.", minutesAgo: 200, messageCount: 1,
        usedFor: "plain viewer (links, quote levels 1-2, -- signature, format=flowed)")
    static let attachments = Fixture(
        r: "rm-attachments", account: RichMailCast.orb, sender: RichMailCast.priya, subject: "Q4 pickle launch plan",
        snippet: "Plan, budget, moodboard and the menu from Café Nowhere attached.", minutesAgo: 260, messageCount: 1,
        unread: true, usedFor: "chips, previews, risky glyph")
    static let inlineImages = Fixture(
        r: "rm-inline-images", account: RichMailCast.fam, sender: RichMailCast.kofi, subject: "Photos from the lake house",
        snippet: "Two from the dock, and the panorama as a file.", minutesAgo: 330, messageCount: 1,
        usedFor: "inline images + preview")

    static let all = [newsletter, gmailReply, outlookReply, appleReply, plain, attachments, inlineImages]

    static func threads(now: Date) -> [MailThread] { all.map { $0.thread(now: now) } }

    /// A 120-character file name (chip truncation).
    static let longName = "Orbital Pickle Co. Q4 launch plan with the full timeline, owners, budget notes and open questions from Suite 404, v7.pdf"
    /// A right-to-left override that makes "exe" read as "pdf" (shown sanitized, with the real extension badge).
    static let bidiName = "invoice\u{202E}fdp.exe"

    /// `rm-attachments`: the file attachments as the reader receives them (Gmail part ids, MIME types).
    static let attachmentList: [MailMessage.Attachment] = [
        .init(name: "Launch plan.pdf", bytes: 2_400_000, id: "2", mimeType: "application/pdf"),
        .init(name: "Budget Q4.xlsx", bytes: 186_000, id: "3",
              mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        .init(name: "Moodboard.zip", bytes: 12_000_000, id: "4", mimeType: "application/zip"),
        .init(name: "Café Nowhere menu.jpg", bytes: 640_000, id: "5", mimeType: "image/jpeg"),
        .init(name: "Rehearsal.ics", bytes: 2_100, id: "6", mimeType: "text/calendar"),
        .init(name: "Installer.dmg", bytes: 3_100_000, id: "7", mimeType: "application/x-apple-diskimage"),
        .init(name: longName, bytes: 88_000, id: "8", mimeType: "application/pdf"),
        .init(name: bidiName, bytes: 41_000, id: "9", mimeType: "application/octet-stream"),
    ]

    /// `rm-inline-images`: two cid photos drawn in the body, plus a HEIC file attachment.
    static let inlineImageList: [MailMessage.Attachment] = [
        .init(name: "dock-1.jpg", bytes: 410_000, id: "1.2", mimeType: "image/jpeg",
              contentId: "dock-1@moonfield-family.example", isInline: true),
        .init(name: "dock-2.jpg", bytes: 380_000, id: "1.3", mimeType: "image/jpeg",
              contentId: "dock-2@moonfield-family.example", isInline: true),
        .init(name: "Lake house.heic", bytes: 1_800_000, id: "2", mimeType: "image/heic"),
    ]

    /// `rm-newsletter`: the band's logo, sent inline (shown even while remote images are blocked).
    static let newsletterLogo = MailMessage.Attachment(name: "comets-logo.png", bytes: 24_000, id: "1.2", mimeType: "image/png",
                                                       contentId: "comets-logo@quietcomets.example", isInline: true)
}

// MARK: - Message bodies (the viewer)

/// Every message of the rich-mail threads, as received: the HTML part as the sender wrote it (each client's own
/// quoting markup), or the plain text (format=flowed where the sender's client uses it). Message ids are the
/// thread's r + "-1" (newest) and up; attachments carry the Gmail part ids `FakeMailAttachments` serves.
enum RichMailBodies {
    struct Message: Equatable {
        var id: String
        var from: RichMailCast.Person
        var to: [String]
        var cc: [String] = []
        var subject: String
        var minutesAgo: Int
        /// The text/html part as sent (unsanitized); nil = a plain-text message.
        var html: String?
        /// The text/plain part (for HTML mail: Gmail's alternative).
        var text: String
        var flowed = false
        /// Files and inline (cid) parts with their part ids.
        var attachments: [MailMessage.Attachment] = []

        func date(now: Date) -> Date { now.addingTimeInterval(-Double(minutesAgo) * 60) }
    }

    static func owner(_ account: RichMailCast.Account) -> RichMailCast.Person { RichMailCast.Person(name: RichMailCast.owner, email: account.email) }

    /// The thread's messages, oldest first.
    static func messages(_ fixture: RichMailThreads.Fixture) -> [Message] {
        switch fixture.r {
        case RichMailThreads.newsletter.r: return [newsletter]
        case RichMailThreads.gmailReply.r: return gmailReply
        case RichMailThreads.outlookReply.r: return outlookReply
        case RichMailThreads.appleReply.r: return appleReply
        case RichMailThreads.plain.r: return [plain]
        case RichMailThreads.attachments.r: return [attachments]
        case RichMailThreads.inlineImages.r: return [inlineImages]
        default: return []
        }
    }

    // MARK: rm-newsletter

    /// The hero image, the tracking pixel: remote (cdn / t.quietcomets.example), blocked until allowed.
    static let heroURL = "https://cdn.quietcomets.example/news/tour-2026.jpg"
    static let pixelURL = "https://t.quietcomets.example/open.gif?n=42"

    static func tourRow(_ day: String, _ place: String, _ note: String, _ link: String) -> String {
        "<tr><td style=\"padding:11px 0;border-bottom:1px solid #E6E0F0;font-weight:bold;color:#2A1B4A;width:118px;font-size:14px\">\(day)</td>"
            + "<td style=\"padding:11px 8px;border-bottom:1px solid #E6E0F0;color:#3A3550;font-size:14px\">\(place)"
            + "<div style=\"color:#8A84A0;font-size:12px\">\(note)</div></td>"
            + "<td align=\"right\" style=\"padding:11px 0;border-bottom:1px solid #E6E0F0\"><a href=\"https://tickets.quietcomets.example/\(link)\" "
            + "style=\"color:#5B3FA8;font-weight:bold;font-size:13px;text-decoration:none\">Tickets \u{2192}</a></td></tr>"
    }

    static let tourRows = tourRow("Fri 6 Nov", "Caf\u{00E9} Nowhere", "Doors 8 pm, two sets", "cafe-nowhere-fri")
        + tourRow("Sat 7 Nov", "Caf\u{00E9} Nowhere", "Second night, new songs", "cafe-nowhere-sat")
        + tourRow("Sun 15 Nov", "The lake house", "Open rehearsal, friends of the band", "lake-house")
        + tourRow("Thu 26 Nov", "Suite 404", "Listening party, small room", "suite-404")

    static let newsletterHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>Comets Weekly</title><style>
    body{margin:0;padding:0;background:#EDE7F6}
    h1{font:800 27px/1.18 Georgia,'Times New Roman',serif;color:#2A1B4A;margin:0 0 12px}
    .lede{font-size:15px;line-height:1.6;color:#3A3550;margin:0 0 6px}
    </style></head><body bgcolor="#EDE7F6" style="margin:0;background:#EDE7F6">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#EDE7F6"><tr><td align="center" style="padding:22px 0 28px">
    <table class="inner" role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;background:#FFFFFF;border-radius:12px;font-family:Helvetica,Arial,sans-serif">
    <tr><td style="background:#2A1B4A;padding:16px 28px;border-radius:12px 12px 0 0"><a name="top"></a>\
    <img src="cid:comets-logo@quietcomets.example" width="120" height="32" alt="The Quiet Comets" style="display:block;border:0"></td></tr>
    <tr><td><img src="\(heroURL)" width="600" height="220" alt="The band on the dock at the lake house" style="display:block;width:600px;border:0"></td></tr>
    <tr><td style="padding:26px 28px 8px">
    <div style="font-size:12px;font-weight:bold;letter-spacing:1.5px;color:#5B3FA8;margin-bottom:8px">COMETS WEEKLY \u{00B7} TOUR DATES</div>
    <h1>Three new dates. One very small stage.</h1>
    <p class="lede">We\u{2019}re playing Caf\u{00E9} Nowhere twice in November, and the rehearsal at the lake house is open to friends of the band. \
    The merch table is back, with the glow-in-the-dark pickle jar from Orbital Pickle Co.</p>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:16px 0 4px">\(tourRows)</table>
    </td></tr>
    <tr><td style="padding:14px 28px 26px"><table role="presentation" cellpadding="0" cellspacing="0"><tr>\
    <td bgcolor="#5B3FA8" style="border-radius:7px"><a href="https://tickets.quietcomets.example/" \
    style="display:inline-block;padding:12px 22px;color:#FFFFFF;font-weight:bold;font-size:14px;text-decoration:none">See every date</a></td>\
    <td style="padding-left:16px;font-size:13px;color:#8A84A0">or reply to this email with a question</td></tr></table></td></tr>
    <tr><td style="padding:16px 28px;background:#F6F3FB;border-radius:0 0 12px 12px;font-size:12px;line-height:1.5;color:#8A84A0">\
    You\u{2019}re getting this because you signed up at a show. \
    <a href="https://quietcomets.example/unsubscribe" style="color:#8A84A0">Unsubscribe</a> \u{00B7} \
    <a href="#top" style="color:#8A84A0">Back to top</a>\
    <img src="\(pixelURL)" width="1" height="1" alt="" style="display:block;border:0"></td></tr>
    </table></td></tr></table></body></html>
    """

    static let newsletter = Message(
        id: "rm-newsletter-1", from: RichMailCast.comets, to: [RichMailCast.cmt.email], subject: RichMailThreads.newsletter.subject,
        minutesAgo: RichMailThreads.newsletter.minutesAgo, html: newsletterHTML,
        text: "Comets Weekly \u{00B7} Tour dates\n\nThree new dates. One very small stage.\n\nFri 6 Nov, Caf\u{00E9} Nowhere\nSat 7 Nov, Caf\u{00E9} Nowhere\nSun 15 Nov, The lake house\nThu 26 Nov, Suite 404",
        attachments: [RichMailThreads.newsletterLogo])

    // MARK: rm-gmail-reply (Gmail's own markup, two levels of gmail_quote)

    static let gq = "margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"

    static let gmailReply: [Message] = {
        let r = RichMailThreads.gmailReply
        let juniper = RichMailCast.juniper, me = owner(RichMailCast.orb)
        let first = """
        <div dir="ltr">Hi Avery,<div><br></div><div>Can we see the labels with a bigger dill sprig? And the jar outline looks a bit wobbly on \
        the left.</div><div><br></div><div>Juniper</div></div>
        """
        let second = """
        <div dir="ltr">Here are the label proofs, v3. The jar outline is fixed and the dill sprig is bigger.<div><br></div><div>Avery</div></div>\
        <br><div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">On Sun, 18 Oct at 17:40, Juniper Vale &lt;\
        <a href="mailto:juniper@vale.example">juniper@vale.example</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="\(gq)">\(first)</blockquote></div>
        """
        let latest = """
        <div dir="ltr"><div>Hi Avery,</div><div><br></div><div>Love the new labels! One question about the lid colour before we print: \
        <b>dill green</b> or <b>brine blue</b>? The printer at Suite 404 needs to know by Thursday.</div><div><br></div>\
        <div>Proofs: <a href="https://proofs.orbitalpickle.example/labels/v3?print=thursday">proofs.orbitalpickle.example/labels/v3</a></div>\
        <div><br></div><div>Juniper</div></div><br><div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">\
        On Mon, 19 Oct at 08:12, Avery Moonfield &lt;<a href="mailto:avery@orbitalpickle.example">avery@orbitalpickle.example</a>&gt; wrote:<br></div>\
        <blockquote class="gmail_quote" style="\(gq)">\(second)</blockquote></div>
        """
        return [
            Message(id: "\(r.r)-3", from: juniper, to: [me.email], subject: "Pickle jar labels", minutesAgo: r.minutesAgo + 900, html: first,
                    text: "Hi Avery,\n\nCan we see the labels with a bigger dill sprig? And the jar outline looks a bit wobbly on the left.\n\nJuniper"),
            Message(id: "\(r.r)-2", from: me, to: [juniper.email], subject: "Re: Pickle jar labels", minutesAgo: r.minutesAgo + 95, html: second,
                    text: "Here are the label proofs, v3. The jar outline is fixed and the dill sprig is bigger.\n\nAvery"),
            Message(id: "\(r.r)-1", from: juniper, to: [me.email], cc: [RichMailCast.priya.display], subject: r.subject, minutesAgo: r.minutesAgo,
                    html: latest, text: "Hi Avery,\n\nLove the new labels! One question about the lid colour before we print: dill green or brine blue?"),
        ]
    }()

    // MARK: rm-outlook-reply (Outlook on the web: appendonsend, <hr>, #divRplyFwdMsg)

    static let outlookReply: [Message] = {
        let r = RichMailThreads.outlookReply
        let milo = RichMailCast.milo, me = owner(RichMailCast.orb)
        let original = "<div dir=\"ltr\">Hi Milo,<br><br>When can we pick up the keys for Suite 404? And does the whiteboard stay?<br><br>Avery</div>"
        let font = "font-family: Aptos, Calibri, Helvetica, sans-serif; font-size: 12pt; color: rgb(0, 0, 0);"
        let latest = """
        <html><head><style type="text/css" style="display:none;">P {margin-top:0;margin-bottom:0;}</style></head><body dir="ltr">\
        <div class="elementToProof" style="\(font)">Hi Avery,</div><div class="elementToProof" style="\(font)"><br></div>\
        <div class="elementToProof" style="\(font)">Keys are ready on Thursday at reception. The whiteboard stays, and so does the plant in the corner \
        if you want it.</div><div class="elementToProof" style="\(font)"><br></div><div class="elementToProof" style="\(font)">Milo</div>\
        <div id="appendonsend"></div><hr style="display:inline-block;width:98%" tabindex="-1">\
        <div id="divRplyFwdMsg" dir="ltr"><font face="Calibri, sans-serif" style="font-size:11pt" color="#000000"><b>From:</b> Avery Moonfield \
        &lt;avery@orbitalpickle.example&gt;<br><b>Sent:</b> Sunday, 18 October 09:30<br><b>To:</b> Milo Brightwater &lt;milo@brightwater.example&gt;\
        <br><b>Subject:</b> Moving into Suite 404</font><div>&nbsp;</div></div>\(original)</body></html>
        """
        return [
            Message(id: "\(r.r)-2", from: me, to: [milo.email], subject: "Moving into Suite 404", minutesAgo: r.minutesAgo + 1_400, html: original,
                    text: "Hi Milo,\n\nWhen can we pick up the keys for Suite 404? And does the whiteboard stay?\n\nAvery"),
            Message(id: "\(r.r)-1", from: milo, to: [me.email], subject: r.subject, minutesAgo: r.minutesAgo, html: latest,
                    text: "Hi Avery,\n\nKeys are ready on Thursday at reception. The whiteboard stays.\n\nMilo"),
        ]
    }()

    // MARK: rm-apple-reply (iOS Mail: the attribution and the quote as sibling blockquotes)

    static let appleReply: [Message] = {
        let r = RichMailThreads.appleReply
        let mom = RichMailCast.mom, me = owner(RichMailCast.fam)
        let original = "<div dir=\"ltr\">Is Sunday at the lake house still on? I can bring the speaker and some lemonade.</div>"
        let latest = """
        <html><head><meta http-equiv="content-type" content="text/html; charset=utf-8"></head><body dir="auto">\
        <div dir="ltr">Bring the big blanket. I\u{2019}ll make the lemon cake.</div><div dir="ltr"><br></div>\
        <div dir="ltr">Love, Mom</div><div dir="ltr"><br><blockquote type="cite">On 18 Oct 2026, at 19:02, Avery Moonfield \
        &lt;avery@moonfield-family.example&gt; wrote:<br><br></blockquote></div><blockquote type="cite">\(original)</blockquote></body></html>
        """
        return [
            Message(id: "\(r.r)-2", from: me, to: [mom.email], subject: "Sunday at the lake house", minutesAgo: r.minutesAgo + 600, html: original,
                    text: "Is Sunday at the lake house still on? I can bring the speaker and some lemonade."),
            Message(id: "\(r.r)-1", from: mom, to: [me.email], subject: r.subject, minutesAgo: r.minutesAgo, html: latest,
                    text: "Bring the big blanket. I\u{2019}ll make the lemon cake.\n\nLove, Mom"),
        ]
    }()

    // MARK: rm-plain (format=flowed: links, quote levels 1-2, a table, a "-- " signature)

    /// A source line ending in a space and a backslash, then an empty source line, is a flowed soft break.

    static let plainText = """
    Hi Avery,

    On Sun, 18 Oct at 22:10, Avery Moonfield <avery@home.example> wrote:
    > Great show! Can you send the set list and the notes from \

    > Caf\u{00E9} Nowhere?

    Here they are. The set list is on the shared board: \

    https://board.quill.example/sets/cafe-nowhere

    > Ines said the sound was the best yet:
    >> Let's book Caf\u{00E9} Nowhere again for November.

    Yes please. I'll ask about 6 and 7 November.

    Running order:
    Song              Key    Length
    Lid Off           D      3:40
    Brine Time        G      4:05
    Dill With It      E      2:55

    Kofi asked whether we can borrow the lake house PA again. Can you check \

    with your mom (mom@moonfield-family.example)?

    --\u{20}
    Theo Quill
    www.quill.example
    """

    static let plain = Message(
        id: "rm-plain-1", from: RichMailCast.theo, to: [RichMailCast.home.email], subject: RichMailThreads.plain.subject,
        minutesAgo: RichMailThreads.plain.minutesAgo, html: nil,
        text: plainText, flowed: true)

    // MARK: rm-attachments

    static let attachments = Message(
        id: "rm-attachments-1", from: RichMailCast.priya, to: [RichMailCast.orb.email], cc: [RichMailCast.juniper.display],
        subject: RichMailThreads.attachments.subject, minutesAgo: RichMailThreads.attachments.minutesAgo, html: nil,
        text: """
        Hi Avery,

        Attached: the launch plan, the Q4 budget, the moodboard and the menu from Caf\u{00E9} Nowhere for the tasting. \
        The rehearsal invite is in there too.

        The installer is the label printer's driver. Only open it if you need it.

        Priya
        """,
        attachments: RichMailThreads.attachmentList)

    // MARK: rm-inline-images

    static let inlineImages = Message(
        id: "rm-inline-images-1", from: RichMailCast.kofi, to: [RichMailCast.fam.email], subject: RichMailThreads.inlineImages.subject,
        minutesAgo: RichMailThreads.inlineImages.minutesAgo,
        html: """
        <div dir="ltr">Two from the dock this morning:<br><br>\
        <img src="cid:dock-1@moonfield-family.example" alt="The dock in the morning" width="480" height="320"><br><br>\
        <img src="cid:dock-2@moonfield-family.example" alt="The dock from the water" width="480" height="320"><br><br>\
        The panorama is attached as a file (it\u{2019}s huge).<br><br>Kofi</div>
        """,
        text: "Two from the dock this morning.\n\nThe panorama is attached as a file.\n\nKofi",
        attachments: RichMailThreads.inlineImageList)
}

// MARK: - Attachment bytes

/// `MailAttachmentStore` for renders and tests: bytes generated in code (no binary assets), written lazily into a
/// scratch folder the caller owns (renders: `<dir>/scratch`; never Application Support). Images are solid-colour
/// PNG/JPEG with a simple shape; every other type is filler of the declared size.
final class FakeMailAttachments: MailAttachmentStore {
    struct Part {
        var threadR: String
        var messageId: String
        var partId: String
        var mimeType: String
        var bytes: Int
        /// Pixel size for generated images.
        var pixels: (width: Int, height: Int) = (640, 400)
        var color: UInt32 = 0x7FA7D9
    }

    let folder: URL
    private let lock = NSLock()
    private var parts: [String: Part] = [:]
    private var written: [String: URL] = [:]
    private var requestLog: [String] = []

    init(folder: URL, parts: [Part] = FakeMailAttachments.cast) {
        self.folder = folder
        for part in parts { self.parts[Self.key(part.threadR, part.messageId, part.partId)] = part }
    }

    /// The cast's parts: every attachment and inline image in `RichMailThreads` (message id = the thread's r + "-1").
    static var cast: [Part] {
        func parts(_ fixture: RichMailThreads.Fixture, _ list: [MailMessage.Attachment], color: UInt32) -> [Part] {
            list.enumerated().map { i, a in
                Part(threadR: fixture.r, messageId: fixture.r + "-1", partId: a.id, mimeType: a.mimeType, bytes: a.bytes,
                     pixels: a.isInline ? (480, 320) : (640, 400), color: color &+ UInt32(i) &* 0x0A0A0A)
            }
        }
        return parts(RichMailThreads.attachments, RichMailThreads.attachmentList, color: 0x7FA7D9)
            + parts(RichMailThreads.inlineImages, RichMailThreads.inlineImageList, color: 0x9CC5A1)
            + [Part(threadR: RichMailThreads.newsletter.r, messageId: RichMailThreads.newsletter.r + "-1", partId: "1.2",
                    mimeType: "image/png", bytes: RichMailThreads.newsletterLogo.bytes, pixels: (240, 64), color: 0xD9A066)]
    }

    /// Every `file(...)` call, as "threadR/messageId/partId" (tests count fetches).
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    func file(threadR: String, messageId: String, partId: String) async throws -> URL {
        let key = Self.key(threadR, messageId, partId)
        lock.lock()
        requestLog.append(key)
        let part = parts[key]
        let done = written[key]
        lock.unlock()
        if let done { return done }
        guard let part else { throw ServiceError(description: "Gmail no longer has that attachment.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(Self.fileName(key))
        try Self.bytes(for: part).write(to: url, options: .atomic)
        lock.lock()
        written[key] = url
        lock.unlock()
        return url
    }

    func cachedFile(threadR: String, messageId: String, partId: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return written[Self.key(threadR, messageId, partId)]
    }

    func usage() -> (files: Int, bytes: Int) {
        lock.lock()
        let urls = Array(written.values)
        lock.unlock()
        let sizes = urls.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.intValue ?? 0 }
        return (urls.count, sizes.reduce(0, +))
    }

    func clear() throws {
        lock.lock()
        let urls = Array(written.values)
        written.removeAll()
        lock.unlock()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Bytes

    private static func key(_ threadR: String, _ messageId: String, _ partId: String) -> String {
        "\(threadR)/\(messageId)/\(partId)"
    }

    /// A name with no sender text in it: the key's characters outside [A-Za-z0-9-] become "_".
    private static func fileName(_ key: String) -> String {
        String(key.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" }) + ".bin"
    }

    static func bytes(for part: Part) -> Data {
        switch part.mimeType.lowercased() {
        case "image/png": return image(part, type: .png) ?? filler(part.bytes)
        case "image/jpeg", "image/jpg", "image/heic": return image(part, type: .jpeg) ?? filler(part.bytes)
        default: return filler(part.bytes)
        }
    }

    /// Solid colour with a lighter disc in the middle.
    static func image(_ part: Part, type: NSBitmapImageRep.FileType) -> Data? {
        let (w, h) = (max(1, part.pixels.width), max(1, part.pixels.height))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        func color(_ rgb: UInt32, _ lift: CGFloat = 0) -> NSColor {
            let c = { (v: UInt32) in min(1, CGFloat(v & 0xFF) / 255 + lift) }
            return NSColor(srgbRed: c(rgb >> 16), green: c(rgb >> 8), blue: c(rgb), alpha: 1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color(part.color).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        color(part.color, 0.25).setFill()
        let d = CGFloat(min(w, h)) * 0.6
        NSBezierPath(ovalIn: NSRect(x: (CGFloat(w) - d) / 2, y: (CGFloat(h) - d) / 2, width: d, height: d)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: type, properties: type == .jpeg ? [.compressionFactor: 0.85] : [:])
    }

    /// Deterministic filler: a short header line, then a repeating pattern up to `count` bytes.
    static func filler(_ count: Int) -> Data {
        var data = Data("yayas-calendar fixture bytes\n".utf8)
        let pattern = Data((0..<256).map { UInt8($0) })
        while data.count < count { data.append(pattern.prefix(count - data.count)) }
        return data.prefix(max(count, 0))
    }
}
#endif
