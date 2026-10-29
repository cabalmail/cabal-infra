import CoreGraphics
import XCTest
@testable import CabalmailUI

/// The pinned list column's width and handle (`ListColumnPolicy`), against
/// the geometry measured on the Studio's iPhone Duo simulator (iOS 27.1,
/// 2026-10-27): the inner display is 951 by 669 pt, its split view is laid
/// out 867 pt wide with the 84 pt side strip outside it, and the division
/// band runs from x 455.5 to 495.5, inactive flat and active in book pose.
/// Laptop and open portrait are 669 by 951, the split 669 wide.
final class ListColumnPolicyTests: XCTestCase {
    private let duoSplit = CGRect(x: 0, y: 0, width: 867, height: 635)
    private let band = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    private let tallSplit = CGRect(x: 0, y: 82, width: 669, height: 835)
    private let tallBand = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    private func policy(
        split: CGRect,
        fold: FoldState = .none,
        division: CGRect? = nil,
        stored: CGFloat? = nil,
        live: CGFloat? = nil
    ) -> ListColumnPolicy {
        ListColumnPolicy(split: split, fold: fold, division: division, stored: stored, live: live)
    }

    // MARK: - The Duo

    /// Flat, with no width of its own, the list ends at the crease band's
    /// leading edge, which is where book pose pins it: folding moves nothing.
    func testFlatWithNothingStoredTheListEndsAtTheCrease() {
        let flat = policy(split: duoSplit, division: band)
        XCTAssertEqual(flat.bounds, 320...491)
        XCTAssertEqual(flat.width, 455.5)
        let book = policy(split: duoSplit, fold: .vertical(crease: band), division: band)
        XCTAssertEqual(book.width, flat.width, "folding moves nothing")
        XCTAssertEqual(flat.readerFloor, 360)
        XCTAssertTrue(flat.handleIsShown)
        XCTAssertEqual(flat.resetTitle, "Reset to Fold")
        XCTAssertFalse(flat.canReset, "nothing to clear")
    }

    func testFlatAStoredWidthWinsAndIsClamped() {
        for (stored, expected) in [(CGFloat(400), CGFloat(400)), (520, 491), (300, 320)] {
            let flat = policy(split: duoSplit, division: band, stored: stored)
            XCTAssertEqual(flat.width, expected, "stored \(stored)")
            XCTAssertTrue(flat.canReset)
        }
    }

    /// Book pose pins the list to the crease over any width of the user's,
    /// and the handle hides.
    func testBookPinsTheListToTheCreaseAndHidesTheHandle() {
        for stored in [nil, CGFloat(320), 400, 491] {
            let book = policy(split: duoSplit, fold: .vertical(crease: band), division: band, stored: stored, live: 330)
            XCTAssertEqual(book.width, 455.5, "stored \(String(describing: stored))")
            XCTAssertFalse(book.handleIsShown)
            XCTAssertFalse(book.canReset)
        }
    }

    /// The transient full-window reading a posture change gives: the line
    /// is the same, so nothing moves.
    func testAFullWidthReadingKeepsTheListAtTheCrease() {
        let wide = policy(split: CGRect(x: 0, y: 0, width: 951, height: 635), division: band)
        XCTAssertEqual(wide.bounds, 320...575)
        XCTAssertEqual(wide.width, 455.5)
    }

    /// Laptop pose pins nothing, and in the 669 pt split the list has no
    /// travel, so the handle hides; open portrait is the same window, flat.
    func testLaptopAndOpenPortraitPinNothingAndHideTheHandle() {
        for fold in [FoldState.horizontal(crease: tallBand), .none] {
            let tall = policy(split: tallSplit, fold: fold, division: tallBand, stored: 400)
            XCTAssertEqual(tall.bounds, 293...293)
            XCTAssertEqual(tall.width, 293, "the measured width")
            XCTAssertEqual(tall.readerFloor, 360)
            XCTAssertFalse(tall.handleIsShown)
            XCTAssertNil(tall.foldLine, "a horizontal band is no place for a list")
        }
    }

    /// A strip on the leading edge moves the split, not the crease.
    func testTheCreaseIsMeasuredFromTheListsLeadingEdge() {
        let shifted = policy(split: CGRect(x: 84, y: 0, width: 867, height: 635), division: band)
        XCTAssertEqual(shifted.width, 371.5)
    }

    /// A band the range cannot seat is not this column's: the list keeps its
    /// own width rather than squeezing to its floor.
    func testABandOutOfRangeFallsThrough() {
        let inspector = policy(split: CGRect(x: 0, y: 0, width: 567, height: 635),
                               fold: .vertical(crease: band), division: band, stored: 400)
        XCTAssertNil(inspector.pin)
        XCTAssertEqual(inspector.width, 220, "the stored width, clamped")
        var sidebar = policy(split: duoSplit, fold: .vertical(crease: band), division: band)
        sidebar.leadingColumnsWidth = 260
        XCTAssertNil(sidebar.pin, "195.5 is under the floor")
        XCTAssertEqual(sidebar.width, 231)
    }

