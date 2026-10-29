import CoreGraphics
import XCTest
@testable import CabalmailUI

/// The hinge hold and the two-pass rule, with the clock passed in. The
/// behaviour they pin is the Studio simulator's (Oct 7 spec): the division
/// region turns active a moment after the hinge rests and drops out while it
/// moves, the hinge reads "partially open" long before the app reaches the
/// inner display, and the first frame after a change can be stale.
final class FoldHoldTests: XCTestCase {
    private let wide = CGSize(width: 951, height: 669)
    private let tall = CGSize(width: 669, height: 951)
    private let crease = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    private func sample(_ region: CGRect?, _ size: CGSize? = nil) -> FoldSample {
        FoldSample(region: region, windowSize: size ?? wide)
    }

    private func partlyOpen(_ angle: Double) -> HingeReading {
        HingeReading(status: .partiallyOpen, angle: angle)
    }

    // MARK: Entering

    func testAnActiveRegionEntersTheFold() {
        var hold = FoldHold()
        hold.observe(sample(crease), at: 0)
        XCTAssertEqual(hold.state, .vertical(crease: crease))
    }

    func testHingeDataNeverEntersAFold() {
        var hold = FoldHold()
        hold.hingeChanged(partlyOpen(20), at: 0)
        hold.hingeChanged(partlyOpen(110), at: 1)
        hold.observe(sample(nil), at: 2)
        hold.tick(at: 10)
        XCTAssertEqual(hold.state, .none)
    }

    // MARK: Holding

    func testTheFoldHoldsWhileTheHingeMoves() {
        var hold = FoldHold()
        hold.hingeChanged(partlyOpen(110), at: 0)
        hold.observe(sample(crease), at: 0.5)
        // The region drops out as soon as the hinge moves, and stays out
        // for as long as it keeps moving.
        hold.observe(sample(nil), at: 1.0)
        for step in 1...20 {
            let time = 1.0 + Double(step) * 0.04
            hold.hingeChanged(partlyOpen(110 + Double(step)), at: time)
            hold.tick(at: time)
        }
        XCTAssertEqual(hold.state, .vertical(crease: crease), "a moving hinge holds the fold")
    }

    func testTheFoldEndsAfterTheGraceAtRestWithNoRegion() {
        var hold = FoldHold()
        hold.observe(sample(crease), at: 0)
        hold.hingeChanged(partlyOpen(130), at: 0)
        hold.observe(sample(nil), at: 1.0)
        hold.hingeChanged(partlyOpen(131), at: 1.2)
        XCTAssertEqual(hold.deadline, 1.2 + FoldHold.defaultGrace)
        hold.tick(at: 1.7)
        XCTAssertTrue(hold.state.isFolded, "still inside the grace after the last movement")
        hold.tick(at: 1.8)
        XCTAssertEqual(hold.state, .none)
        XCTAssertNil(hold.deadline)
    }

    func testTheRegionComingBackKeepsTheFold() {
        var hold = FoldHold()
        hold.observe(sample(crease), at: 0)
        hold.observe(sample(nil), at: 1)
        hold.observe(sample(crease), at: 1.3)
        hold.tick(at: 5)
        XCTAssertEqual(hold.state, .vertical(crease: crease))
        XCTAssertNil(hold.deadline)
    }

    // MARK: Ending

    func testAFullyOpenHingeEndsAHeldFoldAtOnce() {
        var hold = FoldHold()
        hold.observe(sample(crease), at: 0)
        hold.hingeChanged(partlyOpen(170), at: 1)
        hold.observe(sample(nil), at: 1.05)
        hold.hingeChanged(HingeReading(status: .fullyOpen, angle: 180), at: 1.1)
        XCTAssertEqual(hold.state, .none)
    }

    /// The region wins over the hinge: a fully open reading while the region
    /// is still active leaves the fold, and ends it the moment the region
    /// drops, without waiting out the grace.
    func testAFullyOpenHingeEndsTheFoldWhenTheRegionDrops() {
        var hold = FoldHold()
        hold.observe(sample(crease), at: 0)
        hold.hingeChanged(partlyOpen(176), at: 1)
        hold.hingeChanged(HingeReading(status: .fullyOpen, angle: 180), at: 1.1)
        XCTAssertEqual(hold.state, .vertical(crease: crease))
        hold.observe(sample(nil), at: 1.2)
        XCTAssertEqual(hold.state, .none)
    }

    /// Closing reads "closed" from about 62 degrees, possibly while the app
    /// is still on the inner display, so a closed status holds like motion
    /// and the switch to the outer display ends the fold.
    func testAClosedHingeHoldsUntilTheWindowChanges() {
        var hold = FoldHold()
        hold.observe(sample(crease), at: 0)
        hold.hingeChanged(partlyOpen(90), at: 1)
        hold.observe(sample(nil), at: 1.05)
        hold.hingeChanged(HingeReading(status: .closed, angle: 61), at: 1.1)
        XCTAssertEqual(hold.state, .vertical(crease: crease))
        hold.observe(sample(nil, CGSize(width: 466, height: 678)), at: 1.3)
        XCTAssertEqual(hold.state, .none)
    }

