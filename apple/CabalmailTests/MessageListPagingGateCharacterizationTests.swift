import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8: when `ensureLoaded(around:)`
/// declines to load, what a failed or empty page does, and how a refresh and
/// an in-flight page interleave. `ensureLoaded` is a single-flight gate (the
/// index-addressed list, 35105d26) that stands down while a refresh, a
/// search, an optimistic removal or another page load is in flight. Failed
/// pages are swallowed by design (best-effort pagination since 750dba7a),
/// which the P8 tests pin so a refactor does not start surfacing page errors
/// by accident. `hasMore` is written but never read, which the P9 test pins
/// as a weakness so the refactor flips it on purpose rather than by accident.
///
/// Races are staged with the fake's hold-and-release gates, never with
/// timing; see ListPagingWorld.swift.
@MainActor
final class MessageListPagingGateCharacterizationTests: XCTestCase {
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

    private func uids(_ range: Range<Int>, size: Int = 1000) -> [UInt32] {
        ListPagingWorld.uids(range, size: size)
    }

    /// Asks for a page below (index 0) and a far jump (index 900), then checks
    /// neither started.
    private func assertNoLoadStarts(
        _ model: MessageListViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        model.ensureLoaded(around: 0)
        model.ensureLoaded(around: 900)
        XCTAssertFalse(model.isLoadingMore, file: file, line: line)
        XCTAssertFalse(model.isLoadingWindow, file: file, line: line)
        XCTAssertFalse(model.isLoadingPrevious, file: file, line: line)
    }

    // MARK: - P7: the gates

