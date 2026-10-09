import Foundation
import Observation
import UserNotifications
import CabalmailKit

/// The signed-in account's folder counts: the per-folder unread and total
/// counts the sidebar badges draw, which are also a message list's Unread
/// pill (and its flagged counts, its Flagged pill), the Inbox unread count
/// behind the app icon badge, the folders the server reports as subscribed,
/// and the write-through to the saved folder state an offline launch draws
/// from.
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

    // Per-folder unread + total counts, keyed by folder path. Written through
    // the setters, `seed`, `clearSeeded` and `show`; left writable from the
    // module for tests that set up a count directly.
    var folderUnreadCounts: [String: Int] = [:]
    var folderTotalCounts: [String: Int] = [:]
    /// When each folder's counts above were last set by a STATUS, or a
    /// change with a known result (Mark All as Read, Empty Trash), this
    /// session, having moved since only by deltas: what a fetched STATUS may
    /// be bounded against while it is fresh (`isCounted(_:askedAt:)`). A count
    /// seeded from saved state, or guessed by a delta on a folder with none,
    /// isn't.
    private var countedAt: [String: ContinuousClock.Instant] = [:]
    /// How long a count set by a STATUS stays a base to bound a later STATUS
    /// against: past it, the folder may have changed elsewhere (another
    /// device), which no write recorded here accounts for, so a STATUS is
    /// taken as it comes. Two of a message list's refresh cycles.
    static let countFreshness: Duration = .seconds(120)
    /// The same for `inboxUnreadCount`: whether a STATUS has set it this
    /// session (`MailSessionStore.polledInboxUnread`, or INBOX's counts).
    var inboxUnreadIsCounted = false
    /// Per-folder flagged counts: what a message list's Flagged pill shows.
    /// Set by a STATUS that asked for them (a list's), or seeded from saved
    /// state; moved by the mutation service with every flag change and
    /// removal. The sidebar doesn't draw them, and local changes to them
    /// aren't saved.
    private(set) var folderFlaggedCounts: [String: Int] = [:]
    /// When each folder's flagged count was last set by a STATUS, or by
    /// Empty Trash, this session: as `countedAt`, for flagged counts.
    private var flaggedCountedAt: [String: ContinuousClock.Instant] = [:]
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
        countedAt[folderPath] = .now
        savedFolderCounts.countChanged(folderPath, unread: max(0, count), total: folderTotalCounts[folderPath])
    }

    /// Replace the unread + total counts for one folder in one shot.
    /// Preferred over `setUnreadCount` whenever a full STATUS reply is
    /// in hand, so the two maps don't drift.
    func setFolderCounts(folderPath: String, unread: Int, total: Int) {
        folderUnreadCounts[folderPath] = max(0, unread)
        folderTotalCounts[folderPath] = max(0, total)
        countedAt[folderPath] = .now
        savedFolderCounts.countChanged(folderPath, unread: max(0, unread), total: max(0, total))
        if Self.isInbox(folderPath) {
            setInboxUnread(unread)
            inboxUnreadIsCounted = true
        }
    }

    /// Whether `folderPath`'s unread and total counts are a base a STATUS
    /// asked at `askedAt` may be bounded against: set by a STATUS (or a
    /// change with a known result) this session, recently enough
    /// (`countFreshness`).
    func isCounted(_ folderPath: String, askedAt: ContinuousClock.Instant) -> Bool {
        guard let counted = countedAt[folderPath] else { return false }
        return askedAt - counted < Self.countFreshness
    }

    /// The same for `folderPath`'s flagged count.
    func isFlaggedCounted(_ folderPath: String, askedAt: ContinuousClock.Instant) -> Bool {
        guard let counted = flaggedCountedAt[folderPath] else { return false }
        return askedAt - counted < Self.countFreshness
    }

    /// Replace one folder's flagged count, from a STATUS that asked for it
    /// or a change with a known result (Empty Trash).
    func setFlaggedCount(folderPath: String, count: Int) {
        folderFlaggedCounts[folderPath] = max(0, count)
        flaggedCountedAt[folderPath] = .now
    }

    /// Bump (or reduce) one folder's flagged count, clamped at zero. A
    /// folder with no count is left without one (the mutation service moves
    /// only folders that have one).
    func applyFlaggedDelta(folderPath: String, delta: Int) {
        guard let current = folderFlaggedCounts[folderPath] else { return }
        folderFlaggedCounts[folderPath] = max(0, current + delta)
    }

    /// Shows counts for a folder without saving them or putting them on the
    /// app badge. `counted` vouches for them as a base to bound later STATUS
    /// replies against, as a message list's reply that may predate a removal
    /// it already applied does (the counts can only have gone down, and are
    /// bounded); a test setting a list's pills directly vouches for nothing.
    func show(unread: Int? = nil, flagged: Int? = nil, folderPath: String, counted: Bool = false) {
        if let unread {
            folderUnreadCounts[folderPath] = max(0, unread)
            if counted { countedAt[folderPath] = .now }
        }
        if let flagged {
            folderFlaggedCounts[folderPath] = max(0, flagged)
            if counted { flaggedCountedAt[folderPath] = .now }
        }
    }

    /// Starts a folder's counts from saved state (an earlier STATUS, and the
    /// changes made here since), where the session has none of its own yet:
    /// the unread and total counts only when the saved state has both and
    /// there is no unread count, the flagged count only when there is none.
    /// Nothing is marked counted, saved, or put on the app badge, which shows
    /// what this device last set and can be newer. Returns whether the
    /// unread and total counts were seeded.
    @discardableResult
    func seed(folderPath: String, from saved: FolderStatus) -> Bool {
        if folderFlaggedCounts[folderPath] == nil, let flagged = saved.flagged {
            folderFlaggedCounts[folderPath] = max(0, flagged)
        }
        guard folderUnreadCounts[folderPath] == nil, let unread = saved.unseen, let total = saved.messages else {
            return false
        }
        folderUnreadCounts[folderPath] = max(0, unread)
        folderTotalCounts[folderPath] = max(0, total)
        return true
    }

    /// Drops the counts the folder list seeded from a saved copy
    /// (`SavedFolderCounts.takeSeeded()`), once a live list has arrived: a
    /// recount cut short then leaves those badges blank, as online.
    func clearSeeded() {
        for path in savedFolderCounts.takeSeeded() {
            folderUnreadCounts[path] = nil
            folderTotalCounts[path] = nil
            if flaggedCountedAt[path] == nil { folderFlaggedCounts[path] = nil }
        }
    }

    /// Replace the whole unread map. Used by the folder list view model
    /// after a full STATUS walk so any folders that have disappeared
    /// drop out.
    func setUnreadCounts(_ counts: [String: Int]) {
        folderUnreadCounts = counts.mapValues { max(0, $0) }
        for path in counts.keys { countedAt[path] = .now }
        if let inbox = counts.first(where: { Self.isInbox($0.key) })?.value {
            setInboxUnread(inbox)
            inboxUnreadIsCounted = true
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
    /// Internal: a count fetched outside this module goes through
    /// `MailSessionStore.setInboxUnread(_:fetchedThrough:)`, which asks the
    /// count gate first.
    func setInboxUnread(_ count: Int) {
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
        countedAt = [:]
        inboxUnreadIsCounted = false
        folderFlaggedCounts = [:]
        flaggedCountedAt = [:]
        subscribedFolderPaths = nil
        savedFolderCounts.reset()
    }
}
