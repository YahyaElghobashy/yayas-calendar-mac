// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (renders and the test runners). Release builds leave it out.
#if YC_DEV_TOOLS
import Foundation

/// Yaya's Mail Helper's files for renders and tests (D-050), the Moonfield cast only: fictional people, `.example`
/// addresses, made-up subjects. Pinned to the sample week's "now" (Monday 19 October 2026, 9:48 AM, London =
/// 1792399680). `Tests/Fixtures/mailhelper-state.json` and `mailhelper-digest.json` are these same bytes
/// (the shell tests check them; `--write-fixtures` writes them).
/// Accounts: Personal (handed over, Local + Claude, clean-up done), ORB (handed over, Local, a dry run ready to
/// review), CMT (handed over, paused), FAM (not handed over yet).
enum MailHelperFixtures {
    static let home = Cast.home.id.uuidString
    static let orb = Cast.orb.id.uuidString
    static let cmt = Cast.cmt.id.uuidString

    /// The fixture server's sealing key (its private half is in Tests/MailHelperTests.swift, tests only) and its
    /// fingerprint.
    static let sealKey = "agxBS5neXZl+J2wFnss6T3IIpmxWZzVImQhR42I3PHI="
    static let sealFingerprint = "N2MJ-PWCK-MGH4"

    static let state = #"""
    {
      "version": 1,
      "updated_at": 1792399500,
      "lab": {"paired": true, "reachable": true, "origin": "https://mail-lab.example", "last_ok_at": 1792399500, "error": null},
      "server": {"seal_key": "agxBS5neXZl+J2wFnss6T3IIpmxWZzVImQhR42I3PHI=", "seal_fingerprint": "N2MJ-PWCK-MGH4"},
      "status": {
        "version": 1, "now": 1792399500, "root_label": "Sorted", "digest_at": "07:00", "tz": "Europe/London",
        "claude_credentials": ["orbital", "personal"], "codex_credentials": ["personal"], "local_model": true,
        "open_proposals": 3, "errors": [],
        "models": {"fetched_at": 1792399000, "providers": [
          {"id": "local", "title": "Local", "models": [{"id": "local", "title": "Local (on your mail server)", "efforts": []}]},
          {"id": "claude", "title": "Claude", "live": true, "models": [
            {"id": "claude-haiku-5-5", "title": "Claude Haiku 5.5", "efforts": ["low", "medium", "high", "xhigh", "max"], "default_effort": "low"},
            {"id": "claude-sonnet-5-5", "title": "Claude Sonnet 5.5", "efforts": ["low", "medium", "high", "xhigh", "max"], "default_effort": "low"},
            {"id": "claude-opus-5-5", "title": "Claude Opus 5.5", "efforts": ["low", "medium", "high", "xhigh", "max"], "default_effort": "low"},
            {"id": "claude-fable-5-1", "title": "Claude Fable 5.1", "efforts": ["low", "medium", "high", "xhigh", "max"], "default_effort": "low"}]},
          {"id": "codex", "title": "Codex", "live": true, "models": [
            {"id": "gpt-6.1-sol", "title": "GPT-6.1-Sol", "efforts": ["low", "medium", "high", "xhigh", "max", "ultra"], "default_effort": "low"},
            {"id": "BAD ID", "title": "dropped", "efforts": []}]}]},
        "accounts": [
          {"id": "00000000-0000-4000-8000-0000000000A0", "email": "avery@home.example", "kind": "personal", "enabled": true,
           "paused": false, "state": "ready", "detail": null, "ai_policy": "local+claude", "claude_credential": "personal",
           "claude_ready": true, "codex_credential": "personal", "codex_ready": true, "last_sync_at": 1792399440,
           "today": {"priority": 3, "people": 5, "newsletters": 14, "updates": 9, "promotions": 11, "orders": 2, "security": 1},
           "review_waiting": 2, "backfill": {"id": "bf-5e1f0a2b3c4d", "state": "applied", "scanned": 1876, "applied": 1876},
           "has_sign_in": true},
          {"id": "00000000-0000-4000-8000-0000000000A1", "email": "avery@orbitalpickle.example", "kind": "work", "enabled": true,
           "paused": true, "state": "ready", "detail": null, "ai_policy": "local", "claude_credential": null,
           "claude_ready": false, "claude_off_reason": "Claude is off for this account: its AI setting is Local only.", "last_sync_at": 1792399380, "today": {}, "review_waiting": 1,
           "backfill": {"id": "bf-0b1a2c3d4e5f", "state": "ready", "scanned": 1284, "applied": 0}, "has_sign_in": true},
          {"id": "00000000-0000-4000-8000-0000000000A2", "email": "avery@quietcomets.example", "kind": "work", "enabled": true,
           "paused": false, "state": "ready", "detail": null, "ai_policy": "off", "claude_credential": null,
           "claude_ready": false, "last_sync_at": 1792399320, "today": {"people": 2, "updates": 4, "social": 6},
           "review_waiting": 0, "backfill": null, "has_sign_in": true}
        ]
      },
      "labels": {
        "00000000-0000-4000-8000-0000000000A0": [
          {"label_id": "Label_101", "path": "Sorted/Priority", "category": "priority", "topic": null},
          {"label_id": "Label_102", "path": "Sorted/Review", "category": "review", "topic": null},
          {"label_id": "Label_103", "path": "Sorted/Newsletters", "category": "newsletters", "topic": null},
          {"label_id": "Label_104", "path": "Sorted/Newsletters/AI & Tech", "category": "newsletters", "topic": "AI & Tech"}
        ],
        "00000000-0000-4000-8000-0000000000A1": [
          {"label_id": "Label_201", "path": "Sorted/Priority", "category": "priority", "topic": null},
          {"label_id": "Label_202", "path": "Sorted/Review", "category": "review", "topic": null}
        ],
        "00000000-0000-4000-8000-0000000000A2": [
          {"label_id": "Label_301", "path": "Sorted/Priority", "category": "priority", "topic": null}
        ]
      },
      "proposals": [
        {"id": 7, "account": "00000000-0000-4000-8000-0000000000A0", "kind": "rule_suggested", "key": "k7", "status": "open",
         "created_at": 1792390000, "decided_at": null,
         "payload": {"sender": "hello@picklescience.example", "kind": "moved", "category": "newsletters", "topic": "Science", "priority": null}},
        {"id": 8, "account": "00000000-0000-4000-8000-0000000000A0", "kind": "new_label", "key": "k8", "status": "open",
         "created_at": 1792380000, "decided_at": null,
         "payload": {"category": "newsletters", "topic": "Design", "mails": 12, "senders": 3, "moved": 12}},
        {"id": 9, "account": "00000000-0000-4000-8000-0000000000A2", "kind": "merge", "key": "k9", "status": "open",
         "created_at": 1792370000, "decided_at": null,
         "payload": {"label_id": "Label_305", "category": "updates", "topic": "Ticketing", "mails": 2}}
      ],
      "review": [
        {"account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5b0a1", "sender": "theo@moonbase.example",
         "subject": "Quick question about the spring tour", "reasons": ["first email from this sender", "reads like a person and an offer"],
         "confidence": 0.48, "decided_at": 1792398000},
        {"account": "00000000-0000-4000-8000-0000000000A1", "thread_id": "18f2a0c4d1e5b0a2", "sender": "events@lanternhall.example",
         "subject": "Your table for Thursday, plus a members' preview", "reasons": ["mixes a booking with a promotion"],
         "confidence": 0.52, "decided_at": 1792396000}
      ],
      "activity": [
        {"id": 5121, "account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5b1a1", "at": 1792399320,
         "batch": null, "added": ["Sorted/Newsletters/AI & Tech"], "removed": ["INBOX"], "reason": "newsletter from a known sender",
         "source": "engine", "undone": false, "subject": "This week in orbital robotics", "sender": "letters@orbitweekly.example",
         "category": "newsletters", "topic": "AI & Tech"},
        {"id": 5120, "account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5b1a2", "at": 1792398960,
         "batch": null, "added": ["Sorted/Priority", "IMPORTANT"], "removed": [], "reason": "a person you've written to",
         "source": "engine", "undone": false, "subject": "Saturday lunch at Juniper's?", "sender": "juniper@moonfield-family.example",
         "category": "people", "topic": null},
        {"id": 5119, "account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5b1a3", "at": 1792398600,
         "batch": null, "added": ["Sorted/Promotions"], "removed": ["INBOX", "UNREAD"], "reason": "rule: offers@moonbase-outfitters.example",
         "source": "engine", "undone": false, "subject": "Autumn layers, 30% off until Sunday", "sender": "offers@moonbase-outfitters.example",
         "category": "promotions", "topic": null},
        {"id": 5118, "account": "00000000-0000-4000-8000-0000000000A2", "thread_id": "18f2a0c4d1e5b1a4", "at": 1792397700,
         "batch": null, "added": ["Sorted/Social"], "removed": ["INBOX", "UNREAD"], "reason": "social network notification",
         "source": "engine", "undone": false, "subject": "3 people reacted to your rehearsal clip", "sender": "notify@friendwave.example",
         "category": "social", "topic": null},
        {"id": 5117, "account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5b1a5", "at": 1792396500,
         "batch": null, "added": ["Sorted/Updates"], "removed": ["INBOX", "UNREAD"], "reason": "automated update",
         "source": "engine", "undone": true, "subject": "Build 412 passed", "sender": "builds@moonforge.example",
         "category": "updates", "topic": null}
      ],
      "backfills": {
        "bf-0b1a2c3d4e5f": {
          "run": "bf-0b1a2c3d4e5f", "account": "00000000-0000-4000-8000-0000000000A1", "state": "ready", "scanned": 1284, "applied": 0,
          "totals": {"threads": 1284, "stay": 212, "leave": 1072, "priority": 64, "review": 23},
          "labels": [
            {"label": "Sorted/Newsletters/AI & Tech", "category": "newsletters", "topic": "AI & Tech", "count": 214, "stays_in_inbox": 0,
             "senders": [{"sender": "letters@orbitweekly.example", "count": 120}, {"sender": "digest@neuralpost.example", "count": 94}],
             "samples": [{"thread_id": "18f2a0c4d1e5c001", "sender": "letters@orbitweekly.example", "subject": "This week in orbital robotics", "why": []},
                         {"thread_id": "18f2a0c4d1e5c002", "sender": "digest@neuralpost.example", "subject": "Five papers worth your Sunday", "why": []},
                         {"thread_id": "18f2a0c4d1e5c003", "sender": "letters@orbitweekly.example", "subject": "The pickle-powered satellite, explained", "why": []}]},
            {"label": "Sorted/Updates/Dev tools", "category": "updates", "topic": "Dev tools", "count": 188, "stays_in_inbox": 0,
             "senders": [{"sender": "builds@moonforge.example", "count": 141}, {"sender": "alerts@ticketdesk.example", "count": 47}],
             "samples": [{"thread_id": "18f2a0c4d1e5c004", "sender": "builds@moonforge.example", "subject": "Build 409 failed on main", "why": []}]},
            {"label": "Sorted/Promotions", "category": "promotions", "topic": null, "count": 156, "stays_in_inbox": 0,
             "senders": [{"sender": "offers@moonbase-outfitters.example", "count": 88}, {"sender": "deals@lanternhall.example", "count": 68}],
             "samples": [{"thread_id": "18f2a0c4d1e5c005", "sender": "offers@moonbase-outfitters.example", "subject": "Autumn layers, 30% off", "why": []}]},
            {"label": "Sorted/People", "category": "people", "topic": null, "count": 140, "stays_in_inbox": 140,
             "senders": [{"sender": "juniper@orbitalpickle.example", "count": 37}, {"sender": "theo@moonbase.example", "count": 21}],
             "samples": [{"thread_id": "18f2a0c4d1e5c006", "sender": "juniper@orbitalpickle.example", "subject": "Notes from the jar-lid review", "why": []}]},
            {"label": "Sorted/Updates/Work tools", "category": "updates", "topic": "Work tools", "count": 97, "stays_in_inbox": 6,
             "senders": [{"sender": "mentions@taskgarden.example", "count": 97}],
             "samples": [{"thread_id": "18f2a0c4d1e5c007", "sender": "mentions@taskgarden.example", "subject": "Ines assigned you: Brine supplier shortlist", "why": []}]},
            {"label": "Sorted/Money", "category": "money", "topic": null, "count": 61, "stays_in_inbox": 9,
             "senders": [{"sender": "billing@cloudlocker.example", "count": 33}, {"sender": "receipts@parcelwing.example", "count": 28}],
             "samples": [{"thread_id": "18f2a0c4d1e5c008", "sender": "billing@cloudlocker.example", "subject": "Your October invoice", "why": []}]},
            {"label": "Sorted/Review", "category": "review", "topic": null, "count": 23, "stays_in_inbox": 23,
             "senders": [{"sender": "events@lanternhall.example", "count": 9}],
             "samples": [{"thread_id": "18f2a0c4d1e5c009", "sender": "events@lanternhall.example", "subject": "Your table for Thursday", "why": []}]}
          ],
          "new_labels": ["Sorted/Newsletters/AI & Tech", "Sorted/Updates/Dev tools", "Sorted/Updates/Work tools"]
        }
      }
    }
    """#

    static let digest = #"""
    {
      "version": 1,
      "updated_at": 1792389700,
      "digest": {
        "version": 1, "id": 42, "day": "2026-10-19", "window": [1792303200, 1792389600], "built_at": 1792389600, "total": 13,
        "read": {"security": true},
        "sections": [
          {"key": "newsletters", "title": "Newsletters", "count": 3, "items": [
            {"account": "00000000-0000-4000-8000-0000000000A0", "account_email": "avery@home.example", "thread_id": "18f2a0c4d1e5d001",
             "sender": "letters@orbitweekly.example", "subject": "This week in orbital robotics", "topic": "AI & Tech",
             "headline": "A pickle-sized satellite arm passes its first vacuum test",
             "bullets": ["The arm held a jar lid steady for 40 minutes in the test chamber.", "Launch window moves to March; the team is hiring two engineers.", "Next issue covers the docking clamp."],
             "worth_opening": true},
            {"account": "00000000-0000-4000-8000-0000000000A0", "account_email": "avery@home.example", "thread_id": "18f2a0c4d1e5d002",
             "sender": "hello@picklescience.example", "subject": "Brine, explained", "topic": null,
             "headline": "Why brine temperature matters more than salt",
             "bullets": ["Cooler brine kept the crunch in 9 of 10 batches.", "A reader recipe for quick fennel pickles."],
             "worth_opening": false},
            {"account": "00000000-0000-4000-8000-0000000000A2", "account_email": "avery@quietcomets.example", "thread_id": "18f2a0c4d1e5d003",
             "sender": "news@cometchords.example", "subject": "Comet Chords, issue 31", "topic": null,
             "headline": "Three practice drills for tighter harmonies",
             "bullets": ["Record a drone note and sing thirds over it.", "Free workshop on Saturday, sign-up closes Thursday."],
             "worth_opening": false}
          ]},
          {"key": "updates", "title": "Updates", "count": 5, "items": [
            {"service": "moonforge.example", "subjects": ["Build 412 passed", "Build 411 passed", "Deploy to staging finished"],
             "threads": [{"account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5d004"},
                         {"account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5d005"},
                         {"account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5d006"}],
             "account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5d004"},
            {"service": "cloudlocker.example", "subjects": ["Your storage is 80% full", "New sign-in from a known device"],
             "threads": [{"account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5d007"},
                         {"account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5d008"}],
             "account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5d007"}
          ]},
          {"key": "promotions", "title": "Deals and promotions", "count": 2, "items": [
            {"account": "00000000-0000-4000-8000-0000000000A0", "account_email": "avery@home.example", "thread_id": "18f2a0c4d1e5d009",
             "sender": "offers@moonbase-outfitters.example", "subject": "Autumn layers, 30% off until Sunday", "topic": null,
             "headline": "30% off coats and knitwear until Sunday",
             "bullets": ["Code at checkout, ends Sunday at midnight.", "Free returns for 60 days."], "worth_opening": false},
            {"account": "00000000-0000-4000-8000-0000000000A2", "account_email": "avery@quietcomets.example", "thread_id": "18f2a0c4d1e5d00a",
             "sender": "deals@lanternhall.example", "subject": "Members' preview: Friday night", "topic": null,
             "headline": "Members get the Friday show at half price",
             "bullets": ["Booking opens Wednesday at 10:00.", "Two tickets per member."], "worth_opening": true}
          ]},
          {"key": "orders", "title": "Orders and deliveries", "count": 2, "items": [
            {"account": "00000000-0000-4000-8000-0000000000A0", "account_email": "avery@home.example", "thread_id": "18f2a0c4d1e5d00b",
             "sender": "track@parcelwing.example", "subject": "Your parcel is on its way", "topic": null, "headline": null, "bullets": [], "worth_opening": false},
            {"account": "00000000-0000-4000-8000-0000000000A0", "account_email": "avery@home.example", "thread_id": "18f2a0c4d1e5d00c",
             "sender": "receipts@parcelwing.example", "subject": "Receipt for order 2210", "topic": null, "headline": null, "bullets": [], "worth_opening": false}
          ]},
          {"key": "security", "title": "Codes and security", "count": 1, "items": [
            {"account": "00000000-0000-4000-8000-0000000000A0", "account_email": "avery@home.example", "thread_id": "18f2a0c4d1e5d00d",
             "sender": "no-reply@cloudlocker.example", "subject": "Your sign-in code", "topic": null, "headline": null, "bullets": [], "worth_opening": false}
          ]}
        ]
      }
    }
    """#

    /// `needs_reply` → `data`.
    static let needsReply = #"""
    {"threads": [
      {"account": "00000000-0000-4000-8000-0000000000A0", "thread_id": "18f2a0c4d1e5e001", "sender": "juniper@moonfield-family.example",
       "subject": "Saturday lunch at Juniper's?", "category": "people", "priority": 1, "reasons": ["a person you've written to"], "decided_at": 1792398960},
      {"account": "00000000-0000-4000-8000-0000000000A1", "thread_id": "18f2a0c4d1e5e002", "sender": "ines@orbitalpickle.example",
       "subject": "Can you sign off the brine supplier shortlist?", "category": "people", "priority": 1, "reasons": ["asks you something"], "decided_at": 1792390000},
      {"account": "00000000-0000-4000-8000-0000000000A2", "thread_id": "18f2a0c4d1e5e003", "sender": "milo@quietcomets.example",
       "subject": "Set list for Friday", "category": "people", "priority": 0, "reasons": ["band mate"], "decided_at": 1792340000}
    ]}
    """#

    /// `voice_get` → `data` for Personal.
    static let voice = #"""
    {"card": "English, to friends and family: short, warm, first names. Opens with \"Hey <name>\" or straight in; no \"I hope this finds you well\". Two to four sentences, one question at most. Signs off \"A.\" or nothing.\nWork: polite and direct, bullet points for more than two items, ends with a clear next step and \"Thanks, Avery\".", "samples": 46}
    """#

    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func parsedState() -> MailHelperState? { MailHelperParse.state(data(state)).value }
    static func parsedDigest() -> MailHelperDigest? { MailHelperParse.digest(data(digest)).value ?? nil }

    /// Fixture files for Tests/Fixtures (the same text, without the Swift indentation).
    static let files: [(name: String, text: String)] = [("mailhelper-state.json", state), ("mailhelper-digest.json", digest)]
}

/// The helper's fixture files as the Daily Digest's snapshot (D-053), the way `MailHelperLive` builds it.
enum FixtureDigest {
    static func snapshot() -> WidgetSnapshot.Digest {
        let digest = MailHelperParse.digest(Data(MailHelperFixtures.digest.utf8)).value ?? nil
        let state = MailHelperParse.state(Data(MailHelperFixtures.state.utf8)).value
        guard let digest else { return WidgetSnapshot.Digest(id: 0, day: "", total: 0, sections: [], boxes: []) }
        return MailHelperDigestWidget.snapshot(digest, mailboxes: MailHelperDigestWidget.mailboxes(state),
                                               known: FixtureAccounts.all.map(\.id))
    }
}
#endif
