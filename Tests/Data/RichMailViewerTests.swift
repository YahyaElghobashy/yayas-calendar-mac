import Foundation

/// Rich mail viewer, data side: the quote corpus (MailQuote), plain text
/// (MailPlainText), the sanitizer's `cids:` and reserved `yc-` prefix, the parser's part ids / inline parts /
/// format=flowed, the v2 body cache and the inline-image prefetch. Neutral strings and the Moonfield cast only.
enum RichMailViewerTests {
    static func run() async {
        quoteCorpus()
        attributions()
        plainText()
        sanitizerCIDs()
        rasterSniffing()
        cssFastPath()
        parser()
        cacheEntries()
        prefetchPlan()
        await prefetchRuns()
        await pipeline()
    }

    // MARK: Quote corpus

    struct QuoteCase {
        var name: String
        var html: String
        var collapse: Bool
        /// Text that must end up inside the collapsed block / stay outside it.
        var inside: [String] = []
        var outside: [String] = []
    }

    static let gq = "margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"
    static func gmail(_ reply: String, _ quoted: String) -> String {
        "<div dir=\"ltr\">\(reply)</div><br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On Mon, 19 Oct at 08:12, "
            + "Avery Moonfield &lt;<a href=\"mailto:avery@orbitalpickle.example\">avery@orbitalpickle.example</a>&gt; wrote:<br></div>"
            + "<blockquote class=\"gmail_quote\" style=\"\(gq)\">\(quoted)</blockquote></div>"
    }
    static let wordHeader = "<div><div style=\"border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in\">"
        + "<p class=\"MsoNormal\"><b>From:</b> Theo Quill &lt;theo@quill.example&gt;<br><b>Sent:</b> Monday<br><b>Subject:</b> Set list</p></div></div>"

