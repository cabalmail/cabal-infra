import XCTest
import CabalmailKit
@testable import Cabalmail

/// Compose behaviour when the WebKit editor bridge is dead.
///
/// The send-side guard (#745) already refuses to ship a body that converted
/// to `""`, but it refused *silently*: Send stayed enabled, the tap did
/// nothing visible, and the user reasonably concluded the message had gone
/// (#812). These cover the announcement half — the banner goes up when the
/// bridge reports the failure, Send stops being offered, a tap that races
/// the failure still explains itself, and a late `ready` undoes all of it.
@MainActor
final class ComposeBridgeFailureTests: XCTestCase {
    /// A compose filled in far enough that only the editor's health is
    /// left to decide whether Send is offered.
    private func makeFilledModel() throws -> ComposeViewModel {
        let model = try TestFixtures.makeComposeModel()
        model.fromAddress = "sender@cabalmail.example"
        model.subject = "Bridge health"
        model.toText = "recipient@example.com"
        return model
    }

    func testFilledFormOffersSend() throws {
        let model = try makeFilledModel()
        XCTAssertTrue(model.canSend)
    }

    func testBridgeFailureRaisesBannerAndWithdrawsSend() throws {
        let model = try makeFilledModel()
        model.noteEditorUnavailable("failed to load editor-bridge.js")

        XCTAssertFalse(model.canSend, "Send must not stay enabled with no way to build a body")
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.contains("editor didn't load"), message)
        XCTAssertTrue(message.contains("failed to load editor-bridge.js"), message)
    }

    func testSendRefusesAndSaysWhy() async throws {
        let model = try makeFilledModel()
        model.noteEditorUnavailable("the editor did not finish loading")

        let sent = await model.send()

        XCTAssertFalse(sent)
        XCTAssertEqual(
            model.errorMessage,
            ComposeViewModel.editorUnavailableMessage("the editor did not finish loading")
        )
    }

    func testLateReadyClearsBannerAndRestoresSend() throws {
        let model = try makeFilledModel()
        model.noteEditorUnavailable("the editor did not finish loading")

        model.noteEditorRecovered()

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canSend)
    }

    /// Recovery only retracts its own banner — an error raised since the
    /// bridge failed is still the message worth leaving on screen.
    func testLateReadyKeepsAnUnrelatedError() throws {
        let model = try makeFilledModel()
        model.noteEditorUnavailable("the editor did not finish loading")
        model.errorMessage = "Couldn't load addresses: network error"

        model.noteEditorRecovered()

        XCTAssertEqual(model.errorMessage, "Couldn't load addresses: network error")
    }
}
