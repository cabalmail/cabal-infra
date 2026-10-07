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
///    debug log. A failed entry isn't retried until its backoff delay
///    (exponential in its attempt count, from its last attempt) has passed,
///    so a flapping network can't spend the whole budget in seconds; the
///    queue schedules its own drain for when the next entry comes due. A
///    reconnect since an entry's last attempt shortens its wait to the
///    first step (`Backoff.base`), so mail queued during a long outage
///    goes soon after the network returns without letting a flapping
///    link retry more often than that.
/// 5. An entry that hits `Outbox.maxAttempts` stays in the outbox marked
///    `failedAt`. The queue stops retrying it, and the app surfaces it
///    (via `Outbox.changes()`) for the user to retry or discard.
///
/// The queue is main-actor-agnostic: the drain pass runs on its own task
/// so UI doesn't hitch behind a slow retry. Callbacks fire back to the
/// caller's context via `@Sendable` closures.
public actor SendQueue {
    public typealias Sender = @Sendable (OutgoingMessage) async throws -> Void

    /// Time-based retry spacing: `base` after the first failed attempt,
    /// doubling per attempt, capped at `cap`.
    public struct Backoff: Sendable, Equatable {
        public var base: TimeInterval
        public var cap: TimeInterval

        public init(base: TimeInterval, cap: TimeInterval) {
            self.base = base
            self.cap = cap
        }

        /// 30 s, 1 min, 2 min … capped at an hour: the default ten attempts
        /// span roughly three hours before an entry is marked failed.
        public static let standard = Backoff(base: 30, cap: 3600)

        /// The wait after `attempts` attempts. An entry never attempted is
        /// due at once; one whose attempt was rolled back (a send still in
        /// flight server-side) still waits `base`, so it can't spin.
        public func delay(afterAttempts attempts: Int) -> TimeInterval {
            let exponent = Double(max(attempts, 1) - 1)
            return min(base * pow(2, exponent), cap)
        }

        /// When `entry` may next be attempted.
        public func nextAttempt(for entry: Outbox.Entry) -> Date? {
            guard let last = entry.lastAttemptAt else { return nil }
            return last.addingTimeInterval(delay(afterAttempts: entry.attempts))
        }
    }

    private let outbox: Outbox
    private let sender: Sender
    private let backoff: Backoff
    private let now: @Sendable () -> Date
    /// When reachability last came back; see `dueDate(for:)`.
    private var reconnectedAt: Date?
    /// Sleeps until the earliest deferred entry is due, then kicks a drain.
    private var retryTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var reachabilityTask: Task<Void, Never>?
    /// A kick that arrived while a drain was already running, owed another
    /// pass once that one finishes (#1061).
    private var pendingKick = false
    /// Identifies the drain a completion belongs to, so a task retired by
    /// `stop()` — or superseded by a later one — can't clear or restart the
    /// drain that replaced it.
    private var drainGeneration = 0
    /// Set by `stop()`, for good: a stopped queue drains nothing again.
    private var stopped = false

    public init(
        outbox: Outbox,
        backoff: Backoff = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        sender: @escaping Sender
    ) {
        self.outbox = outbox
        self.backoff = backoff
        self.now = now
        self.sender = sender
    }

    /// Starts observing reachability transitions. The first yield on the
    /// stream is the current value so a launch-time "already connected"
    /// state immediately triggers a drain of anything left in the outbox
    /// from a prior session.
    public func bind(reachability: AsyncStream<Bool>) {
        guard !stopped else { return }
        reachabilityTask?.cancel()
        reachabilityTask = Task { [weak self] in
            for await reachable in reachability {
                guard !Task.isCancelled, let self else { break }
                if reachable {
                    await self.reconnected()
                }
            }
        }
    }

    /// Triggers a drain pass explicitly — used by tests and by
    /// `CabalmailClient.send(_:)` after enqueueing a message so a
    /// reachability signal that already came through gets another shot.
    public func kickDrain() {
        guard !stopped else { return }
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

    private func reconnected() {
        reconnectedAt = now()
        kickDrain()
    }

    /// Stops the queue for good: the drain in flight is cancelled, the
    /// reachability observer and the retry timer go, and a later kick, bind
    /// or reconnect starts nothing. What is queued stays in the outbox, and
    /// an attempt the cancel interrupts writes nothing back to it. The
    /// owning client's `shutdown()` calls this when the app lets the client
    /// go, so a client the app no longer holds can't drain an outbox the
    /// app's current client also drains.
    public func stop() {
        stopped = true
        drainTask?.cancel()
        drainTask = nil
        pendingKick = false
        drainGeneration += 1
        reachabilityTask?.cancel()
        reachabilityTask = nil
        retryTask?.cancel()
        retryTask = nil
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
        } else {
            Task { await scheduleRetry(generation: generation) }
        }
    }

    private func drain() async {
        let current = now()
        let entries = ((try? await outbox.list()) ?? []).filter { entry in
            guard !entry.isFailed else { return false }
            guard let due = dueDate(for: entry) else { return true }
            return due <= current
        }
        guard !entries.isEmpty else { return }
        CabalmailLog.info("SendQueue", "draining \(entries.count) outbox entr\(entries.count == 1 ? "y" : "ies")")
        for entry in entries {
            if Task.isCancelled { return }
            await attemptSend(entry)
        }
    }

    /// Arms one timer for the earliest entry still waiting out its backoff,
    /// so a deferred retry happens even if reachability never changes.
    private func scheduleRetry(generation: Int) async {
        guard generation == drainGeneration, drainTask == nil else { return }
        let entries = (try? await outbox.list()) ?? []
        let due = entries.filter { !$0.isFailed }.compactMap { dueDate(for: $0) }.min()
        // Re-check after the await: a stop() or a new drain may have run.
        guard generation == drainGeneration, drainTask == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        guard let due else { return }
        let delay = max(due.timeIntervalSince(now()), 0)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.retryTimerFired(generation: generation)
        }
    }

    /// When `entry` may next be attempted: its backoff, cut to
    /// `Backoff.base` when the network came back after its last attempt.
    private func dueDate(for entry: Outbox.Entry) -> Date? {
        guard let last = entry.lastAttemptAt, let scheduled = backoff.nextAttempt(for: entry) else { return nil }
        if let reconnectedAt, reconnectedAt > last {
            return min(scheduled, last.addingTimeInterval(backoff.base))
        }
        return scheduled
    }

    private func retryTimerFired(generation: Int) {
        guard generation == drainGeneration else { return }
        retryTask = nil
        kickDrain()
    }

    private func attemptSend(_ original: Outbox.Entry) async {
        var entry = original
        entry.attempts += 1
        entry.lastAttemptAt = now()
        do {
            try await sender(entry.message)
            try? await outbox.remove(id: entry.id)
            CabalmailLog.info("SendQueue", "sent queued message \(entry.id)")
        } catch CabalmailError.sendInFlight {
            guard !stopped else { return }
            // The API still holds a dedupe claim on this message's Message-Id
            // and can't prove it delivered, so this attempt says nothing about
            // the message's fate. Keep the entry and roll `attempts` back: a
            // claim outliving a handful of drains must not exhaust the retry
            // budget and drop a message nobody ever sent (#1019). The claim
            // clears within the server's dedupe window, and the next drain
            // either delivers it or is told it already went out.
            entry.attempts = original.attempts
            guard await writeBack(entry) else { return }
            CabalmailLog.info(
                "SendQueue",
                "deferred \(entry.id): an earlier submission of it is still in flight"
            )
        } catch {
            // `stop()` cancelled this attempt, so its failure says nothing
            // about the message, and the outbox may have been wiped since
            // (a sign-out): writing the entry back would bring it back.
            guard !stopped else { return }
            entry.lastError = "\(error)"
            let maxAttempts = outbox.maxAttempts
            CabalmailLog.warn(
                "SendQueue",
                "queued send failed (\(entry.attempts)/\(maxAttempts)): \(error)"
            )
            if entry.attempts >= maxAttempts {
                // Keep the message: marking it failed takes it out of the
                // drain and puts it in front of the user (audit F8).
                entry.failedAt = now()
                CabalmailLog.error(
                    "SendQueue",
                    "giving up on \(entry.id) after \(entry.attempts) attempts; kept for the user"
                )
            }
            await writeBack(entry)
        }
    }

    /// Records an attempt on its entry, unless the entry left the outbox
    /// while the attempt ran (a sign-out's wipe, a discard): then it stays
    /// gone (#1909).
    @discardableResult
    private func writeBack(_ entry: Outbox.Entry) async -> Bool {
        do {
            if try await outbox.update(entry) { return true }
            CabalmailLog.info("SendQueue", "\(entry.id) left the outbox during its attempt; not written back")
        } catch {
            CabalmailLog.warn("SendQueue", "couldn't record the attempt on \(entry.id): \(error)")
        }
        return false
    }
}
