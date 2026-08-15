import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #1078: saving a draft the user had opened
// from the Drafts list dropped the edit that was just saved.
//
// Save Draft on a resumed copy is a `/save_draft` *replace*: it expunges
// the copy it replaces and lands the new content under a fresh UID. Nothing
// told the list, and — the harmful half — nothing told the reader the
// dismissal returns to, which kept rendering the retired copy's fetched
// body. Edit Draft from that reader re-seeded the pre-edit content and
// pinned the send's discard to a UID the server no longer had, so the send
// shipped the stale text and left the saved copy behind as an orphan.
//
// The compose model now reports the replace chain on a save (the Save Draft
// counterpart to `supersededDraftUIDs`, which only covers a send), and
// `DraftReplacementPolicy` decides what the list does with the copy it is
// showing.
@MainActor
final class DraftReplacementTests: XCTestCase {

    // MARK: - What the compose session reports

    /// Resume UID 625, save: the replace retires 625 and the survivor is the
    /// ref `/save_draft` handed back.
    func testSaveOverAResumedDraftReportsTheChainAndTheSurvivor() throws {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = DraftServerRef(uid: 625, uidValidity: 9)

        model.adoptServerDraftRef(DraftServerRef(uid: 626, uidValidity: 9))

        XCTAssertEqual(
            model.savedDraftReplacement,
            DraftReplacement(retiredUIDs: [625], survivingUID: 626)
        )
    }

    /// A long-lived compose can autosave several times before the user
    /// saves; the list may be rendering any copy in the chain, so all of
    /// them are named (the lesson of #1071, applied to the save path).
    func testEveryReplacedCopyInTheChainIsReported() throws {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = DraftServerRef(uid: 100, uidValidity: 9)

        for uid: UInt32 in [101, 102, 103] {
            model.adoptServerDraftRef(DraftServerRef(uid: uid, uidValidity: 9))
        }

        XCTAssertEqual(
            model.savedDraftReplacement,
            DraftReplacement(retiredUIDs: [100, 101, 102], survivingUID: 103)
        )
    }

    /// A first save has no predecessor to retire, so there is no stale row
    /// or stale reader anywhere and nothing to signal.
    func testFirstSaveOfANewDraftReportsNothing() throws {
        let model = try TestFixtures.makeComposeModel()

        model.adoptServerDraftRef(DraftServerRef(uid: 700, uidValidity: 9))

        XCTAssertNil(model.savedDraftReplacement)
    }

    /// A send reports through `supersededDraftUIDs` and its own dispose
    /// signal; reporting a replacement too would have the list re-point at a
    /// survivor `/send` already discarded.
    func testASendReportsNoReplacement() throws {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = DraftServerRef(uid: 625, uidValidity: 9)
        model.adoptServerDraftRef(DraftServerRef(uid: 626, uidValidity: 9))

        model.lastSendOutcome = .sent

        XCTAssertNil(model.savedDraftReplacement)
        XCTAssertEqual(model.supersededDraftUIDs, [625, 626])
    }

    // MARK: - What the list does with it

    private let chain = DraftReplacement(retiredUIDs: [623, 624, 625], survivingUID: 626)

    /// The reported failure: the reader is on a retired copy and the
    /// survivor is loaded, so it swaps rather than sitting on expunged
    /// content. Swept across the whole chain — the list may have loaded any
    /// copy in it, and every one of them is equally stale.
    func testAnyRetiredCopyOnScreenRepointsToTheSurvivor() {
        for retired in chain.retiredUIDs {
            XCTAssertEqual(
                DraftReplacementPolicy.resolve(
                    displayedUID: retired,
                    replacement: chain,
                    loadedUIDs: [610, 626]
                ),
                .repoint(626),
                "displayed UID \(retired) should re-point at the survivor"
            )
        }
    }

    /// The refresh didn't reach the survivor, so there is nothing to point
    /// at. Letting the reader go still beats leaving it on a copy the server
    /// expunged — that is the state Edit Draft reads from.
    func testARetiredCopyWithNoSurvivorLoadedDismisses() {
        XCTAssertEqual(
            DraftReplacementPolicy.resolve(
                displayedUID: 624,
                replacement: chain,
                loadedUIDs: [610, 611]
            ),
            .dismiss
        )
    }

    /// Already looking at the survivor (a save from a reader the list had
    /// re-pointed once already): nothing is stale, so nothing moves.
    func testTheSurvivorOnScreenIsLeftAlone() {
        XCTAssertEqual(
            DraftReplacementPolicy.resolve(
                displayedUID: 626,
                replacement: chain,
                loadedUIDs: [626]
            ),
            .ignore
        )
    }

    /// Someone else's message, or no reader at all — a compose window saving
    /// in the background must not yank the selection out from under the
    /// user. Guard cases: passing before and after the fix, and deliberately
    /// so.
    func testAnUnrelatedOrAbsentSelectionIsLeftAlone() {
        XCTAssertEqual(
            DraftReplacementPolicy.resolve(
                displayedUID: 610,
                replacement: chain,
                loadedUIDs: [610, 626]
            ),
            .ignore
        )
        XCTAssertEqual(
            DraftReplacementPolicy.resolve(
                displayedUID: nil,
                replacement: chain,
                loadedUIDs: [610, 626]
            ),
            .ignore
        )
    }
}
