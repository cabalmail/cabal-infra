#if os(macOS)
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
/// driven by a SwiftUI drag that takes a finger and nothing else.
///
/// A direct touch cannot be made in-process, so the drag cannot be driven
/// here. What is pinned: the drag takes a finger only, the Mac draws the
/// reveal at all, the tracker settles a swipe on macOS as on iPadOS, and the
/// tracker tolerates a drag that keeps no state (a repeated `began`, an
/// `ended` that none opened).
/// `SwipeActionContainerSourceScanTests` pins the row's wiring.
@MainActor
final class TouchRowSwipeTests: XCTestCase {

    // MARK: - The input

    /// A finger and nothing else: a mouse, a trackpad click-drag, the row's
    /// drag onto a folder and the container's trackpad swipe stay out of it.
    func testTheDragTakesAFingerAndNothingElse() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("input kinds are macOS 27 and later") }
        XCTAssertEqual(TrackpadSwipeRecognizer.inputKinds, .directTouch)
    }

    // MARK: - A drag that keeps no state

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
