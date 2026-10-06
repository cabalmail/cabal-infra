import XCTest
import CabalmailKit
@testable import CabalmailUI

// Rapid swipe-to-dispose, and the races around it (reported 2026-09-29, after
// #901: swiping the next message in a triage rhythm revealed the actions on
// the row BELOW the one under the pointer).
//
// Two things could move the list under the user's pointer:
//
// 1. The dispose held the envelope in `envelopes` until the server answered,
//    while the row had already faded and collapsed to zero height after
//    ~300ms. For the rest of the round trip the next message sat under the
//    pointer while still belonging, in the index-addressed list, to the slot
//    below; a swipe begun there attached to that slot, and when the envelope
//    finally left every slot re-pointed one message up -- the reveal landed a
//    row lower than aimed. The row now leaves the moment its animation ends.
//
// 2. A refresh already in flight when a removal landed could answer with the
//    folder as it stood before the move, after the shield had come down, and
//    put the message back until the next refresh. Confirmed removals now
//    stay shielded (`MessageShields.confirmedRemovals`), and a STATUS that may
//    predate a removal can't push the counts back up.
//
// The fake transport holds a move, STATUS or top-page fetch open
// (`FakeImapClient.holdNext`) so each race is staged exactly rather than by
// timing.
@MainActor
final class DisposeRaceTests: XCTestCase {

    private let inbox = "INBOX"

    private func makeModel(
        imap: FakeImapClient,
        uids: [UInt32],
        appState: AppState = AppState()
    ) throws -> MessageListViewModel {
        let model = try TestFixtures.makeModel(
            imap: imap,
            envelopes: uids.map { TestFixtures.makeEnvelope(uid: $0, flags: [.seen]) },
            folderPath: inbox,
            appState: appState
        )
        model.totalMessages = UInt32(uids.count)
        return model
    }

    private func status(messages: Int) -> FolderStatus {
        FolderStatus(messages: messages, unseen: 0, flagged: 0, uidValidity: 7, uidNext: 100)
    }

    private func page(_ uids: [UInt32]) -> [Envelope] {
        uids.map { TestFixtures.makeEnvelope(uid: $0, flags: [.seen]) }
    }

    /// The identity of `uid`'s message in the inbox.
    private func ref(_ uid: UInt32) -> MessageRef {
        MessageRef(folder: inbox, uid: uid)
    }

