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
    /// 288 and 360 points of travel (endpoints 216 and 180 from each edge)
    /// collapsed the window; 144 points (endpoints 288 from each edge) left it
    /// alone. 288 is the margin the gesture has to clear to stay off the
    /// window chrome, which is what this fixture is about and still holds.
    ///
    /// The 144-point arm was recorded here as "scrolled", and #1191 has since
    /// measured that no press-drag scrolls anything on visionOS at any travel
    /// — it was safe, not effective. The clamp is unaffected: it exists to
    /// keep the endpoints off the chrome, and that is what these numbers pin.
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


/// Regression cover for #1191: on visionOS a press-and-drag scrolls nothing at
/// all, so `scroll` reported a plausible travel and left every row on the
/// point. The verb now measures whether the anchor moved and falls back to
/// element swipes when it did not — these pin the two rules that decision
/// rests on.
final class ScrollProgressTests: XCTestCase {

    /// The measured visionOS reading: `message.row.189` sat at 306.0 before
    /// the drag and 306.0 after it, through five sweeps.
    func testAStationaryAnchorIsNotAScroll() {
        XCTAssertFalse(ScrollProgress.moved(from: 306.0, to: 306.0))
    }

    /// The measured iPadOS reading, where the drag works: a Settings row
    /// travelled 242 points across two sweeps.
    func testAMovedAnchorIsAScroll() {
        XCTAssertTrue(ScrollProgress.moved(from: 604.0, to: 362.0))
    }

    /// Sub-point drift is the tree settling — visionOS reported a one-time
    /// 9.5-point inset settle in one arm, and half a point is not that.
    func testDriftBelowThresholdIsNotAScroll() {
        XCTAssertFalse(ScrollProgress.moved(from: 306.0, to: 306.4))
        XCTAssertTrue(ScrollProgress.moved(from: 306.0, to: 307.0))
    }

    /// An anchor that scrolled clean out of the accessibility tree is the
    /// strongest evidence of a scroll there is, not a failure to measure one.
    func testAnAnchorLeavingTheTreeCountsAsAScroll() {
        XCTAssertTrue(ScrollProgress.moved(from: 190.0, to: nil))
    }

    /// ...but one that was never in the tree proves nothing, and must not be
    /// read as a scroll: that would skip the fallback on exactly the platform
    /// that needs it.
    func testAnAnchorThatWasNeverThereIsNotAScroll() {
        XCTAssertFalse(ScrollProgress.moved(from: nil, to: nil))
        XCTAssertFalse(ScrollProgress.moved(from: nil, to: 190.0))
    }

    /// A swipe's step is fixed — 435 points in the measured 393-point
    /// container — so a small `amount:` is covered by the first one and must
    /// not spend a second.
    func testOneSwipeCoversASmallRequest() {
        XCTAssertFalse(ScrollProgress.shouldSwipeAgain(
            travelled: 435, requested: 78, swipes: 1, lastStep: 435
        ))
    }

    /// A request larger than one swipe is what `amount:` still buys on this
    /// path, since the step itself cannot be made bigger.
    func testALargeRequestKeepsSwiping() {
        XCTAssertTrue(ScrollProgress.shouldSwipeAgain(
            travelled: 435, requested: 1200, swipes: 1, lastStep: 435
        ))
    }

    /// A list at the end of its content answers every further swipe with
    /// nothing; without this the budget goes on rubber-banding.
    func testAStalledSwipeStopsTheLoop() {
        XCTAssertFalse(ScrollProgress.shouldSwipeAgain(
            travelled: 435, requested: 1200, swipes: 1, lastStep: 0
        ))
    }

    /// The same backstop the press-drag path has: a huge `amount:` in a short
    /// container must not turn into an unbounded run of gestures.
    func testTheSweepBudgetIsTheCeiling() {
        XCTAssertTrue(ScrollProgress.shouldSwipeAgain(
            travelled: 100, requested: 9999, swipes: ScrollGesture.maxSweeps - 1, lastStep: 100
        ))
        XCTAssertFalse(ScrollProgress.shouldSwipeAgain(
            travelled: 100, requested: 9999, swipes: ScrollGesture.maxSweeps, lastStep: 100
        ))
    }
}

