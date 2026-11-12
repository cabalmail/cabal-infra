import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The Flagged pill's menu on a folder list (cross-media plan, Phase 2):
/// what each row asks the server for, what is recorded for the folder and
/// what is not, and where a pick lives while the folder's list is rebuilt
/// under it. What the pill then shows is `MessageListFlagFilterPillTests`.
///
/// A flag of the user's own, and Any flag, are picks: they narrow the list
/// for the visit and record nothing. The built-in flag's row is the Flagged
/// filter the folder has always had, recorded as the plain pill's tap is.
@MainActor
final class MessageListFlagFilterTests: XCTestCase {
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

    private var folderPath: String { fixture.folderPath }

    /// A folder's list with two flags of the user's own in Settings > Flags.
    private func makeModel(loaded: [UInt32] = [9, 8]) async throws -> MessageListViewModel {
        let model = try await fixture.makeModel(loaded: loaded)
        model.preferences.flagPalette = [
            FlagPaletteEntry(slot: later, label: "Later", color: "blue"),
            FlagPaletteEntry(slot: work, label: "Work", color: "green"),
        ]
        return model
    }

    /// The server's answer to a search: these messages, carrying `flags`.
    private func answer(_ uids: [UInt32], carrying flags: Set<Flag>) -> SearchResult {
        fixture.searchResult(fixture.rows(uids, flags: flags))
    }

    private func sticky(_ model: MessageListViewModel) -> MessageFilter {
        model.preferences.mailFolderFilter(for: folderPath)
    }

    // MARK: - What a row asks for

