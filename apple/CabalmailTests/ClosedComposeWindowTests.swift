import SwiftUI
import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A closed compose window keeps nothing to send once it has left the
/// screen, and leaves again when it is brought back to the front (#2257).
@MainActor
final class ClosedComposeWindowTests: XCTestCase {
    private func closed(in phase: ScenePhase) -> ComposeSlotRegistry.ClosedCompose {
        var closed = ComposeSlotRegistry().closedCompose(for: Draft(subject: "Re: sent"))
        closed.closed(in: phase)
        return closed
    }

    func testAWindowClosedInFrontKeepsItsComposerOnItsWayOut() {
        var closed = closed(in: .active)

        XCTAssertFalse(closed.hasLeftScreen)
        XCTAssertFalse(closed.sceneMoved(from: .active, to: .inactive))
        XCTAssertFalse(closed.hasLeftScreen)
    }

    func testReachingTheBackgroundLeavesTheScreen() {
        var closed = closed(in: .active)

        XCTAssertFalse(closed.sceneMoved(from: .inactive, to: .background))
        XCTAssertTrue(closed.hasLeftScreen)
    }

    func testAWindowClosedOutOfViewHasAlreadyLeftTheScreen() {
        // Send finished after the user had moved to another window.
        XCTAssertTrue(closed(in: .background).hasLeftScreen)
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
        XCTAssertTrue(closed.hasLeftScreen)
    }

    func testTheRegistryRefusesTheComposerOnceTheWindowHasLeft() {
        let registry = ComposeSlotRegistry()
        let reply = Draft(subject: "Re: sent")
        var closed = registry.closedCompose(for: reply)
        closed.closed(in: .background)

        XCTAssertFalse(registry.mayCompose(reply, closedOn: closed))
    }
}
