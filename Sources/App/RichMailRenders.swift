// Developer tool (D-035): compiled only with -D YC_DEV_TOOLS (./build.sh --dev, --render, --bench, --selftest
// and the test runners). Release builds (plain ./build.sh, --install, --release) leave it out.
#if YC_DEV_TOOLS
import SwiftUI

/// Rich-mail renders (`rm-*.png`) for `--render`, from the Moonfield cast only
/// (RichMailFixtures), through the real pipeline (parser, sanitizer, MailQuote, MailPlainText) and real web
/// snapshots of the reader's web view (RichTextSnapshot). HeadlessRender calls this once, before it writes the
/// manifest; every image goes through its `save`, so it lands in `render-manifest.json` with the rest.
@MainActor
enum RichMailRenders {
    static func run(dir: URL, now: Date, save: (AnyView, String, [String: Any]) -> Void) {
        AttachmentIcons.systemIconsOnly = true   // no third-party app icons in the PNGs
        withoutActuallyEscaping(save) { save in
            RichMailReaderRenders.run(dir: dir, now: now, save: save)
        }
    }
}
#endif
