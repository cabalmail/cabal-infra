import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8: the bottom-window prefetch that
/// makes the first End / jump-to-bottom instant (dd885cbf). `loadInitial`
/// stages the folder's last 200-row page off to the side; the first far jump
/// that lands in it adopts it with no round trip; a change in the folder's
/// size drops it so a misaligned window is never shown.
///
/// Like the other paging suites (see ListPagingWorld.swift), every test
/// asserts on the page requests the fake recorded, because the prefetch
/// swallows its errors, and waits for the model's own loads instead of
/// sleeping.
@MainActor
final class MessageListBottomPrefetchCharacterizationTests: XCTestCase {
    private typealias Page = ListPagingWorld.Page
    private var world: ListPagingWorld!

    override func setUp() async throws {
        // A hold that is never reached would otherwise hang until the CI job
        // times out without naming the test.
        executionTimeAllowance = 60
        world = ListPagingWorld()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    /// A list opened the way the view opens it, with the bottom page staged.
    private func openedWithStagedBottom(size: Int = 1000) async throws -> MessageListViewModel {
        await world.scriptServer(size: size)
        let model = try world.makeModel()
        await model.loadInitial()
        await world.settle(model)
        return model
    }

    /// P6. Opening a 1000-message folder asks for its last page (offset 800)
    /// in the background; the rows stay the top page until a jump.
    func testOpeningALargeFolderStagesTheBottomPageAndTheFirstJumpThereAdoptsIt() async throws {
        let model = try await openedWithStagedBottom()

        let staged = await world.pages()
        XCTAssertEqual(staged, [Page(offset: 800, limit: 200)])
        XCTAssertEqual(model.envelopes.map(\.uid), ListPagingWorld.uids(0..<50), "staged off to the side")
        XCTAssertNil(model.envelope(at: 999))

        model.ensureLoaded(around: 999)
        XCTAssertTrue(model.isLoadingWindow)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 800, limit: 200)], "adopted with no round trip")
        XCTAssertEqual(model.windowStart, 800)
        XCTAssertEqual(model.envelopes.map(\.uid), ListPagingWorld.uids(800..<1000))
        XCTAssertEqual(model.envelope(at: 999)?.uid, 1)
        XCTAssertTrue(model.hasTrimmedFront)
    }

    /// The staged page is consumed by the jump that adopts it: jumping away
    /// and back fetches the bottom again.
    func testTheStagedBottomPageIsUsedOnce() async throws {
        let model = try await openedWithStagedBottom()
        model.ensureLoaded(around: 999)
        await world.settle(model)

        model.ensureLoaded(around: 100)
        await world.settle(model)
        model.ensureLoaded(around: 999)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [
            Page(offset: 800, limit: 200),
            Page(offset: 0, limit: 200),
            Page(offset: 800, limit: 200),
        ])
        XCTAssertEqual(model.envelopes.map(\.uid), ListPagingWorld.uids(800..<1000))
    }

    /// The staged page is adopted only by a jump that lands inside it. A jump
    /// to row 500 fetches its own page around the target and leaves the
    /// staged page alone, so a later End still adopts it with no round trip.
    func testAJumpOutsideTheStagedBottomPageFetchesAndKeepsItStaged() async throws {
        let model = try await openedWithStagedBottom()

        model.ensureLoaded(around: 500)
        XCTAssertTrue(model.isLoadingWindow)
        await world.settle(model)

        let jumped = await world.pages()
        XCTAssertEqual(jumped, [Page(offset: 800, limit: 200), Page(offset: 400, limit: 200)])
        XCTAssertEqual(model.windowStart, 400)
        XCTAssertEqual(model.envelope(at: 500)?.uid, 500)

        model.ensureLoaded(around: 999)
        XCTAssertTrue(model.isLoadingWindow)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, jumped, "the staged page survived the jump to 500 and is adopted now")
        XCTAssertEqual(model.windowStart, 800)
        XCTAssertEqual(model.envelope(at: 999)?.uid, 1)
    }

    /// One message arrives: the refresh's STATUS changes the total, which drops
    /// the staged page, so the jump fetches the new last page (offset 801).
    /// Two defences produce this today: `applyStatusCounts` drops the staged
    /// page, and the jump refuses one stamped with another total. Removing
    /// either alone keeps this test green; the in-flight test below fails
    /// without the first.
    func testARefreshThatChangesTheFolderSizeDropsTheStagedBottomPage() async throws {
        let model = try await openedWithStagedBottom()
        await world.scriptServer(size: 1001)

        await model.refresh()
        XCTAssertEqual(model.totalMessages, 1001)
        model.ensureLoaded(around: 999)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 800, limit: 200), Page(offset: 801, limit: 200)])
        XCTAssertEqual(model.windowStart, 801)
        XCTAssertEqual(model.envelopes.map(\.uid), ListPagingWorld.uids(801..<1001, size: 1001))
    }

    /// Negative control for the test above: a refresh that leaves the total
    /// alone keeps the staged page.
    func testARefreshThatKeepsTheFolderSizeKeepsTheStagedBottomPage() async throws {
        let model = try await openedWithStagedBottom()
        let statuses = await world.imap.statusCalls.count

        await model.refresh()
        let statusesAfter = await world.imap.statusCalls.count
        XCTAssertEqual(statusesAfter, statuses + 1, "the refresh ran its STATUS")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.totalMessages, 1000)
        model.ensureLoaded(around: 999)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 800, limit: 200)])
        XCTAssertEqual(model.windowStart, 800)
    }

    /// A fill still in flight when the folder's size changes is cancelled and
    /// stages nothing. The size goes 1000, 1001, then back to 1000 while the
    /// fill is out, so when it lands its stamp matches the live total again:
    /// only the cancel keeps it from being staged and then adopted.
    func testABottomPrefetchInFlightWhenTheFolderSizeChangesStagesNothing() async throws {
        await world.scriptServer(size: 1000)
        await world.imap.holdNext(.envelopes)
        let model = try world.makeModel()
        await model.loadInitial()
        await world.imap.awaitHeld(.envelopes)
        let fill = model.bottomPrefetchTask

        await world.scriptServer(size: 1001)
        await model.refresh()
        XCTAssertEqual(model.totalMessages, 1001)
        XCTAssertNil(model.bottomPrefetchTask, "the size change drops the fill")
        await world.scriptServer(size: 1000)
        await model.refresh()
        XCTAssertEqual(model.totalMessages, 1000)
        XCTAssertNil(model.errorMessage)
        await world.imap.releaseHeld(.envelopes)
        await fill?.value
        model.ensureLoaded(around: 999)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(
            pages, [Page(offset: 800, limit: 200), Page(offset: 800, limit: 200)],
            "nothing was staged, so the jump fetches the bottom page itself"
        )
        XCTAssertEqual(model.windowStart, 800)
        XCTAssertEqual(model.envelope(at: 999)?.uid, 1)
    }

    /// Only a folder bigger than the 600-row window cap gets a staged bottom;
    /// for one, it is the last 200 rows.
    func testOnlyAFolderLargerThanTheWindowCapStagesABottomPage() async throws {
        _ = try await openedWithStagedBottom(size: 600)
        let none = await world.pages()
        XCTAssertEqual(none, [])

        _ = try await openedWithStagedBottom(size: 601)
        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 401, limit: 200)])
    }

    /// A failed fill is silent and leaves End to the normal round trip.
    func testAFailedBottomPrefetchIsSilentAndTheJumpFetchesTheBottom() async throws {
        await world.imap.scriptEnvelopesResults([.failure(CabalmailError.network("offline"))])
        let model = try await openedWithStagedBottom()
        XCTAssertNil(model.errorMessage)

        model.ensureLoaded(around: 999)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 800, limit: 200), Page(offset: 800, limit: 200)])
        XCTAssertEqual(model.envelopes.map(\.uid), ListPagingWorld.uids(800..<1000))
    }
}
