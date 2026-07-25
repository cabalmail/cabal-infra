import XCTest
import CabalmailKit
@testable import Cabalmail

// The swipe-to-dispose row animation: a disposed row fades at full height,
// then collapses to zero, and only then leaves `envelopes`. The timing is
// load-bearing rather than decorative — an instant removal in the index-
// addressed list isn't even a row removal (every slot below just re-points at
// the next envelope), so with no transition the eye reads it as "nothing
// happened" and the user swipes again on whatever slid into place.
@MainActor
final class RowDisposalTests: XCTestCase {

    func testDisposalFadesAtFullHeightBeforeCollapsing() async throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 1)]
        )

        let started = ContinuousClock.now
        let disposal = model.beginRowDisposal(uid: 1)
        XCTAssertEqual(
            model.rowDisposalPhases[1], .fading,
            "the fade starts immediately, at full height, so nothing shifts yet"
        )
        await disposal.value
        XCTAssertEqual(model.rowDisposalPhases[1], .collapsing)
        // Both legs are sleeps, so this is a guaranteed lower bound: the point
        // of the animation is that it takes long enough to be perceived.
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(300))
    }

    func testCancelledDisposalNeverReachesTheCollapse() async throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 1)]
        )

        let disposal = model.beginRowDisposal(uid: 1)
        disposal.cancel()
        await disposal.value

        XCTAssertEqual(
            model.rowDisposalPhases[1], .fading,
            "a cancellation mid-fade (failed write, row coming back) must not fall through to the collapse"
        )
    }

    func testDisposeRemovesTheRowOnlyAfterTheAnimation() async throws {
        let imap = FakeImapClient()
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )

        let disposeTask = Task { await model.dispose(model.envelopes[0]) }
        // Yield until the move has gone out — it's issued before the animation
        // is awaited, so the wire call must not be held up by the 300ms.
        while await imap.moveCalls.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(
            model.envelopes.map(\.uid), [1, 2],
            "the row stays in place (and every row index stays stable) while it animates out"
        )
        XCTAssertNotNil(model.rowDisposalPhases[1])

        await disposeTask.value

        XCTAssertEqual(model.envelopes.map(\.uid), [2])
        XCTAssertTrue(model.rowDisposalPhases.isEmpty)
        let moves = await imap.moveCalls
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.uids, [1])
    }

    func testFailedDisposeLeavesTheRowInPlace() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )

        await model.dispose(model.envelopes[0])

        // The revert is just dropping the phase: the envelope never left, so
        // there's no reinsertion to get the ordering wrong.
        XCTAssertEqual(model.envelopes.map(\.uid), [1, 2])
        XCTAssertTrue(model.rowDisposalPhases.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }
}
