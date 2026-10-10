import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Each main window parks its own restores (`WindowRestores`): the message
/// its folder list selects, the reading position its reader opens at, and
/// the feed item its feed list selects. Before, the three were one slot per
/// install, and any mounted list or reader on the same folder or scope took
/// them, so with two windows on one folder a Resume, a notification or a
/// layout swap's re-park could open in the other window (#1987).
@MainActor
final class SceneNavigatorWindowRestoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorWindowRestoreTests.\(UUID().uuidString)"
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

    private func makeNavigator(_ coordinator: NavStateCoordinator) -> SceneNavigator {
        SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: store.loadSession()?.section)
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let nine = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")
    private let four = TestFixtures.makeEnvelope(uid: 4, messageId: "<four@example.com>")

    /// A window that has landed on INBOX with the folder list loaded, and the
    /// tree that landed it.
    private func landed(
        _ coordinator: NavStateCoordinator, isWide: Bool = false
    ) async -> (navigator: SceneNavigator, tree: UUID) {
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: isWide)
        navigator.foldersLoaded([inbox, archive])
        _ = navigator.restores.consumePendingRestore(for: "INBOX")
        return (navigator, tree)
    }

    // MARK: Mail

    /// #1987: Resume tapped in one of two windows on INBOX parks its message
    /// for that window's list only. The other window's list finds nothing.
    func testTwoWindowsOnOneFolderEachKeepTheirOwnParkedRestore() async throws {
        let coordinator = try makeCoordinator()
        let (tapped, _) = await landed(coordinator, isWide: true)
        let other = (await landed(coordinator, isWide: true)).navigator

        tapped.navigate(to: NavState(folder: "INBOX", messageID: "<seven@example.com>", uid: 7, clientID: "phone"))

        XCTAssertNil(other.restores.pendingRestore)
        XCTAssertNil(other.restores.consumePendingRestore(for: "INBOX"), "the other window's list takes nothing")
        XCTAssertEqual(tapped.restores.consumePendingRestore(for: "INBOX")?.uid, 7)

        other.navigate(to: NavState(folder: "INBOX", uid: 3, clientID: "push"))
        XCTAssertNil(tapped.restores.pendingRestore, "and the other way round")
        XCTAssertEqual(other.restores.pendingRestore?.uid, 3)
    }

    /// A position the cursor carried goes to the reader of the window that
    /// took the cursor, not to another window opening the same message.
    func testAReadingPositionGoesOnlyToTheWindowThatNavigated() async throws {
        let coordinator = try makeCoordinator()
        let (tapped, _) = await landed(coordinator)
        let other = (await landed(coordinator)).navigator
        let ref = MessageRef(folder: "INBOX", uid: 7, messageId: "<seven@example.com>")

        tapped.navigate(to: NavState(
            folder: "INBOX", messageID: "<seven@example.com>", uid: 7, messageScroll: 640, clientID: "phone"
        ))

        XCTAssertNil(other.restores.consumeScrollRestore(for: ref))
        XCTAssertEqual(tapped.restores.consumeScrollRestore(for: ref)?.offset, 640)
    }

    /// Two windows rebuilt in one pass (an iPad with two windows crossing
    /// the size-class line together) each re-park their own open message.
    /// With one slot per install the second re-park replaced the first, so
    /// one window lost its message (#1965's known limits).
    func testTwoWindowsRebuiltInOnePassEachKeepTheirOwnMessage() async throws {
        let coordinator = try makeCoordinator()
        let (first, firstTree) = await landed(coordinator)
        let (second, secondTree) = await landed(coordinator)
        first.selectMessage(nine, isSearching: false, from: firstTree)
        second.selectMessage(four, isSearching: false, from: secondTree)

        await first.mailTreeAppeared(UUID(), isWide: true)
        await second.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(first.restores.pendingRestore?.uid, 9)
        XCTAssertEqual(first.restores.pendingRestore?.messageID, "<nine@example.com>")
        XCTAssertEqual(second.restores.pendingRestore?.uid, 4)
        XCTAssertEqual(second.restores.pendingRestore?.messageID, "<four@example.com>")
        XCTAssertEqual(first.restores.consumePendingRestore(for: "INBOX")?.uid, 9)
        XCTAssertEqual(second.restores.consumePendingRestore(for: "INBOX")?.uid, 4, "taking one leaves the other")
    }

    /// #1966: a window opened after a notification launch lands where the
    /// notification took the user, not on the launch snapshot that the
    /// navigation superseded.
    func testAWindowOpenedAfterANavigationLandsWhereTheUserWent() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42, messageID: "<42@example.com>"))
        let coordinator = try makeCoordinator()
        coordinator.navigateRequest = NavState(folder: "Archive", uid: 7, clientID: "push")
        let first = makeNavigator(coordinator)
        await first.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertEqual(first.selectedFolder?.path, "Archive", "precondition: the tap was the landing")
        XCTAssertTrue(coordinator.didConsumeLaunchSession)

        let second = makeNavigator(coordinator)
        await second.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(second.selectedFolder?.path, "Archive")
        XCTAssertNil(second.restores.pendingRestore, "not the snapshot's Lists message")
        XCTAssertEqual(first.restores.pendingRestore?.uid, 7, "the first window keeps its own")
    }

    /// The same holds for a navigation after the launch landed: Resume, or a
    /// notification tapped while the app runs.
    func testANavigationEndsTheLaunchSnapshotForLaterWindows() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42))
        let coordinator = try makeCoordinator()
        let first = makeNavigator(coordinator)
        first.navigate(to: NavState(folder: "Archive", uid: 7, clientID: "phone"))

        XCTAssertTrue(coordinator.didConsumeLaunchSession)
        XCTAssertEqual(coordinator.mailLaunchTarget().folderPath, "Archive")
    }

    // MARK: Feeds

    private let launchItem = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k")

    /// The feed item that was open when the app last ran comes back with its
    /// scope from the launch lookup, and the landing parks it in the window
    /// for the scope's list to select once loaded (#1664): on the compact
    /// Feeds tab, and on a wide landing in feeds.
    func testAFeedLaunchLandingParksItsItemInTheWindow() async throws {
        store.saveSession(ResumeSession(section: .feeds, feedScope: .subscription("s")))
        let coordinator = try makeCoordinator()
        let launchItem = launchItem
        let compact = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds,
            feedsLaunchTarget: { _ in .init(scope: .subscription("s"), item: launchItem) }
        )
        await compact.feedTreeAppeared(UUID())
        XCTAssertEqual(
            compact.restores.pendingFeedRestore,
            WindowRestores.PendingFeedRestore(scope: .subscription("s"), item: launchItem)
        )

        let wide = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds,
            feedsLaunchTarget: { _ in .init(scope: .subscription("s"), item: launchItem) }
        )
        await wide.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertTrue(wide.splitShowsFeeds)
        XCTAssertEqual(
            wide.restores.pendingFeedRestore,
            WindowRestores.PendingFeedRestore(scope: .subscription("s"), item: launchItem)
        )
    }

    /// A feed item parked in a window goes to that window's list for its
    /// scope, once.
    func testAParkedFeedItemIsConsumedOnlyForItsScope() {
        let restores = WindowRestores()
        let item = RssItem(feedId: "feed-1", subscriptionId: "sub-1", itemId: "i1", sortKey: "k1", title: "T")
        restores.pendingFeedRestore = .init(scope: .subscription("sub-1"), item: item)
        XCTAssertNil(restores.consumeFeedItemRestore(for: .all))
        XCTAssertEqual(restores.consumeFeedItemRestore(for: .subscription("sub-1")), item)
        XCTAssertNil(restores.consumeFeedItemRestore(for: .subscription("sub-1")), "one-shot")
    }

    /// A tapped feed banner parks its item in the tapped window only; a list
    /// on the same scope in another window is left alone.
    func testAFeedBannerParksItsItemOnlyInTheTappedWindow() throws {
        let coordinator = try makeCoordinator()
        let tapped = makeNavigator(coordinator)
        let other = makeNavigator(coordinator)
        let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k")

        tapped.navigateFeeds(to: .init(scope: .subscription("s"), item: item))

        XCTAssertEqual(
            tapped.restores.pendingFeedRestore, WindowRestores.PendingFeedRestore(scope: .subscription("s"), item: item)
        )
        XCTAssertNil(other.restores.pendingFeedRestore)
        XCTAssertNil(other.restores.consumeFeedItemRestore(for: .subscription("s")))
    }
}
