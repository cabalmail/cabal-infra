import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// Feed items in the Spotlight index (`SpotlightFeedIndexer`): what the feed
/// sync gives the index and when, the session-start sweep, a departed feed's
/// delete, and the stop a sign-out makes. What an entry says is in
/// `SpotlightFeedEntryTests`.
///
/// The index is the recording fake `SpotlightIndexerTests` uses, so nothing
/// here touches Core Spotlight.
final class SpotlightFeedIndexerTests: XCTestCase {
    private var fake: FakeSearchableIndex!
    private var indexer: SpotlightIndexer!
    private var tempDir: URL!
    private var store: RssStore!
    private var client: FakeRssClient!
    private var engine: RssSyncEngine!
    private var binding: Task<Void, Never>?

    override func setUp() async throws {
        fake = FakeSearchableIndex()
        // A suite of its own, so the one-time schema wipe is this test's.
        let name = suiteName
        indexer = SpotlightIndexer(index: fake, defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-spotlight-feeds-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        client = FakeRssClient()
        // The engine and the indexer as `CabalmailClient` wires them.
        engine = RssSyncEngine(client: client, store: store, itemIndex: indexer.feeds)
        let feeds = indexer.feeds
        binding = Task { await feeds.bind() }
    }

    override func tearDown() async throws {
        binding?.cancel()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private let suiteName = "spotlight-feed-tests-\(UUID().uuidString)"

    private func item(_ number: Int, feed: String = "f1", content: String = "") -> RssItem {
        RssItem(
            feedId: feed, itemId: "i\(number)",
            sortKey: String(format: "2026-01-%02dT00:00:00+00:00#i%d", number, number),
            title: "Item \(number)", author: "Ada",
            publishedAt: String(format: "2026-01-%02dT00:00:00+00:00", number),
            fetchedKey: String(format: "2026-02-01T00:00:%02d+00:00#i%d", number, number),
            contentHtml: content
        )
    }

    private func subscription(_ id: String, feed: String) -> RssSubscription {
        RssSubscription(subscriptionId: id, feedId: feed, feed: RssFeedSummary(feedId: feed, title: feed))
    }

    private func ref(_ item: RssItem) -> SpotlightFeedItemRef {
        SpotlightFeedItemRef(feedID: item.feedId, sortKey: item.sortKey)
    }

    /// The feed and its first page on the server; the feed's sync is the
    /// first fill.
    private func serve(_ items: [RssItem], subscriptions: [RssSubscription]) async throws {
        await client.set(catalog: RssCatalog(folders: [], subscriptions: subscriptions))
        await client.set(listPages: [RssItemsPage(items: items, nextCursor: "older")])
        await client.set(emptyPagesByDefault: true)
        try await engine.refreshCatalog()
    }

    // MARK: - The sync feeds the index

    func testASyncGivesTheIndexWhatItStored() async throws {
        let sub = subscription("s1", feed: "f1")
        try await serve([item(3, content: "<p>Three</p>"), item(2), item(1)], subscriptions: [sub])
        await client.set(syncPages: [
            RssSyncPage(items: [item(4)], nextSince: item(4).fetchedKey, hasMore: false),
        ])

        try await engine.syncItems(for: sub)

        try await waitUntil { await self.fake.indexedFeedEntries.count == 4 }
        let entries = await fake.indexedFeedEntries
        XCTAssertEqual(entries.map(\.ref), [item(3), item(2), item(1), item(4)].map(ref), "page by page, in order")
        XCTAssertEqual(entries.first?.title, "Item 3")
        XCTAssertEqual(entries.first?.textContent, "Three")
        XCTAssertEqual(entries.first?.authorNames, ["Ada"])
        let mail = await fake.indexedBatches
        XCTAssertTrue(mail.isEmpty, "a feed item is not donated as a message")
    }

    func testOlderItemsAreGivenToo() async throws {
        let sub = subscription("s1", feed: "f1")
        try await serve([item(9)], subscriptions: [sub])
        try await engine.syncItems(for: sub)
        try await waitUntil { await self.fake.indexedFeedEntries.count == 1 }
        await client.set(listPages: [RssItemsPage(items: [item(8), item(7)], nextCursor: nil)])

        let loaded = try await engine.loadOlder(for: sub)

        XCTAssertEqual(loaded, 2)
        try await waitUntil { await self.fake.indexedFeedEntries.count == 3 }
        let refs = await fake.indexedFeedEntries.map(\.ref)
        XCTAssertEqual(refs, [item(9), item(8), item(7)].map(ref))
    }

    /// The sync does not wait for the index: with nothing working the queue
    /// off, it still finishes, and the items are given once something does.
    func testASyncDoesNotWaitForTheIndex() async throws {
        // An indexer of its own, whose queue nothing reads yet.
        let unbound = SpotlightIndexer(index: fake)
        engine = RssSyncEngine(client: client, store: store, itemIndex: unbound.feeds)
        let sub = subscription("s1", feed: "f1")
        try await serve([item(1)], subscriptions: [sub])

        let received = try await engine.syncItems(for: sub)

        XCTAssertEqual(received, 1)
        let before = await fake.indexedFeedEntries
        XCTAssertTrue(before.isEmpty, "nothing has worked the queue off yet")
        let late = Task { await unbound.feeds.bind() }
        defer { late.cancel() }
        try await waitUntil { await self.fake.indexedFeedEntries.count == 1 }
    }

    #if DEBUG
    /// A page the store refuses to write (as the retired store of a session
    /// that has ended refuses every write) is not given to the index: the
    /// index is told after the store has the page, never before. The control
    /// is every other sync test here: the same engine, a store that takes
    /// the write.
    func testWhatTheStoreRefusesIsNotGiven() async throws {
        let sub = subscription("s1", feed: "f1")
        try await serve([item(1)], subscriptions: [sub])
        await store.failNextItemWriteForTests()

        do {
            try await engine.syncItems(for: sub)
            XCTFail("the sync should fail with the write")
        } catch {}

        // A marker behind it in the queue shows the queue was worked off.
        indexer.feeds.feedsRemoved(["marker"])
        try await waitUntil { await self.fake.deletedDomains.count == 1 }
        let entries = await fake.indexedFeedEntries
        XCTAssertTrue(entries.isEmpty)
        let stored = try await store.items(.init(scope: .all))
        XCTAssertTrue(stored.isEmpty, "precondition: the write was refused")
    }
    #endif

    // MARK: - A feed that leaves

    func testAFeedThatLeavesTakesItsItemsOut() async throws {
        let kept = subscription("s1", feed: "f1")
        let leaving = subscription("s2", feed: "f2")
        try await serve([item(1, feed: "f2")], subscriptions: [kept, leaving])
        try await engine.syncItems(for: leaving)
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [kept]))

        try await engine.refreshCatalog()

        try await waitUntil { await self.fake.deletedDomains.count == 1 }
        let domains = await fake.deletedDomains
        XCTAssertEqual(domains, [[SpotlightFeedItemRef.domainIdentifier(feedID: "f2")]])
        // In the order written: the items were given before they were removed.
        let operations = await fake.operations
        XCTAssertEqual(operations, ["feed", "domains"])
    }