    static let cases: [QuoteCase] = [
        QuoteCase(name: "gmail one level", html: gmail("Sounds good.", "<div>Can we print on Thursday?</div>"), collapse: true,
                  inside: ["Can we print", "wrote:"], outside: ["Sounds good."]),
        QuoteCase(name: "gmail two levels, one collapse",
                  html: gmail("Dill green it is.", "<div>Which lid?</div><br><div class=\"gmail_quote\"><div class=\"gmail_attr\">On Sun, Juniper Vale wrote:<br></div><blockquote class=\"gmail_quote\">First proofs attached.</blockquote></div>"),
                  collapse: true, inside: ["Which lid?", "First proofs"], outside: ["Dill green"]),
        QuoteCase(name: "gmail_quote_container", html: "<div>Yes please.</div><div class=\"gmail_quote gmail_quote_container\"><div class=\"gmail_attr\">On Mon, Milo wrote:</div><blockquote class=\"gmail_quote\">Lunch?</blockquote></div>",
                  collapse: true, inside: ["Lunch?"], outside: ["Yes please."]),
        QuoteCase(name: "gmail in a wrapper, trailing br and empty div",
                  html: "<div><div><div>Reply text</div></div><div class=\"gmail_quote\"><blockquote class=\"gmail_quote\">Old</blockquote></div><br><div></div></div><br>",
                  collapse: true, inside: ["Old"], outside: ["Reply text"]),
        QuoteCase(name: "gmail quote with a visible signature after it", html: gmail("Top", "Old") + "<div>Juniper Vale, Orbital Pickle Co.</div>",
                  collapse: false),
        QuoteCase(name: "gmail forward with a comment", html: "<div>FYI, see below.</div><div class=\"gmail_quote\"><div class=\"gmail_attr\">---------- Forwarded message ---------<br>From: Kofi Ember &lt;kofi@ember.example&gt;<br>Subject: Dock photos</div><div>Here they are.</div></div>",
                  collapse: false),
        QuoteCase(name: "gmail forward without a comment", html: "<div class=\"gmail_quote\"><div class=\"gmail_attr\">---------- Forwarded message ---------<br>From: Kofi Ember</div><div>Photos.</div></div>",
                  collapse: false),
        QuoteCase(name: "gmail quote-only body", html: "<div class=\"gmail_quote\"><blockquote class=\"gmail_quote\">Only the quote</blockquote></div>", collapse: false),
        QuoteCase(name: "outlook web: appendonsend, hr, divRplyFwdMsg",
                  html: "<div>Keys are ready on Thursday.</div><div id=\"appendonsend\"></div><hr style=\"display:inline-block;width:98%\"><div id=\"divRplyFwdMsg\" dir=\"ltr\"><b>From:</b> Avery Moonfield<br><b>Subject:</b> Moving into Suite 404</div><div>When can we pick up the keys?</div>",
                  collapse: true, inside: ["From:", "pick up the keys"], outside: ["Keys are ready"]),
        QuoteCase(name: "outlook web: divRplyFwdMsg after its hr",
                  html: "<div>See you there.</div><hr><div id=\"divRplyFwdMsg\"><b>From:</b> Milo Brightwater<br><b>Subject:</b> RE: Suite 404</div><div>Old body</div>",
                  collapse: true, inside: ["Old body"], outside: ["See you there."]),
        QuoteCase(name: "outlook web forward (Subject: FW:)",
                  html: "<div>Passing this on.</div><hr><div id=\"divRplyFwdMsg\"><b>From:</b> Milo<br><b>Subject:</b> FW: Suite 404 floor plan</div><div>Plan inside.</div>",
                  collapse: false),
        QuoteCase(name: "outlook desktop, header in a wrapper div",
                  html: "<div class=\"WordSection1\"><p class=\"MsoNormal\">Thanks Theo.</p><p class=\"MsoNormal\">&nbsp;</p>" + wordHeader
                      + "<p class=\"MsoNormal\">Here is the set list.</p><p class=\"MsoNormal\">Second verse.</p></div>",
                  collapse: true, inside: ["From:", "set list", "Second verse"], outside: ["Thanks Theo."]),
        QuoteCase(name: "outlook desktop #B5C4DF",
                  html: "<div><p>Noted.</p><div style=\"border:none;border-top:solid #B5C4DF 1.0pt\"><p><b>From:</b> Ines Marlowe</p></div><p>Old note</p></div>",
                  collapse: true, inside: ["Old note"], outside: ["Noted."]),
        QuoteCase(name: "outlook desktop OutlookMessageHeader",
                  html: "<div>Works for me.</div><div class=\"OutlookMessageHeader\">From: Priya Starling<br>Subject: Q4</div><div>Old plan</div>",
                  collapse: true, inside: ["Old plan"], outside: ["Works for me."]),
        QuoteCase(name: "border-top divider without From:",
                  html: "<div>News</div><div style=\"border-top:solid #E1E1E1 1px\">Tour dates below</div><div>More news</div>", collapse: false),
        QuoteCase(name: "apple, attribution div before the blockquote",
                  html: "<div>Bring the big blanket.</div><div><br></div><div>On 18 Oct, at 19:02, Avery Moonfield wrote:</div><br><blockquote type=\"cite\"><div>Is Sunday still on?</div></blockquote>",
                  collapse: true, inside: ["wrote:", "Sunday still on"], outside: ["big blanket"]),
        QuoteCase(name: "apple without attribution", html: "<div>Yes.</div><blockquote type=\"cite\">Old</blockquote>", collapse: true,
                  inside: ["Old"], outside: ["Yes."]),
        QuoteCase(name: "apple attribution as an inline run with a link",
                  html: "<div>Lemon cake it is.<br><br>On 18 Oct, at 19:02, Mom &lt;<a href=\"mailto:mom@moonfield-family.example\">mom@moonfield-family.example</a>&gt; wrote:<br><br><blockquote type=\"cite\">Cake?</blockquote></div>",
                  collapse: true, inside: ["Mom", "Cake?"], outside: ["Lemon cake it is."]),
        QuoteCase(name: "ios: attribution and quote as sibling blockquotes",
                  html: "<div dir=\"ltr\">Bring the blanket.</div><div dir=\"ltr\"><br><blockquote type=\"cite\">On 18 Oct, at 19:02, Avery wrote:<br><br></blockquote></div><blockquote type=\"cite\"><div dir=\"ltr\">Sunday?</div></blockquote>",
                  collapse: true, inside: ["Avery wrote:", "Sunday?"], outside: ["Bring the blanket."]),
        QuoteCase(name: "apple inline replies", html: "<div>Answers inline.</div><blockquote type=\"cite\">Q1?</blockquote><div>A1.</div><blockquote type=\"cite\">Q2?</blockquote><div>A2.</div>",
                  collapse: false),
        QuoteCase(name: "apple forward", html: "<div>For you.</div><div>Begin forwarded message:</div><br><blockquote type=\"cite\"><div><b>From:</b> Kofi</div><div>Photos</div></blockquote>",
                  collapse: false),
        QuoteCase(name: "thunderbird cite prefix + blockquote",
                  html: "<p>Agreed.</p><div class=\"moz-cite-prefix\">On 18/10 09:30, Ines Marlowe wrote:<br></div><blockquote type=\"cite\" cite=\"mid:x@marlowe.example\">Old</blockquote>",
                  collapse: true, inside: ["Ines Marlowe wrote:", "Old"], outside: ["Agreed."]),
        QuoteCase(name: "thunderbird forward container", html: "<div class=\"moz-forward-container\"><br>-------- Forwarded Message --------<table><tr><td>Subject:</td><td>Hi</td></tr></table>Body</div>",
                  collapse: false),
        QuoteCase(name: "yahoo_quoted class", html: "<div>Thanks!</div><div class=\"yahoo_quoted\"><div>On Monday, Kofi Ember wrote:</div><div>Old</div></div>",
                  collapse: true, inside: ["Old"], outside: ["Thanks!"]),
        QuoteCase(name: "yahoo_quoted_ id", html: "<div>Thanks!</div><div id=\"yahoo_quoted_4711\"><div>Old</div></div>", collapse: true, inside: ["Old"]),
        QuoteCase(name: "proton quote", html: "<div>See you.</div><div class=\"protonmail_quote\">Original by Priya<blockquote>Old</blockquote></div>",
                  collapse: true, inside: ["Original by Priya"], outside: ["See you."]),
        QuoteCase(name: "-----Original Message----- block", html: "<div>Done.</div><div>-----Original Message-----<br>From: Milo<br>Sent: Monday</div><div>Old request</div>",
                  collapse: true, inside: ["Original Message", "Old request"], outside: ["Done."]),
        QuoteCase(name: "newsletter pull-quote", html: "<div>Tour news</div><blockquote>\u{201C}Best night of the year\u{201D}</blockquote><div>Tickets on sale</div>",
                  collapse: false),
        QuoteCase(name: "plain body, no quote at all", html: "<p>Just a note from Caf\u{00E9} Nowhere.</p>", collapse: false),
        QuoteCase(name: "german attribution before an apple quote",
                  html: "<div>Gerne.</div><div>Am 18.10. um 19:02 schrieb Avery Moonfield:</div><blockquote type=\"cite\">Alt</blockquote>",
                  collapse: true, inside: ["schrieb", "Alt"], outside: ["Gerne."]),
        QuoteCase(name: "gmail quote in a table cell", html: "<table><tr><td><div>Reply</div><div class=\"gmail_quote\">Old</div></td></tr></table>",
                  collapse: true, inside: ["Old"], outside: ["Reply"]),
        QuoteCase(name: "trailing tracking pixel doesn't count", html: gmail("Top", "Old") + "<img src=\"https://t.example/p.gif\" width=\"1\" height=\"1\">",
                  collapse: true, inside: ["Old"], outside: ["Top"]),
        QuoteCase(name: "trailing real image counts", html: gmail("Top", "Old") + "<img src=\"https://t.example/banner.png\" width=\"600\" height=\"120\" alt=\"Banner\">",
                  collapse: false),
        QuoteCase(name: "trailing whitespace and br after outlook history", html: "<div>Ok</div><hr><div id=\"divRplyFwdMsg\">From: X</div><div>Old</div>   <br><br>",
                  collapse: true, inside: ["Old"]),
        QuoteCase(name: "gmail quote before more reply (interleaved)", html: "<div>Intro</div><div class=\"gmail_quote\">Old</div><div>More reply</div>",
                  collapse: false),
        QuoteCase(name: "quote start inside a paragraph parent", html: "<p>Text <span class=\"gmail_quote\">old</span></p>", collapse: false),
        QuoteCase(name: "two-language mix: french attribution",
                  html: "<div>Merci.</div><div>Le 18 oct. 2026, Avery a \u{00E9}crit :</div><blockquote type=\"cite\">Vieux</blockquote>",
                  collapse: true, inside: ["a \u{00E9}crit", "Vieux"], outside: ["Merci."]),
        QuoteCase(name: "arabic attribution", html: "<div dir=\"rtl\">\u{0634}\u{0643}\u{0631}\u{0627}</div><div dir=\"rtl\">\u{0641}\u{064A} \u{0627}\u{0644}\u{0623}\u{062D}\u{062F}\u{060C} \u{0643}\u{062A}\u{0628}:</div><blockquote type=\"cite\">old</blockquote>",
                  collapse: true, inside: ["old", "\u{0643}\u{062A}\u{0628}"]),
        QuoteCase(name: "hebrew attribution", html: "<div dir=\"rtl\">\u{05EA}\u{05D5}\u{05D3}\u{05D4}</div><div dir=\"rtl\">\u{05D1}\u{05D9}\u{05D5}\u{05DD} \u{05E9}\u{05DC}\u{05D9}\u{05E9}\u{05D9}, Avery \u{05DB}\u{05EA}\u{05D1}:</div><blockquote type=\"cite\">old</blockquote>",
                  collapse: true, inside: ["old", "\u{05DB}\u{05EA}\u{05D1}"]),
        QuoteCase(name: "greek attribution before an apple quote",
                  html: "<div>Ευχαριστώ.</div><div>Στις Τρί 20 Οκτ, ο/η Milo Brightwater έγραψε:</div><blockquote type=\"cite\">Παλιό</blockquote>",
                  collapse: true, inside: ["έγραψε", "Παλιό"], outside: ["Ευχαριστώ."]),
        QuoteCase(name: "russian attribution", html: "<div>Спасибо.</div><div>Milo Brightwater пишет:</div><blockquote type=\"cite\">Старое</blockquote>",
                  collapse: true, inside: ["пишет", "Старое"], outside: ["Спасибо."]),
        QuoteCase(name: "chinese attribution with a full-width colon",
                  html: "<div>谢谢。</div><div>Milo Brightwater 于2026年10月20日写道：</div><blockquote type=\"cite\">旧的</blockquote>",
                  collapse: true, inside: ["写道", "旧的"], outside: ["谢谢。"]),
        QuoteCase(name: "outlook desktop, wrapper with reply before (WordSection1)",
                  html: "<div class=\"WordSection1\"><p>Sure.</p>" + wordHeader + "<p>Old</p></div><p>&nbsp;</p>",
                  collapse: true, inside: ["Old", "From:"], outside: ["Sure."]),
        QuoteCase(name: "only a quote after a forwarded blockquote marker in text",
                  html: "<div>Begin forwarded message:</div><blockquote type=\"cite\">Body</blockquote>", collapse: false),
    ]

