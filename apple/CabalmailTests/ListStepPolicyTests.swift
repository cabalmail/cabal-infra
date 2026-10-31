import XCTest
@testable import CabalmailUI

/// Where Previous and Next land (`ListStepPolicy`): the nearest row above or
/// below the open one that the filter shows, among the loaded rows, with no
/// wrap and nothing at either end.
final class ListStepPolicyTests: XCTestCase {
    private let rows = ["a", "b", "c", "d", "e"]

    private func target(from index: Int?, _ step: ListStep, shown: Set<String>? = nil) -> Int? {
        ListStepPolicy.target(from: index, step, in: rows) { shown?.contains($0) ?? true }
    }

    func testAStepIsTheRowAboveOrBelow() {
        XCTAssertEqual(target(from: 2, .next), 3)
        XCTAssertEqual(target(from: 2, .previous), 1)
    }

    /// No wrap: the last row has no Next and the first no Previous.
    func testNothingPastEitherEnd() {
        XCTAssertNil(target(from: 4, .next))
        XCTAssertNil(target(from: 0, .previous))
    }

    /// The filter's hidden rows are skipped, as the list shows them.
    func testAStepSkipsTheRowsTheFilterHides() {
        let shown: Set<String> = ["a", "c", "e"]

        XCTAssertEqual(target(from: 2, .next, shown: shown), 4)
        XCTAssertEqual(target(from: 2, .previous, shown: shown), 0)
    }

    /// In the Unread pill the open message leaves the filtered rows once it
    /// is read; the walk starts from where it sits among the loaded rows.
    func testAStepStartsFromAnOpenRowTheFilterNoLongerShows() {
        let shown: Set<String> = ["a", "d"]

        XCTAssertEqual(target(from: 1, .next, shown: shown), 3)
        XCTAssertEqual(target(from: 1, .previous, shown: shown), 0)
    }

    /// An open message the list hasn't loaded (or none) gives no step.
    func testNoStepWithoutALoadedOpenRow() {
        XCTAssertNil(target(from: nil, .next))
        XCTAssertNil(target(from: 9, .previous))
    }

    func testAvailabilityDimsTheEnds() {
        let first = ListStepPolicy.availability(from: 0, in: rows) { _ in true }
        let middle = ListStepPolicy.availability(from: 2, in: rows) { _ in true }
        let only = ListStepPolicy.availability(from: 0, in: ["a"]) { _ in true }

        XCTAssertEqual(first, ListStepAvailability(canPrevious: false, canNext: true))
        XCTAssertEqual(middle, ListStepAvailability(canPrevious: true, canNext: true))
        XCTAssertEqual(only, .none)
        XCTAssertTrue(middle.allows(.next))
        XCTAssertFalse(first.allows(.previous))
    }
}
