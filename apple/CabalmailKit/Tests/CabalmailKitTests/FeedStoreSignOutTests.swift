import SQLite3
import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// Sign-out retires the ending session's feed store (#1937). Emptying it was
/// not enough: a feed sync the session started (the Feeds sidebar's, which
/// runs until the sidebar goes after the sign-out) kept writing, and the file
/// it wrote to is the one the next account's client opens, so that account
/// saw the previous one's feeds until its own first sync replaced them.
final class FeedStoreSignOutTests: XCTestCase {
    private static let configuration = Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
    )

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-sign-out-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let departing = RssSubscription(subscriptionId: "s1", feedId: "f1")
    private let lateArrival = RssSubscription(subscriptionId: "s2", feedId: "f2")

    func testARetiredStoreKeepsNothingAndTakesNoLaterWrite() async throws {
        let store = try RssStore(directory: root)
        try await store.upsertSubscription(departing)

        try await store.retire()

        do {
            try await store.upsertSubscription(lateArrival)
            XCTFail("a retired store took a write")
        } catch {}
        let next = try RssStore(directory: root)
        let left = try await next.subscriptions()
        XCTAssertEqual(left, [], "the next store on the file finds nothing of the last session's")
    }

    /// A clear that fails must still retire the store. `retire()` used to
    /// close the file only after `clear()` returned, so an SQLite failure
    /// (a busy lock, a full disk, a damaged search index) left the ending
    /// session's store open and taking writes — exactly what the retire
    /// exists to prevent (#1957).
    func testAStoreWhoseClearFailsIsStillRetired() async throws {
        let store = try RssStore(directory: root)
        try await store.upsertSubscription(departing)
        // A second connection holding a write lock makes the clear time out
        // busy, standing in for the failures that are not reproducible here.
        let lock = try lockTheStoreFile()

        do {
            try await store.retire()
            XCTFail("a clear that cannot run should fail the retire")
        } catch {}

        unlock(lock)
        do {
            try await store.upsertSubscription(lateArrival)
            XCTFail("a store whose retire threw still took a write")
        } catch {}
        let next = try RssStore(directory: root)
        let left = try await next.subscriptions().map(\.subscriptionId)
        XCTAssertEqual(left, ["s1"], "the failed clear deleted nothing, which the next sign-in's clear handles")
    }

    /// The control for the arm above: the lock really does stop a write, so
    /// the retire there failed on the injected failure and not on nothing.
    func testTheLockRefusesAnOrdinaryWrite() async throws {
        let store = try RssStore(directory: root)
        let lock = try lockTheStoreFile()
        defer { unlock(lock) }

        do {
            try await store.upsertSubscription(departing)
            XCTFail("the lock let a write through")
        } catch {}
    }

    /// Opens a second connection to the store's own file and holds a write
    /// transaction on it.
    private func lockTheStoreFile() throws -> OpaquePointer {
        var opened: OpaquePointer?
        let path = root.appendingPathComponent("rss.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(opened)
        XCTAssertEqual(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        return handle
    }

    private func unlock(_ handle: OpaquePointer) {
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close_v2(handle)
    }

    // The whole-client tests below run on macOS only. Clearing a client's
    // local data also empties its Spotlight index, and on an iOS or visionOS
    // simulator with no host app Core Spotlight's delete-all stalls for
    // minutes, past the test time allowance (the iOS Kit job on #1940). The
    // store-level test above covers the retire on every platform.
    #if os(macOS)
    /// The app's sign-out path, through a client the factory built: what a
    /// sync still in flight writes after the sign-out's clear never reaches
    /// the next client on the same cache directory.
    func testALateFeedWriteAfterTheSessionEndsNeverReachesTheNextClient() async throws {
        let client = try makeClient()
        let store = try XCTUnwrap(client.rssStore)
        try await store.upsertSubscription(departing)

        await client.clearLocalDataEndingSession()
        try? await store.upsertSubscription(lateArrival)

        let nextClient = try makeClient()
        let next = try XCTUnwrap(nextClient.rssStore)
        let left = try await next.subscriptions()
        XCTAssertEqual(left, [])
        await client.shutdown()
        await nextClient.shutdown()
    }

    /// The control: a client that carries on (a new account's, clearing what
    /// a different user left behind) keeps a working store.
    func testClearingWithoutEndingTheSessionKeepsTheStoreWorking() async throws {
        let client = try makeClient()
        let store = try XCTUnwrap(client.rssStore)
        try await store.upsertSubscription(departing)

        await client.clearLocalData()
        try await store.upsertSubscription(lateArrival)

        let kept = try await store.subscriptions()
        XCTAssertEqual(kept.map(\.subscriptionId), ["s2"])
        await client.shutdown()
    }

    private func makeClient() throws -> CabalmailClient {
        try CabalmailClient.make(
            configuration: Self.configuration,
            secureStore: InMemorySecureStore(),
            httpTransport: ScriptedHTTPTransport { _ in throw CabalmailError.network("offline") },
            cacheDirectory: root
        )
    }
    #endif
}
