import XCTest
import Observation
import CabalmailKit
@testable import CabalmailUI

/// A draft on its way from a compose sheet to a window of its own
/// (`ComposeHandoffs`): expected at the tap, its snapshot sent once the sheet
/// has read it, and then the window opened for it claims it, or the sheet's
/// deadline passes, or the window declines it, and whichever comes first is
/// the outcome. A window that comes after the sheet took its draft back
/// finds the hand-off gone, so the draft is never in two composers.
@MainActor
final class ComposeHandoffsTests: XCTestCase {
    /// A deadline the test never reaches. Bounded, so a broken table fails
    /// on the timing assertions below rather than hanging the run.
    private static let farDeadline: @MainActor (Duration) async -> Void = { _ in
        try? await Task.sleep(for: .seconds(30))
    }

    private func snapshot(subject: String = "moving") -> ComposeSnapshot {
        ComposeSnapshot(
            seed: Draft(subject: subject),
            preferences: Preferences(store: InMemoryPreferenceStore())
        )
    }

    func testClaimBeforeTheWaitIsClaimed() async throws {
        let handoffs = ComposeHandoffs(sleep: Self.farDeadline)
        let offered = snapshot()
        TestFixtures.offer(offered, on: handoffs)
        let claim = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        XCTAssertEqual(claim.snapshot?.subject, "moving", "the window builds its composer from this")

        claim.sceneIsActive = true
        let claimed = await claim.claim()
        let outcome = await handoffs.outcome(for: offered.draftID)

        XCTAssertTrue(claimed)
        XCTAssertEqual(outcome, .claimed)
        XCTAssertNil(claim.snapshot, "a claimed hand-off keeps no copy of the draft")
    }

    /// No window in time: the sheet keeps its draft, and the window that
    /// turns up afterwards cannot take it too.
    func testTimeoutRefusesAndALateClaimFails() async throws {
        let handoffs = ComposeHandoffs(sleep: { _ in })
        let offered = snapshot()
        TestFixtures.offer(offered, on: handoffs)

        let outcome = await handoffs.outcome(for: offered.draftID)
        XCTAssertEqual(outcome, .refused)

        let late = try XCTUnwrap(
            handoffs.pending(for: offered.draftID),
            "a withdrawn hand-off is kept, so a late window closes rather than composing from nothing"
        )
        XCTAssertNil(late.snapshot)
        late.sceneIsActive = true
        let claimed = await late.claim()
        XCTAssertFalse(claimed)
    }

    /// A window that could not hold the draft hands it back now, not at the
    /// deadline.
    func testDeclineRefusesAtOnce() async throws {
        let handoffs = ComposeHandoffs(sleep: Self.farDeadline)
        let offered = snapshot()
        TestFixtures.offer(offered, on: handoffs)
        let claim = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        let started = ContinuousClock.now
        let waiting = Task { await handoffs.outcome(for: offered.draftID) }
        await Task.yield()

        claim.decline()
        let outcome = await waiting.value

        XCTAssertEqual(outcome, .refused)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the sheet waited out its deadline anyway")
        claim.sceneIsActive = true
        let claimedAfterwards = await claim.claim()
        XCTAssertFalse(claimedAfterwards)
    }

    /// Two composers built for the same window (SwiftUI keeps a closed one
    /// mounted, #1084) each hold a claim on the one hand-off, and only the
    /// first claim takes it.
    func testOnlyOneClaimWins() async throws {
        let handoffs = ComposeHandoffs(sleep: Self.farDeadline)
        let offered = snapshot()
        TestFixtures.offer(offered, on: handoffs)
        let first = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        let second = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        XCTAssertFalse(first === second, "each composer holds a claim of its own")
        first.sceneIsActive = true
        second.sceneIsActive = true

        let firstClaimed = await first.claim()
        let secondClaimed = await second.claim()

        XCTAssertTrue(firstClaimed)
        XCTAssertFalse(secondClaimed)
        let outcome = await handoffs.outcome(for: offered.draftID)
        XCTAssertEqual(outcome, .claimed)
    }

    /// The composer in front claims, though the one behind asked first and
    /// says it is behind after the other said it is in front: whether a
    /// window is in front is each composer's own, so the draft never lands
    /// where nobody can see it, nor waits on a window that is not the one
    /// in front.
    func testOnlyTheComposerInFrontClaims() async throws {
        let handoffs = ComposeHandoffs(sleep: Self.farDeadline)
        let offered = snapshot()
        TestFixtures.offer(offered, on: handoffs)
        let behind = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        let inFront = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        let behindClaiming = Task { await behind.claim() }
        await Task.yield()

        inFront.sceneIsActive = true
        behind.sceneIsActive = false
        // Room for the composer behind to run, were it woken to claim.
        try await Task.sleep(for: .milliseconds(100))
        let inFrontClaimed = await inFront.claim()
        let behindClaimed = await behindClaiming.value

        XCTAssertTrue(inFrontClaimed)
        XCTAssertFalse(behindClaimed)
        XCTAssertTrue(inFront.hasClaimed)
        XCTAssertFalse(behind.hasClaimed)
    }

