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
                inspectorPresented: false,
                leadingWidth: 0
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
            ToolbarSearchFieldWidth.width(columnWidth: 0, inspectorPresented: false, leadingWidth: 0),
            ToolbarSearchFieldWidth.preferred
        )
        XCTAssertEqual(
            ToolbarSearchFieldWidth.width(columnWidth: -1, inspectorPresented: true, leadingWidth: 90),
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

    // MARK: - The folder-switch menu at the section's leading edge

    /// The macOS section's leading edge carries the folder-switch menu, whose
    /// width is the folder name's. Sized without it, the field claimed the
    /// menu's share too and was drawn over it — and widening the column
    /// didn't help, because the field grew point-for-point with the column.
    /// Charged, field + siblings + menu stay inside the column wherever the
    /// column can seat all three beside a usable field.
    func testTheFieldLeavesRoomForTheFolderMenu() {
        for column in stride(from: 200.0, through: 1_000.0, by: 5.0) {
            for menu in stride(from: 36.0, through: 160.0, by: 4.0) {
                let width = ToolbarSearchFieldWidth.width(
                    columnWidth: CGFloat(column),
                    inspectorPresented: false,
                    leadingWidth: CGFloat(menu)
                )
                let seatsAll = CGFloat(column) - ToolbarSearchFieldWidth.siblingReserve - CGFloat(menu)
                    >= ToolbarSearchFieldWidth.minimum + ToolbarSearchFieldWidth.margin
                guard seatsAll else { continue }
                XCTAssertLessThanOrEqual(
                    width,
                    CGFloat(column) - ToolbarSearchFieldWidth.siblingReserve - CGFloat(menu),
                    "a \(column)pt column with a \(menu)pt menu got a \(width)pt field"
                )
            }
        }
    }

    /// Widening the column now widens the gap between the menu and the
    /// field, not just the field: with the menu charged, the field's share
    /// grows with the column and stops at `preferred`, exactly as it does
    /// with no menu at all.
    func testTheMenuIsChargedOffTheFieldsShare() {
        let bare = ToolbarSearchFieldWidth.width(columnWidth: 420, inspectorPresented: false, leadingWidth: 0)
        let charged = ToolbarSearchFieldWidth.width(columnWidth: 420, inspectorPresented: false, leadingWidth: 36)
        XCTAssertEqual(bare - charged, 36)
        XCTAssertEqual(
            ToolbarSearchFieldWidth.width(columnWidth: 1_000, inspectorPresented: false, leadingWidth: 120),
            ToolbarSearchFieldWidth.preferred
        )
    }

    /// The field yields to the menu only down to its own floor. A folder
    /// name wider than the section can seat beside a usable field leaves the
    /// field at `minimum` over the menu's tail — cramped, but present: this
    /// field is the only way into search on the layout, so "no field" is
    /// never the answer to a long folder name.
    func testAWideFolderMenuCannotPushTheFieldUnderItsFloor() {
        let reserved = ToolbarSearchFieldWidth.siblingReserve
        // 300 - 140 - 88 - 24 = 48pt beside the floor: a 36pt menu is charged
        // whole, a 95pt one only as far as the floor allows.
        XCTAssertEqual(
            ToolbarSearchFieldWidth.leadingCharge(columnWidth: 300, reserved: reserved, leadingWidth: 36), 36
        )
        XCTAssertEqual(
            ToolbarSearchFieldWidth.leadingCharge(columnWidth: 300, reserved: reserved, leadingWidth: 95), 48
        )
        XCTAssertEqual(
            ToolbarSearchFieldWidth.width(columnWidth: 300, inspectorPresented: false, leadingWidth: 95),
            ToolbarSearchFieldWidth.minimum
        )
        XCTAssertEqual(
            ToolbarSearchFieldWidth.width(columnWidth: 300, inspectorPresented: false, leadingWidth: 400),
            ToolbarSearchFieldWidth.minimum
        )
        // A column too narrow to seat even the floor beside the siblings
        // charges nothing for the menu; the field is whatever it was before
        // the menu existed rather than less.
        XCTAssertEqual(
            ToolbarSearchFieldWidth.leadingCharge(columnWidth: 220, reserved: reserved, leadingWidth: 36), 0
        )
        XCTAssertEqual(
            ToolbarSearchFieldWidth.width(columnWidth: 220, inspectorPresented: false, leadingWidth: 36),
            ToolbarSearchFieldWidth.width(columnWidth: 220, inspectorPresented: false, leadingWidth: 0)
        )
    }

    /// An unmeasured menu — the pre-layout zero, or the search surface that
    /// has none — charges nothing rather than reading as a negative item.
    func testAnUnmeasuredMenuChargesNothing() {
        XCTAssertEqual(ToolbarSearchFieldWidth.leadingCharge(columnWidth: 420, reserved: 140, leadingWidth: 0), 0)
        XCTAssertEqual(ToolbarSearchFieldWidth.leadingCharge(columnWidth: 420, reserved: 140, leadingWidth: -5), 0)
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
