import XCTest
import CabalmailKit
@testable import CabalmailUI

/// How a tree built by a layout swap takes over a window that has landed
/// (`SceneNavigator`): it renders the window's route instead of re-landing
/// from the per-install session, and the compact tab survives the swap.
/// Each rule lived as `@State` handlers on `MailRootView` with no test.
@MainActor
final class SceneNavigatorRebuildTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorRebuildTests.\(UUID().uuidString)"
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
        SceneNavigator(coordinator: { coordinator }, hasClient: { hasClient }, seed: store.loadSession()?.section)
    }

    private let inbox = Folder(path: "INBOX", attributes: ["\\HasNoChildren"], isSubscribed: true)
    private let archive = Folder(path: "Archive", attributes: ["\\HasNoChildren"], isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

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

    /// Where the route has no mail position — here the user backed out to
    /// the folder list — a rebuilt tree lands on the live session, as every
    /// rebuilt tree did before the window kept a route.
    func testARebuiltTreeWithNoFolderLandsOnTheLiveSession() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let first = UUID()
        _ = await navigator.mailTreeAppeared(first, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.selectFolder(nil)
        coordinator.recordFolder("Archive")

        _ = await navigator.mailTreeAppeared(UUID(), isWide: true, showingFeeds: false)

        XCTAssertEqual(navigator.selectedFolder, Folder(path: "Archive", isSubscribed: true))
        XCTAssertTrue(navigator.awaitingLaunchReconcile)
    }

    /// A rebuilt tree with no folder lands on the live session even when the
    /// window's first landing never read the launch snapshot (a cold launch
    /// from a tapped notification), rather than on that stale snapshot
    /// (#1555).
    func testARebuiltTreeAfterANavigateLandingIgnoresTheStaleSnapshot() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists", uid: 3))
        let coordinator = try makeCoordinator()
        coordinator.navigateRequest = NavState(folder: "Archive", uid: 7, clientID: "push")
        let navigator = makeNavigator(coordinator)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.selectFolder(nil)

        _ = await navigator.mailTreeAppeared(UUID(), isWide: true, showingFeeds: false)

        XCTAssertEqual(navigator.selectedFolder?.path, "Archive", "the live session, not the launch snapshot's Lists")
        XCTAssertNotEqual(coordinator.pendingRestore?.folderPath, "Lists", "no restore of the snapshot's message")
    }

    /// #1664: a compact stack is never handed a list and a reader in one
    /// update. A tree the swap has just built sees no folder and no message
    /// until it has taken over, so its list mounts only once the restore is
    /// parked and its gated initial load applies it; the message comes back
    /// only when that list selects it.
    func testARebuiltTreeNeverSeesAListAndAReaderInOneUpdate() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let first = UUID()
        _ = await navigator.mailTreeAppeared(first, isWide: true, showingFeeds: false)
        navigator.foldersLoaded([inbox])
        navigator.selectMessage(message, isSearching: false, from: first)
        XCTAssertEqual(navigator.compactColumn(in: first), .detail)

        let rebuilt = UUID()
        XCTAssertNil(navigator.folder(in: rebuilt), "no list may mount before the restore is parked")
        XCTAssertNil(navigator.envelope(in: rebuilt))
        XCTAssertEqual(navigator.compactColumn(in: rebuilt), .sidebar)

        _ = await navigator.mailTreeAppeared(rebuilt, isWide: false, showingFeeds: false)
        XCTAssertEqual(navigator.folder(in: rebuilt), inbox)
        XCTAssertEqual(coordinator.pendingRestore?.uid, 9)
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
        navigator.selectMessage(TestFixtures.makeEnvelope(uid: 12), isSearching: false, from: first)

        XCTAssertEqual(navigator.route.mail.message, MessageRef(folder: "INBOX", uid: 9))
        XCTAssertEqual(coordinator.session.uid, 9, "nothing the old tree wrote was recorded")
        XCTAssertNil(navigator.envelope(in: rebuilt))
        XCTAssertEqual(navigator.compactColumn(in: rebuilt), .content)
    }

    /// A wide tree rebuilt in the feeds section that has no scope to reopen
    /// shows mail, so the section — and the tab a swap back opens — moves to
    /// mail, as the old re-landing's folder record moved it.
    func testAWideRebuildWithNoFeedScopeMovesTheSectionToMail() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox])
        navigator.showTab(.feeds)
        XCTAssertEqual(coordinator.session.section, .feeds)

        let scope = await navigator.mailTreeAppeared(UUID(), isWide: true, showingFeeds: false)

        XCTAssertNil(scope)
        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertEqual(navigator.route.section, .mail)
        XCTAssertEqual(navigator.compactTab, .mail)
        XCTAssertEqual(coordinator.session.section, .mail)
    }

    /// A utility tab survives a round trip through the split with nothing
    /// picked — the hand-off's restore re-selecting the open message is not a
    /// pick — but a pick in the split moves it to that section.
    func testAUtilityTabSurvivesARoundTripUnlessSomethingIsPicked() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let compact = UUID()
        _ = await navigator.mailTreeAppeared(compact, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.selectMessage(message, isSearching: false, from: compact)
        navigator.showTab(.settings)

        let wide = UUID()
        _ = await navigator.mailTreeAppeared(wide, isWide: true, showingFeeds: false)
        navigator.selectMessage(message, isSearching: false, from: wide)
        XCTAssertEqual(navigator.compactTab, .settings)

        navigator.selectFolder(archive)
        XCTAssertEqual(navigator.compactTab, .mail)
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
