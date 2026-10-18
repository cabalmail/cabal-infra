import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A list that starts over — the Refresh command's hard reload, or leaving a
/// search — clears its folder total to zero until the refresh it starts
/// answers. A STATUS that may predate a removal this client already applied
/// may lower the total but not raise it, and that bound used to be taken
/// against the placeholder zero, so the All pill read 0 and 0 was saved as
/// the folder's total for the next offline launch (#1977). The bound is now
/// taken against what the list believed when the reload started.
@MainActor
final class ReloadDuringRemovalCountTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!
    private var scratch: URL!

    override func setUp() async throws {
        fixture = RefreshCharacterizationFixture()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("reload-removal-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The saved counts need a directory to write to; the default cache has
    /// none and saves nothing.
    private func wireSavedCounts() async -> FolderStateCache {
        let cache = FolderStateCache(directory: scratch.appendingPathComponent("folders"))
        // A local count is saved over a status the cache already has.
        await cache.recordStatus(fixture.status(messages: 3, unseen: 2), for: fixture.folderPath, ifUnchangedSince: 0)
        fixture.mailStore.counts.savedFolderCounts.cache = cache
        fixture.mailStore.counts.setFolderCounts(folderPath: fixture.folderPath, unread: 2, total: 3)
        return cache
    }

    /// Puts the list in the state a reload can arrive in: a removal this
    /// client has applied (the row and its place in the total are gone) with
    /// the move still in flight, so a STATUS answered now may still count
    /// the departed message. `dispose` records exactly this pair; recording
    /// it directly keeps the arm off the network and off the row animation.
    private func removalInFlight(_ model: MessageListViewModel, uid: UInt32) -> MessageRef {
        let ref = fixture.ref(uid)
        fixture.mailStore.shields.beginRemoval([ref])
        model.envelopes.removeAll { $0.uid == uid }
        model.adjustTotalMessages(by: -1)
        return ref
    }

    func testAHardReloadWhileARemovalIsInFlightKeepsTheCountTheListShowed() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        let saved = await wireSavedCounts()
        // The server still counts the archived message: its move is held.
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 2)
        let removed = removalInFlight(model, uid: 3)
        XCTAssertEqual(model.window!.totalMessages, 2, "precondition: the removal took its message from the total")

        await model.hardReload()

        XCTAssertEqual(model.window!.totalMessages, 2, "the count the list showed when the reload started")
        XCTAssertEqual(model.allCount, 2)
        // What an offline launch would read: the same count, not zero.
        try await eventually { await saved.lastKnownStatus(for: self.fixture.folderPath)?.messages == 2 }

        fixture.mailStore.shields.endRemoval([removed])
    }

    /// The same for leaving a search, the other path that clears the total.
    func testClearingASearchWhileARemovalIsInFlightKeepsTheCountTheListShowed() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        _ = await wireSavedCounts()
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 2)
        let removed = removalInFlight(model, uid: 3)

        await model.clearSearch()

        XCTAssertEqual(model.window!.totalMessages, 2)
        fixture.mailStore.shields.endRemoval([removed])
    }

    /// The control: the identical reload with nothing in flight takes the
    /// server's count, so the zero above is the bound and not the reload.
    func testAHardReloadWithNothingInFlightTakesTheServersCount() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        let saved = await wireSavedCounts()
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 2)

        await model.hardReload()

        XCTAssertEqual(model.window!.totalMessages, 3)
        XCTAssertEqual(model.allCount, 3)
        try await eventually { await saved.lastKnownStatus(for: self.fixture.folderPath)?.messages == 3 }
    }

    /// The bound still holds a reply that predates a removal: a STATUS
    /// counting the archived message cannot raise the total back over it.
    func testTheBoundStillHoldsAStatusThatPredatesTheRemoval() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        _ = await wireSavedCounts()
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 2)
        let removed = removalInFlight(model, uid: 3)

        await model.refresh()

        XCTAssertEqual(model.window!.totalMessages, 2, "the server's 3 counts the message already removed here")
        fixture.mailStore.shields.endRemoval([removed])
    }
}
