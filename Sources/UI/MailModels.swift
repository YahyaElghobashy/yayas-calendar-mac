import Foundation

// Mail building blocks shared by the Inbox section, the reader, the composer and the Mail Peek. Pure
// logic only (no WebKit, no windows), so the test binary checks every decision here.

// MARK: - Small local store (last From, image allow-list mirror)

/// A few strings the surfaces remember for themselves. The app uses UserDefaults; tests and renders use
/// memory, so they never write the user's preferences.
protocol MailLocalStore: AnyObject {
    func string(_ key: String) -> String?
    func setString(_ value: String?, _ key: String)
    func strings(_ key: String) -> [String]
    func setStrings(_ value: [String], _ key: String)
}

final class DefaultsMailLocalStore: MailLocalStore {
    static let shared = DefaultsMailLocalStore()
    private let defaults = UserDefaults.standard

    func string(_ key: String) -> String? { defaults.string(forKey: key) }
    func setString(_ value: String?, _ key: String) { defaults.set(value, forKey: key) }
    func strings(_ key: String) -> [String] { defaults.stringArray(forKey: key) ?? [] }
    func setStrings(_ value: [String], _ key: String) { defaults.set(value, forKey: key) }
}

final class MemoryMailLocalStore: MailLocalStore {
    private var values: [String: Any] = [:]

    func string(_ key: String) -> String? { values[key] as? String }
    func setString(_ value: String?, _ key: String) { values[key] = value }
    func strings(_ key: String) -> [String] { values[key] as? [String] ?? [] }
    func setStrings(_ value: [String], _ key: String) { values[key] = value }
}

// MARK: - Image allow list

/// Optional extra on `MailPreferencesStore`: the allow list itself, for Settings. The frozen seam only
/// answers "is this sender allowed?", so until the data layer's store adopts this, the surfaces keep a
/// mirror of the senders they allowed and show those the store still allows.
protocol MailImageAllowListing: AnyObject {
    func allowedImageSenders() -> [String]
}

/// Optional extra on `MailPreferencesStore`, beside the frozen seam like the one above: forgets every address recorded
/// for "Images from people you've written to" (all accounts) when Settings turns it off. The data layer's
/// `LocalMailStore` adopts it (MailIntegration.swift).
protocol MailCorrespondentForgetting: AnyObject {
    func forgetCorrespondents() throws
}

enum MailImageSenders {
    static let mirrorKey = "mail.imageSenders"

    static func list(prefs: MailPreferencesStore, local: MailLocalStore) -> [String] {
        if let listing = prefs as? MailImageAllowListing {
            return listing.allowedImageSenders().map { $0.lowercased() }.sorted()
        }
        return Array(Set(local.strings(mirrorKey).map { $0.lowercased() }))
            .filter { prefs.allowsImages(from: $0) }.sorted()
    }

    /// "Always for this sender".
    static func allow(_ sender: String, prefs: MailPreferencesStore, local: MailLocalStore) throws {
        let s = sender.lowercased()
        try prefs.setAllowsImages(from: s, true)
        var mirror = local.strings(mirrorKey).map { $0.lowercased() }
        if !mirror.contains(s) { mirror.append(s) }
        local.setStrings(mirror, mirrorKey)
    }

    /// Settings → remove.
    static func remove(_ sender: String, prefs: MailPreferencesStore, local: MailLocalStore) throws {
        let s = sender.lowercased()
        try prefs.setAllowsImages(from: s, false)
        local.setStrings(local.strings(mirrorKey).filter { $0.lowercased() != s }, mirrorKey)
    }
}

// MARK: - Undo

/// Undo tokens of recent archives and trashes, by row, for 30 s (CONTRACTS "Mail": `mail/undo?r&k`
/// reverses the last archive/trash of row r). The router, the Inbox section and the Mail Peek share one.
final class MailUndoBook {
    static let shared = MailUndoBook()

    enum Kind: String { case archive, trash }
    struct Entry: Equatable {
        let token: UndoToken
        let kind: Kind
        let at: Date
    }

    private var entries: [String: Entry] = [:]

    func record(r: String, token: UndoToken, kind: Kind, at: Date) {
        prune(now: at)
        entries[r] = Entry(token: token, kind: kind, at: at)
    }

