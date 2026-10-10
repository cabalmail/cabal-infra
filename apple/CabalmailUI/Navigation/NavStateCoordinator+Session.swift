import Foundation
import CabalmailKit

// The local resume layer of `NavStateCoordinator`: the per-install session
// record (section, scope, open item), the per-item reading-position cache,
// and the launch-restore entry points the views call. Nothing here touches
// the network. See `docs/1.x/resume-session-plan.md`.
extension NavStateCoordinator {
    /// Where the mail UI should land at launch: the session's folder (INBOX
    /// when there is none) and, if a message was open, a cursor for the
    /// window to park so its list selects it after its initial load. The
    /// folder is provisional — `MailRootView` swaps the fetched `Folder` in
    /// when the list arrives and falls back to INBOX if it no longer exists.
    /// `listAnchor` is where the folder's list was scrolled when the app
    /// last went away, for the window to park beside the message.
    struct MailLaunchTarget: Equatable {
        let folderPath: String
        let messageRestore: NavState?
        var listAnchor: ListAnchor?
    }

    /// Where the feed reader should land: a scope, and the item that was open
    /// in it, for the window to park until the scope's list has appeared and
    /// loaded (#1664). Also what a tapped feed banner opens.
    struct FeedLaunchTarget: Equatable {
        let scope: RssItemScope
        var item: RssItem?
    }

    /// The record a landing restores from when its window has no stored
    /// route of its own (`StoredRoute`): the launch snapshot for the first
    /// landing in the process, the live session for any root view rebuilt
    /// after it (a size-class flip, #1555). The live record is by
    /// construction "where the user is now", so a rebuilt view lands there
    /// rather than back where the process started.
    var restoreSource: ResumeSession? {
        didConsumeLaunchSession ? session : launchSession
    }

    /// The section the app was last in — what the compact tab bar and the
    /// wide layout's launch task branch on. Mail when nothing is stored.
    var launchSection: ResumeSession.Section {
        restoreSource?.section ?? .mail
    }

    /// The mail landing for a window: its own stored folder and message
    /// (`stored`) when it has a folder, else the session's (`restoreSource`).
    /// Either way the launch snapshot is spent, so a window opened later
    /// lands on the live session. So is the launch's list place, which goes
    /// to the process's first mail landing and to no other: with the
    /// session's folder when that is the place's, and nowhere when the
    /// landing is on another folder or on a window's own stored one, whose
    /// place the window stored with it (`StoredRoute`).
    func mailLaunchTarget(stored: AppRoute.Mail = AppRoute.Mail()) -> MailLaunchTarget {
        let launchAnchor = launchListAnchor
        defer { endLaunchSnapshot() }
        if let folder = stored.folderPath, !folder.isEmpty {
            return MailLaunchTarget(folderPath: folder, messageRestore: stored.message.map(restoreCursor(for:)))
        }
        guard let saved = restoreSource, let folder = saved.folder, !folder.isEmpty else {
            return MailLaunchTarget(folderPath: "INBOX", messageRestore: nil)
        }
        var restore: NavState?
        if saved.hasMessage {
            restore = NavState(folder: folder, messageID: saved.messageID, uid: saved.uid, clientID: clientID)
        }
        return MailLaunchTarget(
            folderPath: folder, messageRestore: restore,
            listAnchor: launchAnchor?.folderPath == folder ? launchAnchor : nil
        )
    }

    /// A landing or a navigation has taken the launch's place: a window
    /// opened from here on lands on the live session (#1966), and the
    /// launch's list place is no longer where the user is.
    func endLaunchSnapshot() {
        didConsumeLaunchSession = true
        launchListAnchor = nil
    }

    /// The feed scope the feed reader should open when it mounts, or nil to
    /// stay at the feed list. Checks the scope against the local `RssStore`
    /// (a departed subscription or folder degrades to the list) and, if an
    /// item was open and is still in the store, returns it beside the scope
    /// for the window to park until the scope's list has loaded. Local
    /// SQLite reads only — no network at launch. Reads the window's stored
    /// scope and item (`stored`) when it has a scope, else `restoreSource`:
    /// the launch snapshot for the process's first landing, the live session
    /// for a window that lands in feeds later. A stored scope that is gone
    /// degrades to the feed list, as the session's does. A tree a layout swap
    /// rebuilds never asks; it takes over its window's place
    /// (`SceneNavigator`).
    func consumeFeedsLaunchTarget(stored: AppRoute.Feeds = AppRoute.Feeds()) async -> FeedLaunchTarget? {
        let source = restoreSource
        didConsumeLaunchSession = true
        if let scope = stored.scope {
            return await feedLaunchTarget(scope, feedID: stored.item?.feedID, sortKey: stored.item?.sortKey)
        }
        guard let saved = source, let scope = saved.feedScope else { return nil }
        return await feedLaunchTarget(scope, feedID: saved.feedItemFeedID, sortKey: saved.feedItemSortKey)
    }

