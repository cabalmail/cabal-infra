import Foundation
import Observation
import CabalmailKit

/// One main window's parked restores: the message its folder list selects
/// once it has appeared and loaded, the row that list opens scrolled to,
/// the reading position the reader opens that message at, and the feed item
/// its feed list selects.
///
/// Each window's `SceneNavigator` owns one, and the views read it through
/// the navigator in the environment. Before, the three slots were one per
/// install on `NavStateCoordinator`, and every mounted list and reader
/// consumed them, so with two windows on one folder a Resume, a notification
/// or a layout swap's re-park could open in the other window (#1987).
///
/// Each slot is pop-once: the view it is aimed at takes it, and nothing else
/// sees it after. A message restore matches its folder exactly; the reader's
/// position matches its message too. While the window records
/// (`WindowRecorder`), the coordinator also primes the working cursor from
/// the same cursor (`schedule(_:priming:)`), so the cursor's UIDVALIDITY and
/// reading fraction stay with the message they came with (#1873).
@Observable
@MainActor
final class WindowRestores {
    /// A restore target handed to the `MessageListView` for a folder: it finds
    /// the matching envelope after its initial load and selects it. Carried as
    /// a value (not applied here) because only the list owns the loaded
    /// envelopes and the wide/compact selection machinery.
    struct PendingRestore: Equatable, Sendable {
        let folderPath: String
        let messageID: String?
        let uid: UInt32?
        let listScroll: Int?
        /// Monotonic so an already-mounted list re-applies even when the same
        /// folder/message recurs (e.g. a same-folder cross-device jump).
        let tick: Int
    }

    /// An in-message scroll position to reapply once the reader opens the
    /// restored message. Keyed by folder + message so it only lands on the
    /// intended message. `offset` restores a plain-text body; `anchor`
    /// restores an HTML body — a message renders as one or the other, so the
    /// reader applies whichever matches.
    struct PendingScrollRestore: Equatable, Sendable {
        let folderPath: String
        let messageID: String?
        let uid: UInt32?
        let offset: Int?
        let anchor: String?
    }

    /// A feed item to select once its scope's list is on screen and loaded:
    /// the feed reader's launch restore, a tapped feed banner, or a layout
    /// swap's hand-off.
    struct PendingFeedRestore: Equatable, Sendable {
        let scope: RssItemScope
        let item: RssItem
    }

    /// Set when a folder's message should be restored or jumped to; consumed
    /// by the matching `MessageListView`.
    private(set) var pendingRestore: PendingRestore?

    /// Set alongside `pendingRestore` when the restored cursor carried a scroll
    /// position; consumed by the reader after the message loads.
    private(set) var pendingScrollRestore: PendingScrollRestore?

    /// Consumed by the scope's `FeedItemListView` through
    /// `consumeFeedItemRestore(for:)`.
    var pendingFeedRestore: PendingFeedRestore?

    /// The row the folder's next list opens scrolled to (`ListAnchor`): where
    /// the window's list was when a layout swap replaced it, or when the app
    /// last went away. Taken once, by
    /// the list for exactly its folder (`FolderListHold.takeAnchor`); a
    /// folder change, a back-out or a navigation drops it. Nothing observes
    /// it: the list asks when it lands.
    @ObservationIgnored private(set) var pendingListAnchor: ListAnchor?

    /// Counts every park, so a mounted list sees a new restore even for the
    /// same message.
    private var restoreTick = 0

    // MARK: Mail

    /// Parks a restore of `cursor` for its folder's list, and primes
    /// `coordinator`'s working cursor from it, as one step: a landing, a
    /// navigation, or a layout swap re-parking the open message. A window
    /// that does not record passes no coordinator (`WindowRecorder`), so it
    /// parks without moving the cursor another window keeps.
    func schedule(_ cursor: NavState, priming coordinator: NavStateCoordinator?) {
        coordinator?.primeCursor(for: cursor)
        park(cursor)
    }

    /// Parks a restore of `cursor`: the message for its folder's list, and
    /// its reading position for the reader when it carried one.
    func park(_ cursor: NavState) {
        restoreTick += 1
        pendingRestore = PendingRestore(
            folderPath: cursor.folder,
            messageID: cursor.messageID,
            uid: cursor.uid,
            listScroll: cursor.listScroll,
            tick: restoreTick
        )
        // Only park a scroll restore when the cursor actually carried one, so
        // the reader doesn't force a message that was saved at the top back to
        // the top redundantly.
        if cursor.messageScroll != nil || cursor.messageAnchor != nil {
            pendingScrollRestore = PendingScrollRestore(
                folderPath: cursor.folder,
                messageID: cursor.messageID,
                uid: cursor.uid,
                offset: cursor.messageScroll,
                anchor: cursor.messageAnchor
            )
        } else {
            pendingScrollRestore = nil
        }
    }

