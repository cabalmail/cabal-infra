#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import CabalmailUI

/// A trackpad two-finger swipe revealed nothing on iPadOS 27's message list.
///
/// The 27 path draws each row's swipe with SwiftUI's own `.swipeActions`
/// inside `.swipeActionsContainer()` (#901), and on iPadOS that reveal is a
/// `DragGesture`: touches only. A trackpad swipe arrives as scroll input,
/// which only recognizers that opt into scroll types receive, and nothing on
/// the row did, so the list's own scroll view took it and dropped it.
/// `TrackpadSwipe.swift` puts a scroll-only pan on every row, driving a
/// `TrackpadSwipeTracker`.
///
/// Scroll input cannot be synthesized in-process, and SwiftUI attaches a
/// `UIGestureRecognizerRepresentable`'s recognizer to a view only once an
/// event arrives, so the pan cannot be found and driven here. What is pinned
/// instead: the recognizer takes trackpad input and nothing else (below),
/// the tracker does what a swipe should (`TrackpadSwipeTrackerTests`), and
/// the row installs both (`SwipeActionContainerSourceScanTests`, macOS
/// bundle). SimDrive's `pscroll` verb drives the real thing in a simulator.
@MainActor
final class TrackpadSwipeRecognizerTests: XCTestCase {

    /// Trackpad scrolling in, touches out: every touch stays with the native
    /// swipe, the row's button and the list's scrolling, and none of them is
    /// ever asked to wait for this one. A pan that takes touches would fight
    /// the native swipe; one without `.continuous` is the regression.
    func testRecognizerTakesTrackpadScrollingAndNoTouches() {
        let pan = TrackpadSwipeRecognizer.configuredRecognizer()
        XCTAssertEqual(pan.allowedTouchTypes, [])
        XCTAssertEqual(pan.allowedScrollTypesMask, .continuous)
    }

    /// The list's scroll view waits for the swipe to decide; nothing else does.
    func testOnlyAScrollViewsPanWaitsForTheSwipe() {
        let pan = TrackpadSwipeRecognizer.configuredRecognizer()
        let delegate = TrackpadSwipeRecognizer.Delegate()
        let scrollView = UIScrollView()
        let other = UIPanGestureRecognizer()
        UIView().addGestureRecognizer(other)

        XCTAssertTrue(delegate.gestureRecognizer(pan, shouldBeRequiredToFailBy: scrollView.panGestureRecognizer))
        XCTAssertFalse(delegate.gestureRecognizer(pan, shouldBeRequiredToFailBy: other))
    }
}

/// What a trackpad swipe does to a row, phase by phase, as the recognizer
/// hands it over.
@MainActor
final class TrackpadSwipeTrackerTests: XCTestCase {

    /// Which actions ran, in order.
    private final class Fired {
        var actions: [String] = []
    }

    private let fired = Fired()

    /// A 360pt row whose capsules settle at 96pt.
    private func row(leading: Bool = true, trailing: Bool = true) -> TrackpadSwipeTracker.Row {
        let fired = fired
        return TrackpadSwipeTracker.Row(
            leading: leading
                ? SwipeActionSpec(systemImage: "envelope.open", title: "Read", tint: .blue) {
                    fired.actions.append("leading")
                }
                : nil,
            trailing: trailing
                ? SwipeActionSpec(systemImage: "archivebox", title: "Archive", tint: .red) {
                    fired.actions.append("trailing")
                }
                : nil,
            width: 360,
            leadingReveal: 96,
            trailingReveal: 96
        )
    }

    /// One swipe: began, a change on the way, ended where the fingers lifted.
    private func swipe(
        _ tracker: TrackpadSwipeTracker,
        by distance: CGFloat,
        velocity: CGFloat = 0,
        row: TrackpadSwipeTracker.Row? = nil,
        coordinator: TrackpadSwipeCoordinator? = nil
    ) {
        let row = row ?? self.row()
        tracker.began(coordinator: coordinator)
        tracker.changed(translation: distance / 2, row: row)
        tracker.ended(translation: distance, velocity: velocity, row: row, coordinator: coordinator)
    }

    func testALongSwipeTowardTheLeadingEdgeRunsTheTrailingAction() {
        let tracker = TrackpadSwipeTracker()
        swipe(tracker, by: -400)
        XCTAssertEqual(fired.actions, ["trailing"])
        XCTAssertEqual(tracker.offset, 0, "the row comes back as the action runs")
    }

