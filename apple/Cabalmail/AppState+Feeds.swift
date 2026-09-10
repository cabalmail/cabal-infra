import Foundation
import CabalmailKit

// Feed reader (RSS plan, phase 5) session flows: the periodic refresh that
// keeps the Feeds section current while the app is open, and the foreground
// refresh the scene-phase handlers call. Lives beside the inbox badge poller
// it mirrors; split out so `AppState.swift` stays within its budget.
extension AppState {
    /// Every fifteen minutes while signed in: pull the catalog and each
    /// subscription's new items, drain the pending mutation queue, then tell
    /// the open feed views to re-read the store. The first pass runs at once,
    /// so the Feeds section is current before the user opens it. Idempotent:
    /// a second call while the task is running is a no-op. The server's
    /// fetcher decides how often a feed is actually fetched; this only
    /// decides how often the client asks what is new. iOS background fetch
    /// waits for the push phase (RSS plan, phase 8).
    func startFeedRefreshPolling() {
        guard feedRefreshTask == nil, client != nil else { return }
        let interval = feedRefreshInterval
        feedRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFeeds()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Tear down the feed poller. Called on sign-out; safe if it never ran.
    func stopFeedRefreshPolling() {
        feedRefreshTask?.cancel()
        feedRefreshTask = nil
    }

    /// Foreground refresh for the feed reader: new items and the pending
    /// mutation queue. Called from the scene-phase handlers alongside the
    /// preferences reconcile; a no-op when signed out.
    func refreshFeedsOnForeground() async {
        await refreshFeeds()
    }

    private func refreshFeeds() async {
        guard let engine = client?.rssSync else { return }
        _ = await engine.syncAll()
        // The store changed under the open views: badges re-read their
        // counts and a list still on its first page reloads.
        FeedStateBus.shared.post()
    }
}
