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

        lock.release()
        do {
            try await store.upsertSubscription(lateArrival)
            XCTFail("a store whose retire threw still took a write")
        } catch {}
        let next = try RssStore(directory: root)
        let left = try await next.subscriptions().map(\.subscriptionId)
        XCTAssertEqual(left, ["s1"], "the failed clear deleted nothing, which the next sign-in's clear handles")
    }

    #if DEBUG
    /// A clear is one transaction. Its six deletes used to run one after
    /// another, so a failure at the fifth left the queue, the cursors, the
    /// items and the subscriptions gone and the folders still there: a
    /// store neither the last account's nor empty.
    func testAClearThatFailsPartWayDeletesNothing() async throws {
        let store = try RssStore(directory: root)
        _ = try await store.replaceCatalog(RssCatalog(
            folders: [RssFolder(folderId: "fo", name: "Tech")],
            subscriptions: [RssSubscription(subscriptionId: "s1", feedId: "f1", folderId: "fo")]))
        try await store.upsertItems([RssItem(feedId: "f1", itemId: "a", sortKey: "a")])
        try await store.setRead(feedId: "f1", sortKey: "a", true)
        try await store.setSyncProgress(feedId: "f1", sinceCursor: "c1", stateCursor: "", lastSyncedAt: "")
        let before = try await store.rowCountsForTests()
        XCTAssertEqual(before, ["pending": 1, "feed_sync": 1, "items": 1, "subscriptions": 1, "folders": 1])
        await store.failNextWriteForTests(to: "folders")

        do {
            try await store.clear()
            XCTFail("the failed delete should fail the clear")
        } catch {}

        let after = try await store.rowCountsForTests()
        XCTAssertEqual(after, before, "every table is as it was")

        try await store.clear()
        let cleared = try await store.rowCountsForTests()
        XCTAssertEqual(cleared, ["pending": 0, "feed_sync": 0, "items": 0, "subscriptions": 0, "folders": 0])
    }
    #endif

    /// The control for the arm above: the lock really does stop a write, so
    /// the retire there failed on the injected failure and not on nothing.
    func testTheLockRefusesAnOrdinaryWrite() async throws {
        let store = try RssStore(directory: root)
        let lock = try lockTheStoreFile()
        defer { lock.release() }

        do {
            try await store.upsertSubscription(departing)
            XCTFail("the lock let a write through")
        } catch {}
    }

    /// A second connection to the store's own file, holding its write lock.
    private func lockTheStoreFile() throws -> SQLiteWriteLock {
        try SQLiteWriteLock(path: root.appendingPathComponent("rss.sqlite").path)
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

private extension RssStore {
    /// How many rows each table `clear()` empties holds.
    func rowCountsForTests() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in ["pending", "feed_sync", "items", "subscriptions", "folders"] {
            counts[table] = try database.rows("SELECT COUNT(*) FROM \(table)").first?.int(0) ?? 0
        }
        return counts
    }

    #if DEBUG
    /// Arms this store's connection to fail its next write to `table`.
    func failNextWriteForTests(to table: String) {
        database.faults.arm(table: table)
    }
    #endif
}
