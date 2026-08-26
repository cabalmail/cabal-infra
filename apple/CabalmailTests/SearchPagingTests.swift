import XCTest
import CabalmailKit
@testable import Cabalmail

// Scroll-driven search pagination. A fresh search (pill or text) loads one
// page and pages in the rest as the list scrolls, replacing the old eager
// walk to a fixed 200-row cap; an in-place refresh re-walks to the depth
// the user has already paged to instead of truncating back to one page.
@MainActor
final class SearchPagingTests: XCTestCase {

    private func page(
        uids: Range<UInt32>,
        folder: String = "INBOX",
        total: Int = 120,
        cursor: String?
    ) -> SearchResult {
        SearchResult(
            envelopes: uids.map {
                SearchedEnvelope(envelope: TestFixtures.makeEnvelope(uid: $0), folder: folder)
            },
            totalEstimate: total,
            nextCursor: cursor,
            foldersSearched: [folder],
            truncated: false
        )
    }

    func testPillSearchLoadsOnePageAndScrollPagesInTheRest() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearchPages([
            page(uids: 1..<51, cursor: "c1"),
            // UID 50 duplicates the previous page's boundary row — the
            // date-based cursor re-delivers it after churn.
            page(uids: 50..<54, cursor: nil),
        ])
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])

        await model.selectFilter(.unread)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isSearchActive)
        XCTAssertEqual(model.envelopes.count, 50, "a fresh pill search fetches exactly one page")
        XCTAssertEqual(model.searchNextCursor, "c1")

        await model.loadMoreSearchResults()
        XCTAssertEqual(
            model.envelopes.count, 53,
            "the next page appends, minus the boundary row already loaded"
        )
        XCTAssertNil(model.searchNextCursor, "the match set is exhausted")
        let calls = await imap.searchCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].cursor, "c1", "load-more resumes from the stored cursor")
    }

    func testInPlaceRefreshRewalksToLoadedDepth() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearchPages([
            page(uids: 1..<51, cursor: "c1"),
            page(uids: 51..<101, cursor: "c2"),
            // The refresh's chunked re-walk, from the top.
            page(uids: 1..<51, cursor: "r1"),
            page(uids: 51..<101, cursor: "r2"),
        ])
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        await model.selectFilter(.unread)
        await model.loadMoreSearchResults()
        XCTAssertEqual(model.envelopes.count, 100)

        // Pull-to-refresh and the background pass route through `refresh()`,
        // which re-runs the search preserving depth — the user's scroll
        // position must not collapse back to one page.
        await model.refresh()
        XCTAssertEqual(model.envelopes.count, 100)
        XCTAssertEqual(model.searchNextCursor, "r2")
        let calls = await imap.searchCalls
        XCTAssertEqual(calls.count, 4)
        XCTAssertNil(calls[2].cursor, "the re-walk starts over from the first page")
    }

    func testAppendedCrossFolderRowRoutesToItsOwnFolder() async throws {
        let imap = FakeImapClient()
        let zeta = TestFixtures.makeEnvelope(uid: 1, messageId: "<zeta@example.com>")
        await imap.scriptSearchPages([
            page(uids: 1..<51, folder: "Archive", cursor: "c1"),
            SearchResult(
                envelopes: [SearchedEnvelope(envelope: zeta, folder: "zeta0802")],
                totalEstimate: 51,
                nextCursor: nil,
                foldersSearched: ["Archive", "zeta0802"],
                truncated: false
            ),
        ])
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "probe"
        await model.runSearch()
        await model.loadMoreSearchResults()

        XCTAssertEqual(
            model.envelopes.count, 51,
            "a colliding UID from another folder is a distinct row, not a duplicate"
        )
        XCTAssertEqual(
            model.sourceFolder(for: zeta), "zeta0802",
            "the source-folder index extends with appended pages"
        )
    }

    func testLoadMoreAfterClearIsANoOp() async throws {
        let imap = FakeImapClient()
        await imap.scriptSearchPages([page(uids: 1..<51, cursor: "c1")])
        let model = try TestFixtures.makeModel(imap: imap, envelopes: [])
        model.searchQuery = "probe"
        await model.runSearch()
        XCTAssertEqual(model.searchNextCursor, "c1")

        // `clearSearch` runs a folder refresh the fake traps on; the state
        // reset it does first is what this asserts.
        await model.clearSearch()
        XCTAssertNil(model.searchNextCursor)
        let before = await imap.searchCalls.count
        await model.loadMoreSearchResults()
        let after = await imap.searchCalls.count
        XCTAssertEqual(after, before, "no cursor after clearing — nothing is fetched")
    }
}
