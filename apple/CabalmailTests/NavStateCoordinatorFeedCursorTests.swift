import XCTest
import CabalmailKit
@testable import Cabalmail

/// The coordinator's feed cursor (resume-session plan, Phase C): what an
/// open feed item makes the cross-device cursor, how its reading position
/// follows the scroll capture in both the cursor and the local cache, the
/// launch hold on server writes, and the same-place rule for feed cursors.
@MainActor
final class NavStateCoordinatorFeedCursorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "NavStateCoordinatorFeedCursorTests.\(UUID().uuidString)"
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

    private func makeItem(feedID: String = "feed-1", sortKey: String = "k1") -> RssItem {
        RssItem(feedId: feedID, subscriptionId: "sub-1", itemId: "i1", sortKey: sortKey, title: "T")
    }

    private func capture(_ anchor: String, _ fraction: Double) -> ScrollCapture {
        ScrollCapture(anchor: anchor, isAtTop: false, fraction: fraction)
    }

    func testOpeningAFeedItemMakesTheWorkingCursorAFeedCursor() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFeedScope(.subscription("sub-1"))
        coordinator.recordFeedItem(makeItem(feedID: "f9", sortKey: "k9"))
        let cursor = try XCTUnwrap(coordinator.workingCursor)
        XCTAssertEqual(cursor.kind, NavState.Kind.rss)
        XCTAssertEqual(cursor.rssItem, "f9#k9")
        XCTAssertEqual(cursor.rssScope, "sub:sub-1")
        XCTAssertEqual(cursor.clientID, "this-install")
        XCTAssertNil(cursor.requestBody["folder"])
    }

    func testFeedScrollUpdatesTheCursorAndTheCache() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFeedItem(makeItem(feedID: "f1", sortKey: "k1"))
        coordinator.recordFeedScroll(itemID: "f1#k1", capture: capture("i4.1|-8", 0.37))
        XCTAssertEqual(coordinator.workingCursor?.messageAnchor, "i4.1|-8")
        XCTAssertEqual(coordinator.workingCursor?.messageFraction, 0.37)
        let cached = coordinator.readingPosition(key: ReadingPositionKey.feed(itemID: "f1#k1"))
        XCTAssertEqual(cached?.anchor, "i4.1|-8")
        XCTAssertEqual(cached?.fraction, 0.37)
        // A late capture from another item never lands on this cursor.
        coordinator.recordFeedScroll(itemID: "f2#k2", capture: capture("i9|0", 0.9))
        XCTAssertEqual(coordinator.workingCursor?.messageAnchor, "i4.1|-8")
        // Back at the top: the cursor drops the position.
        coordinator.recordFeedScroll(itemID: "f1#k1", capture: ScrollCapture(anchor: "i0|0", isAtTop: true))
        XCTAssertNil(coordinator.workingCursor?.messageAnchor)
        XCTAssertNil(coordinator.workingCursor?.messageFraction)
    }

    func testReopeningAFeedItemCarriesItsSavedPositionIntoTheCursor() throws {
        let coordinator = try makeCoordinator()
        coordinator.savePosition(key: ReadingPositionKey.feed(itemID: "f1#k1"), anchor: "i2|3", offset: nil,
                                 fraction: 0.6, atTop: false)
        coordinator.recordFeedItem(makeItem(feedID: "f1", sortKey: "k1"))
        XCTAssertEqual(coordinator.workingCursor?.messageAnchor, "i2|3")
        XCTAssertEqual(coordinator.workingCursor?.messageFraction, 0.6)
    }

    func testGoingBackToMailMakesTheCursorMailAgain() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFeedItem(makeItem())
        coordinator.recordFolder("Archive")
        XCTAssertEqual(coordinator.workingCursor?.kind, NavState.Kind.mail)
        XCTAssertEqual(coordinator.workingCursor?.folder, "Archive")
    }

    func testMessageScrollCarriesTheFraction() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordMessage(folderPath: "INBOX", uid: 3, messageID: "<three>")
        coordinator.recordMessageScroll(
            folderPath: "INBOX", uid: 3, messageID: "<three>",
            position: ReadingPosition(anchor: "i5|0", fraction: 0.44), atTop: false
        )
        XCTAssertEqual(coordinator.workingCursor?.messageFraction, 0.44)
        let cached = coordinator.readingPosition(folderPath: "INBOX", uid: 3, messageID: "<three>")
        XCTAssertEqual(cached?.fraction, 0.44)
    }

    func testServerWritesAreHeldUntilTheLaunchProbeReleasesThem() throws {
        let coordinator = try makeCoordinator()
        XCTAssertTrue(coordinator.serverWritesHeld, "held from launch")
        coordinator.releaseServerWrites()
        XCTAssertFalse(coordinator.serverWritesHeld)
        coordinator.releaseServerWrites()
        XCTAssertFalse(coordinator.serverWritesHeld, "idempotent")
    }

    func testFeedCursorMatchesTheFeedSessionItIsAlreadyOn() {
        let cursor = NavState.feed(itemID: "f1#k1", scope: nil, clientID: "other")
        let reading = ResumeSession(section: .feeds, feedScope: .all, feedItemFeedID: "f1", feedItemSortKey: "k1")
        XCTAssertTrue(NavStateCoordinator.cursor(cursor, matches: reading))
        let elsewhere = ResumeSession(section: .feeds, feedItemFeedID: "f2", feedItemSortKey: "k1")
        XCTAssertFalse(NavStateCoordinator.cursor(cursor, matches: elsewhere))
        let inMail = ResumeSession(section: .mail, folder: "INBOX", feedItemFeedID: "f1", feedItemSortKey: "k1")
        XCTAssertFalse(NavStateCoordinator.cursor(cursor, matches: inMail), "a mail session is somewhere else")
    }
}
