// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import AppKit
import Foundation
import SwiftUI

/// Yaya's Mail Helper renders (D-050), each under a Light and a Dark Mac (the app keeps its own dark look, D-008): the
/// window on Overview and on Digest, the whole Overview (accounts, the backlog's plan, Review, Needs reply,
/// suggestions, activity, your voice open, the VIP editor) and the whole digest, the hand-over card, the Undo all
/// confirmation, the page before pairing, the Inbox with Priority first and its chips, and the composer's Draft with
/// AI (the button, the pop-over, drafting, an error). The Moonfield cast only: MailHelperFixtures' files through a fake
/// session that answers at once (no files read, nothing written or opened), memory bags, a pinned clock.
@MainActor
enum MailHelperRenders {
    /// A session over the fixture files whose commands are answered at once: `draft` per `draftAnswer` (nil = never).
    static func session(paired: Bool = true, draftAnswer: MailHelperResult? = nil, now: Date) -> MailHelperSession {
        var answers: [UUID: MailHelperResult] = [:]
        var state = MailHelperFixtures.parsedState()!
        if !paired {
            state.lab.paired = false
            state.sealKey = nil
            state.sealFingerprint = nil
        }
        let s = MailHelperSession(env: MailHelperSession.Environment(
            installed: { true }, state: { .ready(state) }, digest: { .ready(MailHelperFixtures.parsedDigest()) },
            write: { id, data in
                let kind = MailHelperJSON.parse(data)?["kind"]?.string ?? ""
                switch kind {
                case "needs_reply": answers[id] = MailHelperResult(id: id, ok: true, error: nil, data: MailHelperJSON.parse(Data(MailHelperFixtures.needsReply.utf8))!)
                case "voice_get": answers[id] = MailHelperResult(id: id, ok: true, error: nil, data: MailHelperJSON.parse(Data(MailHelperFixtures.voice.utf8))!)
                case "draft": if let a = draftAnswer { answers[id] = MailHelperResult(id: id, ok: a.ok, error: a.error, data: a.data) }
                default: answers[id] = MailHelperResult(id: id, ok: true, error: nil, data: .object([:]))
                }
                return true
            },
            open: { _ in true }, answer: { answers.removeValue(forKey: $0) }, clock: { now }, after: { _, _ in }))
        s.refresh()
        return s
    }

    static func model(_ session: MailHelperSession, directory: AccountDirectory, now: Date, bag: PreferenceBag = MemoryBag()) -> MailHelperModel {
        MailHelperModel(session: session, directory: { directory }, bag: bag,
                        live: MailHelperModel.Live(personalDomains: ["home.example"]), clock: { now },
                        toasts: MailToastCenter(clock: { now }, schedule: { _, _ in }))
    }

