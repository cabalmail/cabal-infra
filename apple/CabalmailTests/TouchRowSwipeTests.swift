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
/// the trackpad's scroll events and nothing else. AppKit hands a direct touch
/// only to gesture recognizers, and nothing on the row had one. The rows now
/// draw a reveal of their own on macOS as they already did on iPadOS for the
/// trackpad (`TrackpadSwipe.swift`), driven by a pan that takes a finger and
/// nothing else.
///
/// A direct touch cannot be made in-process, and SwiftUI attaches an
/// `NSGestureRecognizerRepresentable`'s recognizer only once an event
/// arrives, so the pan cannot be found and driven here. What is pinned: the
/// recognizer takes a finger and leaves the pointer alone, the scroll view
/// waits for it, the Mac draws the reveal at all, and the tracker the reveal
/// runs on settles a swipe on macOS as it does on iPadOS.
/// `SwipeActionContainerSourceScanTests` pins the row's wiring.
@MainActor
final class TouchRowSwipeTests: XCTestCase {

    // MARK: - The recognizer

    /// A finger in; mouse and trackpad clicks out, so a click on the row, a
    /// drag onto a folder, and the container's trackpad swipe are untouched.
    /// A pan left at the default button mask would start on a mouse drag and
    /// swallow the row's drag; one that took indirect touches would fight the
    /// container for the trackpad.
    func testRecognizerTakesAFingerAndLeavesThePointerAlone() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the recognizer bridge is macOS 26 and later") }
        let pan = TrackpadSwipeRecognizer.configuredRecognizer()
        XCTAssertEqual(pan.allowedTouchTypes, .direct)
        XCTAssertEqual(pan.buttonMask, 0)
    }

    /// The list's scroll view waits for the swipe to decide; nothing else does.
    func testOnlyTheScrollViewWaitsForTheSwipe() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("the recognizer bridge is macOS 26 and later") }
        let pan = TrackpadSwipeRecognizer.configuredRecognizer()
        let delegate = TrackpadSwipeRecognizer.Delegate()
        let scrolling = NSPanGestureRecognizer()
        NSScrollView().addGestureRecognizer(scrolling)
        let other = NSPanGestureRecognizer()
        NSView().addGestureRecognizer(other)

        XCTAssertTrue(delegate.gestureRecognizer(pan, shouldBeRequiredToFailBy: scrolling))
        XCTAssertFalse(delegate.gestureRecognizer(pan, shouldBeRequiredToFailBy: other))
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
