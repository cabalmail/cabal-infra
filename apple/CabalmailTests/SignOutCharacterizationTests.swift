import XCTest
import Observation
import CabalmailKit
@testable import CabalmailUI

/// Workstream 0.8 characterization suite: `AppState.signOut()` with a wired
/// session, the teardown past the no-client guard that
/// `SessionTeardownCharacterizationTests` could not reach without the
/// `SessionEnvironment` seam. The rearchitecture (workstream 1.3) replaces
/// this teardown with a per-account session manager; these record what it
/// does today, step by step and in order, quirks included.
///
/// Protects the #1703 teardown (one sign-out path shared by a deliberate Sign
/// Out and an expiry), the cross-account wipe of locally cached mail, the
/// push deregistration window (`sessionWillEnd` while the tokens still
/// authenticate) and the watch hand-off's `sessionDidEnd`. What sign-out
/// leaves behind (#1825), an expiry with a wired session and a second
/// teardown overlapping the first are in
/// `SignOutLeftoversCharacterizationTests`,
/// `WiredSessionExpiryCharacterizationTests` and
/// `SignOutReentrancyCharacterizationTests`.
@MainActor
final class SignOutCharacterizationTests: XCTestCase {
    private var harness: SessionHarness!

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    /// The whole order, observed from inside each step: the pollers and the
    /// observer stop before anything else (the badge count is back to zero
    /// and the feed poller is cancelled, not just dropped, by the time
    /// `sessionWillEnd` runs); `sessionWillEnd` runs while the
    /// tokens, the cached mail and the resume state are all still there and
    /// the app still reads as signed in; the cached mail is gone before the
    /// tokens are; `sessionDidEnd` runs once the tokens are gone, with the
    /// client still wired and the resume state not yet cleared; and the
    /// status write comes last, after the cursor, compose and client are
    /// dropped.
    func testSignOutRunsItsStepsInOrder() async throws {
        let store = installProbingStore()
        await harness.imap.scriptStatusResults([.success(FolderStatus(messages: 40, unseen: 7))])
        await SignOutSuiteSteps.signIn(harness)
        try await waitUntilOnMainActor { self.harness.appState.mailStore.counts.inboxUnreadCount == 7 }
        let client = try XCTUnwrap(harness.appState.client)
        let feedPoll = try XCTUnwrap(harness.appState.sessionManager.pollers.feedRefreshTask)
        try await seedLocalData(in: client)
        seedResumeState()
        let moments = recordTeardownMoments(of: client, store: store)

        await harness.appState.signOut()

        let live = TeardownMoment(
            status: .signedIn, sameClient: true, navWired: true, observing: false, feedPolling: false,
            inboxUnread: 0, hasCachedFiles: true, tokensStored: true, resumeStored: true, composeSession: 0
        )
        XCTAssertEqual(moments.willEnd, [live])
        XCTAssertEqual(store.cachedFilesAtTokenRemoval, [false], "the cached mail is wiped before the tokens")
        var didEnd = live
        didEnd.hasCachedFiles = false
        didEnd.tokensStored = false
        XCTAssertEqual(moments.didEnd, [didEnd])
        var finalWrite = didEnd
        finalWrite.sameClient = false
        finalWrite.navWired = false
        finalWrite.resumeStored = false
        finalWrite.composeSession = 1
        XCTAssertEqual(moments.statusWrites, [finalWrite], "status is written once, last")
        XCTAssertTrue(feedPoll.isCancelled, "the feed poller was cancelled, not just dropped")
        XCTAssertEqual(harness.appState.status, .signedOut)
    }

    /// Every cache the session's client keeps is emptied: envelope
    /// snapshots, bodies, drafts, the outbox and the address list. The saved
    /// folder state is cleared too: its generation moves, so a fetch still in
    /// flight can't write it back (the harness's copy is memory-only, so its
    /// contents can't be seen). The client itself is dropped but still
    /// answers, so this reads its caches directly.
    func testSignOutWipesEveryCacheOfTheSessionClient() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let client = try XCTUnwrap(harness.appState.client)
        try await seedLocalData(in: client)
        let folderGeneration = await client.folderStateCache.generation
        let addressGeneration = await client.addressCache.generation

        await harness.appState.signOut()

