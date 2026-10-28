import Foundation

/// Rich mail data-layer suite: the pure tests in `RichMailTests`, then the engine
/// tests (attachment cache, outbox, upload path). One hook in TestMain runs it all.
enum RichMailDataTests {
    static func run() async {
        RichComposerTests.run()
        RichMailTests.run()
        await RichMailViewerTests.run()
        await RichMailAttachmentTests.run()
        await RichMailSendTests.run()
        await RichMailReviewTests.run()
    }
}
