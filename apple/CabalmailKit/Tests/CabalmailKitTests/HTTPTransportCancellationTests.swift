import Synchronization
import XCTest
@testable import CabalmailKit

/// How `URLSessionHTTPTransport` reports a cancelled request (#1815), through
/// a real `URLSession`.
///
/// A cancel that comes from the caller's own Task (a view going away, a
/// superseded load) is the caller's, and throws `CabalmailError.cancelled`,
/// so the caller's cancellation guards recognise it. Before, every
/// `URLError` became `.network`, and a cancelled reader load painted
/// "Couldn't reach the server. cancelled." A cancel URLSession makes up on
/// its own, while the Task is live, still gets its one retry and then reads
/// as `.network`.
final class HTTPTransportCancellationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        HoldingURLProtocol.reset()
        ScriptedURLProtocol.reset()
    }

    override func tearDown() {
        HoldingURLProtocol.reset()
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    func testCancellingTheCallersTaskMidRequestThrowsCancelledWithoutARetry() async throws {
        let transport = Self.transport(over: HoldingURLProtocol.self)
        let request = Self.request()
        let call = Task { () -> Error? in
            do {
                _ = try await transport.perform(request)
                return nil
            } catch {
                return error
            }
        }
        try await waitUntil { HoldingURLProtocol.started == 1 }

        call.cancel()
        let error = await call.value

        XCTAssertEqual(error as? CabalmailError, .cancelled)
        XCTAssertEqual(HoldingURLProtocol.started, 1, "a cooperative cancel is not retried")
    }

    /// The control: the same `URLError.cancelled` on a live Task is
    /// URLSession's own, retried once, and `.network` when the retry fails
    /// the same way.
    func testASpuriousCancelIsRetriedOnceAndThenReadsAsNetwork() async throws {
        ScriptedURLProtocol.script(failures: [URLError(.cancelled), URLError(.cancelled)])
        let transport = Self.transport(over: ScriptedURLProtocol.self)

        do {
            _ = try await transport.perform(Self.request())
            XCTFail("expected the request to fail")
        } catch let error as CabalmailError {
            guard case .network = error else { return XCTFail("expected .network, got \(error)") }
        }
        XCTAssertEqual(ScriptedURLProtocol.callCount, 2)
    }

    /// A launch whose task is cancelled while config.json is in flight (its
    /// window closed during the splash) still gets the cached copy, as it did
    /// when the cancel read as `.network` (#1779). Without the fallback the
    /// restore would land on the sign-in form, and a borrower waiting on the
    /// same build would fail with it.
    func testACancelledConfigFetchStillGetsTheCachedCopy() async throws {
        let (cache, cleanUp) = try Self.configurationCache()
        defer { cleanUp() }
        let cached = TestFixtures.makeConfiguration()
        cache.save(cached, controlDomain: "cabalmail.example")
        let transport = Self.transport(over: HoldingURLProtocol.self)
        let launch = Task {
            try await ConfigLoader.load(controlDomain: "cabalmail.example", transport: transport, cache: cache)
        }
        try await waitUntil { HoldingURLProtocol.started == 1 }

        launch.cancel()
        let loaded = try await launch.value

        XCTAssertEqual(loaded, cached)
    }

    /// The control: with nothing cached, the same cancel is rethrown.
    func testACancelledConfigFetchWithNothingCachedThrowsCancelled() async throws {
        let (cache, cleanUp) = try Self.configurationCache()
        defer { cleanUp() }
        let transport = Self.transport(over: HoldingURLProtocol.self)
        let launch = Task { () -> Error? in
            do {
                _ = try await ConfigLoader.load(controlDomain: "cabalmail.example", transport: transport, cache: cache)
                return nil
            } catch {
                return error
            }
        }
        try await waitUntil { HoldingURLProtocol.started == 1 }

        launch.cancel()
        let error = await launch.value

        XCTAssertEqual(error as? CabalmailError, .cancelled)
    }

    private static func configurationCache() throws -> (ConfigurationCache, () -> Void) {
        let suite = "HTTPTransportCancellationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ConfigurationCache(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private static func transport(over protocolClass: URLProtocol.Type) -> URLSessionHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return URLSessionHTTPTransport(session: URLSession(configuration: config))
    }

    private static func request() -> URLRequest {
        URLRequest(url: URL(string: "https://api.cabalmail.example/prod/fetch_message")!)
    }
}

/// A `URLProtocol` that never answers: it counts the loads it starts and
/// waits for URLSession to stop it, which is what a cancelled data task does.
final class HoldingURLProtocol: URLProtocol {
    private static let starts = Mutex(0)

    static var started: Int { starts.withLock { $0 } }

    static func reset() {
        starts.withLock { $0 = 0 }
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.starts.withLock { $0 += 1 }
    }

    override func stopLoading() {}
}
