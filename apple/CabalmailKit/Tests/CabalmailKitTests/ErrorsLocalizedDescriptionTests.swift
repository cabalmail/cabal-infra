import XCTest
@testable import CabalmailKit

// Regression tests for #940: `CabalmailError` conformed to `Error` but not
// `LocalizedError`, so every `error.localizedDescription` in the UI fell back
// to the enum's synthesized description. Opening a message the server had
// deleted printed
//   server(code: "404", message: "{\"status\": \"That message is no longer
//   in Drafts\", \"folder\": \"Drafts\", \"id\": 572}")
// in red across four lines of the reader — with the sentence the user wanted
// sitting inside the payload, wrapped in enum syntax and escaped quotes.
final class ErrorsLocalizedDescriptionTests: XCTestCase {

    func testTheReaders404ReadsAsTheServersOwnSentence() {
        let error = CabalmailError.server(
            code: "404",
            message: #"{"status": "That message is no longer in Drafts", "folder": "Drafts", "id": 572}"#
        )
        XCTAssertEqual(error.localizedDescription, "That message is no longer in Drafts.")
    }

    // The conformance is what makes it work through the `Error` existential —
    // which is how every call site sees it.
    func testTheSentenceSurvivesTheErrorExistential() {
        let error: Error = CabalmailError.maintenance(message: "Mail is briefly unavailable.")
        XCTAssertEqual(error.localizedDescription, "Mail is briefly unavailable.")
    }

    func testAnUnexplainedServerErrorNamesTheCode() {
        // A body that isn't JSON at all (API Gateway HTML, an empty 500).
        XCTAssertEqual(
            CabalmailError.server(code: "500", message: "<html>502 Bad Gateway</html>").localizedDescription,
            "The server couldn't complete that request (500)."
        )
        // A one-word machine marker is state, not an explanation.
        XCTAssertEqual(
            CabalmailError.server(code: "400", message: #"{"status": "unable"}"#).localizedDescription,
            "The server couldn't complete that request (400)."
        )
    }

    func testApiGatewaysOwnMessageKeyIsUsedToo() {
        XCTAssertEqual(
            CabalmailError.server(code: "403", message: #"{"message": "User is not authorized"}"#).localizedDescription,
            "User is not authorized."
        )
    }

    func testWireDetailIsCarriedAsASentence() {
        XCTAssertEqual(
            CabalmailError.network("cancelled").localizedDescription,
            "Couldn't reach the server. cancelled."
        )
        XCTAssertEqual(
            CabalmailError.transport("").localizedDescription,
            "The connection failed.",
            "an empty detail must not leave the copy trailing off"
        )
    }

    func testNoCaseFallsBackToTheEnumDescription() {
        let cases: [CabalmailError] = [
            .notConfigured, .notSignedIn, .invalidCredentials, .authExpired,
            .network("boom"), .transport("boom"), .protocolError("boom"), .decoding("boom"),
            .timeout, .cancelled,
            .server(code: "404", message: ""),
            .imapCommandFailed(status: "NO", detail: "Mailbox doesn't exist"),
            .smtpCommandFailed(code: 550, detail: "Sender rejected"),
            .maintenance(message: "Mail is briefly unavailable."),
            .bulkPartialFailure(succeeded: [1, 2], failed: [3])
        ]
        for error in cases {
            let text = error.localizedDescription
            XCTAssertEqual(text, error.errorDescription, "\(error): the existential must see the same copy")
            XCTAssertFalse(
                text.contains("(code:") || text.contains("\\\"") || text.hasSuffix(")\""),
                "\(error) still reads as a raw enum: \(text)"
            )
            XCTAssertFalse(text.isEmpty, "\(error) has no user-facing copy")
        }
    }

    func testAPartialBulkFailureCountsWhatFailed() {
        XCTAssertEqual(
            CabalmailError.bulkPartialFailure(succeeded: [1, 2], failed: [3]).localizedDescription,
            "1 of 3 messages couldn't be updated."
        )
    }
}
