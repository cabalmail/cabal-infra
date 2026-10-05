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
///    `URLError.networkConnectionLost`, `URLError.timedOut`, or a spurious
///    `URLError.cancelled` (one that arrives while our own Task is NOT
///    cancelled — URLSession drops data tasks on its own; see fe73f2f0),
///    retries once after a short backoff (Apple's own guidance for `-1005`).
///    Any `URLError` that escapes is normalized into
///    `CabalmailError.network(localizedDescription)` so callers and toast
///    UIs see a readable message instead of the verbose NSError dump.
public struct URLSessionHTTPTransport: HTTPTransport {
    public let session: URLSession
    #if canImport(UIKit) && !os(watchOS)
    let backgroundTasks: BackgroundTaskCalls
    #endif

    public init(session: URLSession = .shared) {
        self.session = session
        #if canImport(UIKit) && !os(watchOS)
        self.backgroundTasks = .live
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Test seam: records the background tasks `perform` begins and ends.
    init(session: URLSession, backgroundTasks: BackgroundTaskCalls) {
        self.session = session
        self.backgroundTasks = backgroundTasks
    }
    #endif

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let assertion = await beginBackgroundActivity()
        defer { assertion.end() }
        return try await performWithRetry(request)
    }

    private func beginBackgroundActivity() async -> BackgroundActivityAssertion {
        #if canImport(UIKit) && !os(watchOS)
        await BackgroundActivityAssertion.begin(using: backgroundTasks)
        #else
        await BackgroundActivityAssertion.begin()
        #endif
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
        case .cancelled:
            // URLSession occasionally fails a data task with `.cancelled`
            // that nobody asked for (the class fe73f2f0 recovered from on
            // the body fetch — that recovery went dead when this transport
            // started normalizing URLError before callers could see the
            // code). Only a cancellation that didn't come from our own Task
            // is transient; a cooperative cancel propagates immediately.
            return !Task.isCancelled
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

    #if canImport(UIKit) && !os(watchOS)
    /// Begins a new background-task assertion. The hop to the main actor
    /// is awaited so the assertion is active before the URLSession data
    /// task is enqueued; without that ordering the task could race a
    /// suspension that fires before UIKit registers the assertion.
    static func begin(using calls: BackgroundTaskCalls = .live) async -> BackgroundActivityAssertion {
        let token = await BackgroundActivityToken.begin(using: calls)
        return BackgroundActivityAssertion(token: token)
    }
    #else
    static func begin() async -> BackgroundActivityAssertion {
        BackgroundActivityAssertion()
    }
    #endif

    func end() {
        #if canImport(UIKit) && !os(watchOS)
        token.end()
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
/// The two UIKit calls behind a background-task assertion, injectable so a
/// test can see whether every task begun is ended.
struct BackgroundTaskCalls: Sendable {
    let begin: @MainActor @Sendable (
        _ expiration: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    let end: @MainActor @Sendable (UIBackgroundTaskIdentifier) -> Void

    static let live = BackgroundTaskCalls(
        begin: { expiration in
            UIApplication.shared.beginBackgroundTask(withName: "Cabalmail HTTP", expirationHandler: expiration)
        },
        end: { UIApplication.shared.endBackgroundTask($0) }
    )
}

/// Holds the `UIBackgroundTaskIdentifier` from `beginBackgroundTask` so
/// `BackgroundActivityAssertion` can stay a value type. Reference identity
/// lets the UIKit expiration handler reach the same token the caller's
/// `end()` will use, so a system-fired expiration and a caller-driven end
/// converge on the same id without double-ending. Main-actor isolated, like the
/// UIKit calls it wraps, so `taskID` is only ever touched on main.
@MainActor
final class BackgroundActivityToken {
    private let calls: BackgroundTaskCalls
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    private init(calls: BackgroundTaskCalls) {
        self.calls = calls
    }

    static func begin(using calls: BackgroundTaskCalls) -> BackgroundActivityToken {
        let token = BackgroundActivityToken(calls: calls)
        // Weak is enough here: the task is open only while something still
        // holds the token, the caller's assertion or the hop in `end()`.
        token.taskID = calls.begin { [weak token] in
            token?.endOnMain()
        }
        return token
    }

    /// Ends the task from any isolation. The hop to main holds the token
    /// strongly: the caller's assertion is usually its last owner and is gone
    /// as soon as this returns, before the hop runs, so a weak capture found
    /// nothing to end and every request left its background task open until
    /// iOS expired it, which terminates the app (#1843).
    nonisolated func end() {
        Task { @MainActor in self.endOnMain() }
    }

    private func endOnMain() {
        guard taskID != .invalid else { return }
        let captured = taskID
        taskID = .invalid
        calls.end(captured)
    }
}
#endif
