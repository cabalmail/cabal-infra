import XCTest
@testable import Cabalmail

/// Issue #1425: the Search tab opened with nothing focused, so typing a term
/// cost two taps. The second one carried no information — the tab has exactly
/// one field — but it is not unconditional: the same tab is where results are
/// read, and a keyboard raised over them would take something away.
final class SearchFieldFocusPolicyTests: XCTestCase {
    /// The reported flow: open the tab with no search running.
    func testAnEmptyFieldTakesFocusSoTheTabIsReadyToType() {
        XCTAssertTrue(SearchFieldFocusPolicy.focusesOnAppear(query: ""))
    }

    /// Whitespace is not a search anyone came back to read.
    func testAWhitespaceOnlyFieldCountsAsEmpty() {
        XCTAssertTrue(SearchFieldFocusPolicy.focusesOnAppear(query: "   "))
        XCTAssertTrue(SearchFieldFocusPolicy.focusesOnAppear(query: "\n \t"))
    }

    /// Re-entering the tab with a term still in the field is re-entering a
    /// result set; the keyboard would cover the rows it is there to show.
    func testATermInTheFieldLeavesTheResultsUncovered() {
        XCTAssertFalse(SearchFieldFocusPolicy.focusesOnAppear(query: "invoice"))
        XCTAssertFalse(SearchFieldFocusPolicy.focusesOnAppear(query: "  invoice  "))
    }
}
