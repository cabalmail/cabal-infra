import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Unread changes from a message action that land after its server call,
/// once the session that made them has ended (#1851): the revert when a
/// move, dispose, flag change or purge fails, and a bulk mark read that
/// answers late. Each test holds the call, signs alice out and bob in, gives
/// bob counts of his own for the folders involved (in memory and in a saved
/// folder state, as stage keeps it),
/// then lets the call answer. Before #1851 the late change moved bob's
/// counts by alice's change and saved the result as his.
///
/// Every sign-in's badge poller asks the shared fake for INBOX's STATUS at
/// once, so each sign-in waits for that tick before anything is held.
@MainActor
final class SignOutLateDeltaTests: XCTestCase {
    private var harness: SessionHarness!
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sign-out-late-deltas-\(UUID().uuidString)")
    private let unread = [
        TestFixtures.makeEnvelope(uid: 1),
        TestFixtures.makeEnvelope(uid: 2),
    ]
    private static let refused = CabalmailError.server(code: "500", message: "refused")

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testAFailedMovesRevertAfterTheNextSignInChangesNothing() async throws {
        try await assertLateChangeIsDropped(held: .move) { imap in
            await imap.scriptMoveResults([.failure(Self.refused)])
        } run: { list, envelopes in
            await list.moveTo(envelopes[0], destination: "Archive")
        }
    }

    func testAFailedBulkMovesRevertAfterTheNextSignInChangesNothing() async throws {
        try await assertLateChangeIsDropped(held: .move) { imap in
            await imap.scriptMoveResults([.failure(Self.refused)])
        } run: { list, envelopes in
            await list.moveMessages(refs: Set(envelopes.map { list.rowRef(for: $0) }), to: "Archive")
        }
    }

    func testAPartlyFailedBulkMovesRevertAfterTheNextSignInChangesNothing() async throws {
        try await assertLateChangeIsDropped(held: .move) { imap in
            await imap.scriptMoveResults([.failure(CabalmailError.bulkPartialFailure(succeeded: [1], failed: [2]))])
        } run: { list, envelopes in
            await list.moveMessages(refs: Set(envelopes.map { list.rowRef(for: $0) }), to: "Archive")
        }
    }

    func testAFailedFlagChangesRevertAfterTheNextSignInChangesNothing() async throws {
        try await assertLateChangeIsDropped(held: .setFlags) { imap in
            await imap.scriptFlagResults([.failure(Self.refused)])
        } run: { list, envelopes in
            await list.setFlag(.seen, add: true, envelope: envelopes[0])
        }
    }

    func testAFailedDisposesRevertAfterTheNextSignInChangesNothing() async throws {
        try await assertLateChangeIsDropped(held: .move) { imap in
            await imap.scriptMoveResults([.failure(Self.refused)])
        } run: { list, envelopes in
            await list.dispose(envelopes[0])
        }
    }

    func testAFailedPurgesRevertAfterTheNextSignInChangesNothing() async throws {
        try await assertLateChangeIsDropped(folder: FolderTree.trashPath, held: .purge) { imap in
            await imap.scriptPurgeResults([.failure(Self.refused)])
        } run: { list, envelopes in
            await list.purgeMessages(refs: Set(envelopes.map { list.rowRef(for: $0) }))
        }
    }

    func testABulkMarkReadThatAnswersAfterTheNextSignInChangesNothing() async throws {
        try await assertLateChangeIsDropped(held: .setFlags) { _ in
        } run: { list, envelopes in
            await list.setSeen(true, refs: Set(envelopes.map { list.rowRef(for: $0) }))
        }
    }

    /// The reader's flag revert and failed-move restore land after their
    /// server call. For readers of alice's whose writes the server refuses
    /// once bob is signed in, neither moves his counts.
    func testTheReadersLateRevertsAfterTheNextSignInChangeNothing() async throws {
        try await signIn(as: "alice")
        let client = try XCTUnwrap(harness.appState.client)
        let reading = makeReader(of: unread[0], over: client)
        let disposing = makeReader(of: unread[1], over: client)
        await harness.imap.scriptFlagResults([.failure(Self.refused)])
        await harness.imap.scriptMoveResults([.failure(Self.refused)])
        await harness.imap.holdNext(.setFlags)
        await harness.imap.holdNext(.move)
        let read = Task { await reading.setSeen(true) }
        let dispose = Task { await disposing.dispose() }
        await harness.imap.awaitHeld(.setFlags)
        await harness.imap.awaitHeld(.move)
        await harness.appState.signOut()
        try await signIn(as: "bob")
        let cache = await giveBobCountsOfHisOwn()

        await harness.imap.releaseHeld(.setFlags)
        await harness.imap.releaseHeld(.move)
        await read.value
        await dispose.value
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(harness.appState.mailStore.counts.folderUnreadCounts["INBOX"], 5)
        let saved = await cache.lastKnownStatus(for: "INBOX")
        XCTAssertEqual(saved?.unseen, 5)
    }

