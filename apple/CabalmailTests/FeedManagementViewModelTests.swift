import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The management model against a scripted client and a real (temporary)
/// store: every mutation lands on the server first, then in the store, whose
/// change stream tells the open feed views.
@MainActor
final class FeedManagementViewModelTests: XCTestCase {
    private var directory: URL!
    private var store: RssStore!
    private var client: FakeRssClient!
    private var changes: AsyncStream<RssStore.Change>!
    private var model: FeedManagementViewModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-mgmt-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        client = FakeRssClient()
        changes = await store.changes()
        model = FeedManagementViewModel(rss: client, store: store,
                                        engine: RssSyncEngine(client: client, store: store))
    }

    /// What the store announced so far (once per test: it ends the stream).
    private func announced() async -> [RssStore.Change] {
        await bufferedElements(changes)
    }

    private func catalogAnnouncements() async -> Int {
        await announced().filter { $0 == .catalog }.count
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSubscribeStoresTheServerRowAndAnnouncesTheCatalog() async throws {
        let result = try await model.subscribe(url: "https://example.com/feed", folderId: "")
        XCTAssertFalse(result.existing)
        let stored = try await store.subscription(id: result.subscription.subscriptionId)
        XCTAssertEqual(stored?.feedId, result.subscription.feedId)
        let calls = await client.subscribeCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].folderId, "an empty folder id is sent as top level, not as \"\"")
        let announced = await announced()
        XCTAssertEqual(announced.filter { $0 == .catalog }.count, 1)
        XCTAssertTrue(announced.contains(.feeds([result.subscription.feedId])),
                      "a new feed's first page is pulled, and the lists told")
    }

    func testUnsubscribeRemovesTheRowThroughACatalogRefresh() async throws {
        let result = try await model.subscribe(url: "https://example.com/feed", folderId: nil)
        try await model.unsubscribe(result.subscription)
        let stored = try await store.subscription(id: result.subscription.subscriptionId)
        XCTAssertNil(stored)
        let calls = await client.unsubscribeCalls
        XCTAssertEqual(calls, [result.subscription.subscriptionId])
    }

    func testUpdateWritesTheServersVersion() async throws {
        let result = try await model.subscribe(url: "https://example.com/feed", folderId: nil)
        let updated = try await model.update(result.subscription,
                                             RssSubscriptionUpdate(customTitle: "Mine", orderingMode: .oldestFirst))
        XCTAssertEqual(updated.customTitle, "Mine")
        let stored = try await store.subscription(id: result.subscription.subscriptionId)
        XCTAssertEqual(stored?.orderingMode, .oldestFirst)
        XCTAssertEqual(stored?.displayTitle, "Mine")
    }

    func testFolderLifecycleGoesThroughTheCatalog() async throws {
        let folder = try await model.createFolder(name: "Tech", parentId: "")
        var folders = try await store.folders()
        XCTAssertEqual(folders.map(\.name), ["Tech"])

        let renamed = try await model.updateFolder(folder, RssFolderUpdate(name: "Technology"))
        XCTAssertEqual(renamed.name, "Technology")
        folders = try await store.folders()
        XCTAssertEqual(folders.map(\.name), ["Technology"])

        _ = try await model.deleteFolder(renamed)
        folders = try await store.folders()
        XCTAssertTrue(folders.isEmpty)
        let catalogAnnouncements = await catalogAnnouncements()
        XCTAssertEqual(catalogAnnouncements, 3)
    }

    func testServerErrorsPropagateAndLeaveTheStoreAlone() async throws {
        await client.set(failNext: CabalmailError.server(code: "not_a_feed", message: "no feed there"))
        do {
            _ = try await model.subscribe(url: "https://example.com", folderId: nil)
            XCTFail("expected the server error")
        } catch {
            XCTAssertEqual(FeedErrorText.describe(error),
                           "That address didn't return a feed, and the page doesn't advertise one.")
        }
        let subs = try await store.subscriptions()
        XCTAssertTrue(subs.isEmpty)
        let catalogAnnouncements = await catalogAnnouncements()
        XCTAssertEqual(catalogAnnouncements, 0)
        XCTAssertFalse(model.isBusy)
    }

    func testImportRefreshesTheCatalogAndReportsCounts() async throws {
        let result = try await model.importOpml("<opml/>", folderId: nil)
        XCTAssertEqual(result.created, 2)
        XCTAssertEqual(FeedOpmlSummary.text(for: result),
                       "2 new feeds, 1 feed already subscribed, 1 folder created.")
        // The import's own catalog refresh; the sync it kicks off may follow.
        let first = await announced().first
        XCTAssertEqual(first, .catalog)
    }

    func testExportReturnsTheDocument() async throws {
        let export = try await model.exportOpml()
        XCTAssertEqual(export.filename, "feeds.opml")
        XCTAssertTrue(export.opml.contains("opml"))
    }
}
