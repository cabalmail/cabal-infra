import XCTest
import CabalmailKit
@testable import Cabalmail

/// The feed list's filter pill is sticky per scope: the list opens on the
/// pill stored for its feed, folder, or the all-feeds preference, and a
/// tap writes the pill back there through `FeedDefaultsPersisting`.
@MainActor
final class FeedListStickyFilterTests: XCTestCase {
    private final class RecordingPersister: FeedDefaultsPersisting, @unchecked Sendable {
        private(set) var subscriptionCalls: [(RssSubscription, RssSubscriptionUpdate)] = []
        private(set) var folderCalls: [(RssFolder, RssFolderUpdate)] = []

        func updateSubscription(_ subscription: RssSubscription, _ update: RssSubscriptionUpdate) async throws
            -> RssSubscription {
            subscriptionCalls.append((subscription, update))
            return subscription.applying(update)
        }

        func updateFolder(_ folder: RssFolder, _ update: RssFolderUpdate) async throws -> RssFolder {
            folderCalls.append((folder, update))
            return folder.applying(update)
        }
    }

    private func makeModel(
        scope: RssItemScope, subscription: RssSubscription? = nil, folder: RssFolder? = nil,
        persister: RecordingPersister, allFeeds: RssItemFilter = .unread
    ) throws -> (FeedItemListViewModel, Preferences) {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        preferences.rssAllFeedsFilter = allFeeds
        let model = FeedItemListViewModel(
            scope: scope, subscription: subscription, folder: folder,
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            preferences: preferences, defaults: persister, bus: FeedStateBus()
        )
        return (model, preferences)
    }

    /// Waits for the write-through task a tap spawned.
    private func settle(until done: @escaping () -> Bool) async {
        for _ in 0..<200 where !done() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Policy

    func testInitialPillComesFromTheScopesRow() {
        let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .favorite)
        let folder = RssFolder(folderId: "fo", name: "Tech", defaultFilter: .all)
        XCTAssertEqual(FeedListFilterPolicy.initial(scope: .subscription("s"), subscription: sub, folder: nil,
                                                    allFeedsFilter: .all), .favorite)
        XCTAssertEqual(FeedListFilterPolicy.initial(scope: .folder("fo"), subscription: nil, folder: folder,
                                                    allFeedsFilter: .favorite), .all)
        XCTAssertEqual(FeedListFilterPolicy.initial(scope: .all, subscription: nil, folder: nil,
                                                    allFeedsFilter: .favorite), .favorite)
        // A row not at hand opens on the feed default, never on a mail-ish All.
        XCTAssertEqual(FeedListFilterPolicy.initial(scope: .folder("fo"), subscription: nil, folder: nil,
                                                    allFeedsFilter: .all), .unread)
        XCTAssertEqual(FeedListFilterPolicy.initial(scope: .subscription("s"), subscription: nil, folder: nil,
                                                    allFeedsFilter: .all), .unread)
    }

    func testStickyUpdateIsNilWhenTheRowAlreadySaysSo() {
        let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .unread)
        XCTAssertNil(FeedListFilterPolicy.stickyUpdate(for: sub, filter: .unread))
        XCTAssertEqual(FeedListFilterPolicy.stickyUpdate(for: sub, filter: .all)?.defaultFilter, .all)
        let folder = RssFolder(folderId: "fo", name: "Tech")
        XCTAssertNil(FeedListFilterPolicy.stickyUpdate(for: folder, filter: .unread))
        XCTAssertEqual(FeedListFilterPolicy.stickyUpdate(for: folder, filter: .favorite)?.defaultFilter, .favorite)
    }

    // MARK: - View model

    func testFeedListOpensOnItsStoredPillAndATapWritesItBack() async throws {
        let persister = RecordingPersister()
        let sub = RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .favorite)
        let (model, _) = try makeModel(scope: .subscription("s"), subscription: sub, persister: persister)
        XCTAssertEqual(model.filter, .favorite)

        model.selectFilter(.all)
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.subscription?.defaultFilter, .all, "the held row changes at once")
        await settle { persister.subscriptionCalls.count == 1 }
        XCTAssertEqual(persister.subscriptionCalls.count, 1)
        XCTAssertEqual(persister.subscriptionCalls[0].1.defaultFilter, .all)
        XCTAssertTrue(persister.subscriptionCalls[0].1.customTitle == nil, "only the pill is written")

        model.selectFilter(.all) // the active pill: nothing to apply or write
        await settle { persister.subscriptionCalls.count == 2 }
        XCTAssertEqual(persister.subscriptionCalls.count, 1)
    }

    func testFolderListOpensOnItsStoredPillAndATapWritesItBack() async throws {
        let persister = RecordingPersister()
        let folder = RssFolder(folderId: "fo", name: "Tech")
        let (model, _) = try makeModel(scope: .folder("fo"), folder: folder, persister: persister)
        XCTAssertEqual(model.filter, .unread)

        model.selectFilter(.favorite)
        XCTAssertEqual(model.folder?.defaultFilter, .favorite)
        await settle { persister.folderCalls.count == 1 }
        XCTAssertEqual(persister.folderCalls.count, 1)
        XCTAssertEqual(persister.folderCalls[0].0.folderId, "fo")
        XCTAssertEqual(persister.folderCalls[0].1.defaultFilter, .favorite)
        XCTAssertTrue(persister.subscriptionCalls.isEmpty)
    }

    func testAllFeedsListOpensOnThePreferenceAndATapWritesItBack() throws {
        let persister = RecordingPersister()
        let (model, preferences) = try makeModel(scope: .all, persister: persister, allFeeds: .all)
        XCTAssertEqual(model.filter, .all)
        model.selectFilter(.unread)
        XCTAssertEqual(preferences.rssAllFeedsFilter, .unread)
        XCTAssertEqual(preferences.appPreferencesPayload()["filter:feeds:all"], "unread")
        XCTAssertTrue(persister.subscriptionCalls.isEmpty)
        XCTAssertTrue(persister.folderCalls.isEmpty)
    }
}