    static func marked(_ raw: String) -> (String, Bool) {
        MailQuote.mark(HTMLSanitizer.sanitize(raw, remote: .allow).html)
    }

    /// Visible text of `html` inside / outside the collapse (tags dropped, entities decoded).
    static func split(_ html: String) -> (inside: String, outside: String) {
        guard let open = html.range(of: MailQuote.openTag), let close = html.range(of: MailQuote.closeTag, options: .backwards) else {
            return ("", HTMLSanitizer.text(fromHTML: html))
        }
        let inside = HTMLSanitizer.text(fromHTML: String(html[open.upperBound..<close.lowerBound]))
        let outside = HTMLSanitizer.text(fromHTML: String(html[..<open.lowerBound]) + String(html[close.upperBound...]))
        return (inside, outside)
    }

    static func quoteCorpus() {
        expect(cases.count >= 40, "quote: the corpus has 40 messages (\(cases.count))")
        for c in cases {
            let sanitized = HTMLSanitizer.sanitize(c.html, remote: .allow).html
            let (html, collapsed) = MailQuote.mark(sanitized)
            expect(collapsed == c.collapse, "quote \(c.name): \(c.collapse ? "collapses" : "stays open")")
            if !c.collapse {
                expect(html == sanitized, "quote \(c.name): left byte for byte")
                continue
            }
            let parts = split(html)
            expect(html.components(separatedBy: MailQuote.openTag).count == 2, "quote \(c.name): exactly one collapse")
            expect(html.contains(MailQuote.openTag + MailQuote.summary), "quote \(c.name): the \u{2022}\u{2022}\u{2022} pill opens the block")
            for s in c.inside { expect(parts.inside.contains(s), "quote \(c.name): \u{201C}\(s)\u{201D} is collapsed") }
            for s in c.outside {
                expect(parts.outside.contains(s) && !parts.inside.contains(s), "quote \(c.name): \u{201C}\(s)\u{201D} stays visible")
            }
            // Balanced: the browser sees the same tree shape (every tag we open is closed).
            expect(html.components(separatedBy: "<details").count == html.components(separatedBy: "</details>").count,
                   "quote \(c.name): balanced")
        }
        // Outlook web: the <hr> before the header goes into the collapse.
        let (outlook, _) = marked(cases[9].html)
        expect(outlook.contains(MailQuote.openTag + MailQuote.summary + "<hr"), "quote outlook web: collapse starts at the <hr>")
        // A sender faking our markers: stripped by the sanitizer, so nothing collapses and no yc- class survives.
        let fake = "<div>Hi</div><details class=\"yc-quote\" open><summary class=\"yc-more\" id=\"yc-x\">\u{2022}\u{2022}\u{2022}</summary>Fake</details>"
        let (faked, collapsedFake) = marked(fake)
        expect(!collapsedFake && !faked.contains("yc-"), "quote a sender faking class=\"yc-quote\": stripped, nothing collapses")
        // Our own markers never survive a sanitizer pass (why they're added at read time, never cached).
        let (ours, _) = marked(cases[0].html)
        expect(!HTMLSanitizer.sanitize(ours, remote: .block).html.contains("yc-quote"), "quote a re-pass strips our markers")
    }

    static func attributions() {
        let yes = ["On Tue, 20 Oct at 09:00, Avery Moonfield <avery@home.example> wrote:", "Am Dienstag schrieb Avery Moonfield:",
                   "Le mardi 20 octobre, Avery a \u{00E9}crit :", "El martes, Avery escribi\u{00F3}:", "Op dinsdag schreef Avery:",
                   "Il marted\u{00EC}, Avery ha scritto:", "\u{0641}\u{064A} \u{064A}\u{0648}\u{0645} \u{0627}\u{0644}\u{062B}\u{0644}\u{0627}\u{062B}\u{0627}\u{0621}\u{060C} \u{0643}\u{062A}\u{0628}:",
                   "On Tue,\n 20 Oct,   Theo Quill\twrote:",
                   "Στις Τρί 20 Οκτ 2026 στις 09:00, ο/η Avery Moonfield <avery@home.example> έγραψε:", "Avery Moonfield пишет:",
                   "20 окт. 2026 г., в 09:00, Avery Moonfield написал(а):", "בתאריך 20 באוק׳ 2026, Avery Moonfield כתב:",
                   "Avery Moonfield <avery@home.example> 于2026年10月20日周二 09:00写道：", "2026/10/20 9:00、Avery Moonfield さんは書きました:"]
        for s in yes { expect(MailQuote.isAttribution(s), "attribution: \u{201C}\(s.prefix(30))\u{201D}") }
        let no = ["Once upon a time", "Thanks for writing:", "On wrote:", "On " + String(repeating: "x", count: 420) + " wrote:",
                  "We wrote: the plan", "Σχέδιο: έγραψε το σχέδιο", "Он пишет: сегодня", "写道：开始"]
        for s in no { expect(!MailQuote.isAttribution(s), "not an attribution: \u{201C}\(s.prefix(30))\u{201D}") }
    }

