import XCTest
@testable import CabalmailKit

/// Changes made on this device (deleting a folder, a subscription, a count
/// changed by reading mail) must reach the saved folder state, or an offline
/// launch shows the folders as they were before.
final class FolderStateLocalChangeTests: XCTestCase {
    private var harness: FolderStateHarness!

    override func setUp() {
        harness = FolderStateHarness()
    }

    override func tearDown() {
        harness = nil
    }

    /// A folder deleted on this device must not come back on an offline
    /// launch, counts and all.
    func testDeletedFolderLeavesTheSavedList() async throws {
        let network = FolderNetwork()
        let online = try await harness.onlineSession(network)
        try await online.deleteFolder(path: "Projects/Cabal")

        await network.set(online: false)
        let client = try harness.launch(network)
        let result = try await client.foldersForDisplay()
        XCTAssertEqual(result.folders.map(\.path), ["INBOX", "Archive"])
        let gone = await client.savedFolderStatus(path: "Projects/Cabal")
        XCTAssertNil(gone)
    }

    /// A list the server answered before a delete, but that lands after it,
    /// must not put the deleted folder back.
    func testListInFlightAcrossADeleteDoesNotRestoreIt() async throws {
        let network = FolderNetwork()
        let online = try await harness.onlineSession(network)

        await network.set(holdNextList: true)
        let inFlight = Task { try await online.folders() }
        try await waitUntil { await network.isHoldingList }
        try await online.deleteFolder(path: "Projects/Cabal")
        await network.releaseList()
        _ = try await inFlight.value

        await network.set(online: false)
        let result = try await harness.launch(network).foldersForDisplay()
        XCTAssertEqual(result.folders.map(\.path), ["INBOX", "Archive"])
    }

    /// Local count changes adjust a folder the server reported, keep the
    /// counts they don't touch, and write nothing for an unknown folder or
    /// after sign-out.
    func testLocalCountsAdjustOnlyWhatTheServerReported() async throws {
        let network = FolderNetwork()
        let online = try await harness.onlineSession(network)
        let cache = online.folderStateCache

        await cache.recordLocalCounts(unseen: 0, messages: nil, for: "INBOX")
        let inbox = await cache.lastKnownStatus(for: "INBOX")
        XCTAssertEqual(inbox?.unseen, 0)
        XCTAssertEqual(inbox?.messages, 22)
        XCTAssertEqual(inbox?.flagged, 1)

        // Emptied (Empty Trash): nothing in it can be flagged.
        await cache.recordLocalCounts(unseen: 0, messages: 0, for: "Projects/Cabal")
        let emptied = await cache.lastKnownStatus(for: "Projects/Cabal")
        XCTAssertEqual(emptied?.flagged, 0)

        await cache.recordLocalCounts(unseen: 3, messages: 9, for: "Unknown")
        let unknown = await cache.lastKnownStatus(for: "Unknown")
        XCTAssertNil(unknown)

        await online.clearLocalData()
        await cache.recordLocalCounts(unseen: 7, messages: 30, for: "INBOX")
        let afterSignOut = await cache.lastKnownStatus(for: "INBOX")
        XCTAssertNil(afterSignOut)
    }

    /// A subscription changed on this device must show on an offline launch.
    func testSubscriptionChangeIsSaved() async throws {
        let network = FolderNetwork()
        let online = try await harness.onlineSession(network)
        try await online.setSubscribed(true, path: "Archive")
        try await online.setSubscribed(false, path: "Projects/Cabal")

        await network.set(online: false)
        let result = try await harness.launch(network).foldersForDisplay()
        XCTAssertEqual(result.folders.filter(\.isSubscribed).map(\.path), ["INBOX", "Archive"])
    }
}