/// Regression coverage for issue #1193: after #1192 spread a `scroll` over
/// several sweeps, the verb moved about 2.3x the travel it reported. Each
/// sweep is a separate press-and-drag carrying its own momentum, so n short
/// sweeps move considerably more content than one sweep of the same total
/// length — and the command still printed the number it was asked for. Every
/// recorded recipe that steps by default-amount scrolls therefore landed
/// somewhere else, failing on the *next* command rather than on the scroll.
///
/// The verb now measures each sweep against the element the caller named and
/// sizes the next one for what is left at that rate — closing the loop the
/// swipe fallback already closed, and whose doc comment already claimed the
/// contract for the whole verb ("reports what it measured rather than what it
/// planned").
final class ScrollFeedbackTests: XCTestCase {

    
    /// The reported measurement, as arithmetic. iPhone 26.5, Settings at the
    /// top: the default `dir:down` plans 437 points of finger travel across 3
    /// sweeps of 145.7, and the first one moves the form about 335 — a gain
    /// of roughly 2.3. Open-loop, sweeps 2 and 3 then take it to ~1005 while
    /// the verb prints 437. With feedback the second sweep is sized for the
    /// 102 points still owed at that rate, which is 44 of finger travel.
    func testASweepIsSizedForWhatIsLeftAtTheRateAlreadyMeasured() throws {
        let plan = ScrollGesture.plan(requestedTravel: 437, containerHeight: 874)
        let travel = try XCTUnwrap(ScrollFeedback.nextSweepTravel(
            requested: 437, measured: 335, dragged: plan.sweepTravel, cap: plan.sweepTravel
        ))
        XCTAssertEqual(travel, 44.3, accuracy: 1.0)
        XCTAssertLessThan(travel, plan.sweepTravel)
    }

    /// The first sweep has nothing to learn from, so it must be exactly what
    /// the plan says — the pre-#1193 geometry, unchanged. Anything else would
    /// be a silent behaviour change on the very first gesture.
    func testTheFirstSweepTakesThePlanUnchanged() {
        let plan = ScrollGesture.plan(requestedTravel: 437, containerHeight: 874)
        XCTAssertEqual(
            ScrollFeedback.nextSweepTravel(
                requested: 437, measured: 0, dragged: 0, cap: plan.sweepTravel
            ),
            plan.sweepTravel
        )
    }

    /// Once the request is covered there is nothing left to do — this is the
    /// clause that stops the overshoot, and the whole of #1193 in one line.
    func testAMetRequestAsksForNoFurtherSweep() {
        XCTAssertNil(ScrollFeedback.nextSweepTravel(
            requested: 437, measured: 437, dragged: 145.7, cap: 145.7
        ))
        XCTAssertNil(
            ScrollFeedback.nextSweepTravel(
                requested: 437, measured: 1005, dragged: 437, cap: 145.7
            ),
            "the open-loop outcome: three planned sweeps moved 2.3x the request"
        )
    }

    /// A remainder smaller than a gesture is worth is not worth a gesture.
    func testATinyRemainderIsNotWorthASweep() {
        XCTAssertNil(ScrollFeedback.nextSweepTravel(
            requested: 437, measured: 434, dragged: 145.7, cap: 145.7
        ))
    }

    /// The per-sweep ceiling is #1188's safety property and feedback may only
    /// lower it. A sweep that under-delivered would otherwise ask the next
    /// one to travel a multiple of the container and put an endpoint back on
    /// the chrome that dismissed an iPad sheet.
    func testFeedbackNeverRaisesThePerSweepCeiling() {
        let cap: CGFloat = 145.7
        XCTAssertEqual(
            ScrollFeedback.nextSweepTravel(
                requested: 1200, measured: 5, dragged: cap, cap: cap
            ),
            cap
        )
        XCTAssertEqual(
            ScrollFeedback.nextSweepTravel(
                requested: 1200, measured: 0, dragged: cap, cap: cap
            ),
            cap,
            "a sweep that moved nothing must not be read as infinite gain"
        )
    }

    /// Sweeping the whole plan is still right where the gesture under-delivers
    /// — the pre-#1192 platforms are not the only callers, and a gain below 1
    /// must spend the budget rather than give up early.
    func testAnUnderDeliveringSweepKeepsGoing() {
        let cap: CGFloat = 145.7
        let next = ScrollFeedback.nextSweepTravel(
            requested: 437, measured: 70, dragged: cap, cap: cap
        )
        XCTAssertEqual(next, cap, "still 367 points owed at a gain of 0.48")
    }
}
