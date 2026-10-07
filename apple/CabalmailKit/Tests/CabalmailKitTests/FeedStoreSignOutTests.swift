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
}