    // MARK: - The list over the reader

    /// Laptop pose and open portrait are a window taller than wide: the list
    /// floats over a reader that takes the whole split (`ListOverlay`,
    /// #1686), at the width it has before anyone sets one, with no handle
    /// and no pin. So does an iPad in portrait.
    func testATallWindowFloatsTheListOverTheReader() {
        for fold in [FoldState.horizontal(crease: tallBand), .none] {
            var tall = policy(split: tallSplit, fold: fold, division: tallBand, stored: 400)
            tall.windowIsTall = true
            XCTAssertTrue(tall.overlaysReader)
            XCTAssertEqual(tall.width, 360)
            XCTAssertEqual(tall.readerFloor, 669, "the whole split, so UIKit can't tile the two")
            XCTAssertFalse(tall.handleIsShown)
        }
        var portrait = policy(split: CGRect(x: 0, y: 0, width: 834, height: 1100), stored: 400)
        portrait.windowIsTall = true
        XCTAssertEqual(portrait.width, 360)
        XCTAssertEqual(portrait.readerFloor, 834)
    }

    /// A split narrowed below its height in a wide window, by the addresses
    /// inspector, still tiles: the window's shape decides, not the split's.
    func testAWideWindowTilesHoweverNarrowItsSplit() {
        let squeezed = policy(split: CGRect(x: 0, y: 0, width: 567, height: 635), stored: 400)
        XCTAssertFalse(squeezed.overlaysReader)
        XCTAssertEqual(squeezed.width, 220)
    }

    // MARK: - iPad

    func testIPadKeepsItsDefaultAndGainsTheWideFloorInLandscapeOnly() {
        let portrait = policy(split: CGRect(x: 0, y: 0, width: 834, height: 1100))
        XCTAssertEqual(portrait.bounds, 300...458)
        XCTAssertEqual(portrait.width, 360)
        XCTAssertEqual(portrait.resetTitle, "Reset Width")
        let landscape = policy(split: CGRect(x: 0, y: 0, width: 1194, height: 800), stored: 310)
        XCTAssertEqual(landscape.bounds, 320...818)
        XCTAssertEqual(landscape.width, 320, "a width under the new floor reads as the floor")
    }

    /// #2106's inspector case: no travel, so no handle, and the reader's
    /// floor yields.
    func testIPadPortraitWithTheInspectorOpenHasNoTravel() {
        let squeezed = policy(split: CGRect(x: 0, y: 0, width: 534, height: 1100))
        XCTAssertEqual(squeezed.bounds, 220...220)
        XCTAssertEqual(squeezed.width, 220)
        XCTAssertEqual(squeezed.readerFloor, 298)
        XCTAssertFalse(squeezed.handleIsShown)
    }

    func testUnmeasuredTheRangeIsGenerousAndNothingPins() {
        let unmeasured = policy(split: .zero, fold: .vertical(crease: band), division: band, stored: 500)
        XCTAssertEqual(unmeasured.bounds, 300...640)
        XCTAssertNil(unmeasured.pin)
        XCTAssertNil(unmeasured.foldLine)
        XCTAssertEqual(unmeasured.width, 500)
        XCTAssertEqual(unmeasured.readerFloor, 360)
    }

    // MARK: - Precedence

    func testTheWidthComesFromThePinThenTheDragThenTheStoreThenTheCrease() {
        let book = policy(split: duoSplit, fold: .vertical(crease: band), division: band, stored: 400, live: 330)
        XCTAssertEqual(book.width, 455.5)
        XCTAssertEqual(policy(split: duoSplit, division: band, stored: 400, live: 330).width, 330)
        XCTAssertEqual(policy(split: duoSplit, division: band, stored: 400).width, 400)
        XCTAssertEqual(policy(split: duoSplit, division: band).width, 455.5)
        XCTAssertEqual(policy(split: duoSplit).width, 360)
        XCTAssertEqual(policy(split: duoSplit, live: 900).width, 491, "a drag is clamped")
    }

    func testAStoredValueIsAWidthOnlyWhenPositiveAndFinite() {
        XCTAssertNil(ListColumnPolicy.storedWidth(0))
        XCTAssertNil(ListColumnPolicy.storedWidth(-1))
        XCTAssertNil(ListColumnPolicy.storedWidth(.nan))
        XCTAssertNil(ListColumnPolicy.storedWidth(.infinity))
        XCTAssertEqual(ListColumnPolicy.storedWidth(400), 400)
    }

    // MARK: - The unfold's one animation

