import Foundation
import Observation
import os
import CabalmailKit

// TEMP diagnostic logger (remove with the dbg() calls). Routed through unified
// logging so the output is visible from a Release / TestFlight build in
// Console.app (filter subsystem "com.cabalmail.debug") -- print() stdout is
// not. Values are logged .public so they aren't redacted in Release.
private let mlvmDebugLog = Logger(subsystem: "com.cabalmail.debug", category: "messagelist")

/// Backs `MessageListView`. Owns the paginated envelope window, envelope
/// cache hydration, search results, and the per-row mark-as-read / dispose
/// actions.
///
/// Window strategy: on open, `STATUS` the folder for its message count, then
/// fetch the top page via `topEnvelopes`. Older pages lazy-load as the user
/// scrolls, through positional `envelopes(offset:limit:)` calls against the
/// paginated `/list_messages` (large-mailbox plan Layer 3.1). The loaded
/// count versus the STATUS total decides `hasMore`, so sparse folders no
/// longer dead-end (Layer 3.3). The envelope cache stores everything keyed by
/// `UIDVALIDITY` so reopen is instant while the refresh runs in the
/// background.
@Observable
@MainActor
final class MessageListViewModel {
    let folder: Folder
    // Internal (not `private`) so the view model's same-module extensions
    // in sibling files (`+Optimistic`, `+NextUnread`) can reach them.
    let client: CabalmailClient
    let preferences: Preferences
    let appState: AppState
    private let pageSize: UInt32 = 50
    // Prefetch the next page once the user scrolls within this many rows of the
    // end of the loaded list, so scrolling never stalls at the bottom waiting
    // for a fetch (the trigger used to be the last row only -- zero lookahead).
    // Deliberately larger than `pageSize` and any reasonable viewport: on open
    // this prefetches the second page immediately, then keeps ~two pages loaded
    // ahead of the scroll. Cheap insurance for smoothness.
    private let prefetchDistance = 100

    var envelopes: [Envelope] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    /// Active sort key. Drives both the in-memory display order and the
    /// wire sort the Lambda applies. Mutated via `setSort(_:)`.
    var sortCriterion: SortCriterion = .default

    /// Active filter tab. A client-side filter over the loaded envelopes,
    /// not a wire predicate — purely a display narrowing. Resets to
    /// `.all` when the view-model is rebuilt (folder switch).
    var filterTab: MessageFilter = .all

    /// True when the user has tapped Select; rows render checkboxes and
    /// the per-row tap selects rather than opening the detail pane.
    var bulkMode: Bool = false

    /// UIDs the user has selected while `bulkMode` is on. Keyed by UID
    /// only — cross-folder search rows look up their source via
    /// `sourceFolder(for:)`, which is the same path single-row operations
    /// already use.
    var selectedUIDs: Set<UInt32> = []

    /// Anchor row for shift-click range selection: the last row plainly
    /// selected or command-clicked. iOS drives this (see
    /// `MessageListView+ModifierClick.swift`); macOS uses the native list's
    /// own anchor and leaves it untouched.
    var selectionAnchor: UInt32?

    /// Free-text term submitted from the search field. Filters live in
    /// `searchFilters`; the two are sent together when `runSearch()` runs.
    var searchQuery: String = ""

    /// Structured filter form state — mirrors the React filter panel.
    var searchFilters = MessageSearchFilters()

    /// `true` while search results are showing in `envelopes`.
    var isSearchActive: Bool = false

    /// Search-banner metadata. All zero when no search is active.
    var searchTotalEstimate: Int = 0
    var searchTruncated: Bool = false
    var searchFoldersSearched: [String] = []

    /// Per-uid source folder for cross-folder results. Empty in folder
    /// mode and single-folder searches; `sourceFolder(for:)` falls back
    /// to `folder.path` then. Internal (not private) so the search
    /// extension in `+Search.swift` can populate it.
    var sourceFolderByUID: [UInt32: String] = [:]

    private var uidValidity: UInt32?
    // Folder message count from the last STATUS. Pagination loads until the
    // loaded envelope count reaches it. Internal so the +Refresh sibling
    // extension can read it after a page merge to recompute `hasMore`.
    var totalMessages: UInt32 = 0
    var hasMore = true

    /// Foreground-only IDLE loop. Nil when the view is offscreen; started on
    /// `task`, stopped on `onDisappear`. Separated from the refresh path so
    /// UIDVALIDITY changes, pagination, and flag toggles never fight the
    /// watcher for the main actor.
    private var watcher: MailboxWatcher?
    private var watcherTask: Task<Void, Never>?
    /// Coalescing timestamp — if `.changed` fires in bursts (e.g. server
    /// delivers three messages in quick succession) we collapse them into
    /// one refresh by gating on elapsed time.
    private var lastRefreshFromWatcher: Date = .distantPast

