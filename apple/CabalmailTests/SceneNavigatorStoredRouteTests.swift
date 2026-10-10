import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A window's first landing with a route from its scene storage
/// (`StoredRoute`): a parked deep link first, then the window's own route,
/// then the launch snapshot for the process's first landing and the live
/// session after it (#1555). A stored folder that is gone falls back to
/// INBOX without its message.
@MainActor
final class SceneNavigatorStoredRouteTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorStoredRouteTests.\(UUID().uuidString)"
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

    private func makeNavigator(
        _ coordinator: NavStateCoordinator, stored: AppRoute?, hasClient: Bool = true,
        feeds: @escaping @MainActor (AppRoute.Feeds) -> NavStateCoordinator.FeedLaunchTarget? = { _ in nil }
    ) -> SceneNavigator {
        SceneNavigator(
            coordinator: { coordinator }, hasClient: { hasClient }, seed: store.loadSession()?.section,
            storedRoute: stored, feedsLaunchTarget: { _, stored in feeds(stored) }
        )
    }

    /// What the feed lookup was asked for.
    @MainActor
    private final class Asked {
        var feeds: AppRoute.Feeds?
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let lists = Folder(path: "Lists", isSubscribed: true)

    /// A mail route on `folder`, with message 7 open when `uid` is given.
    private func mailRoute(_ folder: String?, uid: UInt32? = nil) -> AppRoute {
        var route = AppRoute(section: .mail)
        route.mail = AppRoute.Mail(
            folderPath: folder,
            message: uid.map { MessageRef(folder: folder ?? "", uid: $0, messageId: "<\($0)@example.com>") }
        )
        return route
    }

    // MARK: The first frame

    func testAStoredRouteSetsTheFirstFramesTab() throws {
        store.saveSession(ResumeSession(section: .mail, folder: "INBOX"))
        let feeds = makeNavigator(try makeCoordinator(), stored: AppRoute(section: .feeds))
        XCTAssertEqual(feeds.compactTab, .feeds, "before any tree appears")
        XCTAssertEqual(feeds.route.section, .feeds)

        store.saveSession(ResumeSession(section: .feeds, feedScope: .all))
        let mail = makeNavigator(try makeCoordinator(), stored: mailRoute("Archive"))
        XCTAssertEqual(mail.compactTab, .mail)
        XCTAssertEqual(mail.route.mail.folderPath, "Archive")
    }

    // MARK: Landing order

    func testTheStoredRouteIsTheWindowsFirstLanding() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42, messageID: "<42@example.com>"))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, stored: mailRoute("Archive", uid: 7))

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive", "not the snapshot's Lists")
        XCTAssertEqual(navigator.restores.pendingRestore?.folderPath, "Archive")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 7)
        XCTAssertEqual(navigator.restores.pendingRestore?.messageID, "<7@example.com>")
        XCTAssertTrue(navigator.awaitingLaunchReconcile, "provisional until the folder list arrives")
        XCTAssertTrue(coordinator.didConsumeLaunchSession, "the process's first landing spent the snapshot")
        XCTAssertEqual(coordinator.session.folder, "Archive", "the window last used records where it landed")
    }

    func testAParkedDeepLinkBeatsTheStoredRoute() async throws {
        let coordinator = try makeCoordinator()
        coordinator.navigateRequest = NavState(folder: "Lists", uid: 3, clientID: "push")
        let navigator = makeNavigator(coordinator, stored: mailRoute("Archive", uid: 7))

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Lists")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 3)
    }

    /// A stored route with no folder (a compact window backed out to the
    /// folder list) lands as a window with no route does: on the session.
    func testAStoredRouteWithNoFolderLandsOnTheLaunchSnapshot() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, stored: mailRoute(nil))

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Lists")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 42)
    }

    /// A window opened after a restored window landed lands where the user
    /// is now, the live session, not on the other window's stored route.
    func testAWindowOpenedAfterAStoredLandingLandsOnTheLiveSession() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42))
        let coordinator = try makeCoordinator()
        let restored = makeNavigator(coordinator, stored: mailRoute("Archive", uid: 7))
        await restored.mailTreeAppeared(UUID(), isWide: true)

        let opened = makeNavigator(coordinator, stored: nil)
        await opened.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(opened.selectedFolder?.path, "Archive", "the live session the restored window recorded")
        XCTAssertNil(opened.restores.pendingRestore, "the restored window's message is not this window's to open")
    }

    /// Once the window has opened a folder and backed out of it, a rebuilt
    /// tree lands on the live session, not on the folder it was restored on.
    func testARebuiltTreeAfterBackingOutLandsOnTheLiveSession() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, stored: mailRoute("Archive"))
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.foldersLoaded([inbox, archive, lists])
        navigator.selectFolder(lists)
        navigator.selectFolder(nil)

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(navigator.selectedFolder?.path, "Lists", "the live session, not the stored Archive")
    }

    /// A wide window restored into feeds never opened its stored folder; when
    /// it narrows, its Mail tab opens that folder and message, its own place,
    /// rather than the live session.
    func testARebuiltTreeOpensAStoredFolderTheWindowNeverOpened() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42))
        let coordinator = try makeCoordinator()
        var stored = mailRoute("Archive", uid: 7)
        stored.section = .feeds
        stored.feeds = AppRoute.Feeds(scope: .all)
        let navigator = makeNavigator(coordinator, stored: stored) { feeds in
            feeds.scope.map { NavStateCoordinator.FeedLaunchTarget(scope: $0) }
        }
        await navigator.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertTrue(navigator.splitShowsFeeds, "precondition: landed in feeds")
        XCTAssertNil(navigator.selectedFolder)

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 7)
    }

    // MARK: A folder that is gone

    func testAStoredFolderThatNoLongerExistsFallsBackToInboxAndDropsItsMessage() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, stored: mailRoute("Gone", uid: 5))
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertEqual(navigator.restores.pendingRestore?.folderPath, "Gone", "precondition")

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertNil(navigator.restores.pendingRestore)
    }

    /// The same without a client when the tree appeared: the folder list's
    /// first load lands the window, and a stored folder that is gone takes
    /// no message restore to INBOX.
    func testWithoutAClientAStoredFolderThatIsGoneLandsOnInboxWithoutItsMessage() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, stored: mailRoute("Gone", uid: 5), hasClient: false)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertNil(navigator.selectedFolder, "precondition: no landing without a client")

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertNil(navigator.restores.pendingRestore)
    }

    func testWithoutAClientAStoredFolderLandsWithItsMessage() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, stored: mailRoute("Archive", uid: 5), hasClient: false)
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, archive)
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 5)
    }

    // MARK: Feeds

    /// The wide landing reads the window's stored section and hands the
    /// lookup its stored feeds, which come before the session's.
    func testAWideStoredFeedsRouteReopensItsScope() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "INBOX"))
        let coordinator = try makeCoordinator()
        var stored = AppRoute(section: .feeds)
        stored.feeds = AppRoute.Feeds(scope: .subscription("s"))
        let asked = Asked()
        let navigator = makeNavigator(coordinator, stored: stored) { feeds in
            asked.feeds = feeds
            return feeds.scope.map { NavStateCoordinator.FeedLaunchTarget(scope: $0) }
        }

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(asked.feeds?.scope, .subscription("s"))
        XCTAssertTrue(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.feeds.scope, .subscription("s"))
        XCTAssertNil(navigator.selectedFolder)
    }

    func testACompactFeedTreeOpensTheStoredScope() async throws {
        let coordinator = try makeCoordinator()
        var stored = AppRoute(section: .feeds)
        stored.feeds = AppRoute.Feeds(scope: .all)
        let navigator = makeNavigator(coordinator, stored: stored) { feeds in
            feeds.scope.map { NavStateCoordinator.FeedLaunchTarget(scope: $0) }
        }

        await navigator.feedTreeAppeared(UUID())

        XCTAssertEqual(navigator.feeds.scope, .all)
    }
}
