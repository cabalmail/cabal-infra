#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import CabalmailUI

/// A finger's swipe on a message row revealed nothing on the touchscreen
/// MacBook Pro, while feed rows (plain `List` rows) swiped under a finger.
///
/// The 27 path draws each row's swipe with SwiftUI's own `.swipeActions`
/// inside `.swipeActionsContainer()` (#901), and on macOS that reveal answers
/// the trackpad's scroll events and nothing else, and nothing on the row
/// took a finger. The rows now draw a reveal of their own on macOS
/// as they already did on iPadOS for the trackpad (`TrackpadSwipe.swift`),
/// driven by a pan recognizer that takes a finger and nothing else, beside
/// the list's touch scrolling, and reads each touch's axis off its movement.
///
/// A direct touch cannot be made in-process, so the recognizer cannot be
/// driven here. What is pinned: it takes a finger only, runs beside every
/// other gesture, and vetoes no touch before it moves; the axis rule; the Mac
/// draws the reveal at all; the tracker settles a swipe on macOS as on
/// iPadOS, retracts a cancelled one, and tolerates a repeated `began` and an
/// `ended` that none opened (left from an earlier, stateless input, and
/// harmless).
/// `SwipeActionContainerSourceScanTests` pins the row's wiring.
@MainActor
final class TouchRowSwipeTests: XCTestCase {

    // MARK: - The input