    // The two pending-write sets below shield optimistic UI from a stale
    // refresh. A refresh dispatched just before a local write lands returns
    // the row's pre-write server state; applying it verbatim would resurrect
    // a row we just moved or revert a flag we just toggled, leaving the user
    // staring at an apparent no-op until the next refresh. While a UID sits
    // in either set, `mergeFetched` (and the cache persist) refuse to apply
    // the fetched copy for it; the sets clear when the write resolves, so the
    // following refresh carries server truth. Internal (not `private`) so the
    // write paths in the sibling extensions (`+Optimistic`, `+Move`, `+Bulk`)
    // and the merge in `+Refresh` can reach them.

    /// UIDs optimistically removed from `envelopes` (dispose or move) whose
    /// server-side move is still in flight. Besides the merge shield this
    /// doubles as `dispose(_:)`'s re-entrance guard: a duplicate rapid-swipe
    /// tap whose UID is already enqueued short-circuits, preventing
    /// re-entrant `ForEach(model.envelopes)` diffing while several in-flight
    /// moves are still returning.
    var pendingRemovedUIDs: Set<UInt32> = []

    /// UIDs with an in-flight flag write (`\Seen` / `\Flagged`) that this view
    /// model issued. While a UID sits here `mergeFetched` keeps the optimistic
    /// flags rather than letting a stale fetch revert them. Flag writes that
    /// originate in the detail view are tracked separately, in the shared
    /// `AppState.pendingFlagWriteUIDs` (its write lifecycle lives in the detail
    /// view model); `shieldFetched` consults both.
    var pendingFlagUIDs: Set<UInt32> = []

    init(folder: Folder, client: CabalmailClient, preferences: Preferences, appState: AppState) {
        self.folder = folder
        self.client = client
        self.preferences = preferences
        self.appState = appState
    }

    func loadInitial() async {
        guard envelopes.isEmpty else { return }
        await hydrateFromCache()
        await refresh()
    }

