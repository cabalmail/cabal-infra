import XCTest
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8: the folder list's sliding-window
/// paging, as it stands before the app layer moves into CabalmailUI and mail
/// gets a store layer. Nothing tested `ensureLoaded(around:)` and the loads it
/// launches before this suite. It pins load-more (large-mailbox plan Layer 3.1,
/// the 200-row page from 2f1248ea and the one-page runway from 3f2e831c), the
/// 600-row trim and the top-page refresh skip once trimmed (64794213),
/// load-previous (563c3fc6), and the far jump that replaces the window with
/// one server-sized page (35105d26, 55ec160a).
///
/// The paging paths swallow every error, so a wrong turn into the fake's
/// unscripted trap would fail silently: each test asserts on the page
/// requests the fake recorded and on the rows, never on `errorMessage` alone.
/// Each test waits for the model's own loads (`ListPagingWorld.settle`, in
/// ListPagingWorld.swift) rather than sleeping.
@MainActor
final class MessageListPagingCharacterizationTests: XCTestCase {
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

    // MARK: - Load more

    /// P1. The top page is 50 rows and the runway 250, so the very first row
    /// appearing asks for the next 200-row page straight after the window.
    func testLoadMoreFetchesThe200RowPageAfterTheWindowAndAppendsIt() async throws {
        let model = try await world.openedList()
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<50))
        XCTAssertEqual(model.totalMessages, 1000)
        let opened = await world.pages()
        XCTAssertEqual(opened, [], "opening loads only the top page")

        model.ensureLoaded(around: 0)
        XCTAssertTrue(model.isLoadingMore, "raised synchronously, before the page is asked for")
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 50, limit: 200)])
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<250))
        XCTAssertEqual(model.windowStart, 0)
        XCTAssertFalse(model.hasTrimmedFront)
        XCTAssertEqual(model.envelope(at: 249)?.uid, 751)
        XCTAssertNil(model.envelope(at: 250), "past the window the row is a placeholder")
        XCTAssertNil(model.errorMessage)
    }

    /// Every page, staged or loaded, is asked for in the order the list shows.
    func testPagesCarryTheListsSortOrder() async throws {
        let subject = SortCriterion(field: .subject, direction: .ascending)
        let model = try await world.openedList()

        await model.setSort(subject)
        await world.settle(model)
        model.ensureLoaded(around: 0)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [
            Page(offset: 800, limit: 200, sort: subject),
            Page(offset: 50, limit: 200, sort: subject),
        ], "setSort re-stages the bottom page, then the next page follows the top one")
        let topSorts = await world.imap.topEnvelopesCalls.map(\.sort)
        XCTAssertEqual(topSorts, [.default, subject])
    }

    /// P2. Ten messages arrive at the top before the page is asked for, so
    /// position 50 now holds what was position 40: the page repeats ten loaded
    /// rows, and the merge keeps one of each.
    func testAPageOverlappingLoadedRowsAddsNoDuplicates() async throws {
        let model = try await world.openedList()
        await world.imap.scriptFolderContents(ListPagingWorld.serverFolder(size: 1010))

        model.ensureLoaded(around: 0)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 50, limit: 200)])
        let shown = model.envelopes.map(\.uid)
        XCTAssertEqual(shown.count, Set(shown).count, "no row twice")
        XCTAssertEqual(shown, uids(0..<240), "1000 down to 761: 50 loaded plus 190 new")
        XCTAssertEqual(model.windowStart, 0)
    }

    // MARK: - Trim at the window cap

    /// P3. 500 rows plus a 200-row page is 100 over the 600 cap: the front
    /// goes and the window starts at 100. From then on a refresh fetches no
    /// top page (it would splice a gap above the rows). New mail above the
    /// window still moves every server position under it, so the counts send
    /// the window to be read again by position, one page centred on it: the
    /// rows move to where the server now has them (#1818).
    func testTheWindowTrimsItsFrontAtTheCapAndARefreshRealignsItWithoutTheTopPage() async throws {
        let model = try await world.openedList(preloaded: 500)
        XCTAssertEqual(model.envelopes.count, 500)

        model.ensureLoaded(around: 499)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 500, limit: 200)])
        XCTAssertEqual(model.envelopes.count, 600)
        XCTAssertEqual(model.windowStart, 100)
        XCTAssertTrue(model.hasTrimmedFront)
        XCTAssertEqual(model.envelopes.map(\.uid), uids(100..<700))
        XCTAssertNil(model.envelope(at: 99))
        XCTAssertEqual(model.envelope(at: 100)?.uid, 900)

        let topFetches = await world.imap.topEnvelopesCalls.count
        let statuses = await world.imap.statusCalls.count
        // Three messages arrive on top: the folder now holds 1003.
        await world.imap.scriptFolderContents(ListPagingWorld.serverFolder(size: 1003))
        await world.imap.scriptStatusResults([.success(ListPagingWorld.status(messages: 1003))])
        await model.refresh()

        let topFetchesAfter = await world.imap.topEnvelopesCalls.count
        let statusesAfter = await world.imap.statusCalls.count
        let pagesAfter = await world.pages()
        XCTAssertEqual(statusesAfter, statuses + 1, "STATUS still runs")
        XCTAssertEqual(topFetchesAfter, topFetches, "no top page once the front is trimmed")
        XCTAssertEqual(pagesAfter.last, Page(offset: 275, limit: 250), "one page centred on the window")
        XCTAssertEqual(model.totalMessages, 1003, "the counts move")
        XCTAssertEqual(model.windowStart, 275)
        XCTAssertEqual(model.envelopes.map(\.uid), uids(275..<525, size: 1003), "and so do the rows")
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Load previous

    /// P4. A row near the top of a trimmed window refills the 200 rows above
    /// it, trims the bottom back to the cap, and re-anchors the window at the
    /// top, which turns the top-page refresh back on.
    func testLoadPreviousRefillsTheFrontAndReanchorsTheWindowAtTheTop() async throws {
        let model = try await world.openedList(preloaded: 600)
        model.ensureLoaded(around: 599)
        await world.settle(model)
        XCTAssertEqual(model.windowStart, 200)
        XCTAssertTrue(model.hasTrimmedFront)

        model.ensureLoaded(around: 200)
        XCTAssertTrue(model.isLoadingPrevious)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 600, limit: 200), Page(offset: 0, limit: 200)])
        XCTAssertEqual(model.windowStart, 0)
        XCTAssertFalse(model.hasTrimmedFront)
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<600), "the bottom 200 trimmed away")

        let topFetches = await world.imap.topEnvelopesCalls.count
        await model.refresh()
        let topFetchesAfter = await world.imap.topEnvelopesCalls.count
        XCTAssertEqual(topFetchesAfter, topFetches + 1, "the top page is refreshed again")
    }

    /// Above a front trimmed by fewer than 200 rows, load-previous asks for
    /// just those rows.
    func testLoadPreviousAsksOnlyForTheRowsAboveAShortTrimmedFront() async throws {
        let model = try await world.openedList(preloaded: 500)
        model.ensureLoaded(around: 499)
        await world.settle(model)
        XCTAssertEqual(model.windowStart, 100)

        model.ensureLoaded(around: 100)
        XCTAssertTrue(model.isLoadingPrevious)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [Page(offset: 500, limit: 200), Page(offset: 0, limit: 100)])
        XCTAssertEqual(model.windowStart, 0)
        XCTAssertFalse(model.hasTrimmedFront)
        XCTAssertEqual(model.envelopes.map(\.uid), uids(0..<600))
    }

    /// Pins current behaviour, which looks like a defect: a fresh jump window
    /// is one 200-row page (55ec160a), shorter than the 250-row runway, and
    /// `ensureLoaded` tries the bottom edge first, so every index in or just
    /// above the window counts as near the bottom. Scrolling up from it, the
    /// first row above the window loads the page *below* and stays a
    /// placeholder; only the next appearance loads the rows above. The settle
    /// backstop would ask for that page below anyway, so the cost is order:
    /// the rows above wait one extra round trip.
    /// Tracked in #1823.
    func testARowJustAboveAFreshJumpWindowLoadsThePageBelowFirst() async throws {
        let model = try await world.openedList()
        model.ensureLoaded(around: 400)
        await world.settle(model)
        XCTAssertEqual(model.windowStart, 300)

        model.ensureLoaded(around: 299)
        XCTAssertTrue(model.isLoadingMore)
        XCTAssertFalse(model.isLoadingPrevious)
        await world.settle(model)
        XCTAssertNil(model.envelope(at: 299), "the row scrolled to is still a placeholder")

        model.ensureLoaded(around: 299)
        XCTAssertTrue(model.isLoadingPrevious)
        await world.settle(model)

        let pages = await world.pages()
        XCTAssertEqual(pages, [
            Page(offset: 300, limit: 200),
            Page(offset: 500, limit: 200),
            Page(offset: 100, limit: 200),
        ])
        XCTAssertEqual(model.windowStart, 100)
        XCTAssertEqual(model.envelope(at: 299)?.uid, 701)
    }

    // MARK: - Far jump

    /// P5. A target beyond the runway replaces the window with one 200-row
    /// page starting 100 rows above it, clamped to the folder's last page.
    /// The window is replaced, not merged: the top rows are gone.
    func testAFarJumpReplacesTheWindowWithOnePageCenteredOnTheTarget() async throws {
        for (target, start) in [(900, 800), (990, 800), (999, 800), (400, 300)] {
            let model = try await world.openedList()
            let asked = await world.pages().count

            model.ensureLoaded(around: target)
            XCTAssertTrue(model.isLoadingWindow)
            await world.settle(model)

            let pages = await world.pages()
            XCTAssertEqual(pages.count, asked + 1, "one page for a jump to \(target)")
            XCTAssertEqual(pages.last, Page(offset: UInt32(start), limit: 200), "jump to \(target)")
            XCTAssertEqual(model.windowStart, UInt32(start))
            XCTAssertEqual(model.envelopes.map(\.uid), uids(start..<(start + 200)))
            XCTAssertTrue(model.hasTrimmedFront)
            XCTAssertNil(model.envelope(at: 0), "the top page is dropped, not merged")
            XCTAssertEqual(model.envelope(at: target)?.uid, UInt32(1000 - target))
        }
    }
}
