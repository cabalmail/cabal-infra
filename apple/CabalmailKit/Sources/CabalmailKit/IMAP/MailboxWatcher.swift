import Foundation

/// Factory function that opens a fresh IDLE stream for the given folder.
///
/// Live code passes `{ try await client.idle(folder: $0) }`; tests pass a
/// closure that returns a pre-scripted stream so the watcher's reconnect
/// and event-fanout logic is exercised without a real IMAP connection.
public typealias IdleStreamFactory = @Sendable (String) async throws -> AsyncThrowingStream<IdleEvent, Error>

/// Foreground IDLE loop for a single folder.
///
/// Phase 7 of the client plan calls for "while the app is foregrounded,
/// IDLE keeps an IMAP IDLE connection open; EXISTS events trigger an
/// immediate envelope fetch." `MailboxWatcher` is the glue that makes that
/// happen: start it when a folder becomes the active mailbox, stop it on
/// sign-out, reconnect on transport errors with bounded backoff.
///
/// The watcher doesn't drive the refresh itself — instead it exposes an
/// async stream of `WatchEvent.changed` ticks. `MessageListViewModel`
/// consumes the stream and decides whether to call `refresh()` or a
/// lighter incremental fetch. Separating observation from reaction keeps
/// the kit policy-free (no UI preferences, no debouncing decisions) and
/// testable — unit tests script the IDLE stream end and assert the
/// watcher emits the expected ticks.
///
/// Reconnect policy is deliberately conservative: the server disconnects
/// IDLE sessions every 29 minutes per RFC 2177, so tight reconnect loops
/// would hammer the backend. Backoff doubles from 2s up to 60s for
/// transport errors and resets after a successful IDLE attach.
public actor MailboxWatcher {
    public enum WatchEvent: Sendable, Equatable {
        /// Mailbox changed — caller should pull fresh envelopes.
        case changed
        /// Watcher entered the reconnect backoff state.
        case reconnecting(after: TimeInterval)
        /// Watcher resumed and is now actively IDLEing.
        case active
    }

    private let folder: String
    private let streamFactory: IdleStreamFactory
    private let clock: @Sendable (TimeInterval) async -> Void
    private var runner: Task<Void, Never>?
    private var continuation: AsyncStream<WatchEvent>.Continuation?

    private let initialBackoffSeconds: Double
    private let maxBackoffSeconds: Double
    private var currentBackoffSeconds: Double

    public init(
        folder: String,
        streamFactory: @escaping IdleStreamFactory,
        initialBackoffSeconds: Double = 2,
        maxBackoffSeconds: Double = 60,
        clock: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.folder = folder
        self.streamFactory = streamFactory
        self.initialBackoffSeconds = initialBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.currentBackoffSeconds = initialBackoffSeconds
        self.clock = clock
    }

    /// Starts the watcher and returns the event stream. Re-invocation on an
    /// already-running watcher cancels the old run first.
    public func start() -> AsyncStream<WatchEvent> {
        stop()
        let stream = AsyncStream<WatchEvent> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in await self?.stop() }
            }
        }
        runner = Task { [weak self] in
            await self?.runLoop()
        }
        return stream
    }

    public func stop() {
        runner?.cancel()
        runner = nil
        continuation?.finish()
        continuation = nil
        currentBackoffSeconds = initialBackoffSeconds
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                let stream = try await streamFactory(folder)
                currentBackoffSeconds = initialBackoffSeconds
                continuation?.yield(.active)
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event.kind {
                    case .exists, .expunge, .fetch:
                        continuation?.yield(.changed)
                    }
                }
                let closedFolder = folder
                CabalmailLog.info(
                    "MailboxWatcher",
                    "IDLE stream closed on \(closedFolder); reconnecting"
                )
            } catch is CancellationError {
                break
            } catch {
                let erroredFolder = folder
                let backoff = currentBackoffSeconds
                CabalmailLog.warn(
                    "MailboxWatcher",
                    "IDLE error on \(erroredFolder): \(error); backing off \(backoff)s"
                )
            }
            if Task.isCancelled { break }
            let wait = currentBackoffSeconds
            continuation?.yield(.reconnecting(after: wait))
            currentBackoffSeconds = min(currentBackoffSeconds * 2, maxBackoffSeconds)
            await clock(wait)
        }
    }
}
