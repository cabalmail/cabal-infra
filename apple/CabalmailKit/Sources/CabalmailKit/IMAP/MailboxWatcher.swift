import Foundation

/// Factory function that opens a fresh change stream for the given folder.
///
/// Live code passes `{ try await client.idle(folder: $0) }`; tests pass a
/// closure that returns a pre-scripted stream so the watcher's reconnect
/// and event-fanout logic is exercised without a server.
public typealias IdleStreamFactory = @Sendable (String) async throws -> AsyncThrowingStream<IdleEvent, Error>

/// Foreground change watcher for a single folder.
///
/// `MessageListViewModel` starts one when a folder's list comes on screen
/// and stops it when the list goes away. The stream it watches is
/// `ImapClient.idle(folder:)`, which the production client
/// (`ApiBackedImapClient`) implements by polling the folder's status over
/// the API — there is no IMAP connection and no server push; the `idle`
/// and `IdleEvent` names are kept from the protocol's IMAP origins.
///
/// The watcher doesn't drive the refresh itself — instead it exposes an
/// async stream of `WatchEvent.changed` ticks. `MessageListViewModel`
/// consumes the stream and decides whether to call `refresh()` or a
/// lighter incremental fetch. Separating observation from reaction keeps
/// the kit policy-free (no UI preferences, no debouncing decisions) and
/// testable — unit tests script the stream's end and assert the watcher
/// emits the expected ticks.
///
/// When the stream ends or fails, the watcher reopens it after a backoff
/// that doubles from 2s up to 60s, and resets to 2s each time the factory
/// hands back a new stream.
public actor MailboxWatcher {
    public enum WatchEvent: Sendable, Equatable {
        /// Mailbox changed — caller should pull fresh envelopes.
        case changed
        /// Watcher entered the reconnect backoff state.
        case reconnecting(after: TimeInterval)
        /// Watcher (re)opened the change stream and is watching.
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
            // The weak capture belongs on the termination handler itself,
            // not on the `Task` inside it. A `[weak self]` one level in still
            // needs a strong `self` in the enclosing closure to form the weak
            // reference from, and this enclosing closure is *stored* on the
            // continuation — which the watcher in turn holds — so that strong
            // reference is a cycle for as long as the stream lives. Capturing
            // at the stored closure is what makes the weakness do what it was
            // written to do (and what silences `#ImplicitStrongCapture`).
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.stop() }
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
                    "change stream closed on \(closedFolder); reopening"
                )
            } catch is CancellationError {
                break
            } catch {
                let erroredFolder = folder
                let backoff = currentBackoffSeconds
                CabalmailLog.warn(
                    "MailboxWatcher",
                    "change stream error on \(erroredFolder): \(error); backing off \(backoff)s"
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