    /// The live entry for row r (and forgets it): nil when there is none or its 30 s are over.
    func take(r: String, now: Date) -> Entry? {
        guard let entry = entries.removeValue(forKey: r) else { return nil }
        return now.timeIntervalSince(entry.at) < MailUndo.window ? entry : nil
    }

    func peek(r: String, now: Date) -> Entry? {
        guard let entry = entries[r], now.timeIntervalSince(entry.at) < MailUndo.window else { return nil }
        return entry
    }

    func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.at) < MailUndo.window }
    }

    var count: Int { entries.count }
}

/// One toast at a time at the bottom of the Inbox, the Mail Peek or the composer: "Archived · Undo" for
/// 30 s, "Sending… Undo" for 5 s, or a friendly error for 5 s. Undo works only while the toast is live.
struct MailToast: Equatable, Identifiable {
    let id: Int
    let text: String
    let action: String?
    let expiresAt: Date
    let isError: Bool

    /// "Archived · Undo".
    var line: String { action.map { "\(text) · \($0)" } ?? text }
}

final class MailToastCenter: ObservableObject {
    static let errorDuration: TimeInterval = 5
    static let sendDuration: TimeInterval = 5

    @Published private(set) var toast: MailToast?
    private var undoAction: (() async -> Void)?
    private var nextId = 0
    private let clock: () -> Date
    /// Runs the expiry after the toast's duration (the app: the main queue; tests capture it).
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(clock: @escaping () -> Date = { Date() },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.clock = clock
        self.schedule = schedule
    }

    /// Shows a toast with an Undo button (default 30 s, the mail undo window).
    @discardableResult
    func show(_ text: String, action: String? = "Undo", duration: TimeInterval = MailUndo.window,
              undo: (() async -> Void)? = nil) -> MailToast {
        nextId += 1
        let toast = MailToast(id: nextId, text: text, action: undo == nil ? nil : action,
                              expiresAt: clock().addingTimeInterval(duration), isError: false)
        self.toast = toast
        undoAction = undo
        let id = toast.id
        schedule(duration) { [weak self] in self?.expire(id: id) }
        return toast
    }

    @discardableResult
    func error(_ text: String) -> MailToast {
        nextId += 1
        let toast = MailToast(id: nextId, text: text, action: nil, expiresAt: clock().addingTimeInterval(Self.errorDuration),
                              isError: true)
        self.toast = toast
        undoAction = nil
        let id = toast.id
        schedule(Self.errorDuration) { [weak self] in self?.expire(id: id) }
        return toast
    }

    func isLive(at now: Date) -> Bool { toast.map { now < $0.expiresAt } ?? false }

    /// Clears the toast if it is still the one shown (a newer toast replaces the timer's target).
    func expire(id: Int) {
        guard toast?.id == id else { return }
        toast = nil
        undoAction = nil
    }

    func dismiss() {
        toast = nil
        undoAction = nil
    }

    /// Undo, only while the toast is live. True when the undo ran.
    @MainActor
    @discardableResult
    func performUndo() async -> Bool {
        guard isLive(at: clock()), let action = undoAction else { return false }
        undoAction = nil
        toast = nil
        await action()
        return true
    }
}

// MARK: - Reader content policy

/// What the reader may load for one message. Sanitized HTML arrives from the data layer with scripts
/// removed; the reader adds two more locks: JavaScript off, and a content rule list that blocks every
/// remote load (plus a matching Content-Security-Policy) unless the sender is on the allow list or the
/// user tapped "Load images" for this message.
enum MailContentPolicy {
    struct Decision: Equatable {
        /// Draw the HTML part (else the plain text).
        let html: Bool
        /// Remote images may load.
        let allowRemote: Bool
        /// "Remote images are hidden. Load images · Always for this sender".
        let showImagesBar: Bool
    }

