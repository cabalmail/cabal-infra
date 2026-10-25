import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the navigator does with an open message when **two** trees arrive
/// inside one layout swap, which is what a split rebuilt to re-tile makes
/// (`SplitRetilePolicy`, #1988): the Zoom's own tree, then the rebuild's.
///
/// A rebuilt tree parks the open message for its new list to reselect,
/// unless a restore for that folder is already waiting — a navigation or a
/// landing the list has not applied yet, newer than the open message. Inside
/// one swap the waiting restore is the *previous tree's* hand-off of the
/// same message, for a list that is being torn down and will never select
/// it, so standing off there lost the message: the reader came back on "No
/// message selected" in 5 of 6 Zooms. The guard now reads what the waiting
/// restore names, not just that one is waiting.
@MainActor
final class SplitRetileHandOffTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SplitRetileHandOffTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let nine = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

    /// A window on INBOX with uid 9 open in the reader, and the tree showing it.
    private func reading() async throws -> (navigator: SceneNavigator, tree: UUID) {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: nil, deepLinks: DeepLinkRouter()
        )
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: true)
        navigator.foldersLoaded([inbox, archive])
        _ = navigator.restores.consumePendingRestore(for: "INBOX")
        navigator.selectMessage(nine, isSearching: false, from: tree)
        return (navigator, tree)
    }

    // MARK: The two-tree swap

    /// The defect: the Zoom's tree parks uid 9 for a list the rebuild
    /// replaces, and the rebuild's tree has to take that restore over.
    func testTheSecondTreeInOneSwapTakesTheParkedMessageOver() async throws {
        let (navigator, _) = try await reading()

        await navigator.mailTreeAppeared(UUID(), isWide: true)
        let handedOff = try XCTUnwrap(navigator.restores.pendingRestore, "precondition: the Zoom's tree parks it")
        XCTAssertEqual(handedOff.uid, 9)

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        let takenOver = try XCTUnwrap(
            navigator.restores.pendingRestore,
            "the rebuild's tree parks nothing, so the message is left to a list that is going away"
        )
        XCTAssertEqual(takenOver.uid, 9)
        XCTAssertEqual(takenOver.messageID, "<nine@example.com>")
        XCTAssertNotEqual(
            takenOver.tick, handedOff.tick,
            "it has to be a fresh park: the rebuild's list applies a restore it has not seen before"
        )
        XCTAssertEqual(navigator.restores.consumePendingRestore(for: "INBOX")?.uid, 9)
    }

    /// Three trees in one swap — two rebuilds, which a second Zoom inside the
    /// animation makes — keep handing the same message along.
    func testAThirdTreeKeepsTakingItOver() async throws {
        let (navigator, _) = try await reading()
        for _ in 0..<3 { await navigator.mailTreeAppeared(UUID(), isWide: true) }
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 9)
    }

    /// The negative control, and the guard's own reason for existing: a
    /// restore waiting on a *different* message is a navigation or a landing
    /// the list has not applied yet. It carries its own reading position, and
    /// a re-park of the open message would replace it (#1987).
    func testARestoreWaitingOnAnotherMessageStillStandsOff() async throws {
        let (navigator, _) = try await reading()
        navigator.restores.park(NavState(folder: "INBOX", messageID: "<four@example.com>", uid: 4, clientID: "push"))

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 4, "the newer navigation is what the list applies")
        XCTAssertEqual(navigator.restores.pendingRestore?.messageID, "<four@example.com>")
    }

    /// A restore waiting for another folder was never what the guard meant,
    /// and still is not.
    func testARestoreWaitingForAnotherFolderDoesNotStandOff() async throws {
        let (navigator, _) = try await reading()
        navigator.restores.park(NavState(folder: "Archive", uid: 4, clientID: "push"))

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 9, "INBOX's open message is parked for INBOX's list")
    }

    // MARK: The list that is going away

    /// The other half of the loss, measured: the list in the tree the swap
    /// replaced finishes its own initial load ~70 ms before the list that
    /// replaces it, and it is still mounted and still watching the window's
    /// restores. Taking the restore there applies it in a view that is going
    /// away, so the tree that replaced it finds the pop-once slot empty.
    func testAListInTheTreeASwapReplacedTakesNoRestore() async throws {
        let (navigator, firstTree) = try await reading()
        let rebuild = UUID()
        await navigator.mailTreeAppeared(rebuild, isWide: true)

        XCTAssertFalse(navigator.listMayTakeRestore(in: firstTree), "that list is being torn down")
        XCTAssertTrue(navigator.listMayTakeRestore(in: rebuild))
    }

    /// A list with no tree is not in a swap: the compact tab trees, and any
    /// list hosted outside a main window, take a restore as they always did.
    func testAListWithNoTreeTakesARestore() async throws {
        let (navigator, _) = try await reading()
        await navigator.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertTrue(navigator.listMayTakeRestore(in: nil))
    }

    /// A tree that has not appeared yet is not a superseded one — it is the
    /// tree a swap is building. Refusing it would strand the restore, since
    /// nothing re-parks for a list that declined to take one.
    func testATreeThatHasNotAppearedYetMayTakeARestore() async throws {
        let (navigator, _) = try await reading()
        await navigator.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertTrue(navigator.listMayTakeRestore(in: UUID()))
    }

    /// The same tree appearing again is a tab switch, not a swap: it does
    /// not supersede itself.
    func testATreeAppearingAgainDoesNotSupersedeItself() async throws {
        let (navigator, tree) = try await reading()
        await navigator.mailTreeAppeared(tree, isWide: true)
        XCTAssertTrue(navigator.listMayTakeRestore(in: tree))
    }

    /// Three trees in one swap: only the one the last arrival replaced is
    /// refused. The one before it is long gone and asks for nothing.
    func testOnlyTheTreeTheLastArrivalReplacedIsRefused() async throws {
        let (navigator, first) = try await reading()
        let second = UUID()
        let third = UUID()
        await navigator.mailTreeAppeared(second, isWide: true)
        await navigator.mailTreeAppeared(third, isWide: true)

        XCTAssertFalse(navigator.listMayTakeRestore(in: second))
        XCTAssertTrue(navigator.listMayTakeRestore(in: third))
        XCTAssertTrue(navigator.listMayTakeRestore(in: first), "already gone")
    }

    // MARK: The query

    func testTheQueryReadsWhatTheWaitingRestoreNames() {
        let restores = WindowRestores()
        let nine = MessageRef(folder: "INBOX", uid: 9, messageId: "<nine@example.com>")
        XCTAssertFalse(restores.pendingRestoreSupersedes(nine), "nothing is waiting")

        restores.park(NavState(folder: "INBOX", messageID: "<nine@example.com>", uid: 9, clientID: "a"))
        XCTAssertFalse(restores.pendingRestoreSupersedes(nine), "the same message, by Message-ID and UID")

        restores.park(NavState(folder: "INBOX", messageID: "<four@example.com>", uid: 4, clientID: "a"))
        XCTAssertTrue(restores.pendingRestoreSupersedes(nine), "another message")

        restores.park(NavState(folder: "Archive", messageID: "<four@example.com>", uid: 4, clientID: "a"))
        XCTAssertFalse(restores.pendingRestoreSupersedes(nine), "another folder's list takes that one")
    }

    /// Message-ID first, as a scroll restore matches: it survives a move
    /// that renumbers the UID.
    func testTheQueryPrefersTheMessageIDOverTheUID() {
        let restores = WindowRestores()
        restores.park(NavState(folder: "INBOX", messageID: "<nine@example.com>", uid: 9, clientID: "a"))
        XCTAssertFalse(
            restores.pendingRestoreSupersedes(MessageRef(folder: "INBOX", uid: 31, messageId: "<nine@example.com>")),
            "the same message, moved"
        )
        XCTAssertTrue(
            restores.pendingRestoreSupersedes(MessageRef(folder: "INBOX", uid: 9, messageId: "<four@example.com>")),
            "a different message that landed on the UID"
        )
    }

    /// Falls back to the UID where one side carries no Message-ID, which is
    /// every cursor an envelope-less restore came from.
    func testTheQueryFallsBackToTheUID() {
        let restores = WindowRestores()
        restores.park(NavState(folder: "INBOX", uid: 9, clientID: "a"))
        XCTAssertFalse(restores.pendingRestoreSupersedes(MessageRef(folder: "INBOX", uid: 9)))
        XCTAssertFalse(
            restores.pendingRestoreSupersedes(MessageRef(folder: "INBOX", uid: 9, messageId: "<nine@example.com>")),
            "the waiting restore names no Message-ID to disagree with"
        )
        XCTAssertTrue(restores.pendingRestoreSupersedes(MessageRef(folder: "INBOX", uid: 4)))
    }

    /// A restore naming no message at all cannot be read as the same one, so
    /// it stands, exactly as it did before the query existed.
    func testARestoreNamingNoMessageStandsOff() {
        let restores = WindowRestores()
        restores.park(NavState(folder: "INBOX", clientID: "a"))
        XCTAssertTrue(restores.pendingRestoreSupersedes(MessageRef(folder: "INBOX", uid: 9)))
    }
}
