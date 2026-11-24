import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `SearchFlaggedMailSource`: what the Flagged view asks `/search_envelopes`
/// for, and what it makes of the answer.
final class FlaggedMailSourceTests: XCTestCase {
    func testEachCriterionAsksTheServerForItsOwnFlagAndNothingElse() {
        let later = FlagPalette.slots[2]

        XCTAssertEqual(SearchFlaggedMailSource.query(for: .any), SearchQuery(anyFlag: true))
        XCTAssertEqual(
            SearchFlaggedMailSource.query(for: .slot(FlagPalette.systemSlot)), SearchQuery(flagged: true)
        )
        XCTAssertEqual(SearchFlaggedMailSource.query(for: .slot(later)), SearchQuery(keyword: later))
        XCTAssertNil(
            SearchFlaggedMailSource.query(for: .slot("cabal-flag-99")),
            "a string that is no slot is a 400 from the server, and no message carries it"
        )
    }

    /// No folder, so every subscribed folder but Trash is searched.
    func testNoQueryNamesAFolder() {
        for criterion in [FlagCriterion.any, .slot(FlagPalette.systemSlot), .slot(FlagPalette.slots[0])] {
            XCTAssertNil(SearchFlaggedMailSource.query(for: criterion)?.folder)
        }
    }

    func testAPageAsksForTheServersMostFromTheCursorAndCarriesItsAnswer() async throws {
        let imap = FakeImapClient()
        let row = SearchedEnvelope(envelope: Envelope(uid: 7, from: [], flags: [.flagged]), folder: "Lists")
        await imap.scriptSearchPages([
            SearchResult(
                envelopes: [row], totalEstimate: 41, nextCursor: "next", foldersSearched: ["INBOX", "Lists"],
                truncated: true
            ),
        ])
        let source = SearchFlaggedMailSource(imap: imap)

        let page = try await source.page(matching: .any, after: "here")

        let calls = await imap.searchCalls
        XCTAssertEqual(calls, [SearchQuery(anyFlag: true, limit: 200, cursor: "here")])
        XCTAssertEqual(FlaggedList.mailPageSize, 200, "the server's most: each request searches every folder again")
        XCTAssertEqual(page, FlaggedMailPage(rows: [row], total: 41, nextCursor: "next", truncated: true))
    }

    func testACriterionTheServerWouldRefuseIsAnEmptyLastPageAndNoRequest() async throws {
        let imap = FakeImapClient()

        let page = try await SearchFlaggedMailSource(imap: imap).page(matching: .slot("bogus"), after: nil)

        XCTAssertEqual(page, .empty)
        let calls = await imap.searchCalls
        XCTAssertEqual(calls, [])
    }
}
