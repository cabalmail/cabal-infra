import Foundation

/// Drains the `Outbox` when reachability returns.
///
/// Decoupled from `CabalmailClient.send(_:)` so the submission path can
/// stay synchronous from the caller's perspective (send → success or a
/// thrown error) while still recovering from transient transport
/// failures. The flow:
///
/// 1. `CabalmailClient.send(_:)` tries SMTP + Sent-folder APPEND.
/// 2. If SMTP throws with a transport-class error and reachability is
///    down, the client enqueues the message in `Outbox` and returns
///    `SendOutcome.queued(_)` to the caller.
/// 3. `SendQueue` observes `Reachability.changes()`; each transition to
///    "reachable" kicks a drain pass that retries every queued entry
///    in enqueue order.
/// 4. Failures increment `Entry.attempts` and push the error into the
///    debug log; an entry that hits `Outbox.maxAttempts` is removed and
///    surfaced as a permanent failure via the `onFailure` callback.
///
/// The queue is main-actor-agnostic: the drain pass runs on its own task
/// so UI doesn't hitch behind a slow retry. Callbacks fire back to the
/// caller's context via `@Sendable` closures.
public actor SendQueue {
    public typealias Sender = @Sendable (OutgoingMessage) async throws -> Void

    private let outbox: Outbox
    private let sender: Sender
    private var drainTask: Task<Void, Never>?
    private var reachabilityTask: Task<Void, Never>?
    /// A kick that arrived while a drain was already running, owed another
    /// pass once that one finishes (#1061).
    private var pendingKick = false
    /// Identifies the drain a completion belongs to, so a task retired by
    /// `stop()` — or superseded by a later one — can't clear or restart the
    /// drain that replaced it.
    private var drainGeneration = 0

    public init(outbox: Outbox, sender: @escaping Sender) {
        self.outbox = outbox
        self.sender = sender
    }

    /// Starts observing reachability transitions. The first yield on the
    /// stream is the current value so a launch-time "already connected"
    /// state immediately triggers a drain of anything left in the outbox
    /// from a prior session.
    public func bind(reachability: AsyncStream<Bool>) {
        reachabilityTask?.cancel()
        reachabilityTask = Task { [weak self] in
            for await reachable in reachability {
                guard !Task.isCancelled, let self else { break }
                if reachable {
                    await self.kickDrain()
                }
            }
        }
    }

    /// Triggers a drain pass explicitly — used by tests and by
    /// `CabalmailClient.send(_:)` after enqueueing a message so a
    /// reachability signal that already came through gets another shot.
    public func kickDrain() {
        guard drainTask == nil || drainTask?.isCancelled == true else {
            // A drain is already in flight, and it listed the outbox when it
            // started — a message enqueued since is invisible to it. Dropping
            // this kick would leave that message queued until the next
            // reachability transition, which on a stable connection may never
            // come (#1061). Remember it instead and run another pass.
            pendingKick = true
            return
        }
        startDrain()
    }

    public func stop() {
        drainTask?.cancel()
        drainTask = nil
        pendingKick = false
        drainGeneration += 1
        reachabilityTask?.cancel()
        reachabilityTask = nil
    }

    private func startDrain() {
        pendingKick = false
        drainGeneration += 1
        let generation = drainGeneration
        drainTask = Task { [weak self] in
            await self?.drainWhileKicked()
            await self?.markDrainComplete(generation: generation)
        }
    }

    /// Repeats the pass while kicks keep arriving during one, so a message
    /// enqueued mid-drain is picked up by the same task rather than waiting
    /// for a fresh trigger. Each pass re-lists the outbox, so the retry
    /// budget is spent exactly as it would be across separate kicks.
    private func drainWhileKicked() async {
        repeat {
            pendingKick = false
            await drain()
        } while pendingKick && !Task.isCancelled
    }

    private func markDrainComplete(generation: Int) {
        guard generation == drainGeneration else { return }
        drainTask = nil
        // A kick landing between the last pass and this retirement would
        // otherwise fall into the same hole the coalescing closes.
        if pendingKick {
            startDrain()
        }
    }

    private func drain() async {
        let entries = (try? await outbox.list()) ?? []
        guard !entries.isEmpty else { return }
        CabalmailLog.info("SendQueue", "draining \(entries.count) outbox entr\(entries.count == 1 ? "y" : "ies")")
        for entry in entries {
            if Task.isCancelled { return }
            await attemptSend(entry)
        }
    }

    private func attemptSend(_ original: Outbox.Entry) async {
        var entry = original
        entry.attempts += 1
        entry.lastAttemptAt = Date()
        do {
            try await sender(entry.message)
            try? await outbox.remove(id: entry.id)
            CabalmailLog.info("SendQueue", "sent queued message \(entry.id)")
        } catch CabalmailError.sendInFlight {
            // The API still holds a dedupe claim on this message's Message-Id
            // and can't prove it delivered, so this attempt says nothing about
            // the message's fate. Keep the entry and roll `attempts` back: a
            // claim outliving a handful of drains must not exhaust the retry
            // budget and drop a message nobody ever sent (#1019). The claim
            // clears within the server's dedupe window, and the next drain
            // either delivers it or is told it already went out.
            entry.attempts = original.attempts
            try? await outbox.update(entry)
            CabalmailLog.info(
                "SendQueue",
                "deferred \(entry.id): an earlier submission of it is still in flight"
            )
        } catch {
            entry.lastError = "\(error)"
            let maxAttempts = outbox.maxAttempts
            CabalmailLog.warn(
                "SendQueue",
                "queued send failed (\(entry.attempts)/\(maxAttempts)): \(error)"
            )
            if entry.attempts >= maxAttempts {
                try? await outbox.remove(id: entry.id)
                CabalmailLog.error(
                    "SendQueue",
                    "dropping \(entry.id) after \(entry.attempts) attempts"
                )
            } else {
                try? await outbox.update(entry)
            }
        }
    }
}