    func testALongSwipeTowardTheTrailingEdgeRunsTheLeadingAction() {
        let tracker = TrackpadSwipeTracker()
        swipe(tracker, by: 400)
        XCTAssertEqual(fired.actions, ["leading"])
    }

    /// A short swipe reveals and waits: nothing runs until the capsule is
    /// clicked.
    func testAShortSwipeRevealsAndRunsNothingUntilClicked() {
        let tracker = TrackpadSwipeTracker()
        let row = row()
        swipe(tracker, by: -60, row: row)
        XCTAssertEqual(tracker.offset, -96, "settles at the trailing capsule's width")
        XCTAssertEqual(fired.actions, [])

        tracker.run(row.trailing, coordinator: nil)

        XCTAssertEqual(fired.actions, ["trailing"])
        XCTAssertEqual(tracker.offset, 0)
    }

    func testATinySwipeSettlesBackToRest() {
        let tracker = TrackpadSwipeTracker()
        swipe(tracker, by: -30)
        XCTAssertEqual(tracker.offset, 0)
        XCTAssertEqual(fired.actions, [])
    }

    /// A row with no action on an edge does not move that way at all.
    func testSwipingTowardAMissingActionDoesNothing() {
        let tracker = TrackpadSwipeTracker()
        swipe(tracker, by: 400, row: row(leading: false))
        XCTAssertEqual(tracker.offset, 0)
        XCTAssertEqual(fired.actions, [], "no leading action to run")
    }

    func testASwipeOnAnOpenRevealContinuesFromIt() {
        let tracker = TrackpadSwipeTracker()
        let row = row()
        swipe(tracker, by: -60, row: row)
        tracker.began(coordinator: nil)
        tracker.changed(translation: 30, row: row)
        XCTAssertEqual(tracker.offset, -66)
    }

    /// One reveal at a time: a second row's swipe retracts the first.
    func testAnotherRowsSwipeRetractsTheReveal() {
        let coordinator = TrackpadSwipeCoordinator()
        let first = TrackpadSwipeTracker()
        let second = TrackpadSwipeTracker()
        swipe(first, by: -60, coordinator: coordinator)
        XCTAssertEqual(first.offset, -96, "precondition")

        second.began(coordinator: coordinator)
        first.ownerChanged(to: coordinator.owner)

        XCTAssertEqual(first.offset, 0)
    }

    /// A swipe's own claim, and a claim made while its fingers are still
    /// down, leave it alone.
    func testATrackingRowIsNotRetractedUnderItsFingers() {
        let coordinator = TrackpadSwipeCoordinator()
        let tracker = TrackpadSwipeTracker()
        tracker.began(coordinator: coordinator)
        tracker.changed(translation: -60, row: row())

        tracker.ownerChanged(to: coordinator.owner)
        tracker.ownerChanged(to: UUID())

        XCTAssertEqual(tracker.offset, -60)
    }

    /// A scroll or a click elsewhere retracts everything.
    func testClosingAllRetractsTheReveal() {
        let coordinator = TrackpadSwipeCoordinator()
        let tracker = TrackpadSwipeTracker()
        swipe(tracker, by: -60, coordinator: coordinator)

        coordinator.closeAll()
        tracker.ownerChanged(to: coordinator.owner)

        XCTAssertEqual(tracker.offset, 0)
    }

    /// The row was re-pointed at another message: the reveal goes, and the
    /// coordinator no longer counts the row as open.
    func testRepointingTheRowDropsTheReveal() {
        let coordinator = TrackpadSwipeCoordinator()
        let tracker = TrackpadSwipeTracker()
        swipe(tracker, by: -60, coordinator: coordinator)

        tracker.reset(coordinator: coordinator)

        XCTAssertEqual(tracker.offset, 0)
        XCTAssertNil(coordinator.owner)
    }

    /// Settings > Actions took the revealed edge away.
    func testLosingTheRevealedEdgeRetractsIt() {
        let tracker = TrackpadSwipeTracker()
        swipe(tracker, by: 60)
        XCTAssertEqual(tracker.offset, 96, "precondition")

        tracker.edgesChanged(row: row(leading: false), coordinator: nil)

        XCTAssertEqual(tracker.offset, 0)
    }
}

/// The rules the recognizer's handlers apply, without a view.
final class TrackpadSwipePolicyTests: XCTestCase {

