import Foundation
import CabalmailKitTestSupport

// The shared test doubles live in the CabalmailKitTestSupport target, which
// the app-layer bundles link too, so there is one copy of each. Naming them
// here makes them visible to every file in this bundle without each file
// importing the support module.

typealias ScriptedHTTPTransport = CabalmailKitTestSupport.ScriptedHTTPTransport
typealias RecordingHTTPTransport = CabalmailKitTestSupport.RecordingHTTPTransport
typealias NullHTTPTransport = CabalmailKitTestSupport.NullHTTPTransport
typealias UnreachableTransport = CabalmailKitTestSupport.UnreachableTransport
typealias StubAuthService = CabalmailKitTestSupport.StubAuthService
typealias NullAuthService = CabalmailKitTestSupport.NullAuthService
typealias FakeImapClient = CabalmailKitTestSupport.FakeImapClient
typealias TestFixtures = CabalmailKitTestSupport.TestFixtures
typealias TestClock = CabalmailKitTestSupport.TestClock

let defaultWaitTimeout = CabalmailKitTestSupport.defaultWaitTimeout

/// Forwards to the shared `waitUntil`, keeping the caller's file and line so
/// a timeout fails at the test that waited.
func waitUntil(
    timeout: TimeInterval = defaultWaitTimeout,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () async throws -> Bool
) async throws {
    try await CabalmailKitTestSupport.waitUntil(timeout: timeout, file: file, line: line, condition)
}

/// Forwards to the shared `bufferedCount`.
func bufferedCount<Element: Sendable>(_ stream: AsyncStream<Element>) async -> Int {
    await CabalmailKitTestSupport.bufferedCount(stream)
}

/// Whether `stream` ends on its own, without this side cancelling it: true
/// once its producer finishes it, false if it is still open after `timeout`.
/// For lifetime tests, where "the owner went away" should finish the stream.
func finishesWithoutCancelling<Element: Sendable>(
    _ stream: AsyncStream<Element>,
    timeout: TimeInterval = defaultWaitTimeout
) async -> Bool {
    let drain = Task { () -> Bool in
        for await _ in stream {}
        return !Task.isCancelled
    }
    let deadline = Task {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        drain.cancel()
    }
    let finished = await drain.value
    deadline.cancel()
    return finished
}
