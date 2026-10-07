import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A Feeds sidebar refresh whose own task is cancelled is no outcome (#1908).
///
/// Both sidebars refresh from a `.task` that SwiftUI cancels when the sidebar
/// leaves the screen mid-sync (a tab switch, a push on iPhone, the iPad
/// sidebar hidden). The cancelled request used to paint "Couldn't reach the
/// server. cancelled." (or, during the sync, count as every feed failing), and
/// since both views keep the model and only built it once, the line stayed
/// until a manual refresh. Now a cut-short refresh paints nothing and is owed,
/// and the next appearance's `refreshIfNeeded` pays it.
@MainActor
final class FeedSidebarRefreshCancellationTests: XCTestCase {
    private var directories: [URL] = []
    private var rss: FakeRssClient!
    private var model: FeedSidebarViewModel!

    override func setUp() async throws {
        try await makeWorld()
    }

    override func tearDown() async throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A fresh store and client: one subscription in the catalog.
    private func makeWorld() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-sidebar-cancel-\(UUID().uuidString)")
        directories.append(directory)
        let store = try RssStore(directory: directory)
        rss = FakeRssClient()
        await rss.set(catalog: RssCatalog(folders: [], subscriptions: [
            RssSubscription(
                subscriptionId: "sub-1", feedId: "feed-1",
                feed: RssFeedSummary(feedId: "feed-1", canonicalUrl: "https://example.com/feed", title: "Example")
            ),
        ]))
        let engine = RssSyncEngine(client: rss, store: store)
        model = FeedSidebarViewModel(store: store, engine: engine, bus: FeedStateBus())
    }

    // MARK: - A cut-short refresh is no outcome

    func testACancelDuringTheCatalogPaintsNothingAndIsOwed() async throws {
        let shapes: [any Error & Sendable] = [
            CabalmailError.cancelled, CabalmailError.network("cancelled"), CancellationError(),
        ]
        for shape in shapes {
            try await makeWorld()
            await rss.set(cancelledError: shape)

            try await refreshCutShort(at: .catalog)

            XCTAssertNil(model.errorMessage, "\(shape)")
            XCTAssertTrue(model.needsRefresh, "\(shape)")
            XCTAssertFalse(model.isRefreshing, "\(shape)")
            let calls = await rss.catalogCalls
            XCTAssertEqual(calls, 1, "\(shape): a cancelled refresh asks nothing more of the server")
        }
    }

    func testACancelDuringTheFeedSyncIsNotEveryFeedFailing() async throws {
        try await refreshCutShort(at: .items)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.needsRefresh)
        XCTAssertEqual(model.subscriptions.map(\.subscriptionId), ["sub-1"], "what landed before the cancel is shown")
    }

    func testARefreshCutShortAfterASuccessIsOwedAgain() async throws {
        await model.refresh()
        XCTAssertFalse(model.needsRefresh)

        try await refreshCutShort(at: .catalog)

        XCTAssertTrue(model.needsRefresh)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - The next appearance

    func testTheNextAppearanceTakesTheRefreshOver() async throws {
        try await refreshCutShort(at: .catalog)
        XCTAssertTrue(model.subscriptions.isEmpty)

        await model.refreshIfNeeded()

        XCTAssertEqual(model.subscriptions.map(\.subscriptionId), ["sub-1"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.needsRefresh)
        let calls = await rss.catalogCalls
        await model.refreshIfNeeded()
        let again = await rss.catalogCalls
        XCTAssertEqual(again, calls, "a finished refresh isn't repeated on every appearance")
    }

    /// The appearance's `.task` arrives while the cancelled refresh's pass is
    /// still unwinding. The cancelled refresh stopped waiting for it at once;
    /// the appearance is not folded into that dead pass but waits for it to
    /// end and then gets a pass of its own.
    func testAnAppearanceDuringTheCancelledRefreshWaitsAndThenRefreshes() async throws {
        let rss = try XCTUnwrap(rss)
        await rss.holdNext(.catalog)
        let first = Task { await model.refresh() }
        try await waitUntil { await rss.isHolding(.catalog) }
        first.cancel()
        await first.value
        XCTAssertTrue(model.needsRefresh)
        let next = Task { await model.refreshIfNeeded() }
        try await waitUntilOnMainActor { self.model.isRefreshing }
        let stillUnwinding = await rss.isHolding(.catalog)
        XCTAssertTrue(stillUnwinding)

        await rss.releaseHeld(.catalog)
        await next.value

        XCTAssertEqual(model.subscriptions.map(\.subscriptionId), ["sub-1"])
        XCTAssertFalse(model.needsRefresh)
        XCTAssertNil(model.errorMessage)
        let calls = await rss.catalogCalls
        XCTAssertEqual(calls, 2, "the dead pass's catalog, then the appearance's own")
    }

    /// The control: arriving during a live refresh, it waits and then does
    /// nothing, since that refresh reaches an outcome.
    func testAnAppearanceDuringALiveRefreshWaitsAndAddsNothing() async throws {
        let rss = try XCTUnwrap(rss)
        await rss.holdNext(.catalog)
        let live = Task { await model.refresh() }
        try await waitUntil { await rss.isHolding(.catalog) }
        let next = Task { await model.refreshIfNeeded() }
        try await waitUntilOnMainActor { self.model.waitingRefreshCount == 1 }

        await rss.releaseHeld(.catalog)
        await live.value
        await next.value

        let calls = await rss.catalogCalls
        XCTAssertEqual(calls, 1, "the live refresh's one catalog fetch, and no second refresh")
        XCTAssertFalse(model.needsRefresh)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Real failures are still shown

    func testARealCatalogFailureIsStillShownAndEndsTheAttempt() async {
        await rss.set(catalogError: CabalmailError.network("The Internet connection appears to be offline."))

        await model.refresh()

        XCTAssertEqual(model.errorMessage, "Couldn't reach the server. The Internet connection appears to be offline.")
        XCTAssertFalse(model.needsRefresh)
    }

    func testEveryFeedReallyFailingStillShowsOneLine() async {
        await rss.set(itemsError: CabalmailError.network("The request timed out."))

        await model.refresh()

        XCTAssertEqual(model.errorMessage, "Couldn't reach the server. The request timed out.")
        XCTAssertFalse(model.needsRefresh)
    }

    /// #1904: a failed drain of the pending queue is not a feed, so one feed
    /// of two failing plus the queue failing is not "every feed failed".
    func testSomeFeedsAndTheQueueFailingIsNotEveryFeedFailing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-sidebar-1904-\(UUID().uuidString)")
        directories.append(directory)
        let store = try RssStore(directory: directory)
        await rss.set(catalog: RssCatalog(folders: [], subscriptions: [
            RssSubscription(subscriptionId: "sub-1", feedId: "feed-1"),
            RssSubscription(subscriptionId: "sub-2", feedId: "feed-2"),
        ]))
        try await store.upsertItems([RssItem(feedId: "feed-1", itemId: "i1", sortKey: "k1")])
        try await store.setRead(feedId: "feed-1", sortKey: "k1", true)
        await rss.set(itemsError: CabalmailError.network("The request timed out."), forSubscription: "sub-2")
        await rss.set(pushError: CabalmailError.network("The request timed out."))
        model = FeedSidebarViewModel(store: store, engine: RssSyncEngine(client: rss, store: store),
                                     bus: FeedStateBus())

        await model.refresh()

        XCTAssertNil(model.errorMessage, "sub-1 synced; the sidebar has nothing to say")
        XCTAssertFalse(model.needsRefresh)
    }

    // MARK: - Helpers

    /// Runs a refresh in a task that is cancelled while `call` is out, the way
    /// SwiftUI cancels the sidebar's `.task`.
    private func refreshCutShort(at call: FakeRssClient.HeldCall) async throws {
        let rss = try XCTUnwrap(rss)
        await rss.holdNext(call)
        let refreshTask = Task { await model.refresh() }
        try await waitUntil { await rss.isHolding(call) }
        refreshTask.cancel()
        await rss.releaseHeld(call)
        await refreshTask.value
    }
}