    // MARK: Plain text

    static func plain(_ text: String, flowed: Bool = false, delsp: Bool = false) -> String {
        MailPlainText.html(text, flowed: flowed, delsp: delsp)
    }

    static func plainText() {
        // Unflow.
        expect(MailPlainText.parse("Hello \nworld\n", flowed: true, delsp: false).map(\.text) == ["Hello world"], "plain text flowed: soft break joined")
        expect(MailPlainText.parse(" From here", flowed: true, delsp: false).map(\.text) == ["From here"], "plain text flowed: space-stuffing removed")
        expect(MailPlainText.parse("Hel \nlo", flowed: true, delsp: true).map(\.text) == ["Hello"], "plain text delsp=yes: the soft space goes too")
        expect(MailPlainText.parse("> a \n> b\nc", flowed: true, delsp: false) == [.init(depth: 1, text: "a b"), .init(depth: 0, text: "c")],
               "plain text flowed: joins only at the same depth")
        expect(MailPlainText.parse("-- \nTheo", flowed: true, delsp: false).first?.text == "-- ", "plain text flowed: \u{201C}-- \u{201D} is never a soft break")
        expect(MailPlainText.parse("Hello \nworld", flowed: false, delsp: false).count == 2, "plain text fixed text keeps its lines")
        expect(MailPlainText.quoteDepth("> > x", strict: false) == (2, "x") && MailPlainText.quoteDepth(">> x", strict: true) == (2, "x"),
               "plain text quote depth (fixed and flowed)")
        // Quote levels: nested bars, no ">" characters.
        let levels = plain("Top line\n> one\n>> two\n>>> three\n\nAfter")
        expect(levels.components(separatedBy: "<blockquote class=\"yc-q\">").count == 4, "plain text quote depths 1-3 nest three bars")
        expect(!levels.contains("&gt;"), "plain text no \u{201C}>\u{201D} characters are shown")
        expect(!levels.contains(MailQuote.openTag), "plain text a quote followed by more text stays open")
        // Attribution + trailing collapse.
        let reply = plain("Thanks, see you there!\n\nOn Mon, 19 Oct, Theo Quill <theo@quill.example> wrote:\n> Set list attached.\n> Doors at 8.\n")
        let parts = split(reply)
        expect(reply.contains(MailQuote.openTag + MailQuote.summary), "plain text trailing history collapses")
        expect(parts.inside.contains("wrote:") && parts.inside.contains("Doors at 8."), "plain text the attribution joins the run")
        expect(parts.outside.contains("Thanks, see you there!"), "plain text the reply stays visible")
        let wrapped = plain("Ok.\n\nOn Mon, 19 Oct 2026 at 08:12, Theo Quill\n<theo@quill.example> wrote:\n> Old\n")
        expect(split(wrapped).inside.contains("Theo Quill"), "plain text an attribution wrapped over two lines joins too")
        expect(!plain("> only a quote\n> here").contains(MailQuote.openTag), "plain text a quote-only body stays open")
        expect(!plain("Intro\n> q1\nA1\n> q2\nA2").contains(MailQuote.openTag), "plain text inline answers stay open")
        // Signature.
        let sig = plain("See you Sunday.\n-- \nTheo Quill\nCaf\u{00E9} Nowhere, Suite 404")
        expect(sig.contains("<div class=\"yc-sig\"><div>--</div><div>Theo Quill</div>"), "plain text the \u{201C}-- \u{201D} signature is dimmed")
        expect(!sig.contains("yc-sig\"><div>See you"), "plain text the body isn't in the signature")
        let both = plain("Reply\n\nOn Mon, Theo wrote:\n> q\n\n-- \nAvery")
        let closeAt = both.range(of: MailQuote.closeTag)?.lowerBound, sigAt = both.range(of: "<div class=\"yc-sig\">")?.lowerBound
        expect(closeAt != nil && sigAt != nil && closeAt! < sigAt!, "plain text a signature after the history stays outside it")
        let topPost = plain("Reply\n-- \nAvery\n\nOn Mon, Theo wrote:\n> q")
        expect(topPost.contains("<div class=\"yc-sig\">") && topPost.contains("</div>" + MailQuote.openTag), "plain text top-posted signature ends at the history")
        // Outlook plain-text history.
        let outlook = plain("Done.\n\n-----Original Message-----\nFrom: Milo Brightwater\nSent: Monday\n\nOld request\n")
        expect(split(outlook).inside.contains("Old request") && split(outlook).outside.contains("Done."), "plain text -----Original Message----- collapses to the end")
        let underscores = plain("Done.\n________________________________\nFrom: Milo\nOld\n")
        expect(underscores.contains(MailQuote.openTag), "plain text the underscore rule + From: collapses")
        // Preformatted.
        let table = plain("Order:\nName      Qty    Price\nPickles   2      4.00\nJars      10     12.50\n\nThanks")
        expect(table.contains("<div class=\"yc-pre\">Name      Qty"), "plain text an aligned table is monospace")
        let box = plain("\u{250C}\u{2500}\u{2500}\u{2510}\n\u{2502}hi\u{2502}\n\u{2514}\u{2500}\u{2500}\u{2518}")
        expect(box.contains("yc-pre"), "plain text box drawing is monospace")
        let code = plain("Try this:\n    let jar = Jar()\n    jar.fill()\n    jar.seal()")
        expect(code.contains("yc-pre"), "plain text indented code is monospace")
        let prose = plain("This is prose.  It has two spaces.  Old habit.\nAnother line.  Still prose.\nAnd a third line, plain.")
        expect(!prose.contains("yc-pre"), "plain text prose with double spaces after sentences stays proportional")
        // Links.
        let links = plain("(see https://quill.example/set_(list)). Or www.quietcomets.example/tour, or theo@quill.example. <https://a.example/x>")
        expect(links.contains("<a href=\"https://quill.example/set_(list)\">https://quill.example/set_(list)</a>)."), "plain text balanced brackets kept, trailing ). trimmed")
        expect(links.contains("<a href=\"https://www.quietcomets.example/tour\">www.quietcomets.example/tour</a>,"), "plain text www. shown as written, linked as https")
        expect(links.contains("<a href=\"mailto:theo@quill.example\">theo@quill.example</a>."), "plain text addresses link as mailto:")
        expect(links.contains("&lt;<a href=\"https://a.example/x\">https://a.example/x</a>&gt;"), "plain text <url> brackets stay text")
        let js = plain("javascript:alert(1) and http:// and data:text/html,x")
        expect(!js.contains("<a "), "plain text javascript:, bare http:// and data: stay text")
        let long = plain("https://quill.example/" + String(repeating: "a", count: 2_100))
        expect(!long.contains("<a "), "plain text URLs over 2048 characters aren't linked")
        // Escaping: no "<" from the input survives as markup.
        let hostile = plain("<script>alert(1)</script> & <b>bold</b> <img src=x onerror=alert(1)>\n> <i>q</i>")
        let stripped = hostile.replacingOccurrences(of: MailQuote.openTag + MailQuote.summary, with: "")
            .replacingOccurrences(of: MailQuote.closeTag, with: "")
            .replacingOccurrences(of: "<div", with: "").replacingOccurrences(of: "</div>", with: "")
            .replacingOccurrences(of: "<blockquote", with: "").replacingOccurrences(of: "</blockquote>", with: "")
        expect(!stripped.contains("<") && hostile.contains("&lt;script&gt;") && hostile.contains("&amp;"), "plain text every input < is escaped")
        expect(plain("a\r\nb\rc").components(separatedBy: "<div>").count == 4, "plain text CRLF and CR become lines")
        expect(plain("Hi").hasPrefix("<div class=\"yc-plain\" dir=\"auto\">"), "plain text wrapped in yc-plain, dir=auto")
    }