    /// Start the IDLE-backed auto-refresh loop. Called from the view's
    /// `.task` after `loadInitial()` settles. The watcher runs on its own
    /// actor and emits `.changed` whenever the server pushes an
    /// EXISTS/EXPUNGE/FETCH; we collapse bursts to a single refresh by
    /// gating on elapsed time (IMAP doesn't promise deduped notifications
    /// and a 10-message import can fire EXISTS ten times in a second).
    func startWatching() async {
        guard watcher == nil else { return }
        let client = self.client
        let watcher = MailboxWatcher(
            folder: folder.path,
            streamFactory: { folder in
                try await client.imapClient.idle(folder: folder)
            }
        )
        self.watcher = watcher
        let stream = await watcher.start()
        watcherTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self else { break }
                if case .changed = event {
                    await self.handleWatcherChanged()
                }
            }
        }
    }

    /// Tear down the watcher. View hooks this into `.onDisappear` so IDLE
    /// stops when the list isn't on-screen — we don't want to hold a
    /// background IMAP connection open for a mailbox the user isn't looking
    /// at (each session costs ~1 IMAP connection against Dovecot's pool).
    func stopWatching() async {
        watcherTask?.cancel()
        watcherTask = nil
        await watcher?.stop()
        watcher = nil
    }

    private func handleWatcherChanged() async {
        // Coalesce bursts — a multi-message delivery can push ten EXISTS
        // notifications inside a single second. One refresh is enough.
        let now = Date()
        guard now.timeIntervalSince(lastRefreshFromWatcher) > 1 else { return }
        lastRefreshFromWatcher = now
        await refresh()
    }

    func refresh() async {
        // Re-route while a search is showing — pull-to-refresh and the
        // IDLE / 60-second background refreshes shouldn't silently wipe
        // active search results back to the folder view. Re-running the
        // search keeps the result set fresh against any concurrent
        // mailbox churn.
        if isSearchActive {
            await runSearch()
            return
        }
        isLoading = true
        defer { isLoading = false }
        dbg("refresh start sort=\(sortCriterion.field)")
        do {
            try await client.imapClient.connectAndAuthenticate()
            let status = try await client.imapClient.status(path: folder.path)
            dbg("refresh uidv=\(status.uidValidity ?? 0)/\(self.uidValidity ?? 0) msgs=\(status.messages ?? -1)")
            let uidNext = status.uidNext ?? 1
            // Only a concrete, *changed* UIDVALIDITY means "rebuild from
            // scratch." A missing/zero reading from a flaky STATUS must not
            // wipe a scrolled, paginated list back to the top page on a
            // routine background refresh.
            if let fresh = status.uidValidity, fresh != 0 {
                if let known = self.uidValidity, known != fresh {
                    dbg("refresh WIPE-uidValidity \(known) -> \(fresh)")
                    try? await client.envelopeCache.invalidate(folder: folder.path)
                    try? await client.bodyCache.invalidate(folder: folder.path)
                    envelopes = []
                }
                self.uidValidity = fresh
            }
            let uidValidity = self.uidValidity ?? 0
            // Top page uses sequence-number FETCH via `topEnvelopes` (robust on
            // sparse folders); `loadMoreIfNeeded` loads older pages positionally
            // by offset. `totalMessages` from STATUS gates pagination.
            let messages = UInt32(max(0, status.messages ?? 0))
            totalMessages = messages
            let fetched = try await client.imapClient.topEnvelopes(
                folder: folder.path,
                limit: pageSize,
                totalMessages: messages,
                sort: sortCriterion
            )
            dbg("refresh topFetched=\(fetched.count)")
            try await applyRefreshPage(fetched, uidNext: uidNext, uidValidity: uidValidity)
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentItem: Envelope) async {
        // No pagination while a search is active. The displayed envelopes
        // are cross-folder search results, but this method fetches older
        // UIDs from `folder.path` (the sidebar selection) — those would
        // appear as a chunk of unrelated inbox messages tacked onto the
        // bottom of the search results. Worse, the post-fetch
        // `persistCache` writes ALL of in-memory `envelopes` into the
        // current folder's snapshot via `EnvelopeCache.merge`, which has
        // no UID-range filter; the foreign UIDs from search would land
        // in the cache and re-hydrate as phantom rows on next launch.
        // Server-side search pagination is bounded by `searchTruncated`
        // / `searchTotalEstimate`; refining the query is the right
        // affordance for "show me more results," not infinite scroll.
        guard hasMore, !isLoadingMore, !isLoading,
              !isSearchActive,
              pendingRemovedUIDs.isEmpty,
              envelopes.suffix(prefetchDistance).contains(where: { $0.uid == currentItem.uid })
              else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            // Positional page: the next `pageSize` envelopes after what's
            // loaded, in the current sort order. `mergeFetched` dedups, so a
            // shifted offset (a concurrent removal) can't double-insert.
            let offset = UInt32(envelopes.count)
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                offset: offset,
                limit: pageSize,
                sort: sortCriterion
            )
            mergeFetched(fetched)
            // Done when the page comes back empty or the loaded count reaches
            // the folder's STATUS total -- no more decrementing a UID cursor
            // one band at a time, which dead-ended on sparse folders.
            hasMore = !fetched.isEmpty && UInt32(envelopes.count) < totalMessages
            dbg("loadMore off=\(offset) fetched=\(fetched.count) hasMore=\(hasMore) total=\(totalMessages)")
            if let uidValidity, let uidNext = envelopes.map(\.uid).max() {
                try await persistCache(uidValidity: uidValidity, uidNext: uidNext + 1)
            }
        } catch {
            // Best-effort pagination — don't surface an error unless we're
            // blocked entirely.
            dbg("loadMore ERROR \(error)")
        }
    }

    // Structured search (`runSearch`, `clearSearch`, `sourceFolder(for:)`,
    // and the query builder) lives in `MessageListViewModel+Search.swift`
    // so the primary type body stays under SwiftLint's length cap.

    func markRead(_ envelope: Envelope) async {
        await setFlag(.seen, add: true, envelope: envelope)
    }

    /// Flip the `\Seen` flag — drives the leading (left-to-right) swipe
    /// action. Mirrors the Mail.app convention that the same gesture
    /// toggles between read and unread rather than having two.
    func toggleSeen(_ envelope: Envelope) async {
        let add = !envelope.flags.contains(.seen)
        await setFlag(.seen, add: add, envelope: envelope)
    }

    func toggleFlag(_ envelope: Envelope) async {
        let add = !envelope.flags.contains(.flagged)
        await setFlag(.flagged, add: add, envelope: envelope)
    }

    /// Dispose target is the current `Preferences.disposeAction` — Archive
    /// or Trash. The preference is read on every invocation so a user who
    /// toggles the setting mid-session sees the swipe behavior change
    /// immediately.
    ///
    /// Also matches the React webmail behavior by marking the message
    /// `\Seen` before the move: archived == read. The seen flag is set
    /// while the message is still in the current folder; post-move the UID
    /// no longer exists here so `STORE` would reject it.
    ///
    /// Optimistic UI: the row is removed from `envelopes` before the
    /// server round trip so the swipe feels instant. If the move fails the
    /// envelope is reinserted at its prior index. Cache pruning still waits
    /// for server confirmation — without that gate, a transient failure
    /// would leave the persistent snapshot disagreeing with the server.
    func dispose(_ envelope: Envelope) async {
        guard pendingRemovedUIDs.insert(envelope.uid).inserted else { return }
        defer { pendingRemovedUIDs.remove(envelope.uid) }

        let destination = preferences.disposeAction.destinationFolder
        let source = sourceFolder(for: envelope)
        let originalIndex = envelopes.firstIndex { $0.uid == envelope.uid }
        let wasUnread = !envelope.flags.contains(.seen)
        envelopes.removeAll { $0.uid == envelope.uid }
        // Optimistic count drop for the source folder: the dispose path
        // marks the message `\Seen` before moving, so an unread message
        // both loses its unread state AND leaves the folder. One -1 covers
        // both — the post-move STATUS walk will fix it if the server
        // disagrees. In cross-folder search mode `source` may differ from
        // `folder.path`; the unread delta routes to the row's true mailbox.
        if wasUnread {
            appState.applyUnreadDelta(folderPath: source, delta: -1)
        }

        do {
            if !envelope.flags.contains(.seen) {
                try await client.imapClient.setFlags(
                    folder: source,
                    uids: [envelope.uid],
                    flags: [.seen],
                    operation: .add
                )
            }
            try await client.imapClient.move(
                folder: source,
                uids: [envelope.uid],
                destination: destination
            )
            await pruneCachesAfter(move: source, uid: envelope.uid)
        } catch {
            restoreEnvelope(envelope, at: originalIndex)
            if wasUnread {
                appState.applyUnreadDelta(folderPath: source, delta: 1)
            }
            errorMessage = "\(error)"
        }
    }

    /// Cache cleanup after a successful move out of `folder`. Pulled out
    /// of `dispose(_:)` so `moveTo` (in the sibling extension) can share
    /// the path without needing access to the private `uidValidity`.
    func pruneCachesAfter(move folder: String, uid: UInt32) async {
        await pruneCachesAfter(move: folder, uids: [uid])
    }

    /// Batch variant for the bulk-action paths. `EnvelopeCache.remove`
    /// already takes an array; `MessageBodyCache.remove` is per-uid so
    /// we loop.
    func pruneCachesAfter(move folder: String, uids: [UInt32]) async {
        guard let uidValidity, !uids.isEmpty else { return }
        try? await client.envelopeCache.remove(uids: uids, folder: folder)
        for uid in uids {
            await client.bodyCache.remove(
                folder: folder,
                uidValidity: uidValidity,
                uid: uid
            )
        }
    }

    /// The currently-configured dispose action, exposed so the view can
    /// render the right swipe-action label and icon without reaching into
    /// the preferences environment itself.
    var disposeAction: DisposeAction { preferences.disposeAction }

    /// Drop a UID from the in-memory envelope list after it was disposed
    /// elsewhere (currently: the detail-view archive button). The detail
    /// view model already pruned the envelope + body caches; this only
    /// touches the list's in-memory copy so the row disappears immediately
    /// without a server round trip.
    func pruneEnvelope(uid: UInt32) {
        envelopes.removeAll { $0.uid == uid }
    }

    /// Apply a flag toggle that originated outside the list (currently: the
    /// detail view's Mark-as-read toggle). Updates the in-memory envelope so
    /// the row's bold styling and unread dot match the new state without
    /// waiting for IDLE. No-op when the UID isn't currently in the window.
    func applyFlagChange(uid: UInt32, flag: Flag, added: Bool) {
        applyOptimisticFlag(uid: uid, flag: flag, add: added)
    }
}

