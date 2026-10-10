import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Where the folder list was scrolled, kept in the resume session for the
/// next launch (`ResumeSession.listAnchor`): recorded only for the session's
/// folder and never to the server, cleared when the folder changes, and
/// handed to the process's first mail landing and to no other.
@MainActor
final class NavStateCoordinatorListAnchorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ResumeSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "NavStateCoordinatorListAnchorTests.\(UUID().uuidString)"
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

    private func place(_ index: Int, in folder: String = "INBOX") throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: folder, messageID: "<row\(index)@example.com>", uid: UInt32(5000 - index), index: index
        ))
    }

    /// A session the last run left on `folder`, its list at `anchor`.
    private func saveSession(folder: String, anchor: ListAnchor?, section: ResumeSession.Section = .mail) {
        var session = ResumeSession(section: section, folder: folder)
        session.listAnchor = anchor
        store.saveSession(session)
    }

    // MARK: The record

    func testTheSessionKeepsThePlaceInItsFourFields() throws {
        var session = ResumeSession(section: .mail, folder: "INBOX")

        session.listAnchor = try place(300)

        XCTAssertEqual(session.listAnchorFolder, "INBOX")
        XCTAssertEqual(session.listAnchorMessageID, "<row300@example.com>")
        XCTAssertEqual(session.listAnchorUID, 4700)
        XCTAssertEqual(session.listAnchorIndex, 300)
        XCTAssertEqual(session.listAnchor, try place(300))
        session.listAnchor = nil
        XCTAssertNil(session.listAnchorFolder)
        XCTAssertNil(session.listAnchorIndex)
    }

    /// A place left behind for a folder the session has moved off reads as
    /// none.
    func testAPlaceForAnotherFolderThanTheSessionsReadsAsNone() throws {
        var session = ResumeSession(section: .mail, folder: "INBOX")
        session.listAnchor = try place(300)

        session.folder = "Archive"

        XCTAssertNil(session.listAnchor)
    }

    // MARK: Recording

    /// Local only: the session's own debounced save, and never a server
    /// write, so `list_scroll` stays dead on Apple.
    func testRecordingThePlaceSavesTheSessionAndWritesNothingToTheServer() async throws {
        saveSession(folder: "INBOX", anchor: nil)
        let coordinator = try makeCoordinator()

        coordinator.recordListAnchor(try place(300), folderPath: "INBOX")

        XCTAssertNil(store.loadSession()?.listAnchor, "debounced like every session save")
        // Past the cursor's 1 s save debounce: no server write was scheduled.
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertNil(coordinator.heldSnapshot)
        XCTAssertNil(coordinator.listScroll)
        XCTAssertEqual(store.loadSession()?.listAnchor, try place(300), "the session's debounce wrote it")
    }

    func testAPlaceForAnotherFolderThanTheSessionsIsNotRecorded() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")

        coordinator.recordListAnchor(try place(300, in: "Archive"), folderPath: "Archive")

        XCTAssertNil(coordinator.session.listAnchor)
    }

    func testBackAtTheTopClearsThePlace() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordListAnchor(try place(300), folderPath: "INBOX")

        coordinator.recordListAnchor(nil, folderPath: "INBOX")

        XCTAssertNil(coordinator.session.listAnchor)
    }

    /// The launch landing records the session's own folder again, and
    /// opening a message there does not move the list: both keep the place.
    func testRecordingTheSameFolderOrAMessageKeepsThePlace() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordListAnchor(try place(300), folderPath: "INBOX")

        coordinator.recordFolder("INBOX")
        coordinator.recordMessage(MessageRef(folder: "INBOX", uid: 9, messageId: "<nine@example.com>"))
        coordinator.recordNoMessage(folderPath: "INBOX")

        XCTAssertEqual(coordinator.session.listAnchor, try place(300))
    }

    func testAnotherFolderClearsThePlace() throws {
        let coordinator = try makeCoordinator()
        coordinator.recordFolder("INBOX")
        coordinator.recordListAnchor(try place(300), folderPath: "INBOX")

        coordinator.recordFolder("Archive")

        XCTAssertNil(coordinator.session.listAnchor)
        coordinator.recordFolder("INBOX")
        XCTAssertNil(coordinator.session.listAnchor, "going back does not bring it back")
    }

    // MARK: The launch

    func testTheFirstMailLandingCarriesTheLaunchPlaceOnce() throws {
        saveSession(folder: "Archive", anchor: try place(300, in: "Archive"))
        let coordinator = try makeCoordinator()

        let first = coordinator.mailLaunchTarget()
        let second = coordinator.mailLaunchTarget()

        XCTAssertEqual(first.folderPath, "Archive")
        XCTAssertEqual(first.listAnchor, try place(300, in: "Archive"))
        XCTAssertEqual(second.folderPath, "Archive")
        XCTAssertNil(second.listAnchor, "a window opened later starts at the top")
    }

    /// The launch opened on Feeds, and the user's first visit to Mail is the
    /// process's first mail landing: it still gets the place.
    func testAFeedsLandingLeavesTheLaunchPlaceForTheFirstMailLanding() async throws {
        saveSession(folder: "Archive", anchor: try place(300, in: "Archive"), section: .feeds)
        let coordinator = try makeCoordinator()

        _ = await coordinator.consumeFeedsLaunchTarget()
        let target = coordinator.mailLaunchTarget()

        XCTAssertEqual(target.listAnchor, try place(300, in: "Archive"))
    }

    /// A deep link took the launch (`SceneNavigator.navigate(to:)`): the
    /// place is not for where the user went.
    func testANavigationDiscardsTheLaunchPlace() throws {
        saveSession(folder: "Archive", anchor: try place(300, in: "Archive"))
        let coordinator = try makeCoordinator()

        coordinator.endLaunchSnapshot()
        coordinator.recordFolder("Archive")
        let target = coordinator.mailLaunchTarget()

        XCTAssertEqual(target.folderPath, "Archive")
        XCTAssertNil(target.listAnchor)
        XCTAssertTrue(coordinator.didConsumeLaunchSession)
    }

    /// A window the system restored lands on its own stored folder, with
    /// the place it stored beside it (`StoredRoute`): the session's is not
    /// given to it, nor kept for a later landing.
    func testAStoredFolderLandingSpendsTheLaunchPlaceWithoutTakingIt() throws {
        saveSession(folder: "Archive", anchor: try place(300, in: "Archive"))
        let coordinator = try makeCoordinator()

        let stored = coordinator.mailLaunchTarget(stored: AppRoute.Mail(folderPath: "Archive"))
        let later = coordinator.mailLaunchTarget()

        XCTAssertNil(stored.listAnchor)
        XCTAssertNil(later.listAnchor)
    }
}
