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
    private func makeModel() async throws -> MessageListViewModel {
        let model = try await fixture.makeModel(loaded: [9, 8])
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
    /// column). The window holds the pick, so the next list opens on it.
    func testTheFoldersNextListOpensOnThePick() async throws {
        let seed = try await makeModel()
        let picks = FlagPickHold<String>()
        let first = list(over: seed, folder: folderPath, picks: picks)
        await fixture.imap.scriptSearch(answer([7, 5], carrying: [.keyword(later)]))
        await first.chooseFlagFilter(.flag(slot: later))

        let second = list(over: seed, folder: folderPath, picks: picks)

        XCTAssertEqual(second.flagPick, .slot(later), "from its first paint")
        XCTAssertEqual(second.filterTab, .flagged)
        await fixture.scriptRefresh(messages: 2, page: [9, 8])
        await second.loadInitial()
        let searches = await fixture.imap.searchCalls
        XCTAssertEqual(searches.count, 2)
        XCTAssertEqual(searches.last?.keyword, later, "the new list sent the pick's search, not a sticky pill's")
        XCTAssertEqual(second.envelopes.map(\.uid), [7, 5])
        XCTAssertEqual(sticky(second), .all)
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
            XCTAssertEqual(picks.take(for: folderPath), .slot(later), name)

            await end(first)

            let next = list(over: seed, folder: folderPath, picks: picks)
            XCTAssertNil(next.flagPick, name)
        }
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
}
