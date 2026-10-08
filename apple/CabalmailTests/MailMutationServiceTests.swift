import XCTest
import CabalmailKit
@testable import CabalmailUI

// `MailMutationService`, the one place mail writes go through: what each
// write records, posts and counts before the request goes out, and how it
// settles -- confirmed (recorded, and forgotten in the offline caches), taken
// back (the reverse change posted, the counts put back), or answered after
// its session ended (nothing at all). Flags and whole-folder writes here;
// removals in `MailMutationRemovalTests`.

private let refused = CabalmailError.server(code: "500", message: "refused")

private func ref(_ uid: UInt32, in folder: String = "INBOX") -> MessageRef {
    MessageRef(folder: folder, uid: uid)
}

@MainActor
final class MailMutationServiceTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    // MARK: - Flags

    /// Everything happens before the request goes out: the record, the
    /// event, and the count for the messages that flip only. The write stays
    /// in the record while the request is out.
    func testAFlagWriteIsRecordedPostedAndCountedBeforeItGoesOut() async throws {
        let imap = FakeImapClient()
        let world = try await ServiceWorld(imap, fixture: fixture)
        await imap.holdNext(.setFlags)

        let write = world.mutations.setFlag(
            .seen, added: true, on: [ref(3), ref(2)], changing: [ref(3)], by: world.composer
        )

        XCTAssertTrue(world.store.shields.isWritingFlags(ref(3)))
        XCTAssertTrue(world.store.shields.isWritingFlags(ref(2)))
        XCTAssertEqual(world.recorder.changes, [.flagsChanged([ref(3), ref(2)], flag: .seen, added: true)])
        XCTAssertEqual(world.unread("INBOX"), 4, "only 3 flips: 2 was read already")
        await imap.awaitHeld(.setFlags)
        XCTAssertTrue(world.store.shields.isWritingFlags(ref(3)), "still in the record while the request is out")
        await imap.releaseHeld(.setFlags)
        let outcome = await write.value

        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertNil(outcome.message)
        XCTAssertFalse(world.store.shields.isWritingFlags(ref(3)), "the write left the record when it answered")
        XCTAssertEqual(world.unread("INBOX"), 4)
    }

    func testARefusedFlagWriteIsTakenBackForTheMessagesItFlipped() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)

        let outcome = await world.mutations.setFlag(
            .seen, added: true, on: [ref(3), ref(2)], changing: [ref(3)], by: world.composer
        ).value

        XCTAssertEqual(outcome.failed, [ref(3), ref(2)])
        XCTAssertEqual(outcome.message, refused.localizedDescription)
        XCTAssertEqual(world.recorder.changes, [
            .flagsChanged([ref(3), ref(2)], flag: .seen, added: true),
            .flagsChanged([ref(3)], flag: .seen, added: false),
        ], "2 never flipped, so it isn't flipped back")
        XCTAssertEqual(world.unread("INBOX"), 5)
    }

    func testAPartlyRefusedFlagWriteTakesBackOnlyTheRefusedPart() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(CabalmailError.bulkPartialFailure(succeeded: [3], failed: [2]))])
        let world = try await ServiceWorld(imap, fixture: fixture)

        let outcome = await world.mutations.setFlag(
            .seen, added: true, on: [ref(3), ref(2)], changing: [ref(3), ref(2)], by: world.composer
        ).value

        XCTAssertEqual(outcome.failed, [ref(2)])
        XCTAssertEqual(outcome.message, "Updated 1 of 2 messages. 1 could not be updated.")
        XCTAssertEqual(world.recorder.changes, [
            .flagsChanged([ref(3), ref(2)], flag: .seen, added: true),
            .flagsChanged([ref(2)], flag: .seen, added: false),
        ])
        XCTAssertEqual(world.unread("INBOX"), 4)
    }

    /// The writer shows its own change, so it isn't sent the events; every
    /// other subscriber is.
    func testTheWriterIsNotSentItsOwnEvents() async throws {
        let world = try await ServiceWorld(FakeImapClient(), fixture: fixture)
        let writer = MailEventRecorder(world.store)

        await world.mutations.setFlag(
            .flagged, added: true, on: [ref(3)], changing: [ref(3)], by: .list(writer, through: world.client)
        ).value

        XCTAssertEqual(writer.events, [])
        XCTAssertEqual(world.recorder.events, [
            MailEvent(
                change: .flagsChanged([ref(3)], flag: .flagged, added: true), origin: nil,
                sender: ObjectIdentifier(writer), advances: false
            ),
        ])
    }

    /// A reply's `\Answered` shows at once and stays even if the STORE
    /// fails: a reply queued offline still goes, and the message may be
    /// answered already. With no session there is nothing to send it
    /// through, and it still shows.
    func testAReplysAnsweredFlagShowsAtOnceAndIsNeverTakenBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)

        world.store.markAnswered(ref(3), client: world.client)
        try await waitUntil { await !imap.flagCalls.isEmpty }
        try await waitUntilOnMainActor { !world.store.shields.isWritingFlags(ref(3)) }
        world.store.markAnswered(ref(4), client: nil)

        XCTAssertEqual(world.recorder.events, [
            MailEvent(change: .flagsChanged([ref(3)], flag: .answered, added: true), origin: nil),
            MailEvent(change: .flagsChanged([ref(4)], flag: .answered, added: true), origin: nil),
        ])
        let stores = await imap.flagCalls.count
        XCTAssertEqual(stores, 1, "no STORE without a session")
    }

    /// A write from a session that has already ended (a reader whose load
    /// outlived it, marking read on open) changes nothing and goes nowhere.
    func testAWriteFromAnEndedSessionChangesNothingAndSendsNothing() async throws {
        let imap = FakeImapClient()
        let world = try await ServiceWorld(imap, fixture: fixture)
        world.signOutAndIn()

        let flag = await world.mutations.setFlag(
            .seen, added: true, on: [ref(3)], changing: [ref(3)], by: world.composer
        ).value
        let removal = await world.mutations.remove(
            [ref(2)], .move(to: "Archive", markingSeen: true), unread: [ref(2)], by: world.composer
        ).value

        XCTAssertEqual(flag.failed, [ref(3)], "the writer takes its own change back")
        XCTAssertEqual(removal.failed, [ref(2)])
        XCTAssertEqual(world.recorder.events, [])
        XCTAssertEqual(world.unread("INBOX"), 7)
        XCTAssertFalse(world.store.shields.isWritingFlags(ref(3)))
        XCTAssertEqual(world.store.shields.pendingMoveRefs, [])
        let flagCalls = await imap.flagCalls.count
        let moveCalls = await imap.moveCalls.count
        XCTAssertEqual(flagCalls + moveCalls, 0)
    }

    func testAFlagWriteRefusedAfterSignOutChangesNothing() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)
        await imap.holdNext(.setFlags)
        let write = world.mutations.setFlag(.seen, added: true, on: [ref(3)], changing: [ref(3)], by: world.composer)
        await imap.awaitHeld(.setFlags)
        world.signOutAndIn()

        await imap.releaseHeld(.setFlags)
        _ = await write.value

        XCTAssertEqual(world.recorder.changes, [.flagsChanged([ref(3)], flag: .seen, added: true)])
        XCTAssertEqual(world.unread("INBOX"), 7)
        XCTAssertFalse(world.store.shields.isWritingFlags(ref(3)))
    }

    // MARK: - Whole folders

    func testMarkAllAsReadAndEmptyTrashGoThroughTheService() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(5)])
        await imap.scriptEmptyTrashResults([.success(())])
        let world = try await ServiceWorld(imap, fixture: fixture)
        world.store.counts.setFolderCounts(folderPath: FolderTree.trashPath, unread: 1, total: 4)
        let refreshes = world.appState.refreshRequestTick

        let flipped = try await world.mutations.markFolderRead("INBOX", through: world.client)
        try await world.mutations.emptyTrash(through: world.client)

        XCTAssertEqual(flipped, 5)
        XCTAssertEqual(world.unread("INBOX"), 0)
        XCTAssertEqual(world.store.counts.folderTotalCounts["INBOX"], 20)
        XCTAssertEqual(world.store.counts.folderTotalCounts[FolderTree.trashPath], 0)
        XCTAssertEqual(world.appState.refreshRequestTick, refreshes + 2, "each asks the lists to reload once")
    }

    /// Answered once the session has ended, neither touches the next
    /// account's counts or reloads its lists.
    func testMarkAllAsReadAndEmptyTrashAnsweredAfterSignOutChangeNothing() async throws {
        let imap = FakeImapClient()
        await imap.scriptMarkFolderReadResults([.success(5)])
        await imap.scriptEmptyTrashResults([.success(())])
        let world = try await ServiceWorld(imap, fixture: fixture)
        world.signOutAndIn()
        world.store.counts.setFolderCounts(folderPath: FolderTree.trashPath, unread: 1, total: 4)
        let refreshes = world.appState.refreshRequestTick

        try await world.mutations.markFolderRead("INBOX", through: world.client)
        try await world.mutations.emptyTrash(through: world.client)

        XCTAssertEqual(world.unread("INBOX"), 7)
        XCTAssertEqual(world.store.counts.folderTotalCounts[FolderTree.trashPath], 4)
        XCTAssertEqual(world.appState.refreshRequestTick, refreshes)
    }
}

