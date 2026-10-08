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
/// paginated `/list_messages` (large-mailbox plan Layer 3.1). Where the
/// window ends against the STATUS total, and whether a page there came back
/// empty, decide `hasMore`, so sparse folders no longer dead-end (Layer
/// 3.3). The envelope cache stores everything keyed by `UIDVALIDITY` so
/// reopen is instant while the refresh runs in the background.
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
    /// The session's shared mail state: the folder counts this list keeps
    /// the sidebar's in step with, and the shields its merges honour.
    let mailStore: MailSessionStore
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
    /// A refresh, a reset or a search is in flight: the list's spinner, the
    /// Refresh button's disabled state, and the gate that keeps page loads
    /// out meanwhile. It falls only once the last of them has returned
    /// (`holdLoading()`), so an overlapping one can't lower it for another.
    private(set) var isLoading = false
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

    /// The rows the user has selected: on wide layouts every selection
    /// (one row opens the reader), on touch layouts the Select mode's
    /// checkboxes. Keyed by `MessageRef`, so of two search rows that share a
    /// UID exactly the one picked is selected, and every action on the
    /// selection reaches exactly the messages in it.
    var selectedRefs: Set<MessageRef> = []

    /// Anchor row for range selection: the fixed pivot a shift-click or
    /// shift-arrow extends from -- the last row plainly selected or
    /// command-clicked. Settable only through `setSelectionAnchor(_:)`, so
    /// it cannot drift out of step with `selectionRangeBase`.
    private(set) var selectionAnchor: MessageRef?

    /// The selection a range operation extends *from*: whatever was selected
    /// at the moment `selectionAnchor` was pinned.
    ///
    /// A shift-click unions its span onto this rather than replacing the
    /// selection, which is how rows picked with command outside the span
    /// survive (#1768). It is never written on its own -- a base left over
    /// from an earlier anchor would resurrect rows the user has since
    /// dropped -- which is what `setSelectionAnchor(_:)` enforces.
    private(set) var selectionRangeBase: Set<MessageRef> = []

    /// Pin the pivot for range selection, recording the selection it starts
    /// from. The anchor and its base always move together.
    func setSelectionAnchor(_ ref: MessageRef?) {
        selectionAnchor = ref
        selectionRangeBase = selectedRefs
    }

    /// The moving end of a keyboard range selection (the row a plain arrow
    /// last landed on, or a shift-arrow last extended to). Distinct from the
    /// anchor so shift-arrow grows/shrinks the range from the right end rather
    /// than collapsing it. Plain selection sets cursor == anchor.
    var selectionCursor: MessageRef?

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

    /// The folder's UIDVALIDITY, from the last STATUS or the cache snapshot.
    /// Nil until one answers, and always in `.search` scope, which has no
    /// folder. Readable so the sibling extensions can stamp it onto the refs
    /// they build for this folder's rows (`rowRef(for:)`).
    private(set) var uidValidity: UInt32?
    // Folder message count from the last STATUS. Pagination loads until the
    // loaded envelope count reaches it. Internal so the +Refresh sibling
    // extension can read it after a page merge to recompute `hasMore`.
    var totalMessages: UInt32 = 0 {
        // A folder whose count moved may hold rows below the window again.
        didSet { if totalMessages != oldValue { hasMore = true } }
    }
    // The Unread and Flagged pill counts (`unseen`, `flagged`) are the mail
    // store's counts for this folder, the same numbers the sidebar shows; see
    // `+Refresh`. `totalMessages` is the All count.
    /// The All pill's count until a STATUS answers this session: the folder
    /// total last saved (`seedSavedCounts`). Kept apart from `totalMessages`,
    /// which also sizes the list, where a total nothing can load offline
    /// would draw placeholder rows.
    var savedMessageCount: Int?
    /// Whether a page below the window may still hold rows; `ensureLoaded`
    /// asks for one only while it is set. A page that comes back empty clears
    /// it, so a STATUS that over-counts isn't asked for the same empty page by
    /// every row that appears (#1823). Only a change to `totalMessages`, a
    /// move of the window's end, or a reset sets it again
    /// (`recomputeHasMore(windowEndBefore:)`).
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
    /// The refresh passes in flight and the refreshes parked on them.
    @ObservationIgnored var refreshFlight = RefreshFlight()
    /// The refreshes, resets and searches holding `isLoading` up.
    @ObservationIgnored private var loadingHolds = 0

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
    private(set) var persistTask: Task<Void, Never>?
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

    // A refresh dispatched just before a write lands returns the row's
    // pre-write server state; applying it verbatim would resurrect a row
    // just moved or revert a flag just toggled. Every write, this list's or
    // anyone's, is bracketed in the mail store's one record
    // (`MessageShields`), which `shieldFetched`, the refresh's STATUS bounds
    // and the paging gate ask.

    /// The removals in flight that touch this list: its folder's, from any
    /// writer, or on the search surface any. It includes, on the dispose
    /// path, the few hundred milliseconds where the row is still present but
    /// animating out (`rowDisposalPhases`). Paging waits while it is
    /// non-empty, since a removal moves every row below it up a place.
    var pendingRemovedRefs: Set<MessageRef> {
        let removing = mailStore.shields.pendingMoveRefs
        return isSearchScope ? removing : removing.filter { $0.folder == folder.path }
    }

    /// Rows `pruneEnvelope(_:)` took out for a dispose / move / purge made by
    /// the reader or another list that is still in flight, with the index
    /// each held, so a failed server write can put the row back
    /// (`restorePrunedEnvelope`). The rows are this list's own (rows stay in
    /// each list); whether their removal is still in flight is the record's.
    /// Only in-flight removals are kept, so it holds a handful at most. (The
    /// name predates the other lists' removals reaching this list.)
    @ObservationIgnored var readerPrunedEnvelopes: [MessageRef: (envelope: Envelope, index: Int)] = [:]
    /// Removals whose failure reached this list while it still had the row:
    /// the next prune of the message is skipped if no removal is in flight
    /// behind it. See `pruneEnvelope(_:)`.
    @ObservationIgnored var readerFailedRefs: Set<MessageRef> = []

    /// Rows mid-disposal animation. A disposed row stays in `envelopes`
    /// while it fades and then collapses (see `beginRowDisposal` in
    /// `+Optimistic`), so the list closes the gap visibly instead of
    /// instantaneously. Empty except during those ~300ms.
    var rowDisposalPhases: [MessageRef: RowDisposalPhase] = [:]

    /// Generation of each replaced slot of the virtualized list, keyed by
    /// absolute index; an absent index is generation 0. Part of the row's
    /// identity (`MessageListSlot`), so a bump gives that slot a new row --
    /// see `replaceRows(showing:)` in `+RowReplacement`.
    var slotGenerations: [Int: Int] = [:]
    /// The same for the filtered / search list, whose rows are keyed by
    /// message (`MessageRowIdentity`) rather than by slot.
    var rowGenerations: [MessageRef: Int] = [:]

    /// What the mail events this list heard ask of its selection, for its
    /// view to apply (`receive(_:)`, `MailEventSelectionPolicy`).
    let selectionReactions = ListSelectionReactions()

    init(scope: MessageListScope, client: CabalmailClient, preferences: Preferences, mailStore: MailSessionStore) {
        self.scope = scope
        self.folder = scope.folder
        self.client = client
        self.preferences = preferences
        self.mailStore = mailStore
        // For the model's whole life, not the view's: a list under a pushed
        // reader has had `.onDisappear` and still has to hear its archive.
        mailStore.events.subscribe(self)
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
        // Let go of the watcher before waiting for it to stop, so a list back
        // on screen in the meantime starts a fresh one (`startWatching`).
        let stopping = watcher
        watcher = nil
        await stopping?.stop()
    }

    private func handleWatcherChanged() async {
        // Coalesce bursts: one status poll can report both an arrival and a
        // removal, and one refresh covers both.
        let now = Date()
        guard now.timeIntervalSince(lastRefreshFromWatcher) > 1 else { return }
        lastRefreshFromWatcher = now
        await refresh()
    }

    /// Brings the list up to date with the server: the folder's STATUS and
    /// the window work it calls for, or, while a search is showing, that
    /// search again.
    ///
    /// Single-flight (#1820, `RefreshFlight`): a refresh asked for while a
    /// pass is out waits for it, then for one more pass that asks STATUS
    /// afresh and answers every refresh that waited. `isLoading` stays up
    /// until the last of them returns. `prefetched` is a STATUS already asked
    /// for, with when it was asked, used rather than asked for again unless
    /// the refresh had to wait. `startingOver` marks a reset's refresh
    /// (`hardReload`, `setSort`, leaving a search), which runs at once: the
    /// reset has already stood down whatever the pass out was for.
    func refresh(prefetched: PrefetchedStatus? = nil, startingOver: Bool = false) async {
        // Re-route while a search is showing — pull-to-refresh and the
        // watcher / 60-second background refreshes shouldn't silently wipe
        // active search results back to the folder view. Re-running the
        // search keeps the result set fresh against any concurrent
        // mailbox churn.
        if isSearchActive {
            await refreshSearch(prefetched: prefetched)
            return
        }
        // Search scope with no active search has nothing to refresh — and no
        // real folder to STATUS. A background/pull refresh here would query the
        // sentinel path; bail instead.
        if isSearchScope { return }
        holdLoading()
        defer { releaseLoading() }
        let ask = prefetched?.ask ?? refreshFlight.ask()
        var status = prefetched
        var supersede = startingOver
        // A cancelled caller stops asking; a search that starts meanwhile
        // makes the folder's refresh moot.
        while !refreshFlight.hasAnswered(ask), !Task.isCancelled, !isSearchActive {
            if refreshFlight.current != nil, !supersede {
                await withCheckedContinuation { refreshFlight.park($0) }
                status = nil
                continue
            }
            let pass = refreshFlight.begin(answeringThrough: status?.ask)
            await refreshPass(prefetched: status)
            for waiter in refreshFlight.end(pass, finished: !Task.isCancelled) {
                waiter.resume()
            }
            supersede = false
            status = nil
        }
    }

    /// One refresh pass: STATUS (or the one prefetched), the counts, then the
    /// window. A reset or a search that starts while one of its awaits is
    /// out moves the window's generation, and the pass then leaves the list
    /// to it (#1870).
    private func refreshPass(prefetched: PrefetchedStatus?) async {
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
                guard generation == alignment.generation else { return }
            }
            // Only a concrete, *changed* UIDVALIDITY means "rebuild from
            // scratch." A missing/zero reading from a flaky STATUS must not
            // wipe a scrolled, paginated list back to the top page on a
            // routine background refresh.
            if let fresh = status.uidValidity, fresh != 0 {
                if let known = self.uidValidity, known != fresh {
                    try? await client.envelopeCache.invalidate(folder: folder.path)
                    try? await client.bodyCache.invalidate(folder: folder.path)
                    guard generation == alignment.generation else { return }
                    envelopes = []
                    resetWindow()
                    mailStore.shields.clearConfirmedRemovals(folderPath: folder.path)
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
            _ = applyStatusCounts(status, mayPredateRemoval: mayPredate, askedAt: startedAt)
            let reading = windowReading(status, askedAt: startedAt,
                                        mayPredateRemoval: mayPredate, generation: generation)
            // Whether the loaded rows still sit where the server has them
            // decides what comes next: usually the top page, as always.
            try await refreshWindow(reading, status: status, generation: generation, uidValidity: uidValidity)
            errorMessage = nil
        } catch {
            // A refresh whose task was cancelled (the 60-second poll's, the
            // watcher's, when the list leaves the screen) has nothing to
            // report; "cancelled" would stay on a list that is fine (#1816).
            guard !Task.isCancelled else { return }
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
        guard !isSearchActive, pendingRemovedRefs.isEmpty, !alignment.isReconciling,
              !isLoading, !isLoadingMore, !isLoadingPrevious, !isLoadingWindow
              else { return }
        let windowLo = Int(windowStart)
        let windowHi = windowLo + envelopes.count   // exclusive
        let prefetch = Int(prefetchDistance)
        if absoluteIndex >= windowLo - prefetch && absoluteIndex <= windowHi + prefetch {
            // Near or inside the window: extend toward the approached edge.
            // A fresh jump window is shorter than the runway, so an index can
            // be in reach of both; the nearer edge goes first (#1823).
            let below = absoluteIndex >= windowHi - prefetch && hasMore && windowHi < Int(totalMessages)
            let above = absoluteIndex <= windowLo + prefetch && windowLo > 0
            if below, !above || windowHi - 1 - absoluteIndex <= absoluteIndex - windowLo {
                isLoadingMore = true
                loadMoreTask = Task { [weak self] in await self?.performLoadMore() }
            } else if above {
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
        let generation = alignment.generation
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
            // A reset or a search that started while the page was out has
            // replaced the rows it was addressed to (#1870).
            guard generation == alignment.generation else { return }
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

    // Structured search (`runSearch`, `clearSearch`, and the query builder) lives in `MessageListViewModel+Search.swift`
    // so the primary type body stays under SwiftLint's length cap.

    // The per-row flag actions (`markRead`, `toggleSeen`, `toggleFlag`) live in
    // `MessageListViewModel+Flags.swift` to keep this type body under the cap.

    /// Messages this list removed are confirmed gone on the server (a
    /// dispose, move or purge landed; the mutation service has already
    /// forgotten them in the offline caches), so a bottom window staged at
    /// the old positions is misaligned -- drop it. The in-flight removal
    /// already blocks adoption via `ensureLoaded`'s `pendingRemovedRefs`
    /// gate; this covers the window after it clears.
    func removalsConfirmed() {
        invalidateBottomPrefetch()
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
    convenience init(folder: Folder, client: CabalmailClient, preferences: Preferences, mailStore: MailSessionStore) {
        self.init(scope: .folder(folder), client: client, preferences: preferences, mailStore: mailStore)
    }

    /// Drop a message's row from the in-memory envelope list after it was
    /// disposed elsewhere (a `.removed` event: the reader's or another list's
    /// archive, move or purge, or a send from Drafts). The mutation service
    /// forgets the message in the offline caches once the server confirms;
    /// this only touches the list's in-memory copy so the row disappears
    /// immediately without a server round trip.
    ///
    /// A failure that reached this list while it still had the row (it was
    /// built while the removal was out) is remembered in `readerFailedRefs`,
    /// and swallows the next prune of that message if no removal is in
    /// flight behind it -- including a compose session's send from Drafts,
    /// which isn't recorded. It is spent on that next prune either way, so a
    /// removal made through the mutation service goes ahead.
    ///
    /// `originalIndex` is where the row was before the removal that names it
    /// pruned any of its other rows (`applyRemoval`), kept for a revert.
    func pruneEnvelope(_ ref: MessageRef, from originalIndex: Int? = nil) {
        if readerFailedRefs.remove(ref) != nil, !mailStore.shields.isRemoving(ref) { return }
        let removedIndex = index(of: ref)
        let removed = removedIndex.map { envelopes[$0] }
        if let removed, let removedIndex {
            stashForReaderRevert(removed, at: originalIndex ?? removedIndex)
        }
        let loadedBefore = envelopes.count
        if let removedIndex { envelopes.remove(at: removedIndex) }
        // Only adjust when a row really left the window: an event for a
        // message we never had loaded says nothing reliable about the folder
        // total.
        adjustTotalMessages(by: envelopes.count - loadedBefore)
        // The folder lost a row (a removal made elsewhere), so a staged
        // bottom window may no longer line up -- drop it.
        invalidateBottomPrefetch()
    }

    /// Apply a flag toggle that originated outside the list (a
    /// `.flagsChanged` event: the reader's toggles, another list's, a
    /// reply's `\Answered`).
    /// Updates the in-memory envelope so the row's bold styling and unread
    /// dot match the new state without waiting for a refresh. No-op when the
    /// message isn't currently in the window; matched by the row's ref, so
    /// on the search surface it reaches whichever row names the message
    /// (#1859).
    func applyFlagChange(_ ref: MessageRef, flag: Flag, added: Bool) {
        applyOptimisticFlag(ref, flag: flag, add: added)
    }

    /// The identity of `envelope`'s row. Every row this model loads carries
    /// its folder (`placedInFolder(_:)`, and `SearchedEnvelope` for search
    /// rows); one that doesn't is taken to be this folder's.
    func rowRef(for envelope: Envelope) -> MessageRef {
        envelope.ref(defaultFolder: folder.path, uidValidity: uidValidity)
    }

    /// Position of `ref`'s row in `envelopes`, while it is loaded.
    func index(of ref: MessageRef) -> Int? {
        envelopes.firstIndex { rowRef(for: $0) == ref }
    }

    /// The loaded row for `ref`.
    func envelope(for ref: MessageRef) -> Envelope? {
        index(of: ref).map { envelopes[$0] }
    }

    /// `fetched`, a page of this folder's rows, placed in this folder so each
    /// row names its own message. Every folder-mode path that brings rows
    /// into `envelopes` goes through this (or through `shieldFetched`, which
    /// calls it).
    func placedInFolder(_ fetched: [Envelope]) -> [Envelope] {
        fetched.map { $0.folder == nil ? $0.inFolder(folder.path) : $0 }
    }

    // Internal so `loadInitial` in the `+Refresh` sibling can reach it.
    func hydrateFromCache() async {
        if let snapshot = await client.envelopeCache.snapshot(for: folder.path) {
            uidValidity = snapshot.uidValidity
            envelopes = placedInFolder(Array(snapshot.envelopes.values)).sorted(by: envelopeOrder)
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
    /// Search results are never the folder's snapshot, whatever was due to
    /// be written when the search started (#1870).
    private func persistLoadedPages() async {
        guard !hasTrimmedFront, !isSearchActive,
              let uidValidity, let uidNext = envelopes.map(\.uid).max() else { return }
        try? await persistCache(uidValidity: uidValidity, uidNext: uidNext + 1)
    }

    /// Resets the sliding-window cursor to a fresh top-anchored state. Called
    /// by every path that wipes `envelopes` (hard reload, sort change, search
    /// clear, UIDVALIDITY change) so the next load starts at the top of the
    /// folder and the top-page refresh / persist resume.
    func resetWindow() {
        standDownWindowLoads()
        windowStart = 0
        hasTrimmedFront = false
        hasMore = true
        forgetWindowAnchor()
    }

    /// `hasMore` from where the window ends now, `windowEndBefore` being where
    /// it ended before the change. An empty page's verdict stands while the
    /// window's end hasn't moved (#1823); a change in `totalMessages` lifts it
    /// through its didSet, and a reset through `resetWindow()`.
    func recomputeHasMore(windowEndBefore: UInt32) {
        let windowEnd = windowStart + UInt32(envelopes.count)
        hasMore = windowEnd < totalMessages && (hasMore || windowEnd != windowEndBefore)
    }

    /// Stands down every load addressed to the rows on screen: the page
    /// loads are cancelled, the staged bottom window dropped, and the
    /// generation moved, so a page or a refresh pass that lands anyway drops
    /// what it brought (#1870). Every reset runs it, and so does a search, as
    /// it starts and as its rows replace the folder's.
    func standDownWindowLoads() {
        loadMoreTask?.cancel()
        loadPrevTask?.cancel()
        loadWindowTask?.cancel()
        invalidateBottomPrefetch()
        alignment.generation += 1
    }

    /// After a search that stood the window's loads down and then didn't take
    /// the list over (it failed, was cancelled, or another overtook it): what
    /// the viewport shows loads once `isLoading` falls, and the bottom window
    /// is staged again.
    func resumeWindowLoads() {
        guard !isSearchScope else { return }
        alignment.needsSettleLoad = true
        scheduleBottomPrefetch()
    }

    /// Holds `isLoading` up for a refresh, a reset or a search until the
    /// matching `releaseLoading()`. The last release lowers it, and loads
    /// what the viewport shows without rows (`needsSettleLoad`).
    func holdLoading() {
        loadingHolds += 1
        isLoading = true
    }

    func releaseLoading() {
        loadingHolds -= 1
        guard loadingHolds == 0 else { return }
        isLoading = false
        if alignment.needsSettleLoad {
            alignment.needsSettleLoad = false
            scheduleEnsureLoaded()
        }
    }
}

// MARK: - Mail events

// The list's half of the mail store's events (`MailEvents`): what the reader,
// the composer and other lists changed, matched against this list's own rows
// by ref (its own writes aren't sent back to it). A
// folder list's rows all carry its folder; the search surface's come from
// many, and an event reaches whichever of them it names (#1877). Whatever
// the selection should do about one is queued for the view, which owns the
// selection on compact layouts (`selectionReactions`).
extension MessageListViewModel: MailEventSubscriber {
    func receive(_ event: MailEvent) {
        switch event.change {
        case .removed(let refs):
            applyRemoval(of: refs, from: event.origin, advancing: event.advances)
        case .restored(let ref, let markUnread):
            // The selection stays where the removal's advance left it, as
            // with a failed swipe.
            restorePrunedEnvelope(ref, markUnread: markUnread)
        case .flagsChanged(let refs, let flag, let added):
            for ref in refs {
                applyFlagChange(ref, flag: flag, added: added)
            }
        case .draftReplaced(let folderPath, let replacement):
            applyDraftReplacement(replacement, in: folderPath, from: event.origin)
        case .readAdvance(let ref, let advance):
            // The row stays (it is only read now), so nothing is pruned.
            guard let current = envelope(for: ref) else { return }
            let next = markReadAdvanceTarget(after: current, following: advance)
            selectionReactions.append(ListSelectionReaction(
                kind: .readAdvance, rows: [ref], target: next.map(rowRef(for:)), origin: event.origin,
                advances: event.advances
            ))
        }
    }

    /// Drops the rows `refs` names. A folder list takes every ref in its
    /// folder, loaded or not, since one it never loaded still moved the rows
    /// a staged bottom window holds (`pruneEnvelope`); the search surface
    /// takes the rows it lists.
    ///
    /// A send from Drafts names every copy its compose session held (#1071);
    /// whichever of them this list loaded is the row on screen -- the first
    /// in list order, should it hold more than one -- so that's the one the
    /// advance walks from. The rest go first: they're stale copies of the
    /// same draft, and leaving one in place would let the advance walk onto
    /// a row that's about to disappear. The advance target is worked out
    /// before the row goes, since every advance policy walks from its index.
    func applyRemoval(of refs: [MessageRef], from origin: UUID?, advancing: Bool) {
        var seen = Set<MessageRef>()
        let named = refs.filter {
            (isSearchScope ? index(of: $0) != nil : $0.folder == folder.path) && seen.insert($0).inserted
        }
        guard !named.isEmpty else { return }
        let current = envelopes.first { seen.contains(rowRef(for: $0)) }
        let currentRef = current.map(rowRef(for:))
        // Where each row was before any of them left, for a revert.
        var before: [MessageRef: Int] = [:]
        for ref in named { before[ref] = index(of: ref) }
        for ref in named where ref != currentRef {
            pruneEnvelope(ref, from: before[ref])
        }
        let next = current.flatMap { advanceTarget(after: $0, following: preferences.disposeAdvance) }
        if let currentRef {
            pruneEnvelope(currentRef, from: before[currentRef])
        }
        selectionReactions.append(ListSelectionReaction(
            kind: .removal, rows: seen, target: next.map(rowRef(for:)), origin: origin, advances: advancing
        ))
    }

    /// Swaps this list -- and whatever reader it is driving -- from the
    /// Drafts copies a compose session just retired onto the one that
    /// survived.
    ///
    /// The prune is the easy half. The half that matters is the selection:
    /// the reader Save Draft returns to still holds the retired copy's
    /// fetched body, and Edit Draft from there seeds the pre-edit content
    /// and pins the send's discard to an expunged UID, so the edit is
    /// dropped and the saved copy orphaned (#1078). Re-pointing rebuilds
    /// the reader against the survivor (the detail column is keyed on the
    /// UID), which re-fetches and shows what was actually saved.
    ///
    /// The refresh comes first because the survivor landed under a UID this
    /// list has never seen. Nothing else surfaces it promptly: the watcher
    /// on an open folder has no real IDLE behind it, so it re-reads
    /// `folderStatus` every 30 s and the row arrives somewhere in that
    /// window (measured at t+5 s and t+32 s on two runs -- #1083).
    ///
    /// A first save is that refresh and nothing else: no retired UID to
    /// prune, and `DraftReplacementPolicy.resolve` reads an empty chain as
    /// `.ignore`, so whatever the user was reading is left where it was. The
    /// search surface acts only when it lists one of the retired copies, so
    /// a draft saved while results show doesn't re-run the search.
    func applyDraftReplacement(_ replacement: DraftReplacement, in folderPath: String, from origin: UUID?) {
        let retired = replacement.retiredUIDs.map { MessageRef(folder: folderPath, uid: $0) }
        if isSearchScope {
            guard retired.contains(where: { index(of: $0) != nil }) else { return }
        } else {
            guard folder.path == folderPath else { return }
        }
        for ref in retired {
            pruneEnvelope(ref)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh()
            let loadedUIDs = envelopes.map(rowRef(for:)).filter { $0.folder == folderPath }.map(\.uid)
            selectionReactions.append(ListSelectionReaction(
                kind: .draftReplacement(replacement, loadedUIDs: loadedUIDs),
                rows: Set(retired), target: nil, origin: origin
            ))
        }
    }
}

// MARK: - Window (bridge)

extension MessageListViewModel {
    /// Temporary: the folder window's state, reached as `model.window.…`.
    /// The next commit replaces this with the list's `FolderWindowLoader`;
    /// until then it is the list itself, so a receiver change can be shown
    /// to change nothing on its own.
    var window: MessageListViewModel { self }
}
