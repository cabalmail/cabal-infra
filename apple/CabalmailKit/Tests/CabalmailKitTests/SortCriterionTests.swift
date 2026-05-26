import XCTest
@testable import CabalmailKit

final class SortCriterionTests: XCTestCase {
    func testFieldWireValues() {
        XCTAssertEqual(SortCriterion.Field.dateReceived.wireField, "ARRIVAL")
        XCTAssertEqual(SortCriterion.Field.dateSent.wireField, "DATE")
        XCTAssertEqual(SortCriterion.Field.from.wireField, "FROM")
        XCTAssertEqual(SortCriterion.Field.subject.wireField, "SUBJECT")
    }

    func testDirectionWireValues() {
        // Descending must emit the trailing space — the Lambda concats
        // `sort_order + sort_field`, so "REVERSE" + "ARRIVAL" would
        // become "REVERSEARRIVAL" without it.
        XCTAssertEqual(SortCriterion.Direction.descending.wireOrder, "REVERSE ")
        XCTAssertEqual(SortCriterion.Direction.ascending.wireOrder, "")
    }

    func testDefaultIsReverseArrival() {
        XCTAssertEqual(SortCriterion.default.field, .dateReceived)
        XCTAssertEqual(SortCriterion.default.direction, .descending)
        let wire = SortCriterion.default.direction.wireOrder
            + SortCriterion.default.field.wireField
        XCTAssertEqual(wire, "REVERSE ARRIVAL")
    }
}
