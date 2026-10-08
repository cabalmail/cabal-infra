import XCTest
import CabalmailKit
@testable import CabalmailUI

private let refused = CabalmailError.server(code: "500", message: "refused")

private func ref(_ uid: UInt32, in folder: String = "INBOX") -> MessageRef {
    MessageRef(folder: folder, uid: uid)
}

/// The flagged counts the Flagged pill shows (2.1 D): moved by `\Flagged`
/// changes and by removals of flagged messages, only in folders that have
/// one, and put back on a refusal.
@MainActor
final class MailMutationFlaggedCountTests: XCTestCase {
    private var fixture: MessageDetailLoadFixture!

    override func setUp() async throws {
        fixture = MessageDetailLoadFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func flagged(_ world: ServiceWorld, _ folder: String) -> Int? {
        world.store.counts.folderFlaggedCounts[folder]
    }

    func testAFlagChangeMovesTheFlaggedCountAndARefusalPutsItBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.success(()), .failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)
        world.store.counts.setFlaggedCount(folderPath: "INBOX", count: 2)

        await world.mutations.setFlag(.flagged, added: true, on: [ref(3)], changing: [ref(3)], by: world.composer).value
        XCTAssertEqual(flagged(world, "INBOX"), 3)
        await imap.holdNext(.setFlags)
        let unflag = world.mutations.setFlag(
            .flagged, added: false, on: [ref(3)], changing: [ref(3)], by: world.composer
        )
        await imap.awaitHeld(.setFlags)
        XCTAssertEqual(flagged(world, "INBOX"), 2, "moved before the server answers")
        await imap.releaseHeld(.setFlags)
        await unflag.value

        XCTAssertEqual(flagged(world, "INBOX"), 3, "and back on the refusal")
        XCTAssertEqual(world.unread("INBOX"), 5, "a flag moves no unread count")
    }

    /// Which folders a write moves is decided when it starts: a flagged count
    /// that a STATUS sets while the write is out never held the write's
    /// change, so a refusal takes nothing off it.
    func testAFlaggedCountSetWhileAWriteIsOutIsNotTakenBackFrom() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)
        await imap.holdNext(.setFlags)
        let flag = world.mutations.setFlag(.flagged, added: true, on: [ref(3)], changing: [ref(3)], by: world.composer)
        await imap.awaitHeld(.setFlags)
        world.store.counts.setFlaggedCount(folderPath: "INBOX", count: 4)

        await imap.releaseHeld(.setFlags)
        await flag.value

        XCTAssertEqual(flagged(world, "INBOX"), 4)
    }

    /// A refused flag write on a message removed meanwhile gives no count
    /// back: the removal took the message's count with it.
    func testARefusedFlagOnAMessageRemovedMeanwhileGivesNoCountBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptFlagResults([.failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)
        world.store.counts.setFlaggedCount(folderPath: "INBOX", count: 4)
        await imap.holdNext(.setFlags)
        let flag = world.mutations.setFlag(.flagged, added: true, on: [ref(3)], changing: [ref(3)], by: world.composer)
        await imap.awaitHeld(.setFlags)
        XCTAssertEqual(flagged(world, "INBOX"), 5, "precondition")
        await world.mutations.remove(
            [ref(3)], .move(to: "Archive", markingSeen: true), unread: [], flagged: [ref(3)], by: world.composer
        ).value
        XCTAssertEqual(flagged(world, "INBOX"), 4, "precondition: it left, flagged")

        await imap.releaseHeld(.setFlags)
        await flag.value

        XCTAssertEqual(flagged(world, "INBOX"), 4, "the moved message's count isn't given back a second time")
    }

    func testAFolderWithNoFlaggedCountGetsNone() async throws {
        let world = try await ServiceWorld(FakeImapClient(), fixture: fixture)

        await world.mutations.setFlag(.flagged, added: true, on: [ref(3)], changing: [ref(3)], by: world.composer).value
        await world.mutations.remove(
            [ref(2)], .move(to: "Archive", markingSeen: false), unread: [], flagged: [ref(2)], by: world.composer
        ).value

        XCTAssertNil(flagged(world, "INBOX"))
    }

    /// A flagged message leaving takes its count out of the source folder;
    /// a refusal (whole, or a dispose's partial one) puts it back.
    func testARemovalTakesTheFlaggedCountAndARefusalGivesItBack() async throws {
        let cases: [(Error?, Int)] = [
            (nil, 2), (refused, 4), (CabalmailError.bulkPartialFailure(succeeded: [3], failed: [2]), 3),
        ]
        for (failure, expected) in cases {
            let imap = FakeImapClient()
            if let failure { await imap.scriptMoveResults([.failure(failure)]) }
            let world = try await ServiceWorld(imap, fixture: fixture)
            world.store.counts.setFlaggedCount(folderPath: "INBOX", count: 4)
            world.store.counts.setFlaggedCount(folderPath: "Archive", count: 1)
            await imap.holdNext(.move)

            let removal = world.mutations.remove(
                [ref(3), ref(2)], .move(to: "Archive", markingSeen: true), unread: [],
                flagged: [ref(3), ref(2)], by: world.composer
            )
            await imap.awaitHeld(.move)
            XCTAssertEqual(flagged(world, "INBOX"), 2, "\(String(describing: failure))")
            await imap.releaseHeld(.move)
            await removal.value

            XCTAssertEqual(flagged(world, "INBOX"), expected, "\(String(describing: failure))")
            XCTAssertEqual(flagged(world, "Archive"), 1, "the destination waits for its STATUS")
        }
    }

    func testAFlaggedRemovalAnsweredAfterSignOutGivesNothingBack() async throws {
        let imap = FakeImapClient()
        await imap.scriptPurgeResults([.failure(refused)])
        let world = try await ServiceWorld(imap, fixture: fixture)
        world.store.counts.setFlaggedCount(folderPath: "INBOX", count: 4)
        await imap.holdNext(.purge)
        let removal = world.mutations.remove(
            [ref(3)], .purge, unread: [], flagged: [ref(3)], by: world.composer
        )
        await imap.awaitHeld(.purge)
        world.signOutAndIn()
        world.store.counts.setFlaggedCount(folderPath: "INBOX", count: 9)

        await imap.releaseHeld(.purge)
        await removal.value

        XCTAssertEqual(flagged(world, "INBOX"), 9)
    }
}
