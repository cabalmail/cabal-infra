import Foundation
import CabalmailKit

// The local resume layer of `NavStateCoordinator`: the per-install session
// record (section, scope, open item), the per-item reading-position cache,
// and the launch-restore entry points the views call. Nothing here touches
// the network. See `docs/1.x/resume-session-plan.md`.
extension NavStateCoordinator {
    /// Where the mail UI should land at launch: the session's folder (INBOX
    /// when there is none) and, if a message was open, a cursor to hand to
    /// `scheduleRestore` so the list selects it after its initial load. The
    /// folder is provisional — `MailRootView` swaps the fetched `Folder` in
    /// when the list arrives and falls back to INBOX if it no longer exists.
    struct MailLaunchTarget: Equatable {
        let folderPath: String
        let messageRestore: NavState?
    }

    /// The section the app was last in — what the compact tab bar and the
    /// wide layout's launch task branch on. Mail when nothing is stored.
    var launchSection: ResumeSession.Section {
        launchSession?.section ?? .mail
    }

    func mailLaunchTarget() -> MailLaunchTarget {
        guard let saved = launchSession, let folder = saved.folder, !folder.isEmpty else {
            return MailLaunchTarget(folderPath: "INBOX", messageRestore: nil)
        }
        var restore: NavState?
        if saved.hasMessage {
            restore = NavState(folder: folder, messageID: saved.messageID, uid: saved.uid, clientID: clientID)
        }
        return MailLaunchTarget(folderPath: folder, messageRestore: restore)
    }

    /// The feed scope the feed reader should open at launch, once per
    /// process, or nil to stay at the feed list. Checks the scope against the
    /// local `RssStore` (a departed subscription or folder degrades to the
    /// list) and, if an item was open and is still in the store, parks it as
    /// `pendingFeedRestore` for the scope's `onChange` to select. Local SQLite
    /// reads only — no network at launch.
    func consumeFeedsLaunchTarget() async -> RssItemScope? {
        guard !didConsumeFeedsLaunch else { return nil }
        didConsumeFeedsLaunch = true
        guard let saved = launchSession, let scope = saved.feedScope, let store = client.rssStore else {
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
        if let feedID = saved.feedItemFeedID, let sortKey = saved.feedItemSortKey,
           let item = (try? await store.item(feedId: feedID, sortKey: sortKey)) ?? nil {
            pendingFeedRestore = PendingFeedRestore(scope: scope, item: item)
        }
        return scope
    }

    /// Returns and clears the parked feed item if it belongs to `scope` — the
    /// scope the feed navigation just selected. Called from
    /// `onChange(of: selectedScope)`, which is the first point after the
    /// scope change where setting the item won't be undone by the change
    /// handler itself.
    func consumeFeedItemRestore(for scope: RssItemScope) -> RssItem? {
        guard let restore = pendingFeedRestore, restore.scope == scope else { return nil }
        pendingFeedRestore = nil
        return restore.item
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
        } else {
            session.clearFeedItem()
        }
        scheduleSessionSave()
    }

    // MARK: Reading positions

    func readingPosition(key: String) -> ReadingPosition? {
        positions.position(for: key)
    }

    func readingPosition(folderPath: String, uid: UInt32, messageID: String?) -> ReadingPosition? {
        positions.position(for: ReadingPositionKey.mail(messageID: messageID, folder: folderPath, uid: uid))
    }

    /// Stores (or, at the top of the body, clears) the reading position for
    /// `key`. A no-op when nothing changed, so the reader's capture stream
    /// doesn't churn the store.
    func savePosition(key: String, anchor: String?, offset: Int?, atTop: Bool) {
        if atTop {
            guard positions.position(for: key) != nil else { return }
            positions.remove(key)
        } else {
            guard anchor != nil || offset != nil else { return }
            let current = positions.position(for: key)
            if current?.anchor == anchor, current?.offset == offset { return }
            positions.set(ReadingPosition(anchor: anchor, offset: offset), for: key)
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
    func flushSession() {
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
        pendingFeedRestore = nil
        store.clear()
    }
}
