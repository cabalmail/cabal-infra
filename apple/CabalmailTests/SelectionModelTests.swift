import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A list's selection as an object of its own (`SelectionModel`): the
/// anchor rule it took over from the message list's view model, what goes
/// across a layout swap, and the view model reading and writing the one it
/// is given.
@MainActor
final class SelectionModelTests: XCTestCase {
    func testPinningTheAnchorRecordsTheSelectionItStartsFrom() {
        let selection = SelectionModel<Int>()
        selection.selected = [1, 3]
        selection.setAnchor(3)
        selection.selected = [1, 3, 4, 5]

        XCTAssertEqual(selection.anchor, 3)
        XCTAssertEqual(selection.rangeBase, [1, 3], "the base is what was selected when the anchor was pinned")

        selection.selected = []
        selection.setAnchor(nil)
        XCTAssertNil(selection.anchor)
        XCTAssertTrue(selection.rangeBase.isEmpty)
    }

    // MARK: - Layout swaps

    func testAMultiSelectionGoesToTheWideLayoutAsItIs() {
        let selection = SelectionModel<Int>()
        selection.selected = [1, 2]

        XCTAssertTrue(selection.handOff(toWide: true))
        XCTAssertFalse(selection.bulkMode, "the wide layouts draw a multi-selection without Select mode")
        XCTAssertEqual(selection.selected, [1, 2])
    }

    func testAMultiSelectionArrivingOnTheCompactLayoutTurnsSelectModeOn() {
        let selection = SelectionModel<Int>()
        selection.selected = [1, 2]
        selection.setAnchor(2)
        selection.cursor = 2

        XCTAssertTrue(selection.handOff(toWide: false))
        XCTAssertTrue(selection.bulkMode, "the compact layout draws a multi-selection only as checkboxes")
        XCTAssertEqual(selection.selected, [1, 2])
        XCTAssertEqual(selection.anchor, 2)
        XCTAssertEqual(selection.cursor, 2)
    }

    func testSelectModeGoesAcrossWithAnyNumberOfRows() {
        for rows in [Set<Int>(), [1]] {
            for isWide in [true, false] {
                let selection = SelectionModel<Int>()
                selection.bulkMode = true
                selection.selected = rows

                XCTAssertTrue(selection.handOff(toWide: isWide), "\(rows.count) rows, wide: \(isWide)")
                XCTAssertTrue(selection.bulkMode)
                XCTAssertEqual(selection.selected, rows)
            }
        }
    }

    /// One row picked outside Select mode is the open message, which the
    /// window's route carries; nothing else does.
    func testALoneSelectionStaysBehind() {
        for rows in [Set<Int>(), [1]] {
            for isWide in [true, false] {
                let selection = SelectionModel<Int>()
                selection.selected = rows

                XCTAssertFalse(selection.handOff(toWide: isWide), "\(rows.count) rows, wide: \(isWide)")
                XCTAssertFalse(selection.bulkMode)
                XCTAssertEqual(selection.selected, rows)
            }
        }
    }

    // MARK: - The message list's view model

    func testAListReadsAndWritesTheSelectionItIsGiven() throws {
        let selection = SelectionModel<MessageRef>()
        let model = try makeModel(selection: selection)

        XCTAssertIdentical(model.selection, selection)
        model.bulkMode = true
        model.selectedRefs = [ref(1), ref(2)]
        model.setSelectionAnchor(ref(2))
        model.selectionCursor = ref(1)
        model.selectedRefs.remove(ref(1))

        XCTAssertTrue(selection.bulkMode)
        XCTAssertEqual(selection.selected, [ref(2)])
        XCTAssertEqual(selection.anchor, ref(2))
        XCTAssertEqual(selection.rangeBase, [ref(1), ref(2)])
        XCTAssertEqual(selection.cursor, ref(1))

        selection.selected = [ref(1)]
        selection.setAnchor(ref(1))
        selection.cursor = nil
        selection.bulkMode = false
        XCTAssertEqual(model.selectedRefs, [ref(1)])
        XCTAssertEqual(model.selectionAnchor, ref(1))
        XCTAssertEqual(model.selectionRangeBase, [ref(1)])
        XCTAssertNil(model.selectionCursor)
        XCTAssertFalse(model.bulkMode)
    }

    /// The list a swap tears down and the one it builds hold one selection,
    /// so what the old list's bulk action does when it lands — dropping the
    /// rows it moved — reaches the new one.
    func testTwoListsGivenOneSelectionShareIt() throws {
        let selection = SelectionModel<MessageRef>()
        let old = try makeModel(selection: selection)
        let new = try makeModel(selection: selection)

        old.toggleSelection(old.envelopes[0])
        old.toggleSelection(old.envelopes[1])
        XCTAssertEqual(new.selectedRefs, [ref(1), ref(2)])

        old.exitBulkMode()
        XCTAssertTrue(new.selectedRefs.isEmpty)
    }

    func testAListGivenNoSelectionHasItsOwn() throws {
        let first = try makeModel(selection: nil)
        let second = try makeModel(selection: nil)

        first.selectedRefs = [ref(1)]

        XCTAssertNotIdentical(first.selection, second.selection)
        XCTAssertTrue(second.selectedRefs.isEmpty)
    }

    // MARK: - Fixture

    private func makeModel(selection: SelectionModel<MessageRef>?) throws -> MessageListViewModel {
        let model = MessageListViewModel(
            scope: .folder(Folder(path: "INBOX", attributes: [], isSubscribed: true)),
            client: try TestFixtures.makeClient(imap: FakeImapClient()),
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: AppState().mailStore,
            selection: selection
        )
        model.envelopes = model.placedInFolder([1, 2, 3].map { TestFixtures.makeEnvelope(uid: $0) })
        return model
    }

    private func ref(_ uid: UInt32) -> MessageRef {
        MessageRef(folder: "INBOX", uid: uid)
    }
}
