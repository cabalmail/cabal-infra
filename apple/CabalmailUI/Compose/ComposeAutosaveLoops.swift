import Foundation

/// What the autosave loops save: a composer (`ComposeViewModel`), or a
/// test's stand-in for one.
@MainActor
protocol ComposeAutosaveTarget: AnyObject {
    /// Writes the local copy (`DraftStore`).
    func persistCurrentDraft() async
    /// Pushes the server copy (`/save_draft`) when there is one worth
    /// pushing.
    func autosaveToServer() async
}

extension ComposeViewModel: ComposeAutosaveTarget {}

/// How the autosave loops keep time. A test swaps the sleep for one it
/// steps (`ComposeAutosaveLoops.timing`), so it never waits out an interval.
struct ComposeAutosaveTiming {
    /// Between local autosave flushes. Matches the plan.
    var localInterval: TimeInterval = 5

    /// Between server-side draft pushes while composing. Long on purpose:
    /// the 5 s local autosave is the crash-recovery story, and each server
    /// save costs a Lambda invocation plus EFS churn. Close-without-send
    /// always pushes, so this only bounds how stale another device's view
    /// of an *open* compose window can be.
    var serverInterval: TimeInterval = 60

    var sleep: @Sendable (TimeInterval) async -> Void = { interval in
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

/// A composer's two autosave loops: its local copy (`DraftStore`) and its
/// server copy (`/save_draft`).
///
/// Started when the composer opens, stopped when it closes, and paused while
/// "Open in New Window" hands the draft over (`ComposeWindowMove`): a tick
/// landing mid-move would write a copy the window is about to take over.
/// A refused move starts them again, and nothing else of the composer's
/// start runs twice.
///
/// Stopped from the view's `onDisappear` and every flow that closes the
/// composer rather than from the model's `deinit`, which Swift's strict
/// concurrency makes nonisolated. A composer that goes away without that
/// stop ends them all the same: each loop looks for it again every time it
/// wakes, and returns once it is gone.
@MainActor
final class ComposeAutosaveLoops {
    /// The intervals and the sleep both loops are made with. A test sets it
    /// before `start(for:)`.
    var timing = ComposeAutosaveTiming()

    private var local: Task<Void, Never>?
    private var server: Task<Void, Never>?
    /// The composer being saved while the loops run. Weak, so the loops
    /// never keep alive a composer that nothing else holds.
    private weak var target: (any ComposeAutosaveTarget)?

    var isRunning: Bool { local != nil || server != nil }

    /// Starts both loops for `model`, replacing any already running. Each
    /// saves after its first interval, not at once.
    func start(for model: any ComposeAutosaveTarget) {
        stop()
        target = model
        local = loop(every: timing.localInterval) { await $0.persistCurrentDraft() }
        server = loop(every: timing.serverInterval) { await $0.autosaveToServer() }
    }

    func stop() {
        local?.cancel()
        local = nil
        server?.cancel()
        server = nil
        target = nil
    }

    /// Writes the local copy now instead of at the next tick, for a composer
    /// whose scene is going to the background: the app can be suspended, and
    /// then ended, before the tick comes. It is that tick come early and no
    /// more: nothing is written while the loops are stopped, so a draft that
    /// was sent, discarded or handed to a window is not written back, and
    /// the server copy keeps to its own interval.
    @discardableResult
    func flush() -> Task<Void, Never>? {
        guard isRunning else { return nil }
        return Task { @MainActor [weak self] in
            // Looked up when the save starts, as a tick reads its
            // cancellation: a `stop()` that came first has let go of the
            // composer, and wins.
            guard let target = self?.target else { return }
            await target.persistCurrentDraft()
        }
    }

    private func loop(
        every interval: TimeInterval,
        _ save: @escaping @MainActor (any ComposeAutosaveTarget) async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self, timing] in
            while !Task.isCancelled {
                await timing.sleep(interval)
                if Task.isCancelled { return }
                // Looked up on each wake and never held across the sleep,
                // which would keep the composer alive for as long as the
                // loop ran. With the composer gone there is nothing left to
                // save, so the loops end here rather than wake for ever.
                guard let target = self?.target else {
                    self?.stop()
                    return
                }
                await save(target)
            }
        }
    }
}
