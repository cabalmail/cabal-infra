import Foundation

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
/// concurrency makes nonisolated.
@MainActor
final class ComposeAutosaveLoops {
    /// Interval between local autosave flushes. Matches the plan.
    static let autosaveInterval: TimeInterval = 5

    /// Interval between server-side draft pushes while composing. Long on
    /// purpose — the 5 s local autosave is the crash-recovery story, and
    /// each server save costs a Lambda invocation plus EFS churn. Close-
    /// without-send always pushes, so this only bounds how stale another
    /// device's view of an *open* compose window can be.
    static let serverAutosaveInterval: TimeInterval = 60

    private var local: Task<Void, Never>?
    private var server: Task<Void, Never>?

    var isRunning: Bool { local != nil || server != nil }

    /// Starts both loops for `model`, replacing any already running. Each
    /// saves after its first interval, not at once, and holds the model
    /// weakly, so a composer that goes without `stop()` is not kept alive.
    func start(for model: ComposeViewModel) {
        stop()
        local = Self.loop(every: Self.autosaveInterval) { [weak model] in
            await model?.persistCurrentDraft()
        }
        server = Self.loop(every: Self.serverAutosaveInterval) { [weak model] in
            await model?.autosaveToServer()
        }
    }

    func stop() {
        local?.cancel()
        local = nil
        server?.cancel()
        server = nil
    }

    private static func loop(
        every interval: TimeInterval,
        _ save: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await save()
            }
        }
    }
}
