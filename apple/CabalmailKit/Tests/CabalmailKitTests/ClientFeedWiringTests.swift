import XCTest
@testable import CabalmailKit

/// `make(...)` hands the client the feed client it built, rather than the
/// client recovering one by downcasting the mail API client: a downcast
/// answers nil for any `ApiClient` that isn't also an `RssClient`, which
/// would leave the app with no feed client and no error. These pin the
/// factory's wiring. The old downcast found the same object for the one
/// real API client, so they guard the wiring rather than tell the two
/// versions apart.
final class ClientFeedWiringTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-feed-wiring-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheFactoryWiresTheFeedClientItBuilt() async throws {
        let client = try CabalmailClient.make(
            configuration: TestFixtures.makeConfiguration(),
            secureStore: InMemorySecureStore(),
            httpTransport: NullHTTPTransport(),
            cacheDirectory: root
        )

        let rss = try XCTUnwrap(client.rss, "a client from the app's factory has a feed client")
        XCTAssertTrue((rss as AnyObject) === (client.apiClient as AnyObject),
                      "the feed client is the API client the factory built")
        XCTAssertNotNil(client.rssStore)
        XCTAssertNotNil(client.rssSync)
        await client.shutdown()
    }

    /// The control: the memberwise initializer tests use still builds a
    /// client with no feed reader.
    func testTheMemberwiseInitializerStillHasNoFeedClient() throws {
        let client = try TestFixtures.makeClient(imap: FakeImapClient())

        XCTAssertNil(client.rss)
        XCTAssertNil(client.rssStore)
        XCTAssertNil(client.rssSync)
    }
}
