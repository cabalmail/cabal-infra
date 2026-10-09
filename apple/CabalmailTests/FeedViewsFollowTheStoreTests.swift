import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The sidebar, the item list and the reader follow the store through
/// `observe()`: a write made anywhere (another view, another window, the
/// sync engine) reaches each of them without the writer telling it.
@MainActor
final class FeedViewsFollowTheStoreTests: XCTestCase {
    private var directory: URL!
    private var store: RssStore!
    private var followers: [Task<Void, Never>] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-views-follow-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .unread))
        try await store.upsertSubscription(RssSubscription(subscriptionId: "t", feedId: "g", defaultFilter: .unread))
        try await store.upsertItems([item("k1"), item("k2"), item("k3", feed: "g")])
    }

    override func tearDown() async throws {
        followers.forEach { $0.cancel() }
        followers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ sortKey: String, feed: String = "f", day: Int = 1) -> RssItem {
        RssItem(feedId: feed, subscriptionId: feed == "f" ? "s" : "t", itemId: sortKey, sortKey: sortKey,
                title: sortKey, publishedAt: String(format: "2026-01-%02dT00:00:00Z", day))
    }

    private func preferences() -> Preferences {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        return preferences
    }

    private func listModel(scope: RssItemScope, subscription: RssSubscription? = nil,
                           folder: RssFolder? = nil) throws -> FeedItemListViewModel {
        FeedItemListViewModel(
            scope: scope, subscription: subscription, folder: folder,
            client: try TestFixtures.makeClient(imap: FakeImapClient()), preferences: preferences(),
            store: store, engine: RssSyncEngine(client: FakeRssClient(), store: store)
        )
    }

    /// Runs `observe` the way a view's `.task` does.
    private func follow(_ observe: @escaping @MainActor () async -> Void) {
        followers.append(Task { await observe() })
    }

    // MARK: - The sidebar

    func testTheSidebarsBadgesFollowAMarkMadeElsewhere() async throws {
        let model = FeedSidebarViewModel(store: store, engine: nil)
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.unreadCounts["s"] == 2 }

        try await store.setRead(feedId: "f", sortKey: "k1", true)

        try await waitUntilOnMainActor { model.unreadCounts["s"] == 1 }
    }

    func testTheSidebarsTreeFollowsTheCatalog() async throws {
        let model = FeedSidebarViewModel(store: store, engine: nil)
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.hasLoaded }

        try await store.upsertFolder(RssFolder(folderId: "d", name: "Tech"))

        try await waitUntilOnMainActor { model.folders.map(\.name) == ["Tech"] }
    }

    // MARK: - The item list

    /// The reader, another window or another device marks an item: the
    /// list's row patches in place and stays under Unread until the next
    /// reload, with its queued mark.
    func testAListRowPatchesInPlaceWhenItIsMarkedElsewhere() async throws {
        let model = try listModel(scope: .subscription("s"),
                                  subscription: RssSubscription(subscriptionId: "s", feedId: "f"))
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.items.count == 2 }

        try await store.setRead(feedId: "f", sortKey: "k1", true)

        try await waitUntilOnMainActor { model.items.first { $0.sortKey == "k1" }?.isRead == true }
        XCTAssertEqual(model.items.map(\.sortKey).sorted(), ["k1", "k2"], "the read row stays put under Unread")
        XCTAssertEqual(model.pendingIds, ["f#k1"], "the change is queued until the engine pushes it")
    }

    /// A sync the list didn't start (the sidebar's, the poller's) lands new
    /// items: the list re-reads its first page and shows them.
    func testAListShowsItemsASyncElsewhereLanded() async throws {
        let model = try listModel(scope: .all)
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.items.count == 3 }

        try await store.upsertItems([item("k4", day: 2)])

        try await waitUntilOnMainActor { model.items.map(\.sortKey).contains("k4") }
    }

    func testAListPagedPastItsFirstPageKeepsItsPlace() async throws {
        try await store.upsertItems((10..<160).map { item("m\($0)") })
        let model = try listModel(scope: .subscription("s"),
                                  subscription: RssSubscription(subscriptionId: "s", feedId: "f"))
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.items.count == 100 }
        await model.loadMore()
        XCTAssertEqual(model.items.count, 152)
        let shown = model.items.map(\.id)

        try await store.upsertItems([item("n1", day: 9)])
        try await store.setRead(feedId: "f", sortKey: "m10", true)

        try await waitUntilOnMainActor { model.items.first { $0.sortKey == "m10" }?.isRead == true }
        XCTAssertEqual(model.items.map(\.id), shown, "no reload: the rows the user scrolled to stay")
    }

    /// The feed's settings sheet, or another device, changes the order of a
    /// feed whose list is open: the list takes it up.
    func testAnOpenListTakesUpAnOrderChangedElsewhere() async throws {
        try await store.upsertItems([item("k0", day: 3)])
        let row = RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .all)
        try await store.upsertSubscription(row)
        let model = try listModel(scope: .subscription("s"), subscription: row)
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.items.count == 3 }
        XCTAssertEqual(model.ordering, .newestFirst)
        XCTAssertEqual(model.items.first?.sortKey, "k2")

        var changed = row
        changed.orderingMode = .oldestFirst
        try await store.upsertSubscription(changed)

        try await waitUntilOnMainActor { model.ordering == .oldestFirst }
        try await waitUntilOnMainActor { model.items.first?.sortKey == "k0" }
    }

    /// The same for a folder's own order, picked on another device.
    func testAnOpenFolderListTakesUpAnOrderChangedElsewhere() async throws {
        try await store.upsertItems([item("k0", day: 3)])
        let folder = RssFolder(folderId: "d", name: "Tech")
        try await store.upsertFolder(folder)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s", feedId: "f", folderId: "d",
                                                           defaultFilter: .all))
        let model = try listModel(scope: .folder("d"), folder: folder)
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.items.count == 3 }
        XCTAssertEqual(model.ordering, .newestFirst)
        XCTAssertEqual(model.items.first?.sortKey, "k2")

        var changed = folder
        changed.orderingMode = .oldestFirst
        try await store.upsertFolder(changed)

        try await waitUntilOnMainActor { model.ordering == .oldestFirst }
        try await waitUntilOnMainActor { model.items.first?.sortKey == "k0" }
    }

    func testAFolderListFollowsAFeedMovedIntoIt() async throws {
        try await store.upsertFolder(RssFolder(folderId: "d", name: "Tech"))
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s", feedId: "f", folderId: "d",
                                                           defaultFilter: .unread))
        let model = try listModel(scope: .folder("d"), folder: RssFolder(folderId: "d", name: "Tech"))
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.items.count == 2 }

        try await store.upsertSubscription(RssSubscription(subscriptionId: "t", feedId: "g", folderId: "d",
                                                           defaultFilter: .unread))

        try await waitUntilOnMainActor { model.items.map(\.sortKey).contains("k3") }
    }

    func testAListEmptiesWhenTheStoreIsCleared() async throws {
        let model = try listModel(scope: .all)
        follow { await model.observe() }
        try await waitUntilOnMainActor { model.items.count == 3 }

        try await store.clear()

        try await waitUntilOnMainActor { model.items.isEmpty }
    }

    // MARK: - The reader

    func testTheReadersToolbarFollowsAMarkMadeInTheList() async throws {
        let list = try listModel(scope: .subscription("s"),
                                 subscription: RssSubscription(subscriptionId: "s", feedId: "f"))
        let reader = try await followingReader(subscription: nil)

        await list.setFavorite(item("k1"), true)

        try await waitUntilOnMainActor { reader.item.isFavorite }
    }

    func testTheReadersStoredDefaultsFollowTheSettingsSheet() async throws {
        let row = RssSubscription(subscriptionId: "s", feedId: "f")
        let reader = try await followingReader(subscription: row)

        var changed = row
        changed.defaultStyling = .native
        try await store.upsertSubscription(changed)

        try await waitUntilOnMainActor { reader.subscription?.defaultStyling == .native }
        XCTAssertTrue(reader.readerMode, "what is on screen stays as the reader opened it")
    }

    /// A reader on k1, following the store. The store has k1 read while the
    /// item handed to the reader says unread, so the reader's first read of
    /// the store shows once it is subscribed: what the tests wait for before
    /// writing, so the write is one it follows rather than one it reads.
    private func followingReader(subscription: RssSubscription?) async throws -> FeedItemDetailViewModel {
        try await store.setRead(feedId: "f", sortKey: "k1", true)
        let reader = FeedItemDetailViewModel(item: item("k1"), subscription: subscription,
                                             engine: RssSyncEngine(client: FakeRssClient(), store: store),
                                             preferences: preferences())
        follow { await reader.observe() }
        try await waitUntilOnMainActor { reader.item.isRead }
        return reader
    }
}
