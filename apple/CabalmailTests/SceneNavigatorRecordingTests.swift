import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Only the window the user last used records the place the app resumes
/// from (`WindowRecorder`): the per-install session and the server cursor.
/// Every window still keeps reading positions. A window that becomes the
/// one last used records where it is once (`SceneNavigatorHandOverTests`).
@MainActor
final class SceneNavigatorRecordingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorRecordingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// `AppState.lastActiveMainWindow`, as the windows read it.
    @MainActor
    private final class LastUsed {
        var window: UUID?
    }

    private let lastUsed = LastUsed()
    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let nine = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")
    private let four = TestFixtures.makeEnvelope(uid: 4, messageId: "<four@example.com>")
    private let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k")

    private func makeCoordinator() throws -> NavStateCoordinator {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    /// A window with its own identity that has landed on INBOX with the
    /// folder list loaded, and the tree that landed it.
    private func window(
        _ coordinator: NavStateCoordinator, seed: ResumeSession.Section = .mail, isWide: Bool = false
    ) async -> (navigator: SceneNavigator, tree: UUID) {
        let lastUsed = lastUsed
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: seed,
            lastUsedWindow: { lastUsed.window }, feedsLaunchTarget: { _, _ in nil }
        )
        navigator.windowID = UUID()
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: isWide)
        navigator.foldersLoaded([inbox, archive])
        _ = navigator.restores.consumePendingRestore(for: "INBOX")
        return (navigator, tree)
    }

    // MARK: The gate

    func testOnlyTheWindowLastUsedRecords() async throws {
        let coordinator = try makeCoordinator()
        let (used, usedTree) = await window(coordinator)
        let (other, otherTree) = await window(coordinator)
        lastUsed.window = used.windowID
        used.selectMessage(nine, isSearching: false, from: usedTree)

        other.selectFolder(archive)
        other.selectMessage(four, isSearching: false, from: otherTree)
        other.showTab(.feeds)
        other.selectFeedScope(.all)

        XCTAssertEqual(coordinator.session.section, .mail)
        XCTAssertEqual(coordinator.session.folder, "INBOX")
        XCTAssertEqual(coordinator.session.uid, 9)
        XCTAssertNil(coordinator.session.feedScope)
        XCTAssertEqual(coordinator.workingCursor?.folder, "INBOX")
        XCTAssertEqual(coordinator.workingCursor?.uid, 9)
        XCTAssertEqual(other.route.mail.message?.uid, 4, "the window itself still moves")

        used.selectFolder(archive)
        XCTAssertEqual(coordinator.session.folder, "Archive", "the window last used records")
    }

    func testWithNoWindowRecordedEveryWindowRecords() async throws {
        let coordinator = try makeCoordinator()
        let (first, _) = await window(coordinator)
        let (second, secondTree) = await window(coordinator)
        XCTAssertNil(lastUsed.window)

        second.selectMessage(four, isSearching: false, from: secondTree)
        XCTAssertEqual(coordinator.session.uid, 4)

        first.selectFolder(archive)
        XCTAssertEqual(coordinator.session.folder, "Archive")
    }

    /// A window that has no identity yet does not record while another is
    /// the one last used.
    func testAWindowWithNoIDDoesNotRecordWhileAnotherIsLastUsed() async throws {
        let coordinator = try makeCoordinator()
        let (used, _) = await window(coordinator)
        let (other, _) = await window(coordinator)
        lastUsed.window = used.windowID
        other.windowID = nil

        other.selectFolder(archive)

        XCTAssertEqual(coordinator.session.folder, "INBOX")
    }

    /// A navigation in a window that does not record parks its message for
    /// that window's list without priming the cursor the window last used
    /// keeps, UIDVALIDITY included (#1873).
    func testAWindowNotLastUsedDoesNotPrimeTheCursor() async throws {
        let coordinator = try makeCoordinator()
        let (used, _) = await window(coordinator)
        let (other, _) = await window(coordinator)
        lastUsed.window = used.windowID
        used.navigate(to: NavState(folder: "INBOX", uid: 9, uidValidity: 77, clientID: "phone"))

        other.navigate(to: NavState(folder: "Archive", uid: 4, uidValidity: 12, messageScroll: 300, clientID: "push"))

        XCTAssertEqual(other.restores.pendingRestore?.uid, 4, "the window still opens it")
        XCTAssertEqual(coordinator.workingCursor?.folder, "INBOX")
        XCTAssertEqual(coordinator.workingCursor?.uid, 9)
        XCTAssertEqual(coordinator.workingCursor?.uidValidity, 77)
        XCTAssertNil(coordinator.workingCursor?.messageScroll)
    }

    // MARK: Reading positions

    func testReadingPositionsRecordFromEveryWindow() async throws {
        let coordinator = try makeCoordinator()
        let (used, usedTree) = await window(coordinator)
        let (other, otherTree) = await window(coordinator)
        lastUsed.window = used.windowID
        used.selectMessage(nine, isSearching: false, from: usedTree)
        other.selectMessage(four, isSearching: false, from: otherTree)
        let fourRef = MessageRef(folder: "INBOX", uid: 4, messageId: "<four@example.com>")

        other.recordMessageScroll(fourRef, position: ReadingPosition(anchor: "i2|0", fraction: 0.4), atTop: false)

        XCTAssertEqual(coordinator.readingPosition(for: fourRef)?.anchor, "i2|0", "the position is the message's")
        XCTAssertEqual(coordinator.workingCursor?.uid, 9, "the cursor stays with the window last used")
        XCTAssertNil(coordinator.workingCursor?.messageAnchor)

        let elsewhere = MessageRef(folder: "INBOX", uid: 2)
        other.recordMessageScroll(elsewhere, position: ReadingPosition(anchor: "i1|0"), atTop: false)
        XCTAssertNil(coordinator.readingPosition(for: elsewhere), "only the message open in the window")

        let nineRef = MessageRef(folder: "INBOX", uid: 9, messageId: "<nine@example.com>")
        used.recordMessageScroll(nineRef, position: ReadingPosition(anchor: "i5|0", fraction: 0.6), atTop: false)
        XCTAssertEqual(coordinator.workingCursor?.messageAnchor, "i5|0")
        XCTAssertEqual(coordinator.readingPosition(for: nineRef)?.anchor, "i5|0")
    }

    func testAFeedScrollFromAnotherWindowKeepsOnlyThePosition() async throws {
        let coordinator = try makeCoordinator()
        let (used, _) = await window(coordinator)
        let (other, _) = await window(coordinator)
        lastUsed.window = used.windowID
        coordinator.recordFeedItem(item)
        let capture = ScrollCapture(anchor: "p3|0", isAtTop: false, fraction: 0.3)

        other.recordFeedScroll(itemID: item.id, capture: capture)

        XCTAssertEqual(coordinator.readingPosition(key: ReadingPositionKey.feed(itemID: item.id))?.anchor, "p3|0")
        XCTAssertNil(coordinator.workingCursor?.messageAnchor, "the feed cursor did not move")

        used.recordFeedScroll(itemID: item.id, capture: capture)
        XCTAssertEqual(coordinator.workingCursor?.messageAnchor, "p3|0")
    }

    // MARK: The window's identity

    /// A navigator built for a new client keeps the window's identity, so a
    /// sign-in over a wired session does not leave the window unable to
    /// record.
    func testANavigatorBuiltForAWindowKeepsItsIdentity() {
        let appState = AppState()
        let id = UUID()

        let navigator = SceneNavigator(appState: appState, windowID: id)

        XCTAssertEqual(navigator.windowID, id)
        XCTAssertEqual(navigator.recorder.windowID, id)
    }
}
