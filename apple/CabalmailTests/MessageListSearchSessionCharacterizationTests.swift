import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a folder list does around a search that no other suite pins, and that 2.2 C's split could change
/// without a test noticing: once a search's rows live in `MailSearchSession` beside the folder window's, a
/// reset that wipes "the rows on screen", a next page that waits on the list's loading, and a folder load
/// that lands after the results each reach a different store than they did when the two shared one array.
/// Committed before the split, so each test passes against the shared array first.
@MainActor
final class MessageListSearchSessionCharacterizationTests: XCTestCase {
    private var world: ListPagingWorld!

    override func setUp() async throws {
        // A hold that is never reached would otherwise hang until the CI job times out.
        executionTimeAllowance = 60
        world = ListPagingWorld()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
    }

    /// The Refresh command under a pill wipes the rows on screen -- the pill's matches -- with the folder's,
    /// and the pill's search then runs again from one page, as a fresh pill does, however deep the user had
    /// paged.
    func testAHardReloadUnderAPillReRunsItsSearchFromOnePage() async throws {
        let fixture = RefreshCharacterizationFixture()
        defer { fixture.removeScratch() }
        let pageSize = MailSearchSession.pageSize
        let first = fixture.searchResult(fixture.rows(fixture.newestFirst(100, through: 51)), cursor: "c1")
        let second = fixture.searchResult(fixture.rows(fixture.newestFirst(50, through: 41)))
        let model = try await fixture.makeModel()
        await fixture.imap.scriptSearchPages([first, second])
        await model.selectFilter(.unread)
        await model.search.loadMore()
        XCTAssertEqual(model.envelopes.count, 60, "precondition: two pages showing")
        await fixture.scriptRefresh(messages: 100, page: [100], unseen: 60)
        // The re-run's first page, and, should it walk deeper, what a second chunk would find.
        await fixture.imap.scriptSearchPages([first])
        await fixture.imap.scriptSearch(second)
        let asked = await fixture.imap.searchCalls.count

        await model.hardReload()

        let calls = await fixture.imap.searchCalls
        XCTAssertEqual(calls.dropFirst(asked).map(\.limit), [pageSize], "one page, not the 60 rows showing")
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.filterTab, .unread)
        XCTAssertEqual(model.envelopes.count, pageSize)
        XCTAssertFalse(model.isLoading)
    }

    /// A search's next page waits while a folder refresh still holds the list, as it did when the two held
    /// one loading flag: asked for under the refresh, it is not fetched.
    func testASearchPageWaitsWhileAFolderRefreshHoldsTheList() async throws {
        let model = try await world.openedList()
        await world.imap.scriptSearchPages([Self.matchesPage(cursor: "c1")])
        await world.imap.holdNext(.topEnvelopes)
        let refresh = Task { await model.refresh() }
        await world.imap.awaitHeld(.topEnvelopes)
        await model.selectFilter(.unread)
        XCTAssertTrue(model.isSearchActive, "precondition: the pill's first page is showing")
        XCTAssertEqual(model.search.nextCursor, "c1")
        XCTAssertTrue(model.isLoading, "the refresh still holds the list")
        let asked = await world.imap.searchCalls.count

        await model.search.loadMore()

        let after = await world.imap.searchCalls.count
        XCTAssertEqual(after, asked, "no next page while the refresh is out")
        XCTAssertEqual(model.envelopes.count, 50)
        await world.imap.releaseHeld(.topEnvelopes)
        await refresh.value
        XCTAssertFalse(model.isLoading)
    }

    /// A refresh that started while the pill's search was out, its top page carrying a new arrival, writes
    /// nothing once the results have landed: the landing stands it down (#1870), so neither the rows on
    /// screen nor the folder's snapshot take its page.
    func testARefreshThatStartedUnderAPillsSearchWritesNothingOnceTheResultsLand() async throws {
        let model = try await world.openedList()
        let before = await world.snapshotUIDs(model)
        await world.imap.scriptSearch(Self.matchesPage(cursor: nil))
        await world.imap.holdNextSearch()
        let pill = Task { await model.selectFilter(.unread) }
        await world.imap.awaitHeldSearch()
        await world.imap.holdNext(.topEnvelopes)
        let refresh = Task { await model.refresh() }
        await world.imap.awaitHeld(.topEnvelopes)
        // The held top page answers with what is scripted when it is released: a message that arrived.
        let arrived = [TestFixtures.makeEnvelope(uid: 1001)] + ListPagingWorld.serverFolder(size: 1000).prefix(49)
        await world.imap.scriptInitialLoad(status: ListPagingWorld.status(messages: 1001), topEnvelopes: arrived)

        await world.imap.releaseHeldSearch()
        await pill.value
        await world.imap.releaseHeld(.topEnvelopes)
        await refresh.value

        XCTAssertEqual(model.envelopes.map(\.uid), Self.matches.map(\.envelope.uid), "only the matches show")
        let after = await world.snapshotUIDs(model)
        XCTAssertEqual(after, before, "the folder's snapshot took nothing from the page the results overtook")
        XCTAssertFalse(after.contains(1001))
    }

    /// The Unread pill's first page: 50 rows no folder page holds.
    private static let matches: [SearchedEnvelope] = (5001...5050).reversed().map {
        SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: UInt32($0)), folder: ListPagingWorld.folderPath)
    }

    private static func matchesPage(cursor: String?) -> SearchResult {
        SearchResult(
            envelopes: matches, totalEstimate: 60, nextCursor: cursor,
            foldersSearched: [ListPagingWorld.folderPath], truncated: false
        )
    }
}
