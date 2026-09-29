import XCTest
import SwiftUI
import CabalmailKit
@testable import Cabalmail

// The rapid-dispose rhythm on the real rows (reported 2026-09-29): dispose the
// top message, and the next one slides up under the pointer as the disposed
// row collapses. Under the index-addressed list that message still belongs to
// the slot below until the disposed envelope leaves `envelopes`, and the
// envelope used to wait for the server's answer to the move, so a swipe made
// in the meantime attached to the wrong slot and acted a row away from where
// it was aimed once the slots re-pointed.
//
// Driven through `SwipeTestHarness` (macOS 27 and later): the real view model,
// with the move held at the fake transport so "the server is slow" is exact,
// and `DisposingRow` around `SwipeActionRow` in the message list's index-
// addressed ScrollView + LazyVStack + container shape. Each row's action reads
// which message its slot holds when the action runs.
//
// On macOS a trackpad swipe reaches a row by geometry, ignoring hit testing:
// during the collapse it lands on the leaving row's own slot, whose content
// still overflows the zero-height frame. So on macOS what decides the target
// is when that slot re-points to the incoming message -- the dispose now drops
// the envelope as the collapse ends. (Touch swipes follow hit testing instead,
// which is what `DisposingRow`'s all-rows guard is for; unit tests can't drive
// touches.)
@MainActor
final class DisposingRowSwipeGuardTests: XCTestCase {

    func testASwipeRightAfterADisposeActsOnTheMessageUnderThePointer() async throws {
        let imap = FakeImapClient()
        await imap.holdNext(.move)
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: [1, 2, 3, 4].map { TestFixtures.makeEnvelope(uid: $0, flags: [.seen]) }
        )
        model.totalMessages = 4
        let acted = ActedOn()
        let harness = try await SwipeTestHarness.make(rows: 4) {
            IndexedList(model: model, acted: acted)
        }
        defer { harness.close() }

        // Dispose the top message with the server slow to answer.
        let dispose = Task { await model.dispose(model.envelopes[0]) }
        await imap.awaitHeld(.move)
        // The fade and collapse have played; UID 2 is now drawn at the top,
        // under the pointer that just disposed UID 1.
        try await harness.pause(milliseconds: 450)

        try await harness.sendFullSwipe(row: 0, edge: .trailing)
        let ranSomething = try await harness.eventually { !acted.uids.isEmpty }
        XCTAssertTrue(ranSomething, "the swipe under the pointer should run an action")
        XCTAssertEqual(
            acted.uids, [2],
            "the swipe must act on the message drawn under the pointer, not the one still leaving or the one below it"
        )

        await imap.releaseHeld(.move)
        await dispose.value
    }
}

/// UIDs whose trailing action ran, in order.
@Observable
private final class ActedOn {
    var uids: [UInt32] = []
}

/// Index-addressed rows, as in `MessageListView.virtualizedList`: slot `index`
/// shows whichever envelope the model holds at that index, wrapped the way
/// `messageRow` wraps it -- `DisposingRow` around `SwipeActionRow`. The action
/// is built from the slot's envelope on every build, as the app's specs are.
private struct IndexedList: View {
    let model: MessageListViewModel
    let acted: ActedOn

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<max(Int(model.totalMessages), model.envelopes.count), id: \.self) { index in
                    if index < model.envelopes.count {
                        let uid = model.envelopes[index].uid
                        DisposingRow(model: model, uid: uid, rowHeight: SwipeTestHarness.rowHeight) {
                            SwipeActionRow(
                                height: SwipeTestHarness.rowHeight, contentID: uid, rowBackground: .clear,
                                leading: nil,
                                trailing: SwipeActionSpec(systemImage: "archivebox", title: "Archive", tint: .red) {
                                    acted.uids.append(uid)
                                },
                                onSelect: {},
                                content: { Text("Slot \(index), UID \(uid)") }
                            )
                        }
                    } else {
                        Color.clear.frame(height: SwipeTestHarness.rowHeight)
                    }
                }
            }
        }
        .coordinatedSwipeActionsContainer()
    }
}
