import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A feed list sync whose own task is cancelled paints nothing (#1908).
///
/// The list syncs from its `.task(id: scope)`, which SwiftUI cancels when the
/// list leaves the screen mid-sync (a pushed reader or a tab switch on
/// iPhone, a scope change), and from a pull that can be cut short. The
/// cancelled request used to put "Couldn't reach the server. cancelled." over
/// a list that was fine. The store is still re-read, since what synced before
/// the cancel has landed, and the store announces that to the other views.
/// The next appearance re-syncs on its own: the list's `.task` builds a fresh
/// model every time.
@MainActor
final class FeedItemListSyncCancellationTests: XCTestCase {
    private var directory: URL!
    private var store: RssStore!
    private var rss: FakeRssClient!
    private let subscription = RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .all)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-list-cancel-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        rss = FakeRssClient()
        try await store.upsertSubscription(subscription)
        try await store.upsertItems([
            RssItem(feedId: "f", subscriptionId: "s", itemId: "i1", sortKey: "k1", title: "Cached",
                    publishedAt: "2026-10-01T00:00:00Z"),
        ])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testASyncCancelledMidFetchPaintsNoError() async throws {
        let shapes: [any Error & Sendable] = [
            CabalmailError.cancelled, CabalmailError.network("cancelled"), CancellationError(),
        ]
        for shape in shapes {
            await rss.set(cancelledError: shape)
            let model = try makeModel()
            let before = await rss.itemsCalls

            try await syncCutShort(model)

            XCTAssertNil(model.errorMessage, "\(shape)")
            XCTAssertFalse(model.isSyncing, "\(shape)")
            let after = await rss.itemsCalls
            XCTAssertGreaterThan(after, before, "\(shape): the sync reached the wire")
        }
    }

    /// The `.task` rebuilt mid-transition: a sync started in a task that is
    /// already cancelled.
    func testASyncStartedInAnAlreadyCancelledTaskPaintsNoError() async throws {
        let model = try makeModel()

        let sync = Task { await model.sync() }
        sync.cancel()
        await sync.value

        XCTAssertNil(model.errorMessage)
    }

    func testAnEarlierErrorSurvivesACancelledSync() async throws {
        let model = try makeModel()
        await rss.set(itemsError: CabalmailError.network("The request timed out."))
        await model.sync()
        XCTAssertEqual(model.errorMessage, "Couldn't reach the server. The request timed out.")
        await rss.set(itemsError: nil)

        try await syncCutShort(model)

        XCTAssertEqual(model.errorMessage, "Couldn't reach the server. The request timed out.",
                       "a cancelled attempt says nothing about reachability")
    }

    /// A cancelled sync still re-reads the store, and what synced before the
    /// cancel is announced by the store, so it shows here and in the
    /// sidebar's badges. Two feeds: the one whose call is held is cut short,
    /// the other finishes first.
    func testACancelledSyncStillReadsTheStoreAndWhatLandedIsAnnounced() async throws {
        try await store.upsertSubscription(RssSubscription(subscriptionId: "t", feedId: "g", defaultFilter: .all))
        let model = try makeModel(scope: .all)
        let changes = await store.changes()
        let rss = try XCTUnwrap(rss)
        await rss.holdNext(.items)
        let sync = Task { await model.sync() }
        try await waitUntil { await rss.isHolding(.items) }
        // The other feed's sync ends with its cursors, which the store announces.
        let store = try XCTUnwrap(store)
        try await waitUntil {
            let synced = [try await store.syncState(feedId: "f"), try await store.syncState(feedId: "g")]
            return synced.contains { !$0.lastSyncedAt.isEmpty }
        }
        sync.cancel()
        await rss.releaseHeld(.items)
        await sync.value

        XCTAssertEqual(model.items.map(\.itemId), ["i1"])
        let announced = await bufferedElements(changes)
        var feeds: Set<String> = []
        for change in announced {
            guard case .feeds(let ids) = change else { return XCTFail("\(announced)") }
            feeds.formUnion(ids)
        }
        // A feed's sync may announce more than once (its first page, then its
        // cursors); what matters is which feeds it named.
        XCTAssertEqual(feeds.count, 1, "the feed that finished before the cancel, not the one cut short: \(announced)")
    }

    /// The control: an uncancelled failure is still shown.
    func testARealFailureIsStillShown() async throws {
        let model = try makeModel()
        await rss.set(itemsError: CabalmailError.network("The request timed out."))

        await model.sync()

        XCTAssertEqual(model.errorMessage, "Couldn't reach the server. The request timed out.")
    }

    // MARK: - Helpers

    private func makeModel(scope: RssItemScope = .subscription("s")) throws -> FeedItemListViewModel {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        return FeedItemListViewModel(
            scope: scope, subscription: scope == .subscription("s") ? subscription : nil,
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            preferences: preferences,
            store: store, engine: RssSyncEngine(client: rss, store: store)
        )
    }

    /// Runs a sync in a task that is cancelled while its first items call is
    /// out, the way SwiftUI cancels the list's `.task`.
    private func syncCutShort(_ model: FeedItemListViewModel) async throws {
        let rss = try XCTUnwrap(rss)
        await rss.holdNext(.items)
        let sync = Task { await model.sync() }
        try await waitUntil { await rss.isHolding(.items) }
        XCTAssertTrue(model.isSyncing)
        sync.cancel()
        await rss.releaseHeld(.items)
        await sync.value
    }
}
