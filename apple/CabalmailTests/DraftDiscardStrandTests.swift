import XCTest
import CabalmailKit
@testable import Cabalmail

// Regression coverage for issue #1081: discarding a draft that had been
// resumed out of the Drafts reader left the row, the reader and — the
// harmful part — a live Edit Draft behind.
//
// The discard expunges the server copy, but `ComposeView.perform` signalled
// on only two of its three exits: Send (#1071) and Cancel -> Save Draft
// (#1078). Discard published nothing, so the list kept its row and the
// reader kept rendering the thrown-away draft; Edit Draft on it reopened
// the whole message with Send enabled, and the verification run confirmed
// it delivers. Drafts is unsubscribed, so nothing refreshed the state away
// until the user left the folder and came back.
//
// The empty-body cancel (`ComposeCancelPolicy.discardEmpty`) drops the
// server copy the same way through a different button, so it is swept here
// too rather than left as the next report.
@MainActor
final class DraftDiscardStrandTests: XCTestCase {

    // MARK: - What the compose session reports

    /// The reported failure at the model layer: a resumed draft that has
    /// autosaved a few times, then discarded. Every copy the session ever
    /// held is retired — the list may be rendering any of them (#1071) —
    /// and nothing survives, because that is what discarding means.
    func testDiscardingAResumedDraftRetiresTheWholeChainWithNoSurvivor() throws {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = DraftServerRef(uid: 639, uidValidity: 9)
        for uid: UInt32 in [640, 641] {
            model.adoptServerDraftRef(DraftServerRef(uid: uid, uidValidity: 9))
        }

        model.recordServerDraftDiscard(true)

        XCTAssertEqual(
            model.retiredDraftReplacement,
            DraftReplacement(retiredUIDs: [639, 640, 641], survivingUID: nil)
        )
    }

    /// The repro's own shape: resume, discard, no autosave in between. One
    /// UID, and it is the one the reader is showing.
    func testDiscardingAnUntouchedResumedDraftRetiresThatOneCopy() throws {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = DraftServerRef(uid: 639, uidValidity: 9)

        model.recordServerDraftDiscard(true)

        XCTAssertEqual(
            model.retiredDraftReplacement,
            DraftReplacement(retiredUIDs: [639], survivingUID: nil)
        )
    }

    /// `discardDraft` returns false when the UIDVALIDITY guard declines:
    /// the copy is gone under those coordinates either way, so the row on
    /// screen is just as stale and still has to go.
    func testADeclinedDiscardStillRetiresTheRow() throws {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = DraftServerRef(uid: 639, uidValidity: 9)

        model.recordServerDraftDiscard(false)

        XCTAssertEqual(
            model.retiredDraftReplacement,
            DraftReplacement(retiredUIDs: [639], survivingUID: nil)
        )
    }

    /// A discard whose request threw says nothing about the server, so the
    /// copy it aimed at is reported as surviving, not retired: nothing is
    /// pruned and no reader moves (an empty chain resolves to `.ignore`), so
    /// the row this session could not vouch for settles on the refresh the
    /// signal triggers instead of on the next 30 s status poll.
    ///
    /// Before #1083 widened the channel to carry arrivals this reported nil
    /// — the same outcome by a different route, since the only thing the
    /// signal could have done back then was prune. The rule that mattered
    /// then still holds now: a thrown discard never prunes.
    func testADiscardThatNeverReachedTheServerPrunesNothing() throws {
        let model = try TestFixtures.makeComposeModel()
        model.serverDraftRef = DraftServerRef(uid: 639, uidValidity: 9)

        model.recordServerDraftDiscard(nil)

        XCTAssertEqual(
            model.retiredDraftReplacement,
            DraftReplacement(retiredUIDs: [], survivingUID: 639)
        )
        XCTAssertEqual(
            DraftReplacementPolicy.resolve(
                displayedUID: 639,
                replacement: try XCTUnwrap(model.retiredDraftReplacement),
                loadedUIDs: [639]
            ),
            .ignore,
            "the reader on the copy a failed discard aimed at must stay put"
        )
    }

