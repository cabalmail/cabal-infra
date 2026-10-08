import XCTest
import CabalmailKit
@testable import CabalmailUI

/// One window's navigation once it has landed (`SceneNavigator`): picks,
/// navigate requests, the compact tab and column, and what each records on
/// the resume session. Landing and layout swaps are in
/// `SceneNavigatorLandingTests`.
@MainActor
final class SceneNavigatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "SceneNavigatorTests.\(UUID().uuidString)"
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
        SceneNavigator(coordinator: { coordinator }, hasClient: { true })
    }

    private let inbox = Folder(path: "INBOX", isSubscribed: true)
    private let archive = Folder(path: "Archive", isSubscribed: true)
    private let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")

    /// A navigator that has landed on INBOX with the folder list loaded, and
    /// the tree that landed it.
    private func landed(
        _ coordinator: NavStateCoordinator, isWide: Bool = false
    ) async -> (navigator: SceneNavigator, tree: UUID) {
        let navigator = makeNavigator(coordinator)
        let tree = UUID()
        _ = await navigator.mailTreeAppeared(tree, isWide: isWide, showingFeeds: false)
        navigator.foldersLoaded([inbox, archive])
        return (navigator, tree)
    }

    // MARK: Seeding

    func testANewWindowOpensOnTheSessionsSection() throws {
        store.saveSession(ResumeSession(section: .feeds, feedScope: .all))
        let feeds = makeNavigator(try makeCoordinator())
        XCTAssertEqual(feeds.compactTab, .feeds)
        XCTAssertEqual(feeds.route.section, .feeds)

        store.saveSession(ResumeSession(section: .mail, folder: "Archive"))
        let mail = makeNavigator(try makeCoordinator())
        XCTAssertEqual(mail.compactTab, .mail)
        XCTAssertEqual(mail.route.section, .mail)
    }

    // MARK: Navigate requests

    /// The request slot is app-wide; with two windows, the first to see a
    /// request takes it and the other stays where it is.
    func testTheFirstWindowToSeeARequestTakesIt() throws {
        let coordinator = try makeCoordinator()
        let first = makeNavigator(coordinator)
        let second = makeNavigator(coordinator)
        coordinator.navigateRequest = NavState(folder: "Archive", uid: 7, clientID: "push")

        first.takeNavigateRequest()
        second.takeNavigateRequest()

        XCTAssertNil(coordinator.navigateRequest)
        XCTAssertEqual(first.selectedFolder?.path, "Archive")
        XCTAssertNil(second.selectedFolder)
        XCTAssertEqual(coordinator.pendingRestore?.uid, 7)
    }

    /// A navigation opens the Mail tab, whichever tab was showing.
    func testANavigationOpensTheMailTab() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await landed(coordinator)
        navigator.showTab(.search)

        navigator.navigate(to: NavState(folder: "Archive", clientID: "other-install"))

        XCTAssertEqual(navigator.compactTab, .mail)
        XCTAssertEqual(navigator.route.section, .mail)
        XCTAssertEqual(navigator.selectedFolder, archive, "the fetched folder, not a stand-in")
        XCTAssertEqual(coordinator.session.folder, "Archive")
    }

    /// A jump within the folder already open keeps the mounted list, which
    /// picks the new restore up itself, and records nothing over the cursor
    /// the restore primed (#1873).
    func testASameFolderNavigationLeavesTheFolderAlone() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await landed(coordinator)
        navigator.navigate(to: NavState(folder: "INBOX", uid: 4, uidValidity: 77, clientID: "other-install"))

        XCTAssertEqual(navigator.selectedFolder, inbox)
        XCTAssertEqual(coordinator.pendingRestore?.uid, 4)
        XCTAssertEqual(coordinator.workingCursor?.uidValidity, 77)
    }

    // MARK: Picks and the wide layout's mutual exclusion

    func testAFolderPickRecordsTheFolder() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tree) = await landed(coordinator)
        navigator.selectMessage(message, isSearching: false, from: tree)

        navigator.selectFolder(archive)

        XCTAssertEqual(navigator.route.mail, AppRoute.Mail(folderPath: "Archive"))
        XCTAssertNil(navigator.envelope(in: tree))
        XCTAssertEqual(navigator.compactColumn(in: tree), .content)
        XCTAssertEqual(coordinator.session.folder, "Archive")
        XCTAssertNil(coordinator.session.uid)
    }

    /// On the wide layout a feed pick clears the mail folder and message,
    /// recording neither: the feed scope's own record moves the session.
    func testAFeedPickClearsTheMailWithoutRecordingIt() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tree) = await landed(coordinator, isWide: true)
        navigator.selectMessage(message, isSearching: false, from: tree)

        navigator.showFeeds()

        XCTAssertNil(navigator.selectedFolder)
        XCTAssertNil(navigator.envelope(in: tree))
        XCTAssertEqual(navigator.route.section, .feeds)
        XCTAssertEqual(coordinator.session.folder, "INBOX")
        XCTAssertEqual(coordinator.session.uid, 9)
    }

    /// #1644: on the wide layout, which has no tab bar, the tab a swap opens
    /// on follows what the split shows.
    func testAWidePickMovesTheTabToItsSection() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await landed(coordinator, isWide: true)

        navigator.showFeeds()
        XCTAssertEqual(navigator.compactTab, .feeds)

        navigator.selectFolder(archive)
        XCTAssertEqual(navigator.compactTab, .mail)
    }

    /// The compact layout's Mail and Feeds tabs keep their own positions: a
    /// folder landing in the Mail tab does not move the tab the user is on.
    func testACompactFolderChangeLeavesTheTabAlone() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await landed(coordinator)
        navigator.showTab(.feeds)

        navigator.selectFolder(archive)

        XCTAssertEqual(navigator.compactTab, .feeds)
    }

    func testATabSwitchMovesOnlyTheSection() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, _) = await landed(coordinator)

        navigator.showTab(.feeds)
        XCTAssertEqual(coordinator.session.section, .feeds)
        XCTAssertEqual(coordinator.session.folder, "INBOX")

        navigator.showTab(.settings)
        XCTAssertEqual(coordinator.session.section, .feeds, "a utility tab is not a section")
        XCTAssertEqual(navigator.route.section, .feeds)
    }

    // MARK: The open message

    func testOpeningAndClosingAMessageIsRecorded() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tree) = await landed(coordinator)

        navigator.selectMessage(message, isSearching: false, from: tree)
        XCTAssertEqual(navigator.route.mail.message, MessageRef(folder: "INBOX", uid: 9))
        XCTAssertEqual(coordinator.session.uid, 9)
        XCTAssertEqual(navigator.compactColumn(in: tree), .detail)

        navigator.selectMessage(nil, isSearching: false, from: tree)
        XCTAssertNil(navigator.route.mail.message)
        XCTAssertNil(coordinator.session.uid)
        XCTAssertEqual(navigator.compactColumn(in: tree), .content)
    }

    /// While searching, the open message is a result: neither the route nor
    /// the session takes it.
    func testASearchResultIsNotRecorded() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tree) = await landed(coordinator)

        navigator.selectMessage(message.inFolder("Archive"), isSearching: true, from: tree)

        XCTAssertEqual(navigator.envelope(in: tree), message.inFolder("Archive"))
        XCTAssertNil(navigator.route.mail.message)
        XCTAssertNil(coordinator.session.uid)
    }

    /// A row from another folder is not this folder's position.
    func testAnotherFoldersRowIsNotRecorded() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tree) = await landed(coordinator)

        navigator.selectMessage(message.inFolder("Archive"), isSearching: false, from: tree)

        XCTAssertNil(navigator.route.mail.message)
        XCTAssertNil(coordinator.session.uid)
    }

    /// Selecting the message already open records nothing, so the reading
    /// position the cursor holds for it survives.
    func testReselectingTheOpenMessageKeepsItsPosition() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tree) = await landed(coordinator)
        navigator.selectMessage(message, isSearching: false, from: tree)
        coordinator.recordMessageScroll(
            folderPath: "INBOX", uid: 9, messageID: "<nine@example.com>",
            position: ReadingPosition(offset: 640), atTop: false
        )

        navigator.selectMessage(message, isSearching: false, from: tree)

        XCTAssertEqual(coordinator.workingCursor?.messageScroll, 640)
    }

    /// The back gesture out of the compact reader drops the open message, so
    /// the same row can be opened again.
    func testTheBackGestureDropsTheOpenMessage() async throws {
        let coordinator = try makeCoordinator()
        let (navigator, tree) = await landed(coordinator)
        navigator.selectMessage(message, isSearching: false, from: tree)

        navigator.setCompactColumn(.content, isSearching: false, from: tree)

        XCTAssertNil(navigator.envelope(in: tree))
        XCTAssertEqual(navigator.compactColumn(in: tree), .content)
        XCTAssertNil(coordinator.session.uid)
    }
}
