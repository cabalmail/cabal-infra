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
    struct MailLaunchTarget: Equatable {
        let folderPath: String
        let messageRestore: NavState?
    }

    /// Where the feed reader should land: a scope, and the item that was open
    /// in it, for the window to park until the scope's list has appeared and
    /// loaded (#1664). Also what a tapped feed banner opens.
    struct FeedLaunchTarget: Equatable {
        let scope: RssItemScope
        var item: RssItem?
    }

    /// The record a landing restores from: the launch snapshot for the first
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

    func mailLaunchTarget() -> MailLaunchTarget {
        defer { didConsumeLaunchSession = true }
        guard let saved = restoreSource, let folder = saved.folder, !folder.isEmpty else {
            return MailLaunchTarget(folderPath: "INBOX", messageRestore: nil)
        }
        var restore: NavState?
        if saved.hasMessage {
            restore = NavState(folder: folder, messageID: saved.messageID, uid: saved.uid, clientID: clientID)
        }
        return MailLaunchTarget(folderPath: folder, messageRestore: restore)
    }

    /// The feed scope the feed reader should open when it mounts, or nil to
    /// stay at the feed list. Checks the scope against the local `RssStore`
    /// (a departed subscription or folder degrades to the list) and, if an
    /// item was open and is still in the store, returns it beside the scope
    /// for the window to park until the scope's list has loaded. Local
    /// SQLite reads only — no network at launch. Reads `restoreSource`: the
    /// launch snapshot for the process's first landing, the live session for
    /// a window that lands in feeds later. A tree a layout swap rebuilds
    /// never asks; it takes over its window's place (`SceneNavigator`).
    func consumeFeedsLaunchTarget() async -> FeedLaunchTarget? {
        let source = restoreSource
        didConsumeLaunchSession = true
        guard let saved = source, let scope = saved.feedScope, let store = client.rssStore else {
            return nil
        }
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
        if let feedID = saved.feedItemFeedID, let sortKey = saved.feedItemSortKey {
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
    /// cross-device cursor when this item is the one it names.
    func recordFeedScroll(itemID: String, capture: ScrollCapture) {
        savePosition(
            key: ReadingPositionKey.feed(itemID: itemID),
            anchor: capture.anchor,
            offset: nil,
            fraction: capture.fraction,
            atTop: capture.isAtTop
        )
        guard activeKind == .rss, feedCursorItem == itemID else { return }
        feedAnchor = capture.isAtTop ? nil : capture.anchor
        feedFraction = capture.isAtTop ? nil : capture.fraction
        scheduleSave()
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
    /// The scene-phase handlers call this as the app leaves the foreground so
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
