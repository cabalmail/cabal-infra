import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A folder list, or a failed subscription toggle, that answers once its
/// session has ended (#2561): the third late answer #1849 named, after the
/// unread revert (#1851) and the late counts (#1886, #1892). Sign-out resets
/// the store's subscribed set, and each of these used to write the ended
/// account's set back, where it decided the next account's
/// unsubscribed-folder banner until that account's own list answered. Each
/// writer now asks `MailSessionStore.acceptsCounts(from:)` first, as the
/// saved-count seed beside them already did.
///
/// The session is ended the way `SignOutLateCountTests`' offline test ends
/// one: the client is marked ended at the teardown gate, which is what
/// sign-out does before it resets the store.
@MainActor
final class SignOutLateFolderListTests: XCTestCase {
    private var fixture: OfflineFolderFixture!
    private var state: AppState!

    override func setUp() async throws {
        fixture = OfflineFolderFixture()
        state = AppState()
    }

    override func tearDown() async throws {
        fixture = nil
        state = nil
    }

    // MARK: - The live list

    func testALiveFolderListFromAnEndedSessionLeavesTheSubscribedSetAlone() async throws {
        let client = try fixture.makeClient(folderState: FolderStateCache(), transport: FolderServerTransport())
        let sidebar = FolderListViewModel(client: client, mailStore: state.mailStore)
        endSession(of: client)

        await sidebar.loadFolderList()

        XCTAssertEqual(
            sidebar.folders.map(\.path).sorted(), ["Archive", "INBOX", "Projects"], "precondition: it answered"
        )
        XCTAssertFalse(sidebar.isShowingSavedCopy, "precondition: the live path ran")
        XCTAssertNil(state.mailStore.counts.subscribedFolderPaths)
    }

    /// Negative control: a live session's list is published as before.
    func testALiveSessionsFolderListPublishesTheSubscribedSet() async throws {
        let client = try fixture.makeClient(folderState: FolderStateCache(), transport: FolderServerTransport())
        let sidebar = FolderListViewModel(client: client, mailStore: state.mailStore)

        await sidebar.loadFolderList()

        XCTAssertEqual(state.mailStore.counts.subscribedFolderPaths, ["INBOX", "Projects"])
    }

    // MARK: - The saved copy

    func testASavedFolderListFromAnEndedSessionLeavesTheSubscribedSetAlone() async throws {
        let client = try fixture.makeClient(folderState: await fixture.savedState())
        let sidebar = FolderListViewModel(client: client, mailStore: state.mailStore)
        endSession(of: client)

        await sidebar.loadFolderList()

        XCTAssertTrue(sidebar.isShowingSavedCopy, "precondition: the offline path ran")
        XCTAssertNil(state.mailStore.counts.subscribedFolderPaths)
    }

    /// Negative control: offline, a live session's saved list is published.
    func testALiveSessionsSavedFolderListPublishesTheSubscribedSet() async throws {
        let client = try fixture.makeClient(folderState: await fixture.savedState())
        let sidebar = FolderListViewModel(client: client, mailStore: state.mailStore)

        await sidebar.loadFolderList()

        XCTAssertTrue(sidebar.isShowingSavedCopy, "precondition: the offline path ran")
        XCTAssertEqual(state.mailStore.counts.subscribedFolderPaths, ["INBOX", "Projects"])
    }

    // MARK: - A failed toggle's revert

    /// The toggle is applied while the session is live, the session ends
    /// while the server call is out, and the call then fails: the revert
    /// must not put the ended account's folder into the reset store.
    func testAFailedTogglesRevertAfterTheSessionEndedWritesNothing() async throws {
        let connectivity = FolderConnectivity()
        let whenAsked = SubscribeHook()
        let client = try fixture.makeClient(
            folderState: FolderStateCache(),
            transport: FailingSubscribeTransport(connectivity: connectivity, whenAsked: whenAsked)
        )
        let sidebar = FolderListViewModel(client: client, mailStore: state.mailStore)
        await sidebar.loadFolderList()
        XCTAssertEqual(state.mailStore.counts.subscribedFolderPaths, ["INBOX", "Projects"], "precondition")
        let appState = try XCTUnwrap(state)
        await whenAsked.set { @MainActor in
            XCTAssertEqual(
                appState.mailStore.counts.subscribedFolderPaths, ["INBOX"], "precondition: applied optimistically"
            )
            // What sign-out does, in its order: the session is marked
            // ended, then the store is reset.
            appState.sessionManager.teardownGate.markEnded(client)
            appState.mailStore.forgetAccount()
        }
        let projects = try XCTUnwrap(sidebar.folders.first { $0.path == "Projects" })

        await sidebar.toggleSubscription(projects)

        let asked = await whenAsked.calls
        XCTAssertEqual(asked, 1, "precondition: the server was asked, and the session ended meanwhile")
        XCTAssertNotNil(sidebar.errorMessage, "precondition: the toggle failed")
        XCTAssertNil(state.mailStore.counts.subscribedFolderPaths)
    }

    /// Negative control: a live session's failed toggle is reverted in the
    /// published set, as before.
    func testALiveSessionsFailedToggleIsReverted() async throws {
        let client = try fixture.makeClient(
            folderState: FolderStateCache(),
            transport: FailingSubscribeTransport(connectivity: FolderConnectivity(), whenAsked: SubscribeHook())
        )
        let sidebar = FolderListViewModel(client: client, mailStore: state.mailStore)
        await sidebar.loadFolderList()
        let projects = try XCTUnwrap(sidebar.folders.first { $0.path == "Projects" })

        await sidebar.toggleSubscription(projects)

        XCTAssertNotNil(sidebar.errorMessage, "precondition: the toggle failed")
        XCTAssertEqual(state.mailStore.counts.subscribedFolderPaths, ["INBOX", "Projects"])
    }

    // MARK: - Helpers

    private func endSession(of client: CabalmailClient) {
        state.sessionManager.teardownGate.markEnded(client)
    }
}

/// What a test runs when the server is asked to subscribe or unsubscribe.
private actor SubscribeHook {
    private var work: (@MainActor @Sendable () -> Void)?
    private(set) var calls = 0

    func set(_ work: @escaping @MainActor @Sendable () -> Void) {
        self.work = work
    }

    func run() async {
        calls += 1
        await work?()
    }
}

/// `FolderServerTransport` for everything but a subscription change, which
/// runs the hook and then fails as an unreachable server does.
private struct FailingSubscribeTransport: HTTPTransport {
    let connectivity: FolderConnectivity
    let whenAsked: SubscribeHook

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        guard path.hasSuffix("subscribe_folder") else {
            return try await SwitchableFolderTransport(connectivity: connectivity).perform(request)
        }
        await whenAsked.run()
        return try await UnreachableTransport().perform(request)
    }
}
