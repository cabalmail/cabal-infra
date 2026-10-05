import Foundation
import CabalmailKit

// `HTTPTransport` doubles shared by the Kit and app-layer test bundles. A
// suite whose transport scripts one scenario (a held save, a 401 pair) keeps
// that double private to its own file; what lives here is general-purpose.

/// Answers every request through a closure.
public struct ScriptedHTTPTransport: HTTPTransport {
    public typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}

/// Records every request and replies from a FIFO queue of canned responses.
public actor RecordingHTTPTransport: HTTPTransport {
    private var responses: [(Data, Int)]
    public private(set) var requests: [URLRequest] = []

    public init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CabalmailError.transport("RecordingHTTPTransport ran out of responses")
        }
        let (data, status) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}

/// HTTP transport that refuses every request — nothing in a test built on it
/// may reach the network.
public struct NullHTTPTransport: HTTPTransport {
    public init() {}

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw CabalmailError.transport("NullHTTPTransport: unexpected request")
    }
}

/// Fails every request the way URLSession does with no connection.
public struct UnreachableTransport: HTTPTransport {
    public init() {}

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw CabalmailError.network("The Internet connection appears to be offline.")
    }
}
