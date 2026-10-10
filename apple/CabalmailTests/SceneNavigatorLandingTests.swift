import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Where a window lands, and how the folder list's first load finishes the
/// landing (`SceneNavigator`). These rules lived as `@State` handlers on
/// `MailRootView` (its `+Launch` extension and `onFoldersLoaded`) with no
/// test; each is pinned here by the issue it fixed. A tree a layout swap
/// rebuilds is `SceneNavigatorRebuildTests`'.
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

    private func makeNavigator(
        _ coordinator: NavStateCoordinator, hasClient: Bool = true, deepLinks: DeepLinkRouter = DeepLinkRouter()
    ) -> SceneNavigator {
        SceneNavigator(
            coordinator: { coordinator }, hasClient: { hasClient }, seed: store.loadSession()?.section,
            deepLinks: deepLinks
        )
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

        await navigator.mailTreeAppeared(tree, isWide: false)
        XCTAssertEqual(navigator.selectedFolder, Folder(path: "Lists.Cabal", isSubscribed: true))
        XCTAssertEqual(navigator.route.mail.folderPath, "Lists.Cabal")
        XCTAssertEqual(navigator.restores.pendingRestore?.folderPath, "Lists.Cabal")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 42)
        XCTAssertTrue(navigator.didLand)
        XCTAssertTrue(navigator.awaitingLaunchReconcile)
        XCTAssertEqual(navigator.compactColumn(in: tree), .content)
        XCTAssertNil(navigator.envelope(in: tree), "the list selects the message once it has loaded")
    }

    /// The landing waits for a client: the message list cannot build its
    /// model without one. The folder list's first load lands instead.
    func testWithoutAClientTheFolderListLandsTheWindow() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Archive", uid: 5))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, hasClient: false)

        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertNil(navigator.selectedFolder)
        XCTAssertFalse(navigator.didLand)

        navigator.foldersLoaded([inbox, archive])
        XCTAssertEqual(navigator.selectedFolder, archive)
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 5)
        XCTAssertTrue(navigator.didLand, "the folder list's landing is the window's landing")

        // So backing out and a later load don't land the user again.
        navigator.selectFolder(nil)
        navigator.foldersLoaded([inbox, archive])
        XCTAssertNil(navigator.selectedFolder)
    }

    /// A deep link parked before the window existed (a cold launch from a
    /// tapped notification) is the landing, and the session's is not run on
    /// top of it.
    func testAParkedDeepLinkIsTheLanding() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Lists"))
        let coordinator = try makeCoordinator()
        let router = DeepLinkRouter()
        router.open(.message(NavState(folder: "Archive", uid: 7, clientID: "push")))
        let navigator = makeNavigator(coordinator, deepLinks: router)

        await navigator.mailTreeAppeared(UUID(), isWide: false)

        XCTAssertNil(router.parked, "the window took the link")
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 7)
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

        await navigator.mailTreeAppeared(UUID(), isWide: true)
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
        await navigator.mailTreeAppeared(tree, isWide: false)
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
    /// load of the folder list.
    func testBackingOutBeforeFoldersLoadFinishesTheLaunchWithoutLanding() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: false)
        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX")

        navigator.selectFolder(nil)
        navigator.foldersLoaded([inbox, archive])

        XCTAssertNil(navigator.selectedFolder)
        XCTAssertFalse(navigator.awaitingLaunchReconcile)
        navigator.foldersLoaded([inbox, archive])
        XCTAssertNil(navigator.selectedFolder)
        // The launch finished: the cursor write the landing held back goes
        // out (held here until the cross-device probe releases it).
        try await waitUntilOnMainActor { coordinator.heldSnapshot != nil }
    }

    /// The folder list's first load finishes a provisional landing: the
    /// cursor write the landing held back is released.
    func testTheReconcileReleasesTheLandingsHeldWrite() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        // The landing's own folder record wrote nothing: held back so the
        // cross-device probe reads another install's cursor (past the 1 s
        // save debounce).
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertNil(coordinator.heldSnapshot)

        navigator.foldersLoaded([inbox, archive])

        try await waitUntilOnMainActor { coordinator.heldSnapshot?.folder == "INBOX" }
    }

    /// The window has landed, so the same tree appearing again after the
    /// user backed out to the folder list does not land them again.
    func testAReappearingTreeDoesNotLandAgain() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        await navigator.mailTreeAppeared(tree, isWide: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.selectFolder(nil)

        await navigator.mailTreeAppeared(tree, isWide: false)

        XCTAssertNil(navigator.selectedFolder)
    }

    /// Only the wide layout hosts feeds in the mail split: a compact Mail tab
    /// landing with a feeds session lands on mail.
    func testACompactLandingIgnoresAFeedsSession() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Archive", feedScope: .all))
        let coordinator = try makeCoordinator()
        let navigator = SceneNavigator(
            coordinator: { coordinator }, hasClient: { true }, seed: .feeds,
            feedsLaunchTarget: { _, _ in .init(scope: .all) }
        )

        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
    }

    /// The landing's missing-folder fallback: the session's folder is absent
    /// from the fetched list (deleted since it was saved, perhaps from
    /// another device). The landing falls back to INBOX and drops the message
    /// restore aimed at it.
    func testAMissingSessionFolderFallsBackToInbox() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Gone", uid: 5))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        XCTAssertEqual(navigator.restores.pendingRestore?.folderPath, "Gone")

        navigator.foldersLoaded([archive, inbox])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertNil(navigator.restores.pendingRestore)
        XCTAssertEqual(coordinator.session.folder, "INBOX")
    }
}