    func testACatalogRefreshThatRemovesNothingDeletesNothing() async throws {
        let sub = subscription("s1", feed: "f1")
        try await serve([item(1)], subscriptions: [sub])

        try await engine.refreshCatalog()
        try await engine.syncItems(for: sub)

        try await waitUntil { await self.fake.indexedFeedEntries.count == 1 }
        let domains = await fake.deletedDomains
        XCTAssertTrue(domains.isEmpty)
    }

    func testSingleItemsCanBeTakenOut() async {
        let refs = [item(1), item(2)].map(ref)
        await indexer.feeds.removeItems(refs)
        await indexer.feeds.removeItems([])

        let deleted = await fake.deletedIdentifiers
        XCTAssertEqual(deleted, [refs.map(\.stringValue)])
    }

    // MARK: - The session-start sweep

    private func sweep() async throws {
        let cacheDir = tempDir.appendingPathComponent("envelopes")
        let cache = try EnvelopeCache(directory: cacheDir)
        await indexer.sweep(imap: NoFoldersImapClient(), envelopeCache: cache, feedStore: store)
    }

    /// What is already on the device is given at session start, feed by
    /// feed, from the store's own text: the items a sync will never send
    /// again. A feed with no subscription (rows a late write left) is not.
    func testTheSweepGivesEachSubscribedFeedsItems() async throws {
        try await store.upsertSubscription(subscription("s1", feed: "f1"))
        try await store.upsertSubscription(subscription("s2", feed: "f2"))
        let stored = [
            item(1, content: "<p>One <i>body</i></p>"), item(2), item(1, feed: "f2"), item(1, feed: "orphan"),
        ]
        try await store.upsertItems(stored)

        try await sweep()

        let entries = await fake.indexedFeedEntries
        XCTAssertEqual(Set(entries.map(\.ref)), Set([item(1), item(2), item(1, feed: "f2")].map(ref)))
        let one = try XCTUnwrap(entries.first { $0.ref == self.ref(self.item(1)) })
        XCTAssertEqual(one, SpotlightFeedEntry(text: RssItemText(item: stored[0]), maxTextLength: 16_384),
                       "the store's text is the text of the item in hand")
        XCTAssertEqual(one.textContent, "One body")
    }

