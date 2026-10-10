import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A window that becomes the one the user last used records where it is
/// once (`WindowRecorder.handOver`), so the per-install session and the
/// server cursor move to it: the folder and message it has open, and its
/// feed list and item. A place it holds only in its stored route, which it
/// has not opened this run, is left as the session has it.
@MainActor
final class SceneNavigatorHandOverTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorHandOverTests.\(UUID().uuidString)"
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

    func testTheWindowThatBecomesLastUsedRecordsItsRouteOnce() async throws {
        let coordinator = try makeCoordinator()
        let (first, _) = await window(coordinator)
        let (second, secondTree) = await window(coordinator)
        lastUsed.window = first.windowID
        second.selectFolder(archive)
        second.selectMessage(four, isSearching: false, from: secondTree)
        XCTAssertEqual(coordinator.session.folder, "INBOX", "precondition: not recorded")

        lastUsed.window = second.windowID
        second.becameLastUsed()

        XCTAssertEqual(coordinator.session.section, .mail)
        XCTAssertEqual(coordinator.session.folder, "Archive")
        XCTAssertEqual(coordinator.session.uid, 4)
        XCTAssertEqual(coordinator.workingCursor?.folder, "Archive")
        XCTAssertEqual(coordinator.workingCursor?.uid, 4)

        first.selectFolder(inbox)
        XCTAssertEqual(coordinator.session.folder, "Archive", "the first window no longer records")
    }

    /// A window that is not the one named does nothing when asked.
    func testOnlyTheWindowNamedHandsOver() async throws {
        let coordinator = try makeCoordinator()
        let (first, _) = await window(coordinator)
        let (second, _) = await window(coordinator)
        lastUsed.window = first.windowID
        second.selectFolder(archive)

        second.becameLastUsed()

        XCTAssertEqual(coordinator.session.folder, "INBOX")
    }

    /// The section the window is in goes last, so the session and the
    /// cursor's kind end on it; the other half is recorded too.
    func testTheHandOverEndsOnTheWindowsSection() async throws {
        let coordinator = try makeCoordinator()
        let (first, _) = await window(coordinator)
        let (second, _) = await window(coordinator)
        lastUsed.window = first.windowID
        second.selectFolder(archive)
        second.showTab(.feeds)
        let feedTree = UUID()
        await second.feedTreeAppeared(feedTree)
        second.selectFeedScope(.subscription("s"))
        second.selectFeedItem(item, from: feedTree)

        lastUsed.window = second.windowID
        second.becameLastUsed()

        XCTAssertEqual(coordinator.session.section, .feeds)
        XCTAssertEqual(coordinator.session.folder, "Archive")
        XCTAssertEqual(coordinator.session.feedScope, .subscription("s"))
        XCTAssertEqual(coordinator.session.feedItemSortKey, "k")
        XCTAssertEqual(coordinator.workingCursor?.kind, .rss)
    }

    /// A window that has not shown mail (visionOS opening on its Feeds tab)
    /// leaves the session's folder alone, as its quiet landing does.
    func testTheHandOverSkipsMailTheWindowHasNotShown() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "INBOX", feedScope: .all))
        let coordinator = try makeCoordinator()
        let (first, _) = await window(coordinator, seed: .feeds)
        lastUsed.window = UUID()
        coordinator.recordFolder("Lists")

        lastUsed.window = first.windowID
        first.becameLastUsed()

        XCTAssertEqual(coordinator.session.folder, "Lists")
        XCTAssertEqual(coordinator.session.section, .feeds)
    }

    /// A restored window on Mail holds a feed place only in its stored route:
    /// it has not opened that list, so the hand-over leaves the session's
    /// feed scope and item, rather than recording the scope without its item.
    func testTheHandOverLeavesAFeedPlaceTheWindowHasNotOpened() async throws {
        let coordinator = try makeCoordinator()
        let (first, _) = await window(coordinator)
        lastUsed.window = first.windowID
        coordinator.recordFeedScope(.all)
        coordinator.recordFeedItem(item)
        coordinator.recordFolder("INBOX")
        var stored = AppRoute(section: .mail)
        stored.mail = AppRoute.Mail(folderPath: "Archive")
        stored.feeds = AppRoute.Feeds(scope: .subscription("other"))
        let lastUsed = lastUsed
        let restored = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .mail, storedRoute: stored,
            lastUsedWindow: { lastUsed.window }, feedsLaunchTarget: { _, _ in nil }
        )
        restored.windowID = UUID()
        await restored.mailTreeAppeared(UUID(), isWide: false)
        restored.foldersLoaded([inbox, archive])

        lastUsed.window = restored.windowID
        restored.becameLastUsed()

        XCTAssertEqual(coordinator.session.folder, "Archive")
        XCTAssertEqual(coordinator.session.feedScope, .all)
        XCTAssertEqual(coordinator.session.feedItemSortKey, "k")
    }

    /// A wide window restored into feeds has not opened the folder its stored
    /// route names, so the hand-over does not record it, and the cursor is
    /// not moved to a message no window has open.
    func testTheHandOverLeavesAMailPlaceTheWindowHasNotOpened() async throws {
        let coordinator = try makeCoordinator()
        let (first, _) = await window(coordinator)
        lastUsed.window = first.windowID
        var stored = AppRoute(section: .feeds)
        stored.mail = AppRoute.Mail(folderPath: "Archive", message: MessageRef(folder: "Archive", uid: 7))
        stored.feeds = AppRoute.Feeds(scope: .subscription("s"))
        let lastUsed = lastUsed
        let restored = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds, storedRoute: stored,
            lastUsedWindow: { lastUsed.window },
            feedsLaunchTarget: { _, feeds in feeds.scope.map { .init(scope: $0) } }
        )
        restored.windowID = UUID()
        await restored.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertTrue(restored.splitShowsFeeds, "precondition")

        lastUsed.window = restored.windowID
        restored.becameLastUsed()

        XCTAssertEqual(coordinator.session.folder, "INBOX")
        XCTAssertNil(coordinator.session.uid)
        XCTAssertEqual(coordinator.session.feedScope, .subscription("s"))
        XCTAssertEqual(coordinator.session.section, .feeds)
        XCTAssertNotEqual(coordinator.workingCursor?.folder, "Archive")
    }

    /// The hand-over puts the message's saved reading position back on the
    /// cursor, as reopening a feed item does.
    func testTheHandOverCarriesTheSavedReadingPositionIntoTheCursor() async throws {
        let coordinator = try makeCoordinator()
        let (first, _) = await window(coordinator)
        let (second, secondTree) = await window(coordinator)
        lastUsed.window = first.windowID
        second.selectMessage(four, isSearching: false, from: secondTree)
        let fourRef = MessageRef(folder: "INBOX", uid: 4, messageId: "<four@example.com>")
        second.recordMessageScroll(fourRef, position: ReadingPosition(anchor: "i7|0", fraction: 0.7), atTop: false)

        lastUsed.window = second.windowID
        second.becameLastUsed()

        XCTAssertEqual(coordinator.workingCursor?.uid, 4)
        XCTAssertEqual(coordinator.workingCursor?.messageAnchor, "i7|0")
        XCTAssertEqual(coordinator.workingCursor?.messageFraction, 0.7)
    }
}
