import XCTest
@testable import CabalmailKit

/// The From choices compose offers must survive a launch without a
/// connection: `AddressCache` keeps the list the server last returned on
/// disk, and `addressesForSending` answers with it when the fetch fails the
/// way an offline send would. Each test builds a fresh client over the same
/// directory to stand in for a relaunch.
final class OfflineAddressListTests: XCTestCase {
    private static let configuration = Configuration(
        controlDomain: "cabalmail.example",
        domains: [MailDomain(domain: "cabalmail.example")],
        invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
        cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
    )

    private static let first = "first@a.cabalmail.example"
    private static let second = "second@b.cabalmail.example"

    /// Stands in for the network. `/list` answers with `addresses` while
    /// online, fails like URLSession does with no connection otherwise, and
    /// answers `refusal` with a server error when set. Every other endpoint
    /// (revoke, favorite) succeeds. `holdNextList` parks the next `/list`
    /// after it has read `addresses`, until `releaseList()`.
    private actor Network {
        var online = true
        var refusal: Int?
        var addresses: [String] = [OfflineAddressListTests.first, OfflineAddressListTests.second]
        var holdNextList = false
        private var held: CheckedContinuation<Void, Never>?

        var isHoldingList: Bool { held != nil }

        func set(online: Bool) { self.online = online }
        func set(refusal: Int?) { self.refusal = refusal }
        func set(addresses: [String]) { self.addresses = addresses }
        func set(holdNextList: Bool) { self.holdNextList = holdNextList }

        func releaseList() {
            held?.resume()
            held = nil
        }

        func respond(to request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard online else {
                throw CabalmailError.network("The Internet connection appears to be offline.")
            }
            guard request.url?.path.hasSuffix("/list") == true else {
                return (Data("{}".utf8), Self.response(request, status: 200))
            }
            if let refusal {
                return (Data(#"{"status":"boom"}"#.utf8), Self.response(request, status: refusal))
            }
            let items = addresses.map { address -> String in
                let subdomain = address.split(separator: "@")[1].split(separator: ".")[0]
                return #"{"address":"\#(address)","subdomain":"\#(subdomain)","tld":"cabalmail.example"}"#
            }
            let body = Data(#"{"Items":[\#(items.joined(separator: ","))]}"#.utf8)
            if holdNextList {
                holdNextList = false
                await withCheckedContinuation { held = $0 }
            }
            return (body, Self.response(request, status: 200))
        }

        private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-address-list-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// One launch: a new client and a new cache over the shared directory,
    /// as `CabalmailClient.make` wires them. `persistent: false` builds the
    /// memory-only cache every launch had before.
    private func launch(_ network: Network, persistent: Bool = true) throws -> CabalmailClient {
        let auth = StubAuthService()
        let api = URLSessionApiClient(
            configuration: Self.configuration,
            authService: auth,
            transport: ScriptedHTTPTransport { request in try await network.respond(to: request) }
        )
        return CabalmailClient(
            configuration: Self.configuration,
            authService: auth,
            apiClient: api,
            imapClient: ApiBackedImapClient(api: api, host: Self.configuration.imapHost),
            addressCache: persistent
                ? AddressCache(directory: root.appendingPathComponent("addresses"))
                : AddressCache(),
            envelopeCache: try EnvelopeCache(directory: root.appendingPathComponent("envelopes")),
            bodyCache: try MessageBodyCache(directory: root.appendingPathComponent("bodies")),
            draftStore: try DraftStore(directory: root.appendingPathComponent("drafts")),
            outbox: try Outbox(directory: root.appendingPathComponent("outbox"))
        )
    }

    /// What an offline relaunch offers compose.
    private func offlineRelaunch(_ network: Network) async throws -> (addresses: [String], isSavedCopy: Bool) {
        await network.set(online: false)
        let result = try await launch(network).addressesForSending()
        return (result.addresses.map(\.address), result.isSavedCopy)
    }

    private func assertOffline(
        _ call: () async throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await call()
            XCTFail("expected the offline fetch to throw", file: file, line: line)
        } catch let error as CabalmailError {
            guard case .network = error else {
                return XCTFail("expected .network, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - The offline launch

    func testOfflineLaunchOffersTheListAnEarlierLaunchFetched() async throws {
        let network = Network()
        _ = try await launch(network).addresses()

        let result = try await offlineRelaunch(network)

        XCTAssertEqual(result.addresses, [Self.first, Self.second])
        XCTAssertTrue(result.isSavedCopy)
    }

    /// Negative control: the memory-only cache every launch had before kept
    /// nothing across the relaunch, so the offline compose got no list.
    func testMemoryOnlyCacheLeavesAnOfflineLaunchNothing() async throws {
        let network = Network()
        _ = try await launch(network, persistent: false).addresses()

        await network.set(online: false)
        let client = try launch(network, persistent: false)
        await assertOffline { try await client.addressesForSending() }
    }

    func testOfflineLaunchWithNothingSavedStillThrows() async throws {
        let network = Network()
        await network.set(online: false)
        let client = try launch(network)
        await assertOffline { try await client.addressesForSending() }
    }

    func testOnlineAnswerIsNotMarkedSaved() async throws {
        let network = Network()
        let result = try await launch(network).addressesForSending()
        XCTAssertFalse(result.isSavedCopy)
        XCTAssertEqual(result.addresses.count, 2)
    }

    /// The tests above wire the cache by hand; this one goes through the
    /// factory the app uses, so dropping the directory there fails a test.
    func testClientFromMakeKeepsTheListForTheNextLaunch() async throws {
        let network = Network()
        let transport = ScriptedHTTPTransport { request in try await network.respond(to: request) }
        // One store across both launches, as the keychain is.
        let keychain = InMemorySecureStore()
        func makeLaunch() throws -> CabalmailClient {
            try CabalmailClient.make(
                configuration: Self.configuration,
                secureStore: keychain,
                httpTransport: transport,
                cacheDirectory: root.appendingPathComponent("made")
            )
        }
        let first = try makeLaunch()
        let auth = try XCTUnwrap(first.authService as? CognitoAuthService)
        try await auth.adopt(
            tokens: AuthTokens(
                idToken: "ID", accessToken: "ACCESS", refreshToken: "REFRESH",
                tokenType: "Bearer", expiresAt: Date().addingTimeInterval(3600)
            ),
            username: "alice"
        )
        _ = try await first.addresses()

        await network.set(online: false)
        let result = try await makeLaunch().addressesForSending()
        XCTAssertTrue(result.isSavedCopy)
        XCTAssertEqual(result.addresses.count, 2)
    }

    // MARK: - What the saved copy must not do

    /// Only an unreachable server falls back. A server that answers and
    /// refuses has something to say, and a stale list would hide it.
    func testServerRefusalDoesNotFallBack() async throws {
        let network = Network()
        _ = try await launch(network).addresses()

        await network.set(refusal: 500)
        do {
            _ = try await launch(network).addressesForSending()
            XCTFail("expected the refusal to throw")
        } catch let error as CabalmailError {
            guard case .server = error else { return XCTFail("expected .server, got \(error)") }
        }
    }

    /// The plain `addresses()` keeps throwing offline. Its callers (Settings,
    /// the Addresses list) reconcile the default From against the answer, and
    /// a saved copy that predates an address created elsewhere would clear a
    /// default that is still good.
    func testPlainAddressesDoesNotServeTheSavedCopy() async throws {
        let network = Network()
        _ = try await launch(network).addresses()

        await network.set(online: false)
        let client = try launch(network)
        await assertOffline { try await client.addresses() }
    }

    /// The fallback doesn't stand in for the session's fetch: once the
    /// server answers again, the next call asks it rather than replaying the
    /// saved copy.
    func testFallbackDoesNotPinTheSessionToTheSavedCopy() async throws {
        let network = Network()
        _ = try await launch(network).addresses()

        await network.set(online: false)
        let client = try launch(network)
        _ = try await client.addressesForSending()

        await network.set(online: true)
        await network.set(addresses: ["third@c.cabalmail.example"])
        let result = try await client.addressesForSending()
        XCTAssertFalse(result.isSavedCopy)
        XCTAssertEqual(result.addresses.map(\.address), ["third@c.cabalmail.example"])
    }

    func testLaterFetchReplacesTheSavedCopy() async throws {
        let network = Network()
        _ = try await launch(network).addresses()
        await network.set(addresses: ["third@c.cabalmail.example"])
        _ = try await launch(network).addresses(forceRefresh: true)

        let result = try await offlineRelaunch(network)
        XCTAssertEqual(result.addresses, ["third@c.cabalmail.example"])
    }

    // MARK: - Address changes

    /// Starring, suspending, or creating an address leaves every saved
    /// address sendable, and the app doesn't refetch after most of them, so
    /// the saved copy has to outlive the invalidation.
    func testFavoriteKeepsTheSavedCopy() async throws {
        let network = Network()
        let online = try launch(network)
        _ = try await online.addresses()
        try await online.setFavorite(address: Self.first, favorite: true)

        let result = try await offlineRelaunch(network)
        XCTAssertEqual(result.addresses, [Self.first, Self.second])
    }

    /// A revoked address must not come back as an offline From choice.
    func testRevokeTakesThatAddressOutOfTheSavedCopy() async throws {
        let network = Network()
        let online = try launch(network)
        _ = try await online.addresses()
        try await online.revokeAddress(
            address: Self.second, subdomain: "b", tld: "cabalmail.example", publicKey: nil
        )

        let result = try await offlineRelaunch(network)
        XCTAssertEqual(result.addresses, [Self.first])
    }

    /// A fetch the server answered before a revoke, but that lands after it,
    /// must not store its answer: that would put the revoked address back,
    /// on disk for the next offline launch as well as in memory.
    func testFetchInFlightAcrossARevokeDoesNotRestoreIt() async throws {
        let network = Network()
        let online = try launch(network)
        _ = try await online.addresses()

        await network.set(holdNextList: true)
        let inFlight = Task { try await online.addresses(forceRefresh: true) }
        try await waitUntil { await network.isHoldingList }
        try await online.revokeAddress(
            address: Self.second, subdomain: "b", tld: "cabalmail.example", publicKey: nil
        )
        await network.set(addresses: [Self.first])
        await network.releaseList()
        let stale = try await inFlight.value
        XCTAssertEqual(stale.map(\.address), [Self.first, Self.second], "the held answer predates the revoke")

        let cached = await online.addressCache.get()
        XCTAssertNil(cached, "the pre-revoke answer must not become the session's list")
        let result = try await offlineRelaunch(network)
        XCTAssertEqual(result.addresses, [Self.first])
    }

    /// Sign-out wipes the shared cache directory's contents, the saved list
    /// included, so the next account on the device can't send as this one.
    func testSignOutForgetsTheSavedCopy() async throws {
        let network = Network()
        let online = try launch(network)
        _ = try await online.addresses()
        await online.clearLocalData()

        await network.set(online: false)
        let client = try launch(network)
        await assertOffline { try await client.addressesForSending() }
    }

    func testUnreadableSavedCopyIsTreatedAsNone() async throws {
        let directory = root.appendingPathComponent("addresses")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("addresses.json"))

        let network = Network()
        await network.set(online: false)
        let client = try launch(network)
        await assertOffline { try await client.addressesForSending() }
    }
}
