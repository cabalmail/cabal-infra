import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// A feed's sync and a "Load older items" can overlap (the list's refresh
/// as it opens, the poller, the sidebar), and each used to write back the
/// whole cursor row it read when it started, putting back the other's
/// progress (#1938): a sync finishing after a load older restored the older
/// cursor, so the next "Load older items" fetched the same page again, or
/// showed the button again after it had reached the end.
final class RssSyncCursorOverlapTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!
    private var client: FakeRssClient!
    private var engine: RssSyncEngine!
    private let subscription = RssSubscription(subscriptionId: "s1", feedId: "f1")

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-cursors-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        client = FakeRssClient()
        await client.set(emptyPagesByDefault: true)
        engine = RssSyncEngine(client: client, store: store)
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        try await engine.refreshCatalog()
        // Populated: a since cursor, a state cursor, and older history at "o1".
        try await store.setSyncState(feedId: "f1", .init(sinceCursor: "k1", olderCursor: "o1", stateCursor: "c1"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func older(_ key: String) -> RssItem {
        RssItem(feedId: "f1", itemId: key, sortKey: key, publishedAt: "2026-01-01T00:00:00Z")
    }

    func testALoadOlderDuringASyncKeepsItsCursor() async throws {
        let (engine, client, store, subscription) = (self.engine!, self.client!, self.store!, self.subscription)
        await client.holdNext(.sync("s1"))
        let sync = Task { try await engine.syncItems(for: subscription) }
        try await waitUntil { await client.isHolding(.sync("s1")) }

        await client.set(listPages: [RssItemsPage(items: [older("a")], nextCursor: "o2")])
        _ = try await engine.loadOlder(for: subscription)
        await client.release(.sync("s1"))
        _ = try await sync.value

        let state = try await store.syncState(feedId: "f1")
        XCTAssertEqual(state.olderCursor, "o2", "the sync left load older's progress alone")
        XCTAssertFalse(state.olderExhausted)
    }

    func testASyncDuringALoadOlderKeepsItsCursors() async throws {
        let (engine, client, store, subscription) = (self.engine!, self.client!, self.store!, self.subscription)
        await client.set(listPages: [RssItemsPage(items: [older("a")], nextCursor: nil)])
        await client.holdNext(.list)
        let loading = Task { try await engine.loadOlder(for: subscription) }
        try await waitUntil { await client.isHolding(.list) }

        await client.set(syncPages: [RssSyncPage(items: [], nextSince: "k2", hasMore: false)])
        await client.set(statePages: [RssStateSyncPage(states: [], nextSince: "c2", hasMore: false)])
        _ = try await engine.syncItems(for: subscription)
        await client.release(.list)
        _ = try await loading.value

        let state = try await store.syncState(feedId: "f1")
        XCTAssertEqual(state.sinceCursor, "k2", "load older left the sync's progress alone")
        XCTAssertEqual(state.stateCursor, "c2")
        XCTAssertTrue(state.olderExhausted, "and recorded its own")
    }
}
