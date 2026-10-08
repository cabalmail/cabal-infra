import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the feed sheets and sidebars say for an RSS failure.
///
/// A coded failure (`not_a_feed`) reads from the table. A failure without a
/// code is `.http` since workstream 1.6 and reads as its localized sentence;
/// before, it was `.server` with the HTTP status for a code, and the sheets
/// printed the raw reply: escaped JSON, or a whole HTML gateway page.
final class FeedErrorTextTests: XCTestCase {
    func testACodedFailureReadsFromTheTable() {
        let error = CabalmailError.server(code: "not_a_feed", message: "That page does not advertise a feed.")

        XCTAssertEqual(
            FeedErrorText.describe(error),
            "That address didn't return a feed, and the page doesn't advertise one."
        )
    }

    func testAnUncodedFailureReadsAsItsSentenceNotItsBody() {
        let cases: [(error: CabalmailError, text: String)] = [
            (.http(status: 502, body: #"{"message": "Internal server error"}"#), "Internal server error."),
            (.http(status: 500, body: ""), "The server couldn't complete that request (500)."),
            (.http(status: 502, body: "<html><body>502 Bad Gateway</body></html>"),
             "The server couldn't complete that request (502)."),
        ]
        for (error, text) in cases {
            XCTAssertEqual(FeedErrorText.describe(error), text, "\(error)")
        }
    }
}
