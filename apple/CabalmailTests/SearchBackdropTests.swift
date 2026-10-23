import SwiftUI
import XCTest
@testable import CabalmailUI

/// The phone's Search tab opens over the tab in front and shows that tab,
/// dimmed, until a search runs (`SearchBackdrop`). These pin when the
/// captured frame stands in for the results, and when it still fits the
/// window it was captured in.
final class SearchBackdropTests: XCTestCase {

    private let portrait = CGSize(width: 402, height: 874)

    private func backdrop(size: CGSize) -> SearchBackdrop {
        SearchBackdrop(image: Image(systemName: "tray"), size: size, tabTitle: "Mail", returnToTab: {})
    }

    /// Search just opened: nothing has been sent, so the tab it opened over
    /// is still what the screen shows. A term typed but not submitted leaves
    /// `submittedQuery` empty, so it lands here too.
    func testStandsInBeforeASearchRuns() {
        XCTAssertTrue(SearchBackdrop.standsIn(submittedQuery: "", isSearchActive: false))
    }

    /// A submitted term is a search: the results take over at once, while it
    /// is still loading.
    func testASubmittedTermShowsTheResults() {
        XCTAssertFalse(SearchBackdrop.standsIn(submittedQuery: "invoice", isSearchActive: false))
        XCTAssertFalse(SearchBackdrop.standsIn(submittedQuery: "invoice", isSearchActive: true))
    }

    /// The filter sheet can run a search with no term at all.
    func testAFiltersOnlySearchShowsTheResults() {
        XCTAssertFalse(SearchBackdrop.standsIn(submittedQuery: "", isSearchActive: true))
    }

    func testFitsTheWindowItWasCapturedIn() {
        XCTAssertTrue(backdrop(size: portrait).fits(portrait))
        // A fraction of a point is layout rounding, not a different window.
        XCTAssertTrue(backdrop(size: portrait).fits(CGSize(width: 402.4, height: 873.7)))
    }

    /// A rotation while Search is open: the portrait frame would be stretched
    /// over a landscape screen.
    func testARotatedWindowNoLongerFits() {
        XCTAssertFalse(backdrop(size: portrait).fits(CGSize(width: 874, height: 402)))
    }

    /// A narrowed or widened iPad window keeps its height and changes width.
    func testAResizedWindowNoLongerFits() {
        XCTAssertFalse(backdrop(size: portrait).fits(CGSize(width: 390, height: 874)))
    }
}
