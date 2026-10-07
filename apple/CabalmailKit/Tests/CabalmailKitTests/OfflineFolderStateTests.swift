import XCTest
@testable import CabalmailKit

/// The folder list and folder counts must survive a launch without a
/// connection: `FolderStateCache` keeps what the server last returned on
/// disk, `foldersForDisplay` falls back to the saved list when the server
/// can't be reached, and `savedFolderStatus` hands back the saved counts.
final class OfflineFolderStateTests: XCTestCase {
    private var harness: FolderStateHarness!

    override func setUp() {
        harness = FolderStateHarness()
    }

    override func tearDown() {
        harness = nil
    }

    // MARK: - The offline launch

    func testOfflineLaunchDrawsTheFolderListAnEarlierLaunchFetched() async throws {
        let network = FolderNetwork()
        _ = try await harness.onlineSession(network)

        await network.set(online: false)
        let result = try await harness.launch(network).foldersForDisplay()

        XCTAssertEqual(result.folders.map(\.path), ["INBOX", "Archive", "Projects/Cabal"])
        XCTAssertEqual(result.folders.filter(\.isSubscribed).map(\.path), ["INBOX", "Projects/Cabal"])
        guard case .network = result.savedBecause else {
            return XCTFail("a saved list must say why it was used, got \(String(describing: result.savedBecause))")
        }
    }

    func testOfflineLaunchKeepsTheCountsAnEarlierLaunchFetched() async throws {
        let network = FolderNetwork()
        _ = try await harness.onlineSession(network)

        await network.set(online: false)
        let client = try harness.launch(network)
        let inbox = await client.savedFolderStatus(path: "INBOX")
        XCTAssertEqual(inbox?.messages, 22)
        XCTAssertEqual(inbox?.unseen, 2)
        XCTAssertEqual(inbox?.flagged, 1)
        let all = await client.savedFolderStatuses()
        XCTAssertEqual(all["Projects/Cabal"]?.unseen, 5)
        XCTAssertNil(all["Archive"], "never counted, so nothing to offer")
    }

    /// Negative control: without saved folder state, as before, an offline
    /// launch had no folder list to draw and no counts.
    func testWithoutSavedStateAnOfflineLaunchHasNothing() async throws {
        let network = FolderNetwork()
        let online = try harness.launch(network, persistent: false)
        _ = try await online.folders()
        _ = try await online.folderStatus(path: "INBOX", flagged: true)

        await network.set(online: false)
        let client = try harness.launch(network, persistent: false)
        await assertUnreachable { try await client.foldersForDisplay() }
        let inbox = await client.savedFolderStatus(path: "INBOX")
        XCTAssertNil(inbox)
    }

    func testOfflineLaunchWithNothingSavedStillThrows() async throws {
        let network = FolderNetwork()
        await network.set(online: false)
        let client = try harness.launch(network)
        await assertUnreachable { try await client.foldersForDisplay() }
    }

    func testOnlineAnswerIsNotMarkedSaved() async throws {
        let network = FolderNetwork()
        let result = try await harness.launch(network).foldersForDisplay()
        XCTAssertNil(result.savedBecause)
        XCTAssertEqual(result.folders.count, 3)
    }

    /// The sidebar and the folder menu only ever call `foldersForDisplay`, so
    /// its live answer has to be saved too, or nothing ever is.
    func testDisplayedLiveListIsSavedForTheNextLaunch() async throws {
        let network = FolderNetwork()
        _ = try await harness.launch(network).foldersForDisplay()

        await network.set(online: false)
        let result = try await harness.launch(network).foldersForDisplay()
        XCTAssertNotNil(result.savedBecause)
        XCTAssertEqual(result.folders.map(\.path), ["INBOX", "Archive", "Projects/Cabal"])
    }

    /// The tests above wire the cache by hand; this one goes through the
    /// factory the app uses, so dropping the directory there fails a test.
    func testClientFromMakeKeepsTheFoldersForTheNextLaunch() async throws {
        let network = FolderNetwork()
        let transport = ScriptedHTTPTransport { request in try await network.respond(to: request) }
        // One store across both launches, as the keychain is.
        let keychain = InMemorySecureStore()
        func makeLaunch() throws -> CabalmailClient {
            try CabalmailClient.make(
                configuration: FolderStateHarness.configuration,
                secureStore: keychain,
                httpTransport: transport,
                cacheDirectory: harness.root.appendingPathComponent("made")
            )
        }
        let first = try makeLaunch()
        let auth = try XCTUnwrap(first.authService as? CognitoAuthService)
        try await auth.adopt(
            tokens: AuthTokens(
                idToken: "ID", accessToken: "ACCESS", refreshToken: "REFRESH",
                tokenType: "Bearer", expiresAt: Date().addingTimeInterval(3600)
            )
        )
        _ = try await first.folders()
        _ = try await first.folderStatus(path: "INBOX", flagged: true)

        await network.set(online: false)
        let next = try makeLaunch()
        let result = try await next.foldersForDisplay()
        XCTAssertNotNil(result.savedBecause)
        XCTAssertEqual(result.folders.count, 3)
        let inbox = await next.savedFolderStatus(path: "INBOX")
        XCTAssertEqual(inbox?.unseen, 2)
    }

