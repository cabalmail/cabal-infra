import XCTest
import CabalmailKit
@testable import CabalmailUI

/// visionOS's tab view on the window's navigator (`SceneNavigator`): its
/// Folders tab, and its landing, which runs at launch whichever tab is up.
/// These rules lived as `@State` handlers on `VisionSectionView` and its
/// Mail pane, which no test could reach. The quiet landing is a rule of the
/// navigator's, so it holds on the compact layout too.
@MainActor
final class SceneNavigatorVisionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorVisionTests.\(UUID().uuidString)"
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

    // MARK: The quiet landing

    /// A visionOS window that opens on Feeds still lands mail, so the Mail
    /// tab is ready when the user opens it, but records nothing: the session
    /// stays in Feeds with its open message, as it did while the Mail tab,
    /// not yet built, had no handler to record the landing.
    func testATabViewOpeningOnFeedsLandsMailWithoutLeavingFeeds() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Archive", uid: 5, messageID: "<five@x>"))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        XCTAssertEqual(navigator.compactTab, .feeds)

        _ = await navigator.mailTreeAppeared(tree, isWide: false, showingFeeds: false)

        XCTAssertEqual(navigator.folder(in: tree)?.path, "Archive")
        XCTAssertEqual(coordinator.pendingRestore?.uid, 5, "the Mail tab's list reselects it when it loads")
        XCTAssertEqual(coordinator.session.section, .feeds)
        XCTAssertEqual(coordinator.session.uid, 5, "recording the folder would have dropped the open message")
        XCTAssertEqual(navigator.route.section, .feeds)
        XCTAssertEqual(navigator.compactTab, .feeds)

        // The folder list's swap is quiet too, and opening Mail moves the
        // session there.
        navigator.foldersLoaded([inbox, archive])
        XCTAssertEqual(navigator.folder(in: tree), archive)
        XCTAssertEqual(coordinator.session.section, .feeds)
        navigator.showTab(.mail)
        XCTAssertEqual(coordinator.session.section, .mail)
        XCTAssertEqual(coordinator.session.uid, 5)
    }

    /// The landing's folder is gone, so the folder list falls back to INBOX,
    /// still without moving a window that is in Feeds out of it.
    func testAQuietLandingsFallbackDoesNotMoveTheSession() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Gone", uid: 3))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertNil(coordinator.pendingRestore, "the restore was aimed at the missing folder")
        XCTAssertEqual(coordinator.session.section, .feeds)
        XCTAssertEqual(coordinator.session.folder, "Gone")
    }

    /// On the compact layout the Mail tab's tree lands; when its folder list
    /// arrives after the user switched to Feeds, the landing it finishes is
    /// quiet as well.
    func testAFolderListArrivingAfterASwitchToFeedsMovesNothing() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Archive"))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator, hasClient: false)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)
        navigator.showTab(.feeds)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, archive)
        XCTAssertTrue(navigator.didLand)
        XCTAssertEqual(coordinator.session.section, .feeds)
    }

    // MARK: The Folders tab

    /// The Folders tab belongs to mail: switching to it from Feeds moves the
    /// session to mail, as the Mail tab does.
    func testTheFoldersTabIsInTheMailSection() throws {
        store.saveSession(ResumeSession(section: .feeds))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)

        navigator.showTab(.folders)

        XCTAssertEqual(navigator.route.section, .mail)
        XCTAssertEqual(coordinator.session.section, .mail)
    }

    /// A pick in the Folders tab shows that folder's messages: the tab moves
    /// to Mail, and the folder is recorded.
    func testAFolderPickInTheFoldersTabShowsItsMessages() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        _ = await navigator.mailTreeAppeared(tree, isWide: false, showingFeeds: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.showTab(.folders)

        navigator.selectFolder(archive)

        XCTAssertEqual(navigator.compactTab, .mail)
        XCTAssertEqual(navigator.folder(in: tree), archive)
        XCTAssertEqual(coordinator.session.folder, "Archive")
    }

    /// Only a new folder leaves the Folders tab. The landing's same-path
    /// swap, re-picking the folder already selected, and a cleared selection
    /// (the selected folder deleted, #1062) leave the user where they are.
    func testOnlyANewFolderLeavesTheFoldersTab() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)
        navigator.showTab(.folders)

        navigator.foldersLoaded([inbox, archive])
        XCTAssertEqual(navigator.selectedFolder, inbox, "the stand-in swapped for the fetched folder")
        XCTAssertEqual(navigator.compactTab, .folders)

        navigator.selectFolder(inbox)
        XCTAssertEqual(navigator.compactTab, .folders)

        navigator.selectFolder(nil)
        XCTAssertEqual(navigator.compactTab, .folders)
    }

    /// The landing's folder is gone and the user is on the Folders tab when
    /// the list arrives: the INBOX fallback is a new folder, so it shows
    /// Mail, and is recorded, Folders being a mail tab.
    func testTheLandingsFallbackOnTheFoldersTabShowsMail() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Gone"))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        _ = await navigator.mailTreeAppeared(UUID(), isWide: false, showingFeeds: false)
        navigator.showTab(.folders)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertEqual(navigator.compactTab, .mail)
        XCTAssertEqual(coordinator.session.folder, "INBOX")
    }
}
