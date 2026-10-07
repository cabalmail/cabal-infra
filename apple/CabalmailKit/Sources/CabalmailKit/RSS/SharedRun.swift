import Foundation
import Synchronization

/// Work several callers share: `RssSyncEngine`'s single flight. The engine
/// starts a run for the first caller and joins later ones to it, so each gets
/// the one result instead of repeating the work.
///
/// A caller whose task is cancelled stops waiting at once and gets nil, while
/// the run carries on for whoever still waits. When the last of them stops
/// waiting the run is cancelled too, which is what a lone caller's cancel did
/// before runs were shared: a sidebar leaving the screen mid-sync still stops
/// its sync (#1908). A run nobody waits for is *abandoned*; the engine starts
/// the next caller a fresh run behind it rather than joining it to one that
/// is unwinding (`Flight.join`).
final class SharedRun<Value: Sendable>: Sendable {
    /// One caller's place in the run, taken synchronously (inside the engine
    /// actor) before the caller suspends, so a cancel that lands before the
    /// caller is waiting still counts as that caller leaving.
    struct Ticket: Sendable {
        fileprivate let number: Int
    }

    private struct State {
        var lastTicket = 1
        /// Tickets that have joined and not yet left or been answered; the
        /// caller that starts the run holds the first.
        var joined: Set<Int> = [1]
        var waiting: [Int: CheckedContinuation<Value?, Never>] = [:]
        var value: Value?
        var abandoned = false
    }

    private let state = Mutex(State())
    private let work: Task<Value, Never>
    /// The place of the caller that started the run.
    let firstTicket = Ticket(number: 1)

    init(_ operation: @escaping @Sendable () async -> Value) {
        work = Task(operation: operation)
        let work = work
        Task { [self] in finish(await work.value) }
    }

    /// Callers joined and still waiting; the tests' view of a join.
    var waiterCount: Int { state.withLock { $0.joined.count } }

    /// A place in the run, or nil once it is abandoned: checked and taken
    /// under one lock, so a last caller leaving at the same moment cannot
    /// hand a newcomer a run it has just cancelled.
    func join() -> Ticket? {
        state.withLock { state in
            guard !state.abandoned else { return nil }
            state.lastTicket += 1
            state.joined.insert(state.lastTicket)
            return Ticket(number: state.lastTicket)
        }
    }

    /// The run's result, or nil when the calling task is cancelled first.
    func value(for ticket: Ticket) async -> Value? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let answer: Value?? = state.withLock { state in
                    if let value = state.value { return .some(value) }
                    // Left already: cancelled between joining and waiting.
                    guard state.joined.contains(ticket.number) else { return .some(nil) }
                    state.waiting[ticket.number] = continuation
                    return nil
                }
                if let answer { continuation.resume(returning: answer) }
            }
        } onCancel: {
            leave(ticket)
        }
    }

    /// Waits for the work to end, however it ends, without joining it; a run
    /// started behind an abandoned one waits here first.
    func settled() async {
        _ = await work.value
    }

    private func leave(_ ticket: Ticket) {
        let (continuation, cancelsWork) = state.withLock { state in
            guard state.joined.remove(ticket.number) != nil else {
                return (CheckedContinuation<Value?, Never>?.none, false)
            }
            let continuation = state.waiting.removeValue(forKey: ticket.number)
            let last = state.joined.isEmpty && state.value == nil && !state.abandoned
            if last { state.abandoned = true }
            return (continuation, last)
        }
        continuation?.resume(returning: nil)
        if cancelsWork { work.cancel() }
    }

    private func finish(_ value: Value) {
        let waiters = state.withLock { state in
            state.value = value
            state.joined.removeAll()
            defer { state.waiting.removeAll() }
            return Array(state.waiting.values)
        }
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }
}

/// A `SharedRun` in its owner's slot, with the identity its end is recorded
/// under, so a run that ends after a newer one took the slot leaves it alone.
struct Flight<Value: Sendable>: Sendable {
    let id: UUID
    let run: SharedRun<Value>

    /// Joins `current` while somebody still waits for it; otherwise starts a
    /// fresh run behind it, so two runs of the same work never overlap.
    /// Synchronous, so the owning actor stores the flight it returns before
    /// anyone else can look. `body` gets the new flight's id to record its end.
    static func join(
        _ current: Flight?, else body: @escaping @Sendable (UUID) async -> Value
    ) -> (flight: Flight, ticket: SharedRun<Value>.Ticket) {
        if let current, let ticket = current.run.join() { return (current, ticket) }
        return start(behind: current?.run, body)
    }

    /// Starts a fresh run, which waits for `behind` to end first.
    static func start(
        behind: SharedRun<Value>?, _ body: @escaping @Sendable (UUID) async -> Value
    ) -> (flight: Flight, ticket: SharedRun<Value>.Ticket) {
        let id = UUID()
        let run = SharedRun<Value> {
            await behind?.settled()
            return await body(id)
        }
        return (Flight(id: id, run: run), run.firstTicket)
    }
}
