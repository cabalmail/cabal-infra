import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The collapsed Mail stack's landing with nothing to resume
/// (`SceneNavigator.mailTreeAppeared(_:isWide:startsOnFolderList:)`): the
/// iPhone and narrow-window Mail tab opens on its folder list rather than
/// INBOX's messages. Anything to resume — the session's folder, a deep link —
/// still lands there, and visionOS's tab view, whose Mail tab has no folder
/// list, still lands on INBOX.
@MainActor
final class SceneNavigatorFolderListLandingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SceneNavigatorFolderListLandingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ResumeSessionStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
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

    /// No session: the stack lands on its folder list, and the folder list's
    /// first load does not open INBOX behind it. The window has landed, so
    /// picking a folder opens its messages as any pick does.
    func testNothingToResumeLandsOnTheFolderList() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()

        await navigator.mailTreeAppeared(tree, isWide: false, startsOnFolderList: true)
        XCTAssertNil(navigator.selectedFolder)
        XCTAssertNil(navigator.restores.pendingRestore)
        XCTAssertTrue(navigator.didLand)
        XCTAssertFalse(navigator.awaitingLaunchReconcile, "no provisional folder to reconcile")
        XCTAssertEqual(navigator.compactColumn(in: tree), .sidebar)

        navigator.foldersLoaded([inbox, archive])
        XCTAssertNil(navigator.selectedFolder, "the first load doesn't land INBOX either")
        XCTAssertEqual(navigator.compactColumn(in: tree), .sidebar)

        navigator.selectFolder(inbox)
        XCTAssertEqual(navigator.compactColumn(in: tree), .content)
        XCTAssertEqual(coordinator.session.folder, "INBOX", "the pick is recorded")
    }

    /// The control: a tree that doesn't start on a folder list (visionOS's
    /// tab view) lands on INBOX with nothing to resume, as before.
    func testATreeWithoutAFolderListStillLandsOnInbox() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()

        await navigator.mailTreeAppeared(tree, isWide: false)
        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX")
        XCTAssertEqual(navigator.compactColumn(in: tree), .content)
    }

    /// A session folder is a resumption path: the stack opens it, with its
    /// message parked for the list.
    func testASessionFolderIsStillResumed() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Archive", uid: 5))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()

        await navigator.mailTreeAppeared(tree, isWide: false, startsOnFolderList: true)
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 5)
        XCTAssertEqual(navigator.compactColumn(in: tree), .content)
    }

    /// A deep link parked before the window existed is followed.
    func testAParkedDeepLinkIsStillFollowed() async throws {
        let coordinator = try makeCoordinator()
        let router = DeepLinkRouter()
        router.open(.message(NavState(folder: "Archive", uid: 7, clientID: "push")))
        let navigator = makeNavigator(coordinator, deepLinks: router)

        await navigator.mailTreeAppeared(UUID(), isWide: false, startsOnFolderList: true)
        XCTAssertEqual(navigator.selectedFolder?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 7)
    }

    /// A launch whose client was not wired when the stack appeared lands on
    /// the folder list's first load — on the folder list itself.
    func testWithoutAClientTheFirstLoadLeavesTheFolderList() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, hasClient: false)
        let tree = UUID()

        await navigator.mailTreeAppeared(tree, isWide: false, startsOnFolderList: true)
        XCTAssertFalse(navigator.didLand)

        navigator.foldersLoaded([inbox, archive])
        XCTAssertNil(navigator.selectedFolder)
        XCTAssertTrue(navigator.didLand)
        XCTAssertEqual(navigator.compactColumn(in: tree), .sidebar)
    }

    /// The wide split has no folder list to stand on in its place: a window
    /// that widens from the folder-list landing opens INBOX.
    func testWideningFromTheFolderListLandsOnInbox() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)

        await navigator.mailTreeAppeared(UUID(), isWide: false, startsOnFolderList: true)
        XCTAssertNil(navigator.selectedFolder)

        await navigator.mailTreeAppeared(UUID(), isWide: true)
        XCTAssertEqual(navigator.selectedFolder?.path, "INBOX")
    }
}
