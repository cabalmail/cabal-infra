import Foundation

/// Serializes one compose session's server-side Drafts mutations, and lets
/// a discard close the session against later ones.
///
/// `/save_draft` save and `/save_draft` discard both act on a single Drafts
/// copy, and every save lands a *new* UID retiring the last (#1071). So the
/// two can never overlap: whichever round trip finishes second decides what
/// is left on the server, and both orderings strand a copy the user
/// explicitly threw away (#1163) —
///
/// - a save already in flight when Discard runs: the discard expunges the
///   UID the model holds, then the completing save appends a fresh one that
///   no retirement covers;
/// - an autosave tick landing *inside* the discard round trip: it replaces a
///   UID the discard has already expunged, which `/save_draft` degrades to
///   save-as-new.
///
/// The old interlock was a bare `serverSaveInFlight` flag that only the save
/// paths set and only the autosave path read, so neither ordering was
/// covered. This type covers both: mutations run one at a time, and
/// `close(runningDiscard:)` marks the session closed *before* its first
/// suspension point, so a tick that fires during the discard declines rather
/// than resurrecting the draft.
///
/// **Send terminates the session the same way** (#1198). `/send` carries
/// `discardingDraft:`, so both orderings above read identically with "the
/// discard" replaced by "the send" — the copy the send names is expunged
/// server-side, and a save that lands either side of it strands the copy it
/// appends. Send therefore runs through `close(runningThrowing:)` rather
/// than going round the queue.
@MainActor
final class ServerDraftMutationQueue {

    /// The most recently enqueued mutation, or nil when nothing is running.
    /// Doubles as the busy flag `serverSaveInFlight` used to be.
    private var tail: Task<Void, Never>?

    /// Set by `close(runningDiscard:)`. Once closed, nothing else may write
    /// to the server: the user has discarded the draft, and a late append is
    /// the strand this queue exists to prevent.
    private(set) var isClosed = false

    /// Whether the debounced autosave loop may start a save right now.
    ///
    /// A tick that arrives mid-mutation is *skipped*, not queued — the next
    /// tick 60 seconds later will carry the same text, so queueing would only
    /// buy a redundant round trip.
    var acceptsAutosave: Bool { !isClosed && tail == nil }

    /// Runs `work` after every mutation already queued, and waits for it.
    /// Skipped entirely if a discard closed the session while `work` waited
    /// its turn.
    func run(_ work: @escaping @MainActor () async -> Void) async {
        await enqueue { [weak self] in
            guard self?.isClosed == false else { return }
            await work()
        }
    }

    /// Throwing variant of `run(_:)`, for the close-without-send save whose
    /// failure has to reach the user as a banner rather than be swallowed.
    func runThrowing(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let box = ErrorBox()
        await enqueue { [weak self] in
            guard self?.isClosed == false else { return }
            do { try await work() } catch { box.error = error }
        }
        if let error = box.error { throw error }
    }

    /// Closes the session to further saves, then runs the discard behind
    /// anything already in flight.
    ///
    /// `work` is called *after* the wait, so a caller that reads
    /// `serverDraftRef` inside it sees the UID an in-flight save adopted
    /// rather than the one it superseded — which is the whole point.
    func close(runningDiscard work: @escaping @MainActor () async -> Void) async {
        isClosed = true
        await enqueue(work)
    }

    /// Throwing variant of `close(runningDiscard:)`, for Send.
    ///
    /// `/send` carries `discardingDraft:`, so a delivery ends this session's
    /// server-side copy exactly as a discard does and belongs behind the same
    /// interlock (#1198). What differs is the failure: a send that throws
    /// leaves the composer up with the message still in it, so the session
    /// *reopens* — otherwise the close-without-send push, and every autosave
    /// after it, would silently stop reaching the server.
    func close(runningThrowing work: @escaping @MainActor () async throws -> Void) async throws {
        isClosed = true
        let box = ErrorBox()
        await enqueue {
            do { try await work() } catch { box.error = error }
        }
        if let error = box.error {
            isClosed = false
            throw error
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let predecessor = tail
        let task = Task { @MainActor in
            await predecessor?.value
            await work()
        }
        tail = task
        await task.value
        // Only the last link clears the tail; an earlier one finishing
        // would otherwise let a save start alongside its successor.
        if tail == task { tail = nil }
    }
}

/// Carries a thrown error back out of the queued block, which cannot
/// itself throw (the chain is `Task<Void, Never>` so one failure can't
/// cancel the mutations queued behind it).
@MainActor
private final class ErrorBox {
    var error: Error?
}
