import XCTest
@testable import Cabalmail

/// Issue #1027: with a term typed but not submitted, the results area went
/// blank — pixel-identical to a search that had run and matched nothing, on a
/// mailbox where the match existed the whole time. The two states are decided
/// here.
final class SearchResultsPlaceholderTests: XCTestCase {
    private func placeholder(
        isSearchScope: Bool = true,
        query: String,
        submittedQuery: String = "",
        isLoading: Bool = false,
        hasError: Bool = false,
        visibleRowCount: Int = 0
    ) -> SearchResultsPlaceholder {
        SearchResultsPlaceholder(
            isSearchScope: isSearchScope,
            query: query,
            submittedQuery: submittedQuery,
            isLoading: isLoading,
            hasError: hasError,
            visibleRowCount: visibleRowCount
        )
    }

    // MARK: - The reported state

    func testTypedButUnsubmittedSaysNothingHasBeenSearched() {
        XCTAssertEqual(placeholder(query: "delta"), .pressReturn)
    }

    func testAnExhaustedSearchAndAPendingOneAreDifferentStates() {
        // The whole defect: these two rendered identically.
        XCTAssertNotEqual(
            placeholder(query: "delta"),
            placeholder(query: "delta", submittedQuery: "delta")
        )
    }

    func testSubmittedTermWithNoRowsReportsNoMatches() {
        XCTAssertEqual(placeholder(query: "delta", submittedQuery: "delta"), .noMatches)
    }

    /// Editing a term after a search ran puts it back in the pending state —
    /// the rows on screen (or their absence) answer the *old* query.
    func testEditingASubmittedTermGoesBackToPending() {
        XCTAssertEqual(placeholder(query: "delt", submittedQuery: "delta"), .pressReturn)
        XCTAssertEqual(placeholder(query: "deltas", submittedQuery: "delta"), .pressReturn)
    }

    /// Whitespace is trimmed on submit, so a trailing space is not a new query.
    func testWhitespaceDoesNotCountAsAnEdit() {
        XCTAssertEqual(placeholder(query: "  delta ", submittedQuery: "delta"), .noMatches)
    }

    // MARK: - Where it must stay out of the way

    func testResultsOnScreenSuppressIt() {
        XCTAssertEqual(placeholder(query: "delta", submittedQuery: "delta", visibleRowCount: 3), .hidden)
        XCTAssertEqual(placeholder(query: "delta", visibleRowCount: 3), .hidden)
    }

    func testAPristineFieldIsLeftAlone() {
        XCTAssertEqual(placeholder(query: ""), .hidden)
        XCTAssertEqual(placeholder(query: "   "), .hidden)
    }

    func testTheFolderListNeverGetsASearchPlaceholder() {
        XCTAssertEqual(placeholder(isSearchScope: false, query: "delta"), .hidden)
        XCTAssertEqual(
            placeholder(isSearchScope: false, query: "delta", submittedQuery: "delta"),
            .hidden
        )
    }

    func testALoadInFlightOrAnErrorOnScreenSuppressesIt() {
        XCTAssertEqual(placeholder(query: "delta", submittedQuery: "delta", isLoading: true), .hidden)
        XCTAssertEqual(placeholder(query: "delta", submittedQuery: "delta", hasError: true), .hidden)
    }

    // MARK: - What it says

    func testEveryVisibleStateHasSomethingToSay() {
        for state in SearchResultsPlaceholder.allCases where state != .hidden {
            XCTAssertFalse(state.title.isEmpty, "\(state) has no title")
            XCTAssertFalse(state.message(for: "delta").isEmpty, "\(state) has no message")
        }
    }

    func testNoMatchesNamesTheTermSoTheEmptyListIsAttributable() {
        let message = SearchResultsPlaceholder.noMatches.message(for: " delta ")
        XCTAssertTrue(message.contains("delta"), message)
    }

    func testPendingDoesNotClaimAnythingWasSearched() {
        let message = SearchResultsPlaceholder.pressReturn.message(for: "delta")
        XCTAssertFalse(message.lowercased().contains("no messages"), message)
        XCTAssertTrue(SearchResultsPlaceholder.pressReturn.title.contains("Return"))
    }
}
