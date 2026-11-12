import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// Custom flags on feed items at the wire (`docs/rss.md`): `flags` on items
/// and state rows, `add_flags` and `remove_flags` on `/rss_set_item_state`,
/// and the one refusal that names the slots it is about.
final class ApiClientRssFlagTests: XCTestCase {
    private func makeClient(_ responses: [(String, Int)]) -> (URLSessionApiClient, RecordingHTTPTransport) {
        let http = RecordingHTTPTransport(responses: responses.map { (Data($0.0.utf8), $0.1) })
        let client = URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: http
        )
        return (client, http)
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testItemsAndStateRowsDecodeTheirFlags() async throws {
        let page = """
        {"items": [{"feed_id": "f", "sort_key": "2026#i1", "flags": ["cabal-flag-03", "cabal-flag-05"]},
                   {"feed_id": "f", "sort_key": "2026#i2", "flags": []},
                   {"feed_id": "f", "sort_key": "2026#i3"}]}
        """
        let states = """
        {"states": [{"feed_id": "f", "sort_key": "2026#i1", "flags": ["cabal-flag-07"]},
                    {"feed_id": "f", "sort_key": "2026#i2"}], "next_state_since": "sc", "has_more": false}
        """
        let (client, _) = makeClient([(page, 200), (states, 200)])

        let listed = try await client.listItems(scope: .all, filter: .all, order: .newest, limit: 3, cursor: nil)
        XCTAssertEqual(listed.items.map(\.flags), [["cabal-flag-03", "cabal-flag-05"], [], []],
                       "a reply without the field reads as no flags")
        let synced = try await client.syncItemStates(subscriptionId: "s", since: "", limit: 50)
        XCTAssertEqual(synced.states.map(\.flags), [["cabal-flag-07"], []])
    }

    /// The lists go sorted, and an entry that changes no flag sends neither.
    func testSetItemStateSendsFlagsToAddAndToRemove() async throws {
        let (client, http) = makeClient([(#"{"updated": 2}"#, 200)])

        _ = try await client.setItemState([
            RssItemStateChange(feedId: "f", sortKey: "k1", addFlags: ["cabal-flag-05", "cabal-flag-03"],
                               removeFlags: ["cabal-flag-07"]),
            RssItemStateChange(feedId: "f", sortKey: "k2", isRead: true),
        ])

        let requests = await http.requests
        let items = try XCTUnwrap(body(requests[0])["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["add_flags"] as? [String], ["cabal-flag-03", "cabal-flag-05"])
        XCTAssertEqual(items[0]["remove_flags"] as? [String], ["cabal-flag-07"])
        XCTAssertNil(items[0]["is_read"])
        XCTAssertNil(items[1]["add_flags"])
        XCTAssertNil(items[1]["remove_flags"])
    }

    /// The one refusal that carries more than a code: the slots the server
    /// would not add, which the pending queue acts on.
    func testARefusedFlagSurfacesWithTheSlotsRefused() async throws {
        let refusal = """
        {"Error": "Not an enabled flag in the palette: cabal-flag-05, cabal-flag-09.",
         "code": "flag_not_in_palette", "flags": ["cabal-flag-05", "cabal-flag-09"]}
        """
        let (client, _) = makeClient([(refusal, 400)])

        do {
            _ = try await client.setItemState([
                RssItemStateChange(feedId: "f", sortKey: "k", addFlags: ["cabal-flag-05", "cabal-flag-09"]),
            ])
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? RssFlagRefusal, RssFlagRefusal(
                slots: ["cabal-flag-05", "cabal-flag-09"],
                message: "Not an enabled flag in the palette: cabal-flag-05, cabal-flag-09."))
            XCTAssertEqual(error.localizedDescription,
                           "Not an enabled flag in the palette: cabal-flag-05, cabal-flag-09.")
        }
    }

    /// Without slots to act on, and for the other flag codes, the failure
    /// is the coded server error every RSS endpoint gives.
    func testOtherFlagFailuresStayCodedServerErrors() async throws {
        let bodies = [
            #"{"Error": "Not an enabled flag.", "code": "flag_not_in_palette"}"#,
            #"{"Error": "Not an enabled flag.", "code": "flag_not_in_palette", "flags": []}"#,
            #"{"Error": "Not an enabled flag.", "code": "flag_not_in_palette", "flags": "cabal-flag-05"}"#,
            #"{"Error": "Both.", "code": "flag_conflict", "flags": ["cabal-flag-05"]}"#,
            #"{"Error": "Not a slot.", "code": "invalid_flags"}"#,
        ]
        for json in bodies {
            let (client, _) = makeClient([(json, 400)])
            do {
                _ = try await client.setItemState([RssItemStateChange(feedId: "f", sortKey: "k", isRead: true)])
                XCTFail("expected an error for \(json)")
            } catch let error as CabalmailError {
                guard case .server = error else { return XCTFail("\(error) for \(json)") }
            }
        }
    }
}
