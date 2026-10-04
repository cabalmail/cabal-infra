import XCTest
@testable import CabalmailKit

/// Exercises `MailboxWatcher`'s reconnect loop against a scripted
/// stream factory. The production factory is `ApiBackedImapClient.idle(folder:)`,
/// which polls the API — we substitute a closure that returns pre-built
/// `AsyncThrowingStream`s to drive the watcher's states without touching
/// the network.
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

    /// #1797: the backoff grows while opening keeps failing and drops back
    /// once an open succeeds. The other tests here pin the initial backoff
    /// to the maximum, so none of them could see the doubling.
    func testBackoffDoublesWhileOpeningFailsAndResetsAfterASuccessfulOpen() async {
        let attempts = AttemptCounter()
        let watcher = MailboxWatcher(
            folder: "INBOX",
            streamFactory: { _ in
                // Six failed opens, one that succeeds and then drops, then
                // failed opens again.
                if await attempts.next() == 7 {
                    return AsyncThrowingStream { $0.finish(throwing: CabalmailError.network("dropped")) }
                }
                throw CabalmailError.network("offline")
            },
            initialBackoffSeconds: 2,
            maxBackoffSeconds: 60,
            clock: { _ in }
        )
        let stream = await watcher.start()
        let waits = await withDeadline { await Self.reconnectWaits(from: stream, count: 8, stopping: watcher) }
        XCTAssertEqual(waits, [2, 4, 8, 16, 32, 60, 2, 4])
    }

    /// #1797 end to end, over the production factory. Offline, every poll
    /// fails; the watcher has to back off rather than reopen every 2 s.
    /// Before the fix the first poll ran inside the stream, every open
    /// succeeded, and this read [2, 2, 2, 2].
    func testWatcherOverTheApiBackedClientBacksOffWhileOffline() async {
        let api = URLSessionApiClient(
            configuration: Configuration(
                controlDomain: "cabalmail.example",
                domains: [MailDomain(domain: "cabalmail.example")],
                invokeUrl: URL(string: "https://api.cabalmail.example/prod")!,
                cognito: .init(region: "us-east-1", userPoolId: "u", clientId: "c")
            ),
            authService: StubAuthService(),
            transport: ScriptedHTTPTransport { _ in throw CabalmailError.network("offline") }
        )
        let client = ApiBackedImapClient(api: api, host: "imap.example.com", pollInterval: 0.01)
        let watcher = MailboxWatcher(
            folder: "INBOX",
            streamFactory: { try await client.idle(folder: $0) },
            initialBackoffSeconds: 2,
            maxBackoffSeconds: 60,
            clock: { _ in }
        )
        let stream = await watcher.start()
        let waits = await withDeadline { await Self.reconnectWaits(from: stream, count: 4, stopping: watcher) }
        XCTAssertEqual(waits, [2, 4, 8, 16])
    }

    /// The first `count` reconnect waits the watcher announces, after which
    /// it is stopped.
    private static func reconnectWaits(
        from stream: AsyncStream<MailboxWatcher.WatchEvent>,
        count: Int,
        stopping watcher: MailboxWatcher
    ) async -> [TimeInterval] {
        var waits: [TimeInterval] = []
        for await event in stream {
            if case .reconnecting(let after) = event { waits.append(after) }
            if waits.count == count {
                await watcher.stop()
                break
            }
        }
        return waits
    }

    /// Races `operation` against a wall-clock deadline; `nil` means it
    /// stalled. Generous by test standards (these suites complete in
    /// milliseconds) so slow CI simulators don't flake, while a genuine
    /// stall still fails within one test's budget instead of hanging the
    /// whole run.
    /// #1761: the termination handler the watcher stores on its own
    /// continuation used to hold `self` strongly. The `[weak self]` written
    /// one level in, on the `Task` inside the handler, could not prevent that
    /// — forming a weak reference needs a strong one in the enclosing scope,
    /// which is the handler. So the watcher retained itself for as long as a
    /// consumer held the stream.
    ///
    /// The factory throws `CancellationError` because that is the one input
    /// that makes `runLoop` return: the run loop holds `self` strongly for as
    /// long as it runs, which would mask the cycle and let this test pass
    /// either way.
    func testWatcherDeallocatesWhileAConsumerStillHoldsTheStream() async throws {
        var watcher: MailboxWatcher? = MailboxWatcher(
            folder: "INBOX",
            streamFactory: { _ in throw CancellationError() },
            initialBackoffSeconds: 0.01,
            maxBackoffSeconds: 0.01,
            clock: { _ in }
        )
        weak var leaked: MailboxWatcher? = watcher
        let stream = await watcher!.start()
        watcher = nil

        var released = false
        for _ in 0..<200 {
            if leaked == nil {
                released = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            released,
            "the watcher outlived its last owner: its stored termination handler is holding it (#1761)"
        )
        // The stream is what keeps the continuation (and so the handler) alive
        // for the whole poll above; releasing it early would end the stream,
        // clear the handler, and let even the cyclic version deallocate.
        withExtendedLifetime(stream) {}
    }

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