    /// Polls on the main actor (letting the model's own tasks run) until
    /// `condition` holds or `timeout` passes.
    private func eventually(
        within timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: - The row leaves when its animation ends

    func testTheRowLeavesWhenItsAnimationEndsWithTheMoveStillInFlight() async throws {
        let imap = FakeImapClient()
        await imap.holdNext(.move)
        let appState = AppState()
        let model = try makeModel(imap: imap, uids: [1, 2, 3], appState: appState)

        let dispose = Task { await model.dispose(model.envelopes[0]) }
        await imap.awaitHeld(.move)

        let left = await eventually { model.envelopes.map(\.uid) == [2, 3] }
        XCTAssertTrue(left, """
            once the fade and collapse have played the row must leave -- waiting for the server \
            leaves the next message under the pointer in the slot below
            """)
        XCTAssertEqual(model.totalMessages, 2)
        XCTAssertFalse(model.isDisposingRow, "rows take hits again once the gap has closed")
        XCTAssertTrue(
            model.pendingRemovedRefs.contains(ref(1)),
            "the UID stays shielded from a refresh until the move lands"
        )

        await imap.releaseHeld(.move)
        await dispose.value

        XCTAssertEqual(model.envelopes.map(\.uid), [2, 3])
        XCTAssertTrue(model.pendingRemovedRefs.isEmpty)
        XCTAssertEqual(appState.mailStore.shields.confirmedRemovalRefs(folderPath: inbox), [ref(1)])
    }

    func testAMoveThatFailsAfterTheRowLeftPutsItBackWhereItWas() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        await imap.holdNext(.move)
        let appState = AppState()
        let model = try makeModel(imap: imap, uids: [1, 2, 3], appState: appState)

        let dispose = Task { await model.dispose(model.envelopes[1]) }
        await imap.awaitHeld(.move)
        let left = await eventually { model.envelopes.map(\.uid) == [1, 3] }
        XCTAssertTrue(left)

        await imap.releaseHeld(.move)
        await dispose.value

        XCTAssertEqual(model.envelopes.map(\.uid), [1, 2, 3], "the failed row comes back at its old index")
        XCTAssertEqual(model.totalMessages, 3)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.rowDisposalPhases.isEmpty)
        XCTAssertTrue(
            appState.mailStore.shields.confirmedRemovalRefs(folderPath: inbox).isEmpty,
            "a failed move is not a confirmed removal"
        )
    }

    func testEveryRowRefusesHitsWhileARowIsLeaving() async throws {
        let model = try makeModel(imap: FakeImapClient(), uids: [1, 2])
        XCTAssertFalse(model.isDisposingRow)

        let disposal = model.beginRowDisposal(ref(1))
        XCTAssertTrue(model.isDisposingRow, "from the first frame of the fade")
        await disposal.value
        XCTAssertTrue(model.isDisposingRow, "through the collapse")

        model.endRowDisposal(ref(1))
        XCTAssertFalse(model.isDisposingRow)
    }

    // MARK: - A stale refresh can't bring a removal back

    func testARefreshFetchedBeforeADisposeLandedCannotBringTheMessageBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptInitialLoad(status: status(messages: 3), topEnvelopes: page([5, 4, 3]))
        let model = try makeModel(imap: imap, uids: [5, 4, 3])

        // The refresh's STATUS answers; its page is fetched from the folder
        // as it stood before the dispose, but held until the dispose is done.
        await imap.holdNext(.topEnvelopes)
        let refresh = Task { await model.refresh() }
        await imap.awaitHeld(.topEnvelopes)

        await model.dispose(model.envelopes[0])
        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3])

        await imap.releaseHeld(.topEnvelopes)
        await refresh.value

        XCTAssertEqual(
            model.envelopes.map(\.uid), [4, 3],
            "a page fetched before the move landed must not put the disposed message back"
        )
    }

    func testAStatusTakenBeforeADisposeLandedCannotRaiseTheCounts() async throws {
        let imap = FakeImapClient()
        await imap.scriptInitialLoad(status: status(messages: 3), topEnvelopes: page([5, 4, 3]))
        let appState = AppState()
        let model = try makeModel(imap: imap, uids: [5, 4, 3], appState: appState)

        await imap.holdNext(.status)
        let refresh = Task { await model.refresh() }
        await imap.awaitHeld(.status)

        await model.dispose(model.envelopes[0])
        XCTAssertEqual(model.totalMessages, 2)

        await imap.releaseHeld(.status)
        await refresh.value

        XCTAssertEqual(
            model.totalMessages, 2,
            "a STATUS answered before the move landed still counts the departed message; it can't restore the slot"
        )
        XCTAssertEqual(model.envelopes.map(\.uid), [4, 3])
        XCTAssertNil(
            appState.mailStore.counts.folderTotalCounts[inbox],
            "nor is that stale count pushed to the sidebar badge"
        )
    }

    func testOnceTheRaceIsOverRefreshesCountAndAddNewMailAgain() async throws {
        let imap = FakeImapClient()
        await imap.scriptInitialLoad(status: status(messages: 3), topEnvelopes: page([5, 4, 3]))
        let model = try makeModel(imap: imap, uids: [5, 4, 3])
        await model.dispose(model.envelopes[0])

        // New mail arrived after the dispose settled; this refresh started
        // after it, so nothing about it predates the removal.
        await imap.scriptInitialLoad(status: status(messages: 3), topEnvelopes: page([6, 4, 3]))
        await model.refresh()

        XCTAssertEqual(model.envelopes.map(\.uid), [6, 4, 3])
        XCTAssertEqual(model.totalMessages, 3, "the clamp is only for replies that may predate a removal")
    }

    func testAMessageTheReaderMovedStaysGoneFromAStaleRefresh() async throws {
        let imap = FakeImapClient()
        await imap.scriptInitialLoad(status: status(messages: 2), topEnvelopes: page([5, 4]))
        let appState = AppState()
        // The reader's archive has already pruned the list row (so the list
        // holds only 4) and its move is in flight.
        let model = try makeModel(imap: imap, uids: [4], appState: appState)
        appState.mailStore.shields.setMoveInFlight(ref(5), inFlight: true)

        await imap.holdNext(.topEnvelopes)
        let refresh = Task { await model.refresh() }
        await imap.awaitHeld(.topEnvelopes)
        // The move lands, in the reader's order: confirmation recorded, then
        // the in-flight shield dropped.
        appState.mailStore.shields.recordConfirmedRemovals([ref(5)])
        appState.mailStore.shields.setMoveInFlight(ref(5), inFlight: false)
        await imap.releaseHeld(.topEnvelopes)
        await refresh.value

        XCTAssertEqual(model.envelopes.map(\.uid), [4], "the page predates the move; the message stays gone")
        XCTAssertEqual(model.totalMessages, 1, "and its STATUS, taken mid-move, can't restore the slot")
    }

    // MARK: - The reader reports its confirmed moves

    func testTheReaderReportsAConfirmedArchiveButNotAFailedOne() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.success(()), .failure(CabalmailError.network("boom"))])
        var confirmations = 0
        func makeReader() throws -> MessageDetailViewModel {
            let reader = MessageDetailViewModel(
                folder: Folder(path: inbox, attributes: [], isSubscribed: true),
                envelope: TestFixtures.makeEnvelope(uid: 9, flags: [.seen]),
                client: try TestFixtures.makeClient(imap: imap),
                preferences: Preferences(store: InMemoryPreferenceStore())
            )
            reader.onMoveConfirmed = { confirmations += 1 }
            return reader
        }

        let archived = try makeReader()
        await archived.dispose()
        XCTAssertEqual(confirmations, 1)

        let refused = try makeReader()
        await refused.dispose()
        XCTAssertEqual(confirmations, 1, "a move the server refused confirms nothing")
    }

    // MARK: - The confirmed-removal window

    func testConfirmedRemovalsAgeOutAndClear() {
        let shields = AppState().mailStore.shields
        let start = ContinuousClock.now
        shields.recordConfirmedRemovals([ref(1), ref(2)], at: start)

        XCTAssertEqual(shields.confirmedRemovalRefs(folderPath: inbox, now: start + .seconds(59)), [ref(1), ref(2)])
        XCTAssertTrue(shields.confirmedRemovalRefs(folderPath: inbox, now: start + .seconds(61)).isEmpty)
        XCTAssertTrue(shields.confirmedRemovalRefs(folderPath: "Archive", now: start).isEmpty, "folder-keyed")

        XCTAssertTrue(shields.removalConfirmed(folderPath: inbox, after: start - .seconds(1)))
        XCTAssertFalse(shields.removalConfirmed(folderPath: inbox, after: start))

        shields.clearConfirmedRemovals(folderPath: inbox)
        XCTAssertTrue(shields.confirmedRemovalRefs(folderPath: inbox, now: start).isEmpty)
    }
}
