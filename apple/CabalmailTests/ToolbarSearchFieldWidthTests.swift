import XCTest
import CoreGraphics
@testable import Cabalmail

/// The toolbar search field used a hard-coded 260pt width. A toolbar item is
/// not clipped to its own column, so once the detail column was narrower than
/// that — iPad portrait with the Addresses inspector open, measured at ~235pt
/// — the field overhung into the message list: magnifier laid out at x=270.5
/// against a pane starting at x=300, placeholder reading "earch all mail".
final class ToolbarSearchFieldWidthTests: XCTestCase {
    /// The invariant, swept across the whole range of pane widths rather than
    /// spot-checked: the field never claims more than the column it sits over.
    func testTheFieldNeverOverhangsItsColumn() {
        for available in stride(from: 60.0, through: 1_400.0, by: 5.0) {
            let width = ToolbarSearchFieldWidth.width(availableWidth: CGFloat(available))
            XCTAssertLessThanOrEqual(
                width, CGFloat(available),
                "a \(available)pt column got a \(width)pt field"
            )
        }
    }

    /// The measured case, end to end: 834pt portrait iPad, message list at
    /// 300pt, so the detail column measures 534 — and with the inspector open
    /// the toolbar area it offers ends at x=520, i.e. 220pt of usable width.
    func testTheReportedThreeColumnLayoutGetsAFieldThatFitsTheToolbarArea() {
        let available = ToolbarSearchFieldWidth.availableWidth(
            columnWidth: 534,
            inspectorWidth: AddressInspectorWidth.ideal
        )
        let width = ToolbarSearchFieldWidth.width(availableWidth: available)

        XCTAssertEqual(available, 234)
        XCTAssertEqual(width, 210)
        XCTAssertLessThanOrEqual(width, 220, "the field still overhangs into the message list")
    }

    /// Same iPad, inspector closed: the detail column is 473pt and the field
    /// keeps the width that made it right-align cleanly.
    func testTheTwoColumnLayoutIsUnchanged() {
        let available = ToolbarSearchFieldWidth.availableWidth(columnWidth: 473, inspectorWidth: 0)

        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: available), 260)
    }

    func testAnUnmeasuredColumnStaysUnmeasuredRatherThanGoingNegative() {
        // Subtracting the inspector from a pre-layout zero would read as a
        // negative pane and pin the field to its floor.
        XCTAssertEqual(
            ToolbarSearchFieldWidth.availableWidth(
                columnWidth: 0,
                inspectorWidth: AddressInspectorWidth.ideal
            ),
            0
        )
    }

    func testAWidePaneStillGetsThePreferredWidth() {
        // Two-column iPad and any ordinary Mac window: unchanged behaviour.
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: 474), 260)
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: 1_200), 260)
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
        // Zero is "not measured yet", not a zero-width pane: launching at the
        // floor and snapping wider a frame later is its own defect.
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: 0), ToolbarSearchFieldWidth.preferred)
        XCTAssertEqual(ToolbarSearchFieldWidth.width(availableWidth: -1), ToolbarSearchFieldWidth.preferred)
    }
}
