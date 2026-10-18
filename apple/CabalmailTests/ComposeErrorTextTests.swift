import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Issue #1900: a failed draft save read "Couldn't save draft: Send failed:
/// …" — the save path prefixed its own lead onto a renderer that had the
/// send's lead baked in, so every arm but `.network`, `.authExpired` and
/// `.maintenance` told the user a send had failed on a path that sends
/// nothing. The leads live with their operation now.
@MainActor
final class ComposeErrorTextTests: XCTestCase {

    /// Every arm, from the verification's own table. No draft-save message
    /// may mention sending.
    func testDraftSaveFailuresNeverMentionSending() {
        let errors: [CabalmailError] = [
            .server(code: "500", message: ""),
            .decoding("bad json"),
            .storage("keychain"),
            .invalidCredentials,
            .notConfigured,
            .notSignedIn,
            .transport("timed out"),
            .protocolError("bad greeting"),
            .cancelled,
            .sendInFlight,
            .network("offline"),
            .authExpired,
            .maintenance(message: "Back at nine.")
        ]
        for error in errors {
            let text = ComposeErrorText.draftSaveFailure(error)
            XCTAssertTrue(text.hasPrefix("Couldn't save draft: "), "\(error): \(text)")
            XCTAssertFalse(text.lowercased().contains("send failed"), "\(error): \(text)")
        }
    }

    /// The two arms the report and its verification quoted, in full.
    func testQuotedDraftSaveMessages() {
        XCTAssertEqual(
            ComposeErrorText.draftSaveFailure(.server(code: "500", message: "")),
            "Couldn't save draft: The server couldn't complete that request (500)."
        )
        XCTAssertEqual(
            ComposeErrorText.draftSaveFailure(.invalidCredentials),
            "Couldn't save draft: your credentials were rejected."
        )
    }

    /// The negative control: the send path keeps the lead it has always
    /// had, including on the arms whose reason is a sentence of its own.
    func testSendFailuresAreUnchanged() {
        XCTAssertEqual(
            ComposeErrorText.sendFailure(.server(code: "500", message: "")),
            "Send failed: The server couldn't complete that request (500)."
        )
        XCTAssertEqual(
            ComposeErrorText.sendFailure(.invalidCredentials),
            "Send failed: your credentials were rejected."
        )
        XCTAssertEqual(ComposeErrorText.sendFailure(.network("offline")), "Network error: offline")
        XCTAssertEqual(
            ComposeErrorText.sendFailure(.authExpired),
            "Your session expired; please sign in again."
        )
        XCTAssertEqual(ComposeErrorText.sendFailure(.maintenance(message: "Back at nine.")), "Back at nine.")
    }

    /// The whole path, not just the renderer: the shipped
    /// `pushDraftToServer` against a `/save_draft` answering 500, which is
    /// the arm the verification drove.
    func testFailedServerSaveShowsTheSaveLeadOnly() async throws {
        let transport = DraftRaceTransport(nextSaveUid: 786)
        await transport.fail(.save)
        let model = try TestFixtures.makeComposeModel(transport: transport)
        model.fromAddress = "daily@cabalmail.example"
        model.subject = "f1900probe"
        model.toText = "someone@example.com"

        let saved = await model.pushDraftToServer(
            OutgoingMessage(
                from: EmailAddress(name: nil, mailbox: "daily", host: "cabalmail.example"),
                to: [EmailAddress(name: nil, mailbox: "someone", host: "example.com")],
                subject: "f1900probe",
                textBody: "body",
                htmlBody: nil
            )
        )

        XCTAssertFalse(saved, "a 500 leaves the window up")
        XCTAssertEqual(
            model.errorMessage,
            "Couldn't save draft: The server couldn't complete that request (500)."
        )
    }
}
