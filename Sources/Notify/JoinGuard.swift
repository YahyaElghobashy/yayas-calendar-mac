import Foundation

/// The join-link check for notification actions and the Deck export: exactly the sync-time rules of
/// `JoinLinks.isAllowed` (https, no user/password/odd port, ASCII host, exact hosts with per-host path
/// prefixes; subdomains only for Zoom and Webex). Every stored join URL already passed them, and this
/// re-check applies them again before a notification opens a link or the export lists it.
///
/// The widget's Join route, ⌃⌥J, the popover and the Peek re-check with `JoinPolicy` (Sources/App/
/// RouteDecisions.swift) instead: https on the same providers, matched by host or any subdomain, with no
/// path rules. That check is looser on its own, but every link it sees was stored after passing the rules
/// above, so a link that fails them never reaches it.
enum JoinGuard {
    static func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return JoinLinks.isAllowed(url)
    }

    /// "Google Meet", "Zoom"… for the notification body (allowed links only).
    static func providerName(_ url: URL?) -> String? {
        guard isAllowed(url), let host = url?.host?.lowercased() else { return nil }
        let names: [(host: String, subdomains: Bool, name: String)] = [
            ("meet.google.com", false, "Google Meet"), ("zoom.us", true, "Zoom"),
            ("teams.microsoft.com", false, "Teams"), ("teams.live.com", false, "Teams"), ("webex.com", true, "Webex"),
            ("whereby.com", false, "Whereby"), ("app.slack.com", false, "Slack"), ("meet.goto.com", false, "GoTo"),
            ("chime.aws", false, "Chime"), ("meet.jit.si", false, "Jitsi"),
        ]
        return names.first { host == $0.host || ($0.subdomains && host.hasSuffix("." + $0.host)) }?.name
    }
}
