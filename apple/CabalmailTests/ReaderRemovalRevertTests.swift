import XCTest
import CabalmailKit
@testable import CabalmailUI

// A dispose, move or purge started from the reader prunes the list row before
// the server answers. When the server refused, the row used to stay gone (and
// the folder total and Unread pill stayed short) until a later refresh. The
// reader now reports the failure and the list puts the row back. These tests
// wire a reader to a list the way `MessageDetailView` / `MessageListView` do:
// the reader writes through the store's mutation service, whose removal
// prunes the row and whose refusal restores it.
@MainActor
final class ReaderRemovalRevertTests: XCTestCase {

    private let inbox = "INBOX"

    private struct Pair {
        let list: MessageListViewModel
        let reader: MessageDetailViewModel
    }

    /// A list holding `uids` (all read except `unread`) and a reader open on
    /// `open`, wired through the mail store like the views wire them.
    private func makePair(
        imap: FakeImapClient,
        uids: [UInt32],
        unread: Set<UInt32> = [],
        open: UInt32
    ) throws -> Pair {
        let appState = AppState()
        let envelopes = uids.map {
            TestFixtures.makeEnvelope(uid: $0, flags: unread.contains($0) ? [] : [.seen])
        }
        let list = try TestFixtures.makeModel(
            imap: imap, envelopes: envelopes, folderPath: inbox, mailStore: appState.mailStore
        )
        list.totalMessages = UInt32(uids.count)
        list.unseen = unread.count
        let reader = MessageDetailViewModel(
            folder: Folder(path: inbox, attributes: [], isSubscribed: true),
            envelope: envelopes.first(where: { $0.uid == open })!,
            client: try TestFixtures.makeClient(imap: imap),
            preferences: Preferences(store: InMemoryPreferenceStore())
        )
        // The list holds the store, not `appState`, which goes when this
        // returns; the reader writes through the store's mutation service.
        MessageDetailView.relayOutcomes(of: reader, to: appState.mailStore)
        return Pair(list: list, reader: reader)
    }

    /// The identity of `uid` in `folder` (INBOX unless a test says otherwise).
    private func ref(_ uid: UInt32, in folder: String = "INBOX") -> MessageRef {
        MessageRef(folder: folder, uid: uid)
    }

    func testAFailedReaderDisposePutsTheUnreadRowBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        let pair = try makePair(imap: imap, uids: [3, 2, 1], unread: [2], open: 2)
        var failures = 0
        await imap.holdNext(.move)

        let dispose = Task { await pair.reader.dispose(onFailure: { _ in failures += 1 }) }
        await imap.awaitHeld(.move)
        XCTAssertEqual(pair.list.envelopes.map(\.uid), [3, 1], "precondition: the reader's archive pruned the row")
        await imap.releaseHeld(.move)
        await dispose.value

        XCTAssertEqual(failures, 1, "the user still gets the toast")
        XCTAssertEqual(pair.list.envelopes.map(\.uid), [3, 2, 1], "the row is back where it was")
        XCTAssertEqual(pair.list.totalMessages, 3, "and so is its slot in the folder total")
        XCTAssertEqual(pair.list.unseen, 1, "the message is still unread on the server")
        XCTAssertFalse(pair.list.envelopes[1].flags.contains(.seen))
        XCTAssertFalse(pair.reader.isSeen, "the reader drops its optimistic read mark too")
    }

    func testAFailedReaderMovePutsTheRowBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.network("boom"))])
        let pair = try makePair(imap: imap, uids: [3, 2, 1], open: 2)

        await pair.reader.move(to: "Projects")

        XCTAssertEqual(pair.list.envelopes.map(\.uid), [3, 2, 1])
        XCTAssertEqual(pair.list.totalMessages, 3)
    }

    func testAFailedReaderPurgePutsTheRowBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptPurgeResults([.failure(CabalmailError.network("boom"))])
        let pair = try makePair(imap: imap, uids: [3, 2, 1], open: 2)

        await pair.reader.purge()

        XCTAssertEqual(pair.list.envelopes.map(\.uid), [3, 2, 1])
        XCTAssertEqual(pair.list.totalMessages, 3)
    }

    func testASuccessfulReaderDisposeKeepsTheRowGone() async throws {
        let pair = try makePair(imap: FakeImapClient(), uids: [3, 2, 1], open: 2)

        await pair.reader.dispose()

        XCTAssertEqual(pair.list.envelopes.map(\.uid), [3, 1])
        XCTAssertEqual(pair.list.totalMessages, 2)
    }

    func testAFailureThatBeatsThePruneKeepsTheRow() throws {
        // Both signals can reach the list in one update, failure first.
        let pair = try makePair(imap: FakeImapClient(), uids: [3, 2, 1], unread: [2], open: 2)
        pair.list.applyFlagChange(ref(2), flag: .seen, added: true)

        pair.list.restorePrunedEnvelope(ref(2), markUnread: true)
        pair.list.pruneEnvelope(ref(2))

        XCTAssertEqual(pair.list.envelopes.map(\.uid), [3, 2, 1])
        XCTAssertEqual(pair.list.totalMessages, 3)
        XCTAssertEqual(pair.list.unseen, 1)
        XCTAssertFalse(pair.list.envelopes[1].flags.contains(.seen))
    }

    func testAPruneWithNoMoveBehindItIsNotRestorable() throws {
        // The send-from-draft path prunes without a reader move in flight.
        let list = try TestFixtures.makeModel(
            imap: FakeImapClient(),
            envelopes: [TestFixtures.makeEnvelope(uid: 7, flags: [.seen])],
            folderPath: "Drafts"
        )
        list.totalMessages = 1

        list.pruneEnvelope(ref(7, in: "Drafts"))
        list.restorePrunedEnvelope(ref(7, in: "Drafts"))

        XCTAssertTrue(list.envelopes.isEmpty)
        XCTAssertEqual(list.totalMessages, 0)
    }
}
