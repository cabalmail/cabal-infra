import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #837: sending a draft from inside the app
// left the row sitting in the Drafts list for 60–80s. `/send` discards the
// server copy as part of delivery, but nothing told the open list, so it
// waited on a slow background reconcile (Drafts is unsubscribed, so it
// isn't proactively refreshed). The compose surface now prunes the row
// through the same `signalDisposed` path the reader's dispose actions use,
// driven by `supersededDraftUID`.
@MainActor
final class DraftPruneOnSendTests: XCTestCase {

    private func makeModel(draftUID: UInt32?) throws -> ComposeViewModel {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = draftUID.map { DraftServerRef(uid: $0, uidValidity: 9) }
        return model
    }

    func testCompletedSendReportsTheSupersededDraftRow() throws {
        let model = try makeModel(draftUID: 42)

        model.lastSendOutcome = .sent

        XCTAssertEqual(model.supersededDraftUID, 42)
    }

    func testQueuedSendKeepsItsDraft() throws {
        // Nothing has been delivered yet and the server copy is deliberately
        // left in place, so pruning the row would hide a real message.
        let model = try makeModel(draftUID: 42)

        model.lastSendOutcome = .queued(UUID())

        XCTAssertNil(model.supersededDraftUID)
    }

    func testFreshComposeHasNoDraftRowToPrune() throws {
        let model = try makeModel(draftUID: nil)

        model.lastSendOutcome = .sent

        XCTAssertNil(model.supersededDraftUID)
    }

    func testUnsentComposeReportsNothing() throws {
        let model = try makeModel(draftUID: 42)

        XCTAssertNil(model.lastSendOutcome)
        XCTAssertNil(model.supersededDraftUID)
    }
}
