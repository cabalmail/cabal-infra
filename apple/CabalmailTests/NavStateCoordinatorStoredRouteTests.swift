import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The coordinator's side of a window's stored route and of a window that
/// does not record: the landing targets read the window's own place before
/// the session's, and a reading position can be kept without the cursor.
@MainActor
final class NavStateCoordinatorStoredRouteTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "NavStateCoordinatorStoredRouteTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCoordinator() throws -> NavStateCoordinator {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    // MARK: Landing targets

    func testAStoredFolderIsTheMailLaunchTargetOverTheSnapshot() throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42))
        let coordinator = try makeCoordinator()
        let stored = AppRoute.Mail(
            folderPath: "Archive", message: MessageRef(folder: "Archive", uid: 7, messageId: "<seven@example.com>")
        )

        let target = coordinator.mailLaunchTarget(stored: stored)

        XCTAssertEqual(target.folderPath, "Archive")
        XCTAssertEqual(target.messageRestore?.folder, "Archive")
        XCTAssertEqual(target.messageRestore?.uid, 7)
        XCTAssertEqual(target.messageRestore?.messageID, "<seven@example.com>")
        XCTAssertNil(target.messageRestore?.uidValidity, "a stored route carries none, as the session does not")
        XCTAssertEqual(target.messageRestore?.clientID, "this-install")
        XCTAssertTrue(coordinator.didConsumeLaunchSession)
    }

    func testAStoredRouteWithNoFolderReadsTheSnapshot() throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42))
        let coordinator = try makeCoordinator()

        let target = coordinator.mailLaunchTarget(stored: AppRoute.Mail())

        XCTAssertEqual(target.folderPath, "Lists")
        XCTAssertEqual(target.messageRestore?.uid, 42)
    }

    /// The test client has no `RssStore`, so a stored scope can't be checked
    /// and degrades to the feed list, as the session's does.
    func testAStoredFeedScopeWithoutAStoreDegrades() async throws {
        store.saveSession(ResumeSession(section: .feeds, feedScope: .all))
        let coordinator = try makeCoordinator()

        let target = await coordinator.consumeFeedsLaunchTarget(stored: AppRoute.Feeds(scope: .subscription("s")))

        XCTAssertNil(target)
        XCTAssertTrue(coordinator.didConsumeLaunchSession)
    }

    // MARK: Positions without the cursor

    func testSavePositionForARefKeepsItWithoutTheCursor() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordMessage(folderPath: "INBOX", uid: 9, messageID: "<nine@example.com>")
        let other = MessageRef(folder: "INBOX", uid: 4, messageId: "<four@example.com>")

        coordinator.savePosition(for: other, position: ReadingPosition(anchor: "i2|0", fraction: 0.2), atTop: false)

        XCTAssertEqual(coordinator.readingPosition(for: other)?.anchor, "i2|0")
        XCTAssertEqual(coordinator.readingPosition(for: other)?.fraction, 0.2)
        XCTAssertEqual(coordinator.workingCursor?.uid, 9)
        XCTAssertNil(coordinator.workingCursor?.messageAnchor)

        coordinator.savePosition(for: other, position: ReadingPosition(anchor: "i0|0"), atTop: true)
        XCTAssertNil(coordinator.readingPosition(for: other), "the top clears it")
    }

    func testAFeedScrollThatDoesNotMoveTheCursorStillSavesThePosition() throws {
        let coordinator = try makeCoordinator()
        let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k")
        coordinator.recordFeedItem(item)

        coordinator.recordFeedScroll(
            itemID: item.id, capture: ScrollCapture(anchor: "p1|0", isAtTop: false, fraction: 0.1), movesCursor: false
        )

        XCTAssertEqual(coordinator.readingPosition(key: ReadingPositionKey.feed(itemID: item.id))?.anchor, "p1|0")
        XCTAssertNil(coordinator.workingCursor?.messageAnchor)
    }
}
