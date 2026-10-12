import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A window keeps where its folder list is scrolled (`FolderListHold`): a
/// layout swap parks the place for the list the new layout builds, which
/// takes it once; a folder change and a back-out drop what was parked; and
/// a list from the tree a swap is tearing down can neither record nor take.
@MainActor
final class SceneNavigatorListPlaceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorListPlaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

    /// A compact window landed on INBOX, and the tree that landed it.
    private func landed() async throws -> (navigator: SceneNavigator, tree: UUID) {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        let coordinator = NavStateCoordinator(client: client, clientID: "this-install", store: store)
        let navigator = SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: .mail)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: false)
        navigator.foldersLoaded([inbox, archive])
        return (navigator, tree)
    }

    private func place(_ index: Int, in folder: String = "INBOX") throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: folder, messageID: "<row\(index)@example.com>", uid: UInt32(5000 - index), index: index
        ))
    }

    /// A list mounted on `folder` that has scrolled to `index`.
    @discardableResult
    private func scrolledList(
        _ navigator: SceneNavigator, to index: Int, in folder: String = "INBOX"
    ) throws -> FolderListHold.Claim {
        let claim = navigator.listHold.claim(folder, isWide: false)
        XCTAssertTrue(navigator.listHold.record(try place(index, in: folder), under: claim))
        return claim
    }

    // MARK: A layout swap

    func testASwapParksThePlaceForTheNewListWhichTakesItOnce() async throws {
        let (navigator, _) = try await landed()
        try scrolledList(navigator, to: 300)

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300))
        let newList = navigator.listHold.claim("INBOX", isWide: true)
        XCTAssertEqual(navigator.listHold.takeAnchor(under: newList, from: navigator.restores), try place(300))
        XCTAssertNil(navigator.restores.pendingListAnchor, "taken once")
    }

    /// The old tree's list is still being torn down when the new one mounts:
    /// its scroll view going away must not record the top, nor take the
    /// anchor parked for its successor.
    func testAStaleListCanNeitherRecordNorTakeAfterASwap() async throws {
        let (navigator, _) = try await landed()
        let oldList = try scrolledList(navigator, to: 300)

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertFalse(navigator.listHold.holds(oldList))
        XCTAssertFalse(navigator.listHold.record(nil, under: oldList))
        XCTAssertFalse(navigator.listHold.record(try place(2), under: oldList))
        XCTAssertNil(navigator.listHold.takeAnchor(under: oldList, from: navigator.restores))
        XCTAssertEqual(navigator.listHold.place, try place(300))
        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300), "still parked for the new list")
    }

    /// A newer list's claim voids an older one in the same tree too: the
    /// folder's list replaced by a search and coming back.
    func testANewerListsClaimVoidsTheOlderOne() async throws {
        let (navigator, _) = try await landed()
        let first = try scrolledList(navigator, to: 40)

        let second = navigator.listHold.claim("INBOX", isWide: false)

        XCTAssertFalse(navigator.listHold.record(nil, under: first))
        XCTAssertEqual(navigator.listHold.takeAnchor(under: second, from: navigator.restores), try place(40))
    }

    /// Two swaps before the new list lands (a fold and an unfold in quick
    /// succession): the place the window had is parked again, not lost.
    func testTwoSwapsBeforeTheNewListLandsKeepTheFirstPlace() async throws {
        let (navigator, _) = try await landed()
        try scrolledList(navigator, to: 300)

        await navigator.mailTreeAppeared(UUID(), isWide: true)
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        let list = navigator.listHold.claim("INBOX", isWide: false)
        XCTAssertEqual(navigator.listHold.takeAnchor(under: list, from: navigator.restores), try place(300))
    }

    func testTheSameTreeReappearingParksNothing() async throws {
        let (navigator, tree) = try await landed()
        let list = try scrolledList(navigator, to: 300)

        await navigator.mailTreeAppeared(tree, isWide: false)

        XCTAssertNil(navigator.restores.pendingListAnchor)
        XCTAssertTrue(navigator.listHold.holds(list), "the list is the same one")
    }

    /// A fold while reading: the open message is re-parked for the new list
    /// to select, and the list's place beside it.
    func testASwapWithAnOpenMessageParksBoth() async throws {
        let (navigator, tree) = try await landed()
        try scrolledList(navigator, to: 300)
        navigator.selectMessage(message, isSearching: false, from: tree)

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 9)
        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300))
    }

    // MARK: What drops it

    func testAFolderChangeDropsTheParkedAnchorAndThePlace() async throws {
        let (navigator, _) = try await landed()
        try scrolledList(navigator, to: 300)
        await navigator.mailTreeAppeared(UUID(), isWide: true)

        navigator.selectFolder(archive)

        XCTAssertNil(navigator.restores.pendingListAnchor)
        XCTAssertNil(navigator.listHold.place, "the place was the other folder's")
        navigator.selectFolder(inbox)
        let list = navigator.listHold.claim("INBOX", isWide: true)
        XCTAssertNil(navigator.listHold.takeAnchor(under: list, from: navigator.restores))
    }

    /// The list a folder change leaves behind is still being torn down when
    /// the window has moved on: it cannot write its folder's place back.
    func testAListLeftBehindByAFolderChangeRecordsNothing() async throws {
        let (navigator, _) = try await landed()
        let oldList = try scrolledList(navigator, to: 300)

        navigator.selectFolder(archive)

        XCTAssertFalse(navigator.listHold.record(try place(40), under: oldList))
        XCTAssertNil(navigator.listHold.place)
    }

    /// Backing out to the folder list drops what was parked and voids the
    /// list's claim; the place stays for the same folder picked again.
    func testABackOutDropsTheParkedAnchorAndKeepsThePlace() async throws {
        let (navigator, tree) = try await landed()
        let list = try scrolledList(navigator, to: 300)
        navigator.restores.parkListAnchor(try place(12))

        navigator.setCompactColumn(.sidebar, isSearching: false, from: tree)

        XCTAssertNil(navigator.restores.pendingListAnchor)
        XCTAssertFalse(navigator.listHold.holds(list))
        let again = navigator.listHold.claim("INBOX", isWide: false)
        XCTAssertEqual(navigator.listHold.takeAnchor(under: again, from: navigator.restores), try place(300))
    }

    /// A deep link says where to be: it drops an anchor parked for any
    /// folder, its own included.
    func testADeepLinkDropsAnyParkedAnchor() async throws {
        let (navigator, _) = try await landed()
        navigator.restores.parkListAnchor(try place(300))

        navigator.navigate(to: NavState(folder: "INBOX", uid: 9, clientID: "push"))

        XCTAssertNil(navigator.restores.pendingListAnchor)
    }

    // MARK: Matching

    func testAParkedAnchorIsForItsFolderExactly() async throws {
        let (navigator, _) = try await landed()
        navigator.restores.parkListAnchor(try place(300, in: "inbox"))

        XCTAssertNil(navigator.restores.consumeListAnchor(for: "INBOX"))
        XCTAssertNotNil(navigator.restores.pendingListAnchor, "left for its own folder's list")
        XCTAssertEqual(navigator.restores.consumeListAnchor(for: "inbox"), try place(300, in: "inbox"))
        XCTAssertNil(navigator.restores.consumeListAnchor(for: "inbox"), "taken once")
    }

    /// The place is one folder's: a list of another folder takes nothing
    /// from it.
    func testAListOfAnotherFolderTakesNoPlace() async throws {
        let (navigator, _) = try await landed()
        try scrolledList(navigator, to: 300)

        let other = navigator.listHold.claim("Archive", isWide: false)

        XCTAssertNil(navigator.listHold.takeAnchor(under: other, from: navigator.restores))
        XCTAssertEqual(navigator.listHold.place, try place(300), "left for its own folder")
    }

    func testAListRecordsOnlyItsOwnFoldersPlace() async throws {
        let (navigator, _) = try await landed()
        let list = navigator.listHold.claim("INBOX", isWide: false)

        XCTAssertFalse(navigator.listHold.record(try place(4, in: "Archive"), under: list))
        XCTAssertNil(navigator.listHold.place)
        XCTAssertTrue(navigator.listHold.record(try place(4), under: list))
        XCTAssertFalse(navigator.listHold.record(try place(4), under: list), "no change")
        XCTAssertTrue(navigator.listHold.record(nil, under: list), "back at the top")
        XCTAssertNil(navigator.listHold.place)
    }

    /// Dropping the list's anchor leaves a message restore parked beside it.
    func testDroppingTheAnchorLeavesTheMessageRestore() async throws {
        let (navigator, _) = try await landed()
        navigator.restores.park(NavState(folder: "INBOX", uid: 9, clientID: "push"))
        navigator.restores.parkListAnchor(try place(300))

        navigator.restores.dropListAnchor()

        XCTAssertNil(navigator.restores.pendingListAnchor)
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 9)
    }

    /// A landing that moves to a folder keeps an anchor already parked for
    /// that folder, and drops one parked for another.
    func testMovingToAFolderKeepsTheAnchorParkedForIt() async throws {
        let (navigator, _) = try await landed()
        navigator.restores.parkListAnchor(try place(300, in: "Archive"))

        navigator.selectFolder(archive)

        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300, in: "Archive"))
        navigator.restores.parkListAnchor(try place(7, in: "Archive"))
        navigator.selectFolder(inbox)
        XCTAssertNil(navigator.restores.pendingListAnchor)
    }

    // MARK: Windows

    func testTwoWindowsOnOneFolderKeepTheirOwnPlaces() async throws {
        let (first, _) = try await landed()
        let (second, _) = try await landed()
        try scrolledList(first, to: 300)
        try scrolledList(second, to: 30)

        await first.mailTreeAppeared(UUID(), isWide: true)
        await second.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(first.restores.pendingListAnchor, try place(300))
        XCTAssertEqual(second.restores.pendingListAnchor, try place(30))
    }
}
