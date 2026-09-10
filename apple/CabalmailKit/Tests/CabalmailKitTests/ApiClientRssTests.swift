import XCTest
@testable import CabalmailKit

/// Wire-level tests for the RSS endpoints (`docs/rss.md`) on
/// `URLSessionApiClient`: request shapes, response decoding, and the error
/// envelope's `code` token surfacing through `CabalmailError.server`.
final class ApiClientRssTests: XCTestCase {
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

    private func queryItems(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private let catalogJson = """
    {"folders": [{"folder_id": "f1", "parent_folder_id": "", "name": "Tech", "display_order": 2}],
     "subscriptions": [{"subscription_id": "s1", "feed_id": "feed-1", "folder_id": "f1",
       "custom_title": "", "ordering_mode": "oldest_first", "default_open_mode": "article",
       "default_styling": "native", "notifications_enabled": true, "credentials_scheme": "",
       "read_watermark": "2026-09-09T00:00:00+00:00", "data_store_uuid": "D", "created_at": "c",
       "feed": {"feed_id": "feed-1", "canonical_url": "https://x.test/feed", "feed_type": "atom",
                "title": "X", "item_count": 12, "last_status_code": 304, "dead_lettered": false,
                "some_future_field": 1}}]}
    """

    func testListSubscriptionsDecodesCatalog() async throws {
        let (client, http) = makeClient([(catalogJson, 200)])
        let catalog = try await client.listSubscriptions()
        XCTAssertEqual(catalog.folders,
                       [RssFolder(folderId: "f1", parentFolderId: "", name: "Tech", displayOrder: 2)])
        let sub = catalog.subscriptions[0]
        XCTAssertEqual(sub.orderingMode, .oldestFirst)
        XCTAssertEqual(sub.defaultOpenMode, .article)
        XCTAssertEqual(sub.defaultStyling, .native)
        XCTAssertTrue(sub.notificationsEnabled)
        XCTAssertEqual(sub.feed?.title, "X")
        XCTAssertEqual(sub.feed?.itemCount, 12)
        XCTAssertEqual(sub.displayTitle, "X")
        let requests = await http.requests
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertTrue(requests[0].url!.path.hasSuffix("/rss_list_subscriptions"))
    }

    func testUnknownEnumValuesFallBackToDefaults() async throws {
        let json = """
        {"folders": [], "subscriptions": [{"subscription_id": "s", "feed_id": "f", "ordering_mode": "spiral"}]}
        """
        let (client, _) = makeClient([(json, 200)])
        let sub = try await client.listSubscriptions().subscriptions[0]
        XCTAssertEqual(sub.orderingMode, .newestFirst)
        XCTAssertEqual(sub.folderId, "")
        XCTAssertNil(sub.feed)
    }

    func testSubscribePostsUrlAndFolder() async throws {
        let json = #"{"subscription": {"subscription_id": "s", "feed_id": "f"}, "existing": false}"#
        let (client, http) = makeClient([(json, 200)])
        let result = try await client.subscribe(url: "https://x.test/feed", folderId: "fo")
        XCTAssertFalse(result.existing)
        let requests = await http.requests
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertTrue(requests[0].url!.path.hasSuffix("/rss_subscribe"))
        XCTAssertEqual(body(requests[0])["url"] as? String, "https://x.test/feed")
        XCTAssertEqual(body(requests[0])["folder_id"] as? String, "fo")
    }

    func testErrorEnvelopeCodeSurfaces() async throws {
        let json = #"{"Error": "That page does not advertise a feed.", "code": "not_a_feed"}"#
        let (client, _) = makeClient([(json, 400)])
        do {
            _ = try await client.subscribe(url: "https://x.test/", folderId: nil)
            XCTFail("expected an error")
        } catch let CabalmailError.server(code, message) {
            XCTAssertEqual(code, "not_a_feed")
            XCTAssertEqual(message, "That page does not advertise a feed.")
        }
    }

    func testListItemsQueryAndSyncQuery() async throws {
        let page = """
        {"items": [{"feed_id": "f", "sort_key": "2026#i1", "title": "T", "is_read": true}], "next_cursor": "c2"}
        """
        let sync = #"{"items": [], "next_since": "k9", "has_more": false}"#
        let (client, http) = makeClient([(page, 200), (sync, 200)])
        let listed = try await client.listItems(scope: .folder("fo"), filter: .unread, order: .oldest,
                                                limit: 25, cursor: "c1")
        XCTAssertEqual(listed.items[0].title, "T")
        XCTAssertTrue(listed.items[0].isRead)
        XCTAssertEqual(listed.nextCursor, "c2")
        let synced = try await client.syncItems(subscriptionId: "s", since: "", limit: 100)
        XCTAssertEqual(synced.nextSince, "k9")
        XCTAssertFalse(synced.hasMore)
        let requests = await http.requests
        XCTAssertEqual(queryItems(requests[0]),
                       ["folder_id": "fo", "filter": "unread", "order": "oldest", "limit": "25", "cursor": "c1"])
        XCTAssertEqual(queryItems(requests[1]), ["subscription_id": "s", "since": "", "limit": "100"])
    }

    func testSetItemStateAndMarkAllReadBodies() async throws {
        let (client, http) = makeClient([
            (#"{"updated": 2}"#, 200),
            (#"{"subscriptions": 1, "flipped": 0, "read_watermark": "w"}"#, 200),
        ])
        let updated = try await client.setItemState([
            RssItemStateChange(feedId: "f", sortKey: "k1", isRead: true, isFavorite: true),
            RssItemStateChange(feedId: "f", sortKey: "k2", isFavorite: false),
        ])
        XCTAssertEqual(updated, 2)
        let mark = try await client.markAllRead(scope: .subscription("s"))
        XCTAssertEqual(mark.readWatermark, "w")
        let requests = await http.requests
        let items = body(requests[0])["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0]["is_read"] as? Bool, true)
        XCTAssertNil(items?[1]["is_read"])
        XCTAssertEqual(items?[1]["is_favorite"] as? Bool, false)
        XCTAssertEqual(body(requests[1])["subscription_id"] as? String, "s")
    }

    func testUpdateSubscriptionSendsOnlyChangedFields() async throws {
        let json = #"{"subscription": {"subscription_id": "s", "feed_id": "f", "folder_id": ""}}"#
        let (client, http) = makeClient([(json, 200)])
        _ = try await client.updateSubscription("s", RssSubscriptionUpdate(folderId: "", notificationsEnabled: true))
        let requests = await http.requests
        let sent = body(requests[0])
        XCTAssertEqual(sent["subscription_id"] as? String, "s")
        XCTAssertEqual(sent["folder_id"] as? String, "")
        XCTAssertEqual(sent["notifications_enabled"] as? Bool, true)
        XCTAssertNil(sent["custom_title"])
        XCTAssertEqual(requests[0].httpMethod, "PUT")
    }

    func testOpmlRoundTrip() async throws {
        let export = #"{"opml": "<opml/>", "filename": "cabalmail-feeds-20260910.opml"}"#
        let imported = """
        {"created": 1, "existing": 2, "folders_created": 0,
         "failed": [{"url": "ftp://x", "code": "invalid_url", "Error": "no"}]}
        """
        let (client, http) = makeClient([(export, 200), (imported, 200)])
        let exported = try await client.exportOpml()
        XCTAssertEqual(exported.filename, "cabalmail-feeds-20260910.opml")
        let result = try await client.importOpml("<opml/>", folderId: nil)
        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.existing, 2)
        XCTAssertEqual(result.failed[0].message, "no")
        let requests = await http.requests
        XCTAssertEqual(body(requests[1])["opml"] as? String, "<opml/>")
    }
}
