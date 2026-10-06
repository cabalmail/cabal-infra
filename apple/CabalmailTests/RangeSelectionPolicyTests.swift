import XCTest
import CabalmailKit
@testable import CabalmailUI

// #1768: a shift-click after command-clicking replaced the whole selection
// with the range, discarding every row picked with command outside it. The
// platform (Finder, Mail, any NSTableView) unions the span onto what was
// already there, so the rule now lives in RangeSelectionPolicy and both the
// pointer and keyboard paths go through it.
//
// Two layers are covered: the pure rule, over the arms the issue measured,
// and the model-level pairing of `selectionAnchor` with the base it was
// pinned over -- which is where the defect actually lived, since the span
// itself was always computed correctly.
@MainActor
final class RangeSelectionPolicyTests: XCTestCase {

    /// The issue's own list, newest first: 367 above 369, then 316, 313, 312.
    private let ordered: [UInt32] = [367, 369, 316, 313, 312]

    // MARK: - The rule

    func testRangeIsUnionedOntoWhatTheAnchorWasPinnedOver() {
        // Issue arm 1: click 367, command-click 369, shift-click 312.
        let armOne = RangeSelectionPolicy.outcome(
            base: [367, 369], anchor: 369, target: 312, ordered: ordered
        )
        XCTAssertEqual(
            armOne.selected, [367, 369, 316, 313, 312],
            "367 was picked with command outside the span and must survive it"
        )
        XCTAssertNil(armOne.newAnchor, "a resolved anchor stays put")

        // Issue arm 2: click 367, command-click 369, command-click 313,
        // shift-click 312.
        let armTwo = RangeSelectionPolicy.outcome(
            base: [367, 369, 313], anchor: 313, target: 312, ordered: ordered
        )
        XCTAssertEqual(armTwo.selected, [367, 369, 313, 312])
    }

    func testPlainClickThenShiftClickSelectsTheRangeAlone() {
        // The base is the single plainly-clicked row, which is also the
        // anchor, so the union adds nothing: the pre-#1768 answer, preserved.
        let outcome = RangeSelectionPolicy.outcome(
            base: [369], anchor: 369, target: 313, ordered: ordered
        )
        XCTAssertEqual(outcome.selected, [369, 316, 313])
    }

    func testASecondShiftClickReplacesTheFirstSpanRatherThanAccumulating() {
        // Same anchor and base; the span moves. 312 was only ever in the
        // first span, so it goes -- what the anchor was pinned over does not.
        let first = RangeSelectionPolicy.outcome(
            base: [367, 369, 313], anchor: 313, target: 312, ordered: ordered
        )
        XCTAssertEqual(first.selected, [367, 369, 313, 312])
        let second = RangeSelectionPolicy.outcome(
            base: [367, 369, 313], anchor: 313, target: 316, ordered: ordered
        )
        XCTAssertEqual(second.selected, [367, 369, 316, 313])
        XCTAssertFalse(second.selected.contains(312))
    }

    func testRangeIsDirectionAgnostic() {
        let down = RangeSelectionPolicy.outcome(
            base: [], anchor: 369, target: 313, ordered: ordered
        )
        let upward = RangeSelectionPolicy.outcome(
            base: [], anchor: 313, target: 369, ordered: ordered
        )
        XCTAssertEqual(down.selected, [369, 316, 313])
        XCTAssertEqual(upward.selected, down.selected)
    }

    func testAnUnresolvableAnchorFallsBackToTheTargetAndRepinsThere() {
        for anchor: UInt32? in [nil, 9999] {
            let outcome = RangeSelectionPolicy.outcome(
                base: [367, 369], anchor: anchor, target: 313, ordered: ordered
            )
            XCTAssertEqual(
                outcome.selected, [313],
                "nothing to extend from, so the base must not leak into the answer"
            )
            XCTAssertEqual(outcome.newAnchor, 313)
        }
    }

    func testATargetOutsideTheVisibleRunAlsoFallsBack() {
        let outcome = RangeSelectionPolicy.outcome(
            base: [367], anchor: 367, target: 9999, ordered: ordered
        )
        XCTAssertEqual(outcome.selected, [9999])
        XCTAssertEqual(outcome.newAnchor, 9999)
    }

    // MARK: - The pairing, on the model

    /// `setSelectionAnchor` is the only way to move the anchor (the property
    /// is `private(set)`), and it snapshots the live selection -- so a base
    /// can never be left over from an earlier anchor.
    func testPinningTheAnchorSnapshotsTheSelectionAtThatMoment() throws {
        let model = try makeModel()
        model.selectedRefs = [ref(367)]
        model.setSelectionAnchor(ref(367))
        XCTAssertEqual(model.selectionRangeBase, [ref(367)])

        // Command-click 369: toggle first, then pin, which is the order
        // `applyToggleSelection` uses.
        model.toggleSelection(try envelope(369, in: model))
        model.setSelectionAnchor(ref(369))
        XCTAssertEqual(model.selectionAnchor, ref(369))
        XCTAssertEqual(model.selectionRangeBase, [ref(367), ref(369)])

        // Command-click 369 again, dropping it: the base follows the drop,
        // so a shift-click cannot resurrect it.
        model.toggleSelection(try envelope(369, in: model))
        model.setSelectionAnchor(ref(369))
        XCTAssertEqual(model.selectionRangeBase, [ref(367)])

        // And it is a snapshot, not a mirror: a selection change with no new
        // pin -- which is every range operation -- leaves the base alone.
        model.selectedRefs = [ref(367), ref(316), ref(313)]
        XCTAssertEqual(
            model.selectionRangeBase, [ref(367)],
            "a range operation must not fold its own span into the base"
        )
    }