    func testTheSweepGivesAFeedsNewestTwoHundred() async throws {
        try await store.upsertSubscription(subscription("s1", feed: "f1"))
        let items = (1...205).map { number in
            RssItem(feedId: "f1", itemId: "i\(number)", sortKey: String(format: "k%04d", number))
        }
        try await store.upsertItems(items)

        try await sweep()

        let keys = await fake.indexedFeedEntries.map(\.ref.sortKey)
        XCTAssertEqual(keys.count, 200)
        XCTAssertEqual(keys.first, "k0205", "newest first")
        XCTAssertEqual(Set(keys), Set(items.suffix(200).map(\.sortKey)), "the oldest five are left out")
    }

    /// The feeds are given after the one-time schema wipe, which would
    /// otherwise take them straight out again.
    func testTheSweepGivesFeedsAfterTheSchemaWipe() async throws {
        try await store.upsertSubscription(subscription("s1", feed: "f1"))
        try await store.upsertItems([item(1)])

        try await sweep()

        let operations = await fake.operations
        XCTAssertEqual(operations, ["all", "feed"])
    }

    func testASweepWithNoFeedStoreGivesNoFeedItems() async throws {
        try await store.upsertSubscription(subscription("s1", feed: "f1"))
        try await store.upsertItems([item(1)])
        let cache = try EnvelopeCache(directory: tempDir.appendingPathComponent("envelopes"))

        await indexer.sweep(imap: NoFoldersImapClient(), envelopeCache: cache)

        let entries = await fake.indexedFeedEntries
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Stop

    /// Once the session's indexer is stopped nothing more is indexed, feed
    /// item or message, so what a sync still in flight stores after a
    /// sign-out's wipe does not come back. Deletions still apply.
    func testAStoppedIndexerTakesNothingMore() async throws {
        let sub = subscription("s1", feed: "f1")
        try await serve([item(1)], subscriptions: [sub])
        await indexer.setSubscribedFolders(["INBOX"])
        let envelope = Envelope(uid: 1, messageId: "<1@example.test>", subject: "Hi")
        // The control: before the stop, both are taken.
        await indexer.indexEnvelopes([envelope], folder: "INBOX")
        await indexer.feeds.index([RssItemText(item: item(9))])
        var operations = await fake.operations
        XCTAssertEqual(operations, ["mail", "feed"])

        await indexer.stop()
        try await engine.syncItems(for: sub)
        await indexer.feeds.index([RssItemText(item: item(9))])
        await indexer.indexEnvelopes([envelope], folder: "INBOX")
        await indexer.indexBody(text: "body", envelope: envelope, folder: "INBOX")
        try await sweep()
        await indexer.feeds.removeFeeds(["f1"])
        await indexer.removeAll()

        // The delete went through the queue behind the sync's items, so the
        // queue has been worked off by the time it shows.
        indexer.feeds.feedsRemoved(["marker"])
        try await waitUntil { await self.fake.deletedDomains.count == 2 }
        operations = await fake.operations
        XCTAssertEqual(operations, ["mail", "feed", "domains", "all", "domains"])
    }

    /// A stop that comes while a donation is in flight stops the batches
    /// behind it.
    func testAStopBetweenBatchesStopsTheRest() async throws {
        let holding = HoldingIndex()
        let indexer = SpotlightIndexer(index: holding)
        let items = (1...450).map { RssItemText(feedId: "f1", sortKey: "k\($0)") }

        let donation = Task { await indexer.feeds.index(items) }
        try await waitUntil { await holding.isHolding }
        await indexer.stop()
        await holding.release()
        await donation.value

        let batches = await holding.batchSizes
        XCTAssertEqual(batches, [200], "450 items are three batches; the stop left one")
    }

    /// The control for the arm above: without a stop, every batch goes.
    func testEveryBatchGoesWhenNothingStopsIt() async throws {
        let holding = HoldingIndex()
        let indexer = SpotlightIndexer(index: holding)
        let items = (1...450).map { RssItemText(feedId: "f1", sortKey: "k\($0)") }

        let donation = Task { await indexer.feeds.index(items) }
        try await waitUntil { await holding.isHolding }
        await holding.release()
        await donation.value

        let batches = await holding.batchSizes
        XCTAssertEqual(batches, [200, 200, 50])
    }
}

/// An index whose first feed donation waits until released.
private actor HoldingIndex: SearchableIndexing {
    nonisolated var isAvailable: Bool { true }
    private var held: CheckedContinuation<Void, Never>?
    private(set) var batchSizes: [Int] = []

    var isHolding: Bool { held != nil }

    func release() {
        held?.resume()
        held = nil
    }

    func index(_ entries: [SpotlightEntry]) async throws {}

    func indexFeedItems(_ entries: [SpotlightFeedEntry]) async throws {
        batchSizes.append(entries.count)
        if batchSizes.count == 1 { await withCheckedContinuation { held = $0 } }
    }

    func deleteIdentifiers(_ identifiers: [String]) async throws {}
    func deleteDomains(_ domains: [String]) async throws {}
    func deleteAll() async throws {}
}

/// An `ImapClient` with no folder list to give, so a sweep's mail half does
/// nothing and its feed half is what a test sees.
private struct NoFoldersImapClient: ImapClient {
    func listFolders() async throws -> [Folder] { throw CabalmailError.cancelled }
    func createFolder(name: String, parent: String?) async throws { throw CabalmailError.cancelled }
    func deleteFolder(path: String) async throws { throw CabalmailError.cancelled }
    func subscribe(path: String) async throws { throw CabalmailError.cancelled }
    func unsubscribe(path: String) async throws { throw CabalmailError.cancelled }
    func status(path: String, flagged: Bool) async throws -> FolderStatus { throw CabalmailError.cancelled }

    func topEnvelopes(
        folder: String, limit: UInt32, totalMessages: UInt32, sort: SortCriterion
    ) async throws -> [Envelope] { throw CabalmailError.cancelled }

    func fetchBody(folder: String, uid: UInt32) async throws -> RawMessage { throw CabalmailError.cancelled }

    func setFlags(
        folder: String, uids: [UInt32], flags: Set<Flag>, operation: FlagOperation
    ) async throws { throw CabalmailError.cancelled }

    func move(
        folder: String, uids: [UInt32], destination: String, markSeen: Bool
    ) async throws { throw CabalmailError.cancelled }
}

#if DEBUG
private extension RssStore {
    /// Arms this store's connection to fail its next write to the items.
    func failNextItemWriteForTests() {
        database.faults.arm(table: "items")
    }
}
#endif
