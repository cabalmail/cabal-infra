import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a wide layout's reading pane reads from the list's selected rows
/// (`ReadingPaneSelectionPolicy`, #2032). Its own file rather than more of
/// `BulkSelectionTests`, which is at SwiftLint's `type_body_length` ceiling.
@MainActor
final class ReadingPaneSelectionPolicyTests: XCTestCase {

    /// A checkbox and a plain wide click write the same `selectedRefs`, so
    /// deriving the pane from the set alone opened the checked message and
    /// the on-open rule marked it read. Select mode shows no message.
    func testACheckedBoxInSelectModeOpensNoMessage() throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )
        model.toggleBulkMode()
        model.toggleSelection(model.envelopes[0])
        XCTAssertEqual(model.selectedRefs, [ref(1)], "the box is checked")
        XCTAssertNil(
            ReadingPaneSelectionPolicy.shown(selectedRefs: model.selectedRefs, bulkMode: model.bulkMode),
            "one checked box must not open its message"
        )
    }

    /// The report's variant: check two, then uncheck one. The remaining box
    /// used to open its message on the way back down to one.
    func testUncheckingDownToOneBoxOpensNoMessage() throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )
        model.toggleBulkMode()
        model.toggleSelection(model.envelopes[0])
        model.toggleSelection(model.envelopes[1])
        model.toggleSelection(model.envelopes[0])
        XCTAssertEqual(model.selectedRefs, [ref(2)])
        XCTAssertNil(
            ReadingPaneSelectionPolicy.shown(selectedRefs: model.selectedRefs, bulkMode: model.bulkMode)
        )
    }

    /// The rule Select mode must not break: outside it, one selected row is
    /// the pane's message, which is how a click reads a message on a wide
    /// layout.
    func testOneSelectedRowOutsideSelectModeIsThePanesMessage() throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )
        model.toggleSelection(model.envelopes[0])
        XCTAssertFalse(model.bulkMode)
        XCTAssertEqual(
            ReadingPaneSelectionPolicy.shown(selectedRefs: model.selectedRefs, bulkMode: model.bulkMode),
            ref(1)
        )
    }

    func testNoRowAndManyRowsOpenNoMessageEitherWay() {
        for bulkMode in [true, false] {
            XCTAssertNil(ReadingPaneSelectionPolicy.shown(selectedRefs: [], bulkMode: bulkMode))
            XCTAssertNil(
                ReadingPaneSelectionPolicy.shown(selectedRefs: [ref(1), ref(2)], bulkMode: bulkMode)
            )
        }
    }

    // MARK: - Re-opening the row that is already selected (#2033, #2034)

    /// The reported defect, driven through the real model: a tap selects the
    /// row and the pane shows it, the pane is then emptied under the list (a
    /// pushed reader popped, or a layout swap dropped it), and the next tap
    /// on that same row assigns an equal set. The pane has to be written by
    /// the tap, or nothing happens at all.
    func testTappingTheSelectedRowWithAnEmptyPaneReopensIt() throws {
        let model = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 1), TestFixtures.makeEnvelope(uid: 2)]
        )
        model.selectedRefs = [model.rowRef(for: model.envelopes[0])]
        XCTAssertEqual(
            ReadingPaneSelectionPolicy.shown(selectedRefs: model.selectedRefs, bulkMode: model.bulkMode),
            ref(1),
            "the pane showed it while the reader was up"
        )
        XCTAssertTrue(
            ReadingPaneSelectionPolicy.reopens(
                selectedRefs: model.selectedRefs,
                tapped: ref(1),
                paneShowing: nil,
                bulkMode: model.bulkMode
            ),
            "the set cannot change, so the tap re-opens the row itself"
        )
    }

    /// The pane showing a different row than the selection names is the same
    /// divergence the other way round, so a tap still has to write it.
    func testTappingTheSelectedRowWhileThePaneShowsAnotherReopensIt() {
        XCTAssertTrue(
            ReadingPaneSelectionPolicy.reopens(
                selectedRefs: [ref(1)], tapped: ref(1), paneShowing: ref(2), bulkMode: false
            )
        )
    }

    /// Negative control: with the pane already on that row there is nothing
    /// to re-open, so a re-tap on the open message writes nothing.
    func testTappingTheRowThePaneAlreadyShowsIsNotAReopen() {
        XCTAssertFalse(
            ReadingPaneSelectionPolicy.reopens(
                selectedRefs: [ref(1)], tapped: ref(1), paneShowing: ref(1), bulkMode: false
            )
        )
    }

    /// Negative control: a tap that really changes the set is the
    /// derivation's own job (`wideList`'s `.onChange`), from one row and from
    /// a multi-selection alike. Writing the pane here too would read a row
    /// the set has not yet agreed on.
    func testATapThatChangesTheSetLeavesThePaneToTheDerivation() {
        XCTAssertFalse(
            ReadingPaneSelectionPolicy.reopens(
                selectedRefs: [ref(2)], tapped: ref(1), paneShowing: nil, bulkMode: false
            ),
            "another row was selected"
        )
        XCTAssertFalse(
            ReadingPaneSelectionPolicy.reopens(
                selectedRefs: [ref(1), ref(2)], tapped: ref(1), paneShowing: nil, bulkMode: false
            ),
            "a multi-selection collapses to one row"
        )
        XCTAssertFalse(
            ReadingPaneSelectionPolicy.reopens(
                selectedRefs: [], tapped: ref(1), paneShowing: nil, bulkMode: false
            ),
            "nothing was selected"
        )
    }

    /// Select mode's rule (#2032) holds through the new one: a tap on a
    /// checked row must not open it however the pane and the set stand.
    func testSelectModeNeverReopensOnATap() {
        for pane in [nil, ref(1), ref(2)] as [MessageRef?] {
            XCTAssertFalse(
                ReadingPaneSelectionPolicy.reopens(
                    selectedRefs: [ref(1)], tapped: ref(1), paneShowing: pane, bulkMode: true
                )
            )
        }
    }

    /// The ref of row `uid` in INBOX, the folder every model here is over.
    private func ref(_ uid: UInt32) -> MessageRef {
        MessageRef(folder: "INBOX", uid: uid)
    }
}