    /// The reported sequence, driven through the model the way
    /// `applyToggleSelection` / `applyRangeSelection` drive it.
    func testTheReportedSequenceKeepsTheCommandClickedRows() throws {
        let model = try makeModel()

        // 1. Click 367.
        model.selectedRefs = [ref(367)]
        model.setSelectionAnchor(ref(367))
        // 2. Command-click 369.
        model.toggleSelection(try envelope(369, in: model))
        model.setSelectionAnchor(ref(369))
        // 3. Command-click 313.
        model.toggleSelection(try envelope(313, in: model))
        model.setSelectionAnchor(ref(313))
        XCTAssertEqual(model.selectedRefs, [ref(367), ref(369), ref(313)], "the healthy 3-selected state")

        // 4. Shift-click 312.
        let outcome = RangeSelectionPolicy.outcome(
            base: model.selectionRangeBase,
            anchor: model.selectionAnchor ?? model.selectedRefs.first,
            target: ref(312),
            ordered: model.envelopes.map { model.rowRef(for: $0) }
        )
        model.selectedRefs = outcome.selected
        XCTAssertEqual(
            model.selectedRefs, [ref(367), ref(369), ref(313), ref(312)],
            "the range joins the selection; 367 and 369 are not dropped (#1768)"
        )
        XCTAssertEqual(model.selectionAnchor, ref(313), "the anchor still pivots the next span")
    }

    /// Shift+Down after a command-click: the keyboard path shares the rule,
    /// so it keeps the command-picked rows too.
    func testShiftArrowKeepsTheCommandClickedRows() throws {
        let model = try makeModel()
        model.selectedRefs = [ref(367)]
        model.setSelectionAnchor(ref(367))
        model.toggleSelection(try envelope(369, in: model))
        model.setSelectionAnchor(ref(369))

        // Shift+Down from the cursor at 369 lands on 316.
        let outcome = RangeSelectionPolicy.outcome(
            base: model.selectionRangeBase,
            anchor: model.selectionAnchor,
            target: ref(316),
            ordered: model.envelopes.map { model.rowRef(for: $0) }
        )
        XCTAssertEqual(outcome.selected, [ref(367), ref(369), ref(316)])
    }

    /// The guard rail for extending from the *base* rather than from the live
    /// selection: unioning onto what is currently selected would accumulate
    /// spans, so a shift-click that shrinks or re-aims the range could never
    /// give a row back. The anchor is unmoved between the two clicks, so the
    /// second span replaces the first.
    func testASecondShiftClickOnTheModelGivesTheFirstSpanBack() throws {
        let model = try makeModel()
        model.selectedRefs = [ref(367)]
        model.setSelectionAnchor(ref(367))
        model.toggleSelection(try envelope(369, in: model))
        model.setSelectionAnchor(ref(369))

        let shiftClick: (UInt32) -> Set<MessageRef> = { target in
            RangeSelectionPolicy.outcome(
                base: model.selectionRangeBase,
                anchor: model.selectionAnchor,
                target: self.ref(target),
                ordered: model.envelopes.map { model.rowRef(for: $0) }
            ).selected
        }

        model.selectedRefs = shiftClick(312)
        XCTAssertEqual(model.selectedRefs, [ref(367), ref(369), ref(316), ref(313), ref(312)])
        // Same anchor, a shorter span: 316, 313 and 312 are the first span's
        // and must go, while 367 -- command-picked -- stays.
        model.selectedRefs = shiftClick(369)
        XCTAssertEqual(model.selectedRefs, [ref(367), ref(369)])
    }

    func testClearingTheSelectionClearsTheBaseToo() throws {
        let model = try makeModel()
        model.selectedRefs = [ref(367), ref(369)]
        model.setSelectionAnchor(ref(369))
        model.selectedRefs.removeAll()
        model.setSelectionAnchor(nil)
        XCTAssertNil(model.selectionAnchor)
        XCTAssertTrue(model.selectionRangeBase.isEmpty, "Esc must not leave a base behind")
    }

    // MARK: - Fixture

    private func makeModel() throws -> MessageListViewModel {
        try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: ordered.map { TestFixtures.makeEnvelope(uid: $0) }
        )
    }

    private func envelope(_ uid: UInt32, in model: MessageListViewModel) throws -> Envelope {
        try XCTUnwrap(model.envelopes.first { $0.uid == uid })
    }

    /// The ref of row `uid` in INBOX, the folder `makeModel()` lists.
    private func ref(_ uid: UInt32) -> MessageRef {
        MessageRef(folder: "INBOX", uid: uid)
    }
}