    func testHorizontalMovementBeginsASwipe() {
        XCTAssertTrue(TrackpadSwipePolicy.beginsSwipe(translation: CGSize(width: -20, height: 3), velocity: .zero))
        XCTAssertFalse(TrackpadSwipePolicy.beginsSwipe(translation: CGSize(width: 3, height: -20), velocity: .zero))
    }

    /// UIKit can ask before any translation accrues; the velocity decides then.
    func testVelocityDecidesBeforeAnyTranslation() {
        XCTAssertTrue(TrackpadSwipePolicy.beginsSwipe(translation: .zero, velocity: CGSize(width: 900, height: 40)))
        XCTAssertFalse(TrackpadSwipePolicy.beginsSwipe(translation: .zero, velocity: CGSize(width: 40, height: 900)))
    }

    func testTrackingFollowsTheFingersFromWhereTheSwipeStarted() {
        XCTAssertEqual(offset(from: 0, by: 70), 70)
        XCTAssertEqual(offset(from: -96, by: 30), -66, "a swipe on an open reveal continues from it")
    }

    func testTrackingStaysAtRestOnASideWithNoAction() {
        XCTAssertEqual(offset(from: 0, by: 70, leading: false), 0)
        XCTAssertEqual(offset(from: 0, by: -70, trailing: false), 0)
    }

    func testTrackingNeverPassesTheRowsWidth() {
        XCTAssertEqual(offset(from: 0, by: 900), 360)
        XCTAssertEqual(offset(from: 0, by: -900), -360)
    }

    /// The container's own measured threshold, capped for a narrow column.
    func testRunDistance() {
        XCTAssertEqual(TrackpadSwipePolicy.runDistance(rowWidth: 834), 300)
        XCTAssertEqual(TrackpadSwipePolicy.runDistance(rowWidth: 360), 270)
    }

    func testLiftingPastHalfTheRevealOpensIt() {
        XCTAssertEqual(outcome(offset: 60), .open(.leading))
        XCTAssertEqual(outcome(offset: -60), .open(.trailing))
    }

    func testLiftingShortOfHalfTheRevealCloses() {
        XCTAssertEqual(outcome(offset: 40), .closed)
        XCTAssertEqual(outcome(offset: -40), .closed)
    }

    func testAFlickSettlesTheWayItWasGoing() {
        XCTAssertEqual(outcome(offset: 20, velocity: 900), .open(.leading), "a flick open opens")
        XCTAssertEqual(outcome(offset: -80, velocity: 900), .closed, "a flick back closes")
    }

    func testLiftingPastTheRunDistanceRunsTheAction() {
        XCTAssertEqual(outcome(offset: 280), .run(.leading))
        XCTAssertEqual(outcome(offset: -280), .run(.trailing))
    }

    func testRestIsClosed() {
        XCTAssertEqual(outcome(offset: 0, velocity: 900), .closed)
    }

    private func offset(
        from start: CGFloat,
        by translation: CGFloat,
        leading: Bool = true,
        trailing: Bool = true
    ) -> CGFloat {
        TrackpadSwipePolicy.trackedOffset(
            from: start,
            translation: translation,
            hasLeading: leading,
            hasTrailing: trailing,
            rowWidth: 360
        )
    }

    /// A 96pt reveal (an 80pt capsule and its insets) in a 360pt row.
    private func outcome(offset: CGFloat, velocity: CGFloat = 0) -> TrackpadSwipeOutcome {
        TrackpadSwipePolicy.outcome(offset: offset, velocity: velocity, revealOffset: 96, rowWidth: 360)
    }
}

/// One reveal at a time.
@MainActor
final class TrackpadSwipeCoordinatorTests: XCTestCase {

    func testClaimingMovesOwnershipAndClosesTheOther() {
        let coordinator = TrackpadSwipeCoordinator()
        let first = UUID()
        let second = UUID()

        coordinator.claim(first)
        coordinator.claim(second)

        XCTAssertEqual(coordinator.owner, second)
    }

    func testReleasingSomeoneElsesRevealChangesNothing() {
        let coordinator = TrackpadSwipeCoordinator()
        let first = UUID()
        coordinator.claim(first)

        coordinator.release(UUID())

        XCTAssertEqual(coordinator.owner, first)
    }

    func testClosingAllClearsTheOwner() {
        let coordinator = TrackpadSwipeCoordinator()
        coordinator.claim(UUID())

        coordinator.closeAll()

        XCTAssertNil(coordinator.owner)
    }
}
#endif