    static func decide(_ message: MailMessage, senderAllowed: Bool, loadedOnce: Bool) -> Decision {
        let html = !(message.html ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let allow = html && (senderAllowed || loadedOnce)
        return Decision(html: html, allowRemote: allow, showImagesBar: html && message.hasRemoteImages && !allow)
    }

    /// WKContentRuleList JSON. Blocked: every http(s), ws(s), ftp and file load. Allowed: images over
    /// http(s) only; everything else stays blocked.
    static func rules(allowRemote: Bool) -> String {
        let block = ["^https?:", "^wss?:", "^ftp:", "^file:"].map {
            "{\"trigger\":{\"url-filter\":\"\($0)\"},\"action\":{\"type\":\"block\"}}"
        }
        guard allowRemote else { return "[" + block.joined(separator: ",") + "]" }
        let images = "{\"trigger\":{\"url-filter\":\"^https?:\",\"resource-type\":[\"image\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}"
        return "[" + (block + [images]).joined(separator: ",") + "]"
    }

    static func ruleListIdentifier(allowRemote: Bool) -> String {
        allowRemote ? "yayacal.mail.images-allowed.v1" : "yayacal.mail.remote-blocked.v1"
    }

    /// The same rule as a Content-Security-Policy (belt and braces: holds even if the rule list fails).
    static func csp(allowRemote: Bool) -> String {
        "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; "
            + "style-src 'unsafe-inline'; font-src data:; img-src data: cid:" + (allowRemote ? " https: http:" : "")
    }

    /// The document around the sanitized fragment (rich mail, D-040): the message on a white sheet with a
    /// hairline, inset in the paper card (#F8F5F0, D-008); original colours, no dark adaptation. Our font sits on
    /// the sheet only, so sender CSS for `body` or `table` still wins. Wide mail is fitted to the width by the
    /// app-world script (zoom), not squeezed by CSS. `plain`: our own plain-text HTML (MailPlainText).
    static func document(_ html: String, allowRemote: Bool, plain: Bool = false) -> String {
        let hideRemote = allowRemote ? "" : "img[src^=\"http\" i]{display:none!important}"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light">\
        <meta http-equiv="Content-Security-Policy" content="\(csp(allowRemote: allowRemote))">\
        <style>\(css)\(plain ? plainCSS : "")\(hideRemote)</style></head>\
        <body><div class="yc-sheet">\(html)</div></body></html>
        """
    }

    /// Sheet, links, images without a width, quote bars (three colours, cycling) and the "•••" pill. The details
    /// marker rule is spelled `display: none` (with a space): the allowed-images document must not contain the
    /// remote-hiding `display:none` rule (MailTests).
    static let css = "html{background:#F8F5F0}html,body{margin:0;padding:0}body{padding:1px 1px 3px;background:#F8F5F0}"
        + ".yc-sheet{background:#FFFFFF;color:#1D1B20;padding:16px 18px;border-radius:10px;box-shadow:0 0 0 1px #E7E1D8;"
        + "font:14px/1.5 -apple-system,\"SF Pro Text\",Helvetica,sans-serif}"
        + "a{color:#14937F}img:not([width]){max-width:100%;height:auto}pre{white-space:pre-wrap}"
        + "img[data-yc-blocked]{background:#F4F0EA;color:#8C8590;font:12px/1.4 -apple-system,Helvetica,sans-serif;border-radius:4px;"
        + "outline:1px solid #ECE6DC;outline-offset:-1px}"
        + "\(quoteSelector){margin:0 0 0 .3em;padding-left:.9em;border-left:2px solid #C9BFB2;color:#4A4550}"
        + ":is(\(quoteSelector)) :is(\(quoteSelector)){border-left-color:#A9C3B9}"
        + ":is(\(quoteSelector)) :is(\(quoteSelector)) :is(\(quoteSelector)){border-left-color:#B9B2D0}"
        + ":is(\(quoteSelector)) :is(\(quoteSelector)) :is(\(quoteSelector)) :is(\(quoteSelector)){border-left-color:#C9BFB2}"
        + "details.yc-quote{margin:0;padding:0}"
        + "details.yc-quote>summary{list-style:none;display:inline-block;margin:6px 0;padding:0 7px;border-radius:6px;"
        + "background:#ECE6DC;color:#5A5560;font:700 11px/18px -apple-system,Helvetica,sans-serif;letter-spacing:1px;cursor:pointer;"
        + "white-space:nowrap;user-select:none;-webkit-user-select:none}"
        + "details.yc-quote>summary::-webkit-details-marker{display: none}"
        + "details.yc-quote[open]>summary{background:#E2DCD2}"
        + "summary.yc-more{display:inline-block!important;visibility:visible!important;opacity:1!important}"

    static let quoteSelector = "blockquote[type=cite],blockquote.gmail_quote,.yc-q"

    static let plainCSS = ".yc-plain{white-space:pre-wrap;font:14px/1.55 -apple-system,\"SF Pro Text\",Helvetica,sans-serif;"
        + "overflow-wrap:anywhere}.yc-pre{font:12.5px/1.45 Menlo,monospace;white-space:pre;overflow-x:auto;overflow-wrap:normal;"
        + "margin:2px 0}.yc-sig{color:#8C8590}.yc-sig a{color:#8C8590}"

    /// Bodies over this (after sanitizing) are cut, with a "Show the rest" button under them. Gmail
    /// clips at about 100 KB; this only catches pathological mail.
    static let clipLimit = 2 << 20

    /// The first `limit` bytes, cut after the last block end before the limit; nil when the body is smaller.
    static func clip(_ html: String, limit: Int = clipLimit) -> String? {
        guard html.utf8.count > limit else { return nil }
        let head = String(decoding: html.utf8.prefix(limit), as: UTF8.self)
        var cut = head.startIndex
        for end in ["</div>", "</p>", "</table>", "</tr>", "</li>", "</blockquote>", "</ul>", "</ol>", "<br>"] {
            if let r = head.range(of: end, options: .backwards), r.upperBound > cut { cut = r.upperBound }
        }
        if cut == head.startIndex, let gt = head.lastIndex(of: ">") { cut = head.index(after: gt) }
        return String(head[..<cut])
    }

    /// WebKit's context-menu items the reader removes: nothing may open, download or reload in the reader;
    /// "Copy Link" and "Copy Image" are replaced by our own (links: from the hover script; images: cid only).
    static let removedMenuItems: Set<String> = [
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierDownloadMedia", "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
    ]

    /// Keep this context-menu item? (Copy, Look Up, Translate, Speech, Share… stay.)
    static func keepsMenuItem(_ identifier: String?) -> Bool {
        guard let identifier else { return true }
        return !removedMenuItems.contains(identifier)
    }

    /// The hovered link as the reader shows it (anti-phishing): the real host in bold, then the rest, middle-
    /// truncated so the whole fits 60 characters. Only what a click would do: web links and mailto.
    static func hoverLabel(_ url: URL, limit: Int = 60) -> (host: String, rest: String)? {
        switch linkAction(url: url, isUserAction: true) {
        case .openInBrowser(let link):
            var host = (link.host ?? "").lowercased()
            var rest = link.path
            if let query = link.query, !query.isEmpty { rest += "?" + query }
            if let fragment = link.fragment, !fragment.isEmpty { rest += "#" + fragment }
            if rest == "/" { rest = "" }
            if host.count > limit { host = middle(host, limit); rest = "" }
            if host.count + rest.count > limit { rest = middle(rest, max(limit - host.count, 8)) }
            return (host, rest)
        case .compose(let address):
            return (address.count > limit ? middle(address, limit) : address, "")
        default:
            return nil
        }
    }

    /// "abcdefghij" → "abc…hij" in `limit` characters.
    static func middle(_ s: String, _ limit: Int) -> String {
        guard s.count > limit, limit > 1 else { return s }
        let keep = limit - 1
        let head = (keep + 1) / 2, tail = keep - head
        return String(s.prefix(head)) + "\u{2026}" + String(s.suffix(tail))
    }

    /// What a click inside a message does. The reader never navigates: the first load (our own
    /// document) is allowed, web links open in the default browser, `mailto:` opens the composer, and
    /// everything else is ignored.
    enum LinkAction: Equatable {
        case allowInitialLoad
        /// A same-document anchor (`#toc` in a newsletter): scrolls, never navigates.
        case allowAnchor
        case openInBrowser(URL)
        case compose(to: String)
        case ignore
    }

    static func linkAction(url: URL?, isUserAction: Bool) -> LinkAction {
        guard let url else { return .ignore }
        let scheme = url.scheme?.lowercased() ?? ""
        if !isUserAction, scheme == "about" { return .allowInitialLoad }
        guard isUserAction else { return .ignore }
        switch scheme {
        case "about":
            let target = url.absoluteString
            return target.hasPrefix("about:blank#") && target.count > "about:blank#".count ? .allowAnchor : .ignore
        case "http", "https":
            guard url.host?.isEmpty == false, url.user == nil, url.password == nil else { return .ignore }
            return .openInBrowser(url)
        case "mailto":
            let address = String(url.absoluteString.dropFirst("mailto:".count).prefix { $0 != "?" })
                .removingPercentEncoding ?? ""
            return MailText.isAddress(address) ? .compose(to: address) : .ignore
        default:
            return .ignore
        }
    }
}

// MARK: - Text

enum MailText {
    /// Inbox list time: "9:41 AM" today, "Yesterday", the weekday within a week, "12 Oct", "12 Oct 2025".
    static func listTime(_ date: Date, now: Date, calendar: Calendar = WidgetCalendar.current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return DayName.format("h:mm a", date)
        }
        let today = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 99
        if days >= 0, days < 7 { return DayName.format("EEEE", date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return DayName.format("d MMM", date) }
        return DayName.format("d MMM yyyy", date)
    }

    /// Reader header: "Monday 19 October, 9:41 AM".
    static func longDate(_ date: Date) -> String { DayName.format("EEEE d MMMM, h:mm a", date) }

    /// "186 KB", "2.4 MB".
    static func size(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(max(bytes, 0)) bytes" }
        if bytes < 1_000_000 { return "\(Int((Double(bytes) / 1_000).rounded())) KB" }
        let mb = Double(bytes) / 1_000_000
        return mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB"
    }

    /// "Name <a@b.example>" or "a@b.example" → "a@b.example" (lowercased).
    static func bareAddress(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = t.lastIndex(of: "<"), let close = t.lastIndex(of: ">"), open < close {
            return String(t[t.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return t.lowercased()
    }

    /// "Theo Quill <theo@moonbase.example>" → "Theo Quill"; a bare address → nil.
    static func displayName(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = t.lastIndex(of: "<"), let close = t.lastIndex(of: ">"), open < close else { return nil }
        return String(t[..<open])
    }

    /// A display name worth showing: trimmed, unquoted, not empty, not an address itself, at most 60 characters.
    static func cleanName(_ name: String?, address: String) -> String? {
        guard let name else { return nil }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("@"), t.lowercased() != address.lowercased() else { return nil }
        return t.count > 60 ? String(t.prefix(59)) + "\u{2026}" : t
    }

    /// Plain comma entry: commas, semicolons and new lines separate addresses.
    static func addresses(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(bareAddress)
    }

    static func isAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else {
            return false
        }
        return !s.contains { $0.isWhitespace || "<>(),;:\"[]\\".contains($0) }
    }

    /// Reader header: "to me", "to me, milo@orbitalpickle.example", "to juniper@orbitalpickle.example and 2 more".
    static func recipients(to: [String], cc: [String], own: Set<String>, limit: Int = 2) -> String {
        let all = (to + cc).map(bareAddress)
        guard !all.isEmpty else { return "to (no one)" }
        var names: [String] = []
        if all.contains(where: own.contains) { names.append("me") }
        names += all.filter { !own.contains($0) }
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? "to \(shown) and \(names.count - limit) more" : "to \(shown)"
    }

    /// First name for buttons and titles: "Juniper" from "Juniper Vale".
    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

// MARK: - Keyboard

/// Inbox keys (Gmail's): J/K or ↓/↑ move, E archive, U unread, S star, # trash, R reply, F forward, Return open.
enum InboxCommand: Equatable {
    case next, previous, archive, toggleUnread, toggleStar, trash, reply, open, forward

    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    /// `commandKeys` = ⌘, ⌃ or ⌥ held (those belong to menus); Shift is fine (it types #).
    static func from(characters: String?, keyCode: UInt16, commandKeys: Bool) -> InboxCommand? {
        guard !commandKeys else { return nil }
        switch keyCode {
        case returnKey, enterKey: return .open
        case downArrow: return .next
        case upArrow: return .previous
        default: break
        }
        switch characters {
        case "j": return .next
        case "k": return .previous
        case "e": return .archive
        case "u": return .toggleUnread
        case "s": return .toggleStar
        case "#": return .trash
        case "r": return .reply
        case "f": return .forward
        default: return nil
        }
    }
}