    /// Negative control: a live session's reader still moves the count, and
    /// a refusal still hands it back.
    func testALiveReadersRevertsStillMoveTheCount() async throws {
        try await signIn(as: "alice")
        let client = try XCTUnwrap(harness.appState.client)
        let reading = makeReader(of: unread[0], over: client)
        let disposing = makeReader(of: unread[1], over: client)
        harness.appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 5, total: 50)
        await harness.imap.scriptFlagResults([.failure(Self.refused)])
        await harness.imap.scriptMoveResults([.failure(Self.refused)])

        await harness.imap.holdNext(.setFlags)
        let read = Task { await reading.setSeen(true) }
        await harness.imap.awaitHeld(.setFlags)
        XCTAssertEqual(harness.appState.mailStore.counts.folderUnreadCounts["INBOX"], 4)
        await harness.imap.releaseHeld(.setFlags)
        await read.value
        XCTAssertEqual(harness.appState.mailStore.counts.folderUnreadCounts["INBOX"], 5)

        await harness.imap.holdNext(.move)
        let dispose = Task { await disposing.dispose() }
        await harness.imap.awaitHeld(.move)
        XCTAssertEqual(harness.appState.mailStore.counts.folderUnreadCounts["INBOX"], 4)
        await harness.imap.releaseHeld(.move)
        await dispose.value
        XCTAssertEqual(harness.appState.mailStore.counts.folderUnreadCounts["INBOX"], 5)
    }

    /// Negative control: in a live session the bulk mark read still takes
    /// INBOX's unread count down.
    func testABulkMarkReadInALiveSessionStillLowersTheCount() async throws {
        try await signIn(as: "alice")
        let list = try makeList(folder: "INBOX", over: XCTUnwrap(harness.appState.client))
        harness.appState.mailStore.counts.setFolderCounts(folderPath: "INBOX", unread: 5, total: 50)

        await list.setSeen(true, refs: Set(unread.map { list.rowRef(for: $0) }))

        XCTAssertEqual(harness.appState.mailStore.counts.folderUnreadCounts["INBOX"], 3)
    }

    // MARK: - Helpers

    /// Runs `run` on a list of alice's over two unread messages in `folder`,
    /// with the `held` server call held, signs alice out and bob in, gives
    /// bob 5 unread of 50 in INBOX, Archive and Trash, then lets the call
    /// answer as `script` scripted it, and checks bob's counts did not move.
    private func assertLateChangeIsDropped(
        folder: String = "INBOX",
        held: FakeImapClient.HeldCall,
        script: @MainActor (FakeImapClient) async -> Void,
        run: @escaping @MainActor (MessageListViewModel, [Envelope]) async -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await signIn(as: "alice")
        let list = try makeList(folder: folder, over: XCTUnwrap(harness.appState.client))
        let envelopes = unread
        await script(harness.imap)
        await harness.imap.holdNext(held)
        let action = Task { await run(list, envelopes) }
        await harness.imap.awaitHeld(held)
        await harness.appState.signOut()
        try await signIn(as: "bob")
        let cache = await giveBobCountsOfHisOwn()

        await harness.imap.releaseHeld(held)
        await action.value
        try await Task.sleep(for: .milliseconds(200))

        let paths = ["INBOX", "Archive", FolderTree.trashPath]
        for path in paths {
            XCTAssertEqual(
                harness.appState.mailStore.counts.folderUnreadCounts[path], 5, "\(path) unread", file: file, line: line
            )
            let saved = await cache.lastKnownStatus(for: path)
            XCTAssertEqual(saved?.unseen, 5, "\(path) saved unread", file: file, line: line)
        }
    }

    private func giveBobCountsOfHisOwn() async -> FolderStateCache {
        let cache = FolderStateCache(directory: root.appendingPathComponent("folders-\(UUID().uuidString)"))
        harness.appState.mailStore.counts.savedFolderCounts.cache = cache
        for path in ["INBOX", "Archive", FolderTree.trashPath] {
            await cache.recordStatus(FolderStatus(messages: 50, unseen: 5), for: path, ifUnchangedSince: 0)
            harness.appState.mailStore.counts.setFolderCounts(folderPath: path, unread: 5, total: 50)
        }
        return cache
    }

    /// A reader of `envelope` in INBOX over `client`, wired as the view
    /// wires it.
    private func makeReader(of envelope: Envelope, over client: CabalmailClient) -> MessageDetailViewModel {
        let reader = MessageDetailViewModel(
            folder: Folder(path: "INBOX", attributes: [], isSubscribed: true),
            envelope: envelope,
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore())
        )
        MessageDetailView.relayOutcomes(of: reader, to: harness.appState.mailStore)
        return reader
    }

    private func makeList(folder: String, over client: CabalmailClient) -> MessageListViewModel {
        let list = MessageListViewModel(
            folder: Folder(path: folder, attributes: [], isSubscribed: true),
            client: client,
            preferences: Preferences(store: InMemoryPreferenceStore()),
            mailStore: harness.appState.mailStore
        )
        list.envelopes = unread
        return list
    }

    /// Signs `username` in and waits for the badge poller's first INBOX
    /// tick to have answered (unscripted, so it fails and writes nothing).
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
}
