import Foundation
import Observation
import UserNotifications

/// The signed-in account's folder counts: the per-folder unread and total
/// badges the sidebar draws, the Inbox unread count behind the app icon
/// badge, the folders the server reports as subscribed, and the write-through
/// to the saved folder state an offline launch draws from.
///
/// Part of `MailSessionStore` (`counts`). Subscribed folders' counts are
/// refreshed proactively by `FolderListViewModel`; unsubscribed folders are
/// populated lazily on selection, and the unsubscribed-folder banner's Refresh
/// button writes the freshest values through `setFolderCounts` so the sidebar
/// badge and the message-list view advance together. Whether a count fetched
/// through a client may still be written is the store's question
/// (`MailSessionStore.acceptsCounts(from:)`), asked by every writer of a
/// fetched count.
@Observable
@MainActor
public final class MailCounts {
    /// Authoritative Inbox unread count, refreshed by `AppState`'s badge
    /// poller. Exposed as an observable so views (the macOS menu-bar extra)
    /// can mirror what shows on the dock/home-screen badge.
    public private(set) var inboxUnreadCount: Int = 0

    // Per-folder unread + total counts, keyed by folder path. Writable from
    // the module: the sidebar's seeding and its clearing of seeded counts
    // write them directly, deliberately skipping the app badge and the saved
    // counts (`FolderListViewModel`).
    var folderUnreadCounts: [String: Int] = [:]
    var folderTotalCounts: [String: Int] = [:]
    /// Keeps the counts above in step with the saved folder state, for
    /// offline launches (`SavedFolderCounts`).
    let savedFolderCounts = SavedFolderCounts()
    /// Paths of the folders the server's LSUB reports, published by
    /// `FolderListViewModel` on every folder-list load and subscription
    /// toggle. `nil` until the first list lands. Keyed by path, like the
    /// counts above, so a view holding a stand-in `Folder(path:)` (the
    /// resume-position toast, a push-notification tap, Spotlight, Siri —
    /// all of which construct one with `isSubscribed` defaulted to `false`)
    /// can still answer "is this folder subscribed?" truthfully.
    private(set) var subscribedFolderPaths: Set<String>?

    init() {}

    /// Replace the unread count for one folder. Called after an
    /// authoritative `STATUS (UNSEEN)` when the caller doesn't have the
    /// total in hand (e.g. an optimistic delta-based recovery path).
    func setUnreadCount(folderPath: String, count: Int) {
        folderUnreadCounts[folderPath] = max(0, count)
        savedFolderCounts.countChanged(folderPath, unread: max(0, count), total: folderTotalCounts[folderPath])
    }

    /// Replace the unread + total counts for one folder in one shot.
    /// Preferred over `setUnreadCount` whenever a full STATUS reply is
    /// in hand, so the two maps don't drift.
    func setFolderCounts(folderPath: String, unread: Int, total: Int) {
        folderUnreadCounts[folderPath] = max(0, unread)
        folderTotalCounts[folderPath] = max(0, total)
        savedFolderCounts.countChanged(folderPath, unread: max(0, unread), total: max(0, total))
        if Self.isInbox(folderPath) { setInboxUnread(unread) }
    }

    /// Replace the whole unread map. Used by the folder list view model
    /// after a full STATUS walk so any folders that have disappeared
    /// drop out.
    func setUnreadCounts(_ counts: [String: Int]) {
        folderUnreadCounts = counts.mapValues { max(0, $0) }
        if let inbox = counts.first(where: { Self.isInbox($0.key) })?.value {
            setInboxUnread(inbox)
        }
    }

    /// Bump (or reduce) the count for one folder. Clamped at zero so a
    /// stale +1 from a doubled signal can't make the badge negative.
    func applyUnreadDelta(folderPath: String, delta: Int) {
        savedFolderCounts.unreadAdjusted(folderPath, from: folderUnreadCounts[folderPath], by: delta)
        let current = folderUnreadCounts[folderPath] ?? 0
        folderUnreadCounts[folderPath] = max(0, current + delta)
        // Keep the icon badge live. It reads `inboxUnreadCount`, which the
        // 60s poller refreshes from server STATUS — but that poll can't run
        // while the app is backgrounded, so an archive done just before
        // backgrounding used to leave the badge showing the pre-archive
        // count. Applying the same delta here updates the badge the instant
        // the action lands; the poller stays the authority that reconciles
        // any drift on the next foreground.
        if Self.isInbox(folderPath) { setInboxUnread(inboxUnreadCount + delta) }
    }

    /// Canonical INBOX match — IMAP's INBOX name is case-insensitive
    /// (RFC 3501), and folder paths reach these mutators verbatim from the
    /// server, so compare case-insensitively rather than against a literal.
    static func isInbox(_ folderPath: String) -> Bool {
        folderPath.caseInsensitiveCompare("INBOX") == .orderedSame
    }

    /// Single chokepoint for the Inbox unread count and the system icon
    /// badge. Every writer — the STATUS poller, optimistic archive/mark-read
    /// deltas, and full STATUS walks — routes through here so the two never
    /// diverge. The badge task re-reads `inboxUnreadCount` at execution time
    /// rather than capturing `count`, so a burst of deltas can't land the
    /// badge on a stale intermediate value if the tasks run out of order.
    public func setInboxUnread(_ count: Int) {
        inboxUnreadCount = max(0, count)
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(inboxUnreadCount)
        }
    }

    /// Replace the whole subscribed set from a fresh folder list.
    func setSubscribedFolders(_ paths: Set<String>) {
        subscribedFolderPaths = paths
    }

    /// Record one folder's subscription flip (optimistic toggle or its
    /// revert). A flip before any list has landed seeds the set, so the
    /// banner can answer for that folder at least.
    func setSubscription(folderPath: String, isSubscribed: Bool) {
        var paths = subscribedFolderPaths ?? []
        if isSubscribed {
            paths.insert(folderPath)
        } else {
            paths.remove(folderPath)
        }
        subscribedFolderPaths = paths
    }

    /// Sign-out's share of `MailSessionStore.forgetAccount()`: the next
    /// account starts from none of these. The totals matter beyond the
    /// sidebar: `setUnreadCount` saves the folder's total from here into the
    /// session's saved folder state. `inboxUnreadCount` is not reset here:
    /// the badge poller's stop zeroes it, and the system badge with it, first.
    func reset() {
        folderUnreadCounts = [:]
        folderTotalCounts = [:]
        subscribedFolderPaths = nil
        savedFolderCounts.reset()
    }
}