    func testOnlyAnUnfoldAnimatesAndNotWithReduceMotion() {
        let book = FoldState.vertical(crease: band)
        let laptop = FoldState.horizontal(crease: tallBand)
        func animates(_ from: FoldState, _ to: FoldState, _ division: CGRect?, reduceMotion: Bool = false) -> Bool {
            ListColumnPolicy.unfoldAnimates(from: from, to: to, division: division, reduceMotion: reduceMotion)
        }
        XCTAssertTrue(animates(book, .none, band), "unfolding flat")
        XCTAssertFalse(animates(book, .none, band, reduceMotion: true))
        XCTAssertFalse(animates(book, .none, tallBand), "a rotation moves the list with the window")
        XCTAssertFalse(animates(book, .none, nil), "a close")
        XCTAssertFalse(animates(.none, book, band), "folding moves nothing to animate")
        XCTAssertFalse(animates(book, laptop, tallBand))
        XCTAssertFalse(animates(laptop, .none, tallBand))
    }

    // MARK: - Invariants

    /// Wherever the split is measured the list and the reader's floor leave
    /// #1716's slack, the range never goes under the squeezed minimum, and
    /// the width stays in it.
    func testEveryLayoutLeavesTheSlackAndStaysInRange() {
        let storedWidths: [CGFloat?] = [nil, 220, 300, 360, 378, 455.5, 640]
        for width in stride(from: CGFloat(414), through: 1400, by: 7) {
            for height in [CGFloat(600), 1200] {
                let split = CGRect(x: 0, y: 0, width: width, height: height)
                for stored in storedWidths {
                    for fold in [FoldState.none, .vertical(crease: band)] {
                        for division in [nil, band] {
                            let layout = policy(split: split, fold: fold, division: division, stored: stored)
                            let label = "\(width)x\(height) stored \(String(describing: stored)) \(fold)"
                            XCTAssertGreaterThanOrEqual(layout.available - layout.width - layout.readerFloor, 16, label)
                            XCTAssertGreaterThanOrEqual(layout.bounds.lowerBound, 220, label)
                            XCTAssertTrue(layout.bounds.contains(layout.width), label)
                            XCTAssertGreaterThan(layout.readerFloor, 0, label)
                        }
                    }
                }
            }
        }
    }
}

/// A drag records nothing until it ends, and a fold ends it unsaved.
final class ListColumnStateTests: XCTestCase {
    private let band = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    func testADragTracksTheFingerAndRecordsOnceWhenItEnds() {
        var state = ListColumnState()
        state.beginDrag(tab: .mail, from: 360)
        state.moveDrag(tab: .mail, translation: 40, bounds: 320...491)
        XCTAssertEqual(state.liveWidth(for: .mail), 400)
        XCTAssertNil(state.liveWidth(for: .feeds))
        state.moveDrag(tab: .mail, translation: 400, bounds: 320...491)
        XCTAssertEqual(state.liveWidth(for: .mail), 491, "clamped, against the anchor")
        XCTAssertEqual(state.endDrag(tab: .mail), 491)
        XCTAssertNil(state.endDrag(tab: .mail), "once")
        XCTAssertNil(state.liveWidth(for: .mail))
    }

    func testACancelledDragRecordsNothing() {
        var state = ListColumnState()
        state.beginDrag(tab: .mail, from: 360)
        state.moveDrag(tab: .mail, translation: -20, bounds: 320...491)
        state.cancelDrag()
        XCTAssertNil(state.endDrag(tab: .mail))
    }

    func testAFoldEndsADragUnsavedAndNoneStartsWhileFolded() {
        for fold in [FoldState.vertical(crease: band), .horizontal(crease: band)] {
            var state = ListColumnState()
            state.beginDrag(tab: .mail, from: 360)
            state.moveDrag(tab: .mail, translation: 30, bounds: 320...491)
            state.follow(fold)
            XCTAssertNil(state.endDrag(tab: .mail))
            state.beginDrag(tab: .mail, from: 360)
            XCTAssertNil(state.liveWidth(for: .mail), "the handle is hidden")
            XCTAssertEqual(state.fold, fold)
        }
    }

    func testADragOnAListTheColumnStoppedShowingIsDropped() {
        var state = ListColumnState()
        state.beginDrag(tab: .mail, from: 360)
        state.moveDrag(tab: .feeds, translation: 30, bounds: 320...491)
        XCTAssertNil(state.endDrag(tab: .mail))
        state.beginDrag(tab: .mail, from: 360)
        XCTAssertNil(state.endDrag(tab: .feeds))
        XCTAssertNil(state.endDrag(tab: .mail), "ending on another list cleared it")
    }
}

final class ListColumnTabTests: XCTestCase {
    func testEachListKeepsItsOwnWindowKey() {
        let keys = ListColumnTab.allCases.map(\.sceneStorageKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys {
            XCTAssertTrue(key.hasPrefix("cabalmail.window."), key)
        }
    }

    func testRetiringRemovesTheAppWideWidth() throws {
        let suite = "ListColumnTabTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(420.0, forKey: ListColumnTab.retiredAppWideKey)
        ListColumnTab.retireAppWideWidth(in: defaults)
        XCTAssertNil(defaults.object(forKey: ListColumnTab.retiredAppWideKey))
    }
}
