import Foundation

/// Runs the cache root's launch step once per process, before the first
/// client is built (`SessionEnvironment.prepareAccountStorage`).
///
/// A process has no one place where it launches: a window's restore, a
/// sign-in, and a notification action or App Intent on a background launch
/// (`SessionManager.borrowClient()`) can each be the first to build a
/// client, and two of them can ask at once. Whoever asks first runs the
/// step; whoever asks while it runs waits for it; after that it is free. A
/// step that never suspends leaves its caller's turn unbroken.
@MainActor
final class LaunchStorageStep {
    private var isDone = false
    /// Non-nil while the step runs: who is waiting for it.
    private var waiters: [CheckedContinuation<Void, Never>]?

    func run(_ step: @MainActor () async -> Void) async {
        guard !isDone else { return }
        if waiters != nil {
            await withCheckedContinuation { waiters?.append($0) }
            return
        }
        waiters = []
        await step()
        isDone = true
        let waiting = waiters ?? []
        waiters = nil
        for waiter in waiting {
            waiter.resume()
        }
    }
}
