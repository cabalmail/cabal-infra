import Foundation
import CabalmailKit

/// The two loops a signed-in session runs: the Inbox badge poller and the
/// feed reader's periodic refresh. `SessionManager` starts both as it wires a
/// session and stops both first when it ends one. Each tick reads the
/// session's current client through `client`, so a tick that starts after the
/// client is gone finds none and does nothing; a badge tick already waiting
/// on the server when its loop is stopped drops its count.
@MainActor
final class SessionPollers {
    /// The session's client, read on every tick.
    var client: @MainActor () -> CabalmailClient? = { nil }
    /// Where the badge poller's Inbox count goes: `AppState`'s mail store,
    /// whose counts push it to the system badge.
    var inboxUnreadChanged: @MainActor (Int) -> Void = { _ in }

    /// The badge poller's loop; readable so a test can await its last tick.
    private(set) var inboxBadgeTask: Task<Void, Never>?
    private let inboxBadgePollInterval: UInt64 = 60 * 1_000_000_000
    var feedRefreshTask: Task<Void, Never>?
    let feedRefreshInterval: UInt64 = 15 * 60 * 1_000_000_000

    /// Begin the Inbox-badge polling loop. Runs while signed in and polls
    /// `STATUS (UNSEEN)` on INBOX every 60 seconds, pushing the count to the
    /// system badge via `UNUserNotificationCenter`. Requests `.badge`
    /// authorization on first start — the system ignores repeat requests
    /// once the user has responded, so calling this on every sign-in is safe.
    /// Idempotent: subsequent calls while the task is running are no-ops.
    func startInboxBadgePolling(requestAuthorization: @MainActor () -> Void) {
        guard inboxBadgeTask == nil, client() != nil else { return }
        requestAuthorization()
        let interval = inboxBadgePollInterval
        inboxBadgeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshInboxUnread()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Tear down the badge poller and clear the system badge. Called on
    /// sign-out so the icon doesn't keep showing the last signed-in user's
    /// count. Idempotent — safe to call even if polling never started.
    func stopInboxBadgePolling() {
        inboxBadgeTask?.cancel()
        inboxBadgeTask = nil
        inboxUnreadChanged(0)
    }

    private func refreshInboxUnread() async {
        guard let client = client() else { return }
        do {
            let status = try await client.folderStatus(path: "INBOX")
            // A STATUS already answered when the sign-out stopped this loop
            // still resumes here, after the stop reset the badge to 0. Its
            // count is the ended session's, so it goes nowhere (#1886).
            guard !Task.isCancelled else { return }
            inboxUnreadChanged(status.unseen ?? 0)
        } catch {
            // Best-effort: if the STATUS call fails (transient network
            // blip, IMAP reconnection) the prior badge value stays put
            // until the next poll succeeds.
        }
    }

    /// Every fifteen minutes while signed in: pull the catalog and each
    /// subscription's new items, drain the pending mutation queue, then tell
    /// the open feed views to re-read the store. The first pass runs at once,
    /// so the Feeds section is current before the user opens it. Idempotent:
    /// a second call while the task is running is a no-op. The server's
    /// fetcher decides how often a feed is actually fetched; this only
    /// decides how often the client asks what is new. iOS background fetch
    /// waits for the push phase (RSS plan, phase 8).
    func startFeedRefreshPolling() {
        guard feedRefreshTask == nil, client() != nil else { return }
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

    /// One feed pass: new items and the pending mutation queue. The poller's
    /// tick, and the foreground refresh the scene-phase handlers call; a
    /// no-op when signed out.
    func refreshFeeds() async {
        guard let engine = client()?.rssSync else { return }
        _ = await engine.syncAll()
        // A subscription removed on another device takes its site data along.
        await FeedWebStorage.dropDeparted(from: engine.store)
        // The store changed under the open views: badges re-read their
        // counts and a list still on its first page reloads.
        FeedStateBus.shared.post()
    }
}