    /// `scope` when it is still in the local store, with the item
    /// `feedID`/`sortKey` name when that is too; nil when the scope is gone.
    private func feedLaunchTarget(
        _ scope: RssItemScope, feedID: String?, sortKey: String?
    ) async -> FeedLaunchTarget? {
        guard let store = client.rssStore else { return nil }
        let scopeExists: Bool
        switch scope {
        case .all:
            scopeExists = true
        case .subscription(let id):
            scopeExists = ((try? await store.subscription(id: id)) ?? nil) != nil
        case .folder(let id):
            scopeExists = ((try? await store.folders()) ?? []).contains { $0.folderId == id }
        }
        guard scopeExists else { return nil }
        var target = FeedLaunchTarget(scope: scope)
        if let feedID, let sortKey {
            target.item = (try? await store.item(feedId: feedID, sortKey: sortKey)) ?? nil
        }
        return target
    }

    // MARK: Recording (session)

    /// The compact tab bar / visionOS tab switched section. Only the section
    /// moves: the mail and feed positions each keep their own state so a
    /// round trip restores both.
    func noteSection(_ section: ResumeSession.Section) {
        guard session.section != section else { return }
        session.section = section
        scheduleSessionSave()
    }

    /// The feed reader's list scope changed. A scope pick puts the session in
    /// the feeds section; clearing it (back to the feed list on compact) keeps
    /// the section, since on the wide layouts the mail pick that clears it
    /// records `.mail` itself and on compact the user is still in the tab.
    func recordFeedScope(_ scope: RssItemScope?) {
        session.feedScope = scope
        session.clearFeedItem()
        if scope != nil { session.section = .feeds }
        scheduleSessionSave()
    }

    /// The feed reader opened `item` (or closed it, nil).
    func recordFeedItem(_ item: RssItem?) {
        if let item {
            session.section = .feeds
            session.feedItemFeedID = item.feedId
            session.feedItemSortKey = item.sortKey
            // The cross-device cursor follows the item being read (Phase C),
            // starting from wherever this install last left it.
            let saved = positions.position(for: ReadingPositionKey.feed(itemID: item.id))
            activeKind = .rss
            feedCursorItem = item.id
            feedCursorScope = session.feedScope?.token
            feedAnchor = saved?.anchor
            feedFraction = saved?.fraction
            scheduleSave()
        } else {
            session.clearFeedItem()
        }
        scheduleSessionSave()
    }

    /// The feed reader's scroll capture: the local position cache, and the
    /// cross-device cursor when this item is the one it names and the
    /// capture's window records (`movesCursor`, `WindowRecorder`).
    func recordFeedScroll(itemID: String, capture: ScrollCapture, movesCursor: Bool = true) {
        savePosition(
            key: ReadingPositionKey.feed(itemID: itemID),
            anchor: capture.anchor,
            offset: nil,
            fraction: capture.fraction,
            atTop: capture.isAtTop
        )
        guard movesCursor, activeKind == .rss, feedCursorItem == itemID else { return }
        feedAnchor = capture.isAtTop ? nil : capture.anchor
        feedFraction = capture.isAtTop ? nil : capture.fraction
        scheduleSave()
    }

    /// The window's folder list moved (`ListAnchor`; nil at the top): kept
    /// in the session for the next launch, only while the session is on
    /// that folder. Local, with the save debounced like every session save;
    /// never a server write, so `list_scroll` stays dead on Apple.
    func recordListAnchor(_ anchor: ListAnchor?, folderPath: String) {
        guard session.folder == folderPath, session.listAnchor != anchor else { return }
        session.listAnchor = anchor
        scheduleSessionSave()
    }

    // MARK: Reading positions

    func readingPosition(key: String) -> ReadingPosition? {
        positions.position(for: key)
    }

    func readingPosition(folderPath: String, uid: UInt32, messageID: String?) -> ReadingPosition? {
        positions.position(for: ReadingPositionKey.mail(messageID: messageID, folder: folderPath, uid: uid))
    }

    /// The saved reading position for `ref`'s message.
    func readingPosition(for ref: MessageRef) -> ReadingPosition? {
        positions.position(for: ReadingPositionKey.mail(ref))
    }

    /// Stores (or, at the top of the body, clears) the reading position for
    /// `key`. A no-op when nothing changed, so the reader's capture stream
    /// doesn't churn the store.
    func savePosition(key: String, anchor: String?, offset: Int?, fraction: Double? = nil, atTop: Bool) {
        if atTop {
            guard positions.position(for: key) != nil else { return }
            positions.remove(key)
        } else {
            guard anchor != nil || offset != nil else { return }
            let current = positions.position(for: key)
            if current?.anchor == anchor, current?.offset == offset, current?.fraction == fraction { return }
            positions.set(ReadingPosition(anchor: anchor, offset: offset, fraction: fraction), for: key)
        }
        positionsDirty = true
        scheduleSessionSave()
    }

    // MARK: Persistence

    func scheduleSessionSave() {
        session.savedAt = Date()
        sessionSaveTask?.cancel()
        let debounce = sessionSaveDebounce
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.flushSession()
        }
    }

    /// Writes the session record (and the position cache, if it changed) now.
    /// The app's scene-phase handler calls this as it leaves the foreground so
    /// a debounce in flight isn't lost to a termination.
    public func flushSession() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        store.saveSession(session)
        if positionsDirty {
            store.savePositions(positions)
            positionsDirty = false
        }
    }

    /// Sign-out: drop everything this install remembered for the account.
    func clearLocalState() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        session = ResumeSession(section: .mail)
        positions = ReadingPositionCache()
        positionsDirty = false
        store.clear()
    }
}
