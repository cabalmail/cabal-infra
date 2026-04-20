import XCTest
@testable import CabalmailKit

/// Exercises `MailboxWatcher`'s IDLE reconnect loop against a scripted
/// stream factory. The production factory is `LiveImapClient.idle(folder:)`,
/// which opens a real socket — we substitute a closure that returns
/// pre-built `AsyncThrowingStream`s to drive the watcher's states without
/// touching the network.
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
                    break
                }
            case .reconnecting:
                break
            }
            if changes >= 3 { break }
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
        XCTAssertTrue(sawReconnecting)
        XCTAssertTrue(sawChanged)
    }
}

private actor AttemptCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
