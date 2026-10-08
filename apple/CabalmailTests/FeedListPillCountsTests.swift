import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The feed list's All / Unread / Flagged pills count the scope's items, as
/// the message list's count the folder's, and the counts follow a mark made
/// in the list or anywhere else.
@MainActor
final class FeedListPillCountsTests: XCTestCase {
    private var directory: URL!
    private var store: RssStore!
    private var follower: Task<Void, Never>?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-pill-counts-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .all))
        try await store.upsertItems(["k1", "k2", "k3"].map {
            RssItem(feedId: "f", subscriptionId: "s", itemId: $0, sortKey: $0,
                    publishedAt: "2026-01-01T00:00:00Z")
        })
        try await store.setFavorite(feedId: "f", sortKey: "k3", true)
    }

    override func tearDown() async throws {
        follower?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() throws -> FeedItemListViewModel {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        return FeedItemListViewModel(
            scope: .subscription("s"), subscription: RssSubscription(subscriptionId: "s", feedId: "f"),
            client: try TestFixtures.makeClient(imap: FakeImapClient()), preferences: preferences,
            store: store, engine: RssSyncEngine(client: FakeRssClient(), store: store)
        )
    }

    func testThePillsCountTheScope() async throws {
        let model = try makeModel()

        await model.reload()

        XCTAssertEqual(model.filterCounts, RssStore.FilterCounts(all: 3, unread: 3, favorite: 1))
    }

    func testTheCountsFollowAMarkMadeInTheList() async throws {
        let model = try makeModel()
        await model.reload()
        let item = try XCTUnwrap(model.items.first { $0.sortKey == "k1" })

        await model.setRead(item, true)
        XCTAssertEqual(model.filterCounts, RssStore.FilterCounts(all: 3, unread: 2, favorite: 1))

        await model.setFavorite(item, true)
        XCTAssertEqual(model.filterCounts, RssStore.FilterCounts(all: 3, unread: 2, favorite: 2))
    }

    func testTheCountsFollowAMarkMadeElsewhere() async throws {
        let model = try makeModel()
        follower = Task { await model.observe() }
        try await waitUntilOnMainActor { model.filterCounts?.all == 3 }

        try await store.setRead(feedId: "f", sortKey: "k2", true)

        try await waitUntilOnMainActor { model.filterCounts?.unread == 2 }
    }
}
