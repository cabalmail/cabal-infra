import XCTest
import CabalmailKit
@testable import CabalmailUI

/// How the feed view models follow the store (`FeedStoreChanges.follow`): a
/// write reaches every follower with what it changed, a follower stops with
/// its task or its store, and a burst that arrives while a batch is being
/// applied is merged into one more batch rather than one per write.
@MainActor
final class FeedStoreChangesTests: XCTestCase {
    private var directory: URL!
    private var store: RssStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-store-changes-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s", feedId: "f"))
        try await store.upsertItems([RssItem(feedId: "f", subscriptionId: "s", itemId: "i1", sortKey: "k1")])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Collects what one follower is handed.
    private final class Seen {
        var batches: [FeedChangeBatch] = []
    }

    /// Starts a follower on its own subscription and returns once it is
    /// subscribed, so no write made after this is missed.
    private func follow(into seen: Seen) async -> Task<Void, Never> {
        let changes = await store.changes()
        return Task { await FeedStoreChanges.follow(changes) { seen.batches.append($0) } }
    }

    func testAWriteReachesEveryFollowerWithWhatItChanged() async throws {
        let first = Seen(), second = Seen()
        let followers = [await follow(into: first), await follow(into: second)]

        try await store.setRead(feedId: "f", sortKey: "k1", true)

        try await waitUntilOnMainActor { first.batches.count == 1 && second.batches.count == 1 }
        for seen in [first, second] {
            XCTAssertEqual(seen.batches, [FeedChangeBatch(items: ["f#k1"])])
        }
        followers.forEach { $0.cancel() }
    }

    func testAFollowerStopsWithItsTask() async throws {
        let seen = Seen()
        let follower = await follow(into: seen)

        follower.cancel()
        await follower.value
        try await store.setRead(feedId: "f", sortKey: "k1", true)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(seen.batches, [], "a follower whose view went hears nothing more")
    }

    func testAFollowerStopsWhenTheStreamEnds() async {
        let (changes, continuation) = AsyncStream<RssStore.Change>.makeStream()
        let follower = Task { await FeedStoreChanges.follow(changes) { _ in } }

        continuation.finish()

        await follower.value
    }

    /// A sync writes pages, cursors and states in quick succession; what
    /// arrives while the last batch is still being applied becomes one more
    /// batch, so the list re-reads twice, not once per write.
    func testABurstWhileABatchIsAppliedIsMergedIntoOneMore() async throws {
        let (changes, continuation) = AsyncStream<RssStore.Change>.makeStream()
        let seen = Seen()
        let gate = Gate()
        let follower = Task {
            await FeedStoreChanges.follow(changes) { batch in
                seen.batches.append(batch)
                if seen.batches.count == 1 { await gate.wait() }
            }
        }

        continuation.yield(.items(["f#k1"]))
        try await waitUntilOnMainActor { seen.batches.count == 1 }
        continuation.yield(.feeds(["f"]))
        continuation.yield(.items(["f#k2"]))
        continuation.yield(.catalog)
        continuation.yield(.feeds(["g"]))
        // Let the follower take all four before the first batch finishes.
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        try await waitUntilOnMainActor { seen.batches.count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(seen.batches, [
            FeedChangeBatch(items: ["f#k1"]),
            FeedChangeBatch(items: ["f#k2"], feeds: ["f", "g"], catalog: true),
        ])
        follower.cancel()
    }
}

/// Holds the first batch's apply until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
