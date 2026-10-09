import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Thrown by `awaitArrival` when the call waited for never reached the fake.
struct PollCallNeverArrived: Error {}

/// `waitUntil`, then ends the test if `condition` never held, so a wait on
/// the fake that follows (`awaitHeld`, which has no ceiling) fails rather
/// than hangs, as the watcher suites' `ListWatcherHarness.arrive` does.
func awaitArrival(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    try await waitUntil(file: file, line: line, condition)
    guard await condition() else { throw PollCallNeverArrived() }
}

/// The folder pollers' clock, stepped by the test: `now` reads an instant
/// that moves only with `advance(by:)`, and a tick's sleep parks until
/// `fireTicks()` wakes it, or until its task is cancelled, so a stopped
/// poller's tick never leaks. Every interval slept is recorded.
@MainActor
final class ManualPollClock {
    private struct Sleeper {
        let id: Int
        let wake: CheckedContinuation<Void, Never>
    }

    private(set) var instant = ContinuousClock.now
    private(set) var sleeps: [Duration] = []
    private var sleepers: [Sleeper] = []
    private var lastSleeper = 0

    /// Ticks asleep now.
    var sleeping: Int { sleepers.count }

    /// Paces the pollers `pollers` makes from now on.
    func install(on pollers: FolderPollers) {
        pollers.timing.now = { self.instant }
        pollers.timing.sleep = { duration in await self.sleep(for: duration) }
    }

    func advance(by duration: Duration) {
        instant += duration
    }

    /// Wakes every tick asleep.
    func fireTicks() {
        let waking = sleepers
        sleepers = []
        for sleeper in waking { sleeper.wake.resume() }
    }

    /// Returns once `count` ticks are asleep.
    func awaitSleepers(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntilOnMainActor(file: file, line: line) { self.sleeping >= count }
    }

    private func sleep(for duration: Duration) async {
        sleeps.append(duration)
        lastSleeper += 1
        let id = lastSleeper
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleepers.append(Sleeper(id: id, wake: $0)) }
        } onCancel: {
            // Strong: the clock must outlive the wake, or the sleeper leaks.
            Task { @MainActor in self.wake(id) }
        }
    }

    private func wake(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).wake.resume()
    }
}

/// A list as a folder's poller sees it: every ticket it took, every STATUS
/// or failure handed to it, and every ticket given back. Its asks are
/// numbered on from `firstAsk`, as a list's own refresh flight numbers
/// them. `holdsNextRefresh` parks the next hand-off's refresh until
/// `releaseRefresh()`, and records whether its task was cancelled meanwhile.
@MainActor
final class RecordingPollSubscriber: FolderPollSubscriber {
    private(set) var tickets: [FolderPollTicket] = []
    private(set) var handed: [PrefetchedStatus] = []
    private(set) var startedOver: [Bool] = []
    private(set) var failures: [String] = []
    private(set) var released: [FolderPollTicket] = []
    private(set) var refreshWasCancelled = false
    var holdsNextRefresh = false
    private var nextAsk: Int
    private var heldRefresh: CheckedContinuation<Void, Never>?

    init(firstAsk: Int = 1) {
        nextAsk = firstAsk
    }

    /// A hand-off's refresh is parked at `holdsNextRefresh`.
    var isHoldingRefresh: Bool { heldRefresh != nil }

    func beginFolderPoll() -> FolderPollTicket? {
        let ticket = FolderPollTicket(ask: nextAsk, holdsLoading: true)
        nextAsk += 1
        tickets.append(ticket)
        return ticket
    }

    func refresh(prefetched: PrefetchedStatus?, startingOver: Bool) async {
        if let prefetched { handed.append(prefetched) }
        startedOver.append(startingOver)
        guard holdsNextRefresh else { return }
        holdsNextRefresh = false
        await withCheckedContinuation { heldRefresh = $0 }
        refreshWasCancelled = Task.isCancelled
    }

    func releaseRefresh() {
        heldRefresh?.resume()
        heldRefresh = nil
    }

    func folderPollFailed(_ error: Error, ticket: FolderPollTicket) async {
        failures.append(error.localizedDescription)
    }

    func releaseFolderPoll(_ ticket: FolderPollTicket) {
        released.append(ticket)
    }
}
