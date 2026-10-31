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

/// A step once the open message has left the loaded rows
/// (`ListStepPolicy.Place`): a re-run of the Unread pill's search drops it
/// once it is read, while the reader still shows it.
final class ListStepPolicyLeftRowTests: XCTestCase {
    private func target(
        _ open: String?, last: ListStepPolicy.Place<String>?, _ step: ListStep, in rows: [String],
        shown: Set<String>? = nil
    ) -> String? {
        let loaded = ListStepPolicy.Rows(rows: rows, id: { $0 }, isShown: { shown?.contains($0) ?? true })
        return ListStepPolicy.target(from: open, last: last, step, in: loaded).map { rows[$0] }
    }

    func testTheOpenRowsPlaceRecordsItsShownNeighbours() {
        let rows = ListStepPolicy.Rows(rows: ["a", "b", "c", "d", "e"], id: { $0 }, isShown: { $0 != "b" })
        let other = ListStepPolicy.Rows(rows: ["a"], id: { $0 }, isShown: { _ in true })

        XCTAssertEqual(
            ListStepPolicy.place(of: "c", in: rows),
            ListStepPolicy.Place(open: "c", index: 2, previous: "a", next: "d")
        )
        XCTAssertNil(ListStepPolicy.place(of: "z", in: other))
    }

    /// The pill's search ran again without the message just read: a step
    /// goes to the neighbours it had.
    func testAStepFromADroppedRowGoesToItsNeighbours() {
        let last = ListStepPolicy.Place(open: "c", index: 2, previous: "b", next: "d")
        let rows = ["a", "b", "d", "e"]

        XCTAssertEqual(target("c", last: last, .next, in: rows), "d")
        XCTAssertEqual(target("c", last: last, .previous, in: rows), "b")
    }

    /// Neighbours gone too (read in another window): the nearest shown row
    /// on that side of where the open row sat.
    func testWithItsNeighboursGoneAStepGoesByPosition() {
        let last = ListStepPolicy.Place(open: "c", index: 2, previous: "b", next: "d")
        let rows = ["a", "x", "y", "z"]

        XCTAssertEqual(target("c", last: last, .next, in: rows), "y")
        XCTAssertEqual(target("c", last: last, .previous, in: rows), "x")
        XCTAssertEqual(target("c", last: last, .next, in: rows, shown: ["a", "z"]), "z")
    }

    /// A place belongs to the message it was taken for, and a row still
    /// loaded walks from where it is now.
    func testAPlaceServesOnlyItsOwnMessage() {
        let last = ListStepPolicy.Place(open: "c", index: 2, previous: "b", next: "d")

        XCTAssertNil(target("q", last: last, .next, in: ["a", "b", "d"]))
        XCTAssertNil(target(nil, last: last, .next, in: ["a", "b", "d"]))
        XCTAssertEqual(target("a", last: last, .next, in: ["a", "b", "d"]), "b")
    }

    func testAvailabilityFollowsTheDroppedRowsPlace() {
        let last = ListStepPolicy.Place(open: "a", index: 0, previous: nil, next: "b")

        let rows = ListStepPolicy.Rows(rows: ["b", "c"], id: { $0 }, isShown: { _ in true })

        XCTAssertEqual(
            ListStepPolicy.availability(from: "a", last: last, in: rows),
            ListStepAvailability(canPrevious: false, canNext: true)
        )
    }
}
