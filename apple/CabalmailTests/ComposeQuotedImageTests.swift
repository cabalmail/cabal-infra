import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the rich pane shows of a remote image in the seed. Reply, reply-all
/// and forward quote somebody else's message, whose text part can carry a
/// Markdown or raw `<img>` pointing at their server; showing it would fetch
/// it as the composer opened. A new compose and a resumed draft are the
/// user's own words and keep their images, and so does the user's
/// signature in a reply.
@MainActor
final class ComposeQuotedImageTests: XCTestCase {
    private static let body = "Above\n\n![logo](https://tracker.invalid/logo.png)"

    func testQuotingSeedsShowARemoteImageAsText() async throws {
        for intent in [ComposeIntent.reply, .replyAll, .forward] {
            let html = try await seededRichPane(intent: intent)
            XCTAssertFalse(html.contains("<img"), "\(intent): \(html)")
            XCTAssertTrue(html.contains("logo"), "\(intent): \(html)")
        }
    }

    func testNewComposeKeepsItsRemoteImage() async throws {
        let html = try await seededRichPane(intent: .new)
        XCTAssertTrue(html.contains("<img src=\"https://tracker.invalid/logo.png\""), html)
    }

    /// The user's own signature sits above the quote and keeps its image.
    func testQuotingSeedsKeepTheSignaturesImage() async throws {
        let signature = "Me\n\n![sig](https://signature.invalid/sig.png)"
        let html = try await seededRichPane(intent: .reply, signature: signature)
        XCTAssertTrue(html.contains("<img src=\"https://signature.invalid/sig.png\""), html)
        XCTAssertFalse(html.contains("<img src=\"https://tracker.invalid"), html)
    }

    /// Import from Markdown re-renders the quote, so it blocks the same way.
    func testImportFromMarkdownInAReplyShowsARemoteImageAsText() async throws {
        let model = try await bootedModel(intent: .reply, signature: "")
        await model.importFromMarkdown()
        let html = await model.editorController.getHTML()
        XCTAssertFalse(html.contains("<img"), html)
        XCTAssertTrue(html.contains("logo"), html)
    }

    private func seededRichPane(intent: ComposeIntent, signature: String = "") async throws -> String {
        let model = try await bootedModel(intent: intent, signature: signature)
        await model.start()
        model.stop()
        return await model.editorController.getHTML()
    }

    private func bootedModel(intent: ComposeIntent, signature: String) async throws -> ComposeViewModel {
        let model = try TestFixtures.makeComposeModel(
            seed: Draft(body: Self.body, composeIntent: intent),
            signature: signature
        )
        await model.editorController.waitUntilReady()
        try XCTSkipIf(
            model.editorController.bridgeFailure != nil,
            "editor bridge failed to boot: \(model.editorController.bridgeFailure ?? "")"
        )
        return model
    }
}
