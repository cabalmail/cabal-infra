import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the Message and Feeds menus' item commands do to the row open in
/// the Flagged view's reader (`FlaggedItemCommands`). On the Mac the menus
/// were live there and did nothing: no list that answers them is mounted
/// while the window is on the view. These hold what each command comes to
/// in the model; the modifier's part is which row a command is for.
@MainActor
final class FlaggedItemCommandsTests: XCTestCase {
    private typealias Fixture = FlaggedFixture
    private var fixture: FlaggedFixture!

    override func setUp() async throws {
        fixture = try await FlaggedFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    private let inbox = MessageRef(folder: "INBOX", uid: 4)
    private let nested = MessageRef(folder: "Lists/swift", uid: 4)

    /// An unread INBOX message and a read one in a nested folder that
    /// shares its UID.
    private func loaded() async -> FlaggedListViewModel {
        await fixture.source.answer(.any, with: Fixture.page([
            Fixture.mail(4, "2026-03-07T08:00:00Z"),
            Fixture.mail(4, "2026-03-06T08:00:00Z", folder: "Lists/swift", flags: [.flagged, .seen]),
        ]))
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m4", "m4"])
        return model
    }

    // MARK: Which row a command is for

    func testAMessageCommandIsForTheOpenMessageAndForNoFeedItem() throws {
        let envelope = Envelope(uid: 4, subject: "m4", from: [], flags: [.flagged], folder: "Lists/swift")
        let article = RssItem(feedId: "f", subscriptionId: "s", itemId: "a", sortKey: "a", isFavorite: true)

        XCTAssertEqual(FlaggedItemCommands.message(.mail(envelope, nested)), nested)
        XCTAssertNil(FlaggedItemCommands.message(.feed(article)))
        XCTAssertNil(FlaggedItemCommands.message(nil))
    }

    // MARK: Move

    func testAMoveTakesTheMessageOutOfItsOwnFolderToThePickedOne() async throws {
        let model = await loaded()

        await model.move(nested, to: "Projects")

        let moves = await fixture.imap.moveCalls
        let move = try XCTUnwrap(moves.first)
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(move.folder, "Lists/swift", "the row's own folder, not INBOX's namesake")
        XCTAssertEqual(move.uids, [4])
        XCTAssertEqual(move.destination, "Projects")
        await fixture.expect(model, shows: ["m4"])
        XCTAssertNotNil(model.row(for: .mail(inbox)))
        XCTAssertEqual(model.removals.refs, [nested], "named for its reader to close on")
    }

    /// A dispose marks an unread message read as it goes. A move the user
    /// picked a folder for is not a dispose, and leaves it unread.
    func testAMoveLeavesAnUnreadMessageUnread() async throws {
        let model = await loaded()

        await model.move(inbox, to: "Projects")

        let moves = await fixture.imap.moveCalls
        XCTAssertEqual(moves.first?.folder, "INBOX")
        XCTAssertEqual(moves.first?.markSeen, false)
    }

    func testAMoveToTheFolderTheMessageIsInSendsNothing() async throws {
        let model = await loaded()

        await model.move(nested, to: "Lists/swift")

        let moves = await fixture.imap.moveCalls
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(Fixture.names(model), ["m4", "m4"])
    }

    func testARefusedMovePutsTheRowBack() async throws {
        let model = await loaded()
        await fixture.imap.scriptMoveResults([.failure(CabalmailError.network("offline"))])

        await model.move(nested, to: "Projects")

        await fixture.expect(model, shows: ["m4", "m4"])
        XCTAssertNotNil(model.row(for: .mail(nested)))
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: A feed item's read state

    /// The command toggles what the store holds, not the caller's copy: the
    /// reader's copy of an item can be older than the last mark.
    func testToggleReadGoesByWhatTheStoreHoldsNotTheCallersCopy() async throws {
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["a"])
        guard case .feed(let stale)? = model.row(for: .feed(feedID: "f", sortKey: "a")) else {
            return XCTFail("the item is not listed")
        }
        XCTAssertFalse(stale.isRead)

        await model.toggleRead(stale)
        let read = try await fixture.store.item(feedId: "f", sortKey: "a")
        XCTAssertEqual(read?.isRead, true)

        // The same, older copy again: the store says read, so this unreads.
        await model.toggleRead(stale)
        let unread = try await fixture.store.item(feedId: "f", sortKey: "a")
        XCTAssertEqual(unread?.isRead, false)
    }
}
