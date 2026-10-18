import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Who gets a folder poller (#1983). The unsubscribed banner tells the user
/// the folder "is not kept up-to-date automatically", but every open list
/// went on its folder's poller — a `/folder_status` watcher and a 60-second
/// refresh tick — subscribed or not. Both answers now come from
/// `UnsubscribedBannerPolicy`, so the sentence and the behaviour agree.
@MainActor
final class MessageListUnsubscribedPollingTests: XCTestCase {
    private var world: FolderPollListWorld!

    override func setUp() async throws {
        world = FolderPollListWorld()
        await world.setUp()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    /// The control: a subscribed folder is still polled.
    func testASubscribedFoldersListGoesOnThePoller() async throws {
        let list = try await world.oneListOnWork()
        world.fixture.mailStore.counts.setSubscribedFolders(["Work"])

        await list.startWatching()

        XCTAssertNotNil(world.pollers.poller(for: "Work", through: list.client))
    }

    func testAnUnsubscribedFoldersListStaysOffThePoller() async throws {
        let list = try await world.oneListOnWork()
        world.fixture.mailStore.counts.setSubscribedFolders(["INBOX"])

        await list.startWatching()

        XCTAssertNil(
            world.pollers.poller(for: "Work", through: list.client),
            "no watcher and no tick for a folder the banner says is not kept current"
        )
        let statuses = await world.fixture.statusCalls()
        XCTAssertTrue(statuses.isEmpty, "and no STATUS goes out for it")
    }

    /// Subscribing the folder the user is looking at starts keeping it
    /// current, without reopening the list.
    func testSubscribingWhileTheListIsOpenPutsItOnThePoller() async throws {
        let list = try await world.oneListOnWork()
        world.fixture.mailStore.counts.setSubscribedFolders([])
        await list.startWatching()
        XCTAssertNil(world.pollers.poller(for: "Work", through: list.client))

        world.fixture.mailStore.counts.setSubscription(folderPath: "Work", isSubscribed: true)
        await list.updateWatching()

        XCTAssertNotNil(world.pollers.poller(for: "Work", through: list.client))
    }

    /// And unsubscribing it takes it back off, which is the half the user
    /// can watch happen: the banner appears in the same update.
    func testUnsubscribingWhileTheListIsOpenTakesItOffThePoller() async throws {
        let list = try await world.oneListOnWork()
        world.fixture.mailStore.counts.setSubscribedFolders(["Work"])
        await list.startWatching()
        XCTAssertNotNil(world.pollers.poller(for: "Work", through: list.client))

        world.fixture.mailStore.counts.setSubscription(folderPath: "Work", isSubscribed: false)
        await list.updateWatching()

        XCTAssertNil(world.pollers.poller(for: "Work", through: list.client))
    }

    /// Before the folder list lands there is no subscribed set, and the
    /// `Folder` value answers for itself — the launch landing, a push tap
    /// or a Spotlight hit seeds a subscribed INBOX, and this list's folder
    /// is seeded subscribed too, so it is polled from the start rather
    /// than waiting for the list.
    func testAFolderWhoseSubscribedSetHasNotLandedTrustsItsOwnFlag() async throws {
        let list = try await world.oneListOnWork()
        XCTAssertNil(world.fixture.mailStore.counts.subscribedFolderPaths)

        await list.startWatching()

        XCTAssertNotNil(world.pollers.poller(for: "Work", through: list.client))
    }
}
