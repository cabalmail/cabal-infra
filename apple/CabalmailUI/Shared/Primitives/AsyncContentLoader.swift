import Observation

/// The three states `AsyncContentView` shows for a screen that loads one value
/// in its `.task`, and the rule for a load that never finished (#1908).
///
/// A load whose own task was cancelled before it failed has no outcome: SwiftUI
/// tore the `.task` down (a sheet dismissed, a pushed destination rebuilt with
/// its `@State` kept, #1328). It writes nothing and the spinner stays. Every
/// screen using this runs `load` from a `.task` with no gate, so the next
/// appearance starts over, and a cancelled load that lands after that one
/// began can't paint over its list. The cancel is read off the task, never the
/// error: the error's shape has varied, and an error-shaped test would also
/// swallow a live task's failure and leave this spinner up for good. Giving a
/// user's `.task` an `id:` or a "loaded once" gate would need an attempt flag
/// like `RulesViewModel`'s, or a view shown again could spin forever.
@MainActor
@Observable
final class AsyncContentLoader<Value> {
    private(set) var value: Value?
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    /// Runs `operation`. A value it returns is shown even when the task was
    /// cancelled after it arrived; an error is shown only when the task is live.
    func load(
        _ operation: @MainActor () async throws -> Value,
        failure: (any Error) -> String
    ) async {
        isLoading = true
        errorMessage = nil
        do {
            value = try await operation()
            // An answer outranks an error an overlapping live load left.
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = failure(error)
        }
        isLoading = false
    }

    /// Shows `message` without loading (a picker with no session).
    func fail(_ message: String) {
        errorMessage = message
        isLoading = false
    }
}