    // MARK: Expected, then sent

    /// The window opens before the sheet has read its draft. Until the
    /// snapshot comes there is nothing to claim, and a composer that tried
    /// would take a draft it does not have; once it comes, the window's
    /// composer starts from it and claims.
    func testAnExpectedHandoffIsClaimedOnlyOnceItsSnapshotHasCome() async throws {
        let handoffs = ComposeHandoffs(sleep: Self.farDeadline)
        let offered = snapshot()
        handoffs.expect(offered.draftID, within: ComposeWindowMove.deadline)
        XCTAssertTrue(handoffs.awaitsSnapshot(for: offered.draftID), "the window would build a composer from nothing")
        let early = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        XCTAssertNil(early.snapshot)
        early.sceneIsActive = true
        let claimedEarly = await early.claim()
        XCTAssertFalse(claimedEarly, "claimed before the sheet had sent the draft")

        XCTAssertTrue(handoffs.fulfil(offered))
        XCTAssertFalse(handoffs.awaitsSnapshot(for: offered.draftID))
        let claim = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        XCTAssertEqual(claim.snapshot?.subject, "moving")
        claim.sceneIsActive = true
        let claimed = await claim.claim()
        let outcome = await handoffs.outcome(for: offered.draftID)

        XCTAssertTrue(claimed)
        XCTAssertEqual(outcome, .claimed)
    }

    /// The deadline runs from the tap, not from the snapshot: one read after
    /// it reaches no window, and the window finds the hand-off gone rather
    /// than waiting on for a draft that is not coming.
    func testTheDeadlineRunsFromTheExpectation() async throws {
        var asked: [Duration] = []
        let handoffs = ComposeHandoffs(sleep: { asked.append($0) })
        let offered = snapshot()
        handoffs.expect(offered.draftID, within: ComposeWindowMove.deadline)

        let outcome = await handoffs.outcome(for: offered.draftID)

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(asked, [ComposeWindowMove.deadline])
        XCTAssertFalse(handoffs.fulfil(offered), "a snapshot read after the deadline reached the window")
        XCTAssertFalse(handoffs.awaitsSnapshot(for: offered.draftID))
        let late = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        XCTAssertNil(late.snapshot)
    }

    /// The sheet could not read its draft: it takes the hand-off back
    /// before sending anything. The sheet's wait ends, the window stops
    /// waiting and finds the hand-off gone, and nothing sent afterwards
    /// reaches it.
    func testAHandoffWithdrawnBeforeItsSnapshotStaysWithdrawn() async throws {
        let handoffs = ComposeHandoffs(sleep: Self.farDeadline)
        let offered = snapshot()
        handoffs.expect(offered.draftID, within: ComposeWindowMove.deadline)
        let waiting = Task { await handoffs.outcome(for: offered.draftID) }
        await Task.yield()

        handoffs.withdraw(offered.draftID)
        let outcome = await waiting.value

        XCTAssertEqual(outcome, .refused)
        XCTAssertFalse(handoffs.awaitsSnapshot(for: offered.draftID))
        XCTAssertFalse(handoffs.fulfil(offered))
        let late = try XCTUnwrap(handoffs.pending(for: offered.draftID))
        XCTAssertNil(late.snapshot)
        late.sceneIsActive = true
        let claimed = await late.claim()
        XCTAssertFalse(claimed)
    }

    /// The compose window reads `awaitsSnapshot` in its body, so the
    /// snapshot's arrival, and the hand-off's end without one, have to reach
    /// it as a change, or it would show its placeholder for good.
    func testTheWaitForTheSnapshotIsObservable() async throws {
        let handoffs = ComposeHandoffs(sleep: Self.farDeadline)
        let arriving = snapshot()
        handoffs.expect(arriving.draftID, within: ComposeWindowMove.deadline)
        let arrived = expectation(description: "the snapshot's arrival reached the window")
        withObservationTracking {
            _ = handoffs.awaitsSnapshot(for: arriving.draftID)
        } onChange: {
            arrived.fulfill()
        }
        handoffs.fulfil(arriving)
        await fulfillment(of: [arrived], timeout: 1)

        let kept = snapshot()
        handoffs.expect(kept.draftID, within: ComposeWindowMove.deadline)
        let ended = expectation(description: "the hand-off's end reached the window")
        withObservationTracking {
            _ = handoffs.awaitsSnapshot(for: kept.draftID)
        } onChange: {
            ended.fulfill()
        }
        handoffs.withdraw(kept.draftID)
        await fulfillment(of: [ended], timeout: 1)
    }
}
