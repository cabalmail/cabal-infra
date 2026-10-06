import Foundation

/// Orders `AppState`'s sign-out against everything else that starts or ends
/// a session. One per `AppState`.
///
/// - One teardown at a time. `signOut()` awaits the push deregistration
///   before it drops the client, so a second sign-out (the user's, while an
///   expiry's teardown is waiting on the network) used to run the whole
///   teardown again, and a sign-in that completed meanwhile was torn down by
///   the stale one (#1829). A second call now waits for the first, and a
///   sign-in or restore waits for a teardown in flight before it starts.
/// - A teardown waits for the restore in flight, and every sign-out bumps a
///   generation. A sign-out while the launch restore was still building the
///   session used to find no client, leave the tokens stored, and be undone
///   when the restore wired the session (#1827). The restore now sees the
///   generation change and ends the session it built instead, before the
///   teardown carries on, so nothing can sign in between the two.
/// - A count of sign-out requests, so an expiry's teardown knows whether the
///   user also asked to sign out while it ran and leaves the sign-in form
///   without the "session expired" note (#1829).
/// - The sessions that have ended, held weakly, so work a session started
///   that answers once it is ending cannot write back what the sign-out
///   cleared (#1848).
///
/// The teardown runs in a task of its own, so it finishes even when the
/// caller's task is cancelled: an expiry's teardown starts on the session
/// observer's task, and cancelling that observer is one of its first steps.
@MainActor
final class SessionTeardownGate {
    private(set) var generation = 0
    private(set) var signOutRequests = 0
    private var teardown: Task<Void, Never>?
    private var restoresInFlight = 0
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var endedSessions: [EndedSession] = []

    /// A teardown is running; a sign-out now joins it.
    var isTearingDown: Bool { teardown != nil }

    /// Records a sign-out request and runs `body` as the one teardown, once
    /// any restore in flight has finished, or waits for the teardown already
    /// running.
    func signOut(_ body: @escaping @MainActor () async -> Void) async {
        generation += 1
        signOutRequests += 1
        if let running = teardown {
            await running.value
            return
        }
        // The task clears the slot itself, as its last step, so the slot is
        // empty the moment anyone awaiting it resumes. No other teardown can
        // start while it is set.
        let task = Task { @MainActor [weak self] in
            await self?.awaitRestores()
            await body()
            self?.teardown = nil
        }
        teardown = task
        await task.value
    }

    /// Returns once the teardown in flight, if any, has finished, so a new
    /// session never overlaps the end of the last one.
    func awaitTeardown() async {
        if let running = teardown {
            await running.value
        }
    }

    /// Marks a restore as in flight and returns the generation it started
    /// in. Pair with `endRestore()`.
    func beginRestore() -> Int {
        restoresInFlight += 1
        return generation
    }

    /// A restore has finished, wired or not.
    func endRestore() {
        restoresInFlight -= 1
        guard restoresInFlight == 0 else { return }
        let waiters = restoreWaiters
        restoreWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Records that `session` (a session's client) is ending. Called before
    /// the teardown clears the account's state.
    func markEnded(_ session: AnyObject) {
        endedSessions.removeAll { $0.session == nil }
        endedSessions.append(EndedSession(session: session))
    }

    /// Whether `session` has been marked ended.
    func hasEnded(_ session: AnyObject) -> Bool {
        endedSessions.contains { $0.session === session }
    }

    private func awaitRestores() async {
        guard restoresInFlight > 0 else { return }
        await withCheckedContinuation { restoreWaiters.append($0) }
    }
}

/// Weak, so the list never keeps an ended session's client alive, and a
/// freed client's slot cannot match a new one.
private struct EndedSession {
    weak var session: AnyObject?
}
