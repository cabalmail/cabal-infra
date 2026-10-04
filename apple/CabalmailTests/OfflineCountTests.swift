import XCTest
import CabalmailKit
@testable import Cabalmail

/// The message list's All / Unread / Flagged counts offline come from the
/// counts saved by live STATUS replies and by changes made on this device.
@MainActor
final class OfflineCountTests: XCTestCase {
    private var fixture: OfflineFolderFixture!

    override func setUp() async throws {
        fixture = OfflineFolderFixture()
    }

    override func tearDown() async throws {
        fixture = nil
    }

    /// Count changes made on this device reach the saved counts, so an
    /// offline launch shows what the app last showed: a read, then Mark All
    /// as Read. The app badge path is the same `AppState` mutators.
    func testLocalCountChangesAreSaved() async throws {
        let cache = await fixture.savedState()
        let appState = AppState()
        appState.savedFolderCounts.cache = cache
        appState.setFolderCounts(folderPath: "INBOX", unread: 2, total: 22)

        appState.applyUnreadDelta(folderPath: "INBOX", delta: -1)
        try await eventually { await cache.lastKnownStatus(for: "INBOX")?.unseen == 1 }

        appState.setUnreadCount(folderPath: "INBOX", count: 0)
        try await eventually { await cache.lastKnownStatus(for: "INBOX")?.unseen == 0 }
        let inbox = await cache.lastKnownStatus(for: "INBOX")
        XCTAssertEqual(inbox?.messages, 22)
        XCTAssertEqual(inbox?.flagged, 1, "a local unread change leaves the saved flagged count alone")

        // Signed out: nothing more is written.
        appState.savedFolderCounts.reset()
        appState.applyUnreadDelta(folderPath: "INBOX", delta: 3)
        try await Task.sleep(for: .milliseconds(200))
        let after = await cache.lastKnownStatus(for: "INBOX")
        XCTAssertEqual(after?.unseen, 0)
    }

    /// The live STATUS replies the app makes are what fill the saved counts:
    /// the sidebar's walk and the list's flagged STATUS.
    func testLiveCountsAreSavedForTheNextLaunch() async throws {
        let cache = FolderStateCache(directory: fixture.root.appendingPathComponent("folders"))
        let client = try fixture.makeClient(folderState: cache, transport: FolderServerTransport())
        let sidebar = FolderListViewModel(client: client, appState: AppState())
        await sidebar.loadFolderList()
        await sidebar.refreshSubscribedCounts()
        let projects = await cache.lastKnownStatus(for: "Projects")
        XCTAssertEqual(projects?.unseen, 4)
        XCTAssertNil(projects?.flagged, "the sidebar's STATUS asks for no flagged count")

        await fixture.makeListModel(client: client).loadInitial()
        let inbox = await cache.lastKnownStatus(for: "INBOX")
        XCTAssertEqual(inbox?.messages, 30)
        XCTAssertEqual(inbox?.flagged, 2, "the list's STATUS carries the flagged count")
    }

    /// A delta applied to a folder this session hasn't counted starts from a
    /// guessed 0. That guess must not replace the real saved count: say, a
    /// search hit marked read in a folder not opened since launch.
    func testDeltaOnAnUncountedFolderLeavesTheSavedCount() async throws {
        let cache = await fixture.savedState()
        let appState = AppState()
        appState.savedFolderCounts.cache = cache

        appState.applyUnreadDelta(folderPath: "Projects", delta: -1)
        appState.setFolderCounts(folderPath: "INBOX", unread: 7, total: 22)
        try await eventually { await cache.lastKnownStatus(for: "INBOX")?.unseen == 7 }

        let projects = await cache.lastKnownStatus(for: "Projects")
        XCTAssertEqual(projects?.unseen, 5, "the guessed 0 stayed in memory")
    }

    /// A STATUS the list withholds as older than a removal it has applied is
    /// saved as it came by `client.folderStatus`; the counts the list shows
    /// are what must end up saved.
    func testWithheldStatusSavesTheCountsShown() async throws {
        let cache = await fixture.savedState()
        let appState = AppState()
        appState.savedFolderCounts.cache = cache
        let model = fixture.makeListModel(client: try fixture.makeClient(folderState: cache), appState: appState)
        _ = model.applyStatusCounts(FolderStatus(messages: 22, unseen: 2, flagged: 1))
        // An unread message archived here: the list shows one fewer of each.
        model.totalMessages = 21
        model.unseen = 1
        let stale = FolderStatus(messages: 22, unseen: 2, flagged: 1)
        await cache.recordStatus(stale, for: "INBOX", ifUnchangedSince: 0)

        _ = model.applyStatusCounts(stale, mayPredateRemoval: true)

        XCTAssertEqual(model.unseen, 1)
        try await eventually { await cache.lastKnownStatus(for: "INBOX")?.unseen == 1 }
        let inbox = await cache.lastKnownStatus(for: "INBOX")
        XCTAssertEqual(inbox?.messages, 21)
    }

    func testOfflineListPillsShowTheSavedCounts() async throws {
        let client = try fixture.makeClient(folderState: await fixture.savedState())
        try await fixture.cachedInbox(in: client)
        let model = fixture.makeListModel(client: client)

        await model.loadInitial()

        XCTAssertEqual(model.envelopes.count, 22)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.allCount, 22)
        XCTAssertEqual(model.unseen, 2)
        XCTAssertEqual(model.flagged, 1)
        // The saved total is for the pill only: the list keeps sizing itself
        // from what it holds, so it draws no rows it can't load offline.
        XCTAssertEqual(model.totalMessages, 0)
    }

    /// Negative control: with no saved counts, as before, the pills read 0
    /// over the cached rows.
    func testWithoutSavedCountsTheOfflinePillsReadZero() async throws {
        let client = try fixture.makeClient(folderState: FolderStateCache())
        try await fixture.cachedInbox(in: client)
        let model = fixture.makeListModel(client: client)

        await model.loadInitial()

        XCTAssertEqual(model.envelopes.count, 22)
        XCTAssertEqual(model.allCount, 0)
        XCTAssertEqual(model.unseen, 0)
        XCTAssertEqual(model.flagged, 0)
    }

    /// The first STATUS that answers replaces the saved counts.
    func testLiveStatusReplacesTheSavedCounts() async throws {
        let client = try fixture.makeClient(folderState: await fixture.savedState(), transport: FolderServerTransport())
        let model = fixture.makeListModel(client: client)

        await model.seedSavedCounts()
        XCTAssertEqual(model.allCount, 22)
        _ = model.applyStatusCounts(FolderStatus(messages: 30, unseen: 4, flagged: 2))

        XCTAssertNil(model.savedMessageCount)
        XCTAssertEqual(model.allCount, 30)
        XCTAssertEqual(model.unseen, 4)
        XCTAssertEqual(model.flagged, 2)
    }
}
