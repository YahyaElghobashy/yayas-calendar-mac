import Combine
import CryptoKit
import Foundation

/// Yaya's Mail Helper link (D-050): presence, the command link, the helper's files (the fixtures, refusals, items that
/// fail their checks), answers, every command kind and its limits, sealing a sign-in (opened again here with the
/// fixture server's private key), the hand-over card, the inbox's Priority-first order and chips, meeting people, the
/// session (send, answers, time-outs), the page model (backlog, Review, suggestions, activity, VIPs, Needs reply, your
/// voice, the digest's read = done) and the composer's Draft with AI. Fakes and memory bags only: no helper files, no
/// Keychain, nothing opened.
@MainActor
enum MailHelperTests {
    static let now = Date(timeIntervalSince1970: 1_792_399_680)
    static let home = Cast.home.id, orb = Cast.orb.id, cmt = Cast.cmt.id, fam = Cast.fam.id
    /// Google's suffix for rooms and groups on invites (built here so the text holds no address).
    static let resourceDomain = "resource" + ".calendar.google.com"
    /// The fixture server's sealing key, private half (public: MailHelperFixtures.sealKey). Tests only.
    static let fixturePrivateKey = "fCSPjfOnzOM/Ujd6LuCKucS3DVeL9ydEtVKk/PvicVM="

    static func run() async {
        presence()
        links()
        json()
        stateFixture()
        stateRefused()
        digestFixture()
        answers()
        commands()
        sealing()
        inbox()
        inboxModel()
        meetings()
        session()
        await handover()
        backlogReviewActivity()
        vips()
        needsReplyAndVoice()
        digestReadIsDone()
        drafts()
        voiceNotes()
        composerInsert()
        fixtureFiles()
        routes()
    }

    // MARK: Fakes

    final class Fake {
        var installed = true
        var state: MailHelperRead<MailHelperState> = .ready(MailHelperFixtures.parsedState()!)
        var digest: MailHelperRead<MailHelperDigest?> = .ready(MailHelperFixtures.parsedDigest())
        var written: [(UUID, Data)] = []
        var opened: [URL] = []
        var answers: [UUID: MailHelperResult] = [:]
        var writeOK = true
        var clock = MailHelperTests.now
        var later: [@MainActor () -> Void] = []
        /// Answers every command as it is written (for awaited commands).
        var autoAnswer: MailHelperResult?

        func command(_ i: Int) -> MailHelperJSON? { i < written.count ? MailHelperJSON.parse(written[i].1) : nil }
        var last: MailHelperJSON? { written.last.flatMap { MailHelperJSON.parse($0.1) } }
        /// Answers the last command.
        func answer(ok: Bool = true, error: String? = nil, data: MailHelperJSON = .object([:])) {
            guard let id = written.last?.0 else { return }
            answers[id] = MailHelperResult(id: id, ok: ok, error: error, data: data)
        }
    }

    static func session(_ f: Fake, publishesInbox: Bool = false) -> MailHelperSession {
        let s = MailHelperSession(env: MailHelperSession.Environment(
            installed: { f.installed }, state: { f.state }, digest: { f.digest },
            write: { id, data in
                guard f.writeOK else { return false }
                f.written.append((id, data))
                if let a = f.autoAnswer { f.answers[id] = MailHelperResult(id: id, ok: a.ok, error: a.error, data: a.data) }
                return true
            },
            open: { f.opened.append($0); return true },
            answer: { id in f.answers.removeValue(forKey: id) },
            clock: { f.clock }, after: { _, work in f.later.append(work) }), publishesInbox: publishesInbox)
        s.refresh()
        return s
    }

    static func model(_ f: Fake, bag: PreferenceBag = MemoryBag(), live: MailHelperModel.Live = MailHelperModel.Live()) -> MailHelperModel {
        let s = session(f)
        return MailHelperModel(session: s, directory: { FixtureAccounts.directory() }, bag: bag, live: live, clock: { f.clock },
                               toasts: MailToastCenter(clock: { f.clock }, schedule: { _, _ in }))
    }

    // MARK: Presence and the link

    static func presence() {
        T.section("mail helper: installed means its own bundle id handles its scheme")
        let id = Profile.mailHelperBundleId
        T.check(MailHelperPresence.isInstalled(handlers: [id]), "the helper's id")
        T.check(MailHelperPresence.isInstalled(handlers: [nil, "org.example.other", id.uppercased()]), "among others, any case")
        T.check(!MailHelperPresence.isInstalled(handlers: []), "no handler")
        T.check(!MailHelperPresence.isInstalled(handlers: ["org.example.lookalike"]), "a look-alike")
        T.check(!MailHelperPresence.isInstalled(handlers: [id + ".fork", " " + id]), "a longer or padded id")
        #if YC_PROFILE_DEV
        T.check(Profile.mailHelperScheme.hasSuffix("-dev"), "a dev calendar looks only for a dev helper")
        #else
        T.check(!MailHelperPresence.isInstalled(handlers: [id + ".dev"]), "a release calendar ignores a dev helper")
        #endif
        T.equal(MailHelperFiles.changedNotification, id + ".changed", "the ping's name")
    }

    static func links() {
        T.section("mail helper: the command link and file names")
        let id = UUID(uuidString: "6F1C2B3A-0000-4000-8000-00000000BEEF")!
        let url = MailHelperLinks.command(id, scheme: "yayamail")
        T.equal(url?.absoluteString, "yayamail://cmd?id=6f1c2b3a-0000-4000-8000-00000000beef", "yayamail://cmd?id=<uuid>")
        T.equal(MailHelperFiles.commandName(id), "cmd-6f1c2b3a-0000-4000-8000-00000000beef.json", "command file name")
        T.equal(MailHelperFiles.resultName(id), "6f1c2b3a-0000-4000-8000-00000000beef.json", "answer file name")
        T.equal(MailHelperLinks.command(id)?.scheme, Profile.mailHelperScheme, "the profile's scheme")
    }