    /// The single-flight gate `ensureLoaded` took over from `loadMoreIfNeeded`
    /// in 35105d26: no page while a refresh holds `isLoading`.
    func testNoPageLoadsWhileARefreshIsInFlight() async throws {
        let model = try await world.openedList()
        await world.imap.holdNext(.status)
        let refresh = Task { await model.refresh() }
        await world.imap.awaitHeld(.status)
        XCTAssertTrue(model.isLoading)

        assertNoLoadStarts(model)
        await world.imap.releaseHeld(.status)
        await refresh.value
        await world.settle(model)
        let gated = await world.pages()
        XCTAssertEqual(gated, [])

        model.ensureLoaded(around: 0)
        await world.settle(model)
        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 50, limit: 200)], "control: the same call loads once the refresh is done")
    }

    /// No folder page under search results: search-mode paging once appended
    /// folder pages to cross-folder results and leaked their foreign UIDs into
    /// the folder's snapshot (the guard comment 35105d26 replaced; 81e850f4).
    func testNoPageLoadsWhileASearchIsShowing() async throws {
        let model = try await world.openedList()
        model.isSearchActive = true

        assertNoLoadStarts(model)
        await world.settle(model)
        let gated = await world.pages()
        XCTAssertEqual(gated, [])

        model.isSearchActive = false
        model.ensureLoaded(around: 0)
        await world.settle(model)
        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 50, limit: 200)])
    }

    /// While a dispose's move is in flight the positions are about to shift,
    /// so nothing loads; once it lands the next page starts one row earlier.
    func testNoPageLoadsWhileARemovalIsInFlight() async throws {
        let model = try await world.openedList()
        await world.imap.holdNext(.move)
        let first = try XCTUnwrap(model.envelopes.first)
        let dispose = Task { await model.dispose(first) }
        await world.imap.awaitHeld(.move)

        assertNoLoadStarts(model)
        await world.imap.scriptFolderContents(Array(ListPagingWorld.serverFolder(size: 1000).dropFirst()))
        await world.imap.releaseHeld(.move)
        await dispose.value
        await world.settle(model)
        let gated = await world.pages()
        XCTAssertEqual(gated, [])
        XCTAssertEqual(model.envelopes.count, 49)
        XCTAssertEqual(model.totalMessages, 999)

        model.ensureLoaded(around: 0)
        await world.settle(model)
        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 49, limit: 200)])
        XCTAssertEqual(model.envelopes.map(\.uid), uids(1..<250))
    }

    /// A folder that fits in the window has nothing below or above to load.
    func testNothingLoadsOnceTheWindowHoldsTheWholeFolder() async throws {
        let model = try await world.openedList(size: 50)
        for index in [0, 25, 49] {
            model.ensureLoaded(around: index)
            XCTAssertFalse(model.isLoadingMore, "row \(index)")
            XCTAssertFalse(model.isLoadingPrevious, "row \(index)")
        }
        await world.settle(model)
        let pages = await world.pages()
        XCTAssertEqual(pages, [])
    }

    /// At the folder's bottom (window end == total) a row loads the page
    /// above, never one below.
    func testAtTheFolderBottomARowLoadsThePageAboveNeverOneBelow() async throws {
        let model = try await world.openedList()
        model.ensureLoaded(around: 990)
        await world.settle(model)
        XCTAssertEqual(model.windowStart, 800)

        model.ensureLoaded(around: 999)
        XCTAssertFalse(model.isLoadingMore)
        XCTAssertTrue(model.isLoadingPrevious)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 800, limit: 200), Page(offset: 600, limit: 200)])
        XCTAssertEqual(model.windowStart, 600)
        XCTAssertEqual(model.envelopes.map(\.uid), uids(600..<1000))
    }

    /// One load at a time: further calls while a page is out are dropped,
    /// including a far jump, and nothing re-asks when it lands.
    func testCallsWhileAPageIsInFlightAreDropped() async throws {
        let model = try await world.openedList()
        await world.imap.holdNext(.envelopes)
        model.ensureLoaded(around: 0)
        await world.imap.awaitHeld(.envelopes)

        model.ensureLoaded(around: 0)
        model.ensureLoaded(around: 40)
        model.ensureLoaded(around: 900)
        XCTAssertTrue(model.isLoadingMore)
        XCTAssertFalse(model.isLoadingWindow)
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 50, limit: 200)])
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<250))
    }

    /// The far jump joined the single-flight gate with `isLoadingWindow`
    /// (35105d26): while it is out, rows near the old window load nothing.
    func testNoPageLoadsWhileAJumpIsInFlight() async throws {
        let model = try await world.openedList()
        await world.imap.holdNext(.envelopes)
        model.ensureLoaded(around: 900)
        await world.imap.awaitHeld(.envelopes)

        model.ensureLoaded(around: 0)
        model.ensureLoaded(around: 500)
        XCTAssertFalse(model.isLoadingMore)
        XCTAssertFalse(model.isLoadingPrevious)
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 800, limit: 200)])
    }

    // MARK: - P8: failures are silent

    /// Pins intended best-effort paging (750dba7a): a failed page shows no
    /// error and leaves the rows alone. Only a list blocked entirely shows
    /// one, through `refresh()` (a failed STATUS or top page), which the
    /// view's poll and the watcher keep running. Pinned so a refactor does
    /// not start surfacing page errors by accident. An open design question,
    /// not a defect: offline, rows past the window stay placeholders with no
    /// feedback until the next refresh. The next row to appear retries.
    func testAFailedPageIsSilentAndTheNextRowRetriesIt() async throws {
        let model = try await world.openedList()
        await world.imap.scriptEnvelopesResults([.failure(CabalmailError.network("offline"))])

        model.ensureLoaded(around: 0)
        await world.settle(model)

        XCTAssertNil(model.errorMessage)
        // `hasMore` is write-only state (see P9): nothing reads it, so the
        // retry below, not this flag, is what carries the pin.
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<50))

        model.ensureLoaded(around: 0)
        await world.settle(model)
        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 50, limit: 200), Page(offset: 50, limit: 200)])
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<250))
    }

    /// The same best-effort policy for a far jump and for load-previous: the
    /// window stays as it was and no error shows.
    func testAFailedJumpOrPreviousPageIsSilentAndLeavesTheWindowAlone() async throws {
        let jumped = try await world.openedList()
        await world.imap.scriptEnvelopesResults([.failure(CabalmailError.network("offline"))])
        jumped.ensureLoaded(around: 900)
        XCTAssertTrue(jumped.isLoadingWindow)
        await world.settle(jumped)
        XCTAssertNil(jumped.errorMessage)
        XCTAssertEqual(jumped.windowStart, 0)
        XCTAssertEqual(jumped.envelopes.map(\.uid), uids(0..<50))

        let trimmed = try await world.openedList(preloaded: 600)
        trimmed.ensureLoaded(around: 599)
        await world.settle(trimmed)
        await world.imap.scriptEnvelopesResults([.failure(CabalmailError.network("offline"))])
        trimmed.ensureLoaded(around: 200)
        XCTAssertTrue(trimmed.isLoadingPrevious)
        await world.settle(trimmed)
        XCTAssertNil(trimmed.errorMessage)
        XCTAssertEqual(trimmed.windowStart, 200)
        XCTAssertTrue(trimmed.hasTrimmedFront)
        XCTAssertEqual(trimmed.envelopes.map(\.uid), uids(200..<800))

        let pages = await world.pages()
        XCTAssertEqual(pages, [
            Page(offset: 800, limit: 200),
            Page(offset: 600, limit: 200),
            Page(offset: 0, limit: 200),
        ])
    }

    // MARK: - P9: an empty page

    /// Pins a known weakness: `hasMore` is written but never read; paging gates
    /// on the window's end against STATUS's total. When STATUS over-counts
    /// (1000 reported, 50 there), the empty page sets `hasMore` false, yet
    /// every row that appears asks for the same empty page again.
    /// Tracked in #1823.
    func testAnEmptyPageEndsHasMoreButTheNextRowAsksForTheSamePageAgain() async throws {
        let model = try await world.openedList(size: 50, statusCount: 1000)
        XCTAssertEqual(model.totalMessages, 1000)

        for index in [0, 10, 49] {
            model.ensureLoaded(around: index)
            await world.settle(model)
            XCTAssertFalse(model.hasMore, "after row \(index)")
        }

        let pages = await world.pages()
        XCTAssertEqual(pages, Array(repeating: Page(offset: 50, limit: 200), count: 3))
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<50, size: 50))
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - P10: a refresh while a page is out

    /// A refresh does not wait for, or cancel, a page in flight. Ten messages
    /// arrive while the page at offset 250 is out; the refresh folds them in
    /// on top (260 rows), and the page still answers for offset 250, captured
    /// before the refresh, so it repeats ten rows that the merge dedups.
    func testARefreshWhileAPageIsInFlightMergesWithoutDuplicates() async throws {
        let model = try await world.openedList()
        model.ensureLoaded(around: 0)
        await world.settle(model)
        await world.imap.holdNext(.envelopes)
        model.ensureLoaded(around: 249)
        await world.imap.awaitHeld(.envelopes)

        await world.scriptServer(size: 1010)
        await model.refresh()
        XCTAssertTrue(model.isLoadingMore, "the page is still out")
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.totalMessages, 1010)
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<260, size: 1010))

        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 50, limit: 200), Page(offset: 250, limit: 200)])
        let shown = model.envelopes.map(\.uid)
        XCTAssertEqual(shown.count, Set(shown).count, "no row twice")
        XCTAssertEqual(shown, uids(0..<450, size: 1010), "1010 down to 561")
        XCTAssertEqual(model.windowStart, 0)
    }
}
