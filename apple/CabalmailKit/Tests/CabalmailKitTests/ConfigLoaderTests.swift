import XCTest
@testable import CabalmailKit

/// `ConfigLoader` with a `ConfigurationCache`: the last good `config.json`
/// is what an offline cold launch restores against.
final class ConfigLoaderTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cache: ConfigurationCache!

    override func setUp() {
        super.setUp()
        suiteName = "ConfigLoaderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cache = ConfigurationCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private static let configJSON = Data("""
    {
      "control_domain": "mail.example.com",
      "domains": [
        {"domain": "example.com", "arn": "arn:aws:route53:::hostedzone/Z1", "zone_id": "Z1", "name_servers": ["ns1.example.net"]}
      ],
      "invokeUrl": "https://api.example.com/prod",
      "cognitoConfig": {
        "region": "us-east-1",
        "poolData": {"UserPoolId": "us-east-1_pool", "ClientId": "client123"}
      }
    }
    """.utf8)

    private static func transport(status: Int, body: Data) -> ScriptedHTTPTransport {
        ScriptedHTTPTransport { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static let offline = ScriptedHTTPTransport { _ in
        throw CabalmailError.network("The Internet connection appears to be offline.")
    }

    func testSuccessfulFetchIsCached() async throws {
        let loaded = try await ConfigLoader.load(
            controlDomain: "mail.example.com",
            transport: Self.transport(status: 200, body: Self.configJSON),
            cache: cache
        )
        XCTAssertEqual(cache.load(controlDomain: "mail.example.com"), loaded)
        XCTAssertEqual(loaded.cognito.clientId, "client123")
    }

    func testOfflineFallsBackToCachedConfiguration() async throws {
        let online = try await ConfigLoader.load(
            controlDomain: "https://mail.example.com",
            transport: Self.transport(status: 200, body: Self.configJSON),
            cache: cache
        )
        let offline = try await ConfigLoader.load(
            controlDomain: "mail.example.com",
            transport: Self.offline,
            cache: cache
        )
        XCTAssertEqual(offline, online)
    }

    func testCaptivePortalPageFallsBackToCachedConfiguration() async throws {
        let online = try await ConfigLoader.load(
            controlDomain: "mail.example.com",
            transport: Self.transport(status: 200, body: Self.configJSON),
            cache: cache
        )
        let portal = try await ConfigLoader.load(
            controlDomain: "mail.example.com",
            transport: Self.transport(status: 200, body: Data("<html>Sign in to Wi-Fi</html>".utf8)),
            cache: cache
        )
        XCTAssertEqual(portal, online)
    }

    func testOfflineWithNothingCachedRethrows() async {
        do {
            _ = try await ConfigLoader.load(
                controlDomain: "mail.example.com",
                transport: Self.offline,
                cache: cache
            )
            XCTFail("expected a network error")
        } catch CabalmailError.network {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCacheIsPerControlDomain() async throws {
        _ = try await ConfigLoader.load(
            controlDomain: "mail.example.com",
            transport: Self.transport(status: 200, body: Self.configJSON),
            cache: cache
        )
        XCTAssertNil(cache.load(controlDomain: "stage.example.com"))
    }

    func testNoCacheKeepsOldBehaviour() async {
        do {
            _ = try await ConfigLoader.load(controlDomain: "mail.example.com", transport: Self.offline)
            XCTFail("expected a network error")
        } catch CabalmailError.network {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