    /// Losing the hinge ends a fold the hinge was holding, but not one the
    /// region still backs.
    func testNoHingeEndsOnlyAHeldFold() {
        var backed = FoldHold()
        backed.observe(sample(crease), at: 0)
        backed.hingeChanged(nil, at: 1)
        XCTAssertEqual(backed.state, .vertical(crease: crease))

        var held = FoldHold()
        held.observe(sample(crease), at: 0)
        held.observe(sample(nil), at: 1)
        held.hingeChanged(nil, at: 1.1)
        XCTAssertEqual(held.state, .none)
    }

    /// A rotation from book to laptop changes the window's shape: the crease
    /// the hold kept is in the wrong place, so it ends rather than waits.
    func testTheWindowChangingSizeEndsTheFoldAtOnce() {
        var hold = FoldHold()
        hold.observe(sample(crease), at: 0)
        hold.hingeChanged(partlyOpen(130), at: 0.5)
        hold.hingeChanged(partlyOpen(131), at: 1.0)
        hold.observe(sample(nil, tall), at: 1.0)
        XCTAssertEqual(hold.state, .none)
    }

    func testANewRegionAfterARotationEntersTheOtherAxis() {
        let laptop = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        var hold = FoldHold()
        hold.observe(sample(crease), at: 0)
        hold.observe(sample(nil, tall), at: 1)
        hold.observe(sample(laptop, tall), at: 1.3)
        XCTAssertEqual(hold.state, .horizontal(crease: laptop))
    }
}

/// The two-pass rule on its own.
final class FoldSettlerTests: XCTestCase {
    func testAValueSettlesWhenTwoPassesInARowAgree() {
        var settler = FoldSettler<Int>()
        XCTAssertNil(settler.pass(1))
        XCTAssertEqual(settler.pass(1), 1)
        XCTAssertEqual(settler.settled, 1)
    }

    /// The stale first frame: a value the next pass replaced never settles,
    /// and the replacement settles on the pass that confirms it.
    func testAValueReplacedByTheNextPassNeverSettles() {
        var settler = FoldSettler<String>()
        XCTAssertNil(settler.pass("stale"))
        XCTAssertNil(settler.pass("fresh"))
        XCTAssertEqual(settler.pass("fresh"), "fresh")
        XCTAssertEqual(settler.settled, "fresh")
    }

    func testASettledValueIsReportedOnce() {
        var settler = FoldSettler<Int>()
        _ = settler.pass(1)
        XCTAssertEqual(settler.pass(1), 1)
        XCTAssertNil(settler.pass(1))
        XCTAssertNil(settler.pass(1))
    }

    func testFlickeringBetweenTwoValuesNeverSettlesEither() {
        var settler = FoldSettler<Int>()
        _ = settler.pass(0)
        XCTAssertEqual(settler.pass(0), 0)
        for value in [1, 0, 1, 0, 1] {
            XCTAssertNil(settler.pass(value))
        }
        XCTAssertEqual(settler.settled, 0)
    }
}

/// `\.foldDivision`'s hold: the crease's place is kept while the window keeps
/// its size, and goes with a close, an open or a rotation.
final class DivisionHoldTests: XCTestCase {
    private let wide = CGSize(width: 951, height: 669)
    private let tall = CGSize(width: 669, height: 951)
    private let closed = CGSize(width: 466, height: 678)
    private let band = CGRect(x: 455.5, y: 0, width: 40, height: 669)
    private let tallBand = CGRect(x: 0, y: 455.5, width: 669, height: 40)

    func testABandIsKeptThroughAReadingWithoutOneAtTheSameSize() {
        var hold = DivisionHold()
        hold.observe(FoldSample(region: nil, windowSize: wide, division: band))
        XCTAssertEqual(hold.division, band)
        hold.observe(FoldSample(region: nil, windowSize: wide))
        XCTAssertEqual(hold.division, band, "a hinge moving drops the region, not the window")
    }

    func testAReadingAtAnotherSizeReplacesOrDropsIt() {
        var hold = DivisionHold()
        hold.observe(FoldSample(region: nil, windowSize: wide, division: band))
        hold.observe(FoldSample(region: nil, windowSize: closed))
        XCTAssertNil(hold.division, "closed: no crease")
        hold.observe(FoldSample(region: nil, windowSize: wide, division: band))
        hold.observe(FoldSample(region: nil, windowSize: tall, division: tallBand))
        XCTAssertEqual(hold.division, tallBand, "rotated")
    }

    /// The division is not a fold: an inactive band never folds the window.
    func testAnInactiveBandNeverFolds() {
        var fold = FoldHold()
        fold.observe(FoldSample(region: nil, windowSize: wide, division: band), at: 0)
        XCTAssertEqual(fold.state, .none)
    }
}