        let snapshot = await client.envelopeCache.snapshot(for: "INBOX")
        XCTAssertNil(snapshot)
        let body = await client.bodyCache.fetch(folder: "INBOX", uidValidity: 1, uid: 9)
        XCTAssertNil(body)
        let drafts = try await client.draftStore.list()
        XCTAssertEqual(drafts, [])
        let queued = try await client.outbox.list()
        XCTAssertEqual(queued, [])
        let addresses = await client.addressCache.get()
        XCTAssertNil(addresses)
        let folderGenerationAfter = await client.folderStateCache.generation
        XCTAssertEqual(folderGenerationAfter, folderGeneration + 1)
        let addressGenerationAfter = await client.addressCache.generation
        XCTAssertEqual(addressGenerationAfter, addressGeneration + 1)
        XCTAssertFalse(harness.hasStoredTokens)
    }

    /// The cursor's local resume state (session record, reading positions,
    /// the offered cross-device cursor) is cleared from the defaults it was
    /// built over; compose's session ends; the client, cursor and
    /// preferences sync are dropped, the sync stopped rather than just
    /// released; the saved counts stop writing; and a stale reason is
    /// cleared for the blank form.
    func testSignOutForgetsTheResumeStateAndDropsTheSessionObjects() async throws {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        let state = harness.appState
        state.usePreferences(preferences)
        await SignOutSuiteSteps.signIn(harness)
        _ = try XCTUnwrap(state.client)
        try await waitUntilOnMainActor { preferences.onLocalChange != nil }
        seedResumeState()
        state.sessionManager.signedOutReason = .sessionExpired

        await state.signOut()

        let resume = ResumeSessionStore(defaults: harness.defaults)
        XCTAssertNil(resume.loadSession())
        XCTAssertEqual(resume.loadPositions().count, 0)
        XCTAssertEqual(resume.offeredForeignUpdatedAt, 0)
        XCTAssertEqual(state.composeSlots.session, 1)
        XCTAssertNil(state.client)
        XCTAssertNil(state.navCoordinator)
        XCTAssertNil(state.prefsCoordinator)
        XCTAssertNil(preferences.onLocalChange, "the sync was stopped, not just released")
        XCTAssertNil(state.mailStore.counts.savedFolderCounts.cache)
        XCTAssertEqual(state.status, .signedOut)
        XCTAssertNil(state.signedOutReason)
    }

    /// Search is the window's (`SceneNavigator`), not the app's: a new
    /// sign-in gets a new navigator (`SignedInRootView`), and with it a new
    /// search model, so nothing of the last account's query or results
    /// carries over.
    func testANewClientsNavigatorGetsANewSearchModel() async throws {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        let state = harness.appState
        state.usePreferences(preferences)
        await SignOutSuiteSteps.signIn(harness)
        let first = try XCTUnwrap(state.client)
        let search = SceneNavigator(appState: state)
            .searchModel(client: first, preferences: preferences, mailStore: state.mailStore)

        await state.signOut()
        await SignOutSuiteSteps.signIn(harness, idToken: "ID-2")
        let second = try XCTUnwrap(state.client)
        let next = SceneNavigator(appState: state)
            .searchModel(client: second, preferences: preferences, mailStore: state.mailStore)

        XCTAssertFalse(next === search)
        XCTAssertTrue(next.client === second)
    }

    // MARK: - Helpers

    /// Wraps the harness's store so the moment the tokens are removed can be
    /// observed. The environment still records `makeSecureStore`.
    private func installProbingStore() -> ProbingSecureStore {
        let store = ProbingSecureStore(base: harness.secureStore)
        let original = harness.appState.sessionManager.sessionEnvironment.makeSecureStore
        harness.appState.sessionManager.sessionEnvironment.makeSecureStore = {
            _ = original()
            return store
        }
        return store
    }

    /// Something in every cache `clearLocalData()` covers that can hold
    /// something here: the four on-disk caches and the address list. Each is
    /// read back, so no wiped-cache assertion can pass on a seed that landed
    /// nowhere.
    private func seedLocalData(in client: CabalmailClient) async throws {
        let envelope = TestFixtures.makeEnvelope(uid: 9)
        try await client.envelopeCache.store(
            EnvelopeCache.Snapshot(uidValidity: 1, uidNext: 10, envelopes: [9: envelope]), for: "INBOX"
        )
        try await client.bodyCache.store(folder: "INBOX", uidValidity: 1, uid: 9, bytes: Data("raw".utf8))
        try await client.draftStore.save(Draft(subject: "unsent"))
        let sender = EmailAddress(name: nil, mailbox: "alice", host: "x.cabalmail.example")
        try await client.outbox.enqueue(OutgoingMessage(from: sender, to: [sender], subject: "queued"))
        await client.addressCache.set([
            Address(address: "alice@x.cabalmail.example", subdomain: "x", tld: "cabalmail.example"),
        ])
        let snapshot = await client.envelopeCache.snapshot(for: "INBOX")
        XCTAssertNotNil(snapshot, "precondition: an envelope snapshot")
        let body = await client.bodyCache.fetch(folder: "INBOX", uidValidity: 1, uid: 9)
        XCTAssertNotNil(body, "precondition: a body")
        let drafts = try await client.draftStore.list()
        XCTAssertEqual(drafts.count, 1, "precondition: a draft")
        let queued = try await client.outbox.list()
        XCTAssertEqual(queued.count, 1, "precondition: an outbox item")
        let addresses = await client.addressCache.get()
        XCTAssertNotNil(addresses, "precondition: an address list")
        XCTAssertTrue(cachedFiles(under: client), "precondition: the caches hold files")
    }

    /// A session record, a reading position and an offered foreign cursor,
    /// written through the cursor the environment built.
    private func seedResumeState() {
        guard let coordinator = harness.appState.navCoordinator else {
            return XCTFail("no cursor wired")
        }
        coordinator.recordFolder("Archive")
        coordinator.savePosition(
            key: ReadingPositionKey.feed(itemID: "feed-1#k1"), anchor: "i2|0", offset: nil, atTop: false
        )
        coordinator.lastSeenUpdatedAt = 42
        coordinator.flushSession()
        let resume = ResumeSessionStore(defaults: harness.defaults)
        XCTAssertEqual(resume.loadSession()?.folder, "Archive", "precondition")
        XCTAssertEqual(resume.loadPositions().count, 1, "precondition")
        XCTAssertEqual(resume.offeredForeignUpdatedAt, 42, "precondition")
    }

    /// Snapshots the teardown from inside `sessionWillEnd`, the token
    /// removal, `sessionDidEnd` and the `status` write. Each hook still runs
    /// the harness's own, so the event log is unchanged. Nothing here holds
    /// the state strongly from the watch's side, so no cycle outlives the
    /// test.
    private func recordTeardownMoments(of client: CabalmailClient, store: ProbingSecureStore) -> TeardownMoments {
        let moments = TeardownMoments()
        let hooks = harness.appState.sessionManager.sessionEnvironment.hooks
        harness.appState.sessionManager.sessionEnvironment.hooks.sessionWillEnd = { [weak self, weak moments] in
            if let moment = self?.moment(of: client) { moments?.willEnd.append(moment) }
            await hooks.sessionWillEnd()
        }
        harness.appState.sessionManager.sessionEnvironment.hooks.sessionDidEnd = { [weak self, weak moments] in
            if let moment = self?.moment(of: client) { moments?.didEnd.append(moment) }
            hooks.sessionDidEnd()
        }
        store.onTokenRemoval { cachedFiles(under: client) }
        moments.statusWatch = StatusWriteWatch(harness.appState) { [weak self, weak moments] in
            if let moment = self?.moment(of: client) { moments?.statusWrites.append(moment) }
        }
        return moments
    }

    private func moment(of client: CabalmailClient) -> TeardownMoment {
        let state = harness.appState
        return TeardownMoment(
            status: state.status,
            sameClient: state.client === client,
            navWired: state.navCoordinator != nil,
            observing: state.sessionManager.sessionExpiryTask != nil,
            feedPolling: state.sessionManager.pollers.feedRefreshTask != nil,
            inboxUnread: state.mailStore.counts.inboxUnreadCount,
            hasCachedFiles: cachedFiles(under: client),
            tokensStored: harness.hasStoredTokens,
            resumeStored: ResumeSessionStore(defaults: harness.defaults).loadSession() != nil,
            composeSession: state.composeSlots.session
        )
    }
}

