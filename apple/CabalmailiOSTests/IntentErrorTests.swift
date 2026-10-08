#if os(iOS)
import XCTest
import CabalmailKit
@testable import Cabalmail

/// What Siri and Shortcuts say when an intent's request fails.
///
/// A Lambda or S3 failure is `.http` since workstream 1.6 and takes
/// `IntentError.friendly`'s default arm, its readable sentence. Before, it was
/// `.server`, whose arm passes the message through for Cognito's trigger copy,
/// so Siri read the raw reply aloud: JSON, a whole HTML page, or nothing at
/// all for an empty body.
final class IntentErrorTests: XCTestCase {
    func testAnApiFailureIsSpokenAsItsSentence() {
        let cases: [(error: CabalmailError, spoken: String)] = [
            (.http(status: 502, body: #"{"message": "Internal server error"}"#), "Internal server error."),
            (.http(status: 404, body: #"{"status": "That message is no longer in INBOX"}"#),
             "That message is no longer in INBOX."),
            (.http(status: 500, body: ""), "The server couldn't complete that request (500)."),
            (.http(status: 502, body: "<html><body>502 Bad Gateway</body></html>"),
             "The server couldn't complete that request (502)."),
        ]
        for (error, spoken) in cases {
            XCTAssertEqual(Self.text(IntentError.friendly(error)), spoken, "\(error)")
        }
    }

    /// The control: a Cognito trigger's own copy is still spoken verbatim.
    func testACognitoTriggersCopyIsStillSpokenAsWritten() {
        let error = CabalmailError.server(code: "UserLambdaValidationException", message: "Set up two-factor sign-in.")

        XCTAssertEqual(Self.text(IntentError.friendly(error)), "Set up two-factor sign-in.")
    }

    private static func text(_ error: IntentError) -> String? {
        guard case .message(let text) = error else { return nil }
        return text
    }
}
#endif
