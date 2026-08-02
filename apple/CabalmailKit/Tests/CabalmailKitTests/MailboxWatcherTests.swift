import XCTest
@testable import CabalmailKit

/// Exercises `MailboxWatcher`'s IDLE reconnect loop against a scripted
/// stream factory. The production factory is `LiveImapClient.idle(folder:)`,
/// which opens a real socket — we substitute a closure that returns
/// pre-built `AsyncThrowingStream`s to drive the watcher's states without
/// touching the network.
///
/// Every stream consumption here goes through `withDeadline`: an unbounded
/// `for await` on the watcher stream waits forever if the expected event
/// interleaving never arrives, and a hung test emits nothing — no failure,
/// no output. On the visionOS 27.0 simulator (xcode-27 CI image,
/// 2026-08-01) exactly that wedged xcodebuild for 57 silent minutes until
/// the job timeout killed it. The deadline turns a stall into a named,
/// diagnosable test failure on every platform.
final class MailboxWatcherTests: XCTestCase {
    func testEmitsChangedForExistsExpungeFetch() async {
        let watcher = MailboxWatcher(
            folder: "INBOX",
            streamFactory: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(IdleEvent(kind: .exists(12)))
                    continuation.yield(IdleEvent(kind: .expunge(3)))
                    continuation.yield(IdleEvent(kind: .fetch(5)))
                    continuation.finish()
                }
            },
            initialBackoffSeconds: 0.05,
            maxBackoffSeconds: 0.05,
            clock: { _ in }
        )
        let stream = await watcher.start()
        let outcome = await withDeadline {
            var changes = 0
            var sawActive = false
            for await event in stream {
                switch event {
                case .active:
                    sawActive = true
                case .changed:
                    changes += 1
                    if changes == 3 {
                        await watcher.stop()
                    }
                case .reconnecting:
                    break
                }
                if changes >= 3 { break }
            }
            return (sawActive: sawActive, changes: changes)
        }
        guard let (sawActive, changes) = outcome else {
            return XCTFail("watcher stream stalled: no 3rd .changed within the deadline")
        }
        XCTAssertTrue(sawActive)
        XCTAssertEqual(changes, 3)
    }

    func testReconnectsAfterTransportError() async {
        let attempts = AttemptCounter()
        let watcher = MailboxWatcher(
            folder: "INBOX",
            streamFactory: { _ in
                let attempt = await attempts.next()
                if attempt == 1 {
                    return AsyncThrowingStream { continuation in
                        continuation.finish(throwing: CabalmailError.network("boom"))
                    }
                }
                return AsyncThrowingStream { continuation in
                    continuation.yield(IdleEvent(kind: .exists(1)))
                    continuation.finish()
                }
            },
            initialBackoffSeconds: 0.01,
            maxBackoffSeconds: 0.01,
            clock: { _ in }
        )
        let stream = await watcher.start()
        let outcome = await withDeadline {
            var sawReconnecting = false
            var sawChanged = false
            for await event in stream {
                switch event {
                case .reconnecting: sawReconnecting = true
                case .changed:      sawChanged = true
                case .active:       break
                }
                if sawReconnecting && sawChanged {
                    await watcher.stop()
                    break
                }
            }
            return (sawReconnecting: sawReconnecting, sawChanged: sawChanged)
        }
        guard let (sawReconnecting, sawChanged) = outcome else {
            return XCTFail("watcher stream stalled: no .reconnecting + .changed within the deadline")
        }
        XCTAssertTrue(sawReconnecting)
        XCTAssertTrue(sawChanged)
    }

    /// Races `operation` against a wall-clock deadline; `nil` means it
    /// stalled. Generous by test standards (these suites complete in
    /// milliseconds) so slow CI simulators don't flake, while a genuine
    /// stall still fails within one test's budget instead of hanging the
    /// whole run.
    private func withDeadline<T: Sendable>(
        seconds: TimeInterval = 10,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private actor AttemptCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