// MARK: - Shared helpers

/// The steps the sign-out suites share (this file's,
/// `SignOutLeftoversCharacterizationTests`,
/// `WiredSessionExpiryCharacterizationTests`,
/// `SignOutReentrancyCharacterizationTests` and
/// `SessionWiringCharacterizationTests`). A namespace rather than free
/// functions, so a same-named private helper in another suite can't clash.
@MainActor
enum SignOutSuiteSteps {
    /// Signs alice in through the harness: one scripted password sign-in.
    static func signIn(
        _ harness: SessionHarness, idToken: String = "ID-1", file: StaticString = #filePath, line: UInt = #line
    ) async {
        await harness.cognito.script(.passwordSignIn, .tokens(id: idToken))
        await harness.appState.signIn(controlDomain: "cabalmail.example", username: "alice", password: "hunter2")
        XCTAssertEqual(harness.appState.status, .signedIn, "precondition: signed in", file: file, line: line)
    }

    /// Waits for a session observer to end; its teardown cancels it, so its
    /// end is the moment the state is final. Bounded, so a signal that never
    /// arrives fails as a timeout rather than hanging the suite.
    static func awaitEnd(of task: Task<Void, Never>, in testCase: XCTestCase) async {
        let ended = testCase.expectation(description: "the session observer ended")
        Task {
            await task.value
            ended.fulfill()
        }
        await testCase.fulfillment(of: [ended], timeout: defaultWaitTimeout)
    }
}

