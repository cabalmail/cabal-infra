import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Where a window lands, and how a tree built by a layout swap takes over
/// (`SceneNavigator`). These rules lived as `@State` handlers on
/// `MailRootView` (its `+Launch` extension and `onFoldersLoaded`) with no
/// test; each is pinned here by the issue it fixed.
@MainActor
final class SceneNavigatorLandingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorLandingTests.\(UUID().uuidString)"
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

    private func makeNavigator(_ coordinator: NavStateCoordinator, hasClient: Bool = true) -> SceneNavigator {
        SceneNavigator(coordinator: { coordinator }, hasClient: { hasClient })
    }

    private let inbox = Folder(path: "INBOX", attributes: ["\\HasNoChildren"], isSubscribed: true)
    private let archive = Folder(path: "Archive", attributes: ["\\HasNoChildren"], isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

    // MARK: The first landing

    /// #1555, first half: the first tree in a window lands on the launch
    /// snapshot — provisionally, before the folder list returns — with the
    /// open message scheduled for the list to reselect.
    func testTheFirstTreeLandsOnTheLaunchSnapshot() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists.Cabal", uid: 42, messageID: "<m@x>"))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()

        let scope = await navigator.mailTreeAppeared(tree, isWide: false, showingFeeds: false)

        XCTAssertNil(scope)
        XCTAssertEqual(navigator.selectedFolder, Folder(path: "Lists.Cabal", isSubscribed: true))
        XCTAssertEqual(navigator.route.mail.folderPath, "Lists.Cabal")
        XCTAssertEqual(coordinator.pendingRestore?.folderPath, "Lists.Cabal")
        XCTAssertEqual(coordinator.pendingRestore?.uid, 42)
        XCTAssertTrue(navigator.didLand)
        XCTAssertTrue(navigator.awaitingLaunchReconcile)
        XCTAssertEqual(navigator.compactColumn(in: tree), .content)
        XCTAssertNil(navigator.envelope(in: tree), "the list selects the message once it has loaded")
    }

    /// The landing waits for a client: the message list cannot build its
    /// model without one. The folder list's first load lands instead.
    func testWithoutAClientTheFolderListLandsTheWindow() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Archive"))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, hasClient: false)

        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)
        XCTAssertNil(navigator.selectedFolder)
        XCTAssertFalse(navigator.didLand)

        navigator.foldersLoaded([inbox, archive])
        XCTAssertEqual(navigator.selectedFolder, archive)
    }

    /// A navigate request parked before the window existed (a cold launch
    /// from a tapped notification) is the landing, and the session's is not
    /// run on top of it.
    func testAParkedNavigateRequestIsTheLanding() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists"))
        let coordinator = try makeCoordinator()
        coordinator.navigateRequest = NavState(folder: "Archive", uid: 7, clientID: "push")
        let navigator = makeNavigator(coordinator)

        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)

        XCTAssertNil(coordinator.navigateRequest, "the window took the request")
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(coordinator.pendingRestore?.uid, 7)
        XCTAssertTrue(navigator.didLand)
        XCTAssertFalse(navigator.awaitingLaunchReconcile, "no provisional landing to reconcile")
    }

    /// The wide layout reopens a feeds session in the feed reader. When the
    /// scope can't be opened (here the test client has no feed store), it
    /// lands in mail instead, and the tab a swap to compact opens on follows
    /// the mail landing rather than the feeds session it was seeded from.
    func testAWideFeedsLandingThatCannotOpenItsScopeLandsInMail() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Archive", feedScope: .all))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        XCTAssertEqual(navigator.compactTab, .feeds)

        let scope = await navigator.mailTreeAppeared(UUID(), isWide: true, showingFeeds: false)

        XCTAssertNil(scope)
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.route.section, .mail)
        XCTAssertEqual(navigator.compactTab, .mail)
    }

    // MARK: The folder list's first load

    /// #1535: the provisional stand-in is swapped for the fetched folder —
    /// the value the sidebar tags its row with — without clearing the open
    /// message or recording the folder again.
    func testTheStandInSwapKeepsTheMessageAndDoesNotReRecord() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        _ = await navigator.mailTreeAppeared(tree, isWide: false, showingFeeds: false)
        navigator.selectMessage(message, isSearching: false, from: tree)
        XCTAssertEqual(coordinator.session.uid, 9)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, inbox, "the fetched value, attributes and all")
        XCTAssertEqual(navigator.envelope(in: tree), message)
        XCTAssertEqual(coordinator.session.uid, 9, "re-recording the folder would have cleared the message")
        XCTAssertFalse(navigator.awaitingLaunchReconcile)
    }

    /// #1535, the navigate-request half: a request that arrives before the
    /// folder list selects a stand-in, swapped once the list loads.
    func testANavigateRequestsStandInIsSwappedWhenTheFolderListLoads() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        navigator.navigate(to: NavState(folder: "Archive", clientID: "push"))
        XCTAssertEqual(navigator.selectedFolder, Folder(path: "Archive"))

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, archive)
        XCTAssertEqual(navigator.resolvedFolder(path: "INBOX"), inbox)
    }

    /// #1912: the user backed out to the folder list before it loaded. The
    /// launch finishes without landing them in INBOX — then or on a later
    /// tree's load.
    func testBackingOutBeforeFoldersLoadFinishesTheLaunchWithoutLanding() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        _ = await navigator.mailTreeAppeared(tree, isWide: false, showingFeeds: false)
        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX")

        navigator.selectFolder(nil)
        navigator.foldersLoaded([inbox, archive])

        XCTAssertNil(navigator.selectedFolder)
        XCTAssertFalse(navigator.awaitingLaunchReconcile)
        navigator.foldersLoaded([inbox, archive])
        XCTAssertNil(navigator.selectedFolder)
    }

    /// #1062: the session's folder was deleted since it was saved. The
    /// landing falls back to INBOX and drops the message restore aimed at it.
    func testADeletedSessionFolderFallsBackToInbox() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Gone", uid: 5))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)
        XCTAssertEqual(coordinator.pendingRestore?.folderPath, "Gone")

        navigator.foldersLoaded([archive, inbox])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertNil(coordinator.pendingRestore)
        XCTAssertEqual(coordinator.session.folder, "INBOX")
    }

    // MARK: Rebuilt trees

    /// #1555, second half: a tree rebuilt by a layout swap renders the
    /// window's route — not the per-install session, which another window
    /// may have moved since — and re-parks the open message for its list.
    func testARebuiltTreeRendersTheWindowsRouteNotTheLiveSession() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let first = UUID()
        _ = await navigator.mailTreeAppeared(first, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.selectMessage(message, isSearching: false, from: first)
        // Another window on the same install moves on.
        coordinator.recordFolder("Archive")

        let rebuilt = UUID()
        let scope = await navigator.mailTreeAppeared(rebuilt, isWide: true, showingFeeds: false)

        XCTAssertNil(scope)
        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertEqual(coordinator.pendingRestore?.folderPath, "INBOX")
        XCTAssertEqual(coordinator.pendingRestore?.uid, 9)
        XCTAssertEqual(coordinator.pendingRestore?.messageID, "<nine@example.com>")
        XCTAssertEqual(navigator.route.mail.message, MessageRef(folder: "INBOX", uid: 9))
    }

    /// #1664: a compact stack is never handed a list and a reader in one
    /// update. A tree the swap has just built sees the folder's list and no
    /// message until it has appeared, and after that the message comes back
    /// only when its list selects the parked restore.
    func testARebuiltTreeNeverSeesAListAndAReaderInOneUpdate() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let first = UUID()
        _ = await navigator.mailTreeAppeared(first, isWide: true, showingFeeds: false)
        navigator.foldersLoaded([inbox])
        navigator.selectMessage(message, isSearching: false, from: first)
        XCTAssertEqual(navigator.compactColumn(in: first), .detail)

        let rebuilt = UUID()
        XCTAssertNil(navigator.envelope(in: rebuilt))
        XCTAssertEqual(navigator.compactColumn(in: rebuilt), .content)

        _ = await navigator.mailTreeAppeared(rebuilt, isWide: false, showingFeeds: false)
        XCTAssertNil(navigator.envelope(in: rebuilt))
        XCTAssertEqual(navigator.compactColumn(in: rebuilt), .content)

        // The list has appeared and loaded, and applies the restore.
        navigator.selectMessage(message, isSearching: false, from: rebuilt)
        XCTAssertEqual(navigator.envelope(in: rebuilt), message)
        XCTAssertEqual(navigator.compactColumn(in: rebuilt), .detail)
    }

    /// The same tree appearing again — a tab switch away and back — is not a
    /// rebuild: its open message stays and nothing is re-parked.
    func testTheSameTreeAppearingAgainKeepsItsMessage() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        _ = await navigator.mailTreeAppeared(tree, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox])
        navigator.selectMessage(message, isSearching: false, from: tree)

        _ = await navigator.mailTreeAppeared(tree, isWide: false, showingFeeds: false)

        XCTAssertEqual(navigator.envelope(in: tree), message)
        XCTAssertEqual(navigator.compactColumn(in: tree), .detail)
        XCTAssertNil(coordinator.pendingRestore)
    }

    /// A swap tears the old tree down after the new one is built; whatever
    /// the old tree writes on its way out must not move the window.
    func testWritesFromATornDownTreeAreDropped() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let first = UUID()
        _ = await navigator.mailTreeAppeared(first, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox])
        navigator.selectMessage(message, isSearching: false, from: first)
        let rebuilt = UUID()
        _ = await navigator.mailTreeAppeared(rebuilt, isWide: true, showingFeeds: false)

        navigator.setCompactColumn(.sidebar, isSearching: false, from: first)
        navigator.selectMessage(nil, isSearching: false, from: first)

        XCTAssertEqual(navigator.route.mail.message, MessageRef(folder: "INBOX", uid: 9))
        XCTAssertEqual(coordinator.session.uid, 9, "the old tree's back-out was not recorded")
        XCTAssertEqual(navigator.compactColumn(in: rebuilt), .content)
    }

    /// #1644: the tab survives a rebuild in each direction, utility tabs
    /// included — a swap no longer re-seeds it from the session.
    func testTheTabSurvivesARebuild() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)
        navigator.showTab(.addresses)

        _ = await navigator.mailTreeAppeared(UUID(), isWide: true, showingFeeds: false)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)

        XCTAssertEqual(navigator.compactTab, .addresses)
    }
}
