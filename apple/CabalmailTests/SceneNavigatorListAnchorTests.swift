import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A window's folder list reopens where it was scrolled when the app last
/// went away: the process's first mail landing parks the session's place
/// for its folder's list, a window the system restored parks its own, and
/// only the window last used writes its place to the session.
@MainActor
final class SceneNavigatorListAnchorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorListAnchorTests.\(UUID().uuidString)"
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

    private func makeCoordinator() throws -> NavStateCoordinator {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())
        return NavStateCoordinator(client: client, clientID: "this-install", store: store)
    }

    private func makeNavigator(
        _ coordinator: NavStateCoordinator, hasClient: Bool = true, deepLinks: DeepLinkRouter = DeepLinkRouter()
    ) -> SceneNavigator {
        let lastUsed = lastUsed
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { hasClient }, seed: .mail,
            lastUsedWindow: { lastUsed.window }, deepLinks: deepLinks
        )
        navigator.windowID = UUID()
        return navigator
    }

    private func place(_ index: Int, in folder: String = "Archive") throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: folder, messageID: "<row\(index)@example.com>", uid: UInt32(5000 - index), index: index
        ))
    }

    /// The session the last run left: on `folder`, its list at row 300, and
    /// message `uid` open when given.
    private func saveSession(folder: String = "Archive", uid: UInt32? = nil) throws {
        var session = ResumeSession(section: .mail, folder: folder, uid: uid)
        session.listAnchor = try place(300, in: folder)
        store.saveSession(session)
    }

    /// A list mounted on `folder` that has scrolled to `index`.
    private func scroll(_ navigator: SceneNavigator, to index: Int?, in folder: String = "INBOX") throws {
        let claim = navigator.listHold.claim(folder, isWide: false)
        let anchor = try index.map { try place($0, in: folder) }
        navigator.listHold.record(anchor, under: claim)
        navigator.recorder.listPlace(anchor, in: folder)
    }

    // MARK: The launch landing

    func testTheFirstLandingParksTheLaunchPlaceForItsFoldersList() async throws {
        try saveSession()
        let navigator = makeNavigator(try makeCoordinator())

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        let list = navigator.listHold.claim("Archive", isWide: false)
        XCTAssertEqual(navigator.listHold.takeAnchor(under: list, from: navigator.restores), try place(300))
        XCTAssertNil(navigator.restores.pendingListAnchor, "taken once")
    }

    /// With a message open too, both wait for the list: the place sets its
    /// scroll, and the message is selected.
    func testALandingWithAnOpenMessageParksBoth() async throws {
        try saveSession(uid: 9)
        let navigator = makeNavigator(try makeCoordinator())

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 9)
        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300))
    }

    /// The folder list arriving swaps the fetched folder in for the
    /// landing's stand-in: the same folder, so the place stays parked.
    func testTheStandInSwapKeepsTheParkedPlace() async throws {
        try saveSession()
        let navigator = makeNavigator(try makeCoordinator())
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, archive)
        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300))
    }

    func testASessionFolderThatIsGoneDropsThePlaceWithTheFallbackToInbox() async throws {
        try saveSession(folder: "Gone")
        let navigator = makeNavigator(try makeCoordinator())
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertNotNil(navigator.restores.pendingListAnchor, "precondition: parked for the provisional landing")

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX")
        XCTAssertNil(navigator.restores.pendingListAnchor)
    }

    /// The client was not wired when the tree appeared, so the folder list's
    /// first load lands the window: the place is parked when the folder is
    /// there, and not for one that is gone.
    func testALandingFromTheFolderListParksThePlaceOnlyForAFolderThatExists() async throws {
        try saveSession()
        let navigator = makeNavigator(try makeCoordinator(), hasClient: false)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.foldersLoaded([inbox, archive])
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300))

        try saveSession(folder: "Gone")
        let other = makeNavigator(try makeCoordinator(), hasClient: false)
        await other.mailTreeAppeared(UUID(), isWide: false)
        other.foldersLoaded([inbox, archive])
        XCTAssertEqual(other.selectedFolder?.path, "INBOX")
        XCTAssertNil(other.restores.pendingListAnchor)
    }

    /// The launch's place is one window's: a window opened after the first
    /// landing opens its list at the top.
    func testAWindowOpenedLaterParksNothing() async throws {
        try saveSession()
        let coordinator = try makeCoordinator()
        let first = makeNavigator(coordinator)
        await first.mailTreeAppeared(UUID(), isWide: false)

        let second = makeNavigator(coordinator)
        await second.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(second.selectedFolder?.path, "Archive")
        XCTAssertNil(second.restores.pendingListAnchor)
    }

    /// A cold launch from a tapped notification: the link is the landing,
    /// and the launch's place is not for where it went, even in the session's
    /// own folder; nor for a window opened after it.
    func testADeepLinkLandingDiscardsTheLaunchPlace() async throws {
        try saveSession()
        let coordinator = try makeCoordinator()
        let router = DeepLinkRouter()
        router.open(.message(NavState(folder: "Archive", uid: 7, clientID: "push")))
        let navigator = makeNavigator(coordinator, deepLinks: router)

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 7)
        XCTAssertNil(navigator.restores.pendingListAnchor)
        XCTAssertNil(coordinator.mailLaunchTarget().listAnchor)
    }

    /// The same when the link opens in a window that does not record (the
    /// system aimed it at a window other than the one last used): the
    /// launch is over, and no later landing is handed last run's place.
    func testADeepLinkInAWindowThatDoesNotRecordDiscardsTheLaunchPlace() async throws {
        try saveSession()
        let coordinator = try makeCoordinator()
        let router = DeepLinkRouter()
        router.open(.message(NavState(folder: "INBOX", uid: 7, clientID: "push")))
        let navigator = makeNavigator(coordinator, deepLinks: router)
        lastUsed.window = UUID()

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX")
        XCTAssertEqual(coordinator.session.folder, "Archive", "precondition: this window did not record")
        XCTAssertNil(coordinator.mailLaunchTarget().listAnchor)
    }

    // MARK: A restored window's own place

    /// A window the system restored parks the place it stored with its
    /// route, and lands on its own folder; the session's place, for another
    /// window's folder, is not used.
    func testARestoredWindowParksItsOwnStoredPlace() async throws {
        let harness = try SessionHarness()
        harness.seedLastSession()
        try await harness.seedTokens()
        await harness.appState.restoreIfPossible()
        var route = AppRoute(section: .mail)
        route.mail = AppRoute.Mail(folderPath: "Archive")
        let stored = StoredRoute(account: harness.appState.routeAccount, route: route, listAnchor: try place(120))

        let navigator = SceneNavigator(appState: harness.appState, windowID: UUID(), stored: stored)
        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(120), "parked as the window is made")
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(120))
        await harness.tearDown()
    }

    /// Through the window's making: a restored window that was last used
    /// parks the session's place, not the older one stored with its route.
    func testARestoredWindowThatWasLastUsedParksTheSessionsPlace() async throws {
        let harness = try SessionHarness()
        harness.seedLastSession()
        try await harness.seedTokens()
        var session = ResumeSession(section: .mail, folder: "Archive")
        session.listAnchor = try place(300)
        ResumeSessionStore(defaults: harness.defaults).saveSession(session)
        await harness.appState.restoreIfPossible()
        var route = AppRoute(section: .mail)
        route.mail = AppRoute.Mail(folderPath: "Archive")
        let stored = StoredRoute(
            account: harness.appState.routeAccount, route: route, listAnchor: try place(120), wasLastUsed: true
        )

        let navigator = SceneNavigator(appState: harness.appState, windowID: UUID(), stored: stored)

        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300))
        await harness.tearDown()
    }

    /// The window that was last used reopens at the session's place for its
    /// folder, which followed its list as it scrolled; its own stored place
    /// is as old as its last route change (a Mac that quits straight after
    /// a scroll writes nothing more). Any other window reopens at its own.
    func testTheWindowLastUsedReopensAtTheSessionsPlace() throws {
        let account = StoredRoute.Account(controlDomain: "cabalmail.example", username: "alice")
        var route = AppRoute(section: .mail)
        route.mail = AppRoute.Mail(folderPath: "Archive")
        var session = ResumeSession(section: .mail, folder: "Archive")
        session.listAnchor = try place(300)
        let lastUsed = StoredRoute(account: account, route: route, listAnchor: try place(120), wasLastUsed: true)
        let other = StoredRoute(account: account, route: route, listAnchor: try place(120), wasLastUsed: false)
        let older = StoredRoute(account: account, route: route, listAnchor: try place(120))

        XCTAssertEqual(lastUsed.placeToReopen(session: session), try place(300))
        XCTAssertEqual(other.placeToReopen(session: session), try place(120))
        XCTAssertEqual(older.placeToReopen(session: session), try place(120), "stored before this was kept")

        session.listAnchor = nil
        XCTAssertNil(lastUsed.placeToReopen(session: session), "it was at the top when the app went away")
        session.folder = "INBOX"
        XCTAssertEqual(lastUsed.placeToReopen(session: session), try place(120), "the session is on another folder")
        XCTAssertEqual(lastUsed.placeToReopen(session: nil), try place(120))
    }

    /// A window that becomes the one last used before its list has landed
    /// (it was restored, and its first load is still out) hands the session
    /// the place still parked for that list, not none.
    func testAWindowBecomingLastUsedBeforeItsListLandsKeepsItsParkedPlace() async throws {
        try saveSession()
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertEqual(navigator.restores.pendingListAnchor, try place(300), "precondition: no list has taken it")
        lastUsed.window = navigator.windowID

        navigator.becameLastUsed()

        XCTAssertEqual(navigator.listPlace, try place(300))
        XCTAssertEqual(coordinator.session.listAnchor, try place(300))
    }

    /// A stored place is used only when it is for the stored route's folder.
    func testAStoredPlaceForAnotherFolderThanTheRoutesIsIgnored() throws {
        let account = StoredRoute.Account(controlDomain: "cabalmail.example", username: "alice")
        var route = AppRoute(section: .mail)
        route.mail = AppRoute.Mail(folderPath: "Archive")

        let own = StoredRoute(account: account, route: route, listAnchor: try place(120))
        let other = StoredRoute(account: account, route: route, listAnchor: try place(120, in: "INBOX"))
        route.mail = AppRoute.Mail(folderPath: nil)
        let none = StoredRoute(account: account, route: route, listAnchor: try place(120))

        XCTAssertEqual(own.listPlace, try place(120))
        XCTAssertNil(other.listPlace)
        XCTAssertNil(none.listPlace, "a route with no folder")
    }

    // MARK: Recording

    func testOnlyTheWindowLastUsedWritesItsPlaceToTheSession() async throws {
        let coordinator = try makeCoordinator()
        let first = makeNavigator(coordinator)
        let second = makeNavigator(coordinator)
        await first.mailTreeAppeared(UUID(), isWide: false)
        await second.mailTreeAppeared(UUID(), isWide: false)
        lastUsed.window = first.windowID

        try scroll(second, to: 40)
        XCTAssertNil(coordinator.session.listAnchor, "a window in the background records nothing")

        try scroll(first, to: 300)
        XCTAssertEqual(coordinator.session.listAnchor, try place(300, in: "INBOX"))
    }

    /// Two windows on one folder: the one that becomes last used replaces
    /// the place the other left, with its own, or with none at the top.
    func testTheWindowBecomingLastUsedWritesItsOwnPlace() async throws {
        let coordinator = try makeCoordinator()
        let first = makeNavigator(coordinator)
        let second = makeNavigator(coordinator)
        let third = makeNavigator(coordinator)
        for navigator in [first, second, third] { await navigator.mailTreeAppeared(UUID(), isWide: false) }
        lastUsed.window = first.windowID
        try scroll(first, to: 300)
        try scroll(second, to: 40)
        XCTAssertEqual(coordinator.session.listAnchor, try place(300, in: "INBOX"), "precondition")

        lastUsed.window = second.windowID
        second.becameLastUsed()
        XCTAssertEqual(coordinator.session.listAnchor, try place(40, in: "INBOX"))

        lastUsed.window = third.windowID
        third.becameLastUsed()
        XCTAssertNil(coordinator.session.listAnchor, "a window at the top of its list")
    }

    /// The place survives to the next launch through the session's own
    /// save, and a relaunch's first landing parks it.
    func testARecordedPlaceIsTheNextLaunchsPlace() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        try scroll(navigator, to: 300)
        coordinator.flushSession()

        let relaunched = makeNavigator(try makeCoordinator())
        await relaunched.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertEqual(relaunched.selectedFolder?.path, "INBOX")
        XCTAssertEqual(relaunched.restores.pendingListAnchor, try place(300, in: "INBOX"))
    }
}
