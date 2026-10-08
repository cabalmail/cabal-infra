import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A folder load still out when a search starts lands nowhere (#1870). A
/// pill is a search (`selectFilter` runs one) and the cheapest trigger, so
/// each test holds one of the list's loads, or a refresh, at the fake, lets
/// the Unread pill's search finish, releases what it held, and checks that
/// the list shows the pill's matches alone and the folder's snapshot took
/// neither the load's rows nor the matches. The later sections cover what a
/// search stands down while it is still out, and what one that fails gives
/// back. Resets stand loads down the same way
/// (`MessageListResetStandDownTests`).
///
/// The fake answers a held page even when its task was cancelled meanwhile
/// (`answerEnvelopesAfterCancellation()`), as a page already on its way back
/// does, so what drops it is the window's generation, not the cancel. The
/// cancel is checked on its own.
@MainActor
final class MessageListSearchStandDownTests: XCTestCase {
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

    /// The Unread pill's matches: two rows no folder page holds.
    private static let matches: [UInt32] = [5002, 5001]

    private func scriptPill() async {
        await world.imap.scriptSearch(SearchResult(
            envelopes: Self.matches.map {
                SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: $0), folder: ListPagingWorld.folderPath)
            },
            totalEstimate: Self.matches.count,
            nextCursor: nil,
            foldersSearched: [ListPagingWorld.folderPath],
            truncated: false
        ))
    }

    /// The pill has run and the held load has landed: only the matches show,
    /// and once any debounced write has come due, the snapshot is as it was.
    private func assertOnlyTheMatches(
        _ model: MessageListViewModel,
        snapshotBefore: Set<UInt32>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertTrue(model.isSearchActive, file: file, line: line)
        XCTAssertEqual(model.envelopes.map(\.uid), Self.matches, "no folder row among the matches",
                       file: file, line: line)
        await model.persistTask?.value
        let after = await world.snapshotUIDs(model)
        XCTAssertEqual(after, snapshotBefore, "the snapshot took neither the page nor the matches",
                       file: file, line: line)
    }

    // MARK: - The three page loads

    func testAPageBelowStillOutWhenAPillStartsLandsNowhere() async throws {
        let model = try await world.openedList()
        let before = await world.snapshotUIDs(model)
        await scriptPill()
        await world.imap.answerEnvelopesAfterCancellation()
        await world.imap.holdNext(.envelopes)
        model.ensureLoaded(around: 0)
        XCTAssertTrue(model.isLoadingMore)
        await world.imap.awaitHeld(.envelopes)

        await model.selectFilter(.unread)
        XCTAssertEqual(model.loadMoreTask?.isCancelled, true, "the search stood the page down")
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        await assertOnlyTheMatches(model, snapshotBefore: before)
    }

    func testAPageAboveStillOutWhenAPillStartsLandsNowhere() async throws {
        let model = try await world.openedList(preloaded: 600)
        model.ensureLoaded(around: 599)
        await world.settle(model)
        XCTAssertEqual(model.windowStart, 200)
        let before = await world.snapshotUIDs(model)
        await scriptPill()
        await world.imap.answerEnvelopesAfterCancellation()
        await world.imap.holdNext(.envelopes)
        model.ensureLoaded(around: 200)
        XCTAssertTrue(model.isLoadingPrevious)
        await world.imap.awaitHeld(.envelopes)

        await model.selectFilter(.unread)
        XCTAssertEqual(model.loadPrevTask?.isCancelled, true, "the search stood the page down")
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        await assertOnlyTheMatches(model, snapshotBefore: before)
    }

    func testAJumpStillOutWhenAPillStartsLandsNowhere() async throws {
        let model = try await world.openedList()
        let before = await world.snapshotUIDs(model)
        await scriptPill()
        await world.imap.answerEnvelopesAfterCancellation()
        await world.imap.holdNext(.envelopes)
        model.ensureLoaded(around: 900)
        XCTAssertTrue(model.isLoadingWindow)
        await world.imap.awaitHeld(.envelopes)

        await model.selectFilter(.unread)
        XCTAssertEqual(model.loadWindowTask?.isCancelled, true, "the search stood the jump down")
        await world.imap.releaseHeld(.envelopes)
        await world.settle(model)

        await assertOnlyTheMatches(model, snapshotBefore: before)
    }

    // MARK: - A refresh still out

    /// A refresh's top page that lands under the matches would have been
    /// folded into them, and, as the window then fits one top page, pruned
    /// them as gone from the folder. The search doesn't lower `isLoading`
    /// under the refresh either (#1820).
    func testARefreshsTopPageStillOutWhenAPillStartsLandsNowhere() async throws {
        let model = try await world.openedList()
        let before = await world.snapshotUIDs(model)
        await scriptPill()
        await world.imap.holdNext(.topEnvelopes)
        let refresh = Task { await model.refresh() }
        await world.imap.awaitHeld(.topEnvelopes)

        await model.selectFilter(.unread)
        XCTAssertTrue(model.isLoading, "the refresh is still out")
        await world.imap.releaseHeld(.topEnvelopes)
        await refresh.value

        XCTAssertFalse(model.isLoading)
        await assertOnlyTheMatches(model, snapshotBefore: before)
    }

    /// The same with the refresh's STATUS still out: the pass stands down as
    /// it answers, before it asks for a top page at all.
    func testARefreshsStatusStillOutWhenAPillStartsLandsNowhere() async throws {
        let model = try await world.openedList()
        let before = await world.snapshotUIDs(model)
        let topsBefore = await world.imap.topEnvelopesCalls.count
        await scriptPill()
        await world.imap.holdNext(.status)
        let refresh = Task { await model.refresh() }
        await world.imap.awaitHeld(.status)

        await model.selectFilter(.unread)
        await world.imap.releaseHeld(.status)
        await refresh.value

        let tops = await world.imap.topEnvelopesCalls.count
        XCTAssertEqual(tops, topsBefore, "no top page for a pass the pill overtook")
        await assertOnlyTheMatches(model, snapshotBefore: before)
    }

    // MARK: - While the search is out

    /// A refresh that starts while the pill's search is out, when the folder
    /// rows still show, is addressed to them too: its top page lands after
    /// the matches have replaced them, and is dropped.
    func testARefreshStartedWhileThePillsSearchIsOutLandsNowhere() async throws {
        let model = try await world.openedList()
        let before = await world.snapshotUIDs(model)
        await scriptPill()
        await world.imap.holdNextSearch()
        let pill = Task { await model.selectFilter(.unread) }
        await world.imap.awaitHeldSearch()
        await world.imap.holdNext(.topEnvelopes)
        let refresh = Task { await model.refresh() }
        await world.imap.awaitHeld(.topEnvelopes)

        await world.imap.releaseHeldSearch()
        await pill.value
        await world.imap.releaseHeld(.topEnvelopes)
        await refresh.value

        await assertOnlyTheMatches(model, snapshotBefore: before)
    }

    /// The stand-down comes as the search starts, not only as it lands: a
    /// page released while the pill's search is still out is dropped too,
    /// and the folder rows it was addressed to stay as they were.
    func testAPageStillOutWhenAPillStartsIsStoodDownBeforeItsSearchAnswers() async throws {
        let model = try await world.openedList()
        await scriptPill()
        await world.imap.answerEnvelopesAfterCancellation()
        await world.imap.holdNext(.envelopes)
        model.ensureLoaded(around: 0)
        await world.imap.awaitHeld(.envelopes)
        await world.imap.holdNextSearch()
        let pill = Task { await model.selectFilter(.unread) }
        await world.imap.awaitHeldSearch()

        XCTAssertEqual(model.loadMoreTask?.isCancelled, true, "stood down as the search started")
        await world.imap.releaseHeld(.envelopes)
        await model.loadMoreTask?.value
        XCTAssertEqual(model.envelopes.map(\.uid), ListPagingWorld.uids(0..<50), "the page was dropped")

        await world.imap.releaseHeldSearch()
        await pill.value
        XCTAssertEqual(model.envelopes.map(\.uid), Self.matches)
    }

    /// A search holds `isLoading` as a refresh does (#1820), so no folder page
    /// starts while it is out, to land under its results later.
    func testNoPageStartsWhileThePillsSearchIsOut() async throws {
        let model = try await world.openedList()
        await scriptPill()
        await world.imap.holdNextSearch()
        let pill = Task { await model.selectFilter(.unread) }
        await world.imap.awaitHeldSearch()

        XCTAssertTrue(model.isLoading)
        model.ensureLoaded(around: 0)
        model.ensureLoaded(around: 900)
        XCTAssertFalse(model.isLoadingMore)
        XCTAssertFalse(model.isLoadingWindow)

        await world.imap.releaseHeldSearch()
        await pill.value
        let pages = await world.pages()
        XCTAssertEqual(pages, [], "no folder page was asked for")
        XCTAssertEqual(model.envelopes.map(\.uid), Self.matches)
    }

    // MARK: - A refresh waiting on a page in flight

    /// A refresh whose re-read waits for a page already out
    /// (`ListPagingWorld.refreshWaitingOnAPage()`): a pill that lands
    /// meanwhile leaves the pass nothing to do. It stands down after the wait,
    /// before it asks for a top page that would land on the matches and prune
    /// them.
    func testARefreshWaitingOnAPageWhenAPillLandsLandsNowhere() async throws {
        let (model, refresh) = try await world.refreshWaitingOnAPage()
        let before = await world.snapshotUIDs(model)
        let topsBefore = await world.imap.topEnvelopesCalls.count
        await scriptPill()

        await model.selectFilter(.unread)
        await world.imap.releaseHeld(.envelopes)
        await refresh.value
        await world.settle(model)

        let tops = await world.imap.topEnvelopesCalls.count
        XCTAssertEqual(tops, topsBefore, "no top page for the pass the pill overtook")
        await assertOnlyTheMatches(model, snapshotBefore: before)
    }

    // MARK: - The debounced snapshot write

    /// A page that landed just before the pill scheduled a snapshot write,
    /// which waits for scrolling to settle and so comes due under the
    /// matches. It writes nothing then: the matches are not the folder's rows.
    func testASnapshotWriteDueUnderThePillWritesNoMatches() async throws {
        let model = try await world.openedList()
        model.ensureLoaded(around: 0)
        await world.settle(model)
        let due = try XCTUnwrap(model.persistTask, "the page scheduled a write")
        await scriptPill()

        await model.selectFilter(.unread)
        XCTAssertTrue(model.isSearchActive)
        await due.value

        let after = await world.snapshotUIDs(model)
        XCTAssertTrue(after.isDisjoint(with: Self.matches), "no match was written as the folder's")
    }

    // MARK: - A search that fails

    /// A search that fails leaves the folder rows showing, but not the loads
    /// it stood down: here a sort's rebuild, whose top page then lands
    /// nowhere. What the viewport shows loads once the list is idle again.
    func testAPillWhoseSearchFailsLoadsTheRowsItStoodDown() async throws {
        let model = try await world.openedList()
        model.visibleRowIndices = [0: 1, 20: 1]
        await world.imap.holdNext(.topEnvelopes)
        let sort = Task { await model.setSort(SortCriterion(field: .subject, direction: .ascending)) }
        await world.imap.awaitHeld(.topEnvelopes)

        // Nothing is scripted for the search, so it fails.
        await model.selectFilter(.unread)
        XCTAssertFalse(model.isSearchActive)
        XCTAssertNotNil(model.errorMessage)
        await world.imap.releaseHeld(.topEnvelopes)
        await sort.value
        XCTAssertTrue(model.envelopes.isEmpty, "the rebuild's top page landed nowhere")

        try await waitUntilOnMainActor { model.envelope(at: 20) != nil }
        await world.settle(model)
    }
}
