import XCTest
import CabalmailKit
@testable import CabalmailUI

/// An app opened without a connection must still draw the sidebar's folders
/// and badges from what an earlier launch saved, and give way to the live
/// list once the server answers. These drive the real API-backed client over
/// a transport that fails like URLSession does offline, so the fallback runs
/// through the same `CabalmailError` the app sees.
@MainActor
final class OfflineSidebarTests: XCTestCase {
    private var fixture: OfflineFolderFixture!

    override func setUp() async throws {
        fixture = OfflineFolderFixture()
    }

    override func tearDown() async throws {
        fixture = nil
    }

    func testOfflineSidebarDrawsTheSavedFoldersAndBadges() async throws {
        let appState = AppState()
        let client = try fixture.makeClient(folderState: await fixture.savedState())
        let model = FolderListViewModel(client: client, mailStore: appState.mailStore)

        await model.loadFolderList()

        XCTAssertEqual(Set(model.folders.map(\.path)), ["INBOX", "Archive", "Projects"])
        XCTAssertTrue(model.isShowingSavedCopy)
        let message = try XCTUnwrap(model.errorMessage, "the sidebar still says it couldn't reach the server")
        XCTAssertTrue(message.contains("Couldn't reach the server"), message)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["INBOX"], 2)
        XCTAssertEqual(appState.mailStore.counts.folderTotalCounts["INBOX"], 22)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Projects"], 5)
        XCTAssertNil(
            appState.mailStore.counts.folderUnreadCounts["Archive"],
            "unsubscribed: no badge until opened, as online, so none is left stale after reconnecting"
        )
        XCTAssertEqual(
            appState.mailStore.counts.inboxUnreadCount, 0,
            "the app badge is left alone: it shows what this device last set, which can be newer"
        )
        XCTAssertEqual(appState.mailStore.counts.savedFolderCounts.seededPaths, ["INBOX", "Projects"])
        XCTAssertEqual(appState.mailStore.counts.subscribedFolderPaths, ["INBOX", "Projects"])
    }

    /// Negative control: with nothing saved, as before, the offline sidebar
    /// had no folders and no badges.
    func testWithoutSavedStateTheOfflineSidebarIsEmpty() async throws {
        let appState = AppState()
        let client = try fixture.makeClient(folderState: FolderStateCache())
        let model = FolderListViewModel(client: client, mailStore: appState.mailStore)

        await model.loadFolderList()

        XCTAssertTrue(model.folders.isEmpty)
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(appState.mailStore.counts.folderUnreadCounts.isEmpty)
    }

    /// A count this session already has from a live STATUS is newer than the
    /// saved one, and an optimistic delta may have moved it since; the saved
    /// count must not overwrite it.
    func testSavedBadgesDoNotOverwriteLiveCounts() async throws {
        let appState = AppState()
        appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 9, total: 30)
        let client = try fixture.makeClient(folderState: await fixture.savedState())
        let model = FolderListViewModel(client: client, mailStore: appState.mailStore)

        await model.loadFolderList()

        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["INBOX"], 9)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Projects"], 5)
    }

    /// A live first load isn't a saved copy, and says nothing went wrong.
    func testLiveListIsNotASavedCopy() async throws {
        let model = FolderListViewModel(
            client: try fixture.makeClient(folderState: await fixture.savedState(), transport: FolderServerTransport()),
            mailStore: AppState().mailStore
        )

        await model.loadFolderList()

        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(Set(model.folders.map(\.path)), ["INBOX", "Archive", "Projects"])
    }

    /// A refresh that fails after a live load keeps the live list: the saved
    /// copy is older, and may still hold a folder deleted since.
    func testFailedRefreshKeepsTheLiveList() async throws {
        let connectivity = FolderConnectivity()
        let cache = await fixture.savedState()
        let model = FolderListViewModel(
            client: try fixture.makeClient(
                folderState: cache, transport: SwitchableFolderTransport(connectivity: connectivity)
            ),
            mailStore: AppState().mailStore
        )
        await model.loadFolderList()
        let live = model.folders.map(\.path)
        // Make the saved list older than the screen, as a delete on another
        // device since the last save would.
        await cache.recordFolders(
            [Folder(path: "INBOX", isSubscribed: true), Folder(path: "Gone")],
            ifUnchangedSince: 0
        )

        await connectivity.goOffline()
        await model.loadFolderList()

        XCTAssertEqual(model.folders.map(\.path), live)
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertNotNil(model.errorMessage)
    }

    /// One model through a whole outage: offline it draws the saved copy and
    /// its badges; back online the live list replaces it and the seeded
    /// badges go (a recount cut short leaves them blank rather than old);
    /// offline again, the live list stays.
    func testSavedCopyGivesWayToTheLiveListAndBack() async throws {
        let connectivity = FolderConnectivity()
        await connectivity.goOffline()
        let appState = AppState()
        let model = FolderListViewModel(
            client: try fixture.makeClient(
                folderState: await fixture.savedState(),
                transport: SwitchableFolderTransport(connectivity: connectivity)
            ),
            mailStore: appState.mailStore
        )

        await model.loadFolderList()
        XCTAssertTrue(model.isShowingSavedCopy)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Projects"], 5)

        await connectivity.goOnline()
        await model.loadFolderList()
        XCTAssertFalse(model.isShowingSavedCopy)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(appState.mailStore.counts.folderUnreadCounts["Projects"], "seeded badge dropped until the recount")
        XCTAssertTrue(appState.mailStore.counts.savedFolderCounts.seededPaths.isEmpty)
        await model.refreshSubscribedCounts()
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Projects"], 4, "the live count")

        await connectivity.goOffline()
        await model.loadFolderList()
        XCTAssertFalse(model.isShowingSavedCopy, "a live list from this session stays")
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Projects"], 4)
    }

    /// A live list clears only the badges still seeded: one the message list
    /// has since published from a live STATUS keeps its live value, and one a
    /// delta has moved is still derived from the seed, so it goes.
    func testLiveListClearsOnlyTheBadgesStillSeeded() async throws {
        let connectivity = FolderConnectivity()
        await connectivity.goOffline()
        let appState = AppState()
        let model = FolderListViewModel(
            client: try fixture.makeClient(
                folderState: await fixture.savedState(),
                transport: SwitchableFolderTransport(connectivity: connectivity)
            ),
            mailStore: appState.mailStore
        )
        await model.loadFolderList()

        appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 9, total: 30)
        appState.mailStore.counts.applyUnreadDelta(folderPath: "Projects", delta: -1)
        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["Projects"], 4)

        await connectivity.goOnline()
        await model.loadFolderList()

        XCTAssertEqual(appState.mailStore.counts.folderUnreadCounts["INBOX"], 9, "a live count stays")
        XCTAssertNil(
            appState.mailStore.counts.folderUnreadCounts["Projects"], "a count moved from the seed is still the seed's"
        )
    }

    /// Deleting or (un)subscribing a folder on this device updates the saved
    /// list, so the next offline launch shows the folders as they are.
    func testFolderChangesReachTheSavedList() async throws {
        let cache = FolderStateCache(directory: fixture.root.appendingPathComponent("folders"))
        let online = FolderListViewModel(
            client: try fixture.makeClient(folderState: cache, transport: FolderServerTransport()),
            mailStore: AppState().mailStore
        )
        await online.loadFolderList()
        let projects = try XCTUnwrap(online.folders.first { $0.path == "Projects" })
        let archive = try XCTUnwrap(online.folders.first { $0.path == "Archive" })
        let deleted = await online.deleteFolder(projects)
        XCTAssertTrue(deleted)
        await online.toggleSubscription(archive)

        let offline = FolderListViewModel(
            client: try fixture.makeClient(folderState: cache), mailStore: AppState().mailStore
        )
        await offline.loadFolderList()

        XCTAssertTrue(offline.isShowingSavedCopy)
        XCTAssertEqual(Set(offline.folders.map(\.path)), ["INBOX", "Archive"])
        XCTAssertEqual(offline.folders.first { $0.path == "Archive" }?.isSubscribed, true)
    }
}
