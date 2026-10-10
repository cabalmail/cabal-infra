import XCTest
import CabalmailKit
@testable import CabalmailUI

/// visionOS's tab view on the window's navigator (`SceneNavigator`): its
/// Folders tab, and its landing, which runs at launch whichever tab is up.
/// These rules lived as `@State` handlers on `VisionSectionView` and its
/// Mail pane, which no test could reach.
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

        await navigator.mailTreeAppeared(tree, isWide: false)

        XCTAssertEqual(navigator.folder(in: tree)?.path, "Archive")
        XCTAssertEqual(navigator.restores.pendingRestore?.uid, 5, "the Mail tab's list reselects it when it loads")
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
        await navigator.mailTreeAppeared(UUID(), isWide: false)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertNil(navigator.restores.pendingRestore, "the restore was aimed at the missing folder")
        XCTAssertEqual(coordinator.session.section, .feeds)
        XCTAssertEqual(coordinator.session.folder, "Gone")
    }

    /// Once the window has shown mail, the landing records again, whatever
    /// tab is up when the folder list arrives — as the Mail tab did once
    /// built. Here a launch on Mail whose folder is gone: the user opened
    /// Settings before the list came back, and the INBOX fallback still
    /// replaces the deleted folder in the session.
    func testALandingRecordsOnceTheWindowHasShownMail() async throws {
        store.saveSession(ResumeSession(section: .mail, folder: "Gone"))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.showTab(.settings)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertEqual(coordinator.session.folder, "INBOX")
    }

    /// The same once a window that opened on Feeds has visited Mail: the
    /// fallback is recorded even from Feeds, moving the session to mail, as
    /// the Mail tab, built by that visit, did.
    func testAFeedsWindowThatVisitedMailRecordsItsLanding() async throws {
        store.saveSession(ResumeSession(section: .feeds, folder: "Gone"))
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.showTab(.mail)
        navigator.showTab(.feeds)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(coordinator.session.folder, "INBOX")
        XCTAssertEqual(coordinator.session.section, .mail)
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
        await navigator.mailTreeAppeared(tree, isWide: false)
        navigator.foldersLoaded([inbox, archive])
        navigator.showTab(.folders)

        navigator.selectFolder(archive)

        XCTAssertEqual(navigator.compactTab, .mail)
        XCTAssertEqual(navigator.folder(in: tree), archive)
        XCTAssertEqual(coordinator.session.folder, "Archive")
    }

    /// Only a new folder leaves the Folders tab. The landing's same-path
    /// swap, re-picking the folder already selected, and a cleared selection
    /// leave the user where they are. (Deleting the selected folder selects
    /// INBOX, a new folder, #1062.)
    func testOnlyANewFolderLeavesTheFoldersTab() async throws {
        let coordinator = try makeCoordinator()
        let navigator = makeNavigator(coordinator)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
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
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        navigator.showTab(.folders)

        navigator.foldersLoaded([inbox, archive])

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertEqual(navigator.compactTab, .mail)
        XCTAssertEqual(coordinator.session.folder, "INBOX")
    }
}
