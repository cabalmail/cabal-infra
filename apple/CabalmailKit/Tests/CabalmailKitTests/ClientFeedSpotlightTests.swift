import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// The client the app's factory builds gives its feed items to Spotlight:
/// its feed engine is wired to its indexer, the indexer's queue is being
/// worked off, and a sign-out stops the indexer before it wipes the index.
///
/// The index is a recording fake handed to the factory, so these run on
/// every platform and never touch the device's own index.
final class ClientFeedSpotlightTests: XCTestCase {
    private var root: URL!
    private var index: FakeSearchableIndex!
    private var client: CabalmailClient!

    private let subscription = RssSubscription(subscriptionId: "s1", feedId: "f1")
    private let item = RssItemText(feedId: "f1", sortKey: "k1", title: "One")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-feed-spotlight-\(UUID().uuidString)")
        index = FakeSearchableIndex()
        // The server's catalog is empty: whatever the device holds has left.
        let catalog = try JSONEncoder().encode(RssCatalog(folders: [], subscriptions: []))
        client = try CabalmailClient.make(
            configuration: TestFixtures.makeConfiguration(),
            secureStore: InMemorySecureStore(),
            httpTransport: ScriptedHTTPTransport { request in
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil
                )
                return (catalog, try XCTUnwrap(response))
            },
            cacheDirectory: root,
            searchableIndex: index
        )
        let auth = try XCTUnwrap(client.authService as? CognitoAuthService)
        try await auth.adopt(tokens: AuthTokens(
            idToken: "ID", accessToken: "ACCESS", refreshToken: "REFRESH",
            expiresAt: Date().addingTimeInterval(3600)
        ))
    }

    override func tearDown() async throws {
        await client.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    /// A feed that leaves in a catalog refresh, through the client's own
    /// engine, has its items deleted from the client's own index.
    func testTheFactoryWiresTheFeedEngineToTheIndex() async throws {
        let store = try XCTUnwrap(client.rssStore)
        try await store.upsertSubscription(subscription)

        let diff = try await XCTUnwrap(client.rssSync).refreshCatalog()

        XCTAssertEqual(diff.removedFeedIds, ["f1"])
        try await waitUntil { await self.index.deletedDomains.count == 1 }
        let domains = await index.deletedDomains
        XCTAssertEqual(domains, [[SpotlightFeedItemRef.domainIdentifier(feedID: "f1")]])
    }

    /// The session-start refresh gives the index what the feed store holds.
    func testTheSessionStartRefreshGivesTheStoredItems() async throws {
        let store = try XCTUnwrap(client.rssStore)
        try await store.upsertSubscription(subscription)
        try await store.upsertItems([RssItem(feedId: "f1", itemId: "i1", sortKey: "k1", title: "One")])

        await client.refreshSpotlightIndex()

        let refs = await index.indexedFeedEntries.map(\.ref)
        XCTAssertEqual(refs, [SpotlightFeedItemRef(feedID: "f1", sortKey: "k1")])
    }

    /// A sign-out wipes the index and leaves the ending session's indexer
    /// taking nothing: what a sync still in flight stores afterwards does
    /// not come back into the index the next account searches.
    func testASignOutStopsTheIndexerAndWipesTheIndex() async throws {
        let feeds = try XCTUnwrap(client.spotlightIndexer).feeds
        await feeds.index([item])

        await client.clearLocalDataEndingSession()
        await feeds.index([item])

        // The wipe arrives twice, once from the sign-out and once from the
        // envelope cache's own clear, so only its place is pinned.
        let operations = await index.operations
        XCTAssertEqual(operations.prefix(2), ["feed", "all"])
        XCTAssertEqual(operations.filter { $0 == "feed" }.count, 1, "\(operations)")
    }

    /// The control: a client that carries on (a new account's, clearing what
    /// another user left behind) wipes the index and goes on indexing.
    func testClearingWithoutEndingTheSessionKeepsIndexing() async throws {
        let feeds = try XCTUnwrap(client.spotlightIndexer).feeds
        await feeds.index([item])

        await client.clearLocalData()
        await feeds.index([item])

        let operations = await index.operations
        XCTAssertEqual(operations.prefix(2), ["feed", "all"])
        XCTAssertEqual(operations.filter { $0 == "feed" }.count, 2, "\(operations)")
    }
}
