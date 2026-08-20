import XCTest

/// Regression cover for #1188: `scroll` put a finger on the chrome at the edge
/// of the container it was supposed to be scrolling, and said `ok:true`.
///
/// The two failing cases are pinned as arithmetic because both of them are:
/// the numbers below are the frames measured on the simulators, and the
/// margins are the measured boundary between the arms that scrolled and the
/// arms that dismissed a sheet or resized a window.
final class ScrollGestureTests: XCTestCase {

    /// iPadOS 26.5, portrait iPad Pro 11-inch: an 834x1210 window, the
    /// Settings form sheet's list occupying `{{127, 275}, {580, 650}}`. The
    /// default `amount:0.5` asks for 605 points of travel.
    private let sheetContainerHeight: CGFloat = 650
    private let sheetRequest: CGFloat = 605
    /// A press 88 points below the sheet's top edge scrolled it; one 58 points
    /// below dismissed it. 88 is the margin the gesture has to clear.
    private let sheetSafeMargin: CGFloat = 88

    /// visionOS 26.5: a 1280x720 window whose Settings list fills it, so the
    /// container IS the window. The default `amount:0.5` asks for 360 points.
    private let visionContainerHeight: CGFloat = 720
    private let visionRequest: CGFloat = 360
    /// 144 points of travel (endpoints 288 from each edge) scrolled; 288 and
    /// 360 points (216 and 180 from each edge) collapsed the window instead.
    private let visionSafeMargin: CGFloat = 288

    /// The clearance between a sweep's furthest endpoint and the container's
    /// nearer edge — the quantity both defects were really about.
    private func edgeClearance(_ plan: ScrollGesture, containerHeight: CGFloat) -> CGFloat {
        let (press, release) = plan.offsets(goingDown: true)
        return containerHeight / 2 - max(abs(press), abs(release))
    }

    func testTheIPadSheetCaseKeepsBothEndsClearOfTheSheetEdge() {
        let plan = ScrollGesture.plan(requestedTravel: sheetRequest, containerHeight: sheetContainerHeight)
        XCTAssertGreaterThanOrEqual(
            edgeClearance(plan, containerHeight: sheetContainerHeight),
            sheetSafeMargin,
            "a sweep reaching within \(sheetSafeMargin)pt of the sheet's edge dismisses it"
        )
    }

    func testTheVisionOSWindowCaseKeepsBothEndsClearOfTheWindowEdge() {
        let plan = ScrollGesture.plan(requestedTravel: visionRequest, containerHeight: visionContainerHeight)
        XCTAssertGreaterThanOrEqual(
            edgeClearance(plan, containerHeight: visionContainerHeight),
            visionSafeMargin,
            "a sweep reaching within \(visionSafeMargin)pt of the window's edge resizes it"
        )
    }

    /// The rule the two cases above share, stated once: whatever the request,
    /// no single sweep spans more than a fifth of its container.
    func testNoSweepSpansMoreThanAFifthOfItsContainer() {
        for height in stride(from: CGFloat(120), through: 1400, by: 40) {
            for amount in [0.05, 0.2, 0.5, 0.9] {
                let plan = ScrollGesture.plan(requestedTravel: CGFloat(amount) * height, containerHeight: height)
                // The fifth is spelled out rather than read back off
                // `sweepSpanFraction`, which would make this pass for
                // whatever the constant happened to say.
                XCTAssertLessThanOrEqual(
                    plan.sweepTravel,
                    height * 0.2 + 0.001,
                    "height \(height), amount \(amount)"
                )
            }
        }
    }

    /// The defect, kept as arithmetic: spending the whole request in one sweep
    /// — what the verb did before — misses both measured margins. Without this
    /// the tests above pass for a rule that never had to change.
    func testSpendingTheWholeRequestInOneSweepMissesBothMargins() {
        XCTAssertLessThan(
            sheetContainerHeight / 2 - sheetRequest / 2, sheetSafeMargin,
            "the iPad case has to be one the old single-sweep rule got wrong"
        )
        XCTAssertLessThan(
            visionContainerHeight / 2 - visionRequest / 2, visionSafeMargin,
            "the visionOS case has to be one the old single-sweep rule got wrong"
        )
    }

    func testTheRequestedTravelIsSpentInFull() {
        let plan = ScrollGesture.plan(requestedTravel: sheetRequest, containerHeight: sheetContainerHeight)
        XCTAssertEqual(plan.totalTravel, sheetRequest, accuracy: 0.001)
        XCTAssertFalse(plan.truncated)
    }

    /// A request that already fits is left alone — one sweep, exactly the
    /// travel asked for, which is what the `amount:0.2` workaround relied on.
    func testARequestThatFitsStaysASingleSweep() {
        let plan = ScrollGesture.plan(requestedTravel: 100, containerHeight: 650)
        XCTAssertEqual(plan.sweeps, 1)
        XCTAssertEqual(plan.sweepTravel, 100, accuracy: 0.001)
    }

    /// A big request in a short container hits the sweep cap. It then moves
    /// less than it was asked for, and has to say so rather than repeating the
    /// silence that made the original defect hard to see.
    func testACappedPlanReportsTheShortfall() {
        let plan = ScrollGesture.plan(requestedTravel: 1089, containerHeight: 400)
        XCTAssertEqual(plan.sweeps, ScrollGesture.maxSweeps)
        XCTAssertTrue(plan.truncated)
        XCTAssertLessThan(plan.totalTravel, 1089)
    }

    /// `dir:down` means "show me what is below", so the finger travels up.
    func testDirectionOnlySwapsTheEndpoints() {
        let plan = ScrollGesture.plan(requestedTravel: 300, containerHeight: 720)
        let down = plan.offsets(goingDown: true)
        let up = plan.offsets(goingDown: false)
        XCTAssertGreaterThan(down.press, down.release)
        XCTAssertEqual(down.press, -up.press, accuracy: 0.001)
        XCTAssertEqual(down.release, -up.release, accuracy: 0.001)
    }
}
