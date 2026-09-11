import XCTest
import CabalmailKit
@testable import Cabalmail

/// The coordinator's local resume layer (`NavStateCoordinator+Session`): what
/// a launch lands on, how navigation is recorded into the session record and
/// the reading-position cache, and what sign-out forgets. The server-cursor
/// paths (network) are out of scope here.
@MainActor
final class NavStateCoordinatorSessionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "NavStateCoordinatorSessionTests.\(UUID().uuidString)"
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

    // MARK: Launch target

    func testMailLaunchTargetDefaultsToInboxWithoutASession() throws {
        let coordinator = try makeCoordinator()
        XCTAssertEqual(coordinator.launchSection, .mail)
        XCTAssertEqual(
            coordinator.mailLaunchTarget(),
            NavStateCoordinator.MailLaunchTarget(folderPath: "INBOX", messageRestore: nil)
        )
    }

    func testMailLaunchTargetReopensSessionFolderAndMessage() throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists.Cabal", uid: 42, messageID: "<m@x>"))
        let coordinator = try makeCoordinator()
        let target = coordinator.mailLaunchTarget()
        XCTAssertEqual(target.folderPath, "Lists.Cabal")
        XCTAssertEqual(target.messageRestore?.folder, "Lists.Cabal")
        XCTAssertEqual(target.messageRestore?.uid, 42)
        XCTAssertEqual(target.messageRestore?.messageID, "<m@x>")
        XCTAssertEqual(target.messageRestore?.clientID, "this-install")
    }

    func testMailLaunchTargetWithoutAMessageHasNoRestore() throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Archive"))
        let coordinator = try makeCoordinator()
        XCTAssertEqual(coordinator.launchSection, .feeds)
        XCTAssertEqual(
            coordinator.mailLaunchTarget(),
            NavStateCoordinator.MailLaunchTarget(folderPath: "Archive", messageRestore: nil)
        )
    }

    /// The test client has no `RssStore`, so a feeds session can't be
    /// verified and degrades to the feed list — and the second call is a
    /// no-op regardless.
    func testFeedsLaunchTargetIsOneShotAndDegradesWithoutAStore() async throws {
        store.saveSession(ResumeSession(section: .feeds, feedScope: .all, feedItemFeedID: "f", feedItemSortKey: "k"))
        let coordinator = try makeCoordinator()
        let first = await coordinator.consumeFeedsLaunchTarget()
        XCTAssertNil(first)
        XCTAssertNil(coordinator.pendingFeedRestore)
        XCTAssertTrue(coordinator.didConsumeFeedsLaunch)
        let second = await coordinator.consumeFeedsLaunchTarget()
        XCTAssertNil(second)
    }

    func testFeedItemRestoreIsConsumedOnlyForItsScope() throws {
        let coordinator = try makeCoordinator()
        let item = makeItem()
        coordinator.pendingFeedRestore = .init(scope: .subscription("sub-1"), item: item)
        XCTAssertNil(coordinator.consumeFeedItemRestore(for: .all))
        XCTAssertEqual(coordinator.consumeFeedItemRestore(for: .subscription("sub-1")), item)
        XCTAssertNil(coordinator.consumeFeedItemRestore(for: .subscription("sub-1")), "one-shot")
    }

    // MARK: Recording

    func testRecordFolderMovesSessionToMailAndClearsMessage() throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "INBOX", uid: 3, messageID: "<old>", feedScope: .all))
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("Archive")
        coordinator.flushSession()
        let saved = store.loadSession()
        XCTAssertEqual(saved?.section, .mail)
        XCTAssertEqual(saved?.folder, "Archive")
        XCTAssertFalse(saved?.hasMessage ?? true)
        XCTAssertEqual(saved?.feedScope, .all, "the feed position is kept for a round trip")
    }

    func testRecordMessageAndNoMessage() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordMessage(folderPath: "INBOX", uid: 9, messageID: "<nine>")
        coordinator.flushSession()
        var saved = store.loadSession()
        XCTAssertEqual(saved?.uid, 9)
        XCTAssertEqual(saved?.messageID, "<nine>")
        coordinator.recordNoMessage(folderPath: "INBOX")
        coordinator.flushSession()
        saved = store.loadSession()
        XCTAssertEqual(saved?.folder, "INBOX")
        XCTAssertFalse(saved?.hasMessage ?? true)
    }

    func testRecordFeedScopeAndItem() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordFeedScope(.folder("fold-1"))
        coordinator.recordFeedItem(makeItem(feedID: "feed-9", sortKey: "sk"))
        coordinator.flushSession()
        var saved = store.loadSession()
        XCTAssertEqual(saved?.section, .feeds)
        XCTAssertEqual(saved?.feedScope, .folder("fold-1"))
        XCTAssertEqual(saved?.feedItemFeedID, "feed-9")
        XCTAssertEqual(saved?.feedItemSortKey, "sk")
        XCTAssertEqual(saved?.folder, "INBOX", "the mail position is kept for a round trip")

        coordinator.recordFeedItem(nil)
        coordinator.flushSession()
        saved = store.loadSession()
        XCTAssertFalse(saved?.hasFeedItem ?? true)
        XCTAssertEqual(saved?.feedScope, .folder("fold-1"))

        // Back to the feed list (compact): scope clears, section stays feeds.
        coordinator.recordFeedScope(nil)
        coordinator.flushSession()
        saved = store.loadSession()
        XCTAssertNil(saved?.feedScope)
        XCTAssertEqual(saved?.section, .feeds)
    }

    func testNoteSectionMovesOnlyTheSection() throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 1, feedScope: .all))
        let coordinator = try makeCoordinator()
        coordinator.noteSection(.feeds)
        coordinator.flushSession()
        let saved = store.loadSession()
        XCTAssertEqual(saved?.section, .feeds)
        XCTAssertEqual(saved?.folder, "Lists")
        XCTAssertEqual(saved?.uid, 1)
        XCTAssertEqual(saved?.feedScope, .all)
    }

    // MARK: Reading positions

    func testSavePositionStoresAndClearsAtTop() throws {
        let coordinator = try makeCoordinator()
        let key = ReadingPositionKey.feed(itemID: "feed-1#k1")
        coordinator.savePosition(key: key, anchor: "i2.0.5|-12", offset: nil, atTop: false)
        XCTAssertEqual(coordinator.readingPosition(key: key)?.anchor, "i2.0.5|-12")
        coordinator.flushSession()
        XCTAssertEqual(store.loadPositions().position(for: key)?.anchor, "i2.0.5|-12")

        coordinator.savePosition(key: key, anchor: "i0|0", offset: nil, atTop: true)
        XCTAssertNil(coordinator.readingPosition(key: key))
        coordinator.flushSession()
        XCTAssertNil(store.loadPositions().position(for: key))
    }

    func testMessageScrollIsCachedOnlyForTheOpenMessage() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordMessage(folderPath: "INBOX", uid: 5, messageID: "<five>")
        // A late capture from a message the user already left is dropped.
        coordinator.recordMessageScroll(
            folderPath: "INBOX", uid: 6, messageID: "<six>", position: ReadingPosition(anchor: "i1|0"), atTop: false
        )
        XCTAssertNil(coordinator.readingPosition(folderPath: "INBOX", uid: 6, messageID: "<six>"))
        coordinator.recordMessageScroll(
            folderPath: "INBOX", uid: 5, messageID: "<five>", position: ReadingPosition(anchor: "i3|-4"), atTop: false
        )
        let same = coordinator.readingPosition(folderPath: "INBOX", uid: 5, messageID: "<five>")
        XCTAssertEqual(same?.anchor, "i3|-4")
        // Keyed by Message-ID, so a lookup from another folder finds it.
        let moved = coordinator.readingPosition(folderPath: "Archive", uid: 99, messageID: "<five>")
        XCTAssertEqual(moved?.anchor, "i3|-4")
    }

    func testPlainTextOffsetRoundTrips() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordMessage(folderPath: "INBOX", uid: 2, messageID: nil)
        coordinator.recordMessageScroll(
            folderPath: "INBOX", uid: 2, messageID: nil, position: ReadingPosition(offset: 640), atTop: false
        )
        let position = coordinator.readingPosition(folderPath: "INBOX", uid: 2, messageID: nil)
        XCTAssertEqual(position?.offset, 640)
        XCTAssertNil(position?.anchor)
    }

    // MARK: Sign-out

    func testClearLocalStateForgetsEverything() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("Archive")
        coordinator.savePosition(key: "feed:x", anchor: "i1|0", offset: nil, atTop: false)
        coordinator.lastSeenUpdatedAt = 1_700_000_000_000
        coordinator.flushSession()
        XCTAssertNotNil(store.loadSession())
        coordinator.clearLocalState()
        XCTAssertNil(store.loadSession())
        XCTAssertEqual(store.loadPositions().count, 0)
        XCTAssertEqual(store.offeredForeignUpdatedAt, 0)
        XCTAssertNil(coordinator.readingPosition(key: "feed:x"))
        XCTAssertEqual(coordinator.mailLaunchTarget().folderPath, "INBOX")
    }

    // MARK: Same-place checks

    func testCursorMatchesSessionPosition() {
        let session = ResumeSession(section: .mail, folder: "Lists", uid: 7, messageID: "<seven>")
        XCTAssertTrue(NavStateCoordinator.cursor(
            NavState(folder: "Lists", messageID: "<seven>", uid: 999, clientID: "other"), matches: session
        ), "Message-ID wins over a differing UID")
        XCTAssertTrue(NavStateCoordinator.cursor(
            NavState(folder: "Lists", uid: 7, clientID: "other"), matches: session
        ), "UID when the cursor carries no Message-ID")
        XCTAssertFalse(NavStateCoordinator.cursor(
            NavState(folder: "Lists", messageID: "<eight>", clientID: "other"), matches: session
        ))
        XCTAssertFalse(NavStateCoordinator.cursor(
            NavState(folder: "Lists", clientID: "other"), matches: session
        ), "a folder-only cursor is a different place from an open message")
        XCTAssertFalse(NavStateCoordinator.cursor(
            NavState(folder: "INBOX", messageID: "<seven>", clientID: "other"), matches: session
        ))
        XCTAssertTrue(NavStateCoordinator.cursor(
            NavState(folder: "Archive", clientID: "other"),
            matches: ResumeSession(section: .mail, folder: "Archive")
        ), "folder-only on both sides")
        XCTAssertFalse(NavStateCoordinator.cursor(
            NavState(folder: "Lists", uid: 7, clientID: "other"),
            matches: ResumeSession(section: .feeds, folder: "Lists", uid: 7)
        ), "a feeds session restores the feed reader, not this message")
        XCTAssertFalse(NavStateCoordinator.cursor(NavState(folder: "INBOX", clientID: "o"), matches: nil))
    }

    /// The persisted "already offered" watermark seeds the coordinator so an
    /// ignored cross-device toast doesn't come back on the next launch.
    func testOfferedForeignWatermarkPersistsAcrossCoordinators() throws {
        let first = try makeCoordinator()
        first.lastSeenUpdatedAt = 1_719_600_000_000
        let second = try makeCoordinator()
        XCTAssertEqual(second.lastSeenUpdatedAt, 1_719_600_000_000)
    }
}
