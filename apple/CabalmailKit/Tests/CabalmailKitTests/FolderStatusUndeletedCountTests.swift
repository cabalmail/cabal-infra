import XCTest
@testable import CabalmailKit
import CabalmailKitTestSupport

/// `/folder_status`'s not-deleted count, and the reading the message list
/// addresses positions by (#1836). STATUS MESSAGES counts a message flagged
/// `\Deleted` elsewhere and not yet expunged; `/list_messages` leaves it out
/// of its `NOT DELETED` sort, so the two totals are over different sets and
/// only the second one says where row n is.
final class FolderStatusUndeletedCountTests: XCTestCase {

    private func makeClient(_ body: String) -> ApiBackedImapClient {
        let configuration = TestFixtures.makeConfiguration()
        let api = URLSessionApiClient(
            configuration: configuration,
            authService: StubAuthService(),
            transport: RecordingHTTPTransport(responses: [(Data(body.utf8), 200)])
        )
        return ApiBackedImapClient(api: api, host: "imap.example.com")
    }

    func testTheFlaggedReplyCarriesTheCountAndPositionsReadIt() async throws {
        let client = makeClient(
            #"{"messages":42,"unseen":3,"flagged":2,"undeleted":41,"uid_validity":12345,"uid_next":100}"#
        )
        let status = try await client.status(path: "INBOX", flagged: true)
        XCTAssertEqual(status.messages, 42, "MESSAGES still counts the deleted-but-unexpunged one")
        XCTAssertEqual(status.flagged, 2)
        XCTAssertEqual(status.undeleted, 41)
        XCTAssertEqual(status.listedMessages, 41, "positions are over the not-deleted set")
    }

    func testTheCheapReplyCarriesNoCountAndPositionsFallBackToMessages() async throws {
        let client = makeClient(#"{"messages":42,"unseen":3,"uid_validity":12345,"uid_next":100}"#)
        let status = try await client.status(path: "INBOX")
        XCTAssertNil(status.undeleted)
        XCTAssertEqual(status.listedMessages, 42)
    }

    /// A reply with the count but no MESSAGES is still readable, and one with
    /// neither says nothing -- the guard the window reads it behind.
    func testTheCountStandsAloneAndNeitherIsNil() async throws {
        let only = try await makeClient(#"{"undeleted":7,"uid_next":100}"#).status(path: "INBOX", flagged: true)
        XCTAssertEqual(only.listedMessages, 7)
        let neither = try await makeClient(#"{"uid_next":100}"#).status(path: "INBOX")
        XCTAssertNil(neither.listedMessages)
    }
}
