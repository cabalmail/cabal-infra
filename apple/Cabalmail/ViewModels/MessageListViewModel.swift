import Foundation
import Observation
import CabalmailKit

/// Backs `MessageListView`. Owns the sliding UID window, envelope cache
/// hydration, search results, and the per-row mark-as-read / dispose actions.
///
/// Window strategy (per Phase 4 plan): on open, `STATUS` the folder to pick
/// up `UIDNEXT`, then `UID FETCH (uidNext - pageSize):uidNext`. Older pages
/// lazy-load as the user scrolls. The envelope cache stores everything keyed
/// by `UIDVALIDITY` so reopen is instant while the refresh runs in the
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
    // Internal so the +Refresh sibling extension can update them after a
    // page merge; they're otherwise driven from the main view-model only.
    var lowestUID: UInt32?
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

    /// UIDs currently in flight through `dispose(_:)`. Every swipe enqueues
    /// the UID here, removes it in `defer`, and short-circuits duplicate
    /// taps. Prevents re-entrant SwiftUI list mutation when a user taps
    /// archive rapidly on several rows — the previous pattern queued one
    /// `UID MOVE` per tap and mutated `envelopes` on completion, which
    /// allowed `ForEach(model.envelopes)` to diff a shrinking array while
    /// the in-flight moves were still returning.
    private var pendingDisposeUIDs: Set<UInt32> = []

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
        do {
            try await client.imapClient.connectAndAuthenticate()
            let status = try await client.imapClient.status(path: folder.path)
            let uidNext = status.uidNext ?? 1
            let uidValidity = status.uidValidity ?? 0
            if self.uidValidity != uidValidity {
                try? await client.envelopeCache.invalidate(folder: folder.path)
                try? await client.bodyCache.invalidate(folder: folder.path)
                envelopes = []
                lowestUID = nil
            }
            self.uidValidity = uidValidity
            // Top page uses sequence-number FETCH via `topEnvelopes` — see
            // the protocol doc for why UID range fetches go wrong on sparse
            // folders. `loadMoreIfNeeded` handles older pages by UID.
            let messages = UInt32(max(0, status.messages ?? 0))
            let fetched = try await client.imapClient.topEnvelopes(
                folder: folder.path,
                limit: pageSize,
                totalMessages: messages,
                sort: sortCriterion
            )
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
              pendingDisposeUIDs.isEmpty,
              envelopes.last?.uid == currentItem.uid,
              let lowestUID,
              lowestUID > 1 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let upper = lowestUID - 1
            let lower = upper > pageSize ? upper - pageSize : 1
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                range: lower...upper,
                sort: sortCriterion
            )
            mergeFetched(fetched)
            // An empty fetch on a range above UID 1 means the server has no
            // messages in that band — don't spin indefinitely decrementing
            // `lowestUID` one at a time. Flag "no more" explicitly.
            if fetched.isEmpty {
                hasMore = false
                self.lowestUID = lower
            } else {
                let newLowest = fetched.map(\.uid).min() ?? upper
                self.lowestUID = newLowest
                hasMore = newLowest > 1
            }
            if let uidValidity, let uidNext = envelopes.map(\.uid).max() {
                try await persistCache(uidValidity: uidValidity, uidNext: uidNext + 1)
            }
        } catch {
            // Best-effort pagination — don't surface an error unless we're
            // blocked entirely.
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
        guard pendingDisposeUIDs.insert(envelope.uid).inserted else { return }
        defer { pendingDisposeUIDs.remove(envelope.uid) }

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
    private func hydrateFromCache() async {
        if let snapshot = await client.envelopeCache.snapshot(for: folder.path) {
            uidValidity = snapshot.uidValidity
            envelopes = snapshot.envelopes.values.sorted(by: envelopeOrder)
            lowestUID = envelopes.map(\.uid).min()
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
