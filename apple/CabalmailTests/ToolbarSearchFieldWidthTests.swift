import XCTest
import CoreGraphics
@testable import Cabalmail

/// The toolbar search field used a hard-coded 260pt width. A toolbar item is
/// not clipped to its own column, so once the column was narrower than that,
/// the field overhung into the neighbouring one: magnifier laid out at
/// x=270.5 against a pane starting at x=300, placeholder reading "earch all
/// mail". Since the #1047 toolbar rework the field rides the message-list
/// column and shares its toolbar area with fixed sibling buttons, whose
/// footprint (`siblingReserve`) comes off the column before the field takes
/// its share.
final class ToolbarSearchFieldWidthTests: XCTestCase {
    /// The invariant, swept across the whole range of pane widths rather than
    /// spot-checked: the field never claims more than the area it sits over.
    func testTheFieldNeverOverhangsItsColumn() {
        for available in stride(from: 60.0, through: 1_400.0, by: 5.0) {
            let width = ToolbarSearchFieldWidth.width(availableWidth: CGFloat(available))
            XCTAssertLessThanOrEqual(
                width, CGFloat(available),
                "a \(available)pt area got a \(width)pt field"
            )
        }
    }

    /// The end-to-end invariant on the public entry point: over any measured
    /// list column, field + reserved siblings stay inside the column.
    func testTheFieldLeavesRoomForTheSiblingButtons() {
        for column in stride(from: 100.0, through: 1_000.0, by: 5.0) {
            let width = ToolbarSearchFieldWidth.width(
                columnWidth: CGFloat(column),
                inspectorPresented: false
            )
            XCTAssertLessThanOrEqual(
                width,
                max(0, CGFloat(column) - ToolbarSearchFieldWidth.siblingReserve),
                "a \(column)pt column got a \(width)pt field beside "
                + "\(ToolbarSearchFieldWidth.siblingReserve)pt of buttons"
            )
        }
    }

    /// The macOS launch layout: a list column at its 420pt ideal
    /// (`ListColumnWidth.ideal`) leaves the field short of `preferred` but
    /// comfortably usable once the siblings take theirs.
    func testTheDefaultListColumnGetsAUsableField() {
        let available = ToolbarSearchFieldWidth.availableWidth(
            columnWidth: ListColumnWidth.ideal,
            reserved: ToolbarSearchFieldWidth.siblingReserve
        )
        let width = ToolbarSearchFieldWidth.width(availableWidth: available)

        XCTAssertGreaterThanOrEqual(width, ToolbarSearchFieldWidth.minimum)
        XCTAssertLessThanOrEqual(width, available)
    }

    func testAWideColumnStillCapsAtThePreferredWidth() {
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: 474), 260)
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: 1_200), 260)
    }

    func testAnUnmeasuredColumnStaysUnmeasuredRatherThanGoingNegative() {
        // Subtracting the reserve from a pre-layout zero would read as a
        // negative pane and pin the field to its floor.
        XCTAssertEqual(
            ToolbarSearchFieldWidth.availableWidth(
                columnWidth: 0,
                reserved: ToolbarSearchFieldWidth.siblingReserve
            ),
            0
        )
    }

    func testTheFieldStopsShortOfTheColumnEdgeRatherThanSittingFlush() {
        XCTAssertEqual(
            ToolbarSearchFieldWidth.width(availableWidth: 200),
            200 - ToolbarSearchFieldWidth.margin
        )
    }

    func testAPaneTooNarrowForAUsableFieldKeepsAFloorRatherThanVanishing() {
        // Below the floor the field is a magnifier and a glyph or two, which
        // still accepts typing — the point is that it is on screen.
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: 90), ToolbarSearchFieldWidth.minimum)
    }

    func testAPaneNarrowerThanTheFloorGetsAFlushFieldRatherThanAnOverhang() {
        // The floor is not allowed to recreate the bug it exists inside of.
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: 60), 60)
    }

    func testThePreLayoutMeasurementResolvesToThePreferredWidth() {
        // A zero column is "not measured yet", not a zero-width pane:
        // launching at the floor and snapping wider a frame later is its own
        // defect.
        XCTAssertEqual(
            ToolbarSearchFieldWidth.width(columnWidth: 0, inspectorPresented: false),
            ToolbarSearchFieldWidth.preferred
        )
        XCTAssertEqual(
            ToolbarSearchFieldWidth.width(columnWidth: -1, inspectorPresented: true),
            ToolbarSearchFieldWidth.preferred
        )
    }

    func testAMeasuredAreaSmallerThanTheSiblingsYieldsNoFieldRatherThanAnOverhang() {
        // Distinct from pre-layout: a MEASURED column the fixed buttons
        // already exceed has no room to give, and any nonzero width would
        // hang under the neighbouring column.
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: 0), 0)
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: -40), 0)
    }

    /// The iPad inspector can reach `AddressInspectorWidth.maximum` over a
    /// reading pane at its `readerFloor`; only that overhang is charged to
    /// the list column's toolbar area (and only on iOS — macOS tiles).
    func testTheInspectorOverlapIsTheReachBeyondTheReaderFloor() {
        XCTAssertEqual(
            ToolbarSearchFieldWidth.inspectorOverlap,
            AddressInspectorWidth.maximum - ListColumnWidth.readerFloor
        )
        XCTAssertGreaterThanOrEqual(ToolbarSearchFieldWidth.inspectorOverlap, 0)
    }
}