    // MARK: Sanitizer

    static func sanitizerCIDs() {
        let html = "<p><img src=\"cid:Logo@X\" alt=\"Logo\" width=\"80\" height=\"40\" style=\"display:block\" onerror=\"x()\"></p>"
        let kept = HTMLSanitizer.sanitize(html, remote: .allow, cids: ["<logo@x>"])
        expect(kept.html.contains("<img src=\"cid:logo@x\" alt=\"Logo\" width=\"80\" height=\"40\"") && !kept.html.contains("onerror"),
               "sanitizer a known cid stays an image (normalized id, cleaned attributes)")
        expect(kept.cidImages == 0, "sanitizer cidImages counts placeholders only")
        let placeholder = HTMLSanitizer.sanitize(html, remote: .allow, cids: ["other@x"])
        expect(placeholder.cidImages == 1 && placeholder.html.contains("[image: Logo]") && !placeholder.html.contains("cid:"),
               "sanitizer an unknown cid → placeholder")
        let encoded = HTMLSanitizer.sanitize("<img src=\"cid:part1%40moonfield.example\">", remote: .allow, cids: ["part1@moonfield.example"])
        expect(encoded.html.contains("src=\"cid:part1@moonfield.example\""), "sanitizer percent-encoded ids match")
        let cased = HTMLSanitizer.sanitize("<img src=\"CID:img001.png@01d9\">", remote: .allow, cids: ["IMG001.PNG@01D9"])
        expect(cased.html.contains("src=\"cid:img001.png@01d9\""), "sanitizer ids compare case-insensitively")
        let odd = HTMLSanitizer.sanitize("<img src=\"cid:a b@x\">", remote: .allow, cids: ["a b@x"])
        expect(odd.html.contains("src=\"cid:a%20b@x\""), "sanitizer unusual characters are percent-encoded in src")
        let mixed = "<img src=\"cid:logo@x\"><img src=\"https://cdn.quietcomets.example/hero.jpg\" width=\"600\">"
        let cached = HTMLSanitizer.sanitize(mixed, remote: .allow, cids: ["logo@x"]).html
        let blocked = HTMLSanitizer.sanitize(cached, remote: .block, cids: ["logo@x"])
        expect(blocked.html.contains("src=\"cid:logo@x\"") && !blocked.html.contains("cdn.quietcomets") && blocked.hasRemoteImages,
               "sanitizer a .block re-pass with the same cids keeps the cid image, blocks the remote one")
        expect(HTMLSanitizer.sanitize(cached, remote: .block).cidImages == 1, "sanitizer a re-pass without cids → placeholder")
        expect(HTMLSanitizer.sanitize("<img src=\"cid:\">", remote: .allow, cids: [""]).cidImages == 1, "sanitizer an empty cid is never known")
        // Reserved prefix.
        let classes = HTMLSanitizer.sanitize("<div class=\"yc-quote gmail_quote YC-sheet x\" id=\"yc-1\">a</div><span id=\"YC-Fake\" class=\"yc-\">b</span><p id=\"ok\">c</p>",
                                             remote: .allow).html
        expect(classes.contains("<div class=\"gmail_quote x\">") && classes.contains("<span>b</span>") && classes.contains("<p id=\"ok\">"),
               "sanitizer yc- class tokens and ids are stripped (any case), others kept")
        let details = HTMLSanitizer.sanitize("<details open><summary>More</summary>x</details>", remote: .allow).html
        let again = HTMLSanitizer.sanitize(details, remote: .block).html
        expect(again.contains("<details open") && again.contains("<summary>More</summary>"), "sanitizer details/summary survive a .block re-pass")
    }