/// Whether any regular file is left under the client's cache directories
/// (the harness puts all four in one per-client directory). Called from the
/// auth actor too, so it touches nothing but the file system.
private func cachedFiles(under client: CabalmailClient) -> Bool {
    let root = client.outbox.directory.deletingLastPathComponent()
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    let urls = walker?.allObjects.compactMap { $0 as? URL } ?? []
    return urls.contains { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
}

/// The session as seen from inside one teardown step.
private struct TeardownMoment: Equatable {
    var status: AppState.Status
    var sameClient: Bool
    var navWired: Bool
    var observing: Bool
    var feedPolling: Bool
    var inboxUnread: Int
    var hasCachedFiles: Bool
    var tokensStored: Bool
    var resumeStored: Bool
    var composeSession: Int
}

@MainActor
private final class TeardownMoments {
    var willEnd: [TeardownMoment] = []
    var didEnd: [TeardownMoment] = []
    var statusWrites: [TeardownMoment] = []
    var statusWatch: StatusWriteWatch?
}

/// Calls `onWrite` from inside every `status` write, before the new value
/// is stored (Observation's `onChange` runs in the write's `willSet`). Holds
/// the state weakly: the state's hooks hold what this reports into.
@MainActor
private final class StatusWriteWatch {
    private weak var state: AppState?
    private let onWrite: @MainActor () -> Void

    init(_ state: AppState, onWrite: @escaping @MainActor () -> Void) {
        self.state = state
        self.onWrite = onWrite
        arm()
    }

    private func arm() {
        withObservationTracking {
            _ = state?.status
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.onWrite()
                self?.arm()
            }
        }
    }
}

/// The harness's secure store, reporting what a probe saw at each removal
/// of the tokens. Thread-safe: the auth service calls it from its actor.
private final class ProbingSecureStore: SecureStore, @unchecked Sendable {
    private let base: SecureStore
    private let lock = NSLock()
    private var probe: (@Sendable () -> Bool)?
    private var seen: [Bool] = []

    init(base: SecureStore) {
        self.base = base
    }

    var cachedFilesAtTokenRemoval: [Bool] {
        lock.withLock { seen }
    }

    func onTokenRemoval(_ probe: @escaping @Sendable () -> Bool) {
        lock.withLock { self.probe = probe }
    }

    func set(_ value: Data, forKey key: String) throws {
        try base.set(value, forKey: key)
    }

    func get(_ key: String) throws -> Data? {
        try base.get(key)
    }

    func remove(_ key: String) throws {
        if key == SecureStoreKey.authTokens, let probe = lock.withLock({ probe }) {
            let result = probe()
            lock.withLock { seen.append(result) }
        }
        try base.remove(key)
    }
}
