import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Where a folder list's per-visit flag pick is kept (`FlagPickHold`). A
/// list's model does not outlive its view, and a folder's list is rebuilt
/// more often than the folder is left, so the window holds the pick: the
/// folder's next list opens on it, and a list for another folder ends the
/// visit. What a pick asks for and records is `MessageListFlagFilterTests`.
@MainActor
final class MessageListFlagPickHoldTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!
    private let later = "cabal-flag-03"

    override func setUp() async throws {
        executionTimeAllowance = 60
        fixture = RefreshCharacterizationFixture()
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
    }

    private var folderPath: String { fixture.folderPath }

    /// A folder's list with a flag of the user's own in Settings > Flags.
    /// It holds no rows yet, so its first load runs.
    private func makeModel() async throws -> MessageListViewModel {
        let model = try await fixture.makeModel()
        model.preferences.flagPalette = [FlagPaletteEntry(slot: later, label: "Later", color: "blue")]
        return model
    }

    private func answer(_ uids: [UInt32], carrying flags: Set<Flag>) -> SearchResult {
        fixture.searchResult(fixture.rows(uids, flags: flags))
    }

    private func sticky(_ model: MessageListViewModel) -> MessageFilter {
        model.preferences.mailFolderFilter(for: folderPath)
    }

    private func list(over model: MessageListViewModel, folder: String, picks: FlagPickHold<String>)
        -> MessageListViewModel {
        MessageListViewModel(
            scope: .folder(Folder(path: folder, attributes: [], isSubscribed: true)), client: model.client,
            preferences: model.preferences, mailStore: fixture.mailStore, flagPicks: picks
        )
    }

    /// A folder's list is rebuilt more often than the folder is left (a
    /// layout swap, a move below a fold, the search field taking the
    /// column). The window holds the pick, so the next list opens on it,
    /// from its first paint and ahead of the folder's own sticky pill.
    func testTheFoldersNextListOpensOnThePick() async throws {
        let seed = try await makeModel()
        seed.preferences.setMailFolderFilter(.unread, for: folderPath)
        let picks = FlagPickHold<String>()
        let first = list(over: seed, folder: folderPath, picks: picks)
        await fixture.imap.scriptSearch(answer([7, 5], carrying: [.keyword(later)]))
        await first.chooseFlagFilter(.flag(slot: later))

        let second = list(over: seed, folder: folderPath, picks: picks)

        XCTAssertEqual(second.flagPick, .slot(later), "from its first paint")
        XCTAssertEqual(second.filterTab, .flagged)
        await fixture.scriptRefresh(messages: 2, page: [9, 8])
        await fixture.imap.holdNext(.status)
        let load = Task { await second.loadInitial() }
        await fixture.imap.awaitHeld(.status)
        XCTAssertEqual(second.flagPick, .slot(later), "and through the first load, not the sticky Unread")
        XCTAssertEqual(second.filterTab, .flagged)
        XCTAssertEqual(second.envelopes.filter(second.narrowing.includes).map(\.uid), [])
        await fixture.imap.releaseHeld(.status)
        await load.value

        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(searches.last?.keyword, later, "the new list sent the pick's search, not a sticky pill's")
        XCTAssertEqual(searches.last?.unread, false)
        XCTAssertEqual(second.envelopes.map(\.uid), [7, 5])
        XCTAssertEqual(sticky(second), .unread, "the folder's own pill is as it was")
    }

    func testAListForAnotherFolderEndsTheVisit() async throws {
        let seed = try await makeModel()
        let picks = FlagPickHold<String>()
        let first = list(over: seed, folder: folderPath, picks: picks)
        await fixture.imap.scriptSearch(answer([7], carrying: [.keyword(later)]))
        await first.chooseFlagFilter(.flag(slot: later))

        let elsewhere = list(over: seed, folder: "Archive", picks: picks)
        let back = list(over: seed, folder: folderPath, picks: picks)

        XCTAssertNil(elsewhere.flagPick)
        XCTAssertNil(back.flagPick, "the window moved on; coming back finds no pick")
        XCTAssertEqual(back.filterTab, .all)
    }

    /// The hold follows the list: a pick that ended (Unread over it, Clear
    /// filter, the built-in row) is not what the next list opens on.
    func testAPickThatEndedIsNotHandedToTheNextList() async throws {
        let seed = try await makeModel()
        let picks = FlagPickHold<String>()
        let endings: [(String, @MainActor (MessageListViewModel) async -> Void)] = [
            ("Unread", { await $0.selectFilter(.unread) }),
            ("Clear filter", { await $0.chooseFlagFilter(.clear) }),
            ("the built-in row", { await $0.chooseFlagFilter(.flag(slot: FlagPalette.systemSlot)) }),
        ]
        for (name, end) in endings {
            let first = list(over: seed, folder: folderPath, picks: picks)
            await fixture.imap.scriptSearch(answer([7], carrying: [.keyword(later)]))
            await fixture.scriptRefresh(messages: 2, page: [9, 8])
            await first.chooseFlagFilter(.flag(slot: later))
            XCTAssertEqual(first.flagPick, .slot(later), name)

            await end(first)

            let next = list(over: seed, folder: folderPath, picks: picks)
            XCTAssertNil(next.flagPick, name)
        }
    }

    /// A list the window has replaced can still be finishing its first
    /// load, and that load ends by settling its own filter. Only the newest
    /// list writes the hold: the old one can neither put a pick back after
    /// the window moved on, nor clear the pick of the list that replaced it.
    func testAListTheWindowHasLeftCannotWriteTheHold() async throws {
        let seed = try await makeModel()
        let picks = FlagPickHold<String>()
        let first = list(over: seed, folder: folderPath, picks: picks)
        await fixture.imap.scriptSearch(answer([7], carrying: [.keyword(later)]))
        await first.chooseFlagFilter(.flag(slot: later))

        // The folder's next list opens on the pick and starts its first load.
        let departing = list(over: seed, folder: folderPath, picks: picks)
        await fixture.scriptRefresh(messages: 2, page: [9, 8])
        await fixture.imap.holdNext(.status)
        let load = Task { await departing.loadInitial() }
        await fixture.imap.awaitHeld(.status)
        // The window moves to another folder, which ends the visit, and the
        // list there takes a pick of its own.
        let elsewhere = list(over: seed, folder: "Archive", picks: picks)
        XCTAssertNil(elsewhere.flagPick)
        await elsewhere.chooseFlagFilter(.any)
        // Only now does the departed list's load answer and send its pick.
        await fixture.imap.releaseHeld(.status)
        await load.value
        XCTAssertEqual(departing.flagPick, .slot(later), "the departed list did settle on its pick")

        let archiveAgain = list(over: seed, folder: "Archive", picks: picks)
        XCTAssertEqual(archiveAgain.flagPick, .any, "the newer list's pick was not overwritten")
        let back = list(over: seed, folder: folderPath, picks: picks)
        XCTAssertNil(back.flagPick, "nor did the visit the window ended come back")
    }

    /// The pill is live from the first paint. A row chosen while the first
    /// load is out is the user's: the sticky pill is not replayed over it.
    func testARowChosenDuringTheFirstLoadIsNotReplayedOver() async throws {
        let model = try await makeModel()
        model.preferences.setMailFolderFilter(.unread, for: folderPath)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 2)
        await fixture.imap.scriptSearch(answer([2], carrying: [.keyword(later)]))
        await fixture.imap.holdNext(.status)

        let load = Task { await model.loadInitial() }
        await fixture.imap.awaitHeld(.status)
        XCTAssertEqual(model.filterTab, .unread, "the sticky pill shows from the first paint")
        await model.chooseFlagFilter(.flag(slot: later))
        await fixture.imap.releaseHeld(.status)
        await load.value

        XCTAssertEqual(model.flagPick, .slot(later))
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1, "the pick's search, and no Unread search after it")
        XCTAssertEqual(searches.first?.keyword, later)
        XCTAssertEqual(sticky(model), .unread, "the folder's own pill is untouched")
    }

    /// The same, where only the filters moved: the folder's sticky pill is
    /// Flagged, and a flag picked from its menu leaves that pill lit. The
    /// replay has to see the pick, not only the pill.
    func testAPickOverTheStickyFlaggedPillDuringTheFirstLoadIsKept() async throws {
        let model = try await makeModel()
        model.preferences.setMailFolderFilter(.flagged, for: folderPath)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], flagged: 1)
        await fixture.imap.scriptSearch(answer([2], carrying: [.keyword(later)]))
        await fixture.imap.holdNext(.status)

        let load = Task { await model.loadInitial() }
        await fixture.imap.awaitHeld(.status)
        XCTAssertEqual(model.filterTab, .flagged)
        await model.chooseFlagFilter(.flag(slot: later))
        await fixture.imap.releaseHeld(.status)
        await load.value

        XCTAssertEqual(model.flagPick, .slot(later), "the built-in Flagged filter was not replayed over the pick")
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(searches.first?.flagged, false)
    }

    /// And where only the pill moved: Unread turned off during the first
    /// load leaves the filters as they opened, empty, and the pill on All.
    func testAStickyPillTurnedOffDuringTheFirstLoadStaysOff() async throws {
        let model = try await makeModel()
        model.preferences.setMailFolderFilter(.unread, for: folderPath)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1], unseen: 2)
        await fixture.imap.holdNext(.status)

        let load = Task { await model.loadInitial() }
        await fixture.imap.awaitHeld(.status)
        // What the lit pill's tap does, short of the folder reload that
        // follows it, which would wait on the STATUS held here.
        model.filterTab = model.filterTab.toggling(.unread)
        await fixture.imap.releaseHeld(.status)
        await load.value

        XCTAssertEqual(model.filterTab, .all)
        let searches = await fixture.imap.searchCalls
        XCTAssertTrue(searches.isEmpty, "Unread was not replayed over the pill the user turned off")
        XCTAssertEqual(sticky(model), .all)
    }
}
