import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a folder list's Flagged pill shows while it is a menu
/// (`MessageListViewModel.flagFilterPill`): its word, its rows, and the
/// picked flag's number, which is the server's count for the pick, kept in
/// step with the rows; and what the list says when a pick finds nothing.
/// What the rows do is `MessageListFlagFilterTests`.
@MainActor
final class MessageListFlagFilterPillTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!
    private let later = "cabal-flag-03"
    private let work = "cabal-flag-05"

    override func setUp() async throws {
        executionTimeAllowance = 60
        fixture = RefreshCharacterizationFixture()
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
    }

    /// A folder's list with two flags of the user's own, and three messages
    /// flagged with the built-in one as far as the folder's counts know.
    private func makeModel() async throws -> MessageListViewModel {
        let model = try await fixture.makeModel(loaded: [9, 8])
        model.preferences.flagPalette = [
            FlagPaletteEntry(slot: later, label: "Later", color: "blue"),
            FlagPaletteEntry(slot: work, label: "Work", color: "green"),
        ]
        model.flagged = 3
        return model
    }

    /// The server's answer: these messages carrying `slot`, of `total` that
    /// match in all, with `cursor` for the page after.
    private func answer(_ uids: [UInt32], slot: String, total: Int? = nil, cursor: String? = nil) -> SearchResult {
        SearchResult(
            envelopes: fixture.rows(uids, flags: [.keyword(slot)])
                .map { SearchedEnvelope(envelope: $0, folder: fixture.folderPath) },
            totalEstimate: total ?? uids.count, nextCursor: cursor, foldersSearched: [fixture.folderPath],
            truncated: false
        )
    }

    // MARK: - The pill

    func testThePillIsAPlainToggleUntilThereIsAFlagOfTheUsersOwn() async throws {
        let model = try await makeModel()
        model.preferences.flagPalette = []

        XCTAssertNil(model.flagFilterPill, "the bar draws the plain Flagged pill")

        model.preferences.flagPalette = [FlagPaletteEntry(slot: later, label: "Later", color: "blue")]
        let pill = try XCTUnwrap(model.flagFilterPill)
        XCTAssertEqual(pill.label, "Flagged", "unlit, it keeps the built-in flag's name")
        XCTAssertFalse(pill.isOn)
        XCTAssertEqual(pill.count, 3, "and the built-in flag's count")
        XCTAssertEqual(pill.rows.map(\.label), ["Flagged", "Later", "Any flag", "Clear filter"])
        XCTAssertEqual(pill.rows.map(\.isOn), [false, false, false, false])
        XCTAssertEqual(pill.rows.last?.isEnabled, false, "nothing to clear")
    }

    func testLitOnTheBuiltInFlagItChecksThatRowAndKeepsItsCount() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(fixture.searchResult(fixture.rows([7], flags: [.flagged])))

        await model.chooseFlagFilter(.flag(slot: FlagPalette.systemSlot))

        let pill = try XCTUnwrap(model.flagFilterPill)
        XCTAssertTrue(pill.isOn)
        XCTAssertEqual(pill.label, "Flagged")
        XCTAssertEqual(pill.count, 3, "the folder's own count, as the plain pill shows")
        XCTAssertEqual(pill.rows.map(\.isOn), [true, false, false, false, false])
        XCTAssertEqual(pill.rows.last?.isEnabled, true)
    }

    func testUnderAPickItCarriesThatFlagsNameAndCount() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], slot: later, total: 7))

        await model.chooseFlagFilter(.flag(slot: later))

        var pill = try XCTUnwrap(model.flagFilterPill)
        XCTAssertEqual(pill.label, "Later")
        XCTAssertTrue(pill.isOn)
        XCTAssertEqual(pill.count, 7, "what the server counted, not the two rows loaded nor the built-in flag's 3")
        XCTAssertEqual(pill.rows.map(\.isOn), [false, true, false, false, false])

        await fixture.imap.scriptSearch(answer([6], slot: work))
        await model.chooseFlagFilter(.any)

        pill = try XCTUnwrap(model.flagFilterPill)
        XCTAssertEqual(pill.label, "Any flag")
        XCTAssertEqual(pill.name, "Any flag")
        XCTAssertEqual(pill.rows.map(\.isOn), [false, false, false, true, false])
    }

    /// A number read for the flag picked before is not this flag's. Until
    /// the new pick's search answers the pill draws none, and keeps the
    /// room for one.
    func testANewPickShowsNoNumberUntilItsOwnAnswer() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], slot: later, total: 7))
        await model.chooseFlagFilter(.flag(slot: later))
        XCTAssertEqual(model.flagPickCount, 7)
        await fixture.imap.holdNextSearch()

        let pick = Task { await model.chooseFlagFilter(.flag(slot: work)) }
        await fixture.imap.awaitHeldSearch()

        let waiting = try XCTUnwrap(model.flagFilterPill)
        XCTAssertEqual(waiting.label, "Work")
        XCTAssertNil(waiting.count, "not Later's 7 under Work's name")
        XCTAssertEqual(waiting.reservedCount, 3, "the room a number will take, so the bar does not reflow twice")

        await fixture.imap.scriptSearch(answer([6, 4], slot: work, total: 4))
        await fixture.imap.releaseHeldSearch()
        await pick.value
        XCTAssertEqual(model.flagFilterPill?.count, 4)
        XCTAssertNil(model.flagFilterPill?.reservedCount)
    }

    /// A later page counts only from its cursor's day on, so the search's
    /// running total falls as the list pages in. The pill keeps the first
    /// page's, which is the query's.
    func testTheNumberIsTheFirstPagesHoweverManyPagesLoad() async throws {
        let model = try await makeModel()
        // A full first page, so the run stops there with the next page's
        // cursor in hand and the list pages the rest in.
        let firstPage = fixture.newestFirst(150, through: 101)
        // The second page brings one row of the first again, as a page
        // boundary that moved under mailbox churn does; it is one row.
        await fixture.imap.scriptSearchPages([
            answer(firstPage, slot: later, total: 120, cursor: "page-2"),
            answer([101, 4, 3], slot: later, total: 70),
        ])
        await model.chooseFlagFilter(.flag(slot: later))
        XCTAssertEqual(model.search.nextCursor, "page-2")

        await model.search.loadMore()

        XCTAssertEqual(model.envelopes.map(\.uid), firstPage + [4, 3])
        XCTAssertEqual(model.search.totalEstimate, 70, "the later page's count")
        XCTAssertEqual(model.flagPickCount, 120)
    }

    func testARefreshKeepsTheNumberWhileItsSearchIsOut() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], slot: later, total: 7))
        await model.chooseFlagFilter(.flag(slot: later))
        await fixture.scriptRefresh(messages: 2, page: [9, 8], flagged: 3)
        await fixture.imap.holdNextSearch()

        let refresh = Task { await model.refresh() }
        await fixture.imap.awaitHeldSearch()

        XCTAssertEqual(model.flagPickCount, 7, "a poll must not blank the number and bring it back")

        await fixture.imap.scriptSearch(answer([7, 5], slot: later, total: 8))
        await fixture.imap.releaseHeldSearch()
        await refresh.value
        XCTAssertEqual(model.flagPickCount, 8)
    }

    /// The server's count moves only when the search runs again. A row that
    /// leaves the pick here, its flag taken off or the message gone, takes
    /// one off the number at once, as the built-in flag's count does.
    func testTheNumberFollowsRowsThatLeaveTheList() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5, 3], slot: later, total: 9))
        await model.chooseFlagFilter(.flag(slot: later))
        XCTAssertEqual(model.flagPickCount, 9)

        await model.toggle(.keyword(later), on: model.envelopes[0])

        XCTAssertFalse(model.envelopes[0].flags.contains(.keyword(later)))
        XCTAssertEqual(model.flagPickCount, 8, "the flag came off one row")

        model.envelopes.removeAll { $0.uid == 5 }

        XCTAssertEqual(model.flagPickCount, 7, "and one message left the folder")
        XCTAssertEqual(model.flagged, 3, "the built-in flag's count is another number")
    }

    /// A count the server gave low (a total is a lower bound once a search
    /// is truncated) cannot take the number below nothing.
    func testTheNumberStopsAtZero() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], slot: later, total: 1))
        await model.chooseFlagFilter(.flag(slot: later))

        model.envelopes.removeAll()

        XCTAssertEqual(model.flagPickCount, 0)
    }

    /// A hard reload empties the rows before it fetches them again. The
    /// number on the pill stands until that answer: it does not go back to
    /// the first count, nor lose the rows that had left twice over.
    func testAHardReloadKeepsTheNumberUntilItsSearchAnswers() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5, 3], slot: later, total: 9))
        await model.chooseFlagFilter(.flag(slot: later))
        await model.toggle(.keyword(later), on: model.envelopes[0])
        XCTAssertEqual(model.flagPickCount, 8)
        await fixture.scriptRefresh(messages: 2, page: [9, 8], flagged: 3)
        await fixture.imap.holdNextSearch()

        let reload = Task { await model.hardReload() }
        await fixture.imap.awaitHeldSearch()

        XCTAssertTrue(model.envelopes.isEmpty, "the rows are gone until the search answers")
        XCTAssertEqual(model.flagPickCount, 8)
        XCTAssertNil(model.flagPickEmptyState(visibleRowCount: 0), "and an emptied list is not an empty answer")

        await fixture.imap.scriptSearch(answer([5, 3], slot: later, total: 8))
        await fixture.imap.releaseHeldSearch()
        await reload.value
        XCTAssertEqual(model.flagPickCount, 8)
        XCTAssertEqual(model.envelopes.map(\.uid), [5, 3])
    }

    /// Deleting the picked flag in Settings, the palette's last custom one
    /// included, leaves the list narrowed to its slot. The pill stays a
    /// menu, named for what is in force, with the way out under it.
    func testAPickWhoseFlagWasDeletedKeepsItsMenu() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7], slot: later))
        await model.chooseFlagFilter(.flag(slot: later))

        model.preferences.flagPalette = []

        let pill = try XCTUnwrap(model.flagFilterPill, "not the plain pill, lit and named for the built-in flag")
        XCTAssertEqual(pill.label, later, "the slot's id, as a row's dot is named once its flag is gone")
        XCTAssertEqual(pill.count, 1)
        XCTAssertEqual(pill.rows.map(\.label), ["Flagged", "Any flag", "Clear filter"])
        XCTAssertEqual(pill.rows.last?.isEnabled, true)
    }

    // MARK: - A pick that finds nothing

    func testAPickThatFindsNothingSaysSoOnceItHasAnswered() async throws {
        let model = try await makeModel()
        await fixture.imap.holdNextSearch()
        let pick = Task { await model.chooseFlagFilter(.flag(slot: later)) }
        await fixture.imap.awaitHeldSearch()

        XCTAssertNil(model.flagPickEmptyState(visibleRowCount: 0), "an empty list is not an answer yet")

        await fixture.imap.scriptSearch(answer([], slot: later))
        await fixture.imap.releaseHeldSearch()
        await pick.value

        let empty = try XCTUnwrap(model.flagPickEmptyState(visibleRowCount: 0))
        XCTAssertEqual(empty.title, "No messages marked Later")
        XCTAssertEqual(empty.message, "Nothing in Work carries this flag.")
        XCTAssertNil(model.flagPickEmptyState(visibleRowCount: 2))
    }

    /// The answer stands while a refresh asks again (a poll comes every
    /// minute, and words that blinked out each time would read as a fault),
    /// and gives way to an error.
    func testTheEmptyAnswerStandsThroughARefreshAndGivesWayToAnError() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearchPages([answer([], slot: later), answer([], slot: later)])
        await model.chooseFlagFilter(.flag(slot: later))
        XCTAssertNotNil(model.flagPickEmptyState(visibleRowCount: 0))
        await fixture.scriptRefresh(messages: 2, page: [9, 8], flagged: 3)
        await fixture.imap.holdNextSearch()

        let refresh = Task { await model.refresh() }
        await fixture.imap.awaitHeldSearch()
        XCTAssertNotNil(model.flagPickEmptyState(visibleRowCount: 0), "while the refresh's search is out")
        await fixture.imap.releaseHeldSearch()
        await refresh.value
        XCTAssertNotNil(model.flagPickEmptyState(visibleRowCount: 0))

        // Nothing more is scripted, so the next refresh's search fails.
        await model.refresh()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.flagPickEmptyState(visibleRowCount: 0), "the error line is what the list says now")
    }

    func testTheEmptyStateIsForAPickWithEveryMatchInHand() {
        func state(_ pick: FlagCriterion?, settled: Bool = true, rows: Int = 0) -> FlagPickEmptyState? {
            FlagPickEmptyState(pick: pick, name: "Later", folderName: "INBOX", isSettled: settled,
                               visibleRowCount: rows)
        }

        XCTAssertEqual(state(.any)?.title, "No flagged messages")
        XCTAssertEqual(state(.any)?.message, "Nothing in INBOX carries a flag.")
        XCTAssertEqual(state(.slot(later))?.title, "No messages marked Later")
        XCTAssertNil(state(nil), "the pills' own filters are as they were")
        XCTAssertNil(state(.slot(later), settled: false), "a page still to come may hold a match")
        XCTAssertNil(state(.slot(later), rows: 1))
    }

    func testAPageStillToComeIsNotAnEmptyAnswer() async throws {
        let model = try await makeModel()
        // The total is the page's own size, as a truncated search's can be:
        // by the count alone nothing would be left once these rows are gone.
        await fixture.imap.scriptSearch(
            answer(fixture.newestFirst(150, through: 101), slot: later, total: 50, cursor: "next")
        )
        await model.chooseFlagFilter(.flag(slot: later))
        XCTAssertNotNil(model.search.nextCursor)

        model.envelopes.removeAll()

        XCTAssertEqual(model.flagPickCount, 0)
        XCTAssertNil(model.flagPickEmptyState(visibleRowCount: 0), "the rest are a page away")
    }
}
