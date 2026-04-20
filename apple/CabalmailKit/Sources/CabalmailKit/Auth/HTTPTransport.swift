import Foundation

/// Minimal HTTP interface used by `CognitoAuthService` and `URLSessionApiClient`.
///
/// Abstracted so unit tests can inject a fake without URLProtocol gymnastics.
/// Production implementations wrap `URLSession.data(for:)`.
public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production `HTTPTransport` built on `URLSession`.
public struct URLSessionHTTPTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CabalmailError.transport("Non-HTTP response")
        }
        return (data, http)
    }
}
