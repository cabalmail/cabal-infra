import XCTest
@testable import CabalmailKit

/// Tests that exercise `URLSessionHTTPTransport` itself (retry + URLError
/// normalization) via a scripted `URLProtocol`. The api-client tests
/// elsewhere keep using the lightweight `RecordingHTTPTransport`; this file
/// is the one place we need a real `URLSession` so the production retry
/// path executes end-to-end.
final class HTTPTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ScriptedURLProtocol.reset()
    }

    override func tearDown() {
        ScriptedURLProtocol.reset()
        super.tearDown()
    }

    private func makeTransport() -> URLSessionHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return URLSessionHTTPTransport(session: URLSession(configuration: config))
    }

    private func sampleRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://api.cabalmail.example/prod/move_messages")!)
    }

    func testRetriesOnceOnNetworkConnectionLost() async throws {
        ScriptedURLProtocol.script(
            failures: [URLError(.networkConnectionLost)],
            responses: [(Data("{}".utf8), 200)]
        )
        let transport = makeTransport()
        let (data, response) = try await transport.perform(sampleRequest())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "{}")
        XCTAssertEqual(ScriptedURLProtocol.callCount, 2)
    }

    func testRetriesOnceOnTimeout() async throws {
        ScriptedURLProtocol.script(
            failures: [URLError(.timedOut)],
            responses: [(Data("{}".utf8), 200)]
        )
        let transport = makeTransport()
        let (_, response) = try await transport.perform(sampleRequest())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ScriptedURLProtocol.callCount, 2)
    }

    func testPersistentNetworkConnectionLostSurfacesAsCabalmailNetworkError() async throws {
        ScriptedURLProtocol.script(failures: [
            URLError(.networkConnectionLost),
            URLError(.networkConnectionLost),
        ])
        let transport = makeTransport()
        do {
            _ = try await transport.perform(sampleRequest())
            XCTFail("Expected throw")
        } catch let error as CabalmailError {
            guard case .network = error else {
                XCTFail("Expected .network, got \(error)")
                return
            }
        }
        XCTAssertEqual(ScriptedURLProtocol.callCount, 2)
    }

    func testNonRetryableURLErrorIsNormalizedWithoutRetry() async throws {
        ScriptedURLProtocol.script(failures: [URLError(.cannotFindHost)])
        let transport = makeTransport()
        do {
            _ = try await transport.perform(sampleRequest())
            XCTFail("Expected throw")
        } catch let error as CabalmailError {
            guard case .network = error else {
                XCTFail("Expected .network, got \(error)")
                return
            }
        }
        // Single attempt — `.cannotFindHost` is not in the retryable set.
        XCTAssertEqual(ScriptedURLProtocol.callCount, 1)
    }

    func testSuccessfulRequestDoesNotRetry() async throws {
        ScriptedURLProtocol.script(responses: [(Data("ok".utf8), 200)])
        let transport = makeTransport()
        let (_, response) = try await transport.perform(sampleRequest())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ScriptedURLProtocol.callCount, 1)
    }

    func testHTTPErrorStatusReturnedDirectlyForCallerToHandle() async throws {
        // `URLSessionHTTPTransport` only normalizes URLError-level failures.
        // Non-2xx HTTP responses pass through so `URLSessionApiClient.send`
        // can run its 401 token-refresh path and surface other statuses as
        // `.server(code:message:)`.
        ScriptedURLProtocol.script(responses: [(Data("nope".utf8), 500)])
        let transport = makeTransport()
        let (_, response) = try await transport.perform(sampleRequest())
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertEqual(ScriptedURLProtocol.callCount, 1)
    }
}

// MARK: - URLProtocol fake

/// `URLProtocol` subclass that drains scripted failures/responses from
/// class storage. Each `startLoading()` consumes the next entry; failures
/// come first (one per attempt) so a `[failure, response]` script verifies
/// retry-then-success cleanly.
final class ScriptedURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var failures: [URLError] = []
    private static var responses: [(Data, Int)] = []
    private static var calls: Int = 0

    static func script(failures: [URLError] = [], responses: [(Data, Int)] = []) {
        lock.lock()
        self.failures = failures
        self.responses = responses
        self.calls = 0
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        failures.removeAll()
        responses.removeAll()
        calls = 0
        lock.unlock()
    }

    static var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    // URLProtocol's class methods are `class func`; `static` would not
    // satisfy the override, so the SwiftLint hint doesn't apply here.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.calls += 1
        // Failures drain first so a `[failure, response]` script verifies
        // retry-then-success. Only fall through to the response queue once
        // the scripted failures are exhausted — otherwise the retry attempt
        // races against an already-popped success entry.
        let failure: URLError? = Self.failures.isEmpty ? nil : Self.failures.removeFirst()
        let response: (Data, Int)?
        if failure == nil, !Self.responses.isEmpty {
            response = Self.responses.removeFirst()
        } else {
            response = nil
        }
        Self.lock.unlock()

        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let (data, status) = response else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
