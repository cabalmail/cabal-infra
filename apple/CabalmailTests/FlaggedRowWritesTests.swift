import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a message's row in the Flagged view writes, and what a write does
/// to the list: a swipe acts in the row's own folder, a cleared flag takes
/// its row out at once, and the list hears what readers and other lists
/// did to its messages. `FlaggedFeedRowWritesTests` has a feed item's row.
@MainActor
final class FlaggedRowWritesTests: XCTestCase {
    private typealias Fixture = FlaggedFixture
    private var fixture: FlaggedFixture!

    override func setUp() async throws {
        fixture = try await FlaggedFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    /// A list of one unread INBOX message, one read message in a nested
    /// folder that shares its UID, and an unread one in Archive.
    private func loaded() async -> FlaggedListViewModel {
        await fixture.source.answer(.any, with: Fixture.page([
            Fixture.mail(4, "2026-03-07T08:00:00Z"),
            Fixture.mail(4, "2026-03-06T08:00:00Z", folder: "Lists/swift", flags: [.flagged, .seen]),
            Fixture.mail(9, "2026-03-05T08:00:00Z", folder: "Archive"),
        ]))
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m4", "m4", "m9"])
        return model
    }

    /// A row a test asked for is not in the list: a failure, never a skip.
    private struct NotLoaded: Error {
        let what: String
    }

    private let inbox = MessageRef(folder: "INBOX", uid: 4)
    private let nested = MessageRef(folder: "Lists/swift", uid: 4)
    private let archived = MessageRef(folder: "Archive", uid: 9)

    private func envelope(_ ref: MessageRef, in model: FlaggedListViewModel) throws -> Envelope {
        guard case .mail(let envelope, _)? = model.row(for: .mail(ref)) else { throw NotLoaded(what: "\(ref)") }
        return envelope
    }

    // MARK: A dispose acts in the row's own folder

    func testASwipeDisposeMovesTheMessageOutOfItsOwnFolder() async throws {
        fixture.preferences.disposeAction = .archive
        let model = await loaded()
        let actions = FlaggedRowActions(model: model)
        let spec = try XCTUnwrap(actions.mailSwipe(.dispose, envelope: try envelope(nested, in: model), ref: nested))
        XCTAssertEqual(spec.title, "Archive")
        XCTAssertEqual(spec.role, .destructive)

        spec.perform()

        try await waitUntilOnMainActor { await self.fixture.imap.moveCalls.count == 1 }
        let move = await fixture.imap.moveCalls[0]
        XCTAssertEqual(move.folder, "Lists/swift", "the row's own folder, not the view's or INBOX")
        XCTAssertEqual(move.uids, [4])
        XCTAssertEqual(move.destination, "Archive")
        XCTAssertFalse(move.markSeen, "it was read already")
        // Its namesake in INBOX, the same UID, is another message.
        await fixture.expect(model, shows: ["m4", "m9"])
        XCTAssertNotNil(model.row(for: .mail(inbox)))
        XCTAssertNil(model.row(for: .mail(nested)))
        XCTAssertEqual(model.removals.refs, [nested])
    }

    func testADisposeMarksAnUnreadMessageReadAsItMoves() async throws {
        fixture.preferences.disposeAction = .trash
        let model = await loaded()

        await model.dispose(inbox)

        let moves = await fixture.imap.moveCalls
        let move = try XCTUnwrap(moves.first)
        XCTAssertEqual(move.folder, "INBOX")
        XCTAssertEqual(move.destination, "Trash")
        XCTAssertTrue(move.markSeen)
    }

    func testInsideArchiveTheDisposeIsARestoreToTheInbox() async throws {
        fixture.preferences.disposeAction = .archive
        let model = await loaded()
        let actions = FlaggedRowActions(model: model)

        XCTAssertEqual(model.disposeIntent(for: archived), .restore)
        XCTAssertEqual(model.disposeIntent(for: inbox), .move(.archive))
        let spec = try XCTUnwrap(actions.disposeSpec(archived))
        XCTAssertEqual(spec.title, "Restore")
        XCTAssertNil(spec.role)
        spec.perform()

        try await waitUntilOnMainActor { await self.fixture.imap.moveCalls.count == 1 }
        let move = await fixture.imap.moveCalls[0]
        XCTAssertEqual(move.folder, "Archive")
        XCTAssertEqual(move.destination, "INBOX")
        XCTAssertFalse(move.markSeen, "a restore carries its read state with it")
    }

    func testATrashPreferenceMovesAnArchiveRowToTrash() async throws {
        fixture.preferences.disposeAction = .trash
        let model = await loaded()

        XCTAssertEqual(model.disposeIntent(for: archived), .move(.trash))
        await model.dispose(archived)

        let moves = await fixture.imap.moveCalls
        let move = try XCTUnwrap(moves.first)
        XCTAssertEqual(move.folder, "Archive")
        XCTAssertEqual(move.destination, "Trash")
    }

    func testARowInTrashOffersNoDispose() async throws {
        let model = await loaded()

        XCTAssertNil(FlaggedRowActions(model: model).disposeSpec(MessageRef(folder: "Trash", uid: 1)))
    }

    func testARefusedDisposePutsTheRowBackWhereItWas() async throws {
        fixture.preferences.disposeAction = .archive
        let model = await loaded()
        await fixture.imap.scriptMoveResults([.failure(CabalmailError.network("offline"))])

        await model.dispose(nested)

        await fixture.expect(model, shows: ["m4", "m4", "m9"])
        XCTAssertNotNil(model.row(for: .mail(nested)))
        XCTAssertNotNil(model.errorMessage)
    }

    func testASecondDisposeOfAMessageOnItsWayOutSendsNothing() async throws {
        let model = await loaded()

        let ref = inbox
        let first = Task { await model.dispose(ref) }
        let second = Task { await model.dispose(ref) }
        await first.value
        await second.value

        let moves = await fixture.imap.moveCalls
        XCTAssertEqual(moves.count, 1)
    }

    // MARK: A message's flags

    func testAMessageWhoseOnlyFlagIsClearedLeavesAtOnce() async throws {
        let model = await loaded()
        let actions = FlaggedRowActions(model: model)
        let spec = try XCTUnwrap(actions.mailSwipe(.toggleFlag, envelope: try envelope(nested, in: model), ref: nested))
        XCTAssertEqual(spec.title, "Unflag")

        spec.perform()

        await fixture.expect(model, shows: ["m4", "m9"])
        try await waitUntilOnMainActor { await self.fixture.imap.flagCalls.count == 1 }
        let call = await fixture.imap.flagCalls[0]
        XCTAssertEqual(call.folder, "Lists/swift")
        XCTAssertEqual(call.uids, [4])
        XCTAssertEqual(call.flags, [.flagged])
        XCTAssertEqual(call.operation, .remove)
        XCTAssertEqual(model.removals.tick, 0, "its flag went, not the message: a reader stays open on it")
    }

    func testAMessageThatStillCarriesAnotherFlagStaysUnderAnyFlag() async throws {
        fixture.addLaterFlag()
        await fixture.source.answer(.any, with: Fixture.page([
            Fixture.mail(1, "2026-03-07T08:00:00Z", flags: [.flagged, .keyword(Fixture.later)]),
        ]))
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m1"])

        await model.toggle(.flagged, on: MessageRef(folder: "INBOX", uid: 1))

        XCTAssertEqual(Fixture.names(model), ["m1"])
        XCTAssertEqual(try envelope(MessageRef(folder: "INBOX", uid: 1), in: model).flags, [.keyword(Fixture.later)])
    }

    func testARefusedFlagWriteBringsTheRowBack() async throws {
        let model = await loaded()
        await fixture.imap.scriptFlagResults([.failure(CabalmailError.network("offline"))])

        await model.toggleDefaultFlag(on: inbox)

        await fixture.expect(model, shows: ["m4", "m4", "m9"])
        XCTAssertTrue(try envelope(inbox, in: model).flags.contains(.flagged))
        XCTAssertNotNil(model.errorMessage)
    }

    func testReadAndUnreadAreWrittenInTheRowsFolderAndTheRowStays() async throws {
        let model = await loaded()

        await model.toggleSeen(nested)

        let flagCalls = await fixture.imap.flagCalls
        let call = try XCTUnwrap(flagCalls.first)
        XCTAssertEqual(call.folder, "Lists/swift")
        XCTAssertEqual(call.flags, [.seen])
        XCTAssertEqual(call.operation, .remove)
        XCTAssertEqual(Fixture.names(model), ["m4", "m4", "m9"])
    }

    func testTheCountFollowsTheRowsThatLeave() async throws {
        fixture.addLaterFlag()
        let model = await loaded()
        XCTAssertEqual(model.count, 3)

        await model.toggleDefaultFlag(on: inbox)
        XCTAssertEqual(model.count, 2)
        await model.dispose(archived)
        XCTAssertEqual(model.count, 1)
    }

    // MARK: What the rest of the app did

    /// A reader opened from the list clears the flag and sets it again: the
    /// row leaves, and comes back.
    func testAFlagSetAgainElsewhereBringsTheRowBack() async throws {
        let model = await loaded()

        fixture.mailStore.events.post(.flagsChanged([nested], flag: .flagged, added: false), from: nil)
        XCTAssertEqual(Fixture.names(model), ["m4", "m9"])
        XCTAssertEqual(model.removals.tick, 0)

        fixture.mailStore.events.post(.flagsChanged([nested], flag: .flagged, added: true), from: nil)
        XCTAssertEqual(Fixture.names(model), ["m4", "m4", "m9"])
    }

    func testAMessageRemovedElsewhereLeavesAndIsNamedForTheReaderToClose() async throws {
        let model = await loaded()

        fixture.mailStore.events.post(.removed([nested, MessageRef(folder: "Sent", uid: 1)]), from: nil)

        XCTAssertEqual(Fixture.names(model), ["m4", "m9"])
        XCTAssertEqual(model.removals.tick, 1)
        XCTAssertTrue(model.removals.refs.contains(nested))

        // The server refused it: the row is back where it was.
        fixture.mailStore.events.post(.restored(nested, markUnread: true), from: nil)
        XCTAssertEqual(Fixture.names(model), ["m4", "m4", "m9"])
        XCTAssertFalse(try envelope(nested, in: model).flags.contains(.seen))
    }

    func testARemovalThatNamesNoneOfItsRowsChangesNothing() async throws {
        let model = await loaded()

        fixture.mailStore.events.post(.removed([MessageRef(folder: "Sent", uid: 4)]), from: nil)

        XCTAssertEqual(Fixture.names(model), ["m4", "m4", "m9"])
        XCTAssertEqual(model.removals.tick, 0)
    }

    func testADisabledEdgeHasNoSwipe() async throws {
        let model = await loaded()
        let actions = FlaggedRowActions(model: model)
        let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "a", sortKey: "a", isFavorite: true)

        XCTAssertNil(actions.feedSwipe(.disabled, item: item))
        XCTAssertNil(actions.mailSwipe(.disabled, envelope: try envelope(inbox, in: model), ref: inbox))
    }
}
