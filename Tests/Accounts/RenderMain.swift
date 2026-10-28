import AppKit
import SwiftUI

/// Headless PNGs of the accounts screens with fixture data (ImageRenderer only; no window, no app).
///     accounts-render <out-dir> <scratch-dir>
/// The accounts are the sample cast with its badges, drawn in code.
@main
enum AccountsRender {
    static let width: CGFloat = 900
    static let now = Date(timeIntervalSince1970: 1_760_878_800) // a fixed Sunday morning

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 2 else {
            print("usage: accounts-render <out-dir> <scratch-dir>")
            exit(2)
        }
        let out = URL(fileURLWithPath: args[1], isDirectory: true)
        let scratch = URL(fileURLWithPath: args[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        func logo(_ name: String) -> NSImage? { Cast.badge(key: name) }

        // 1. The screen: four accounts, one signed out, one blocked (kit open), personal blank.
        let full = model(scratch: scratch, google: true)
        let orb = account(Cast.orb.name, Cast.orb.tag, Cast.orb.email, Cast.orb.color, 0, .ok)
        let cmt = account(Cast.cmt.name, Cast.cmt.tag, Cast.cmt.email, Cast.cmt.color, 1, .reauthNeeded,
                          HealthText.detail(.reauthNeeded))
        let fam = account(Cast.fam.name, Cast.fam.tag, Cast.fam.email, Cast.fam.color, 2, .adminBlocked,
                          HealthText.detail(.adminBlocked))
        var personal = account("Gmail", "Personal", consumerAddress("avery.moonfield"), Cast.home.color, 3, .ok)
        personal.mailEnabled = true
        personal.includeInAll = false
        full.accounts = [orb, cmt, fam, personal]
        full.logos = [orb.id: logo("orb"), cmt.id: logo("cmt"), fam.id: logo("fam")].compactMapValues { $0 }
        full.checkedAt = [orb.id: now.addingTimeInterval(-120), personal.id: now.addingTimeInterval(-120)]
        full.adminKitOpen = [fam.id]
        save(screen(full), out.appendingPathComponent("accounts-screen.png"))

        // 2. Empty state, Google sign-in not set up, developer file available.
        let empty = model(scratch: scratch, google: false)
        empty.devClientFile = URL(fileURLWithPath: "/dev/Config/oauth.local.json")
        save(screen(empty), out.appendingPathComponent("accounts-empty.png"))

        // 3–6. The add sheet: idle, waiting on a copied link, blocked by an admin, success.
        let sheet = model(scratch: scratch, google: true)
        sheet.accounts = [orb, cmt, fam, personal]
        sheet.logos = full.logos
        sheet.addTarget = AddFlowTarget()
        sheet.addPhase = .idle
        save(sheetView(sheet), out.appendingPathComponent("accounts-add-idle.png"))
        sheet.addPhase = .waiting(SignInWaiting(mode: .link, link: URL(string: "https://accounts.google.com/"),
                                                deadline: now.addingTimeInterval(272)))
        save(sheetView(sheet), out.appendingPathComponent("accounts-add-waiting.png"))
        sheet.addPhase = .failed(.adminBlocked(code: "admin_policy_enforced"))
        save(sheetView(sheet), out.appendingPathComponent("accounts-add-blocked.png"))
        sheet.addTarget = AddFlowTarget(provider: .google, reauthAccount: cmt.id, loginHint: cmt.email)
        sheet.addPhase = .idle
        save(sheetView(sheet), out.appendingPathComponent("accounts-add-reauth.png"))
        sheet.addTarget = AddFlowTarget()
        sheet.addPhase = .success(SignInSuccess(accountId: orb.id, email: orb.email, isNew: true, note: nil))
        save(sheetView(sheet), out.appendingPathComponent("accounts-add-success.png"))

        // 7. Provider setup: missing (with the developer-file offer) and ready.
        let missing = model(scratch: scratch, google: false)
        missing.devClientFile = URL(fileURLWithPath: "/dev/Config/oauth.local.json")
        let ready = model(scratch: scratch, google: true)
        save(VStack(alignment: .leading, spacing: 18) {
            ProviderSetupView(model: missing)
            ProviderSetupView(model: ready)
        }
        .padding(28)
        .frame(width: 760)
        .background(AppTheme.background), out.appendingPathComponent("accounts-provider-setup.png"))

        print("\u{2713} rendered to \(out.path)")
    }

    @MainActor
    static func model(scratch: URL, google: Bool) -> AccountsModel {
        let clients = FakeClientStore(google ? [.google: Fixtures.googleClient] : [:])
        let env = Fixtures.environment(dir: scratch, vault: FakeVault(), clients: clients,
                                       recorders: Fixtures.Recorders())
        let model = AccountsModel(environment: env)
        // What `reloadProviderStatus()` (async since D-021) reads back from the fake client store.
        // As Provider Setup shows a client: "…" and the last six characters, never the project number.
        model.google = google ? .ready(clientIDHint: AccountsModel.clientHint(Fixtures.googleClient.clientId)) : .missing
        model.devClientFile = nil
        return model
    }

    static func account(_ name: String, _ tag: String, _ email: String, _ color: UInt32, _ order: Int,
                        _ health: HealthState, _ detail: String? = nil) -> AccountRecord {
        AccountRecord(id: UUID(), provider: "google", email: email, displayName: name, tag: tag, color: color,
                      logoFile: nil, includeInAll: true, mailEnabled: true, calendarEnabled: true, sortOrder: order,
                      health: health, healthDetail: detail, createdAt: now)
    }

    @MainActor
    static func screen(_ model: AccountsModel) -> some View {
        AccountsScreen(model: model, now: now)
            .frame(width: width)
            .background(AppTheme.background)
    }

    @MainActor
    static func sheetView(_ model: AccountsModel) -> some View {
        AddAccountSheet(model: model, now: now)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppTheme.stroke))
            .padding(30)
            .background(Color(hex: 0x070D11))
    }

    @MainActor
    static func save<V: View>(_ view: V, _ url: URL) {
        let content = view
            .environment(\.accountsStaticRender, true)
            .environment(\.colorScheme, .dark)
            .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("\u{2717} \(url.lastPathComponent)")
            return
        }
        do {
            try png.write(to: url)
            print("  \(url.lastPathComponent)  \(Int(image.size.width))\u{00D7}\(Int(image.size.height)) pt")
        } catch {
            print("\u{2717} \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
