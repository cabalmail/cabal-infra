import XCTest
@testable import Cabalmail

// Regression coverage for issue #983: the macOS folder sidebar came up at
// SwiftUI's own default column width, which the tester measured at 144pt with
// the row content starting ~60pt in (two nested `DisclosureGroup`s inside a
// sidebar `List`) and an unread badge and row menu on the trailing side. That
// left `INBOX` 14pt and `Archive` 31pt of label, i.e. `I…` and `Arc…`, on every
// launch. The width the column opens at is now this policy's, and a width the
// user drags to is persisted.
final class SidebarColumnWidthTests: XCTestCase {

    // The geometry the tester captured on macOS 27: the column, and the widest
    // of the two truncated names.
    private let observedColumnWidth: CGFloat = 144
    private let observedRowInset: CGFloat = 85

    func testTheLaunchWidthLeavesAFolderNameRoomToRead() {
        let launchWidth = SidebarColumnWidth.resolved(stored: 0)
        // Past the inset, "Archive" rendered in 31pt when it needed ~55, and the
        // badge and row menu still want their share of what's left.
        XCTAssertGreaterThan(
            launchWidth - observedRowInset,
            observedColumnWidth,
            "a launch has to leave more than the whole old column for the name, badge and row menu"
        )
    }

    func testADeliberateResizeIsWhatComesBackNextLaunch() {
        XCTAssertEqual(SidebarColumnWidth.resolved(stored: 320), 320)
    }

    func testAStoredWidthOutsideTheAllowedRangeIsClamped() {
        XCTAssertEqual(SidebarColumnWidth.resolved(stored: 40), SidebarColumnWidth.minimum)
        XCTAssertEqual(SidebarColumnWidth.resolved(stored: 4000), SidebarColumnWidth.maximum)
    }

    func testADragIsPersisted() {
        // 292 is what the layout reported after a divider drag to a 300pt
        // column in the AppKit probe (the split keeps 8pt for the divider),
        // and 292 fed back as the launch width reproduces that 300pt column.
        XCTAssertTrue(SidebarColumnWidth.shouldPersist(measured: 292, stored: 0))
        XCTAssertEqual(SidebarColumnWidth.resolved(stored: 292), 292)
        XCTAssertTrue(SidebarColumnWidth.shouldPersist(measured: 200, stored: 292))
    }

    // The column reporting back (near enough) the width it was asked for is the
    // layout settling, not a drag. Persisting that would feed a systematic
    // few-point delta back as the next launch's width, walking the sidebar
    // narrower on every run — the very failure being fixed.
    func testSettlingAtTheWidthWeAskedForIsNotADrag() {
        XCTAssertFalse(
            SidebarColumnWidth.shouldPersist(measured: SidebarColumnWidth.ideal, stored: 0),
            "an unresized launch must not write a width"
        )
        XCTAssertFalse(SidebarColumnWidth.shouldPersist(measured: 318, stored: 320))
        XCTAssertFalse(
            SidebarColumnWidth.shouldPersist(measured: 0, stored: 320),
            "the pre-layout measurement is not a resize"
        )
    }

    func testRepeatedLaunchesHoldTheSameWidth() {
        // Three launches with the same small measurement delta: the stored
        // width has to be the same each time, not 4pt narrower.
        var stored = 320.0
        for _ in 0..<3 {
            let measured = SidebarColumnWidth.resolved(stored: stored) - 2
            if SidebarColumnWidth.shouldPersist(measured: measured, stored: stored) {
                stored = Double(SidebarColumnWidth.clamp(measured))
            }
        }
        XCTAssertEqual(stored, 320)
    }
}
