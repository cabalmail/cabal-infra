import XCTest
@testable import CabalmailKit

/// `RssSyncEngine` against a scripted `RssClient`: initial population,
/// since-sync paging, load-older, catalog removal, and the pending queue.
final class RssSyncEngineTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!
    private var client: FakeRssClient!
    private var engine: RssSyncEngine!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-engine-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        client = FakeRssClient()
        engine = RssSyncEngine(client: client, store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ number: Int, feed: String = "f1") -> RssItem {
        RssItem(feedId: feed, itemId: "i\(number)",
                sortKey: String(format: "2026-01-%02dT00:00:00+00:00#i%d", number, number),
                title: "Item \(number)", publishedAt: String(format: "2026-01-%02dT00:00:00+00:00", number),
                fetchedKey: String(format: "2026-02-01T00:00:%02d+00:00#i%d", number, number))
    }

    private let subscription = RssSubscription(subscriptionId: "s1", feedId: "f1", dataStoreUuid: "ds1",
                                               feed: RssFeedSummary(feedId: "f1", title: "F1"))

    func testInitialPopulationThenIncrementalSync() async throws {
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        await client.set(listPages: [RssItemsPage(items: [item(5), item(4), item(3)], nextCursor: "older-1")])
        await client.set(syncPages: [RssSyncPage(items: [item(6)], nextSince: item(6).fetchedKey, hasMore: false)])
        try await engine.refreshCatalog()
        let received = try await engine.syncItems(for: subscription)
        XCTAssertEqual(received, 4)
        let state = try await store.syncState(feedId: "f1")
        XCTAssertEqual(state.sinceCursor, item(6).fetchedKey)
        XCTAssertEqual(state.olderCursor, "older-1")
        XCTAssertFalse(state.olderExhausted)
        let observed1 = try await store.items(.init(scope: .all)).map(\.itemId)
        XCTAssertEqual(observed1, ["i6", "i5", "i4", "i3"])
        // The since-sync started from the newest fetched_key of the initial page.
        let observed101 = await client.syncCalls.map(\.since)
        XCTAssertEqual(observed101, [item(5).fetchedKey])
        // A second run: only since-sync, from the stored cursor, bounded by maxPagesPerRun.
        await client.set(syncPages: [
            RssSyncPage(items: [item(7)], nextSince: item(7).fetchedKey, hasMore: true),
            RssSyncPage(items: [item(8)], nextSince: item(8).fetchedKey, hasMore: false),
        ])
        let observed2 = try await engine.syncItems(for: subscription)
        XCTAssertEqual(observed2, 2)
        let observed102 = await client.listCalls.count
        XCTAssertEqual(observed102, 1)
        let observed3 = try await store.syncState(feedId: "f1").sinceCursor
        XCTAssertEqual(observed3, item(8).fetchedKey)
    }

    func testEmptyFeedGetsSentinelCursorNotAnotherInitialLoad() async throws {
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        await client.set(listPages: [RssItemsPage(items: [], nextCursor: nil)])
        await client.set(syncPages: [RssSyncPage(items: [], nextSince: "", hasMore: false),
                                     RssSyncPage(items: [], nextSince: "", hasMore: false)])
        try await engine.refreshCatalog()
        let observed4 = try await engine.syncItems(for: subscription)
        XCTAssertEqual(observed4, 0)
        let observed5 = try await engine.syncItems(for: subscription)
        XCTAssertEqual(observed5, 0)
        let observed103 = await client.listCalls.count
        XCTAssertEqual(observed103, 1)                 // no second initial load
        let observed104 = await client.syncCalls.map(\.since)
        XCTAssertEqual(observed104, ["", ""])
    }

    func testLoadOlderFollowsCursorUntilExhausted() async throws {
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        try await engine.refreshCatalog()
        try await store.setSyncState(feedId: "f1", .init(sinceCursor: "k", olderCursor: "c1"))
        await client.set(listPages: [RssItemsPage(items: [item(2)],
            nextCursor: "c2"), RssItemsPage(items: [item(1)], nextCursor: nil)])
        let observed6 = try await engine.loadOlder(for: subscription)
        XCTAssertEqual(observed6, 1)
        let observed105 = await client.listCalls.last?.cursor
        XCTAssertEqual(observed105, "c1")
        let observed7 = try await engine.loadOlder(for: subscription)
        XCTAssertEqual(observed7, 1)
        let observed8 = try await store.syncState(feedId: "f1").olderExhausted
        XCTAssertTrue(observed8)
        let observed9 = try await engine.loadOlder(for: subscription)
        XCTAssertEqual(observed9, 0)
        let observed106 = await client.listCalls.count
        XCTAssertEqual(observed106, 2)
    }

    func testDrainPendingBatchesAndClears() async throws {
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        try await engine.refreshCatalog()
        try await store.upsertItems((1...3).map { item($0) })
        try await store.setRead(feedId: "f1", sortKey: item(1).sortKey, true)
        try await store.setFavorite(feedId: "f1", sortKey: item(1).sortKey, true)
        try await store.setRead(feedId: "f1", sortKey: item(2).sortKey, true)
        try await store.setRead(feedId: "f1", sortKey: item(2).sortKey, false)   // supersedes
        try await store.markAllRead(subscriptionId: "s1", watermark: "w")
        await client.set(markAllReadWatermark: "server-w")
        let cleared = try await engine.drainPending()
        XCTAssertEqual(cleared, 4)
        let observed10 = try await store.pendingCount()
        XCTAssertEqual(observed10, 0)
        let changes = await client.stateCalls.flatMap { $0 }.sorted { $0.sortKey < $1.sortKey }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].isRead, true)
        XCTAssertEqual(changes[0].isFavorite, true)
        XCTAssertEqual(changes[1].isRead, false)
        XCTAssertNil(changes[1].isFavorite)
        let observed107 = await client.markAllReadCalls
        XCTAssertEqual(observed107, [.subscription("s1")])
        let observed11 = try await store.subscription(id: "s1")?.readWatermark
        XCTAssertEqual(observed11, "w")   // MAX("w", "server-w")
    }

    func testDrainReplaysMarkAllReadInQueueOrder() async throws {
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        try await engine.refreshCatalog()
        try await store.upsertItems((1...3).map { item($0) })
        // Offline: read 1, mark all read, then change your mind about 2.
        try await store.setRead(feedId: "f1", sortKey: item(1).sortKey, true)
        try await store.markAllRead(subscriptionId: "s1", watermark: "w")
        try await store.setRead(feedId: "f1", sortKey: item(2).sortKey, false)
        try await store.setFavorite(feedId: "f1", sortKey: item(2).sortKey, true)
        let cleared = try await engine.drainPending()
        XCTAssertEqual(cleared, 4)
        let observed108 = await client.pushLog
        XCTAssertEqual(observed108, ["state", "mark_all_read", "state"])
        let calls = await client.stateCalls
        XCTAssertEqual(calls.map { $0.map(\.sortKey) }, [[item(1).sortKey], [item(2).sortKey]])
        XCTAssertEqual(calls[1][0].isRead, false)
        XCTAssertEqual(calls[1][0].isFavorite, true)
        let observed109 = try await store.pendingCount()
        XCTAssertEqual(observed109, 0)
    }

    func testStateSyncAppliesMarksFromOtherDevicesAndKeepsCursor() async throws {
        await client.set(catalog: RssCatalog(folders: [],
            subscriptions: [RssSubscription(subscriptionId: "s1", feedId: "f1", readWatermark: item(4).publishedAt,
                                            dataStoreUuid: "ds1", feed: RssFeedSummary(feedId: "f1", title: "F1"))]))
        try await engine.refreshCatalog()
        try await store.setSyncState(feedId: "f1", .init(sinceCursor: "k"))
        try await store.upsertItems((1...5).map { item($0) })
        // Items 1-4 read by the watermark, 5 unread. Another device marked
        // 2 unread and favorited 5; the state sync pages that in.
        await client.set(syncPages: [RssSyncPage(items: [], nextSince: "", hasMore: false),
                                     RssSyncPage(items: [], nextSince: "", hasMore: false)])
        await client.set(statePages: [
            RssStateSyncPage(states: [RssItemState(feedId: "f1", sortKey: item(2).sortKey, isRead: false,
                                                   isReadExplicit: true)],
                             nextSince: "c1", hasMore: true),
            RssStateSyncPage(states: [RssItemState(feedId: "f1", sortKey: item(5).sortKey, isFavorite: true),
                                      RssItemState(feedId: "f1", sortKey: "2026-01-09T00:00:00+00:00#i9")],
                             nextSince: "c2", hasMore: false),
        ])
        try await engine.syncItems(for: subscription)
        let observed110 = await client.stateSyncCalls.map(\.since)
        XCTAssertEqual(observed110, ["", "c1"])
        let observed111 = try await store.syncState(feedId: "f1").stateCursor
        XCTAssertEqual(observed111, "c2")
        let rows = try await store.items(.init(scope: .all, ordering: .oldestFirst))
        XCTAssertEqual(rows.map(\.isRead), [true, false, true, true, false])
        XCTAssertEqual(rows.map(\.isReadExplicit), [false, true, false, false, false])
        XCTAssertEqual(rows.map(\.isFavorite), [false, false, false, false, true])
        XCTAssertEqual(rows.count, 5)                       // the unknown item is skipped, not created
        // A queued local change outranks what the server reports for that flag.
        try await store.setRead(feedId: "f1", sortKey: item(2).sortKey, true)
        await client.set(failNextState: true)
        _ = try? await engine.drainPending()
        await client.set(statePages: [
            RssStateSyncPage(states: [RssItemState(feedId: "f1", sortKey: item(2).sortKey, isRead: false,
                                                   isReadExplicit: true, isFavorite: true)],
                             nextSince: "c3", hasMore: false),
        ])
        try await engine.syncItems(for: subscription)
        let observed112 = try await store.item(feedId: "f1", sortKey: item(2).sortKey)
        XCTAssertEqual(observed112?.isRead, true)
        XCTAssertEqual(observed112?.isFavorite, true)
    }

    func testDrainFailureLeavesQueue() async throws {
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        try await engine.refreshCatalog()
        try await store.upsertItems([item(1)])
        await client.set(failNextState: true)
        try await engine.setRead(item(1), true)          // best-effort push fails quietly
        let observed12 = try await store.pendingCount()
        XCTAssertEqual(observed12, 1)
        let observed13 = try await store.items(.init(scope: .all))[0].isRead
        XCTAssertTrue(observed13)
        let observed14 = try await engine.drainPending()
        XCTAssertEqual(observed14, 1)
        let observed15 = try await store.pendingCount()
        XCTAssertEqual(observed15, 0)
    }

    func testSyncAllReportsPerFeedFailuresAndDropsDepartedSubscriptions() async throws {
        let other = RssSubscription(subscriptionId: "s2", feedId: "f2", dataStoreUuid: "ds2")
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription, other]))
        await client.set(listPages: [RssItemsPage(items: [item(1)], nextCursor: nil),
                                     RssItemsPage(items: [item(1, feed: "f2")], nextCursor: nil)])
        await client.set(syncPages: [RssSyncPage(items: [], nextSince: "", hasMore: false),
                                     RssSyncPage(items: [], nextSince: "", hasMore: false)])
        var failures = await engine.syncAll()
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        let observed16 = try await store.items(.init(scope: .all)).count
        XCTAssertEqual(observed16, 2)
        // s2 disappears server-side; its items go with it.
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        await client.set(syncPages: [RssSyncPage(items: [], nextSince: "", hasMore: false)])
        failures = await engine.syncAll()
        XCTAssertTrue(failures.isEmpty)
        let observed17 = try await store.items(.init(scope: .all)).map(\.feedId)
        XCTAssertEqual(observed17, ["f1"])
    }
}