    static func json() {
        T.section("mail helper: JSON values keep their types")
        let j = MailHelperJSON.parse(Data(#"{"a":true,"b":1,"c":1.5,"d":"x","e":null,"f":[1,false]}"#.utf8))
        T.equal(j?["a"]?.bool, true, "a boolean stays a boolean")
        T.equal(j?["a"]?.int, nil, "…and is never a number")
        T.equal(j?["b"]?.int, 1, "integer")
        T.equal(j?["b"]?.bool, nil, "1 is not true")
        T.equal(j?["c"]?.double, 1.5, "fraction")
        T.equal(j?["c"]?.int, nil, "a fraction is not an integer")
        T.equal(j?["e"]?.isNull, true, "null")
        T.equal(j?["f"]?.array?.count, 2, "array")
        T.equal(MailHelperPlain.clean("a\u{202E}b\u{0007}  \n c", 10), "ab c", "control and direction characters out, spaces folded")
        T.equal(MailHelperPlain.clean(String(repeating: "x", count: 50), 10)?.count, 10, "capped")
    }

    // MARK: Files

    static func stateFixture() {
        T.section("mail helper: state.json (the fixture)")
        guard let s = MailHelperFixtures.parsedState() else { T.check(false, "the fixture parses"); return }
        T.equal(s.lab.paired, true, "paired")
        T.equal(s.lab.reachable, true, "reachable")
        T.equal(s.sealKey?.count, 32, "seal key, 32 bytes")
        T.equal(s.sealFingerprint, MailHelperFixtures.sealFingerprint, "fingerprint")
        T.equal(s.accounts.count, 3, "three accounts with the helper")
        let h = s.account(home)
        T.equal(h?.aiPolicy, .localClaude, "Personal: Local + Claude")
        T.equal(h?.claudeCredential, "personal", "Personal's credential")
        T.equal(h?.today["newsletters"], 14, "today's counts")
        T.equal(h?.reviewWaiting, 2, "review waiting")
        T.equal(h?.hasSignIn, true, "handed over")
        T.equal(s.account(orb)?.paused, true, "ORB paused")
        T.equal(s.account(fam) == nil, true, "FAM not with the helper")
        T.equal(s.claudeCredentials, ["orbital", "personal"], "credential names")
        T.equal(s.labels(home).count, 4, "Personal's labels")
        T.equal(s.proposals.map(\.kind), ["rule_suggested", "new_label", "merge"], "suggestions")
        T.equal(s.review.count, 2, "review queue")
        T.equal(s.activity.first?.id, 5121, "activity, newest first")
        T.equal(s.activity.last?.undone, true, "an undone action")
        let b = s.backfill(orb)
        T.equal(b?.state, "ready", "ORB's dry run is ready")
        T.equal(b?.groups.count, 7, "seven label groups")
        T.equal(b?.groups.first?.senders.count, 2, "top senders")
        T.equal(b?.groups.first?.samples.count, 3, "three samples")
        T.equal(s.backfill(home)?.state, "applied", "a run the helper sent no summary for: its status (Undo all still there)")
        T.equal(s.backfill(home)?.groups.count, 0, "…without label groups")
        T.equal(s.backfill(cmt), nil, "no run: none")
        T.equal(MailHelperText.backfillState(s.backfill(orb)!), "Plan ready: 1,284 conversations. Nothing has moved yet.", "the plan's words")
        T.equal(MailHelperText.change(s.activity[0], root: s.rootLabel), "Out of the inbox \u{00B7} Newsletters/AI & Tech", "what an action did")
        T.equal(MailHelperText.change(s.activity[2], root: s.rootLabel), "Out of the inbox \u{00B7} Promotions \u{00B7} marked read", "…and read")
    }

    static func stateRefused() {
        T.section("mail helper: files refused or partly read")
        T.equal(MailHelperParse.state(nil), .missing, "no file")
        T.equal(MailHelperParse.state(Data("not json".utf8)), .unreadable, "not JSON")
        T.equal(MailHelperParse.state(Data(#"{"version":"1"}"#.utf8)), .unreadable, "a string version")
        T.equal(MailHelperParse.state(Data(#"{"version":true}"#.utf8)), .unreadable, "a boolean version")
        T.equal(MailHelperParse.state(Data(#"{"version":2}"#.utf8)), .newer, "a newer version")
        T.equal(MailHelperParse.state(Data("[1]".utf8)), .unreadable, "not an object")
        T.equal(MailHelperParse.state(Data(count: MailHelperFiles.fileLimit + 1)), .unreadable, "over 4 MiB")
        T.equal(MailHelperParse.state(Data(#"{"version":1}"#.utf8)).value?.accounts.count, 0, "a bare file is an empty report")
        let partial = #"""
        {"version":1,"status":{"accounts":[{"id":"bad id!"},{"id":"ok-1","email":"a@b.example","today":{"people":-3,"news":"x"}}]},
         "review":[{"account":"ok-1","thread_id":"NOT-HEX"},{"account":"ok-1","thread_id":"abc123"}],
         "activity":[{"id":1,"account":"ok-1","thread_id":"abc","at":"yesterday"}],
         "backfills":{"bf-zzz":{"account":"ok-1"}},
         "server":{"seal_key":"c2hvcnQ=","seal_fingerprint":"AAAA-BBBB-CCCC"}}
        """#
        let s = MailHelperParse.state(Data(partial.utf8)).value
        T.equal(s?.accounts.map(\.id), ["ok-1"], "an account with a bad id is skipped")
        T.equal(s?.accounts.first?.today, [:], "bad counts read as absent")
        T.equal(s?.review.map(\.threadId), ["abc123"], "a thread id that isn't Gmail's is skipped")
        T.equal(s?.activity.count, 0, "an action without a time is skipped")
        T.equal(s?.backfills.count, 0, "a run id outside the contract is skipped")
        T.equal(s?.sealKey, nil, "a seal key that isn't 32 bytes is ignored")
    }

    static func digestFixture() {
        T.section("mail helper: digest.json (the fixture)")
        guard let d = MailHelperFixtures.parsedDigest() else { T.check(false, "the fixture parses"); return }
        T.equal(d.id, 42, "id")
        T.equal(d.sections.map(\.key), ["newsletters", "updates", "promotions", "orders", "security"], "sections in order")
        T.equal(d.total, 13, "total")
        let first = d.sections[0].items[0]
        T.equal(first.isSummary, true, "a newsletter is summarised")
        T.equal(first.worthOpening, true, "worth opening")
        T.equal(first.bullets.count, 3, "bullets")
        let group = d.sections[1].items[0]
        T.equal(group.isGroup, true, "updates are grouped by service")
        T.equal(group.threads.count, 3, "each subject's thread")
        T.equal(d.sections[3].items[0].isSummary, false, "orders are plain subjects")
        T.equal(d.read, ["security": true], "what the helper already marked read")
        T.equal(d.batch("newsletters"), "digest:42:newsletters", "the undo batch of a section")
        T.equal(d.batch(nil), "digest:42:all", "…and of Mark all read")
        T.equal(MailHelperParse.digest(Data(#"{"version":1,"digest":null}"#.utf8)), .ready(nil), "no digest yet")
        T.equal(MailHelperParse.digest(Data(#"{"version":3}"#.utf8)), .newer, "a newer digest")
        let hostile = #"{"version":1,"digest":{"id":1,"sections":[{"key":"newsletters","items":[{"account":"a","thread_id":"ab","headline":"[click](https://x.example) ‮evil","bullets":["a\u0000b"]}]}]}}"#
        let h = MailHelperParse.digest(Data(hostile.utf8)).value??.sections.first?.items.first
        T.equal(h?.headline, "[click](https://x.example) evil", "a headline stays plain text (drawn verbatim), direction marks out")
        T.equal(h?.bullets, ["ab"], "control characters out")
    }

    static func answers() {
        T.section("mail helper: answers")
        let id = UUID()
        let ok = MailHelperParse.result(Data(#"{"version":1,"id":"\#(id.uuidString.lowercased())","ok":true,"error":null,"data":{"draft":"Hi"}}"#.utf8), id: id)
        T.equal(ok?.ok, true, "ok")
        T.equal(ok?.data["draft"]?.string, "Hi", "data")
        let bad = MailHelperParse.result(Data(#"{"version":1,"id":"\#(id.uuidString)","ok":false,"error":"Claude is off for this account"}"#.utf8), id: id)
        T.equal(bad?.error, "Claude is off for this account", "an error (any case of the id)")
        let other = MailHelperParse.result(Data(#"{"version":1,"id":"someone-else","ok":true}"#.utf8), id: id)
        T.equal(other?.ok, false, "an answer for another id is refused")
        T.equal(MailHelperParse.result(nil, id: id), nil, "no answer yet")
    }

    // MARK: Commands

    static func commands() {
        T.section("mail helper: command files")
        let c = MailHelperCommand.setPaused(true, account: home)
        guard let data = c.encoded(), let j = MailHelperJSON.parse(data) else { T.check(false, "encodes"); return }
        T.equal(j["version"]?.int, 1, "version 1")
        T.equal(j["id"]?.string, c.id.uuidString.lowercased(), "id")
        T.equal(j["kind"]?.string, "account", "kind")
        T.equal(j["args"]?["account"]?.string, home.uuidString, "account = the calendar's account UUID")
        T.equal(j["args"]?["paused"]?.bool, true, "paused")
        T.check(String(decoding: data, as: UTF8.self).hasPrefix(#"{"args":"#), "sorted keys, compact")
        T.equal(MailHelperCommand.setPolicy(.localClaude, account: orb).args["ai_policy"], .string("local+claude"), "policy")
        T.equal(MailHelperCommand.setCredential(nil, account: orb)?.args["claude_credential"], .null, "no credential = null")
        T.equal(MailHelperCommand.setCredential("bad name", account: orb), nil, "a credential name outside the rule")
        T.equal(MailHelperCommand.setKind("boss", account: orb), nil, "kind: personal or work only")
        T.equal(MailHelperCommand.review(account: "x", thread: "ABC", category: .people), nil, "thread ids are Gmail's hex")
        T.equal(MailHelperCommand.review(account: "x", thread: "abc", category: .review), nil, "Review is not a choice")
        T.equal(MailHelperCommand.review(account: "x", thread: "abc", category: .money)?.args["scope"], .string("sender"), "scope: sender by default")
        T.equal(MailHelperCommand.review(account: "x", thread: "abc", category: .money, onlyThisThread: true)?.args["scope"], .string("thread"), "…or this thread")
        T.equal(MailHelperCommand.backfill(.apply, run: "bf-0b1a2c3d4e5f")?.kind, "backfill_apply", "apply")
        T.equal(MailHelperCommand.backfill(.undo, run: "bf-0b1a2c3d4e5f")?.kind, "backfill_undo", "undo all")
        T.equal(MailHelperCommand.backfill(.stop, run: "bf-0b1a2c3d4e5f")?.kind, "backfill_stop", "stop")
        T.equal(MailHelperCommand.backfill(.apply, run: "bf-123"), nil, "a run id outside the contract")
        T.equal(MailHelperCommand.backfillOverride(run: "bf-0b1a2c3d4e5f", sender: "a@b.example", category: .updates)?.args["category"],
                .string("updates"), "Move to…")
        T.equal(MailHelperCommand.undo(since: Date(timeIntervalSince1970: 100.7)).args["since"], .int(100), "undo since (unix seconds)")
        T.equal(MailHelperCommand.undo(batch: "digest:42:all").args["batch"], .string("digest:42:all"), "undo a batch")
        T.equal(MailHelperCommand.undo(actions: [1, 2]).args["action_ids"], .array([.int(1), .int(2)]), "undo actions")
        T.equal(MailHelperCommand.proposal(7, accept: false).args["decision"], .string("reject"), "proposal")
        T.equal(MailHelperCommand.digestRead(42, section: nil).args["section"], nil, "Mark all read has no section")
        T.equal(MailHelperCommand.needsReply().args, [:], "needs_reply, every account")
        T.equal(MailHelperCommand.voiceBuild(account: home, useClaude: false).args["use_claude"], .bool(false), "voice_build")
        T.equal(MailHelperCommand.voicePut(account: home, card: String(repeating: "a", count: 4000)).args["card"]?.string?.count, 3000,
                "a style card is capped at 3,000 characters")
        let draft = MailHelperCommand.draft(account: home, thread: "18f2a0c4d1e5e001", model: .sonnet, effort: "xhigh", instruction: "  ")
        T.equal(draft?.args["model"], .string("claude-sonnet-5-5"), "draft model id")
        T.equal(draft?.args["effort"], .string("xhigh"), "effort")
        T.equal(draft?.args["instruction"], nil, "an empty instruction is left out")
        T.equal(MailHelperCommand.draft(account: home, thread: "18f", model: .local, effort: "low", instruction: String(repeating: "x", count: 1500))?
                    .args["instruction"]?.string?.count, 1000, "instructions are capped at 1,000 characters")
        T.equal(MailHelperCommand.draft(account: home, thread: "m123", model: .local, effort: "low", instruction: ""), nil, "a calendar row id is not a thread id")
        T.equal(draft?.args["provider"], .string("claude"), "the provider goes along (v1.2)")
        let codex = MailDraftModel(provider: "codex", id: "gpt-6.1-sol", title: "GPT-6.1-Sol", efforts: ["low", "ultra"], defaultEffort: "low")
        T.equal(MailHelperCommand.draft(account: home, thread: "18f", model: codex, effort: "max", instruction: "")?.args["effort"],
                .string("low"), "a level the model hasn't falls back to its default")
        T.equal(MailHelperCommand.draft(account: home, thread: "18f", model: MailDraftModel(provider: "codex", id: "Bad Id", title: "x",
                efforts: [], defaultEffort: nil), effort: "low", instruction: ""), nil, "a model id that isn't one is refused")
        T.equal(MailHelperCommand.setCodexCredential("personal", account: home).flatMap { $0.args["codex_credential"] }, .string("personal"),
                "Codex sign-in per account")
        let on = MailHelperCommand.enableClaude("orbital", account: orb)
        T.equal(on?.args["ai_policy"], .string("local+claude"), "Turn on: cloud AI")
        T.equal(on?.args["claude_credential"], .string("orbital"), "…with that credential")

        T.section("mail helper: people lists")
        let people = MailHelperCommand.people(.vip, addresses: ["Ines@OrbitalPickle.example", "ines@orbitalpickle.example", "not an address", " theo@moonbase.example "],
                                              account: home)
        T.equal(people.args["addresses"], .array([.string("ines@orbitalpickle.example"), .string("theo@moonbase.example")]),
                "lowercased, checked, de-duplicated")
        T.equal(MailHelperCommand.people(.vipDomain, addresses: ["moonbase.example", "@lanternhall.example", "x"], account: home).args["addresses"]?.array?.count,
                1, "domains checked (the editor strips a leading @)")
        let many = (0..<5000).map { "person\($0)@a-rather-long-domain-name-for-testing.example" }
        let big = MailHelperCommand.people(.meeting, addresses: many, account: home)
        let count = big.args["addresses"]?.array?.count ?? 0
        T.check(big.encoded() != nil, "a long list still fits in 64 KiB")
        T.check(count > 900 && count <= 2000, "…cut to fit (\(count) addresses), never past 2,000")
        T.equal(MailHelperPeople.split("Theo Quill <theo@moonbase.example>, ines@orbitalpickle.example\n@lanternhall.example"),
                ["theo@moonbase.example", "ines@orbitalpickle.example", "lanternhall.example"], "the editor's text")
    }

    // MARK: Sealing

    /// Opens an envelope the way the server does (X25519 + HKDF-SHA256 + ChaCha20-Poly1305 over the AAD).
    static func open(_ env: [String: MailHelperJSON], purpose: String, account: String) -> Data? {
        guard let priv = Data(base64Encoded: fixturePrivateKey),
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv),
              env["v"] == .int(1), env["purpose"]?.string == purpose, env["account"]?.string == account,
              let epk = env["epk"]?.string.flatMap({ Data(base64Encoded: $0) }),
              let nonce = env["nonce"]?.string.flatMap({ Data(base64Encoded: $0) }),
              let ct = env["ct"]?.string.flatMap({ Data(base64Encoded: $0) }), ct.count > 16,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk),
              let shared = try? key.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("yaya-mail-helper seal v1".utf8),
                                                      outputByteCount: 32)
        guard let box = try? ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ct.dropLast(16), tag: ct.suffix(16)) else { return nil }
        return try? ChaChaPoly.open(box, using: symmetric, authenticating: Data("mh-seal-v1|\(purpose)|\(account)".utf8))
    }

    static func sealing() {
        T.section("mail helper: sealing a sign-in (CONTRACT §2)")
        let key = Data(base64Encoded: MailHelperFixtures.sealKey)!
        T.equal(MailHelperSeal.fingerprint(key), MailHelperFixtures.sealFingerprint, "the fingerprint the helper reports (computed the server's way)")
        let signIn = MailHelperSignIn(refreshToken: "1/refresh-fixture-token-not-real", clientId: "123456-abcdefghijkl.apps.example",
                                      clientSecret: "fixture-secret", email: "avery@home.example")
        T.equal("\(signIn)", "MailHelperSignIn(redacted)", "never printed")
        T.equal(String(reflecting: signIn), "MailHelperSignIn(redacted)", "…not even in a debug print")
        let state = MailHelperFixtures.parsedState()!
        guard let env = try? MailHelperSeal.gmail(signIn, account: home, state: state) else { T.check(false, "seals"); return }
        T.equal(env["purpose"], .string("gmail"), "purpose gmail")
        T.equal(env["account"], .string(home.uuidString), "account = the calendar's account id")
        T.equal(Data(base64Encoded: env["epk"]?.string ?? "")?.count, 32, "a fresh X25519 key")
        T.equal(Data(base64Encoded: env["nonce"]?.string ?? "")?.count, 12, "a 12-byte nonce")
        let opened = open(env, purpose: "gmail", account: home.uuidString).flatMap { MailHelperJSON.parse($0) }
        T.equal(opened?["refresh_token"]?.string, signIn.refreshToken, "the server opens it: refresh token")
        T.equal(opened?["client_id"]?.string, signIn.clientId, "client id")
        T.equal(opened?["client_secret"]?.string, signIn.clientSecret, "client secret")
        T.equal(opened?["email"]?.string, signIn.email, "email")
        T.equal(open(env, purpose: "gmail", account: orb.uuidString), nil, "sealed for one account only (the AAD)")
        T.equal(open(env, purpose: "claude", account: home.uuidString), nil, "…and one purpose")
        let again = try? MailHelperSeal.gmail(signIn, account: home, state: state)
        T.check(again?["epk"] != env["epk"] && again?["ct"] != env["ct"], "a fresh key and nonce every time")
        var wrong = state
        wrong.sealFingerprint = "AAAA-BBBB-CCCC"
        T.check((try? MailHelperSeal.gmail(signIn, account: home, state: wrong)) == nil, "a fingerprint that doesn't match its key: refused")
        var none = state
        none.sealKey = nil
        T.check((try? MailHelperSeal.gmail(signIn, account: home, state: none)) == nil, "no key: refused")
        let text = String(decoding: MailHelperJSON.object(env).encoded() ?? Data(), as: UTF8.self)
        T.check(!text.contains("refresh-fixture") && !text.contains("fixture-secret"), "nothing readable in the envelope")
    }

    // MARK: Inbox

    static func thread(_ r: String, _ account: UUID, labels: [String], at: Double) -> MailThread {
        MailThread(r: r, accountId: account, sender: "S", senderEmail: "s@x.example", subject: r, snippet: "",
                   at: Date(timeIntervalSince1970: at), unread: false, starred: false, messageCount: 1, labels: labels)
    }

    static func inbox() {
        T.section("mail helper: Priority first, chips")
        let labels = MailHelperInboxLabels(MailHelperFixtures.parsedState())
        T.check(labels != nil, "labels from state.json")
        let list = [thread("a", home, labels: ["INBOX"], at: 5), thread("b", home, labels: ["INBOX", "Label_101"], at: 4),
                    thread("c", orb, labels: ["Label_101"], at: 3), thread("d", orb, labels: ["Label_201"], at: 2),
                    thread("e", home, labels: ["Label_102"], at: 1), thread("f", home, labels: ["Label_101", "Label_102"], at: 0)]
        T.equal(MailHelperInbox.order(list, labels).map(\.r), ["b", "d", "f", "a", "c", "e"], "Priority first, both groups in order")
        T.equal(MailHelperInbox.order(list, nil).map(\.r), list.map(\.r), "no labels: the inbox as it was")
        T.equal(labels?.chips(list[1]), [.priority], "⭐ chip")
        T.equal(labels?.chips(list[2]), [], "another account's label id means nothing")
        T.equal(labels?.chips(list[4]), [.review], "Review chip")
        T.equal(labels?.chips(list[5]), [.priority, .review], "both")
        var empty = MailHelperFixtures.parsedState()!
        empty.labels = [:]
        T.check(MailHelperInboxLabels(empty) == nil, "a report without labels changes nothing")
        T.check(MailHelperInboxLabels(nil) == nil, "no report changes nothing")
    }

    static func inboxModel() {
        T.section("mail helper: the Inbox section with and without the helper")
        var fixtures = FixtureMail.threads()
        for i in fixtures.indices where fixtures[i].thread.r == "th-mom" { fixtures[i].thread.labels = ["Label_101"] }
        for i in fixtures.indices where fixtures[i].thread.r == "th-wiki" { fixtures[i].thread.labels = ["Label_202"] }
        let store = FakeMailStore(threads: fixtures)
        let labels = MailHelperInboxLabels(MailHelperFixtures.parsedState())
        let plain = InboxSectionModel(store: { store }, directory: { FixtureAccounts.directory() }, clock: { now },
                                      local: MemoryMailLocalStore(), mailHelperLabels: { nil })
        plain.load()
        let with = InboxSectionModel(store: { store }, directory: { FixtureAccounts.directory() }, clock: { now },
                                     local: MemoryMailLocalStore(), mailHelperLabels: { labels })
        with.load()
        T.equal(with.threads.first?.r, "th-mom", "the Priority thread comes first")
        T.equal(with.threads.dropFirst().map(\.r), plain.threads.filter { $0.r != "th-mom" }.map(\.r), "the rest keep their order")
        T.equal(with.threads.first.map(with.chips), [.priority], "its ⭐ chip")
        T.equal(with.threads.first { $0.r == "th-wiki" }.map(with.chips), [.review], "Review chip")
        T.equal(plain.threads.first.map(plain.chips), [], "without the helper: no chips")
        T.check(plain.helperLabels == nil, "…and no labels")
    }

    // MARK: Meeting people

    static func meetings() {
        T.section("mail helper: meeting people")
        func person(_ email: String, me: Bool = false) -> CalendarEvent.Attendee {
            CalendarEvent.Attendee(name: nil, email: email, response: .accepted, isSelf: me, isOrganizer: false)
        }
        func event(_ r: String, _ accounts: [UUID], days: Double, _ people: [CalendarEvent.Attendee]) -> CalendarEvent {
            CalendarEvent(r: r, accountIds: accounts, calendarName: "Work", title: r, start: now.addingTimeInterval(days * 86400),
                          end: now.addingTimeInterval(days * 86400 + 1800), allDay: false, location: nil, joinURL: nil, webURL: nil,
                          notes: nil, organizer: person("Org@Moonbase.example"), attendees: people, myResponse: .accepted, clashes: false)
        }
        let events = [
            event("far", [orb], days: -10, [person("old@x.example"), person("avery@orbitalpickle.example", me: true)]),
            event("near", [orb], days: 1, [person("Ines@OrbitalPickle.example"), person("room-4" + "@" + MailHelperTests.resourceDomain), person("bad")]),
            event("past", [orb], days: -70, [person("ancient@x.example")]),
            event("later", [orb], days: 40, [person("future@x.example")]),
            event("other", [home], days: 0.5, [person("family@x.example")]),
            event("merged", [home, orb], days: 2, [person("ines@orbitalpickle.example"), person("theo@moonbase.example")]),
        ]
        let own: Set<String> = ["avery@orbitalpickle.example", "avery@home.example"]
        T.equal(MailHelperMeetings.addresses(events, account: orb, own: own, now: now),
                ["org@moonbase.example", "ines@orbitalpickle.example", "theo@moonbase.example", "old@x.example"],
                "the account's meetings, nearest first, distinct, lowercased; not you, rooms, bad addresses or outside 60/30 days")
        let crowd = (0..<2500).map { person("p\($0)@x.example") }
        T.equal(MailHelperMeetings.addresses([event("big", [orb], days: 1, crowd)], account: orb, own: own, now: now).count, 2000, "at most 2,000")
        let cal = WidgetCalendar.current
        T.check(MailHelperMeetings.due(last: nil, now: now, calendar: cal), "never sent: due")
        T.check(!MailHelperMeetings.due(last: now.addingTimeInterval(-3600), now: now, calendar: cal), "sent an hour ago today: not due")
        T.check(MailHelperMeetings.due(last: now.addingTimeInterval(-86400), now: now, calendar: cal), "sent yesterday: due")
    }

    // MARK: Session

    static func session() {
        T.section("mail helper: commands, answers, time-outs")
        let f = Fake()
        let s = session(f, publishesInbox: true)
        var got: [MailHelperResult] = []
        T.check(s.send(.refresh()) { got.append($0) }, "sent")
        T.equal(f.written.count, 1, "the command file is written")
        T.equal(f.opened.first?.absoluteString, MailHelperLinks.command(f.written[0].0)?.absoluteString, "then its link is opened")
        T.equal(s.waiting.count, 1, "waiting for the answer")
        s.collect()
        T.equal(got.count, 0, "no answer yet")
        f.answer(ok: true)
        f.later.removeFirst()()  // the 1.5 s poll
        T.equal(got.first?.ok, true, "the answer arrives (and is read once)")
        T.equal(s.waiting.count, 0, "nothing waiting")

        s.send(.refresh()) { got.append($0) }
        f.clock = now.addingTimeInterval(MailHelperSession.answerTimeout + 1)
        s.collect()
        T.equal(got.last?.error, "No answer from Yaya\u{2019}s Mail Helper. Is it running?", "no answer in time")
        f.clock = now

        let id = (s.send(.refresh()) { got.append($0) }, f.written.last!.0).1
        let before = got.count
        s.stopWaiting(id)
        f.answer()
        s.collect()
        T.equal(got.count, before, "stopped waiting: the answer is dropped")

        s.send(.refresh()) { got.append($0) }
        s.linkFailed(MailHelperLinks.command(f.written.last!.0)!)
        T.equal(got.last?.ok, false, "the link didn't open: the command ends at once")

        f.writeOK = false
        T.check(!s.send(.refresh()) { got.append($0) }, "a file that can't be written")
        T.equal(got.last?.ok, false, "…fails at once")
        f.writeOK = true
        f.installed = false
        s.refresh()
        T.check(!s.send(.refresh()) { got.append($0) }, "not installed: nothing is written")
        T.equal(got.last?.error, MailHelperSession.notInstalled, "…and says so")
        T.equal(s.state, nil, "no report while it isn't installed")
        T.equal(MailHelperInbox.current.get(), nil, "the inbox goes back to its own order")
        f.installed = true
        s.refresh()
        T.check(MailHelperInbox.current.get() != nil, "installed again: Priority first again")
        T.equal(s.statusLine.tone, .good, "status: paired and reachable")
        var away = MailHelperFixtures.parsedState()!
        away.lab.reachable = false
        f.state = .ready(away)
        s.refresh()
        T.equal(s.statusLine.tone, .bad, "status: out of reach")
        f.state = .newer
        s.refresh()
        T.equal(s.statusLine.tone, .warn, "status: a newer report")
        MailHelperInbox.current.set(nil)
    }

    // MARK: Hand-over

    static func handover() async {
        T.section("mail helper: hand-over card")
        T.equal(MailHelperHandover.defaultKind(email: "avery@home.example", personalDomains: ["home.example"]), "personal", "a consumer address: personal")
        T.equal(MailHelperHandover.defaultKind(email: "avery@orbitalpickle.example", personalDomains: ["home.example"]), "work", "any other: work")
        let f = Fake()
        var asked: [UUID] = []
        let live = MailHelperModel.Live(credentials: { id in
            asked.append(id)
            return MailHelperSignIn(refreshToken: "1/refresh-fixture-token-not-real", clientId: "123456-abcdefghijkl.apps.example",
                                    clientSecret: "fixture-secret", email: "avery@moonfield-family.example")
        }, personalDomains: ["home.example"])
        let m = model(f, live: live)
        T.equal(m.cards.first { $0.id == fam }?.handedOver, false, "FAM isn't handed over")
        T.equal(m.cards.first { $0.id == home }?.handedOver, true, "Personal is")
        m.beginHandover(fam)
        T.equal(m.handover?.fingerprint, MailHelperFixtures.sealFingerprint, "the card shows the server's fingerprint")
        T.equal(m.handover?.email, Cast.fam.email, "…and names the account")
        T.equal(m.handover?.kind, "work", "FAM defaults to work")
        T.equal(asked, [], "nothing is read from the Keychain before approval")
        await m.approveHandover()
        T.equal(f.written.count, 0, "Return within 0.3 s of the card does nothing")
        T.check(m.handover != nil, "…and the card stays")
        f.clock = now.addingTimeInterval(0.4)
        m.setHandoverKind("personal")
        f.autoAnswer = MailHelperResult(id: UUID(), ok: true, error: nil, data: .object(["state": .string("new")]))
        await m.approveHandover()
        f.autoAnswer = nil
        T.equal(asked, [fam], "approved: the sign-in is read once")
        T.equal(f.last?["kind"]?.string, "handover", "handover command")
        T.equal(f.last?["args"]?["account"]?.string, fam.uuidString, "for that account")
        T.equal(f.last?["args"]?["kind"]?.string, "personal", "the kind picked on the card")
        let env = f.last?["args"]?["envelope"]?.object ?? [:]
        let opened = open(env, purpose: "gmail", account: fam.uuidString).flatMap { MailHelperJSON.parse($0) }
        T.equal(opened?["refresh_token"]?.string, "1/refresh-fixture-token-not-real", "only the server's key opens the sign-in")
        let raw = String(decoding: f.written.last?.1 ?? Data(), as: UTF8.self)
        T.check(!raw.contains("refresh-fixture") && !raw.contains("fixture-secret"), "the command file holds no readable token or secret")
        T.equal(m.handover, nil, "the card closes")
        T.check(m.toasts.toast?.text.hasPrefix("Handed over") == true, "and says so")

        let count = f.written.count
        m.live.credentials = { _ in throw MailHelperSignInError.notConnected }
        m.beginHandover(fam)
        f.clock = f.clock.addingTimeInterval(1)
        await m.approveHandover()
        T.equal(m.handoverProblem, MailHelperModel.words(.notConnected), "no sign-in on this Mac: said on the card")
        T.equal(f.written.count, count, "…and nothing is written")
        m.cancelHandover()
        T.equal(m.handover, nil, "Cancel")

        m.live = live
        m.beginHandover(fam)
        f.clock = f.clock.addingTimeInterval(1)
        f.autoAnswer = MailHelperResult(id: UUID(), ok: false, error: "the sealed sign-in could not be opened", data: .null)
        await m.approveHandover()
        f.autoAnswer = nil
        T.equal(m.handoverProblem, "the sealed sign-in could not be opened", "the server's refusal, on the card")
        T.check(m.handover != nil, "the card stays for another try")
        m.cancelHandover()

        var unpaired = MailHelperFixtures.parsedState()!
        unpaired.sealKey = nil
        f.state = .ready(unpaired)
        m.session.refresh()
        m.beginHandover(fam)
        T.equal(m.handover, nil, "not paired: no card")
        var forged = MailHelperFixtures.parsedState()!
        forged.sealFingerprint = "AAAA-BBBB-CCCC"
        f.state = .ready(forged)
        m.session.refresh()
        m.beginHandover(fam)
        T.equal(m.handover, nil, "a fingerprint that doesn't match the key: no card")
        T.equal(MailHelperInbox.current.get(), nil, "a page model's own session never touches the inbox")
    }

    // MARK: Backlog, Review, suggestions, activity

    static func backlogReviewActivity() {
        T.section("mail helper: backlog, Review, suggestions, activity")
        let f = Fake()
        let m = model(f)
        m.backfillApply("bf-0b1a2c3d4e5f")
        T.equal(f.last?["kind"]?.string, "backfill_apply", "Apply")
        T.check(m.isBusy("apply:bf-0b1a2c3d4e5f"), "busy until the answer")
        f.answer()
        m.session.collect()
        T.check(!m.isBusy("apply:bf-0b1a2c3d4e5f"), "answered")
        m.askUndoAll("bf-0b1a2c3d4e5f", tag: "ORB")
        T.equal(f.written.count, 1, "Undo all asks first")
        m.confirmed()
        T.equal(f.last?["kind"]?.string, "backfill_undo", "…then undoes")
        m.move(run: "bf-0b1a2c3d4e5f", sender: "digest@neuralpost.example", to: .updates)
        T.equal(f.last?["kind"]?.string, "backfill_override", "Move to…")
        T.equal(f.last?["args"]?["sender"]?.string, "digest@neuralpost.example", "…that sender")
        let r = m.state!.review[0]
        m.review(r, as: .people)
        T.equal(f.last?["args"]?["scope"]?.string, "sender", "Review: the sender follows")
        T.equal(f.last?["args"]?["thread_id"]?.string, r.threadId, "…that thread")
        m.decide(m.state!.proposals[0], accept: true)
        T.equal(f.last?["args"]?["decision"]?.string, "accept", "a suggestion accepted")
        T.equal(MailHelperText.proposal(m.state!.proposals[1]).reject, "Merge back", "a new label: Keep or Merge back")
        m.undo(m.state!.activity[0])
        T.equal(f.last?["args"]?["action_ids"], .array([.int(5121)]), "one action undone")
        m.askUndoToday()
        m.confirmed()
        T.equal(f.last?["args"]?["since"]?.int, Int(WidgetCalendar.current.startOfDay(for: now).timeIntervalSince1970), "Undo today: since midnight")
        m.setPolicy(.off, cmt)
        T.equal(f.last?["args"]?["ai_policy"]?.string, "off", "AI policy")
        m.setPaused(false, orb)
        T.equal(f.last?["args"]?["paused"]?.bool, false, "Sorting again")
        m.askForget(orb)
        m.confirm = nil
        T.equal(f.last?["kind"]?.string, "account", "Take back asks first; Cancel sends nothing")
    }

    static func vips() {
        T.section("mail helper: VIPs")
        let f = Fake()
        let bag = MemoryBag()
        let m = model(f, bag: bag)
        m.editVIPs(home)
        m.vipPeople = "Theo Quill <Theo@Moonbase.example>\nnot-an-address"
        m.vipDomains = "lanternhall.example"
        m.saveVIPs()
        T.equal(f.last?["args"]?["kind"]?.string, "vip", "people first")
        T.equal(f.last?["args"]?["addresses"], .array([.string("theo@moonbase.example")]), "checked addresses")
        T.equal(m.vips(home).people, [], "kept only once the helper took them")
        f.answer()
        m.session.collect()
        T.equal(m.vips(home).people, ["theo@moonbase.example"], "remembered")
        T.equal(f.last?["args"]?["kind"]?.string, "vip_domain", "then domains")
        f.answer()
        m.session.collect()
        T.equal(m.vips(home).domains, ["lanternhall.example"], "remembered")
    }

    static func needsReplyAndVoice() {
        T.section("mail helper: Needs reply, your voice")
        let f = Fake()
        var replied: [(UUID, String)] = []
        let m = model(f, live: MailHelperModel.Live(reply: { replied.append(($0, $1)) }))
        m.loadNeedsReply()
        T.equal(m.needsReply, .loading, "asking")
        f.answer(data: MailHelperJSON.parse(Data(MailHelperFixtures.needsReply.utf8))!)
        m.session.collect()
        guard case .ready(let rows) = m.needsReply else { T.check(false, "the list came"); return }
        T.equal(rows.count, 3, "three threads")
        T.equal(rows[0].priority, true, "priority")
        m.reply(rows[1])
        T.equal(replied.first?.0, orb, "Reply opens the composer for that account")
        T.equal(replied.first?.1, rows[1].threadId, "…and thread")

        T.equal(m.defaultUseClaude(home), true, "Claude for the style card: on for personal")
        T.equal(m.defaultUseClaude(orb), false, "…off for work")
        m.loadVoice(home)
        T.equal(f.last?["kind"]?.string, "voice_get", "voice_get")
        f.answer(data: MailHelperJSON.parse(Data(MailHelperFixtures.voice.utf8))!)
        m.session.collect()
        T.equal(m.voice(home)?.samples, 46, "samples")
        T.check(m.voice(home)?.card?.hasPrefix("English, to friends") == true, "the card")
        m.editVoice(home)
        m.setVoiceDraft("Short and warm.", home)
        m.saveVoice(home)
        T.equal(f.last?["kind"]?.string, "voice_put", "voice_put")
        T.equal(f.last?["args"]?["card"]?.string, "Short and warm.", "the edited card")
        f.answer()
        m.session.collect()
        T.equal(m.voice(home)?.card, "Short and warm.", "saved")
        T.equal(m.voice(home)?.draft, nil, "editing ends")
        m.buildVoice(orb)
        T.equal(f.last?["args"]?["use_claude"]?.bool, false, "Build for a work account: no Claude unless switched on")
        m.setVoiceUsesClaude(true, orb)
        m.buildVoice(orb)
        T.equal(f.last?["args"]?["use_claude"]?.bool, true, "…switched on")
    }

    // MARK: Digest

    static func digestReadIsDone() {
        T.section("mail helper: the digest's read = done")
        let f = Fake()
        let m = model(f)
        T.equal(m.mark("security"), .marked, "a section the helper already marked")
        m.sectionEnd("newsletters", visible: true)
        T.equal(f.written.count, 0, "an end on screen before the page moved: not read yet")
        m.digestDidScroll()
        T.equal(f.last?["kind"]?.string, "digest_read", "the page moved: that section is read")
        T.equal(f.last?["args"]?["section"]?.string, "newsletters", "…that section only")
        T.equal(f.last?["args"]?["id"]?.int, 42, "…of this digest")
        T.equal(m.mark("newsletters"), .sending, "Marking read…")
        f.answer(data: .object(["marked": .int(3)]))
        m.session.collect()
        T.equal(m.mark("newsletters"), .marked, "Marked read · Undo")
        m.sectionEnd("newsletters", visible: false)
        m.sectionEnd("newsletters", visible: true)
        T.equal(f.written.count, 1, "never twice")
        m.sectionEnd("security", visible: true)
        T.equal(f.written.count, 1, "a section the helper marked isn't sent again")
        m.undoRead("newsletters")
        T.equal(f.last?["kind"]?.string, "undo", "Undo")
        T.equal(f.last?["args"]?["batch"]?.string, "digest:42:newsletters", "…the helper's batch for that read")
        f.answer()
        m.session.collect()
        T.equal(m.mark("newsletters"), .undone, "Unread again")
        m.sectionEnd("newsletters", visible: false)
        m.sectionEnd("newsletters", visible: true)
        T.equal(f.written.count, 2, "an undone section stays unread while this window is open")
        m.markRead("updates")
        T.equal(f.last?["args"]?["section"]?.string, "updates", "Mark section read")
        m.markRead(nil)
        T.equal(f.last?["args"]?["section"], nil, "Mark all read")
        f.answer(ok: false, error: "Gmail said no")
        m.session.collect()
        T.equal(m.marks["all"], .failed("Gmail said no"), "a failure says why")
        var opened: [(UUID, String)] = []
        m.live.openThread = { opened.append(($0, $1)) }
        m.open(m.digest!.sections[1].items[0].threads[1])
        T.equal(opened.first?.0, home, "an item opens in the reader: account")
        T.equal(opened.first?.1, "18f2a0c4d1e5d005", "…and the Gmail thread")
    }

    // MARK: Draft with AI

    static func voiceNotes() {
        T.section("mail helper: the Draft pop-over's voice note (D-052)")
        let f = Fake()
        let s = session(f)
        let rec = MailVoiceScriptedRecorder(permission: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yc-voice-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var published: [String] = [], removed: [URL] = [], ticks = 0, privacy = 0
        let env = MailVoiceNoteModel.Environment(
            newClip: { dir.appendingPathComponent(UUID().uuidString.lowercased() + ".wav") },
            publish: { _ in let n = MailHelperFiles.clipName(UUID()); published.append(n); return n },
            remove: { removed.append($0); try? FileManager.default.removeItem(at: $0) },
            openPrivacy: { privacy += 1 },
            ticker: { _ in ticks += 1; return AnyCancellable {} })
        var texts: [String] = []
        let v = MailVoiceNoteModel(session: s, recorder: rec, env: env, onText: { texts.append($0) })
        T.equal(v.phase, .idle, "idle until asked")
        v.record()
        T.equal(rec.calls.prefix(2).map { $0 }, ["ask", "start"], "asks for the microphone once, then records")
        T.equal(v.phase, .recording, "recording")
        T.equal(ticks, 1, "the clock and bars run while recording")
        rec.recorded = 3.4; rec.nextLevel = 0.8
        v.tickNow()
        T.equal(MailVoiceNoteModel.clock(v.elapsed), "0:03", "the time")
        T.equal(v.levels.last, 0.8, "the newest bar")
        T.equal(v.levels.count, MailVoiceNoteModel.barCount, "a fixed number of bars")
        v.pause()
        T.equal(v.phase, .paused, "paused")
        v.resume()
        T.equal(v.phase, .recording, "resumed")
        rec.recorded = 7.2
        v.stop()
        T.equal(v.phase, .stopped, "stopped with a clip")
        T.equal(MailVoiceNoteModel.clock(v.elapsed), "0:07", "its length")
        v.togglePlay()
        T.check(v.playing && rec.playingURL != nil, "listen back")
        rec.endPlayback()
        T.check(!v.playing, "playback ends on its own")
        v.send()
        T.equal(v.phase, .sending, "sending")
        T.equal(f.last?["kind"]?.string, "transcribe", "the transcribe command")
        T.equal(f.last?["args"]?["clip"]?.string, published.last, "with the share copy's name")
        f.answer(ok: false, error: "transcription isn't set up on this Mac (whisper-cli is missing)")
        s.collect()
        T.equal(v.phase, .failed("transcription isn't set up on this Mac (whisper-cli is missing)"), "the helper's error")
        T.check(v.isFailedWithClip && v.canSend, "the recording is kept, so it can be sent again")
        v.send()
        f.answer(data: .object(["text": .string("  It\u{2019}s fine, I\u{2019}ll wait for your call.\u{0007} ")]))
        s.collect()
        T.equal(texts, ["It\u{2019}s fine, I\u{2019}ll wait for your call."], "the text, cleaned, goes on")
        T.equal(v.phase, .idle, "and the bar is ready again")
        T.check(removed.count == 1 && !FileManager.default.fileExists(atPath: removed[0].path), "the private recording is deleted")

        // A short tap is no voice note; discard mid-recording; refused microphone; the five-minute stop.
        v.record(); rec.recorded = 0.2; v.stop()
        T.equal(v.phase, .idle, "under half a second: nothing kept")
        v.record(); v.discard()
        T.equal(v.phase, .idle, "discard while recording")
        T.check(rec.calls.last == "stop", "…stops the microphone")
        v.record(); rec.recorded = MailVoiceNoteModel.maxDuration; v.tickNow()
        T.equal(v.phase, .stopped, "stops itself at five minutes")
        v.discard()
        v.record(); rec.recorded = 4; v.stop(); v.send()
        v.discard()
        f.answer(data: .object(["text": .string("late")]))
        s.collect()
        T.equal(texts.count, 1, "an answer after Discard is dropped")
        let denied = MailVoiceNoteModel(session: s, recorder: MailVoiceScriptedRecorder(permission: false), env: env)
        denied.record()
        T.equal(denied.phase, .denied, "refused in System Settings: said, with a way there")
        denied.openPrivacy()
        T.equal(privacy, 1, "Open Settings")
        let stuck = MailVoiceScriptedRecorder(permission: true); stuck.startOK = false
        let busy = MailVoiceNoteModel(session: s, recorder: stuck, env: env)
        busy.record()
        if case .failed = busy.phase {} else { T.check(false, "a microphone that won't start says so") }

        // In the pop-over: the transcript joins "What should it say?" and the draft starts.
        MailHelperDraftModel.makeVoice = { sess in MailVoiceNoteModel(session: sess, recorder: MailVoiceScriptedRecorder(), env: env) }
        let d = MailHelperDraftModel(account: home, threadR: "mRowId", session: s, threadId: { _ in "18f2a0c4d1e5e001" }, bag: MemoryBag())
        d.instruction = "Keep it short."
        d.voice?.onText("Say yes to Wednesday")
        T.equal(d.instruction, "Keep it short.\nSay yes to Wednesday", "added to what was typed")
        T.check(d.isWorking && f.last?["kind"]?.string == "draft", "and the draft starts")
        MailHelperDraftModel.makeVoice = nil
        T.check(MailHelperFiles.isClip(MailHelperFiles.clipName(UUID())) && !MailHelperFiles.isClip("voice-../x.wav")
                && !MailHelperFiles.isClip("voice-0A1B2C3D-0000-4000-8000-00000000ABCD.wav"), "clip names: lowercase uuid only")
        T.equal(MailHelperCommand.transcribe(clip: "x.wav"), nil, "transcribe takes only clip names")
        try? FileManager.default.removeItem(at: dir)
    }

    static func drafts() {
        T.section("mail helper: Draft with AI")
        let f = Fake()
        let s = session(f)
        let bag = MemoryBag()
        var inserted: [String] = []
        let d = MailHelperDraftModel(account: home, threadR: "mRowId", session: s, threadId: { $0 == "mRowId" ? "18f2a0c4d1e5e001" : nil },
                                     bag: bag, clock: { f.clock }, insert: { inserted.append($0) })
        T.equal(d.model, .local, "Local by default")
        T.equal(d.effort, "low", "Low by default")
        T.equal(d.models.map(\.id), ["local", "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1", "gpt-6.1-sol"],
                "the helper's live list, a bad id dropped")
        T.equal(d.models.last?.efforts.last, "ultra", "each model with its own thinking levels")
        T.equal(d.note, nil, "Personal is handed over and Claude is on")
        d.model = .opus
        d.effort = "high"
        d.instruction = "Say yes, ask about parking"
        d.draft()
        T.equal(f.last?["kind"]?.string, "draft", "the draft command")
        T.equal(f.last?["args"]?["thread_id"]?.string, "18f2a0c4d1e5e001", "the Gmail thread behind the row")
        T.equal(f.last?["args"]?["account"]?.string, home.uuidString, "the composer's account")
        T.equal(f.last?["args"]?["model"]?.string, "claude-opus-5-5", "model")
        T.equal(f.last?["args"]?["instruction"]?.string, "Say yes, ask about parking", "what it should say")
        T.check(d.isWorking, "working…")
        f.clock = now.addingTimeInterval(75)
        T.equal(d.elapsed(f.clock), "1 min 15 s", "how long so far")
        f.answer(data: .object(["draft": .string("Hey Juniper,\n\nYes please!\u{0007}")]))
        s.collect()
        T.equal(inserted, ["Hey Juniper,\n\nYes please!"], "inserted as plain text")
        T.equal(d.phase, .idle, "done")
        T.equal(d.open, false, "the pop-over closes")
        let again = MailHelperDraftModel(account: home, threadR: "mRowId", session: s, threadId: { _ in "abc" }, bag: bag)
        T.equal(again.model, .opus, "the choice is remembered per account")
        T.equal(again.effort, "high", "…thinking too")
        T.equal(MailHelperDraftModel(account: orb, threadR: "x", session: s, threadId: { _ in "abc" }, bag: bag).model, .local, "another account keeps its own")

        d.draft()
        f.answer(ok: false, error: "Claude is off for this account")
        s.collect()
        T.equal(d.phase, .failed("Claude is off for this account"), "the helper's error, inline")
        d.model = .local
        T.equal(d.phase, .idle, "picking another model clears the old error")
        T.equal(d.model.efforts, [], "Local has no thinking levels")
        d.model = .opus
        d.effort = "high"
        d.draft()
        f.answer(data: .object(["draft": .string("Hi,\n\nYes.\n\nAvery"), "provider": .string("codex"), "model": .string("gpt-6.1-sol"),
                                "fallback": .string("Claude: claude failed: rate_limit 429")]))
        s.collect()
        T.equal(d.lastNote, "Written by Codex (GPT-6.1-Sol). Claude: claude failed: rate_limit 429", "who wrote it, when Codex stood in")
        T.equal(d.open, true, "…and the pop-over stays to say so")
        let insertedSoFar = inserted.count
        d.draft()
        d.cancel()
        T.equal(d.phase, .idle, "Cancel stops waiting")
        f.answer(data: .object(["draft": .string("late")]))
        s.collect()
        T.equal(inserted.count, insertedSoFar, "a late answer is dropped")
        let orbDraft = MailHelperDraftModel(account: orb, threadR: "x", session: s, threadId: { _ in "abc" }, bag: MemoryBag())
        orbDraft.model = .haiku
        T.check(orbDraft.note?.hasPrefix("Claude is off for this account") == true, "Claude off for ORB: said before asking")
        T.equal(orbDraft.enableCredential, "orbital", "a work account is offered its own credential, never \"personal\"")
        orbDraft.enableClaude()
        T.equal(f.last?["kind"]?.string, "account", "Turn on Claude: one account command")
        T.equal(f.last?["args"]?["claude_credential"]?.string, "orbital", "…with the work credential")
        let homeDraft = MailHelperDraftModel(account: home, threadR: "x", session: s, threadId: { _ in "abc" }, bag: MemoryBag())
        homeDraft.model = .haiku
        T.equal(homeDraft.enableCredential, nil, "nothing to turn on where Claude is ready")
        let famDraft = MailHelperDraftModel(account: fam, threadR: "x", session: s, threadId: { _ in "abc" }, bag: MemoryBag())
        T.check(famDraft.note?.contains("isn\u{2019}t handed over") == true, "FAM isn't handed over: said")
        let lost = MailHelperDraftModel(account: home, threadR: "gone", session: s, threadId: { _ in nil }, bag: MemoryBag())
        let before = f.written.count
        lost.draft()
        T.equal(f.written.count, before, "no Gmail thread: nothing is sent")
        if case .failed = lost.phase {} else { T.check(false, "…and it says why") }

        let request = ComposerRequest.reply(thread("mRowId", home, labels: [], at: 1), nil)
        let composer = ComposerModel(request: request, accounts: FixtureAccounts.directory().accounts, safeSend: false,
                                     local: MemoryMailLocalStore(), format: .plain)
        T.check(MailHelperDraftModel.make(for: request, composer: composer, session: s) != nil, "a reply gets the button")
        T.check(MailHelperDraftModel.make(for: .new(from: home), composer: composer, session: s) == nil, "new mail doesn't")
        f.installed = false
        s.refresh()
        T.check(MailHelperDraftModel.make(for: request, composer: composer, session: s) == nil, "nor any composer without the helper")
    }

    static func composerInsert() {
        T.section("mail helper: a draft lands in the composer")
        let request = ComposerRequest.reply(thread("mRowId", home, labels: [], at: 1), nil)
        let plain = ComposerModel(request: request, accounts: FixtureAccounts.directory().accounts, safeSend: false,
                                  local: MemoryMailLocalStore(), format: .plain)
        let opening = plain.body
        T.check(!plain.hasOwnText, "nothing written yet")
        plain.insertDraft("Hey,\nYes.")
        T.equal(plain.body, "Hey,\nYes." + opening, "the body setter: the draft, then the blank line and the rest as it was")
        T.check(plain.hasOwnText, "written now")
        var atCursor: [String] = []
        plain.insertAtCursor = { atCursor.append($0); return true }
        plain.insertDraft("More.")
        T.equal(atCursor, ["More."], "text already there: at the cursor")
        plain.insertAtCursor = nil
        let before = plain.body
        plain.insertDraft("Fallback.")
        T.equal(plain.body, "Fallback.\n\n" + before, "no text view: on top, a blank line after it")
        let rich = ComposerModel(request: request, accounts: FixtureAccounts.directory().accounts, safeSend: false,
                                 local: MemoryMailLocalStore(), format: .rich)
        T.check(!rich.hasOwnText, "rich: nothing written yet")
        rich.insertDraft("Hello there.")
        T.check(rich.body.hasPrefix("Hello there.\n\n"), "rich: the body setter too")
    }

    // MARK: Fixtures and routes

    static func fixtureFiles() {
        T.section("mail helper: committed fixture files match the fixtures")
        guard let folder = ProcessInfo.processInfo.environment["YC_FIXTURES"] else { T.note("YC_FIXTURES not set; skipped"); return }
        for (name, text) in MailHelperFixtures.files {
            let disk = try? String(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name), encoding: .utf8)
            T.equal(disk, text + "\n", "Tests/Fixtures/\(name)")
        }
    }

    static func write(to folder: String) -> Int32 {
        for (name, text) in MailHelperFixtures.files {
            guard (try? (text + "\n").write(to: URL(fileURLWithPath: folder).appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil else { return 1 }
        }
        return 0
    }

    static func routes() {
        T.section("mail helper: the section and its route")
        T.equal(AppSection.mailHelper.rawValue, "mailhelper", "open/app?section=mailhelper")
        let route = Route.parse(YayaLink.openApp(.mailHelper))
        T.equal(route?.params["section"], "mailhelper", "the link carries it")
        if let route, case .openApp(let section) = RouteDecider.decide(route, verify: { _, _ in false }) {
            T.equal(section, .mailHelper, "the router opens Mail helper")
        } else {
            T.check(false, "the router opens Mail helper")
        }
    }
}