    /// The cid handler answers with what the bytes are, never with the declared type.
    static func rasterSniffing() {
        func bytes(_ b: [UInt8], _ tail: String = "") -> Data { Data(b) + Data(tail.utf8) }
        let cases: [(Data, String?)] = [
            (bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "IHDR"), "image/png"),
            (bytes([0xFF, 0xD8, 0xFF, 0xE0], "JFIF"), "image/jpeg"),
            (Data("GIF89a....".utf8), "image/gif"),
            (Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8), "image/webp"),
            (bytes([0, 0, 0, 0x18], "ftypheic...."), "image/heic"),
            (bytes([0, 0, 0, 0x18], "ftypavif...."), "image/avif"),
            (Data("BM\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}".utf8), "image/bmp"),
            (Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>x()</script></svg>".utf8), nil),
            (Data("<!doctype html><script>x()</script>".utf8), nil),
            (Data("%PDF-1.7\n".utf8), nil),
            (bytes([0, 0, 0, 0x18], "ftypqt  ...."), nil),
            (Data(), nil),
        ]
        for (data, type) in cases { expect(MailCID.rasterType(data) == type, "cid sniffing: \(type ?? "refused") (\(data.prefix(4).map { String($0) }))") }
        expect(MailCID.isImageType("image/PNG") && MailCID.isImageType("image/heic") && !MailCID.isImageType("image/svg+xml")
               && !MailCID.isImageType("text/html") && !MailCID.isImageType("application/pdf"), "cid: servable types are raster + HEIC only")
    }

    /// Inline styles: the byte-level path for ASCII gives exactly what the general path gives (forced here by one
    /// non-ASCII declaration appended to the same style).
    static func cssFastPath() {
        let styles = [
            "color: red; font-size:12px", "COLOR:Red;Font-Family:'Helvetica Neue', Arial, sans-serif", "  ;;  margin:0 ; ;",
            "width: expression(alert(1)); color: blue", "background:url(https://cdn.quietcomets.example/a.png) no-repeat; padding:2px",
            "background-image: url('data:image/png;base64,AAAA'); border:0", "behavior: url(x.htc); color: red", "-moz-binding: url(x)",
            "font-family:\"a;b\"; color: red", "content: 'x:y'; top:1px", "x: javascript:alert(1); y: ok", "a:b:c; d: (e;f)",
            "border-top: solid #E1E1E1 1.0pt; padding: 3.0pt 0in 0in 0in", "/* c */ color: red /* d */; margin: 0",
            "list-style-image: url(javascript:alert(1)); color: green", "font: 700 11px/18px -apple-system", "x:<b>; y: {z}; w: ok",
            "image-set( x ); color: red", "background: URL(  \"https://t.example/p.gif\"  )", "prop with space: 1; ok-prop: 2",
            "a\t:\tb", "UPPER-CASE: VALUE", "-o-link: x; color: red", "@import: x", "color:", ":red", "verylongpropertynameverylongpropertynameverylongpropertynameverylong: 1",
        ]
        for remote in [HTMLSanitizer.RemoteContent.allow, .block] {
            for style in styles {
                var foundFast = false, foundSlow = false
                let fast = CSSSanitizer.declarations(style, remote: remote, found: &foundFast)
                let slow = CSSSanitizer.declarations(style + "; x-pad: \u{00E9}", remote: remote, found: &foundSlow)
                let expected = fast.isEmpty ? "x-pad: \u{00E9}" : fast + "; x-pad: \u{00E9}"
                expect(slow == expected && foundFast == foundSlow, "css fast path = general path (\(remote)): \(style.prefix(40))")
            }
        }
    }

    // MARK: Parser

    static func b64(_ s: String) -> String { Data(s.utf8).base64URLString }

    static func part(_ dict: [String: Any]) -> GMessagePart {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return (try? JSONDecoder().decode(GMessagePart.self, from: data)) ?? GMessagePart()
    }

    static let html = "<p>Tour dates <img src=\"cid:comets-logo@quietcomets.example\" alt=\"Comets\"></p>"
    static func newsletterPayload(logoData: Bool, extraInline: Bool = false) -> [String: Any] {
        var logo: [String: Any] = ["partId": "0.1", "mimeType": "image/png", "filename": "comets-logo.png",
                                   "headers": [["name": "Content-Type", "value": "image/png"],
                                               ["name": "Content-ID", "value": "<comets-logo@quietcomets.example>"],
                                               ["name": "Content-Disposition", "value": "inline; filename=\"comets-logo.png\""]]]
        logo["body"] = logoData ? ["size": 4, "data": Data([0x89, 0x50, 0x4E, 0x47]).base64URLString] as [String: Any]
                                : ["size": 24_000, "attachmentId": "ANGjdLogo"] as [String: Any]
        var related: [[String: Any]] = [
            ["partId": "0.0", "mimeType": "text/html", "headers": [["name": "Content-Type", "value": "text/html; charset=utf-8"]],
             "body": ["size": html.utf8.count, "data": b64(html)]],
            logo,
        ]
        if extraInline {
            related.append(["partId": "0.2", "mimeType": "image/jpeg",
                            "headers": [["name": "Content-Type", "value": "image/jpeg"], ["name": "Content-ID", "value": "<unused@quietcomets.example>"]],
                            "body": ["size": 9_000, "attachmentId": "ANGjdUnused"]])
        }
        return [
            "partId": "", "mimeType": "multipart/mixed",
            "headers": [["name": "Content-Type", "value": "multipart/mixed; boundary=x"]],
            "parts": [
                ["partId": "0", "mimeType": "multipart/related", "headers": [["name": "Content-Type", "value": "multipart/related; boundary=r"]],
                 "parts": related],
                ["partId": "1", "mimeType": "application/pdf", "filename": "Tour poster.pdf",
                 "headers": [["name": "Content-Type", "value": "application/pdf; name=\"Tour poster.pdf\""],
                             ["name": "Content-Disposition", "value": "attachment; filename=\"Tour poster.pdf\""]],
                 "body": ["size": 48_213, "attachmentId": "ANGjdPoster"]],
            ],
        ]
    }

    static func parser() {
        let x = MIMEParser.extract(MIMEParser.fromGmail(part(newsletterPayload(logoData: false))))
        expect(x.attachments == [MailMessage.Attachment(name: "Tour poster.pdf", bytes: 48_213)], "parser attachments stay name + size")
        expect(x.files.first?.partId == "1" && x.files.first?.attachmentId == "ANGjdPoster" && x.files.first?.mimeType == "application/pdf"
               && x.files.first?.data == nil, "parser the file keeps its part id, attachment id and type")
        expect(x.inline.count == 1 && x.inline.first?.contentId == "comets-logo@quietcomets.example" && x.inline.first?.partId == "0.1"
               && x.inline.first?.attachmentId == "ANGjdLogo" && x.inline.first?.data == nil && x.inline.first?.bytes == 24_000,
               "parser the inline image is recorded (no data: Gmail sent an attachment id)")
        let withData = MIMEParser.extract(MIMEParser.fromGmail(part(newsletterPayload(logoData: true))))
        expect(withData.inline.first?.data == Data([0x89, 0x50, 0x4E, 0x47]), "parser inline bytes kept when Gmail sent them")
        let raw = MIMEParser.extract(MIMEParser.parse(Data("""
            Content-Type: multipart/related; boundary="r"

            --r
            Content-Type: text/html

            <p><img src="cid:dock-1@moonfield-family.example"></p>
            --r
            Content-Type: image/jpeg
            Content-ID: <dock-1@moonfield-family.example>
            Content-Transfer-Encoding: base64

            /9j/4AAQ
            --r--
            """.utf8)))
        expect(raw.inline.first?.data == Data(base64Encoded: "/9j/4AAQ") && raw.inline.first?.partId == nil && raw.attachments.isEmpty,
               "parser a raw parse keeps the inline bytes, no part id, no chip")
        let stray = MIMEParser.extract(MIMEParser.parse(Data("""
            Content-Type: multipart/mixed; boundary="m"

            --m
            Content-Type: text/plain

            Photo below.
            --m
            Content-Type: image/jpeg
            Content-ID: <iphone-1@home.example>

            JPEGBYTES
            --m--
            """.utf8)))
        expect(stray.inline.count == 1 && stray.attachments.isEmpty && stray.text == "Photo below.", "parser a stray cid image is inline, not dropped")
        let flowed = MIMEParser.extract(MIMEParser.parse(Data("Content-Type: text/plain; charset=utf-8; format=flowed; delsp=yes\n\nHi \nthere\n".utf8)))
        expect(flowed.flowed && flowed.delsp, "parser format=flowed; delsp=yes read from the text part")
        let fixed = MIMEParser.extract(MIMEParser.parse(Data("Content-Type: text/plain; format=fixed\n\nHi\n".utf8)))
        expect(!fixed.flowed && !fixed.delsp, "parser format=fixed is not flowed")
        let delspOnly = MIMEParser.extract(MIMEParser.parse(Data("Content-Type: text/plain; delsp=yes\n\nHi\n".utf8)))
        expect(!delspOnly.delsp, "parser delsp only counts with format=flowed")
    }

    // MARK: v2 cache entries

    static func message(_ payload: [String: Any], id: String = "m1", from: String = "The Quiet Comets <news@quietcomets.example>") -> GMessage {
        var p = part(payload)
        p.headers = (p.headers ?? []) + [GHeader(name: "From", value: from), GHeader(name: "Subject", value: "Comets Weekly")]
        return GMessage(id: id, threadId: "t", labelIds: ["INBOX"], snippet: "", historyId: "1", internalDate: "1760000000000", payload: p)
    }

    static func cacheEntries() {
        let (entry, inline) = CachedMessage.parsed(message(newsletterPayload(logoData: false, extraInline: true)))
        expect(entry.v == 2, "cache v2")
        expect(entry.html?.contains("src=\"cid:comets-logo@quietcomets.example\"") == true, "the cached HTML keeps the cid image")
        let names = entry.attachments.map { "\($0.name)|\($0.partId)|\($0.isInline)" }
        expect(names == ["Tour poster.pdf|1|false", "Image.jpg|0.2|false", "comets-logo.png|0.1|true"],
               "files, then an unreferenced inline image as a chip (named), then the drawn one (\(names))")
        expect(entry.attachments.first?.attachmentId == "ANGjdPoster", "the attachment id is cached for fetching")
        expect(inline.map(\.partId) == ["0.1"], "only drawn inline parts are handed to the prefetch")
        let shown = entry.message(blockRemote: true)
        expect(shown.html?.contains("src=\"cid:comets-logo@quietcomets.example\"") == true, "the blocked re-pass keeps our cid image")
        expect(shown.attachments.last == MailMessage.Attachment(name: "comets-logo.png", bytes: 24_000, id: "0.1", mimeType: "image/png",
                                                                 contentId: "comets-logo@quietcomets.example", isInline: true),
               "MailMessage carries part id, type, Content-ID and isInline")
        // Plain text with an iPhone photo: plain viewer + a chip.
        let photo: [String: Any] = [
            "partId": "", "mimeType": "multipart/mixed",
            "headers": [["name": "Content-Type", "value": "multipart/mixed; boundary=m"]],
            "parts": [
                ["partId": "0", "mimeType": "text/plain", "headers": [["name": "Content-Type", "value": "text/plain; format=flowed"]],
                 "body": ["size": 12, "data": b64("Look at \nthis.")]],
                ["partId": "1", "mimeType": "image/heic", "headers": [["name": "Content-Type", "value": "image/heic"], ["name": "Content-ID", "value": "<p1@home.example>"]],
                 "body": ["size": 1_800_000, "attachmentId": "ANGjdPhoto"]],
            ],
        ]
        let plainEntry = CachedMessage.from(message(photo, from: "Kofi Ember <kofi@ember.example>"))
        let plainShown = plainEntry.message(blockRemote: true)
        expect(plainShown.isPlainText && plainShown.html?.contains("<div>Look at this.</div>") == true, "plain text → our HTML, unflowed")
        expect(plainShown.attachments.map(\.name) == ["Image.heic"] && plainShown.attachments.first?.isInline == false,
               "an inline image a plain message can't draw becomes a chip")
        // A Gmail reply: the quote collapses at read time, and the cache holds no markers.
        let reply: [String: Any] = ["partId": "", "mimeType": "text/html", "headers": [["name": "Content-Type", "value": "text/html"]],
                                    "body": ["size": 10, "data": b64(gmail("Sounds good.", "Old"))]]
        let replyEntry = CachedMessage.from(message(reply, from: "Juniper Vale <juniper@vale.example>"))
        expect(replyEntry.html?.contains("yc-quote") == false, "markers are never cached")
        expect(replyEntry.message(blockRemote: false).html?.contains(MailQuote.openTag) == true, "…they're added at read time")
        // Empty bodies stay empty (no web view for nothing).
        let empty: [String: Any] = ["partId": "", "mimeType": "text/plain", "headers": [["name": "Content-Type", "value": "text/plain"]],
                                    "body": ["size": 0, "data": ""]]
        expect(CachedMessage.from(message(empty)).message(blockRemote: true).html == nil, "an empty text body has no HTML")
    }

    // MARK: Prefetch

    static func ref(_ partId: String, bytes: Int, data: Data? = nil, mime: String = "image/jpeg") -> MIMEParser.PartRef {
        MIMEParser.PartRef(name: "", contentId: "\(partId)@moonfield-family.example", partId: partId, attachmentId: "A\(partId)",
                           mimeType: mime, bytes: bytes, data: data)
    }

    static func prefetchPlan() {
        let ten = (1...10).map { ref("1.\($0)", bytes: 100_000) }
        let plan = InlinePrefetch.plan(messageId: "m", parts: ten)
        expect(plan.count == 8 && plan.first?.partId == "1.1" && plan.last?.partId == "1.8", "prefetch: at most 8 parts, in order")
        let big = [ref("2", bytes: 3 << 20), ref("3", bytes: 3 << 20), ref("4", bytes: 3 << 20), ref("5", bytes: 1 << 20)]
        expect(InlinePrefetch.plan(messageId: "m", parts: big).map(\.partId) == ["2", "3", "5"], "prefetch: at most 8 MB (a part that doesn't fit is skipped)")
        let skipped = [ref("6", bytes: 10, data: Data([1])), ref("7", bytes: 10, mime: "image/svg+xml"), ref("8", bytes: 10, mime: "application/pdf")]
        expect(InlinePrefetch.plan(messageId: "m", parts: skipped).isEmpty, "prefetch: parts with bytes, SVG and non-images are never fetched")
        var noId = ref("9", bytes: 10)
        noId.attachmentId = nil
        expect(InlinePrefetch.plan(messageId: "m", parts: [noId]).isEmpty, "prefetch: nothing to fetch without an attachment id")
    }

    final class FakePrefetch: MailInlinePrefetching, @unchecked Sendable {
        let lock = NSLock()
        var stored: [String] = []
        var fetched: [String] = []
        var inFlight = 0
        var maxInFlight = 0

        func store(accountId: UUID, threadR: String, messageId: String, partId: String, mimeType: String, data: Data) async throws {
            lock.lock(); stored.append("\(messageId)/\(partId)/\(data.count)"); lock.unlock()
        }

        func fetch(accountId: UUID, threadR: String, messageId: String, partId: String, attachmentId: String, mimeType: String) async throws {
            lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
            try? await Task.sleep(nanoseconds: 15_000_000)
            lock.lock(); inFlight -= 1; fetched.append("\(messageId)/\(partId)"); lock.unlock()
            if partId == "1.3" { throw ServiceError(description: "gone") }
        }
    }

    static func prefetchRuns() async {
        let fake = FakePrefetch()
        let older = (1...3).map { ref("1.\($0)", bytes: 1_000) } + [ref("1.9", bytes: 4, data: Data([1, 2, 3, 4]))]
        let newest = (1...10).map { ref("1.\($0)", bytes: 1_000) } + [ref("1.20", bytes: 2, data: Data([9, 9]))]
        await LocalMailStore.prefetch([("old", older), ("new", newest)], into: fake, accountId: UUID(), threadR: "rm-inline-images")
        expect(Set(fake.stored) == ["old/1.9/4", "new/1.20/2"], "prefetch: bytes from any message go straight into the cache")
        expect(fake.fetched.count == 8 && fake.fetched.allSatisfy { $0.hasPrefix("new/") }, "prefetch: only the newest message, at most 8 fetched")
        expect(fake.maxInFlight <= 4 && fake.maxInFlight >= 2, "prefetch: at most 4 at once (\(fake.maxInFlight))")
    }

    // MARK: Pipeline with the engine

    static func pipeline() async {
        let m = MailHarness("rich-viewer")
        let (cmt, token) = m.account("avery@quietcomets.example", tag: "CMT", sort: 0)
        let blocked = "<p>Hello <img src=\"https://cdn.quietcomets.example/hero.jpg\" width=\"600\"></p>"
        var payload = newsletterPayload(logoData: false)
        if var parts = payload["parts"] as? [[String: Any]], var related = parts[0]["parts"] as? [[String: Any]] {
            let body = html + blocked
            related[0]["body"] = ["size": body.utf8.count, "data": b64(body)]
            parts[0]["parts"] = related
            payload["parts"] = parts
        }
        m.gmail.add(token: token, thread: "news", id: "n1", from: "The Quiet Comets <news@quietcomets.example>", subject: "Comets Weekly",
                    date: m.clock.now.addingTimeInterval(-120), payload: payload)
        let flowedReply: [String: Any] = ["mimeType": "text/plain",
                                          "headers": [["name": "Content-Type", "value": "text/plain; charset=utf-8; format=flowed"]],
                                          "body": ["size": 30, "data": b64("Thanks for the \nnews!\n\nOn Mon, The Quiet Comets wrote:\n> Tour dates\n")]]
        m.gmail.add(token: token, thread: "news", id: "n2", from: "Avery Moonfield <avery@quietcomets.example>", subject: "Re: Comets Weekly",
                    date: m.clock.now.addingTimeInterval(-60), labels: ["SENT"], payload: flowedReply)
        _ = await m.syncMail(cmt.id)
        let store = m.engine.mailStore
        let prefetch = FakePrefetch()
        store.inlinePrefetch = prefetch
        let r = m.r(cmt.id, "news")
        m.gmail.clearLog()
        guard let messages = try? await store.messages(threadR: r), messages.count == 2 else { expect(false, "pipeline: messages"); return }
        let news = messages[0], reply = messages[1]
        expect(news.html?.contains("src=\"cid:comets-logo@quietcomets.example\"") == true && news.html?.contains("cdn.quietcomets") == false,
               "pipeline: remote blocked, our cid image kept")
        expect(news.hasRemoteImages && !news.isPlainText, "pipeline: HTML mail with remote images")
        expect(news.attachments.map(\.isInline) == [false, true] && news.attachments.first?.id == "1" && news.attachments.first?.mimeType == "application/pdf",
               "pipeline: a file chip (part id, type) and the inline logo")
        expect(reply.isPlainText && reply.html?.contains("<div>Thanks for the news!</div>") == true && reply.html?.contains(MailQuote.openTag) == true,
               "pipeline: plain reply unflowed, its history collapsed")
        expect(reply.text.contains("> Tour dates"), "pipeline: the text part is unchanged (replies quote it)")
        expect(prefetch.fetched == [] && prefetch.stored == [], "pipeline: the newest message has no inline images to fetch")
        let allowed = try? await store.messages(threadR: r, loadImages: true)
        expect(allowed?.first?.html?.contains("https://cdn.quietcomets.example/hero.jpg") == true, "pipeline: Load images shows remote images")
        expect(m.gmail.count("format=full") == 1, "pipeline: one fetch, then the v2 cache")
        // A v1 cache file (no part ids) is fetched again.
        let cacheDir = store.cacheDirectory
        let name = LocalMailStore.fileName(accountId: cmt.id, messageId: "n1")
        if let data = try? Data(contentsOf: cacheDir.appendingPathComponent(name)),
           let text = String(data: data, encoding: .utf8) {
            try? Data(text.replacingOccurrences(of: "\"v\":2", with: "\"v\":1").utf8).write(to: cacheDir.appendingPathComponent(name))
        }
        _ = try? await store.messages(threadR: r)
        expect(m.gmail.count("format=full") == 2, "pipeline: a v1 cache entry is fetched again")

        // Prefetch on open: the newest message's drawn images, through the store's hook.
        m.gmail.add(token: token, thread: "photos", id: "p1", from: "Kofi Ember <kofi@ember.example>", subject: "Dock photos",
                    date: m.clock.now.addingTimeInterval(-30), payload: newsletterPayload(logoData: false))
        _ = await m.syncMail(cmt.id)
        _ = try? await store.messages(threadR: m.r(cmt.id, "photos"))
        expect(prefetch.fetched == ["p1/0.1"], "pipeline: opening a thread prefetches its drawn inline image (\(prefetch.fetched))")
    }
}