// MARK: - Scripted client

actor FakeRssClient: RssClient {
    struct ListCall: Equatable { let scope: RssItemScope; let cursor: String? }
    struct SyncCall: Equatable { let subscriptionId: String; let since: String }

    private var catalog = RssCatalog(folders: [], subscriptions: [])
    private var listPages: [RssItemsPage] = []
    private var syncPages: [RssSyncPage] = []
    private var statePages: [RssStateSyncPage] = []
    private var markAllReadWatermark = "w"
    private var failNextState = false
    private(set) var listCalls: [ListCall] = []
    private(set) var syncCalls: [SyncCall] = []
    private(set) var stateSyncCalls: [SyncCall] = []
    private(set) var stateCalls: [[RssItemStateChange]] = []
    private(set) var markAllReadCalls: [RssItemScope] = []
    /// Every mutating call in the order it arrived ("state" / "mark_all_read").
    private(set) var pushLog: [String] = []

    func set(catalog: RssCatalog) { self.catalog = catalog }
    func set(listPages: [RssItemsPage]) { self.listPages = listPages }
    func set(syncPages: [RssSyncPage]) { self.syncPages = syncPages }
    /// Unscripted state syncs answer with an empty, exhausted page.
    func set(statePages: [RssStateSyncPage]) { self.statePages = statePages }
    func set(markAllReadWatermark: String) { self.markAllReadWatermark = markAllReadWatermark }
    func set(failNextState: Bool) { self.failNextState = failNextState }

    func listSubscriptions() async throws -> RssCatalog { catalog }
    func subscribe(url: String, folderId: String?) async throws -> RssSubscribeResult { fatalError("unused") }
    func unsubscribe(subscriptionId: String) async throws -> RssUnsubscribeResult { fatalError("unused") }
    func updateSubscription(_: String, _: RssSubscriptionUpdate) async throws -> RssSubscription {
        fatalError("unused")
    }
    func newFolder(name: String, parentFolderId: String?, displayOrder: Int?) async throws -> RssFolder {
        fatalError("unused")
    }
    func updateFolder(_: String, _: RssFolderUpdate) async throws -> RssFolder { fatalError("unused") }
    func deleteFolder(_: String) async throws -> RssFolderDeleteResult { fatalError("unused") }

    func listItems(scope: RssItemScope, filter: RssItemFilter, order: RssItemOrder, limit: Int,
                   cursor: String?) async throws -> RssItemsPage {
        listCalls.append(ListCall(scope: scope, cursor: cursor))
        guard !listPages.isEmpty else { throw CabalmailError.transport("no scripted list page") }
        return listPages.removeFirst()
    }

    func syncItems(subscriptionId: String, since: String, limit: Int) async throws -> RssSyncPage {
        syncCalls.append(SyncCall(subscriptionId: subscriptionId, since: since))
        guard !syncPages.isEmpty else { throw CabalmailError.transport("no scripted sync page") }
        return syncPages.removeFirst()
    }

    func syncItemStates(subscriptionId: String, since: String, limit: Int) async throws -> RssStateSyncPage {
        stateSyncCalls.append(SyncCall(subscriptionId: subscriptionId, since: since))
        guard !statePages.isEmpty else { return RssStateSyncPage(states: [], nextSince: "", hasMore: false) }
        return statePages.removeFirst()
    }

    func getItem(feedId: String, sortKey: String) async throws -> RssItem { fatalError("unused") }

    func setItemState(_ changes: [RssItemStateChange]) async throws -> Int {
        if failNextState {
            failNextState = false
            throw CabalmailError.transport("offline")
        }
        stateCalls.append(changes)
        pushLog.append("state")
        return changes.count
    }

    func markAllRead(scope: RssItemScope) async throws -> RssMarkAllReadResult {
        markAllReadCalls.append(scope)
        pushLog.append("mark_all_read")
        let json = #"{"subscriptions": 1, "flipped": 0, "read_watermark": "\#(markAllReadWatermark)"}"#
        return try JSONDecoder().decode(RssMarkAllReadResult.self, from: Data(json.utf8))
    }

    func importOpml(_ opml: String, folderId: String?) async throws -> RssOpmlImportResult { fatalError("unused") }
    func exportOpml() async throws -> RssOpmlExport { fatalError("unused") }
}