// MARK: - Internals

// Lifted into an extension so the primary type body stays under SwiftLint's
// 250-line cap. Same-file extension — all helpers remain file-private to
// the view model.
extension MessageListViewModel {
    // TEMP diagnostic (remove once the deep-scroll reset is pinned). Logs the
    // event and the current envelope count: a list wipe shows up as a count
    // drop here, while a scroll-only reset shows the count holding steady.
    // Internal (not private) so the sibling-file extensions can call it. Uses
    // os.Logger (not print) so it's visible from a Release / TestFlight build.
    func dbg(_ msg: String) {
        let line = "CABALDBG [\(folder.path)] \(msg) | n=\(envelopes.count)"
        mlvmDebugLog.notice("\(line, privacy: .public)")
    }

    private func hydrateFromCache() async {
        if let snapshot = await client.envelopeCache.snapshot(for: folder.path) {
            uidValidity = snapshot.uidValidity
            envelopes = snapshot.envelopes.values.sorted(by: envelopeOrder)
            dbg("hydrate loaded=\(snapshot.envelopes.count)")
            // `hasMore`/`totalMessages` stay at their defaults; the refresh
            // that follows hydration sets the real count from STATUS.
        }
    }

    private func persistCache(uidValidity: UInt32, uidNext: UInt32) async throws {
        try await client.envelopeCache.merge(
            envelopes: envelopes,
            uidValidity: uidValidity,
            uidNext: uidNext,
            into: folder.path
        )
    }
}
