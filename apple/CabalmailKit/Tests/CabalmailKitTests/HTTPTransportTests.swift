import Synchronization
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

    func testRetriesOnceOnSpuriousCancel() async throws {
        // A `.cancelled` failure while our own Task is NOT cancelled is
        // URLSession dropping the data task on its own — transient, retried.
        ScriptedURLProtocol.script(
            failures: [URLError(.cancelled)],
            responses: [(Data("{}".utf8), 200)]
        )
        let transport = makeTransport()
        let (_, response) = try await transport.perform(sampleRequest())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ScriptedURLProtocol.callCount, 2)
    }

    func testCancelledIsNotRetryableInsideCancelledTask() async {
        // A cooperative cancel (our own Task was cancelled) must propagate,
        // not spin a retry.
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return URLSessionHTTPTransport.isRetryableTransportError(URLError(.cancelled))
        }
        task.cancel()
        let retryable = await task.value
        XCTAssertFalse(retryable)
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

    func testAWriteWhoseSecondCopyIsNotSafeIsSentOnce() async throws {
        // The first copy may have landed; a second /new_folder would answer
        // "already exists" for a folder this request created.
        ScriptedURLProtocol.script(
            failures: [URLError(.networkConnectionLost)],
            responses: [(Data("{}".utf8), 200)]
        )
        var request = URLRequest(url: URL(string: "https://api.cabalmail.example/prod/new_folder")!)
        request.httpMethod = "PUT"
        do {
            _ = try await makeTransport().perform(request)
            XCTFail("Expected throw")
        } catch let error as CabalmailError {
            guard case .network = error else { return XCTFail("Expected .network, got \(error)") }
        }
        XCTAssertEqual(ScriptedURLProtocol.callCount, 1)
    }

    func testCancellingDuringTheBackoffSendsNoSecondCopy() async throws {
        ScriptedURLProtocol.script(
            failures: [URLError(.networkConnectionLost)],
            responses: [(Data("{}".utf8), 200)]
        )
        // A path no other test uses, to find this request's log line.
        let path = "probe-\(UUID().uuidString)"
        let request = URLRequest(url: URL(string: "https://api.cabalmail.example/prod/\(path)")!)
        var configured = makeTransport()
        // Far longer than any runner stall, so the cancel always lands
        // inside the backoff; a cancelled sleep returns at once.
        configured.retryBackoffNanoseconds = 60_000_000_000
        let transport = configured
        let call = Task { () -> Error? in
            do {
                _ = try await transport.perform(request)
                return nil
            } catch {
                return error
            }
        }
        // The line is logged just before the backoff starts.
        try await waitUntil {
            DebugLogStore.shared.snapshot().contains {
                $0.category == "HTTPTransport" && $0.message.hasPrefix("retrying GET \(path)")
            }
        }

        call.cancel()
        let error = await call.value

        XCTAssertEqual(error as? CabalmailError, .cancelled)
        XCTAssertEqual(ScriptedURLProtocol.callCount, 1, "the request was sent again after its caller gave up")
    }

    func testHTTPErrorStatusReturnedDirectlyForCallerToHandle() async throws {
        // `URLSessionHTTPTransport` only normalizes URLError-level failures.
        // Non-2xx HTTP responses pass through so `URLSessionApiClient.send`
        // can run its 401 token-refresh path and surface other statuses as
        // `.http(status:body:)`.
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
    private struct Script {
        var failures: [URLError] = []
        var responses: [(Data, Int)] = []
        var calls = 0
    }

    private static let state = Mutex(Script())

    static func script(failures: [URLError] = [], responses: [(Data, Int)] = []) {
        state.withLock { $0 = Script(failures: failures, responses: responses) }
    }

    static func reset() {
        state.withLock { $0 = Script() }
    }

    static var callCount: Int {
        state.withLock { $0.calls }
    }

    // URLProtocol's class methods are `class func`; `static` would not
    // satisfy the override, so the SwiftLint hint doesn't apply here.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Failures drain first so a `[failure, response]` script verifies
        // retry-then-success. Only fall through to the response queue once
        // the scripted failures are exhausted — otherwise the retry attempt
        // races against an already-popped success entry.
        let (failure, response) = Self.state.withLock { script -> (URLError?, (Data, Int)?) in
            script.calls += 1
            if !script.failures.isEmpty { return (script.failures.removeFirst(), nil) }
            if !script.responses.isEmpty { return (nil, script.responses.removeFirst()) }
            return (nil, nil)
        }

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
