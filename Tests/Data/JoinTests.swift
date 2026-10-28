import Foundation

/// The join-link corpus: priority order, the host allowlist, https only, wrappers, lookalikes.
enum JoinTests {
    struct Case {
        var name: String
        var video: [String] = []
        var hangout: String? = nil
        var location: String? = nil
        var description: String? = nil
        var expected: String?
    }

    static let corpus: [Case] = [
        // Priority
        Case(name: "conference video entry point", video: ["https://meet.google.com/abc-defg-hij"],
             expected: "https://meet.google.com/abc-defg-hij"),
        Case(name: "video beats hangoutLink", video: ["https://us02web.zoom.us/j/1234567890?pwd=abc"],
             hangout: "https://meet.google.com/abc-defg-hij", expected: "https://us02web.zoom.us/j/1234567890?pwd=abc"),
        Case(name: "hangoutLink when no conference data", hangout: "https://meet.google.com/abc-defg-hij",
             expected: "https://meet.google.com/abc-defg-hij"),
        Case(name: "hangoutLink beats location", hangout: "https://meet.google.com/abc-defg-hij",
             location: "https://zoom.us/j/123", expected: "https://meet.google.com/abc-defg-hij"),
        Case(name: "location beats description", location: "https://zoom.us/j/111",
             description: "https://zoom.us/j/222", expected: "https://zoom.us/j/111"),
        Case(name: "disallowed video entry falls through to hangout", video: ["https://example.com/meet"],
             hangout: "https://meet.google.com/abc-defg-hij", expected: "https://meet.google.com/abc-defg-hij"),
        // Hosts
        Case(name: "zoom bare domain", location: "https://zoom.us/j/1234567890", expected: "https://zoom.us/j/1234567890"),
        Case(name: "zoom company vanity subdomain", description: "Join: https://acme.zoom.us/j/99?pwd=x",
             expected: "https://acme.zoom.us/j/99?pwd=x"),
        Case(name: "zoom personal room", location: "https://us06web.zoom.us/my/demo", expected: "https://us06web.zoom.us/my/demo"),
        Case(name: "zoom webinar", description: "https://us02web.zoom.us/w/8123?tk=abc", expected: "https://us02web.zoom.us/w/8123?tk=abc"),
        Case(name: "teams meetup-join", description: "Click https://teams.microsoft.com/l/meetup-join/19%3ameeting_ab%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d now",
             expected: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ab%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d"),
        Case(name: "teams short meet link", location: "https://teams.microsoft.com/meet/2468?p=abc",
             expected: "https://teams.microsoft.com/meet/2468?p=abc"),
        Case(name: "teams consumer", description: "https://teams.live.com/meet/1234567890", expected: "https://teams.live.com/meet/1234567890"),
        Case(name: "webex subdomain", description: "https://acme.webex.com/acme/j.php?MTID=m123", expected: "https://acme.webex.com/acme/j.php?MTID=m123"),
        Case(name: "webex meet", location: "https://meetings.webex.com/meet/demo", expected: "https://meetings.webex.com/meet/demo"),
        Case(name: "whereby", description: "Room: https://whereby.com/yaya-team", expected: "https://whereby.com/yaya-team"),
        Case(name: "slack huddle", description: "https://app.slack.com/huddle/T0123/C0456", expected: "https://app.slack.com/huddle/T0123/C0456"),
        Case(name: "goto", location: "https://meet.goto.com/123456789", expected: "https://meet.goto.com/123456789"),
        Case(name: "chime", description: "https://chime.aws/1234567890", expected: "https://chime.aws/1234567890"),
        Case(name: "jitsi", description: "https://meet.jit.si/YayaStandup", expected: "https://meet.jit.si/YayaStandup"),
        Case(name: "uppercase scheme and host", location: "HTTPS://Meet.Google.com/abc-defg-hij",
             expected: "HTTPS://Meet.Google.com/abc-defg-hij"),
        // Text and HTML
        Case(name: "html href with &amp;", description: "<a href=\"https://zoom.us/j/123?pwd=a&amp;uname=b\">Join</a>",
             expected: "https://zoom.us/j/123?pwd=a&uname=b"),
        Case(name: "trailing punctuation trimmed", description: "Join here: https://meet.google.com/abc-defg-hij.",
             expected: "https://meet.google.com/abc-defg-hij"),
        Case(name: "wrapped in parentheses", description: "(https://whereby.com/room)", expected: "https://whereby.com/room"),
        Case(name: "google redirect wrapper unwrapped",
             description: "https://www.google.com/url?q=https://us02web.zoom.us/j/777?pwd%3Dz&sa=D&source=calendar",
             expected: "https://us02web.zoom.us/j/777?pwd=z"),
        Case(name: "outlook safelinks unwrapped",
             description: "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_x%2540thread.v2%2F0&data=05",
             expected: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"),
        Case(name: "first allowed link in a long description",
             description: "Agenda https://docs.google.com/document/d/abc then https://zoom.us/j/42 and https://meet.google.com/abc-defg-hij",
             expected: "https://zoom.us/j/42"),
        Case(name: "link after newline", description: "Notes\nhttps://meet.jit.si/Room\nBye", expected: "https://meet.jit.si/Room"),
        // Rejected
        Case(name: "http rejected", location: "http://zoom.us/j/123", expected: nil),
        Case(name: "http hangout rejected", hangout: "http://meet.google.com/abc-defg-hij", expected: nil),
        Case(name: "lookalike suffix", description: "https://zoom.us.evil.example/j/1", expected: nil),
        Case(name: "lookalike prefix", description: "https://evilzoom.us/j/1", expected: nil),
        Case(name: "userinfo trick", description: "https://meet.google.com@evil.example/abc", expected: nil),
        Case(name: "non-default port", description: "https://meet.google.com:8443/abc-defg-hij", expected: nil),
        Case(name: "javascript scheme", description: "javascript:alert(1)//https", expected: nil),
        Case(name: "data url", location: "data:text/html;base64,PHNjcmlwdD4=", expected: nil),
        Case(name: "https link inside other text still found", description: "see:https://zoom.us/j/1", expected: "https://zoom.us/j/1"),
        Case(name: "mailto", location: "mailto:a@b.c", expected: nil),
        Case(name: "zoom without a meeting path", description: "Download https://zoom.us/download", expected: nil),
        Case(name: "zoom root", location: "https://zoom.us/", expected: nil),
        Case(name: "teams non-meeting page", description: "https://teams.microsoft.com/v2/", expected: nil),
        Case(name: "slack non-huddle", description: "https://app.slack.com/client/T0/C0", expected: nil),
        Case(name: "webex bare domain", description: "https://webex.com/meet/demo", expected: nil),
        Case(name: "meet root", description: "https://meet.google.com/", expected: nil),
        Case(name: "unknown host", location: "https://example.com/meeting/1", expected: nil),
        Case(name: "google redirect to a bad host", description: "https://www.google.com/url?q=https://evil.example/j/1", expected: nil),
        Case(name: "plain room name", location: "Room 4B, Building 2", expected: nil),
        Case(name: "nothing at all", expected: nil),
        Case(name: "IDN lookalike host", description: "https://zоom.us/j/1", expected: nil),
    ]

    static func run() {
        expect(corpus.count >= 40, "join corpus has at least 40 cases (\(corpus.count))")
        for c in corpus {
            let got = JoinLinks.extract(videoEntryPoints: c.video, hangoutLink: c.hangout, location: c.location,
                                        description: c.description)
            expect(got?.absoluteString == c.expected, "join: \(c.name) → \(got?.absoluteString ?? "nil")")
        }
        expect(JoinLinks.urls(in: "a https://x.y/1, https://z.w/2.") == ["https://x.y/1", "https://z.w/2"], "url scanner")
        expect(PlainText.fromHTML("Hi<br>there &amp; <b>you</b><p>Para</p>") == "Hi\nthere & you\nPara", "html → plain")
        expect(PlainText.fromHTML("Line 1\nLine 2") == "Line 1\nLine 2", "plain text untouched")
        expect(PlainText.fromHTML("<ul><li>One</li><li>Two</li></ul>") == "\u{2022} One\n\u{2022} Two", "list items")
        expect(PlainText.fromHTML("   ") == nil && PlainText.fromHTML(nil) == nil, "empty → nil")
        expect(PlainText.decode("&#39;x&#x41;&nbsp;&bogus;") == "'xA &bogus;", "entity decoding")
    }
}
