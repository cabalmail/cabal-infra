import XCTest
@testable import CabalmailUI

// Regression coverage for issue #2106, a sibling of `ListColumnWidthTests`'
// #1716 section (split out for the type-body cap, like the mail-mutation
// suites).
//
// Where the list column is PINNED (regular-width iPad), #1716 stopped the
// pinned width short of an exact fit against the reading pane's declared
// floor, because UIKit resolves an exact fit at launch and drops the primary
// column when a size transition re-resolves it. But the pinned ceiling stops
// falling at `squeezedMinimum`, so from 596pt of split downwards the pinned
// width plus a CONSTANT floor is not an exact fit but an over-subscribed one,
// and it fails in the same place.
//
// The addresses inspector is what puts an iPad in that band: it tiles beside
// the split at regular width and takes its width out of the measurement, so
// the reported 834pt portrait window left a 534pt split — 220pt of list
// against a 360pt floor. Composing from the message list's overflow menu and
// cancelling was the size transition that collected it: list column and every
// toolbar control gone, the reader's placeholder alone in the window with the
// inspector, and no way back without a relaunch.
final class ListColumnPinnedReaderFloorTests: XCTestCase {

    /// The stored column width behind #1716's sweep, kept as the realistic
    /// "dragged to something" case alongside the range's own ends.
    private let storedWidthBehindTheSweep: CGFloat = 378
    private let storedWidths: [CGFloat] = [220, 300, 360, 378, 420, 640]

    /// The reported configuration: an 834pt portrait window with the inspector
    /// tiled beside the split at its `ideal`.
    private var splitBesideTheInspector: CGFloat {
        834 - AddressInspectorWidth.ideal
    }

    /// The narrowest split a regular-width iPad can leave, the inspector
    /// dragged to its `maximum`.
    private var narrowestSupportedSplit: CGFloat {
        834 - AddressInspectorWidth.maximum
    }

    /// What the column is actually pinned to, exactly as
    /// `SplitShell.listColumnWidth` computes it.
    private func pinnedWidth(stored: CGFloat, inSplitOfWidth split: CGFloat) -> CGFloat {
        let bounds = ListColumnWidth.pinnedBounds(splitWidth: split)
        return min(max(stored, bounds.minimum), bounds.maximum)
    }

    /// What the reader declares beside it, exactly as
    /// `SplitShell.readerColumnMinWidth` computes it.
    private func declaredReaderFloor(stored: CGFloat, inSplitOfWidth split: CGFloat) -> CGFloat {
        ListColumnWidth.pinnedReaderFloor(
            splitWidth: split,
            listWidth: pinnedWidth(stored: stored, inSplitOfWidth: split)
        )
    }

    // The invariant, now across every split a regular-width iPad can leave
    // rather than only those wide enough for the constant floor: what the two
    // columns declare always leaves the split `reservedSlack` to resolve in.
    func testTheDeclaredColumnsNeverOverSubscribeTheSplit() {
        for split in stride(from: narrowestSupportedSplit, through: 1400, by: 1) {
            for stored in storedWidths {
                let list = pinnedWidth(stored: stored, inSplitOfWidth: split)
                let floor = declaredReaderFloor(stored: stored, inSplitOfWidth: split)
                XCTAssertGreaterThanOrEqual(
                    split - list - floor, ListColumnWidth.reservedSlack,
                    "a \(split)pt split with \(stored)pt stored declares \(list) + \(floor)"
                )
                XCTAssertGreaterThan(floor, 0, "no floor at all in a \(split)pt split")
            }
        }
    }

    // The reported case, named rather than left to the sweep: the inspector
    // open in portrait leaves a split the constant floor over-subscribed, and
    // the derived one fits with the slack to spare.
    func testTheSplitBesideTheInspectorFitsBothColumns() {
        let split = splitBesideTheInspector
        let list = pinnedWidth(stored: storedWidthBehindTheSweep, inSplitOfWidth: split)
        XCTAssertEqual(list, ListColumnWidth.squeezedMinimum,
                       "the list is not squeezed to its floor beside the inspector")
        XCTAssertLessThan(
            split - list, ListColumnWidth.readerFloor + ListColumnWidth.reservedSlack,
            "the constant floor would have fitted here, so this is the wrong arm"
        )
        XCTAssertEqual(
            ListColumnWidth.pinnedReaderFloor(splitWidth: split, listWidth: list),
            split - list - ListColumnWidth.reservedSlack,
            "the derived floor does not take the remainder of the split"
        )
    }

    // And the floor only yields where it has to: wherever the split can seat
    // `readerFloor` beside the pinned column, that is still what the reader
    // declares, so nothing about the roomy layouts moves.
    func testAnUncrampedSplitStillDeclaresTheFullReaderFloor() {
        for split in stride(from: CGFloat(600), through: 1400, by: 1) {
            for stored in storedWidths {
                XCTAssertEqual(
                    declaredReaderFloor(stored: stored, inSplitOfWidth: split),
                    ListColumnWidth.readerFloor,
                    "a \(split)pt split with \(stored)pt stored shrinks the reader's floor"
                )
            }
        }
    }

    // The pre-layout measurement declares the floor it always did: nothing is
    // pinned against anything yet, and the first layout seats both columns.
    func testTheUnmeasuredSplitDeclaresTheConstantFloor() {
        XCTAssertEqual(
            ListColumnWidth.pinnedReaderFloor(splitWidth: 0, listWidth: ListColumnWidth.ideal),
            ListColumnWidth.readerFloor
        )
    }
}