    func testACustomFlagsRowSearchesTheFolderForThatFlagAlone() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], carrying: [.keyword(later)]))

        await model.chooseFlagFilter(.flag(slot: later))

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(searches.first?.keyword, later)
        XCTAssertEqual(searches.first?.folder, folderPath, "a pill narrows to its own folder")
        XCTAssertEqual(searches.first?.flagged, false, "a picked flag is the one criterion, not the built-in flag too")
        XCTAssertEqual(searches.first?.anyFlag, false)
        XCTAssertEqual(searches.first?.unread, false)
        XCTAssertEqual(model.filterTab, .flagged, "the Flagged pill is lit over the pick")
        XCTAssertEqual(model.flagPick, .slot(later))
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.envelopes.map(\.uid), [7, 5])
        XCTAssertNil(model.errorMessage)
    }

    func testAnyFlagAsksForTheServersAnyFlagSwitch() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], carrying: [.flagged]))

        await model.chooseFlagFilter(.any)

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(searches.first?.anyFlag, true)
        XCTAssertNil(searches.first?.keyword)
        XCTAssertEqual(searches.first?.flagged, false,
                       "flagged beside it would leave only the built-in flag's messages")
        XCTAssertEqual(searches.first?.folder, folderPath)
        XCTAssertEqual(model.flagPick, .any)
        XCTAssertEqual(model.filterTab, .flagged)
    }

    /// The row for the built-in flag is the Flagged filter itself. Chosen
    /// over a pick, the pill is already lit, and a route that only looked
    /// at the pill would do nothing.
    func testTheBuiltInFlagsRowOverAPickRunsAndRecordsTheFlaggedFilter() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], carrying: [.keyword(later)]))
        await model.chooseFlagFilter(.flag(slot: later))
        XCTAssertEqual(sticky(model), .all, "the pick recorded nothing")
        await fixture.imap.scriptSearch(answer([4], carrying: [.flagged]))

        await model.chooseFlagFilter(.flag(slot: FlagPalette.systemSlot))

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(searches.last?.flagged, true)
        XCTAssertNil(searches.last?.keyword)
        XCTAssertEqual(searches.last?.anyFlag, false)
        XCTAssertNil(model.flagPick)
        XCTAssertEqual(model.filterTab, .flagged)
        XCTAssertEqual(sticky(model), .flagged, "recorded for the folder, as a tap on the plain pill is")
        XCTAssertEqual(model.envelopes.map(\.uid), [4])
    }

    func testARowAlreadyShowingIsNotSentAgain() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7], carrying: [.keyword(later)]))
        await model.chooseFlagFilter(.flag(slot: later))

        await model.chooseFlagFilter(.flag(slot: later))

        var searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1)

        await model.chooseFlagFilter(.flag(slot: FlagPalette.systemSlot))
        await model.chooseFlagFilter(.flag(slot: FlagPalette.systemSlot))

        searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2, "the built-in row once, and not again while it shows")
    }

    /// A pick whose search failed is lit over a list no refresh will fix: a
    /// refresh re-runs only a search that answered. The same row is the
    /// retry.
    func testARowWhoseSearchFailedRunsAgainWhenChosenAgain() async throws {
        let model = try await makeModel()

        await model.chooseFlagFilter(.flag(slot: later))

        XCTAssertNotNil(model.errorMessage, "nothing is scripted, so the search failed")
        XCTAssertEqual(model.flagPick, .slot(later))
        XCTAssertFalse(model.isSearchActive)
        await fixture.imap.scriptSearch(answer([7], carrying: [.keyword(later)]))

        await model.chooseFlagFilter(.flag(slot: later))

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(searches.last?.keyword, later)
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.envelopes.map(\.uid), [7])
        XCTAssertNil(model.errorMessage)
    }

    /// A search that fails leaves the rows of the one before it on screen,
    /// so "a search is showing" does not mean this row's is. The retry must
    /// not be taken for the row already in force.
    func testAFailedRowOverAnAnsweredPillRunsAgainWhenChosenAgain() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearchPages([answer([7, 5], carrying: [])])
        await model.selectFilter(.unread)
        XCTAssertTrue(model.isSearchActive)

        await model.chooseFlagFilter(.flag(slot: later))

        XCTAssertNotNil(model.errorMessage, "no answer is scripted for the pick, so its search failed")
        XCTAssertEqual(model.flagPick, .slot(later))
        XCTAssertTrue(model.isSearchActive, "Unread's rows are still the list's")
        await fixture.imap.scriptSearchPages([answer([7], carrying: [.keyword(later)])])

        await model.chooseFlagFilter(.flag(slot: later))

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 3, "Unread, the pick that failed, and the pick again")
        XCTAssertEqual(searches.last?.keyword, later)
        XCTAssertEqual(model.envelopes.map(\.uid), [7])
        XCTAssertNil(model.errorMessage)
    }

    func testARowChosenAgainWhileItsSearchIsOutIsSentOnce() async throws {
        let model = try await makeModel()
        await fixture.imap.holdNextSearch()
        let first = Task { await model.chooseFlagFilter(.flag(slot: later)) }
        await fixture.imap.awaitHeldSearch()

        await model.chooseFlagFilter(.flag(slot: later))

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1)
        await fixture.imap.scriptSearch(answer([7], carrying: [.keyword(later)]))
        await fixture.imap.releaseHeldSearch()
        await first.value
        XCTAssertEqual(model.envelopes.map(\.uid), [7])
    }

    func testAStringThatIsNoFlagOfThePaletteChangesNothing() async throws {
        let model = try await makeModel()

        await model.chooseFlagFilter(.flag(slot: "$Forwarded"))

        let searches = await fixture.imap.searchCalls
        XCTAssertTrue(searches.isEmpty, "a search with no criterion would list the whole folder as matches")
        XCTAssertEqual(model.filterTab, .all)
        XCTAssertNil(model.flagPick)
    }

    // MARK: - What is recorded

    /// A pick is for the visit. The folder's own pill, Unread here, is what
    /// its next list opens on.
    func testAPickRecordsNothingAndTheFolderReopensOnItsOwnPill() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], carrying: []))
        await model.selectFilter(.unread)
        XCTAssertEqual(sticky(model), .unread)

        await model.chooseFlagFilter(.flag(slot: later))

        XCTAssertEqual(model.flagPick, .slot(later))
        XCTAssertEqual(sticky(model), .unread, "the pick lit Flagged without recording it")

        await fixture.scriptRefresh(messages: 2, page: [9, 8], unseen: 2)
        let reopened = fixture.reopen(model)
        await reopened.loadInitial()

        XCTAssertEqual(reopened.filterTab, .unread)
        XCTAssertNil(reopened.flagPick)
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 3, "Unread, the pick, and Unread again for the folder's next list")
        XCTAssertEqual(searches.last?.unread, true)
        XCTAssertNil(searches.last?.keyword)
    }

    func testClearFilterReturnsToAllAndRecordsIt() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], carrying: []))
        await model.selectFilter(.unread)
        await model.chooseFlagFilter(.flag(slot: later))
        await fixture.scriptRefresh(messages: 2, page: [9, 8])

        await model.chooseFlagFilter(.clear)

        XCTAssertEqual(model.filterTab, .all)
        XCTAssertNil(model.flagPick)
        XCTAssertFalse(model.isSearchActive)
        XCTAssertEqual(sticky(model), .all, "as every route to All is")
        XCTAssertEqual(model.envelopes.map(\.uid), [9, 8], "the folder's own rows are back")
    }

    func testUnreadOverAPickTakesItsPlace() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], carrying: [.keyword(later)]))
        await model.chooseFlagFilter(.flag(slot: later))

        // The Unread pill's tap, as the bar sends it.
        await model.selectFilter(model.filterTab.toggling(.unread))

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(searches.last?.unread, true)
        XCTAssertNil(searches.last?.keyword, "the pick did not ride along")
        XCTAssertEqual(model.filterTab, .unread)
        XCTAssertNil(model.flagPick)
        XCTAssertEqual(sticky(model), .unread)
    }

    // MARK: - While the pick stands

    func testARefreshRunsThePickAgain() async throws {
        let model = try await makeModel()
        await fixture.imap.scriptSearch(answer([7, 5], carrying: [.keyword(later)]))
        await model.chooseFlagFilter(.flag(slot: later))
        await fixture.scriptRefresh(messages: 2, page: [9, 8])

        await model.refresh()

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(searches.last?.keyword, later)
        XCTAssertEqual(searches.last?.folder, folderPath)
        XCTAssertEqual(model.flagPick, .slot(later))
        XCTAssertEqual(sticky(model), .all, "a refresh records nothing either")
    }

    /// Every reader of the rows goes by the picked flag, not by the pill:
    /// a message carrying only the picked flag is not flagged with the
    /// built-in one, and the Flagged pill's own rule would hide it.
    func testRowsCarryingOnlyThePickedFlagAreShownAndSelected() async throws {
        let model = try await makeModel()
        let picked = fixture.rows([7, 5], flags: [.keyword(later), .seen])
        let stale = fixture.rows([3], flags: [.flagged])
        await fixture.imap.scriptSearch(fixture.searchResult(picked + stale))

        await model.chooseFlagFilter(.flag(slot: later))

        XCTAssertEqual(model.narrowing.shown(model.envelopes).map(\.uid), [7, 5],
                       "and not a row the server sent that does not carry the flag")
        model.selectAllVisible()
        XCTAssertEqual(model.selectedRefs, [fixture.ref(7), fixture.ref(5)])

        await fixture.imap.scriptSearch(fixture.searchResult(picked + stale))
        await model.chooseFlagFilter(.flag(slot: FlagPalette.systemSlot))
        XCTAssertEqual(model.narrowing.shown(model.envelopes).map(\.uid), [3],
                       "under the built-in flag's row the rule is the built-in flag")
    }

    /// Until the pick's search answers, the rows are the folder's own,
    /// narrowed here by the same rule.
    func testTheFoldersOwnRowsAreNarrowedWhileThePicksSearchIsOut() async throws {
        let model = try await fixture.makeModel(loaded: [])
        model.envelopes = model.placedInFolder(
            fixture.rows([9], flags: [.keyword(later)]) + fixture.rows([8], flags: [.flagged]) + fixture.rows([7])
        )
        await fixture.imap.holdNextSearch()

        let pick = Task { await model.chooseFlagFilter(.any) }
        await fixture.imap.awaitHeldSearch()

        XCTAssertEqual(model.narrowing.shown(model.envelopes).map(\.uid), [9, 8])
        await fixture.imap.scriptSearch(answer([9, 8], carrying: [.flagged]))
        await fixture.imap.releaseHeldSearch()
        await pick.value
    }

    func testAnEarlierPicksLateAnswerDoesNotLandOverALaterPick() async throws {
        let model = try await makeModel()
        await fixture.imap.holdNextSearch()
        let first = Task { await model.chooseFlagFilter(.flag(slot: later)) }
        await fixture.imap.awaitHeldSearch()
        // Answers are taken in the order they are asked for once released:
        // the second pick's first, then the parked first pick's.
        await fixture.imap.scriptSearchPages([
            answer([6, 4], carrying: [.keyword(work)]), answer([7, 5, 3], carrying: [.keyword(later)]),
        ])

        await model.chooseFlagFilter(.flag(slot: work))
        await fixture.imap.releaseHeldSearch()
        await first.value

        XCTAssertEqual(model.flagPick, .slot(work))
        XCTAssertEqual(model.envelopes.map(\.uid), [6, 4])
        XCTAssertEqual(model.flagPickCount, 2, "the count is the later pick's too")
        XCTAssertNil(model.errorMessage)
    }
}