@MainActor
final class MailMutationRemovalTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testADisposeMovesTheUnreadCountOutOfTheSourceOnly() async throws {
        let imap = FakeImapClient()
        let world = try await ServiceWorld(imap, fixture: fixture)
        let shields = world.store.shields
        await imap.holdNext(.move)

        let removal = world.mutations.remove(
            [ref(3), ref(2)], .move(to: "Archive", markingSeen: true), unread: [ref(3)], by: world.composer
        )

        XCTAssertEqual(shields.pendingMoveRefs, [ref(3), ref(2)])
        XCTAssertEqual(world.recorder.changes, [.removed([ref(3), ref(2)])])
        XCTAssertEqual(world.unread("INBOX"), 4)
        XCTAssertEqual(world.unread("Archive"), 2, "it arrives read")
        await imap.awaitHeld(.move)
        XCTAssertEqual(shields.pendingMoveRefs, [ref(3), ref(2)], "still in the record while the request is out")
        await imap.releaseHeld(.move)
        let outcome = await removal.value
        XCTAssertEqual(outcome.confirmed, [ref(3), ref(2)])
        XCTAssertEqual(shields.pendingMoveRefs, [])
        XCTAssertEqual(shields.confirmedRemovalRefs(folderPath: "INBOX"), [ref(3), ref(2)])
        let moves = await imap.moveCalls
        XCTAssertEqual(moves.map(\.markSeen), [true])
    }

    func testAPlainMoveCarriesTheUnreadCountToTheDestination() async throws {
        let world = try await ServiceWorld(FakeImapClient(), fixture: fixture)

        await world.mutations.remove(
            [ref(3)], .move(to: "Archive", markingSeen: false), unread: [ref(3)], by: world.composer
        ).value

        XCTAssertEqual(world.unread("INBOX"), 4)
        XCTAssertEqual(world.unread("Archive"), 3)
    }

    /// The destination's count rose before the move landed, so a STATUS of
    /// it asked meanwhile can't take that back (the gap B left for C). A
    /// dispose raises nothing there, and records nothing.
    func testADestinationStatusAskedBeforeAMoveLandedCannotTakeTheArrivalBack() async throws {
        let imap = FakeImapClient()
        let world = try await ServiceWorld(imap, fixture: fixture)
        let store = world.store
        await imap.holdNext(.move)
        let askedAt = ContinuousClock.now

        let move = world.mutations.remove(
            [ref(3)], .move(to: "Archive", markingSeen: false), unread: [ref(3)], by: world.composer
        )
        await imap.awaitHeld(.move)
        let whileOut = store.boundedFolderCounts(unread: 2, total: 9, folderPath: "Archive", askedAt: askedAt)
        XCTAssertEqual(whileOut.unread, 3)
        await imap.releaseHeld(.move)
        await move.value

        XCTAssertEqual(
            store.boundedFolderCounts(unread: 2, total: 9, folderPath: "Archive", askedAt: askedAt).unread, 3,
            "asked before it landed"
        )
        XCTAssertEqual(
            store.boundedFolderCounts(unread: 2, total: 9, folderPath: "Archive", askedAt: .now).unread, 2,
            "asked after: the reply stands"
        )
        store.counts.setFolderCounts(folderPath: "Projects", unread: 4, total: 10)
        await world.mutations.remove(
            [ref(2)], .move(to: "Projects", markingSeen: true), unread: [ref(2)], by: world.composer
        ).value
        XCTAssertEqual(
            store.boundedFolderCounts(unread: 3, total: 10, folderPath: "Projects", askedAt: askedAt).unread, 3,
            "a dispose arrives read: nothing to bound"
        )
    }

    /// A folder the store has no count for (not opened or counted this
    /// session) gets none from a write or its revert: a delta would invent a
    /// count from 0, and taking it back would save that guess over the
    /// folder's real saved count.
    func testAFolderWithNoCountGetsNoneFromAWriteOrItsRevert() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(refused)])
        await imap.scriptFlagResults([.failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)
        await imap.holdNext(.move)

        let move = world.mutations.remove(
            [ref(3)], .move(to: "Projects", markingSeen: false), unread: [ref(3)], by: world.composer
        )
        await imap.awaitHeld(.move)
        XCTAssertNil(world.unread("Projects"), "no count invented for the destination")
        XCTAssertEqual(world.unread("INBOX"), 4, "the counted source still moves")
        await imap.releaseHeld(.move)
        await move.value
        await world.mutations.setFlag(
            .seen, added: true, on: [ref(7, in: "Lists")], changing: [ref(7, in: "Lists")], by: world.composer
        ).value

        XCTAssertNil(world.unread("Projects"))
        XCTAssertNil(world.unread("Lists"))
        XCTAssertEqual(world.unread("INBOX"), 5)
        XCTAssertEqual(
            world.store.boundedFolderCounts(unread: 12, total: 30, folderPath: "Projects", askedAt: .now).unread, 12,
            "and no arrival bounds its first STATUS"
        )
    }

    func testARefusedDisposeComesBackUnreadWithItsCount() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)

        let outcome = await world.mutations.remove(
            [ref(3), ref(2)], .move(to: "Archive", markingSeen: true), unread: [ref(3)], by: world.composer
        ).value

        XCTAssertEqual(outcome.failed, [ref(3), ref(2)])
        XCTAssertTrue(outcome.markedRead.isEmpty)
        XCTAssertEqual(world.recorder.changes, [
            .removed([ref(3), ref(2)]),
            .restored(ref(3), markUnread: true),
            .restored(ref(2), markUnread: false),
        ])
        XCTAssertEqual(world.unread("INBOX"), 5)
        XCTAssertTrue(world.store.shields.confirmedRemovalRefs(folderPath: "INBOX").isEmpty)
    }

    /// A dispose the server moved in part had already marked the rest read:
    /// they come back read, and their unread count stays gone.
    func testAPartlyRefusedDisposeBringsTheRestBackRead() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.bulkPartialFailure(succeeded: [3], failed: [2]))])
        let world = try await ServiceWorld(imap, fixture: fixture)

        let outcome = await world.mutations.remove(
            [ref(3), ref(2)], .move(to: "Archive", markingSeen: true), unread: [ref(3), ref(2)], by: world.composer
        ).value

        XCTAssertEqual(outcome.confirmed, [ref(3)])
        XCTAssertEqual(outcome.failed, [ref(2)])
        XCTAssertEqual(outcome.markedRead, [ref(2)])
        XCTAssertEqual(outcome.message, "Moved 1 of 2 messages. 1 could not be moved.")
        XCTAssertEqual(world.recorder.changes, [
            .removed([ref(3), ref(2)]),
            .restored(ref(2), markUnread: false),
            .flagsChanged([ref(2)], flag: .seen, added: true),
        ])
        XCTAssertEqual(world.unread("INBOX"), 3)
        XCTAssertEqual(world.store.shields.confirmedRemovalRefs(folderPath: "INBOX"), [ref(3)])
    }

    func testAPartlyRefusedMoveHandsTheRefusedUnreadCountBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.bulkPartialFailure(succeeded: [3], failed: [2]))])
        let world = try await ServiceWorld(imap, fixture: fixture)

        await world.mutations.remove(
            [ref(3), ref(2)], .move(to: "Archive", markingSeen: false), unread: [ref(3), ref(2)], by: world.composer
        ).value

        XCTAssertEqual(world.unread("INBOX"), 4, "3 went; 2 is back")
        XCTAssertEqual(world.unread("Archive"), 3)
    }

    func testAPurgeTakesTheUnreadCountAndARefusalGivesItBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptPurgeResults([.success(()), .failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)
        let trash = FolderTree.trashPath
        world.store.counts.setFolderCounts(folderPath: trash, unread: 2, total: 4)
        let purged = ref(3, in: trash)
        let kept = ref(2, in: trash)

        await world.mutations.remove([purged], .purge, unread: [purged], by: world.composer).value
        XCTAssertEqual(world.unread(trash), 1)
        await imap.holdNext(.purge)
        let refusedPurge = world.mutations.remove([kept], .purge, unread: [kept], by: world.composer)
        await imap.awaitHeld(.purge)
        XCTAssertEqual(world.unread(trash), 0, "taken before the server answers")
        await imap.releaseHeld(.purge)
        let outcome = await refusedPurge.value

        XCTAssertEqual(outcome.failed, [kept])
        XCTAssertEqual(world.unread(trash), 1, "and given back when it refuses")
    }

    /// A purge the server carried out in part is handled as refused
    /// throughout, as it always was: every message comes back and none is
    /// confirmed, so the next refresh settles which are really gone.
    func testAPartlyRefusedPurgeBringsEveryMessageBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptPurgeResults([.failure(CabalmailError.bulkPartialFailure(succeeded: [3], failed: [2]))])
        let world = try await ServiceWorld(imap, fixture: fixture)
        let refs = [ref(3, in: FolderTree.trashPath), ref(2, in: FolderTree.trashPath)]

        let outcome = await world.mutations.remove(refs, .purge, unread: [], by: world.composer).value

        XCTAssertEqual(outcome.failed, Set(refs))
        XCTAssertTrue(outcome.confirmed.isEmpty)
        XCTAssertTrue(world.store.shields.confirmedRemovalRefs(folderPath: FolderTree.trashPath).isEmpty)
    }

    /// #1869: a confirmed removal forgets the message in its own folder's
    /// offline caches, whoever removed it.
    func testAConfirmedRemovalForgetsTheMessageInItsFoldersCaches() async throws {
        let world = try await ServiceWorld(FakeImapClient(), fixture: fixture)
        let client = world.client
        let rows = [3, 2].map { TestFixtures.makeEnvelope(uid: UInt32($0)) }
        try await fixture.seedSnapshot(client: client, folder: "INBOX", envelopes: rows)
        try await client.bodyCache.store(
            folder: "INBOX", uidValidity: fixture.uidValidity, uid: 3, bytes: Data("x".utf8)
        )

        await world.mutations.remove(
            [ref(3)], .move(to: "Archive", markingSeen: false), unread: [], by: world.composer
        ).value

        let cached = await client.envelopeCache.snapshot(for: "INBOX")?.envelopes.keys.sorted()
        XCTAssertEqual(cached, [2])
        let body = await client.bodyCache.fetch(folder: "INBOX", uidValidity: fixture.uidValidity, uid: 3)
        XCTAssertNil(body)
    }

    /// A partly refused move puts the refused message back in the store
    /// before it forgets the moved one in the caches, which can wait on a
    /// STATUS: a sign-out during that wait can't carry the put-back into the
    /// next account's counts.
    func testAPartlyRefusedMoveSettlesTheStoreBeforeTheCacheForgetWaits() async throws {
        let imap = FakeImapClient()
        await imap.scriptMoveResults([.failure(CabalmailError.bulkPartialFailure(succeeded: [3], failed: [2]))])
        await imap.scriptStatusResults([.success(FolderStatus(messages: 9, uidValidity: 11))])
        let world = try await ServiceWorld(imap, fixture: fixture)
        await imap.holdNext(.status)

        let move = world.mutations.remove(
            [ref(3), ref(2)], .move(to: "Archive", markingSeen: false), unread: [ref(3), ref(2)], by: world.composer
        )
        await imap.awaitHeld(.status)
        XCTAssertEqual(world.recorder.changes.last, .restored(ref(2), markUnread: false), "settled before the wait")
        world.signOutAndIn()
        await imap.releaseHeld(.status)
        _ = await move.value

        XCTAssertEqual(world.unread("INBOX"), 7, "nothing reached the next account")
        XCTAssertEqual(world.recorder.changes.count, 2)
    }

    /// A removal that answers once its session has ended writes nothing into
    /// the store the next account uses: no confirmed removal, no cache
    /// prune, no row put back, no count.
    func testARemovalAnsweredAfterSignOutChangesNothing() async throws {
        for result in [Result<Void, Error>.success(()), .failure(refused)] {
            let imap = FakeImapClient()
            await imap.scriptMoveResults([result])
            let world = try await ServiceWorld(imap, fixture: fixture)
            let one = [TestFixtures.makeEnvelope(uid: 3)]
            try await fixture.seedSnapshot(client: world.client, folder: "INBOX", envelopes: one)
            await imap.holdNext(.move)
            let removal = world.mutations.remove(
                [ref(3)], .move(to: "Archive", markingSeen: true), unread: [ref(3)], by: world.composer
            )
            await imap.awaitHeld(.move)
            world.signOutAndIn()

            await imap.releaseHeld(.move)
            _ = await removal.value

            XCTAssertEqual(world.recorder.changes, [.removed([ref(3)])], "\(result)")
            XCTAssertTrue(world.store.shields.confirmedRemovalRefs(folderPath: "INBOX").isEmpty, "\(result)")
            XCTAssertEqual(world.store.shields.pendingMoveRefs, [], "\(result)")
            XCTAssertEqual(world.unread("INBOX"), 7, "\(result)")
            let cached = await world.client.envelopeCache.snapshot(for: "INBOX")?.envelopes.keys.sorted()
            XCTAssertEqual(cached, [3], "\(result): the ended session's caches aren't touched")
        }
    }
}
