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

    /// The ref of row `uid` in INBOX, the folder every model here is over.
    private func ref(_ uid: UInt32) -> MessageRef {
        MessageRef(folder: "INBOX", uid: uid)
    }
}