/// `MessageListNarrowing`: the one rule for which of a list's rows pass its
/// filter, which the list, Select All and Previous / Next all ask.
final class MessageListNarrowingTests: XCTestCase {
    private let later = "cabal-flag-03"

    private var rows: [Envelope] {
        [
            TestFixtures.makeEnvelope(uid: 5),
            TestFixtures.makeEnvelope(uid: 4, flags: [.seen]),
            TestFixtures.makeEnvelope(uid: 3, flags: [.seen, .flagged]),
            TestFixtures.makeEnvelope(uid: 2, flags: [.seen, .keyword(later)]),
            TestFixtures.makeEnvelope(uid: 1, flags: [.keyword("$Forwarded")]),
        ]
    }

    private func shown(_ narrowing: MessageListNarrowing) -> [UInt32] {
        narrowing.shown(rows).map(\.uid)
    }

    func testEachPillShowsItsOwnRows() {
        XCTAssertEqual(shown(MessageListNarrowing()), [5, 4, 3, 2, 1])
        XCTAssertFalse(MessageListNarrowing().narrows)
        XCTAssertEqual(shown(MessageListNarrowing(tab: .unread)), [5, 1])
        XCTAssertEqual(shown(MessageListNarrowing(tab: .flagged)), [3], "the built-in flag alone")
        XCTAssertTrue(MessageListNarrowing(tab: .unread).narrows)
    }

    /// Under a pick the rule is the picked flag, whatever the pill's own
    /// filter would say.
    func testAPickedFlagIsTheRule() {
        XCTAssertEqual(shown(MessageListNarrowing(tab: .flagged, flag: .slot(later))), [2])
        XCTAssertEqual(shown(MessageListNarrowing(tab: .flagged, flag: .any)), [3, 2],
                       "any flag: the built-in one or a palette slot, and no other keyword")
        XCTAssertTrue(MessageListNarrowing(flag: .any).narrows)
    }
}
