import Foundation
import Observation
import CabalmailKit

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
    /// What this list is showing — a folder or the global search surface.
    /// `.search` runs no folder lifecycle; see `MessageListScope`.
    let scope: MessageListScope
    /// Resolved anchor folder (a sentinel in `.search` scope). Folder-keyed
    /// call sites read this unchanged; the search paths are gated off before
    /// any of them issue an IMAP request against a `.search` sentinel.
    let folder: Folder
    // Internal (not `private`) so the view model's same-module extensions
    // in sibling files (`+Optimistic`, `+NextUnread`) can reach them.
    let client: CabalmailClient
    let preferences: Preferences
    let appState: AppState
    // Top-page size. Kept small for a fast first paint on a cold folder, and
    // reused as the "have we paginated past the top page?" threshold in
    // `applyRefreshPage` (+Refresh sibling file), so it's internal not private.
    let pageSize: UInt32 = 50
    // Older pages fetched while scrolling use a larger size: each
    // /list_envelopes round trip carries fixed IMAP connect/SELECT overhead,
    // so bigger pages mean fewer trips and steadier deep scrolling. Capped
    // server-side by helper.py MAX_PAGE_SIZE (250); 200 stays under it.
    let loadMorePageSize: UInt32 = 200
    // Max rows kept in the loaded window. Trimming the scrolled-past front
    // past this bound keeps SwiftUI's per-update cost (its O(n) ForEach diff
    // and the O(n) `filteredEnvelopes` in the view) from growing without
    // limit -- what made the list sluggish past ~800 loaded. Sized to hold
    // the viewport, the prefetch runway below it, and a scroll-back buffer
    // above, while staying under that point. Tunable.
    let windowCap = 600
    // Prefetch the next page once the user scrolls within this many rows of the
    // end of the loaded list, so scrolling doesn't stall at the bottom waiting
    // for a fetch. It has to exceed the number of rows the user scrolls past
    // during one page fetch, so it scales with `loadMorePageSize`: at 100 (set
    // when pages were 50) the next 200-row page only began loading once the
    // user was halfway through the page they were on, so a normal scroll
    // reached the end before it arrived. A little over one page keeps a full
    // page of runway ahead -- on open it prefetches the first big page
    // immediately, then stays ~a page ahead of the scroll.
    let prefetchDistance = 250

    var envelopes: [Envelope] = []
    var isLoading = false
    var isLoadingMore = false
    // Upward counterpart of `isLoadingMore`: a front-reload (loadPrevious) is
    // in flight. No top spinner (a top ProgressView would itself shift the
    // scroll); it only gates against overlapping a downward page with an
    // upward one. Internal so the `+Refresh` sibling that owns loadPrevious
    // can set it.
    var isLoadingPrevious = false
    // A full-window reload (a scrollbar drag into an unloaded region) is in
    // flight. Gates the incremental extends and other jumps against it.
    // Internal so `performLoadWindow` in the `+Refresh` sibling can clear it.
    var isLoadingWindow = false
    var errorMessage: String?
    /// Why the last action on selected rows left some of them alone (the
    /// cross-folder guard, `unambiguous(_:)` in `+Bulk`, behind the bulk bar,
    /// the selection menu and shortcuts, a row menu's Archive or Delete, and
    /// a multi-row drag). Not `errorMessage`: that reports the list's own
    /// failures, scrolls with the rows and is cleared by the next successful
    /// load, which in search mode is a page the user pulls in just by
    /// scrolling. This answers something the user just did, so the list pins
    /// it until they dismiss it, act again, or leave the results.
    var skippedNotice: String?

    /// Active sort key. Drives both the in-memory display order and the
    /// wire sort the Lambda applies. Mutated via `setSort(_:)`.
    var sortCriterion: SortCriterion = .default

    /// Active filter tab. Narrows the loaded envelopes client-side and, for
    /// Unread / Flagged, drives the folder-scoped server search that loads
    /// them (`selectFilter`). Sticky per folder: a rebuilt view-model
    /// (folder switch, relaunch) opens on the pill the user last chose for
    /// this folder (`Preferences.mailFolderFilters`), All until then.
    var filterTab: MessageFilter = .all

    /// True when the user has tapped Select; rows render checkboxes and
    /// the per-row tap selects rather than opening the detail pane.
    var bulkMode: Bool = false

    /// UIDs the user has selected while `bulkMode` is on. Keyed by UID
    /// only — cross-folder search rows look up their source via
    /// `sourceFolder(for:)`, which is the same path single-row operations
    /// already use.
    var selectedUIDs: Set<UInt32> = []

    /// Anchor row for range selection: the fixed pivot a shift-click or
    /// shift-arrow extends from -- the last row plainly selected or
    /// command-clicked. Settable only through `setSelectionAnchor(_:)`, so
    /// it cannot drift out of step with `selectionRangeBase`.
    private(set) var selectionAnchor: UInt32?

    /// The selection a range operation extends *from*: whatever was selected
    /// at the moment `selectionAnchor` was pinned.
    ///
    /// A shift-click unions its span onto this rather than replacing the
    /// selection, which is how rows picked with command outside the span
    /// survive (#1768). It is never written on its own -- a base left over
    /// from an earlier anchor would resurrect rows the user has since
    /// dropped -- which is what `setSelectionAnchor(_:)` enforces.
    private(set) var selectionRangeBase: Set<UInt32> = []

    /// Pin the pivot for range selection, recording the selection it starts
    /// from. The anchor and its base always move together.
    func setSelectionAnchor(_ uid: UInt32?) {
        selectionAnchor = uid
        selectionRangeBase = selectedUIDs
    }

    /// The moving end of a keyboard range selection (the row a plain arrow
    /// last landed on, or a shift-arrow last extended to). Distinct from the
    /// anchor so shift-arrow grows/shrinks the range from the right end rather
    /// than collapsing it. Plain selection sets cursor == anchor.
    var selectionCursor: UInt32?

    /// Free-text term submitted from the search field. Filters live in
    /// `searchFilters`; the two are sent together when `runSearch()` runs.
    var searchQuery: String = ""

    /// Structured filter form state — mirrors the React filter panel.
    var searchFilters = MessageSearchFilters()

    /// The folder the global search surface's "This folder only" narrows to:
    /// the wide layout's sidebar selection, fed in through
    /// `setSearchAnchor(_:)`. Unused in folder scope, which narrows to
    /// `folder`; see `searchFolder`.
    var searchAnchor: Folder?

    /// The trimmed term the most recent submitted search ran with. Distinct
    /// from `searchQuery`, which tracks the field as the user types: search is
    /// submit-driven, so the two diverge for every keystroke between typing
    /// and Return, and that gap is what tells a pending query from an
    /// exhausted one.
    /// Written by `runSearch()` / `clearSearch()` only.
    var submittedQuery: String = ""

    /// `true` while search results are showing in `envelopes`.
    var isSearchActive: Bool = false

    /// Search-banner metadata. All zero when no search is active.
    var searchTotalEstimate: Int = 0
    var searchTruncated: Bool = false
    var searchFoldersSearched: [String] = []

    /// Opaque next-page cursor for the active search; nil = every match
    /// loaded (or no search active). Cleared before every fresh search so
    /// an in-flight load-more can detect it raced a reset and drop its
    /// page. Written by the `+Search.swift` extension only.
    var searchNextCursor: String?

    /// A search load-more page is in flight — guards re-entry and drives
    /// the list's tail spinner.
    var isLoadingMoreSearch = false

    /// Model-owned task for the search load-more fetch, so it outlives the
    /// triggering row's `.task` cancellation (the `loadMoreTask` pattern).
    var loadMoreSearchTask: Task<Void, Never>?

    /// Per-row source folder for cross-folder results. Empty in folder
    /// mode and single-folder searches; `sourceFolder(for:)` falls back
    /// to `folder.path` then. Internal (not private) so the search
    /// extension in `+Search.swift` can populate it.
    var sourceFolderIndex = SearchSourceFolderIndex()

    private var uidValidity: UInt32?
    // Folder message count from the last STATUS. Pagination loads until the
    // loaded envelope count reaches it. Internal so the +Refresh sibling
    // extension can read it after a page merge to recompute `hasMore`.
    var totalMessages: UInt32 = 0
    // Server-sourced folder counts from the last STATUS (+ SEARCH FLAGGED),
    // independent of how many envelopes are paged in. Drive the Unread/Flagged
    // filter-pill counts, mirroring the React pills; `totalMessages` is the All
    // count. Reset alongside `totalMessages` on folder/search change.
    var unseen: Int = 0
    var flagged: Int = 0
    /// The All pill's count until a STATUS answers this session: the folder
    /// total last saved (`seedSavedCounts`). Kept apart from `totalMessages`,
    /// which also sizes the list, where a total nothing can load offline
    /// would draw placeholder rows.
    var savedMessageCount: Int?
    var hasMore = true
    // Sliding-window pagination state. `envelopes` holds a contiguous window
    // [windowStart, windowStart + count) of the folder's sorted list;
    // `windowStart` is the absolute sort-index of `envelopes[0]`, so page
    // offsets are absolute, not `envelopes.count`. `hasTrimmedFront` records
    // that the window no longer starts at the top, which gates the top-page
    // refresh and the snapshot persist (both assume a top-anchored window).
    // `performLoadPrevious` reloads the front as the user scrolls back up,
    // clearing `hasTrimmedFront` once the window reaches the top again. Reset
    // via `resetWindow()` on every path that wipes `envelopes`. Internal so
    // the `+Refresh` sibling (loadPrevious) can reach them.
    var windowStart: UInt32 = 0
    var hasTrimmedFront = false
    /// What the window is known to line up with on the server, and the state
    /// of any re-read that realigns it (`+Reconcile`).
    @ObservationIgnored var alignment = WindowAlignment()

    /// Foreground-only change watcher (`MailboxWatcher`, which polls folder
    /// status). Nil when the view is offscreen; started on
    /// `task`, stopped on `onDisappear`. Separated from the refresh path so
    /// UIDVALIDITY changes, pagination, and flag toggles never fight the
    /// watcher for the main actor.
    private var watcher: MailboxWatcher?
    private var watcherTask: Task<Void, Never>?
    /// In-flight pagination fetch, owned by the model so it survives the
    /// triggering row's `.task` cancellation (see `ensureLoaded(around:)`).
    /// Cancelled in `stopWatching()` when the list goes away.
    var loadMoreTask: Task<Void, Never>?
    /// In-flight front reload (loadPrevious), owned by the model like
    /// `loadMoreTask` so it survives the triggering row's `.task`
    /// cancellation. Cancelled in `stopWatching()`.
    var loadPrevTask: Task<Void, Never>?
    /// In-flight full-window reload for a scrollbar jump. Model-owned for the
    /// same reason; cancelled in `stopWatching()`.
    var loadWindowTask: Task<Void, Never>?
    /// Debounced envelope-snapshot writer (see `schedulePersist`). Coalesces
    /// the O(loaded count) snapshot rewrite so a continuous scroll persists
    /// once when it settles, not on every page. Cancelled in `stopWatching()`.
    private var persistTask: Task<Void, Never>?
    /// Debounced "load where the list settled" after a keyboard page jump.
    /// Cancelled in `stopWatching()`.
    var keyScrollTask: Task<Void, Never>?
    /// Absolute indices of the rows the list is currently rendering, tracked via
    /// row onAppear/onDisappear. `@ObservationIgnored` so the high-frequency
    /// churn never invalidates the view; read only by the page-scroll handlers.
    /// Counted rather than a set: a replaced row (`replaceRows(showing:)`) is
    /// one row leaving its index and another arriving at it, and SwiftUI
    /// doesn't promise the old one's onDisappear comes first.
    @ObservationIgnored var visibleRowIndices: [Int: Int] = [:]
    /// Pre-fetched bottom window, staged off to the side so the first jump to
    /// the bottom (End / scrollbar-to-bottom) is instant rather than a round
    /// trip. The single contiguous `envelopes` window can't hold both the top
    /// and the bottom at once, and the on-disk cache is UID-keyed + top-
    /// anchored (no positional hydrate), so the bottom lives here (see
    /// `BottomPrefetch`). `performLoadWindow` adopts it;
    /// `invalidateBottomPrefetch()` drops it. `@ObservationIgnored` so the
    /// background fill never invalidates the list view.
    @ObservationIgnored var bottomPrefetch: BottomPrefetch?
    /// In-flight bottom-prefetch fetch, model-owned (like `loadWindowTask`) so a
    /// late fill can be cancelled on folder teardown / invalidation rather than
    /// landing stale rows. Cancelled in `stopWatching()` and on every invalidate.
    @ObservationIgnored var bottomPrefetchTask: Task<Void, Never>?
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

    /// UIDs on their way out of `envelopes` (dispose or move) whose
    /// server-side move is still in flight — including, on the dispose path,
    /// the few hundred milliseconds where the row is still present but
    /// animating out (`rowDisposalPhases`). Besides the merge shield this
    /// doubles as `dispose(_:)`'s re-entrance guard: a duplicate rapid-swipe
    /// tap whose UID is already enqueued short-circuits, preventing
    /// re-entrant `ForEach(model.envelopes)` diffing while several in-flight
    /// moves are still returning.
    var pendingRemovedUIDs: Set<UInt32> = []

    /// Rows `pruneEnvelope(uid:)` took out for a reader dispose / move /
    /// purge that is still in flight, with the index each held, so a failed
    /// server write can put the row back (`restorePrunedEnvelope`).
    /// Only in-flight removals are kept, so it holds a handful at most.
    @ObservationIgnored var readerPrunedEnvelopes: [UInt32: (envelope: Envelope, index: Int)] = [:]
    /// Reader removals that failed before their prune ran; the prune skips
    /// them. See `restorePrunedEnvelope(uid:markUnread:)`.
    @ObservationIgnored var readerFailedUIDs: Set<UInt32> = []

    /// UIDs with an in-flight flag write (`\Seen` / `\Flagged`) that this view
    /// model issued. While a UID sits here `mergeFetched` keeps the optimistic
    /// flags rather than letting a stale fetch revert them. Flag writes that
    /// originate in the detail view are tracked separately, in the shared
    /// `AppState.pendingFlagWriteUIDs` (its write lifecycle lives in the detail
    /// view model); `shieldFetched` consults both.
    var pendingFlagUIDs: Set<UInt32> = []

    /// Rows mid-disposal animation, keyed by UID. A disposed row stays in
    /// `envelopes` while it fades and then collapses (see `beginRowDisposal`
    /// in `+Optimistic`), so the list closes the gap visibly instead of
    /// instantaneously. Empty except during those ~300ms.
    var rowDisposalPhases: [UInt32: RowDisposalPhase] = [:]

    /// Generation of each replaced slot of the virtualized list, keyed by
    /// absolute index; an absent index is generation 0. Part of the row's
    /// identity (`MessageListSlot`), so a bump gives that slot a new row --
    /// see `replaceRows(showing:)` in `+RowReplacement`.
    var slotGenerations: [Int: Int] = [:]
    /// The same for the filtered / search list, whose rows are keyed by
    /// message (`MessageRowIdentity`) rather than by slot.
    var rowGenerations: [UInt32: Int] = [:]

    init(scope: MessageListScope, client: CabalmailClient, preferences: Preferences, appState: AppState) {
        self.scope = scope
        self.folder = scope.folder
        self.client = client
        self.preferences = preferences
        self.appState = appState
    }

    /// Start the watcher-driven auto-refresh loop. Called from the view's
    /// `.task` after `loadInitial()` settles. The watcher runs on its own
    /// actor and emits `.changed` whenever a folder-status poll shows an
    /// arrival (`UIDNEXT` advanced) or a removal (the count dropped); we
    /// collapse bursts to a single refresh by gating on elapsed time, since
    /// one poll can report both.
    func startWatching() async {
        // The global search surface has no anchor folder to watch.
        guard !isSearchScope, watcher == nil else { return }
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

    /// Tear down the watcher. View hooks this into `.onDisappear` so the
    /// status polling stops when the list isn't on screen — no API calls
    /// for a mailbox the user isn't looking at.
    func stopWatching() async {
        watcherTask?.cancel()
        watcherTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadPrevTask?.cancel()
        loadPrevTask = nil
        loadWindowTask?.cancel()
        loadWindowTask = nil
        persistTask?.cancel()
        persistTask = nil
        keyScrollTask?.cancel()
        keyScrollTask = nil
        bottomPrefetchTask?.cancel()
        bottomPrefetchTask = nil
        await watcher?.stop()
        watcher = nil
    }

    private func handleWatcherChanged() async {
        // Coalesce bursts: one status poll can report both an arrival and a
        // removal, and one refresh covers both.
        let now = Date()
        guard now.timeIntervalSince(lastRefreshFromWatcher) > 1 else { return }
        lastRefreshFromWatcher = now
        await refresh()
    }

    /// `prefetched` is a STATUS already asked for, with when it was asked:
    /// `hardReload` and `setSort` check the server with one before dropping
    /// the list, and it is used rather than asked for again.
    func refresh(prefetched: PrefetchedStatus? = nil) async {
        // Re-route while a search is showing — pull-to-refresh and the
        // watcher / 60-second background refreshes shouldn't silently wipe
        // active search results back to the folder view. Re-running the
        // search keeps the result set fresh against any concurrent
        // mailbox churn.
        if isSearchActive {
            await runSearch(resetFilterTab: false, preserveDepth: true)
            return
        }
        // Search scope with no active search has nothing to refresh — and no
        // real folder to STATUS. A background/pull refresh here would query the
        // sentinel path; bail instead.
        if isSearchScope { return }
        isLoading = true
        defer { finishRefresh() }
        let startedAt = prefetched?.askedAt ?? ContinuousClock.now
        var generation = alignment.generation
        do {
            // flagged: true asks for the SEARCH FLAGGED count too -- this is the
            // one status call that drives the filter-pill counts.
            let status: FolderStatus
            if let prefetched {
                status = prefetched.status
            } else {
                status = try await client.folderStatus(path: folder.path, flagged: true)
            }
            let uidNext = status.uidNext ?? 1
            // Only a concrete, *changed* UIDVALIDITY means "rebuild from
            // scratch." A missing/zero reading from a flaky STATUS must not
            // wipe a scrolled, paginated list back to the top page on a
            // routine background refresh.
            if let fresh = status.uidValidity, fresh != 0 {
                if let known = self.uidValidity, known != fresh {
                    try? await client.envelopeCache.invalidate(folder: folder.path)
                    try? await client.bodyCache.invalidate(folder: folder.path)
                    envelopes = []
                    resetWindow()
                    appState.clearConfirmedRemovals(folderPath: folder.path)
                    generation = alignment.generation
                }
                self.uidValidity = fresh
            }
            let uidValidity = self.uidValidity ?? 0
            // Top page uses sequence-number FETCH via `topEnvelopes` (robust on
            // sparse folders); `performLoadMore` loads older pages positionally
            // by offset. `totalMessages` from STATUS gates pagination.
            // STATUS drives the All/Unread/Flagged pill counts and the
            // pagination gate; helper lives in +Refresh to keep this body lean.
            let mayPredate = removalMayPostdate(startedAt)
            let messages = applyStatusCounts(status, mayPredateRemoval: mayPredate)
            let reading = windowReading(status, askedAt: startedAt,
                                        mayPredateRemoval: mayPredate, generation: generation)
            // Whether the loaded rows still sit where the server has them
            // decides what comes next: usually the top page, as always.
            try await refreshWindow(reading, messages: messages, uidNext: uidNext,
                                    uidValidity: uidValidity,
                                    serverReportsEmpty: status.messages == 0)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Index-driven window loader. A row (real or placeholder) at
    /// `absoluteIndex` appeared, so ensure the loaded window covers it. Near
    /// an edge it extends incrementally via `performLoadMore` /
    /// `performLoadPrevious` (cheap: one page + a trim of the far side); a far
    /// jump (the user dragged the scrollbar into an unloaded region) reloads a
    /// fresh window centered there. Replaces the old envelope-keyed
    /// loadMore/loadPrevious triggers: because the list's `ForEach` spans the
    /// full stable index range, shifting/trimming the backing window only
    /// changes which indices hold data -- it never restructures the list, so
    /// there's no jump and no trim-retrigger thrash. The fetches run on
    /// model-owned tasks so they outlive the row `.task`'s cancellation.
    func ensureLoaded(around absoluteIndex: Int) {
        guard !isSearchActive, pendingRemovedUIDs.isEmpty, !alignment.isReconciling,
              !isLoading, !isLoadingMore, !isLoadingPrevious, !isLoadingWindow
              else { return }
        let windowLo = Int(windowStart)
        let windowHi = windowLo + envelopes.count   // exclusive
        let prefetch = Int(prefetchDistance)
        let total = Int(totalMessages)
        if absoluteIndex >= windowLo - prefetch && absoluteIndex <= windowHi + prefetch {
            // Near or inside the window: extend toward the approached edge.
            if absoluteIndex >= windowHi - prefetch, windowHi < total {
                isLoadingMore = true
                loadMoreTask = Task { [weak self] in await self?.performLoadMore() }
            } else if absoluteIndex <= windowLo + prefetch, windowLo > 0 {
                isLoadingPrevious = true
                loadPrevTask = Task { [weak self] in await self?.performLoadPrevious() }
            }
        } else {
            // Far jump: replace the window with one centered on the target.
            isLoadingWindow = true
            loadWindowTask = Task { [weak self] in await self?.performLoadWindow(around: absoluteIndex) }
        }
    }

    /// Fetches and merges the next positional page. Always invoked from
    /// `loadMoreTask` (see `ensureLoaded(around:)`) so it outlives the
    /// triggering row's `.task` cancellation. Resets `isLoadingMore` on every
    /// exit, including cancellation, via `defer`.
    private func performLoadMore() async {
        defer { isLoadingMore = false }
        do {
            // Positional page in the current sort order. `mergeFetched`
            // dedups, so a shifted offset (a concurrent removal) can't
            // double-insert. The offset is absolute: the window's front may
            // have been trimmed, so the next page starts past everything ever
            // loaded (`windowStart` + the rows still in memory), not at
            // `envelopes.count`.
            let offset = windowStart + UInt32(envelopes.count)
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                offset: offset,
                limit: loadMorePageSize,
                sort: sortCriterion
            )
            mergeFetched(fetched)
            // Trim the scrolled-past front so the loaded window stays bounded
            // (see `windowCap`). loadMore only fires near the bottom (within
            // `prefetchDistance`), so the last `windowCap` rows always cover
            // the viewport, the runway below it, and a scroll-back buffer
            // above; `removeFirst` drops the newest rows the user scrolled up
            // and away from under the default newest-first sort. Spacer
            // virtualization (the list reserves the off-window rows as blank
            // cells) keeps each loaded row at its absolute position, so the
            // viewport doesn't move across the removal.
            if envelopes.count > windowCap {
                let overflow = envelopes.count - windowCap
                envelopes.removeFirst(overflow)
                windowStart += UInt32(overflow)
                hasTrimmedFront = true
            }
            // Done when the page comes back empty or the absolute bottom of
            // the window reaches the folder's STATUS total.
            hasMore = !fetched.isEmpty && (windowStart + UInt32(envelopes.count)) < totalMessages
            // Persist is debounced: rewriting the whole on-disk snapshot is
            // O(loaded count) and, awaited here on every page, put a growing
            // write (~0.7s at 800 rows, ~1.5s at 1500) on the pagination
            // critical path while `isLoadingMore` was held -- so deep
            // scrolling fell further behind the longer it ran. The snapshot
            // is a warm-reopen cache, not source of truth, so coalescing the
            // writes to once the scroll settles is safe: a kill mid-scroll
            // just re-paginates from the last flush.
            schedulePersist()
        } catch {
            // Best-effort pagination — don't surface an error unless we're
            // blocked entirely.
        }
    }

    // `performLoadPrevious` -- the upward counterpart of `performLoadMore`
    // that reloads the trimmed front as the user scrolls back up -- lives in
    // `MessageListViewModel+Refresh.swift` alongside `mergeFetched`, to keep
    // this type body under SwiftLint's length cap.

    // Structured search (`runSearch`, `clearSearch`, `sourceFolder(for:)`,
    // and the query builder) lives in `MessageListViewModel+Search.swift`
    // so the primary type body stays under SwiftLint's length cap.

    // The per-row flag actions (`markRead`, `toggleSeen`, `toggleFlag`) live in
    // `MessageListViewModel+Flags.swift` to keep this type body under the cap.

    /// Cache cleanup after a successful move out of `folder`, reached through
    /// `confirmRemoval` so every removal path shares it without needing the
    /// private `uidValidity`. `EnvelopeCache.remove` already takes an array;
    /// `MessageBodyCache.remove` is per-uid so we loop.
    func pruneCachesAfter(move folder: String, uids: [UInt32]) async {
        guard let uidValidity, !uids.isEmpty else { return }
        // Messages just left this folder (a confirmed dispose / move / purge),
        // so a bottom window staged at the old positions is misaligned -- drop
        // it. The in-flight removal already blocks adoption via `ensureLoaded`'s
        // `pendingRemovedUIDs` gate; this covers the window after it clears.
        invalidateBottomPrefetch()
        try? await client.envelopeCache.remove(uids: uids, folder: folder)
        for uid in uids {
            await client.bodyCache.remove(
                folder: folder,
                uidValidity: uidValidity,
                uid: uid
            )
        }
    }

}

// MARK: - Internals

// Lifted into an extension so the primary type body stays under SwiftLint's
// 250-line cap. Same-file extension — all helpers remain file-private to
// the view model.
extension MessageListViewModel {
    /// The currently-configured dispose action, exposed so the view can
    /// render the right swipe-action label and icon without reaching into
    /// the preferences environment itself.
    var disposeAction: DisposeAction { preferences.disposeAction }

    /// The swipe bindings, exposed for the same reason: the row picks the
    /// spec each edge reveals from these.
    var swipeLeading: MailSwipeAction { preferences.swipeLeading }
    var swipeTrailing: MailSwipeAction { preferences.swipeTrailing }

    /// The user's custom-flag palette, exposed for the row chips and the
    /// Flags picker menu (same narrow-accessor rationale as
    /// `disposeAction`).
    var flagPalette: [FlagPaletteEntry] { preferences.flagPalette }

    /// True when this is the global search surface (no anchor folder).
    var isSearchScope: Bool { scope.isSearch }

    /// Convenience for the folder path — the overwhelming majority of call
    /// sites. Equivalent to `init(scope: .folder(folder), ...)`.
    convenience init(folder: Folder, client: CabalmailClient, preferences: Preferences, appState: AppState) {
        self.init(scope: .folder(folder), client: client, preferences: preferences, appState: appState)
    }

    /// Drop a UID from the in-memory envelope list after it was disposed
    /// elsewhere (currently: the detail-view archive button). The detail
    /// view model already pruned the envelope + body caches; this only
    /// touches the list's in-memory copy so the row disappears immediately
    /// without a server round trip.
    func pruneEnvelope(uid: UInt32) {
        if readerFailedUIDs.remove(uid) != nil { return }
        let removedIndex = envelopes.firstIndex { $0.uid == uid }
        let removed = removedIndex.map { envelopes[$0] }
        if let removed, let removedIndex {
            stashForReaderRevert(removed, at: removedIndex)
        }
        let loadedBefore = envelopes.count
        envelopes.removeAll { $0.uid == uid }
        // Only adjust when a row really left the window: a signal for a UID
        // we never had loaded says nothing reliable about the folder total.
        adjustTotalMessages(by: envelopes.count - loadedBefore)
        // Same for the Unread pill, which otherwise only moves on a flag flip
        // against a loaded row: the reader's dispose folds the `\Seen` marking
        // into the move server-side, and its flag signal reaches the list in
        // the same render pass as this prune -- once the row is gone
        // `applyOptimisticFlag` no-ops, so the count keeps counting a message
        // that left the folder. Adjusting on the row that actually departed
        // holds whichever order the two signals arrive in: if the flag signal
        // wins the race the row is already `\Seen` here and this is a no-op.
        if let removed, !removed.flags.contains(.seen) {
            unseen = max(0, unseen - 1)
        }
        // The folder lost a row (detail-view dispose, no cache-prune round
        // trip), so a staged bottom window may no longer line up -- drop it.
        invalidateBottomPrefetch()
    }

    /// Apply a flag toggle that originated outside the list (currently: the
    /// detail view's Mark-as-read toggle). Updates the in-memory envelope so
    /// the row's bold styling and unread dot match the new state without
    /// waiting for a refresh. No-op when the UID isn't currently in the
    /// window.
    func applyFlagChange(uid: UInt32, flag: Flag, added: Bool) {
        applyOptimisticFlag(uid: uid, flag: flag, add: added)
    }

    // Internal so `loadInitial` in the `+Refresh` sibling can reach it.
    func hydrateFromCache() async {
        if let snapshot = await client.envelopeCache.snapshot(for: folder.path) {
            uidValidity = snapshot.uidValidity
            envelopes = snapshot.envelopes.values.sorted(by: envelopeOrder)
            // Nothing says where these rows sit on the server now; the
            // refresh that follows decides (`planWindow`).
            forgetWindowAnchor()
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

    /// Coalesces envelope-snapshot writes during pagination. Each loaded page
    /// reschedules the write ~1s out, so a continuous scroll persists once
    /// when it settles rather than O(loaded count) on every page's critical
    /// path. `stopWatching()` cancels a pending write when the list goes away.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.persistLoadedPages()
        }
    }

    /// Writes the current in-memory window to the on-disk snapshot. Invoked
    /// only from the debounce, never on the per-page path. Skipped once the
    /// front has been trimmed: the snapshot is a warm-reopen cache and must
    /// stay top-anchored so a relaunch lands at the top of the folder, not
    /// mid-scroll. The cache therefore holds up to the first `windowCap` rows.
    private func persistLoadedPages() async {
        guard !hasTrimmedFront,
              let uidValidity, let uidNext = envelopes.map(\.uid).max() else { return }
        try? await persistCache(uidValidity: uidValidity, uidNext: uidNext + 1)
    }

    /// Resets the sliding-window cursor to a fresh top-anchored state. Called
    /// by every path that wipes `envelopes` (hard reload, sort change, search
    /// clear, UIDVALIDITY change) so the next load starts at the top of the
    /// folder and the top-page refresh / persist resume.
    func resetWindow() {
        windowStart = 0
        hasTrimmedFront = false
        forgetWindowAnchor()
        // A wiped / re-anchored window (hard reload, sort change, search clear,
        // UIDVALIDITY change) invalidates any staged bottom window with it.
        invalidateBottomPrefetch()
    }
}