    /// Discarding a compose that never reached the server (no ref, no
    /// chain) leaves nothing anywhere to prune.
    func testDiscardingADraftWithNoServerCopyReportsNothing() throws {
        let model = try TestFixtures.makeComposeModel()

        model.recordServerDraftDiscard(true)

        XCTAssertNil(model.retiredDraftReplacement)
    }

    // MARK: - The rule, independent of a model

    /// Save and discard differ in exactly one thing: whether the current
    /// ref survives. Swept over a chain rather than a case each, because a
    /// session can retire any number of copies before either exit.
    func testTheRetirementRuleKeepsTheRefOnSaveAndRetiresItOnDiscard() {
        let replaced: [UInt32] = [100, 101]
        XCTAssertEqual(
            DraftReplacementPolicy.retirement(
                discarded: false,
                replacedUIDs: replaced,
                currentUID: 102
            ),
            DraftReplacement(retiredUIDs: [100, 101], survivingUID: 102)
        )
        XCTAssertEqual(
            DraftReplacementPolicy.retirement(
                discarded: true,
                replacedUIDs: replaced,
                currentUID: 102
            ),
            DraftReplacement(retiredUIDs: [100, 101, 102], survivingUID: nil)
        )
    }

    /// A first save retires nothing, but it still reports: the copy it
    /// created is missing from a list already showing Drafts, and that list
    /// otherwise waits out the 30 s status poll (#1083). Reported with an
    /// empty chain, which is what keeps it from yanking anybody's selection
    /// — see `testAFirstSaveLeavesEveryReaderAlone` below.
    ///
    /// This case used to assert nil (#1081, when the channel only carried
    /// retirements); #1083 is the human accepting the arrival half.
    func testAFirstSaveReportsTheNewCopyWithNothingRetired() {
        XCTAssertEqual(
            DraftReplacementPolicy.retirement(
                discarded: false,
                replacedUIDs: [],
                currentUID: 700
            ),
            DraftReplacement(retiredUIDs: [], survivingUID: 700)
        )
    }

    /// A save-shaped session that never reached the server has no survivor
    /// and nothing retired, and stays silent — an empty compose opened and
    /// closed must not make an open list refresh.
    func testASaveThatNeverReachedTheServerReportsNothing() {
        XCTAssertNil(
            DraftReplacementPolicy.retirement(
                discarded: false,
                replacedUIDs: [],
                currentUID: nil
            )
        )
    }

    // MARK: - What the list does with it

    private let discarded = DraftReplacement(retiredUIDs: [639, 640, 641], survivingUID: nil)

    /// The heart of the fix: whichever copy in the chain the reader is on,
    /// there is nothing to point it at, so it goes. Leaving it is what let
    /// Edit Draft resurrect a discarded draft and send it.
    func testAnyDiscardedCopyOnScreenDismissesTheReader() {
        for retired in discarded.retiredUIDs {
            XCTAssertEqual(
                DraftReplacementPolicy.resolve(
                    displayedUID: retired,
                    replacement: discarded,
                    loadedUIDs: [610, 639, 640, 641]
                ),
                .dismiss,
                "displayed UID \(retired) should drop the reader"
            )
        }
    }

    /// Someone else's message, or no reader at all: a compose discarding in
    /// the background must not clear the user's selection. Guard case,
    /// passing before and after.
    func testAnUnrelatedOrAbsentSelectionSurvivesADiscard() {
        XCTAssertEqual(
            DraftReplacementPolicy.resolve(
                displayedUID: 610,
                replacement: discarded,
                loadedUIDs: [610, 639]
            ),
            .ignore
        )
        XCTAssertEqual(
            DraftReplacementPolicy.resolve(
                displayedUID: nil,
                replacement: discarded,
                loadedUIDs: [610, 639]
            ),
            .ignore
        )
    }
}
