import XCTest
import CabalmailKit
@testable import CabalmailUI

private let refused = CabalmailError.server(code: "500", message: "refused")
private let work = "Work"

private func ref(_ uid: UInt32, in folder: String = work) -> MessageRef {
    MessageRef(folder: folder, uid: uid)
}

/// Two writes to one message's flag, where the first one to go out is the
/// last to answer and fails (#1974): the count stands on the write the
/// server took, so the failure's take-back is not its to make -- unless
/// the server took neither, when both are still owed.
@MainActor
final class MailFlagWriteSupersededTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// Two lists of Work's messages 3, 2 and 1 (3 and 2 unread) over one
    /// store, as two windows would hold them, with the sidebar agreeing --
    /// `MailMutationListTests`' fixture, which these interleaves share.
    private func twoLists(
        imap: FakeImapClient,
        appState: AppState
    ) async throws -> (MessageListViewModel, MessageListViewModel) {
        let rows = [3, 2, 1].map { TestFixtures.makeEnvelope(uid: UInt32($0), flags: $0 == 1 ? [.seen] : []) }
        let store = appState.mailStore
        let first = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        let second = try TestFixtures.makeModel(imap: imap, envelopes: rows, folderPath: work, mailStore: store)
        for list in [first, second] {
            await fixture.track(list.client)
            list.window!.totalMessages = 3
            list.unseen = 2
        }
        store.counts.setFolderCounts(folderPath: work, unread: 2, total: 3)
        return (first, second)
    }

    /// A mark-read whose request fails after another list has marked the
    /// same message unread leaves the count where the server is. It used to
    /// raise the count a second time and read one unread too many until the
    /// next STATUS.
    func testAFailedMarkReadIsNotTakenBackOverANewerWriteTheServerTook() async throws {
        let imap = FakeImapClient()
        // The held write is the loser: the one that lands answers first.
        await imap.scriptFlagResults([.success(()), .failure(refused)])
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)
        let counts = appState.mailStore.counts
        await imap.holdNext(.setFlags)

        let read = Task { await first.setFlag(.seen, add: true, envelope: first.envelopes[0]) }
        await imap.awaitHeld(.setFlags)
        XCTAssertEqual(counts.folderUnreadCounts[work], 1, "precondition: the held mark-read moved the count")
        await second.setFlag(.seen, add: false, envelope: second.envelopes[0])
        XCTAssertEqual(counts.folderUnreadCounts[work], 2, "precondition: the newer mark-unread put it back")

        await imap.releaseHeld(.setFlags)
        await read.value

        XCTAssertEqual(counts.folderUnreadCounts[work], 2, "uid 3 is unread on the server, and 2 is the count")
        XCTAssertFalse(second.envelopes[0].flags.contains(.seen), "and the rows agree with it")
        XCTAssertFalse(first.envelopes[0].flags.contains(.seen))
    }

    /// The mirror: a failed mark-*unread* taken back after a newer
    /// mark-read used to leave the count one low, which hides a real unread
    /// message rather than inventing one.
    func testAFailedMarkUnreadIsNotTakenBackOverANewerWriteTheServerTook() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.success(()), .failure(refused)])
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)
        let counts = appState.mailStore.counts
        await imap.holdNext(.setFlags)

        // uid 1 is the read one of the three.
        let unread = Task { await first.setFlag(.seen, add: false, envelope: first.envelopes[2]) }
        await imap.awaitHeld(.setFlags)
        XCTAssertEqual(counts.folderUnreadCounts[work], 3, "precondition: the held mark-unread moved the count")
        await second.setFlag(.seen, add: true, envelope: second.envelopes[2])
        XCTAssertEqual(counts.folderUnreadCounts[work], 2, "precondition: the newer mark-read put it back")

        await imap.releaseHeld(.setFlags)
        await unread.value

        XCTAssertEqual(counts.folderUnreadCounts[work], 2, "uid 1 is read on the server, and 2 is the count")
        XCTAssertTrue(second.envelopes[2].flags.contains(.seen), "and the rows agree with it")
    }

    /// The control that bounds the rule: when the newer write fails too,
    /// the server took neither, and each take-back is still owed. Suppress
    /// the older one here and the count ends one short of the folder.
    func testTwoFailedWritesToOneMessageEachTakeTheirOwnCountBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(refused), .failure(refused)])
        let appState = AppState()
        let (first, second) = try await twoLists(imap: imap, appState: appState)
        let counts = appState.mailStore.counts
        await imap.holdNext(.setFlags)

        let read = Task { await first.setFlag(.seen, add: true, envelope: first.envelopes[0]) }
        await imap.awaitHeld(.setFlags)
        await second.setFlag(.seen, add: false, envelope: second.envelopes[0])
        XCTAssertEqual(counts.folderUnreadCounts[work], 1, "precondition: the refused mark-unread took its own back")

        await imap.releaseHeld(.setFlags)
        await read.value

        XCTAssertEqual(counts.folderUnreadCounts[work], 2, "neither write landed: uid 3 is unread, and 2 is the count")
        XCTAssertFalse(first.envelopes[0].flags.contains(.seen))
    }
}