    // MARK: - What the saved state must not do

    /// Only an unreachable server falls back. A server that answers and
    /// refuses has something to say, and a stale list would hide it.
    func testServerRefusalDoesNotFallBack() async throws {
        let network = FolderNetwork()
        _ = try await harness.onlineSession(network)

        await network.set(refusal: 500)
        do {
            _ = try await harness.launch(network).foldersForDisplay()
            XCTFail("expected the refusal to throw")
        } catch let error as CabalmailError {
            guard case .http = error else { return XCTFail("expected .http, got \(error)") }
        }
    }

    /// `folders()` itself never answers from the saved list: callers that
    /// act on the list (the Spotlight gate, the launch reconcile) must only
    /// ever see a live one.
    func testPlainFoldersDoesNotServeTheSavedList() async throws {
        let network = FolderNetwork()
        _ = try await harness.onlineSession(network)

        await network.set(online: false)
        let client = try harness.launch(network)
        await assertUnreachable { try await client.folders() }
    }

    // MARK: - Keeping it current

    func testLaterFetchReplacesTheSavedListAndDropsGoneFoldersCounts() async throws {
        let network = FolderNetwork()
        _ = try await harness.onlineSession(network)
        await network.set(folders: ["INBOX", "Archive"], subscribed: ["INBOX"])
        _ = try await harness.launch(network).folders()

        await network.set(online: false)
        let client = try harness.launch(network)
        let result = try await client.foldersForDisplay()
        XCTAssertEqual(result.folders.map(\.path), ["INBOX", "Archive"])
        let gone = await client.savedFolderStatus(path: "Projects/Cabal")
        XCTAssertNil(gone, "a deleted folder's counts must not linger")
        let inbox = await client.savedFolderStatus(path: "INBOX")
        XCTAssertEqual(inbox?.unseen, 2)
    }

    /// The badge poller and the sidebar walk use the cheap STATUS, which
    /// carries no flagged count; it must not wipe the one the message list's
    /// STATUS saved.
    func testCheapStatusKeepsTheSavedFlaggedCount() async throws {
        let network = FolderNetwork()
        let client = try await harness.onlineSession(network)
        await network.set(status: "INBOX", FolderCounts(messages: 23, unseen: 3, flagged: 9))
        _ = try await client.folderStatus(path: "INBOX")

        await network.set(online: false)
        let relaunched = try harness.launch(network)
        let inbox = await relaunched.savedFolderStatus(path: "INBOX")
        XCTAssertEqual(inbox?.messages, 23)
        XCTAssertEqual(inbox?.unseen, 3)
        XCTAssertEqual(inbox?.flagged, 1, "the cheap STATUS asked for no flagged count")
    }

    // MARK: - Forgetting it

    /// Sign-out wipes it, so the next account on the device can't see this
    /// one's folders.
    func testSignOutForgetsTheSavedState() async throws {
        let network = FolderNetwork()
        let online = try await harness.onlineSession(network)
        await online.clearLocalData()

        await network.set(online: false)
        let client = try harness.launch(network)
        await assertUnreachable { try await client.foldersForDisplay() }
        let inbox = await client.savedFolderStatus(path: "INBOX")
        XCTAssertNil(inbox)
    }

    /// A STATUS the server answered before sign-out, but that lands after
    /// it, must not write the signed-out account's counts back.
    func testStatusInFlightAcrossSignOutDoesNotWriteBack() async throws {
        let network = FolderNetwork()
        let online = try await harness.onlineSession(network)

        await network.set(holdNextStatus: true)
        let inFlight = Task { try await online.folderStatus(path: "INBOX", flagged: true) }
        try await waitUntil { await network.isHoldingStatus }
        await online.clearLocalData()
        await network.releaseStatus()
        _ = try await inFlight.value

        let inbox = await online.savedFolderStatus(path: "INBOX")
        XCTAssertNil(inbox)
    }

    func testUnreadableSavedStateIsTreatedAsNone() async throws {
        let directory = harness.root.appendingPathComponent("folders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("folders.json"))

        let network = FolderNetwork()
        await network.set(online: false)
        let client = try harness.launch(network)
        await assertUnreachable { try await client.foldersForDisplay() }
    }}
