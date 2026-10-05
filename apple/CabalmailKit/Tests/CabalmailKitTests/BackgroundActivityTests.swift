#if canImport(UIKit) && !os(watchOS)
import Synchronization
import UIKit
import XCTest
@testable import CabalmailKit

/// #1843. Every request through `URLSessionHTTPTransport` holds a UIKit
/// background task so it can finish if the app is backgrounded mid-request.
/// Ending one used to hop to the main actor holding the token weakly; the
/// request's assertion, the token's only owner, was gone before the hop ran,
/// so the task was never ended, and iOS terminates an app that leaves one open
/// when its background time runs out.
///
/// UIKit-only, so these run on the iOS and visionOS legs, not under `swift test`
/// on macOS.
@MainActor
final class BackgroundActivityTests: XCTestCase {
    /// The shape of the bug, deterministically: on the main actor, nothing the
    /// hop scheduled can run until this test suspends, by which time the
    /// assertion and its token are gone.
    func testEndingAnAssertionEndsItsTaskAfterTheAssertionIsDropped() async throws {
        let recorder = BackgroundTaskRecorder()
        do {
            let assertion = await BackgroundActivityAssertion.begin(using: recorder.calls)
            assertion.end()
        }
        XCTAssertEqual(recorder.begun, [1])
        try await settle { recorder.ended == [1] }
        XCTAssertEqual(recorder.ended, [1], "the task the assertion began was never ended")
    }

    func testARequestEndsTheTaskItBegan() async throws {
        ScriptedURLProtocol.script(responses: [(Data("{}".utf8), 200)])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        let recorder = BackgroundTaskRecorder()
        let transport = URLSessionHTTPTransport(
            session: URLSession(configuration: config),
            backgroundTasks: recorder.calls
        )

        let (_, response) = try await transport.perform(
            URLRequest(url: URL(string: "https://api.cabalmail.example/prod/list_folders")!)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(recorder.begun, [1])
        try await settle { recorder.ended == [1] }
        XCTAssertEqual(recorder.ended, [1], "the request's background task was never ended")
    }

    /// The system's expiration ends the task while the request still holds
    /// it, and the request's own end afterwards does not end it twice.
    func testAnExpiredTaskIsEndedOnce() async throws {
        let recorder = BackgroundTaskRecorder()
        let assertion = await BackgroundActivityAssertion.begin(using: recorder.calls)
        recorder.expire(task: 1)
        XCTAssertEqual(recorder.ended, [1])

        assertion.end()
        // Long enough for the hop to main that `end()` schedules to run.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.ended, [1], "a task already ended by its expiration was ended again")
    }

    /// Suspends, letting the main actor run what was scheduled on it, until
    /// `condition` holds or about two seconds pass. `waitUntil` can't be used
    /// from this main-actor class: its condition closure isn't `Sendable`.
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Stands in for `UIApplication`: hands out ids from 1, keeps each task's
/// expiration handler, and records which ids are ended.
private final class BackgroundTaskRecorder: Sendable {
    private struct State {
        var next = 1
        var begun: [Int] = []
        var ended: [Int] = []
        var expirations: [Int: @MainActor @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    var begun: [Int] { state.withLock { $0.begun } }
    var ended: [Int] { state.withLock { $0.ended } }

    var calls: BackgroundTaskCalls {
        BackgroundTaskCalls(
            begin: { expiration in
                self.state.withLock { state in
                    let id = state.next
                    state.next += 1
                    state.begun.append(id)
                    state.expirations[id] = expiration
                    return UIBackgroundTaskIdentifier(rawValue: id)
                }
            },
            end: { id in
                self.state.withLock { $0.ended.append(id.rawValue) }
            }
        )
    }

    /// Calls the expiration handler UIKit would call when `task` runs out of
    /// background time.
    @MainActor
    func expire(task: Int) {
        let handler = state.withLock { $0.expirations[task] }
        handler?()
    }
}
#endif
