import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

// A full swipe to Archive must not leave the next message covered (reported
// 2026-09-30 on iOS; macOS has it too).
//
// A full swipe on an action with the destructive role tells SwiftUI the row is
// being deleted, and on 27 and later its swipe-actions container holds that
// row slid open -- content pushed off the edge, the full-width Archive button
// across it -- until the row leaves the container. The index-addressed
// message list never removed it: the slot re-pointed at the next message,
// which came up covered by the swiped row's button, with a drag to close it
// taken by the navigation back gesture. A move that failed early kept the
// swiped message itself covered the same way. The list now hands the slot a
// new row once the swiped message's fate is settled
// (`MessageListViewModel+RowReplacement.swift`).
//
// Driven through `SwipeTestHarness` (macOS 27 and later): the real view model
// and `dispose(_:)`, `DisposingRow` around `SwipeActionRow` in the message
// list's ScrollView + LazyVStack + container shape, swiped by in-process
// trackpad events. Whether a row is held open is read from its content's
// position: the swipe offsets the content, so a held-open row's content sits
// left of the window's edge. The negative controls key the slots by index
// alone, as the list did before, and must see the held-open row; that is what
// shows the harness can catch the bug at all.
@MainActor
final class FullSwipeRowReplacementTests: XCTestCase {

    /// The report: the message that moves up into a full-swiped row is drawn,
    /// not hidden behind that row's button.
    func testTheMessageThatMovesUpIntoAFullSwipedRowIsNotHeldOpen() async throws {
        let (model, rows) = try await archiveTheTopMessage(keying: .slots)
        XCTAssertEqual(model.window.envelope(at: 0)?.uid, 2, "the full swipe should have archived the top message")
        XCTAssertFalse(
            try rows.isHeldOpen(slot: 0),
            "the message that moved up inherited the swiped row's held-open reveal"
        )
    }

    /// A move that fails while the row is still fading keeps the message where
    /// it was. It must come back drawn, not covered by its own Archive button.
    func testAMessageWhoseArchiveFailsComesBackClosed() async throws {
        let (model, rows) = try await archiveTheTopMessage(keying: .slots, moveFails: true)
        XCTAssertEqual(model.window.envelope(at: 0)?.uid, 1, "a failed move leaves the message in place")
        XCTAssertFalse(
            try rows.isHeldOpen(slot: 0),
            "the message whose archive failed came back held open behind its own button"
        )
    }

    /// The negative control: slots keyed by index alone -- the list before the
    /// fix -- leave the row that took the archived message's place held open.
    /// If they ever stop doing so, SwiftUI no longer holds destructive full
    /// swipes open outside a `List`, and the replacement could be retired.
    func testHarnessSeesTheHeldOpenRowWhenSlotsAreKeyedByIndex() async throws {
        let (model, rows) = try await archiveTheTopMessage(keying: .index)
        XCTAssertEqual(model.window.envelope(at: 0)?.uid, 2)
        try Self.expectHeldOpen(rows)
    }

    /// The same control for the failed move.
    func testHarnessSeesAFailedArchiveHeldOpenWhenSlotsAreKeyedByIndex() async throws {
        let (model, rows) = try await archiveTheTopMessage(keying: .index, moveFails: true)
        XCTAssertEqual(model.window.envelope(at: 0)?.uid, 1)
        try Self.expectHeldOpen(rows)
    }

    /// Full-swipes the top row's destructive trailing action -- `dispose(_:)`,
    /// as the app's Archive swipe runs it -- and waits for the dispose to
    /// finish, then for the rows to settle.
    private func archiveTheTopMessage(
        keying: SlotList.Keying,
        moveFails: Bool = false
    ) async throws -> (MessageListViewModel, RowPositions) {
        let imap = FakeImapClient()
        if moveFails {
            await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        }
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [1, 2, 3, 4].map { TestFixtures.makeEnvelope(uid: $0, flags: [.seen]) }
        )
        model.window.totalMessages = 4
        let rows = RowPositions()
        let harness = try await SwipeTestHarness.make(rows: 4) {
            SlotList(model: model, rows: rows, keying: keying)
        }
        defer { harness.close() }

        try await harness.sendFullSwipe(row: 0, edge: .trailing)
        let settled = try await harness.eventually {
            moveFails ? model.errorMessage != nil : model.envelopes.map(\.uid) == [2, 3, 4]
        }
        XCTAssertTrue(settled, "the full swipe never ran the Archive action; the harness isn't reaching the swipe")
        let idle = try await harness.eventually { model.rowDisposalPhases.isEmpty && model.pendingRemovedRefs.isEmpty }
        XCTAssertTrue(idle, "the dispose never finished")
        try await harness.pause(milliseconds: 500)
        return (model, rows)
    }

    private static func expectHeldOpen(_ rows: RowPositions) throws {
        if try !rows.isHeldOpen(slot: 0) {
            throw XCTSkip("""
                SwiftUI no longer holds a destructive full swipe open outside a List: the row \
                replacement may be unnecessary now (MessageListViewModel+RowReplacement.swift)
                """)
        }
    }
}

/// Where each slot's content was last laid out, horizontally. A plain class:
/// the rows write it from a geometry callback, and nothing renders from it.
@MainActor
private final class RowPositions {
    var minX: [Int: CGFloat] = [:]

    /// The swipe offsets a row's content, and a held-open row's content sits
    /// left of the window's edge; a closed row's sits at its inset.
    func isHeldOpen(slot: Int) throws -> Bool {
        try XCTUnwrap(minX[slot], "slot \(slot) never reported its position") < 0
    }
}

/// The message list's index-addressed shape, as `virtualizedList` and
/// `messageRow` build it: slot `index` shows whichever envelope the model holds
/// there, wrapped in `DisposingRow` around `SwipeActionRow`, with a trailing
/// Archive action that is destructive and runs `dispose(_:)`, as the app's
/// `disposeSwipe` does.
private struct SlotList: View {
    enum Keying {
        /// The list's identity: `model.rowSlots(count:)`.
        case slots
        /// Index alone -- the list before the fix.
        case index
    }

    let model: MessageListViewModel
    let rows: RowPositions
    let keying: Keying

    var body: some View {
        let count = max(Int(model.window.totalMessages), Int(model.window.windowStart) + model.envelopes.count)
        ScrollView {
            LazyVStack(spacing: 0) {
                switch keying {
                case .slots:
                    ForEach(model.rowSlots(count: count), id: \.self) { slot in row(slot.index) }
                case .index:
                    ForEach(0..<count, id: \.self) { index in row(index) }
                }
            }
        }
        .coordinatedSwipeActionsContainer()
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        if let envelope = model.window.envelope(at: index) {
            DisposingRow(model: model, ref: model.rowRef(for: envelope), rowHeight: SwipeTestHarness.rowHeight) {
                SwipeActionRow(
                    height: SwipeTestHarness.rowHeight, contentID: envelope.uid, rowBackground: .clear,
                    leading: nil,
                    trailing: SwipeActionSpec(
                        systemImage: "archivebox", title: "Archive", tint: .red, role: .destructive
                    ) {
                        Task { await model.dispose(envelope) }
                    },
                    onSelect: {},
                    content: {
                        Text("Slot \(index), UID \(envelope.uid)")
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX in
                                rows.minX[index] = minX
                            }
                    }
                )
            }
        } else {
            Color.clear.frame(height: SwipeTestHarness.rowHeight)
        }
    }
}