    @discardableResult
    static func run(dir: URL, now: Date, directory: AccountDirectory, save: (AnyView, String, [String: Any]) -> Void) -> Int {
        var count = 0
        let backdrop = AppTheme.background
        for mac in [ColorScheme.light, .dark] {
            let look = mac == .dark ? "dark" : "light"

            func window(_ shell: ShellModel, _ name: String, _ state: String) {
                save(AnyView(MainView(shell: shell).frame(width: 1100, height: 740)
                        .environment(\.colorScheme, mac).environment(\.headlessRender, true)),
                     "\(name)-\(look).png", ["window": "mailhelper", "feature": "mailhelper", "state": state, "mac": look])
                count += 1
            }
            func shell(_ section: AppSection, helper: MailHelperModel, inbox: InboxSectionModel? = nil) -> ShellModel {
                ShellModel(section: section, calendar: CalendarSectionModel(clock: { now }),
                           inbox: inbox ?? InboxSectionModel(clock: { now }, mailHelperLabels: { nil }),
                           menuBar: MenuBarSettingsModel(bag: MemoryBag(), mailEnabled: { true }, state: { .on }, post: {}),
                           mailHelper: helper, fixedNow: now)
            }

            // 1. The window: Overview and Digest; before pairing.
            let overview = model(session(now: now), directory: directory, now: now)
            overview.loadNeedsReply()
            window(shell(.mailHelper, helper: overview), "mailhelper-window-overview", "overview")
            let digest = model(session(now: now), directory: directory, now: now)
            digest.page = .digest
            digest.markRead("updates")
            window(shell(.mailHelper, helper: digest), "mailhelper-window-digest", "digest")
            let unpaired = model(session(paired: false, now: now), directory: directory, now: now)
            unpaired.loadNeedsReply()
            window(shell(.mailHelper, helper: unpaired), "mailhelper-window-unpaired", "unpaired")

            // 2. The whole pages, top to bottom.
            let full = model(session(now: now), directory: directory, now: now, bag: MemoryBag([
                MailHelperModel.vipKey + Cast.home.id.uuidString: ["juniper@moonfield-family.example", "theo@moonbase.example"],
                MailHelperModel.vipDomainKey + Cast.home.id.uuidString: ["moonfield-family.example"]]))
            full.loadNeedsReply()
            full.toggle("voice:\(Cast.home.id)")
            full.loadVoice(Cast.home.id)
            full.editVIPs(Cast.cmt.id)
            full.vipPeople = "milo@quietcomets.example"
            save(AnyView(MailHelperOverview(model: full).padding(.horizontal, 24).padding(.vertical, 22)
                    .frame(width: 899).fixedSize(horizontal: false, vertical: true)
                    .background(backdrop).environment(\.colorScheme, mac).environment(\.headlessRender, true)),
                 "mailhelper-overview-full-\(look).png", ["window": "mailhelper", "feature": "mailhelper", "state": "overview-full", "mac": look])
            count += 1
            let fullDigest = model(session(now: now), directory: directory, now: now)
            fullDigest.markRead("newsletters")
            save(AnyView(MailHelperDigestView(model: fullDigest)
                    .frame(width: 899).fixedSize(horizontal: false, vertical: true)
                    .background(backdrop).environment(\.colorScheme, mac).environment(\.headlessRender, true)),
                 "mailhelper-digest-full-\(look).png", ["window": "mailhelper", "feature": "mailhelper", "state": "digest-full", "mac": look])
            count += 1

            // 3. The hand-over card (FAM, not handed over yet) and the Undo all confirmation.
            let handover = model(session(now: now), directory: directory, now: now)
            handover.beginHandover(Cast.fam.id)
            window(shell(.mailHelper, helper: handover), "mailhelper-handover", "handover-card")
            let confirm = model(session(now: now), directory: directory, now: now)
            confirm.askUndoAll("bf-0b1a2c3d4e5f", tag: Cast.orb.tag)
            window(shell(.mailHelper, helper: confirm), "mailhelper-confirm-undo-all", "confirm-undo-all")

            // 4. The Inbox: Priority first, ⭐ and Review chips (labels on a few of the sample threads).
            var threads = FixtureMail.threads(now: now)
            for i in threads.indices {
                switch threads[i].thread.r {
                case "th-mom", "th-rafa": threads[i].thread.labels = ["INBOX", "Label_101"]
                case "th-juniper": threads[i].thread.labels = ["INBOX", "Label_201"]
                case "th-wiki": threads[i].thread.labels = ["INBOX", "Label_202"]
                default: break
                }
            }
            let store = FakeMailStore(threads: threads)
            let labels = MailHelperInboxLabels(MailHelperFixtures.parsedState())
            let inbox = InboxSectionModel(store: { store }, actions: { FakeMailActions(store: store) }, prefs: { FakeMailPreferences() },
                                          directory: { directory }, clock: { now }, undoBook: MailUndoBook(), local: MemoryMailLocalStore(),
                                          toasts: MailToastCenter(clock: { now }, schedule: { _, _ in }), mailHelperLabels: { labels })
            inbox.load()
            window(shell(.inbox, helper: model(session(now: now), directory: directory, now: now), inbox: inbox),
                   "mailhelper-inbox-priority", "inbox-priority-chips")

            // 5. The composer: Draft with AI on a reply (plain), its pop-over (rich), drafting, and the helper's error.
            func composer(_ name: String, format: ComposerFormat, draftAnswer: MailHelperResult?, open: Bool, act: Bool,
                          pick: MailDraftModel = .local, thread: String = "th-juniper") {
                let fixture = FixtureMail.threads(now: now).first { $0.thread.r == thread }!
                let request = ComposerRequest.reply(fixture.thread, fixture.messages.max { $0.date < $1.date })
                let composer = ComposerModel(request: request, accounts: directory.accounts, safeSend: true, local: MemoryMailLocalStore(),
                                             clock: { now }, schedule: { _, _ in }, toasts: MailToastCenter(clock: { now }, schedule: { _, _ in }),
                                             format: format)
                var clock = now
                let drafting = MailHelperDraftModel(account: fixture.thread.accountId, threadR: fixture.thread.r,
                                                    session: session(draftAnswer: draftAnswer, now: now), threadId: { _ in "18f2a0c4d1e5e002" },
                                                    bag: MemoryBag(), clock: { clock }, insert: { [weak composer] in composer?.insertDraft($0) })
                drafting.model = pick
                drafting.instruction = act ? "Yes to Wednesday; ask whether 3 pm works" : ""
                if act {
                    drafting.draft()
                    clock = now.addingTimeInterval(95)
                }
                drafting.open = open
                save(AnyView(ComposerView(model: composer, drafting: drafting).frame(width: 640, height: 600)
                        .environment(\.colorScheme, mac).environment(\.headlessRender, true)),
                     "\(name)-\(look).png", ["window": "composer", "feature": "mailhelper", "state": name, "mac": look])
                count += 1
            }
            composer("mailhelper-composer-draft-button", format: .plain, draftAnswer: nil, open: false, act: false)
            // Personal (Local + Claude on): no warning before asking.
            composer("mailhelper-composer-draft-popover", format: .rich, draftAnswer: nil, open: true, act: false, pick: .sonnet, thread: "th-rafa")
            composer("mailhelper-composer-draft-working", format: .rich, draftAnswer: nil, open: true, act: true, pick: .sonnet, thread: "th-rafa")
            // ORB (Claude off): the helper's own answer, inline.
            composer("mailhelper-composer-draft-error", format: .rich,
                     draftAnswer: MailHelperResult(id: UUID(), ok: false, error: "Claude is off for this account.", data: .null),
                     open: true, act: true, pick: .opus)
            composer("mailhelper-composer-draft-inserted", format: .plain,
                     draftAnswer: MailHelperResult(id: UUID(), ok: true, error: nil, data: .object(["draft": .string(
                        "Hi Juniper,\n\nWednesday works for me. Would 3 pm suit you? If not, any time after lunch is fine.\n\nThanks, Avery")])),
                     open: false, act: true)
        }
        return count
    }
}
#endif
