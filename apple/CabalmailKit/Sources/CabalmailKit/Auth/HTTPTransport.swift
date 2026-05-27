import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Minimal HTTP interface used by `CognitoAuthService` and `URLSessionApiClient`.
///
/// Abstracted so unit tests can inject a fake without URLProtocol gymnastics.
/// Production implementations wrap `URLSession.data(for:)`.
public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production `HTTPTransport` built on `URLSession`.
///
/// `perform(_:)` adds two pieces of resilience over a bare
/// `URLSession.data(for:)`:
///
/// 1. **Background-task assertion (iOS/visionOS).** Holds a
///    `UIApplication.beginBackgroundTask` assertion across the whole call.
///    iOS otherwise tears down active URLSession connections the instant
///    the app is backgrounded; without the assertion, an in-flight POST
///    raced against the user backgrounding the app (e.g. tapping Archive
///    then swiping the app away) surfaces a `URLError.networkConnectionLost`
///    (`-1005`) before the request can finish. The assertion buys roughly
///    30 seconds after backgrounding for the request to complete.
/// 2. **Transient-error retry + normalization.** On
///    `URLError.networkConnectionLost` or `URLError.timedOut`, retries
///    once after a short backoff (Apple's own guidance for `-1005`). Any
///    `URLError` that escapes is normalized into
///    `CabalmailError.network(localizedDescription)` so callers and toast
///    UIs see a readable message instead of the verbose NSError dump.
public struct URLSessionHTTPTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let assertion = await BackgroundActivityAssertion.begin()
        defer { assertion.end() }
        return try await performWithRetry(request)
    }

    private func performWithRetry(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await performOnce(request)
        } catch let err as URLError where Self.isRetryableTransportError(err) {
            CabalmailLog.warn(
                "HTTPTransport",
                "retrying after URLError \(err.code.rawValue): \(err.localizedDescription)"
            )
            try? await Task.sleep(nanoseconds: 250_000_000)
            do {
                return try await performOnce(request)
            } catch let retryErr as URLError {
                throw CabalmailError.network(retryErr.localizedDescription)
            }
        } catch let err as URLError {
            throw CabalmailError.network(err.localizedDescription)
        }
    }

    private func performOnce(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CabalmailError.transport("Non-HTTP response")
        }
        return (data, http)
    }

    static func isRetryableTransportError(_ err: URLError) -> Bool {
        switch err.code {
        case .networkConnectionLost, .timedOut:
            return true
        default:
            return false
        }
    }
}

// MARK: - Background-task assertion

/// Tiny shim around `UIApplication.beginBackgroundTask` so the transport
/// stays platform-neutral. On macOS (no UIKit) every operation is a no-op
/// and the struct compiles down to nothing.
struct BackgroundActivityAssertion: Sendable {
    #if canImport(UIKit) && !os(watchOS)
    private let token: BackgroundActivityToken
    #endif

    /// Begins a new background-task assertion. The hop to the main actor
    /// is awaited so the assertion is active before the URLSession data
    /// task is enqueued; without that ordering the task could race a
    /// suspension that fires before UIKit registers the assertion.
    static func begin() async -> BackgroundActivityAssertion {
        #if canImport(UIKit) && !os(watchOS)
        let token = await BackgroundActivityToken.begin()
        return BackgroundActivityAssertion(token: token)
        #else
        return BackgroundActivityAssertion()
        #endif
    }

    func end() {
        #if canImport(UIKit) && !os(watchOS)
        token.end()
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Holds the `UIBackgroundTaskIdentifier` from `beginBackgroundTask` so
/// `BackgroundActivityAssertion` can stay a value type. Reference identity
/// lets the UIKit expiration handler reach the same token the caller's
/// `end()` will use, so a system-fired expiration and a caller-driven end
/// converge on the same id without double-ending.
final class BackgroundActivityToken: @unchecked Sendable {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    static func begin() -> BackgroundActivityToken {
        let token = BackgroundActivityToken()
        token.taskID = UIApplication.shared.beginBackgroundTask(withName: "Cabalmail HTTP") { [weak token] in
            token?.endOnMain()
        }
        return token
    }

    func end() {
        Task { @MainActor [weak self] in self?.endOnMain() }
    }

    @MainActor
    private func endOnMain() {
        guard taskID != .invalid else { return }
        let captured = taskID
        taskID = .invalid
        UIApplication.shared.endBackgroundTask(captured)
    }
}
#endif
