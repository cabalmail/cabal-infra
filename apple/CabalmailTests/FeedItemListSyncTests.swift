import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The item list's refresh goes through the engine's scope sync: the feeds in
/// scope four at a time, each one tried whatever another one does, then the
/// pending queue. It used to sync one feed at a time and stop at the first
/// failure, which skipped every feed after it and the drain.
@MainActor
final class FeedItemListSyncTests: XCTestCase {
    private var directory: URL!
    private var store: RssStore!
    private var rss: FakeRssClient!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-list-sync-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        rss = FakeRssClient()
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s2", feedId: "f2"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAFailingFeedDoesNotStopTheRestOrTheDrain() async throws {
        try await store.upsertItems([RssItem(feedId: "f2", subscriptionId: "s2", itemId: "i1", sortKey: "k1")])
        try await store.setRead(feedId: "f2", sortKey: "k1", true)
        await rss.set(itemsError: CabalmailError.network("The request timed out."), forSubscription: "s1")
        let model = try makeModel(scope: .all)

        await model.sync()

        let synced = await rss.syncedSubscriptions
        XCTAssertEqual(synced, ["s2"], "s2 synced although s1, before it, failed")
        let pending = try await store.pendingCount()
        XCTAssertEqual(pending, 0, "the queue drained although a feed failed")
        XCTAssertEqual(model.errorMessage, "Couldn't reach the server. The request timed out.")
    }

    func testASuccessfulSyncClearsAnEarlierError() async throws {
        let model = try makeModel(scope: .all)
        await rss.set(itemsError: CabalmailError.network("The request timed out."))
        await model.sync()
        XCTAssertNotNil(model.errorMessage)

        await rss.set(itemsError: nil)
        await model.sync()

        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Helpers

    private func makeModel(scope: RssItemScope) throws -> FeedItemListViewModel {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        return FeedItemListViewModel(
            scope: scope, subscription: nil,
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            preferences: preferences, bus: FeedStateBus(),
            store: store, engine: RssSyncEngine(client: rss, store: store)
        )
    }
}
