import XCTest
import CabalmailKit
@testable import Cabalmail

/// Regression coverage for issue #903: tapping "Save Draft" with the From
/// picker still on "Select an address…" dismissed the composer exactly as if
/// the save had succeeded, and nothing ever reached the Drafts folder — the
/// typed recipient and subject were gone. `cancel()` checked for a sender
/// before it checked whether there was anything to keep, and treated the
/// missing sender as "close silently".
@MainActor
final class ComposeCancelPolicyTests: XCTestCase {

    /// The reported flow: To and Subject filled in, From never picked.
    func testContentWithoutAFromRefusesInsteadOfClosing() {
        let resolution = ComposeCancelPolicy.resolve(
            bridgeFailed: false,
            hasContent: true,
            hasFrom: false
        )

        XCTAssertEqual(resolution, .refuseMissingFrom)
    }

    func testContentWithAFromSavesToTheServer() {
        let resolution = ComposeCancelPolicy.resolve(
            bridgeFailed: false,
            hasContent: true,
            hasFrom: true
        )

        XCTAssertEqual(resolution, .saveToServer)
    }

    /// Opening the composer and closing it again leaves no breadcrumb —
    /// with or without a From address. Nothing was typed, so there is
    /// nothing to refuse over.
    func testEmptyComposeDiscardsWhateverTheFromIs() {
        XCTAssertEqual(
            ComposeCancelPolicy.resolve(bridgeFailed: false, hasContent: false, hasFrom: false),
            .discardEmpty
        )
        XCTAssertEqual(
            ComposeCancelPolicy.resolve(bridgeFailed: false, hasContent: false, hasFrom: true),
            .discardEmpty
        )
    }

    /// A dead bridge still wins (#745): every body converted to `""`, so
    /// pushing would blank a good server copy. The local autosave holds the
    /// text and the window is allowed to close — including when there is no
    /// From, where refusing would trap the user in a composer whose editor
    /// doesn't work.
    func testDeadBridgeClosesOnTheLocalCopy() {
        for hasFrom in [true, false] {
            XCTAssertEqual(
                ComposeCancelPolicy.resolve(bridgeFailed: true, hasContent: true, hasFrom: hasFrom),
                .closeKeepingLocalCopy,
                "hasFrom: \(hasFrom)"
            )
        }
    }

    func testRefusalSaysWhatToDoAboutIt() {
        let message = ComposeCancelPolicy.missingFromMessage

        XCTAssertTrue(message.contains("From address"), message)
        XCTAssertTrue(message.contains("Discard Draft"), message)
    }

    // MARK: - The composer's own view of "is there anything to keep"

    /// A recipient and a subject are content on their own — the bodies are
    /// empty in the reported repro, and that must not read as an empty
    /// compose (which would resolve to `.discardEmpty` and throw the same
    /// text away by a different route).
    func testRecipientAndSubjectCountAsContentWithEmptyBodies() throws {
        let model = try TestFixtures.makeComposeModel()
        model.toText = "recipient@example.com"
        model.subject = "t27-0803 draft probe"

        XCTAssertTrue(model.hasDraftContent(bodies: (text: "", html: "")))
    }

    func testABlankComposeHasNothingToKeep() throws {
        let model = try TestFixtures.makeComposeModel()

        XCTAssertFalse(model.hasDraftContent(bodies: (text: "", html: "")))
    }
}