    /// Drops a parked message restore whose folder turned out not to exist
    /// (the launch landing fell back to INBOX).
    func clearPendingRestore() {
        pendingRestore = nil
        pendingScrollRestore = nil
    }

    /// Whether a restore for `folderPath` is waiting for its list.
    func hasPendingRestore(in folderPath: String) -> Bool {
        pendingRestore?.folderPath == folderPath
    }

    /// Returns and clears the parked restore if it targets `folderPath`. The
    /// list calls this after its initial load.
    func consumePendingRestore(for folderPath: String) -> PendingRestore? {
        guard let restore = pendingRestore, restore.folderPath == folderPath else { return nil }
        pendingRestore = nil
        return restore
    }

    /// Returns and clears the parked scroll restore if it targets the message
    /// the reader just opened — matched by folder plus Message-ID (durable
    /// across a move) or UID. The reader calls this once the body has loaded
    /// and applies `offset` (plain text) or `anchor` (HTML).
    func consumeScrollRestore(folderPath: String, uid: UInt32?, messageID: String?) -> PendingScrollRestore? {
        guard let restore = pendingScrollRestore, restore.folderPath == folderPath else { return nil }
        let messageMatches: Bool
        if let wanted = restore.messageID, let have = messageID {
            messageMatches = wanted == have
        } else if let wanted = restore.uid, let have = uid {
            messageMatches = wanted == have
        } else {
            messageMatches = false
        }
        guard messageMatches else { return nil }
        pendingScrollRestore = nil
        return restore
    }

    /// The parked scroll restore, if it targets the message `ref` names.
    func consumeScrollRestore(for ref: MessageRef) -> PendingScrollRestore? {
        consumeScrollRestore(folderPath: ref.folder, uid: ref.uid, messageID: ref.messageId)
    }

    // MARK: The list's place

    func parkListAnchor(_ anchor: ListAnchor) {
        pendingListAnchor = anchor
    }

    /// Parks a mail landing's message and list place for its folder's list.
    /// Before the window moves to the folder: the move keeps what is parked
    /// for the folder it lands on, and drops what is parked for another.
    func park(_ target: NavStateCoordinator.MailLaunchTarget, priming coordinator: NavStateCoordinator?) {
        if let restore = target.messageRestore { schedule(restore, priming: coordinator) }
        if let anchor = target.listAnchor { parkListAnchor(anchor) }
    }

    /// Drops the parked anchor, unless it is for `folderPath`: the folder a
    /// landing is moving to keeps the anchor parked for it.
    func dropListAnchor(keeping folderPath: String? = nil) {
        if let folderPath, pendingListAnchor?.folderPath == folderPath { return }
        pendingListAnchor = nil
    }

    /// Returns and clears the parked anchor if it is for `folderPath`.
    func consumeListAnchor(for folderPath: String) -> ListAnchor? {
        guard let anchor = pendingListAnchor, anchor.folderPath == folderPath else { return nil }
        pendingListAnchor = nil
        return anchor
    }

    // MARK: Feeds

    /// Parks `item` for `scope`'s list to select once it is on screen and
    /// loaded.
    func parkFeedItem(_ item: RssItem, in scope: RssItemScope) {
        pendingFeedRestore = PendingFeedRestore(scope: scope, item: item)
    }

    /// Parks a feed landing's item, when it has one, for its scope's list,
    /// and returns the scope for the window to open.
    func park(_ target: NavStateCoordinator.FeedLaunchTarget) -> RssItemScope {
        if let item = target.item { parkFeedItem(item, in: target.scope) }
        return target.scope
    }

    /// Returns and clears the parked feed item if it belongs to `scope`.
    /// Called by the scope's `FeedItemListView` once it is on screen and
    /// loaded, so the reader never arrives in the same update as its list
    /// (#1664).
    func consumeFeedItemRestore(for scope: RssItemScope) -> RssItem? {
        guard let restore = pendingFeedRestore, restore.scope == scope else { return nil }
        pendingFeedRestore = nil
        return restore.item
    }
}

extension WindowRestores.PendingRestore {
    /// The message to restore, when the cursor named one by UID: what the
    /// list falls back to after the Message-ID.
    var ref: MessageRef? {
        uid.map { MessageRef(folder: folderPath, uid: $0, messageId: messageID) }
    }
}
