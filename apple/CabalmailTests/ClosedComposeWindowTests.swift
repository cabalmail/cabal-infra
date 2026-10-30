import SwiftUI
import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A closed compose window keeps nothing to send once it has left the
/// screen or stayed on it past the linger (#2271), and leaves again when it
/// is brought back to the front (#2257).
@MainActor
final class ClosedComposeWindowTests: XCTestCase {
    private func closed(in phase: ScenePhase) -> ComposeSlotRegistry.ClosedCompose {
        var closed = ComposeSlotRegistry().closedCompose(for: Draft(subject: "Re: sent"))
        closed.closed(in: phase)
        return closed
    }

    func testAWindowClosedInFrontKeepsItsComposerOnItsWayOut() {
        var closed = closed(in: .active)

        XCTAssertFalse(closed.isSpent)
        XCTAssertFalse(closed.sceneMoved(from: .active, to: .inactive))
        XCTAssertFalse(closed.isSpent)
    }

    func testReachingTheBackgroundLeavesTheScreen() {
        var closed = closed(in: .active)

        XCTAssertFalse(closed.sceneMoved(from: .inactive, to: .background))
        XCTAssertTrue(closed.isSpent)
    }

    func testAWindowClosedOutOfViewHasAlreadyLeftTheScreen() {
        // Send finished after the user had moved to another window.
        XCTAssertTrue(closed(in: .background).isSpent)
    }

    func testAWindowBroughtBackFromTheBackgroundLeavesAgain() {
        var closed = closed(in: .background)

        XCTAssertFalse(closed.sceneMoved(from: .background, to: .inactive))
        XCTAssertTrue(closed.sceneMoved(from: .inactive, to: .active))
    }

    func testAWindowPickedAgainBeforeItReachedTheBackgroundLeavesAgain() {
        var closed = closed(in: .active)

        XCTAssertFalse(closed.sceneMoved(from: .active, to: .inactive))
        XCTAssertTrue(closed.sceneMoved(from: .inactive, to: .active))
        XCTAssertTrue(closed.isSpent)
    }

    func testAWindowStillOnScreenAfterTheLingerIsSpent() {
        // Split View on a phone: nothing covers the closed window (#2271).
        var closed = closed(in: .active)
        XCTAssertFalse(closed.isSpent, "it keeps its composer while it may still animate away")

        closed.lingered()

        XCTAssertTrue(closed.isSpent)
        XCTAssertTrue(closed.sceneMoved(from: .inactive, to: .active), "picked again, it still leaves")
    }

    func testTheRegistryRefusesTheComposerOnceTheWindowHasLeft() {
        let registry = ComposeSlotRegistry()
        let reply = Draft(subject: "Re: sent")
        var closed = registry.closedCompose(for: reply)
        closed.closed(in: .background)

        XCTAssertFalse(registry.mayCompose(reply, closedOn: closed))
    }
}
