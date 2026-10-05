import XCTest
import CabalmailKit
@testable import Cabalmail

/// Counts that a session's own work fetches but that only answer once the
/// session is ending (#1848). Sign-out clears the folder counts before it
/// awaits the push deregistration and the local wipe, with the signed-in
/// views still on screen, and the list's refreshes run in tasks of their own
/// that outlive the views. A STATUS that answered in that time used to write
/// the last account's counts back after the reset, so the next account
/// started from them and saved their totals as its own. Each writer of a
/// fetched count now asks `AppState.acceptsCounts(from:)` first.
///
/// Every sign-in starts the badge poller, whose first tick asks the shared
/// `FakeImapClient` for INBOX's STATUS at once, and the fake answers any
/// path from one queue. So each test waits for that tick before it holds
/// a call, and scripts the Archive reply only just before releasing it, so
/// the tick can neither take the reply nor be the call held.
@MainActor
final class SignOutLateCountTests: XCTestCase {
    private var harness: SessionHarness!
    private var gate: LateCountHookGate?
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sign-out-late-counts-\(UUID().uuidString)")
    private let archive = FolderStatus(messages: 40, unseen: 3)

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        gate?.release()
        await harness?.tearDown()
        harness = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// The sidebar's STATUS answers while the sign-out waits in
    /// `sessionWillEnd`: nothing is written back, then or after.
    func testASidebarStatusThatAnswersDuringTheTeardownIsDropped() async throws {
        let midTeardown = try await signOutWithASidebarStatusLandingMidTeardown()

        XCTAssertEqual(midTeardown, [:], "nothing written back while the teardown waits")
        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.appState.folderUnreadCounts, [:])
        XCTAssertEqual(harness.appState.folderTotalCounts, [:])
    }

    /// The next account's unread change saves that account's own total, not
    /// the last account's 40.
    func testTheNextAccountSavesItsOwnTotal() async throws {
        _ = try await signOutWithASidebarStatusLandingMidTeardown()
        try await signIn(as: "bob")
        let cache = FolderStateCache(directory: root.appendingPathComponent("folders"))
        await cache.recordStatus(FolderStatus(messages: 11, unseen: 3), for: "Archive", ifUnchangedSince: 0)
        harness.appState.savedFolderCounts.cache = cache

        harness.appState.setUnreadCount(folderPath: "Archive", count: 1)
        try await eventually { await cache.lastKnownStatus(for: "Archive")?.unseen == 1 }

        let saved = await cache.lastKnownStatus(for: "Archive")
        XCTAssertEqual(saved?.messages, 11)
    }

    /// A STATUS from the last session that only answers once the next
    /// account is signed in is dropped too: the session it belongs to has
    /// ended, whatever is wired now.
    func testASidebarStatusThatAnswersAfterTheNextSignInIsDropped() async throws {
        try await signIn(as: "alice")
        let sidebar = FolderListViewModel(client: try XCTUnwrap(harness.appState.client), appState: harness.appState)
        let refresh = await holdASidebarStatus(on: sidebar)
        await harness.appState.signOut()
        try await signIn(as: "bob")

        await releaseTheHeldStatusWithArchive()
        await refresh.value
        let statusCalls = await harness.imap.statusCalls
        XCTAssertEqual(
            statusCalls.map(\.path), ["INBOX", "Archive", "INBOX"], "precondition: the held call is the sidebar's"
        )

        XCTAssertNil(harness.appState.folderUnreadCounts["Archive"])
        XCTAssertNil(harness.appState.folderTotalCounts["Archive"])
    }

    /// Negative control: a live session's STATUS is published as before.
    func testALiveSessionsSidebarStatusIsPublished() async throws {
        try await signIn(as: "alice")
        let sidebar = FolderListViewModel(client: try XCTUnwrap(harness.appState.client), appState: harness.appState)
        await harness.imap.scriptStatusResults([.success(archive)])

        await sidebar.refreshFolderCount(path: "Archive")

        XCTAssertEqual(harness.appState.folderUnreadCounts["Archive"], 3)
        XCTAssertEqual(harness.appState.folderTotalCounts["Archive"], 40)
    }

    /// The message list's STATUS, published to the sidebar or saved as the
    /// counts it shows, stays in the list once its session has ended. The
    /// list's own pills still take it: the view is on its way out.
    func testAListStatusFromAnEndedSessionReachesNeitherTheSidebarNorTheSavedCounts() async throws {
        try await signIn(as: "alice")
        let list = try makeList(over: XCTUnwrap(harness.appState.client))
        await harness.appState.signOut()
        let cache = FolderStateCache(directory: root.appendingPathComponent("folders"))
        await cache.recordStatus(FolderStatus(messages: 11, unseen: 3), for: "Archive", ifUnchangedSince: 0)
        harness.appState.savedFolderCounts.cache = cache

        _ = list.applyStatusCounts(archive)
        _ = list.applyStatusCounts(archive, mayPredateRemoval: true)

        XCTAssertEqual(list.allCount, 40)
        XCTAssertEqual(harness.appState.folderUnreadCounts, [:])
        XCTAssertEqual(harness.appState.folderTotalCounts, [:])
        try await Task.sleep(for: .milliseconds(200))
        let saved = await cache.lastKnownStatus(for: "Archive")
        XCTAssertEqual(saved?.messages, 11, "the saved counts are not the ended session's")
    }

    /// Mark All as Read and Empty Trash that finish after the sign-out set no
    /// badge for the account that left.
    func testMarkAllReadAndEmptyTrashFinishingAfterASignOutSetNoCounts() async throws {
        try await signIn(as: "alice")
        let client = try XCTUnwrap(harness.appState.client)
        let sidebar = FolderListViewModel(client: client, appState: harness.appState)
        await harness.appState.signOut()
        await harness.imap.scriptMarkFolderReadResults([.success(3)])
        await harness.imap.scriptEmptyTrashResults([.success(())])

        try await FolderMarkAllRead.perform(folderPath: "Archive", client: client, appState: harness.appState)
        await sidebar.emptyTrash()

        XCTAssertEqual(harness.appState.folderUnreadCounts, [:])
        XCTAssertEqual(harness.appState.folderTotalCounts, [:])
    }

    /// The offline sidebar seeds its badges from the saved counts after an
    /// await. A load that resumes once its session has ended seeds nothing;
    /// `OfflineSidebarTests` pins the seeding itself.
    func testAnOfflineSidebarLoadFromAnEndedSessionSeedsNoCounts() async throws {
        let fixture = OfflineFolderFixture()
        let client = try fixture.makeClient(folderState: await fixture.savedState())
        let state = AppState()
        let sidebar = FolderListViewModel(client: client, appState: state)
        state.teardownGate.markEnded(client)

        await sidebar.loadFolderList()

        XCTAssertTrue(sidebar.isShowingSavedCopy, "precondition: the offline path ran")
        XCTAssertEqual(state.folderUnreadCounts, [:])
        XCTAssertEqual(state.folderTotalCounts, [:])
        XCTAssertEqual(state.savedFolderCounts.seededPaths, [])
    }

    // MARK: - Helpers

    /// Signs alice in, holds a sidebar STATUS for Archive, starts a sign-out
    /// and holds it in `sessionWillEnd`, then lets the STATUS answer before
    /// the teardown resumes. Returns the unread counts as they stood then.
    private func signOutWithASidebarStatusLandingMidTeardown() async throws -> [String: Int] {
        try await signIn(as: "alice")
        let state = harness.appState
        let sidebar = FolderListViewModel(client: try XCTUnwrap(state.client), appState: state)
        let refresh = await holdASidebarStatus(on: sidebar)

        let gate = holdFirstSessionWillEnd()
        let signOut = Task { await state.signOut() }
        await fulfillment(of: [gate.arrival], timeout: defaultWaitTimeout)

        await releaseTheHeldStatusWithArchive()
        await refresh.value
        let midTeardown = state.folderUnreadCounts
        gate.release()
        await signOut.value
        return midTeardown
    }

    /// Starts the sidebar's STATUS for Archive and returns once it is held
    /// at the fake. Call after the sign-in's badge tick has answered.
    private func holdASidebarStatus(on sidebar: FolderListViewModel) async -> Task<Void, Never> {
        await harness.imap.holdNext(.status)
        let refresh = Task { await sidebar.refreshFolderCount(path: "Archive") }
        await harness.imap.awaitHeld(.status)
        return refresh
    }

    /// Scripts the Archive reply (40 messages, 3 unread) and lets the held
    /// call take it.
    private func releaseTheHeldStatusWithArchive() async {
        await harness.imap.scriptStatusResults([.success(archive)])
        await harness.imap.releaseHeld(.status)
    }

    private func makeList(over client: CabalmailClient) -> MessageListViewModel {
        MessageListViewModel(
            folder: Folder(path: "Archive", attributes: [], isSubscribed: true),
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()),
            appState: harness.appState
        )
    }

    /// Signs `username` in and waits for the badge poller's first INBOX
    /// tick to have answered (unscripted, so it fails and writes nothing);
    /// the next tick is a minute away.
    private func signIn(as username: String) async throws {
        let ticks = await inboxStatusCalls()
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-\(username)"))
        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: username, password: SignInScript.password
        )
        XCTAssertEqual(harness.appState.status, .signedIn, "precondition: \(username) signed in")
        let deadline = ContinuousClock.now + .seconds(defaultWaitTimeout)
        while await inboxStatusCalls() == ticks {
            guard ContinuousClock.now < deadline else { return XCTFail("the badge poller never ticked") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func inboxStatusCalls() async -> Int {
        await harness.imap.statusCalls.filter { $0.path == "INBOX" }.count
    }

    private func holdFirstSessionWillEnd() -> LateCountHookGate {
        let gate = LateCountHookGate(arrival: expectation(description: "the teardown reached sessionWillEnd"))
        let original = harness.appState.sessionEnvironment.hooks.sessionWillEnd
        harness.appState.sessionEnvironment.hooks.sessionWillEnd = {
            await gate.holdFirstCall()
            await original()
        }
        self.gate = gate
        return gate
    }
}

/// Holds the first `sessionWillEnd` until `release()`, standing in for the
/// push deregistration's network wait.
@MainActor
private final class LateCountHookGate {
    let arrival: XCTestExpectation
    private var used = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?

    init(arrival: XCTestExpectation) {
        self.arrival = arrival
    }

    func holdFirstCall() async {
        guard !used, !released else { return }
        used = true
        await withCheckedContinuation { continuation in
            held = continuation
            arrival.fulfill()
        }
    }

    func release() {
        released = true
        held?.resume()
        held = nil
    }
}
