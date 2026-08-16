import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #837: sending a draft from inside the app
// left the row sitting in the Drafts list for 60–80s. `/send` discards the
// server copy as part of delivery, but nothing told the open list, so it
// waited on a slow background reconcile (Drafts is unsubscribed, so it
// isn't proactively refreshed). The compose surface now prunes the row
// through the same `signalDisposed` path the reader's dispose actions use,
// driven by `supersededDraftUIDs`.
//
// And for issue #1071: once the 60s server autosave had replaced the copy,
// that report named only the *surviving* UID, which the list had never
// loaded — the pre-autosave row stayed on screen and could be opened and
// re-sent, delivering a duplicate. The report now covers the whole chain.
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

        XCTAssertEqual(model.supersededDraftUIDs, [42])
    }

    func testQueuedSendKeepsItsDraft() throws {
        // Nothing has been delivered yet and the server copy is deliberately
        // left in place, so pruning the row would hide a real message.
        let model = try makeModel(draftUID: 42)

        model.lastSendOutcome = .queued(UUID())

        XCTAssertTrue(model.supersededDraftUIDs.isEmpty)
    }

    func testFreshComposeHasNoDraftRowToPrune() throws {
        let model = try makeModel(draftUID: nil)

        model.lastSendOutcome = .sent

        XCTAssertTrue(model.supersededDraftUIDs.isEmpty)
    }

    func testUnsentComposeReportsNothing() throws {
        let model = try makeModel(draftUID: 42)

        XCTAssertNil(model.lastSendOutcome)
        XCTAssertTrue(model.supersededDraftUIDs.isEmpty)
    }

    // MARK: - #1071: the autosave chain

    func testAutosaveReplacementStillReportsTheRowTheListLoaded() throws {
        // The reported sequence: Drafts shows uid 604, the composer sits
        // open past the 60s autosave, and the server copy becomes 605. The
        // list never hears about the swap, so 604 is the row on screen and
        // has to be named for it to disappear.
        let model = try makeModel(draftUID: 604)

        model.adoptServerDraftRef(DraftServerRef(uid: 605, uidValidity: 9))
        model.lastSendOutcome = .sent

        XCTAssertEqual(model.supersededDraftUIDs, [604, 605])
    }

    func testEveryAutosaveGenerationIsReported() throws {
        // Sitting in the composer long enough autosaves repeatedly; the
        // rendered row can be several generations stale.
        let model = try makeModel(draftUID: 606)

        model.adoptServerDraftRef(DraftServerRef(uid: 607, uidValidity: 9))
        model.adoptServerDraftRef(DraftServerRef(uid: 608, uidValidity: 9))
        model.lastSendOutcome = .sent

        XCTAssertEqual(model.supersededDraftUIDs, [606, 607, 608])
    }

    func testAReplaceThatKeptItsUIDIsNotReportedTwice() throws {
        // `/save_draft` answering with the same UID replaced nothing; the
        // list has one row, and naming it twice would double the total
        // adjustment `pruneEnvelope` applies.
        let model = try makeModel(draftUID: 604)

        model.adoptServerDraftRef(DraftServerRef(uid: 604, uidValidity: 9))
        model.lastSendOutcome = .sent

        XCTAssertEqual(model.supersededDraftUIDs, [604])
    }

    func testAutosaveOfAnUnsavedComposeReportsOnlyTheNewUID() throws {
        // A fresh compose has no server copy until the first autosave, so
        // there's no predecessor to prune.
        let model = try makeModel(draftUID: nil)

        model.adoptServerDraftRef(DraftServerRef(uid: 700, uidValidity: 9))
        model.lastSendOutcome = .sent

        XCTAssertEqual(model.supersededDraftUIDs, [700])
    }
}
