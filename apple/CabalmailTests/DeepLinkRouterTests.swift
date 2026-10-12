import XCTest
import CabalmailKit
@testable import CabalmailUI

/// One router delivers each deep link to exactly one main window
/// (`DeepLinkRouter`): the system's target, else the window last used, else
/// the window most recently opened; with no window, it parks, the last link
/// winning, for the first window to open.
@MainActor
final class DeepLinkRouterTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "DeepLinkRouterTests.\(UUID().uuidString)"
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

    /// A window's navigator that takes its deep links from `router`, not
    /// yet registered with it.
    private func navigator(
        _ coordinator: NavStateCoordinator, _ router: DeepLinkRouter, seed: ResumeSession.Section = .mail
    ) -> SceneNavigator {
        SceneNavigator(coordinator: { coordinator }, hasClient: { true }, seed: seed, deepLinks: router)
    }

    /// A main window registered with `router`.
    private func window(_ coordinator: NavStateCoordinator, _ router: DeepLinkRouter) -> SceneNavigator {
        let navigator = navigator(coordinator, router)
        navigator.windowID = UUID()
        router.register(navigator)
        return navigator
    }

    private let archiveSeven = DeepLink.message(NavState(folder: "Archive", uid: 7, clientID: "push"))

    // MARK: Delivery

    func testWithNoTargetTheWindowLastUsedTakesIt() throws {
        let appState = AppState()
        let router = appState.deepLinks
        let coordinator = try makeCoordinator()
        let first = window(coordinator, router)
        let second = window(coordinator, router)
        appState.noteActiveMainWindow(try XCTUnwrap(first.windowID))

        router.open(archiveSeven)

        XCTAssertEqual(first.selectedFolder?.path, "Archive")
        XCTAssertNil(second.selectedFolder)
        XCTAssertNil(router.parked)
    }

    /// A target that is not a main window (a compose scene's, or one gone)
    /// falls back to the window last used.
    func testATargetThatIsNotAMainWindowFallsBackToTheWindowLastUsed() throws {
        let appState = AppState()
        let router = appState.deepLinks
        let coordinator = try makeCoordinator()
        let first = window(coordinator, router)
        let second = window(coordinator, router)
        appState.noteActiveMainWindow(try XCTUnwrap(second.windowID))

        router.open(archiveSeven, in: UUID())

        XCTAssertNil(first.selectedFolder)
        XCTAssertEqual(second.selectedFolder?.path, "Archive")
        XCTAssertEqual(second.restores.pendingRestore?.uid, 7)
    }

    /// With windows open and none recorded as last used (none has come to
    /// the front yet, or the one last used closed), the window opened last
    /// takes it rather than leave it parked with every window landed.
    func testWithNoWindowLastUsedTheWindowOpenedLastTakesIt() throws {
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        let first = window(coordinator, router)
        let second = window(coordinator, router)

        router.open(archiveSeven)

        XCTAssertNil(first.selectedFolder)
        XCTAssertEqual(second.selectedFolder?.path, "Archive")
    }

    /// With no window, the link parks; the first window to land takes it,
    /// and a window after it lands on the session.
    func testWithNoWindowTheLinkParksForTheFirstWindowToLand() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42))
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        router.open(archiveSeven)
        XCTAssertEqual(router.parked, archiveSeven)

        let first = navigator(coordinator, router)
        await first.mailTreeAppeared(UUID(), isWide: false)
        let second = navigator(coordinator, router)
        await second.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertNil(router.parked)
        XCTAssertEqual(first.selectedFolder?.path, "Archive")
        XCTAssertEqual(first.restores.pendingRestore?.uid, 7)
        XCTAssertEqual(second.selectedFolder?.path, "Archive", "the live session the first window recorded")
        XCTAssertNil(second.restores.pendingRestore)
    }

    /// A window registering takes a link parked before it existed, so a
    /// window that opens on its Feeds tab (whose Mail tab lands only when
    /// tapped) still opens a notification it was launched from.
    func testAWindowRegisteringTakesAParkedLink() throws {
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        router.open(archiveSeven)
        let navigator = navigator(coordinator, router, seed: .feeds)
        navigator.windowID = UUID()
        XCTAssertEqual(navigator.compactTab, .feeds, "precondition")

        router.register(navigator)

        XCTAssertNil(router.parked)
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.compactTab, .mail)
    }

    func testTheLastLinkParkedWins() {
        let router = DeepLinkRouter()
        router.open(archiveSeven)
        router.open(.spotlight(SpotlightMessageRef(folder: "INBOX", uid: 3)))
        router.open(.folder("Junk"))

        XCTAssertEqual(router.parked, .folder("Junk"))
    }

    /// Siri's Open Folder opens the folder, with no message to select.
    func testAFolderLinkOpensTheFolder() throws {
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        let navigator = window(coordinator, router)

        router.open(.folder("Junk"), in: navigator.windowID)

        XCTAssertEqual(navigator.selectedFolder?.path, "Junk")
        XCTAssertEqual(navigator.restores.pendingRestore?.folderPath, "Junk")
        XCTAssertNil(navigator.restores.pendingRestore?.uid)
    }

    /// A Spotlight result opens once its Message-ID is looked up, unless the
    /// user went somewhere else meanwhile.
    func testASpotlightResultGivesWayToANavigationMeanwhile() async throws {
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        let navigator = window(coordinator, router)

        router.open(.spotlight(SpotlightMessageRef(folder: "Archive", uid: 9)), in: navigator.windowID)
        navigator.navigate(to: NavState(folder: "INBOX", uid: 4, clientID: "other-install"))
        for _ in 0..<20 { await Task.yield() }
        _ = await coordinator.client.envelopeCache.snapshot(for: "Archive")
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 4)
    }

    func testASpotlightResultOpensOnceLookedUp() async throws {
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        let navigator = window(coordinator, router)

        router.open(.spotlight(SpotlightMessageRef(folder: "Archive", uid: 9)), in: navigator.windowID)

        try await waitUntilOnMainActor { navigator.selectedFolder?.path == "Archive" }
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 9)
    }

    /// A Spotlight result parked before the window existed is taken as the
    /// window registers, which is before its first tree lands. Its lookup is
    /// the landing: the session's does not run beside it.
    func testAParkedSpotlightResultTakenAtRegistrationIsTheLanding() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 42))
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        router.open(.spotlight(SpotlightMessageRef(folder: "Archive", uid: 9)))
        let navigator = window(coordinator, router)
        XCTAssertNil(router.parked, "precondition: taken at registration")

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 9)
        XCTAssertFalse(navigator.awaitingLaunchReconcile, "the session's landing did not run")
    }

    /// The same in a wide window that would land in the feed reader: the
    /// feeds landing does not run over the result.
    func testAParkedSpotlightResultIsNotOverwrittenByAFeedsLanding() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Lists", feedScope: .all))
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        router.open(.spotlight(SpotlightMessageRef(folder: "Archive", uid: 9)))
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds, deepLinks: router,
            feedsLaunchTarget: { _, _ in NavStateCoordinator.FeedLaunchTarget(scope: .all) }
        )
        navigator.windowID = UUID()
        router.register(navigator)

        await navigator.mailTreeAppeared(UUID(), isWide: true)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertFalse(navigator.splitShowsFeeds)
        XCTAssertEqual(navigator.route.section, .mail)
    }

    // MARK: Registration

    func testAnUnregisteredWindowTakesNothing() throws {
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        let navigator = window(coordinator, router)
        router.unregister(navigator)

        router.open(archiveSeven, in: navigator.windowID)

        XCTAssertNil(navigator.selectedFolder)
        XCTAssertEqual(router.parked, archiveSeven)
    }

    /// A navigator replaced in its window (a new sign-in) cannot unregister
    /// its replacement.
    func testAReplacedNavigatorCannotUnregisterItsReplacement() throws {
        let router = DeepLinkRouter()
        let coordinator = try makeCoordinator()
        let old = window(coordinator, router)
        let replacement = navigator(coordinator, router)
        replacement.windowID = old.windowID
        router.register(replacement)

        router.unregister(old)
        router.open(archiveSeven, in: replacement.windowID)

        XCTAssertNil(old.selectedFolder)
        XCTAssertEqual(replacement.selectedFolder?.path, "Archive")
    }
}