    /// A finger in; mouse and trackpad clicks out, so a click on the row, a
    /// drag onto a folder, and the container's trackpad swipe are untouched.
    func testTheRecognizerTakesAFingerAndLeavesThePointerAlone() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("the touch recognizer is macOS 27 and later") }
        let pan = TrackpadSwipeRecognizer.configuredRecognizer()
        XCTAssertEqual(pan.allowedTouchTypes, .direct)
        XCTAssertEqual(pan.buttonMask, 0)
    }

    /// Beside the list's touch scrolling, never in its way: a SwiftUI drag on
    /// the rows kept a finger from scrolling the mail list on the device,
    /// even attached beside it.
    func testTheRecognizerRunsBesideEveryOtherGesture() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("the touch recognizer is macOS 27 and later") }
        let pan = TrackpadSwipeRecognizer.configuredRecognizer()
        let touch = TrackpadSwipeRecognizer.Touch()
        let scrolling = NSPanGestureRecognizer()
        NSScrollView().addGestureRecognizer(scrolling)
        XCTAssertTrue(touch.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: scrolling))
    }

    /// The recognizer begins on any movement, so nothing may veto a touch at
    /// touch-down: the first version's delegate did, before the finger had
    /// moved, and a finger never revealed anything.
    func testNothingRefusesATouchBeforeItMoves() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("the touch recognizer is macOS 27 and later") }
        let touch = TrackpadSwipeRecognizer.Touch()
        XCTAssertFalse(touch.responds(to: #selector(NSGestureRecognizerDelegate.gestureRecognizerShouldBegin(_:))),
                       "a shouldBegin veto is back; asked at touch-down it refuses every touch")
    }

    // MARK: - A touch's axis

    /// Undecided while short, then sideways is a swipe and anything else a
    /// scroll, for the rest of the touch.
    func testATouchsAxisIsReadOffItsMovement() {
        XCTAssertNil(TrackpadSwipePolicy.touchAxis(translation: CGSize(width: 5, height: -4)))
        XCTAssertEqual(TrackpadSwipePolicy.touchAxis(translation: CGSize(width: -30, height: 9)), .swipe)
        XCTAssertEqual(TrackpadSwipePolicy.touchAxis(translation: CGSize(width: 18, height: -197)), .scroll)
        XCTAssertEqual(TrackpadSwipePolicy.touchAxis(translation: CGSize(width: 10, height: 10)), .scroll,
                       "a diagonal is the list's: only a clearly sideways touch swipes")
    }

    // MARK: - The tracker's tolerance

    /// The Mac's drag reports `began` with every change that reads as a
    /// swipe; only the first starts it, so the swipe tracks from where the
    /// row was, not from wherever it had got to.
    func testARepeatedBeganKeepsTheSwipesStart() {
        let row = row()
        let tracker = TrackpadSwipeTracker()
        tracker.began(coordinator: nil)
        tracker.changed(translation: -40, row: row)
        tracker.began(coordinator: nil)
        tracker.changed(translation: -60, row: row)
        XCTAssertEqual(tracker.offset, -60, "a second began restarted the swipe from where it had got to")
    }

    /// A drag that ends without ever reading as a swipe (a vertical scroll
    /// over an open row) leaves the row alone.
    func testAnEndWithoutABeganLeavesTheRowAlone() {
        let row = row()
        let tracker = TrackpadSwipeTracker()
        tracker.began(coordinator: nil)
        tracker.ended(translation: -70, velocity: 0, row: row, coordinator: nil)
        XCTAssertEqual(tracker.offset, -row.trailingReveal)

        // A flick back that would close it, were the end taken as a swipe's.
        tracker.ended(translation: 0, velocity: 900, row: row, coordinator: nil)
        XCTAssertEqual(tracker.offset, -row.trailingReveal, "an ended no began opened moved the open reveal")
    }

    /// A drag SwiftUI cancels mid-swipe reports no end; its cancel retracts
    /// the row, so the next swipe on it starts. On the device a cancelled
    /// drag left the row tracking, deaf to its next swipe.
    func testACancelMidSwipeRetractsTheRowAndFreesIt() {
        let row = row()
        let tracker = TrackpadSwipeTracker()
        tracker.began(coordinator: nil)
        tracker.changed(translation: -50, row: row)
        tracker.cancel(coordinator: nil)
        XCTAssertEqual(tracker.offset, 0)
        XCTAssertNil(tracker.trackingFrom, "the cancelled swipe left the row tracking")

        tracker.began(coordinator: nil)
        tracker.changed(translation: -30, row: row)
        XCTAssertEqual(tracker.offset, -30, "the next swipe didn't start")
    }

    /// The Mac's input reports a cancel after every drag, clean ends too; a
    /// reveal a clean end left open stays open.
    func testACancelAfterACleanEndLeavesTheRevealOpen() {
        let row = row()
        let tracker = TrackpadSwipeTracker()
        tracker.began(coordinator: nil)
        tracker.ended(translation: -70, velocity: 0, row: row, coordinator: nil)
        tracker.cancel(coordinator: nil)
        XCTAssertEqual(tracker.offset, -row.trailingReveal, "a clean end's reveal was retracted")
    }

    // MARK: - Where the reveal is drawn

    /// iPadOS draws it for the trackpad and macOS for a finger; visionOS has
    /// neither input. Before this the Mac drew none.
    func testTheMacDrawsARowSwipeRevealOfItsOwn() {
        XCTAssertTrue(HostPlatform.current.drawsRowSwipeReveal, "the Mac rows draw no reveal for a finger")
        XCTAssertTrue(HostPlatform.macOS.drawsRowSwipeReveal)
        XCTAssertTrue(HostPlatform.iOS.drawsRowSwipeReveal)
        XCTAssertFalse(HostPlatform.visionOS.drawsRowSwipeReveal)
        XCTAssertFalse(HostPlatform.watchOS.drawsRowSwipeReveal)
    }

    // MARK: - The tracker, on macOS

    private func row() -> TrackpadSwipeTracker.Row {
        let spec = SwipeActionSpec(systemImage: "archivebox", title: "Archive", tint: .green) {}
        return TrackpadSwipeTracker.Row(
            leading: spec, trailing: spec, width: 400,
            leadingReveal: TrackpadSwipePolicy.revealOffset(capsuleWidth: 80),
            trailingReveal: TrackpadSwipePolicy.revealOffset(capsuleWidth: 80)
        )
    }

    /// A finger dragged past half the capsule and lifted leaves the trailing
    /// action revealed; a short one closes; a long one runs it and closes.
    func testASwipeSettlesTheWayItDoesOnIPadOS() {
        let row = row()
        let coordinator = TrackpadSwipeCoordinator()

        let reveals = TrackpadSwipeTracker()
        reveals.began(coordinator: coordinator)
        reveals.ended(translation: -70, velocity: 0, row: row, coordinator: coordinator)
        XCTAssertEqual(reveals.offset, -row.trailingReveal)
        XCTAssertEqual(coordinator.owner, reveals.token)

        let closes = TrackpadSwipeTracker()
        closes.began(coordinator: coordinator)
        closes.ended(translation: -20, velocity: 0, row: row, coordinator: coordinator)
        XCTAssertEqual(closes.offset, 0)
        XCTAssertNotEqual(coordinator.owner, reveals.token, "a second row's swipe leaves the first open")
    }
}
#endif
