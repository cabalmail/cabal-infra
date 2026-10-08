import XCTest
import CabalmailKit
@testable import CabalmailUI

// Whose selection a reader or composer change moves (#1845, items 1 and 2):
// with two windows open, archiving or marking read with "then go to" moved
// the selection in every window, because the signal named no window. The
// rule is now `MailEventSelectionPolicy`, which each list's view applies.
@MainActor
final class MailEventSelectionPolicyTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()
    private let open = MessageRef(folder: "INBOX", uid: 5)
    private let next = MessageRef(folder: "INBOX", uid: 4)
    private let other = MessageRef(folder: "INBOX", uid: 9)

    private func removal(_ rows: Set<MessageRef>, target: MessageRef?, origin: UUID?) -> ListSelectionReaction {
        ListSelectionReaction(kind: .removal, rows: rows, target: target, origin: origin)
    }

    private func readAdvance(target: MessageRef?, origin: UUID?) -> ListSelectionReaction {
        ListSelectionReaction(kind: .readAdvance, rows: [open], target: target, origin: origin)
    }

    private func answer(_ reaction: ListSelectionReaction, current: Set<MessageRef>, in window: UUID?)
        -> Set<MessageRef>? {
        MailEventSelectionPolicy.selection(after: reaction, current: current, in: window)
    }

    // MARK: - Removal

    func testTheWindowThatArchivedAdvances() {
        XCTAssertEqual(answer(removal([open], target: next, origin: windowA), current: [open], in: windowA), [next])
    }

    func testAnotherWindowOnTheRowLetsGoOfItWithoutAdvancing() {
        XCTAssertEqual(answer(removal([open], target: next, origin: windowA), current: [open], in: windowB), [])
    }

    func testASelectionOffTheRowNeverMoves() {
        for window in [windowA, windowB] {
            XCTAssertNil(answer(removal([open], target: next, origin: windowA), current: [other], in: window))
            XCTAssertNil(answer(removal([open], target: next, origin: windowA), current: [], in: window))
        }
    }

    func testARemovalWithNoNextRowClearsTheOriginsSelection() {
        XCTAssertEqual(answer(removal([open], target: nil, origin: windowA), current: [open], in: windowA), [])
    }

    /// A send from a compose window names none: every window whose selection
    /// is on the row advances, as before.
    func testARemovalNoWindowStartedAdvancesEveryWindowOnTheRow() {
        let reaction = removal([open], target: next, origin: nil)
        XCTAssertEqual(answer(reaction, current: [open], in: windowA), [next])
        XCTAssertEqual(answer(reaction, current: [open], in: windowB), [next])
        XCTAssertNil(answer(reaction, current: [other], in: windowB))
    }

    /// A change another list made (a swipe, a bulk archive) advances no one:
    /// that list saw to its own selection, and every other list, in any
    /// window, lets go of the row. Its reactions name no window, so without
    /// `advances` they would read as a compose window's and advance them all.
    func testARemovalAnotherListMadeAdvancesNoOne() {
        let reaction = ListSelectionReaction(kind: .removal, rows: [open], target: next, origin: nil, advances: false)
        for window in [windowA, windowB, nil] {
            XCTAssertEqual(answer(reaction, current: [open], in: window), [])
            XCTAssertEqual(answer(reaction, current: [open, other], in: window), [other])
            XCTAssertNil(answer(reaction, current: [other], in: window))
        }
    }

    /// Only a selection wholly on the leaving rows is the reader's message;
    /// a larger one just loses the rows that went.
    func testAMultiSelectionLosesTheRemovedRowsWithoutAdvancing() {
        let reaction = removal([open], target: next, origin: windowA)
        XCTAssertEqual(answer(reaction, current: [open, other], in: windowA), [other])
        XCTAssertEqual(answer(reaction, current: [open, other], in: windowB), [other])
    }

    /// A send from Drafts can name several copies of one draft.
    func testASelectionOnAnyOfTheRemovedRowsAdvances() {
        let copy = MessageRef(folder: "Drafts", uid: 605)
        let stale = MessageRef(folder: "Drafts", uid: 604)
        let reaction = removal([copy, stale], target: next, origin: nil)
        XCTAssertEqual(answer(reaction, current: [stale], in: windowA), [next])
        XCTAssertEqual(answer(reaction, current: [copy], in: windowA), [next])
    }

    // MARK: - Read advance

    func testReadAdvanceMovesOnlyTheWindowThatAsked() {
        let reaction = readAdvance(target: next, origin: windowA)
        XCTAssertEqual(answer(reaction, current: [open], in: windowA), [next])
        XCTAssertNil(answer(reaction, current: [open], in: windowB), "another window's reader stays on the message")
    }

    func testReadAdvanceWithNoTargetStaysPut() {
        XCTAssertNil(answer(readAdvance(target: nil, origin: windowA), current: [open], in: windowA))
    }

    func testReadAdvanceLeavesASelectionOffTheRowAlone() {
        XCTAssertNil(answer(readAdvance(target: next, origin: windowA), current: [other], in: windowA))
        XCTAssertNil(answer(readAdvance(target: next, origin: windowA), current: [open, other], in: windowA))
    }

    // MARK: - Draft replacement

    private func draftReaction(_ replacement: DraftReplacement, loaded: [UInt32]) -> ListSelectionReaction {
        ListSelectionReaction(
            kind: .draftReplacement(replacement, loadedUIDs: loaded),
            rows: Set(replacement.retiredUIDs.map { MessageRef(folder: "Drafts", uid: $0) }),
            target: nil,
            origin: nil
        )
    }

    func testAReaderOnARetiredCopyIsRepointedAtTheSurvivor() {
        let reaction = draftReaction(DraftReplacement(retiredUIDs: [610], survivingUID: 700), loaded: [700, 639])
        XCTAssertEqual(
            answer(reaction, current: [MessageRef(folder: "Drafts", uid: 610)], in: windowA),
            [MessageRef(folder: "Drafts", uid: 700)]
        )
    }

    func testAReaderOnARetiredCopyWhoseSurvivorIsNotLoadedLetsGo() {
        let saved = draftReaction(DraftReplacement(retiredUIDs: [610], survivingUID: 700), loaded: [639])
        let discarded = draftReaction(DraftReplacement(retiredUIDs: [610], survivingUID: nil), loaded: [639])
        let retired: Set<MessageRef> = [MessageRef(folder: "Drafts", uid: 610)]
        XCTAssertEqual(answer(saved, current: retired, in: windowA), [])
        XCTAssertEqual(answer(discarded, current: retired, in: windowA), [])
    }

    /// The selection is matched by ref, so a message in another folder that
    /// shares a retired UID (on the search surface) is left alone.
    func testAReaderOnAnotherMessageIsLeftAlone() {
        let reaction = draftReaction(DraftReplacement(retiredUIDs: [610], survivingUID: 700), loaded: [700])
        XCTAssertNil(answer(reaction, current: [MessageRef(folder: "Drafts", uid: 639)], in: windowA))
        XCTAssertNil(answer(reaction, current: [MessageRef(folder: "INBOX", uid: 610)], in: windowA))
        XCTAssertNil(answer(reaction, current: [], in: windowA))
    }

    func testAFirstSaveLeavesEveryReaderAlone() {
        let reaction = draftReaction(DraftReplacement(retiredUIDs: [], survivingUID: 700), loaded: [700, 639])
        for current: Set<MessageRef> in [[MessageRef(folder: "Drafts", uid: 639)], [], [next]] {
            XCTAssertNil(answer(reaction, current: current, in: windowA))
        }
    }

    // MARK: - A view applying what it hasn't yet

    private func update(
        _ reactions: [ListSelectionReaction],
        selectedRefs: Set<MessageRef>,
        shown: MessageRef?,
        isWideLayout: Bool,
        in window: UUID?
    ) -> ListSelectionUpdate? {
        MailEventSelectionPolicy.update(
            after: reactions, selectedRefs: selectedRefs, shown: shown, isWideLayout: isWideLayout, in: window
        )
    }

    func testAWideViewMovesItsSelectedRowsAndShowsTheOneLeft() {
        XCTAssertEqual(
            update([removal([open], target: next, origin: windowA)],
                   selectedRefs: [open], shown: open, isWideLayout: true, in: windowA),
            ListSelectionUpdate(selectedRefs: [next], shown: next)
        )
    }

    /// A wide list with no selected rows under an open reader takes the
    /// reader's message as its selection, as the shortcuts do.
    func testAWideViewWithNoSelectedRowsFollowsItsReader() {
        XCTAssertEqual(
            update([removal([open], target: next, origin: windowA)],
                   selectedRefs: [], shown: open, isWideLayout: true, in: windowA),
            ListSelectionUpdate(selectedRefs: [next], shown: next)
        )
    }

    func testACompactViewMovesItsReaderAndLeavesTheSelectedRowsAlone() {
        XCTAssertEqual(
            update([removal([open], target: next, origin: windowA)],
                   selectedRefs: [other], shown: open, isWideLayout: false, in: windowA),
            ListSelectionUpdate(selectedRefs: [other], shown: next)
        )
    }

    /// The reactions are worked through in refs: the first advance's target
    /// was pruned by the second removal before the view applied either, and
    /// the view still ends on the second's target.
    func testTwoReactionsAreWorkedThroughBeforeAnythingIsShown() {
        let three = MessageRef(folder: "INBOX", uid: 3)
        let reactions = [
            removal([open], target: three, origin: windowA),
            removal([three], target: next, origin: windowA),
        ]
        for isWideLayout in [true, false] {
            XCTAssertEqual(
                update(reactions, selectedRefs: isWideLayout ? [open] : [], shown: open,
                       isWideLayout: isWideLayout, in: windowA)?.shown,
                next
            )
        }
    }

    func testReactionsThatMoveNothingUpdateNothing() {
        XCTAssertNil(update([removal([open], target: next, origin: windowA)],
                            selectedRefs: [other], shown: other, isWideLayout: true, in: windowA))
        XCTAssertNil(update([], selectedRefs: [open], shown: open, isWideLayout: true, in: windowA))
    }

    func testAMultiSelectionThatLosesARowShowsNothing() {
        let third = MessageRef(folder: "INBOX", uid: 1)
        XCTAssertEqual(
            update([removal([open], target: next, origin: windowA)],
                   selectedRefs: [open, other, third], shown: nil, isWideLayout: true, in: windowA),
            ListSelectionUpdate(selectedRefs: [other, third], shown: nil)
        )
    }

    // MARK: - The reactions views apply them from

    func testEachViewTakesTheReactionsAfterItsOwnPlace() {
        let reactions = ListSelectionReactions()
        let first = removal([open], target: next, origin: windowA)
        let second = readAdvance(target: next, origin: windowA)

        reactions.append(first)
        let placeAfterFirst = reactions.tick
        reactions.append(second)

        XCTAssertEqual(reactions.tick, 2)
        XCTAssertEqual(reactions.since(0), [first, second])
        XCTAssertEqual(reactions.since(placeAfterFirst), [second])
        XCTAssertEqual(reactions.since(0), [first, second], "one view applying them leaves them for another")
        XCTAssertEqual(reactions.since(reactions.tick), [])
    }

    func testOnlyTheLatestAreKept() {
        let reactions = ListSelectionReactions()
        for uid in 1...UInt32(ListSelectionReactions.limit + 4) {
            reactions.append(removal([MessageRef(folder: "INBOX", uid: uid)], target: nil, origin: nil))
        }

        let kept = reactions.since(0)
        XCTAssertEqual(kept.count, ListSelectionReactions.limit)
        XCTAssertEqual(kept.last?.rows, [MessageRef(folder: "INBOX", uid: UInt32(ListSelectionReactions.limit + 4))])
        XCTAssertEqual(reactions.since(reactions.tick - 1).count, 1)
    }
}
