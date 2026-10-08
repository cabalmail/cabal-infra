import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The feed sidebar publishes its catalog whole (`FeedSidebarViewModel`).
/// It used to publish the folders, then read the subscriptions: a view
/// rendering in between saw a selected subscription missing from the
/// catalog, and the sidebar's management host dropped the selection for
/// All Feeds. A wide split built by a fold opened on All Feeds that way
/// (#1962).
@MainActor
final class FeedSidebarCatalogTests: XCTestCase {
    private var directory: URL!

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private final class Box {
        var subscriptions: [String]?
    }

    func testTheFoldersNeverArriveWithoutTheirSubscriptions() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-sidebar-catalog-\(UUID().uuidString)")
        let store = try RssStore(directory: directory)
        try await store.upsertFolder(RssFolder(folderId: "tech", parentFolderId: "", name: "Tech"))
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .unread))
        let model = FeedSidebarViewModel(store: store, engine: nil)
        let seen = Box()

        // What a view would read on the first render after the folders change.
        withObservationTracking {
            _ = model.folders
        } onChange: {
            Task { @MainActor in seen.subscriptions = model.subscriptions.map(\.subscriptionId) }
        }
        await model.load()

        try await waitUntilOnMainActor { seen.subscriptions != nil }
        XCTAssertEqual(seen.subscriptions, ["s"])
    }
}
