import XCTest
import CabalmailKit
@testable import Cabalmail

// "This folder only" on the global search surface (#1510). The surface's own
// folder is a sentinel, so the toggle was hidden there — the only place the
// Filters sheet is presented — and single-folder search was unreachable. It
// now narrows to the anchor the wide layout feeds in from the sidebar.
@MainActor
final class SearchFolderScopeTests: XCTestCase {

    private func makeSearchModel(imap: FakeImapClient) throws -> MessageListViewModel {
        MessageListViewModel(
            scope: .search,
            client: try TestFixtures.makeClient(imap: imap),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            appState: AppState()
        )
    }

    private func result(folder: String) -> SearchResult {
        SearchResult(
            envelopes: [SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: 1), folder: folder)],
            totalEstimate: 1,
            nextCursor: nil,
            foldersSearched: [folder],
            truncated: false
        )
    }

    /// A search-scope model with an Archive anchor and a completed
    /// single-folder search for "invoice".
    private func makeScopedSearch(imap: FakeImapClient) async throws -> MessageListViewModel {
        await imap.scriptSearch(result(folder: "Archive"))
        let model = try makeSearchModel(imap: imap)
        await model.setSearchAnchor(Folder(path: "Archive"))
        model.searchQuery = "invoice"
        model.searchFilters.thisFolderOnly = true
        await model.runSearch()
        return model
    }

    func testThisFolderOnlySendsTheAnchorPath() async throws {
        let imap = FakeImapClient()
        let model = try await makeScopedSearch(imap: imap)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.searchFolder?.path, "Archive", "the toggle is offered with the anchor's name")
        let calls = await imap.searchCalls
        XCTAssertEqual(calls.map(\.folder), ["Archive"], "the wire query narrows to the anchor, not the sentinel")
    }

    func testCrossFolderSearchSendsNoFolder() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearch(result(folder: "INBOX"))
        let model = try makeSearchModel(imap: imap)
        await model.setSearchAnchor(Folder(path: "Archive"))
        model.searchQuery = "invoice"
        await model.runSearch()

        let calls = await imap.searchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].folder, "an anchor alone does not narrow; only the toggle does")
    }

    func testNoAnchorOffersNoFolderScope() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearch(result(folder: "INBOX"))
        let model = try makeSearchModel(imap: imap)
        XCTAssertNil(model.searchFolder, "the iPhone / visionOS search tab has nothing to narrow to")

        // Even a stray flag can't send the sentinel's empty path.
        model.searchQuery = "invoice"
        model.searchFilters.thisFolderOnly = true
        await model.runSearch()
        let calls = await imap.searchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertNil(calls[0].folder)
    }

    func testAnchorMoveRerunsAnActiveSingleFolderSearch() async throws {
        let imap = FakeImapClient()
        let model = try await makeScopedSearch(imap: imap)

        await model.setSearchAnchor(Folder(path: "Sent"))
        let calls = await imap.searchCalls
        XCTAssertEqual(
            calls.map(\.folder), ["Archive", "Sent"],
            "the banner must not keep naming a folder the rows no longer came from"
        )
        XCTAssertTrue(model.searchFilters.thisFolderOnly)
    }

    func testAnchorMoveLeavesACrossFolderSearchAlone() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearch(result(folder: "INBOX"))
        let model = try makeSearchModel(imap: imap)
        await model.setSearchAnchor(Folder(path: "Archive"))
        model.searchQuery = "invoice"
        await model.runSearch()

        await model.setSearchAnchor(Folder(path: "Sent"))
        let count = await imap.searchCalls.count
        XCTAssertEqual(count, 1, "a cross-folder search does not depend on the anchor")
    }

    // A sidebar pick empties the query (`endGlobalSearch`) and then writes
    // the new folder, which moves the anchor. Re-running there drew the whole
    // folder as a query-less search and left the surface stuck over it
    // (#1536).
    func testAnchorMoveEndsASearchWithNothingLeftToMatchOn() async throws {
        let imap = FakeImapClient()
        let model = try await makeScopedSearch(imap: imap)

        model.searchQuery = ""
        await model.setSearchAnchor(Folder(path: "INBOX"))

        let calls = await imap.searchCalls
        XCTAssertEqual(
            calls.map(\.folder), ["Archive"],
            "the scope alone is not a search; no request goes out for the folder just picked"
        )
        XCTAssertFalse(model.isSearchActive, "the pick ends the search rather than re-scoping it")
        XCTAssertFalse(model.searchFilters.thisFolderOnly)
        XCTAssertTrue(model.envelopes.isEmpty, "the folder view owns the column again")
    }

    // The same stuck surface, reached with a request in flight rather than a
    // completed one: the pick's teardown lands while the search is still out,
    // and its answer must not raise the banner back over the folder (#1536).
    func testAResultLandingAfterTheSearchEndsIsDropped() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearch(result(folder: "Archive"))
        let model = try makeSearchModel(imap: imap)
        await model.setSearchAnchor(Folder(path: "Archive"))
        model.searchQuery = "invoice"
        model.searchFilters.thisFolderOnly = true

        await imap.holdNextSearch()
        let search = Task { await model.runSearch() }
        await imap.awaitHeldSearch()
        await model.clearSearch()
        await imap.releaseHeldSearch()
        await search.value

        XCTAssertFalse(model.isSearchActive, "the search the answer belongs to is over")
        XCTAssertTrue(model.envelopes.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testLosingTheAnchorDropsTheScopeAndRerunsCrossFolder() async throws {
        let imap = FakeImapClient()
        let model = try await makeScopedSearch(imap: imap)

        await model.setSearchAnchor(nil)
        XCTAssertFalse(model.searchFilters.thisFolderOnly)
        let calls = await imap.searchCalls
        XCTAssertEqual(calls.map(\.folder), ["Archive", nil])
    }
}
