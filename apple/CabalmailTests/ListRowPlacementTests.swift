import XCTest
import CabalmailKit
@testable import CabalmailUI

// Every row the list loads names its own message: the paths that bring a
// folder's rows in (a fetched page, the cache snapshot, the window
// re-read) place each row in the list's folder, and the cache keeps its
// stored form, which has no folder. A row left unplaced would key its
// filtered-list identity on its UID alone, out of step with the
// generations the model bumps under its ref (`MessageRowIdentity`).
@MainActor
final class ListRowPlacementTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!

    override func setUp() async throws {
        fixture = RefreshCharacterizationFixture()
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
    }

    private func assertPlaced(
        _ model: MessageListViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(model.envelopes.isEmpty, "rows were loaded", file: file, line: line)
        XCTAssertEqual(
            Set(model.envelopes.map(\.folder)), [fixture.folderPath],
            "every loaded row carries the list's folder", file: file, line: line
        )
    }

    func testAFetchedPageIsPlacedInTheListsFolder() async throws {
        let model = try await fixture.makeModel()

        model.window.mergeFetched(fixture.rows([3, 2, 1]))

        assertPlaced(model)
        XCTAssertEqual(model.envelopes.map { model.rowRef(for: $0) }, [3, 2, 1].map { fixture.ref($0) })
    }

    func testTheCacheSnapshotIsPlacedOnHydrate() async throws {
        let model = try await fixture.makeModel()
        try await fixture.seedSnapshot(model, uids: [3, 2, 1])

        await model.window.hydrateFromCache()

        assertPlaced(model)
    }

    func testARefreshedListIsPlacedButStoresNoFolder() async throws {
        let model = try await fixture.makeModel()
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])

        await model.loadInitial()

        assertPlaced(model)
        // The refresh wrote the placed rows to the snapshot; read back from
        // disk they carry no folder, so the stored form is as it was.
        let snapshot = await fixture.snapshot(model)
        let stored = try XCTUnwrap(snapshot)
        XCTAssertEqual(Set(stored.envelopes.keys), [3, 2, 1])
        XCTAssertTrue(stored.envelopes.values.allSatisfy { $0.folder == nil })
    }

    func testAFilteredListRenewsTheRowItsModelReplaces() async throws {
        // What the filtered / search list draws after a full swipe that left
        // its message in place: a new row for that message only.
        let model = try await fixture.makeModel()
        model.window.mergeFetched(fixture.rows([3, 2, 1]))

        model.replaceRows(showing: [fixture.ref(2)])

        XCTAssertEqual(
            MessageRowIdentity.identify(model.envelopes, generations: model.rowGenerations).map(\.id.generation),
            [0, 1, 0]
        )
    }
}
