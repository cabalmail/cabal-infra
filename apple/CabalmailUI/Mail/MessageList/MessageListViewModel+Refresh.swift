import Foundation
import CabalmailKit

// Cache-merge helpers used by the refresh / loadMore paths. Pulled into
// a sibling extension so the main view-model file stays under SwiftLint's
// 400-line cap. Both helpers are internal so the sort-extension and the
// main file can call them; the cache-snapshot path (`hydrateFromCache`,
// `persistCache`) stays in the main file because the cache scope is
// intentionally narrow (`loadInitial` below is its one outside caller).
extension MessageListViewModel {
    /// First load for a freshly built model: the cached snapshot, then the
    /// folder refresh, then the folder's sticky pill.
    ///
    /// The pill applies from the first paint: `filterTab` is set before the
    /// cache hydrates so the cached rows are narrowed at once, and the
    /// pill's server search runs once the folder's STATUS has driven the
    /// pill counts -- the same two steps a tap performs (`selectFilter`).
    ///
    /// Unstructured, model-owned task, so a cancellation of the view's
    /// `.task` (SwiftUI fires it mid-push transition — same class as the
    /// detail view's #403) can't propagate into the first fetch. The view
    /// only runs this once per model, so a first load cut short there would
    /// end as `.cancelled`, silently, on an empty list with nothing left to
    /// retry it. Mirrors `refreshFromPull`.
    func loadInitial() async {
        guard envelopes.isEmpty else { return }
        let sticky = isSearchScope ? .all : preferences.mailFolderFilter(for: folder.path)
        filterTab = sticky
        await Task {
            await self.hydrateFromCache()
            await self.seedSavedCounts()
            await self.refresh()
            if sticky != .all { await self.applyFilter(sticky) }
        }.value
        scheduleBottomPrefetch()
    }

    /// Pull-to-refresh entry point. Runs `refresh()` on an unstructured,
    /// model-owned `Task` and awaits it, so a cancellation of SwiftUI's
    /// `.refreshable` task doesn't propagate into the in-flight request and
    /// cut the refresh short as `.cancelled`. The embedded per-row swipe `List`s
    /// inherit the outer `.refreshable`, and that scroll interaction was
    /// cancelling the pull task mid-fetch; an unstructured task is detached
    /// from that cancellation. Mirrors the pagination cancel-storm fix.
    func refreshFromPull() async {
        await Task { await self.refresh() }.value
    }

    /// Starts the pills from the counts the last successful STATUS saved,
    /// possibly in an earlier launch, so a list opened offline doesn't read 0
    /// over its cached rows. The Unread and Flagged counts are seeded into the
    /// mail store where it has none of its own yet (`MailCounts.seed`), so
    /// the sidebar shows them too and every change moves both; the All count
    /// goes to `savedMessageCount` rather than `totalMessages`. The first
    /// STATUS that answers replaces all three (`applyStatusCounts`).
    func seedSavedCounts() async {
        guard !isSearchScope, let saved = await client.savedFolderStatus(path: folder.path) else { return }
        savedMessageCount = saved.messages.map { max(0, $0) }
        guard mailStore.acceptsCounts(from: client) else { return }
        let counts = mailStore.counts
        if counts.seed(folderPath: folder.path, from: saved) {
            counts.savedFolderCounts.markSeeded(folder.path)
        }
        // While this list has the folder open, a live folder list arriving
        // mustn't blank its seeded counts; once it has gone, they go as any
        // other seeded badge.
        counts.savedFolderCounts.adopt(folder.path, by: self)
    }

    /// The All pill's folder count: the saved one until a STATUS answers.
    var allCount: Int { savedMessageCount ?? Int(totalMessages) }

    /// The Unread pill's count: the mail store's unread count for this
    /// folder, which the sidebar shows too, so the two are one number. None
    /// on the search surface, whose rows come from many folders. Setting it
    /// shows a count without vouching for it (`MailCounts.show`); nothing in
    /// the app does, since the mutation service moves the store's counts.
    var unseen: Int {
        get { isSearchScope ? 0 : mailStore.counts.folderUnreadCounts[folder.path] ?? 0 }
        set {
            guard !isSearchScope else { return }
            mailStore.counts.show(unread: newValue, folderPath: folder.path)
        }
    }

    /// The Flagged pill's count: the mail store's flagged count for this
    /// folder. As `unseen`.
    var flagged: Int {
        get { isSearchScope ? 0 : mailStore.counts.folderFlaggedCounts[folder.path] ?? 0 }
        set {
            guard !isSearchScope else { return }
            mailStore.counts.show(flagged: newValue, folderPath: folder.path)
        }
    }

    /// Capture the server-sourced counts from a STATUS reply: `totalMessages`
    /// (the All pill and the pagination gate) here, and the Unread/Flagged
    /// pill counts in the mail store, where the sidebar reads them too
    /// (`MailSessionStore.takeStatus`). Returns the server's own message
    /// total so `refresh()` can address the top-page fetch in the server's
    /// numbering. Lives here so the main view-model body stays under
    /// SwiftLint's type-body cap.
    ///
    /// `mayPredateRemoval` marks a reply that could have been taken before a
    /// removal this client already applied -- one still in flight, or one
    /// confirmed after the refresh began. Such a reply would count the
    /// departed message again, so it may lower the counts but not raise them
    /// (new mail waits for the next STATUS).
    ///
    /// `askedAt` is when the STATUS was asked for. A flag write in flight then,
    /// or since, may be missing from it: a mark-read still going out leaves
    /// the message counted unread. So the Unread and Flagged counts may move
    /// only the way those writes move them (`MessageShields.unreadBound`)
    /// rather than bounce back (#1880).
    func applyStatusCounts(
        _ status: FolderStatus,
        mayPredateRemoval: Bool = false,
        askedAt: ContinuousClock.Instant = .now
    ) -> UInt32 {
        let serverMessages = UInt32(max(0, status.messages ?? 0))
        var messages = serverMessages
        if mayPredateRemoval {
            messages = min(messages, totalMessages)
        }
        // A changed folder size shifts every absolute index, so a bottom window
        // staged against the old total is no longer aligned -- drop it (the
        // stamp check in `performLoadWindow` is the backstop for the window
        // between a mutation and the STATUS that reflects it).
        if messages != totalMessages { invalidateBottomPrefetch() }
        totalMessages = messages
        savedMessageCount = nil
        guard !isSearchScope else { return serverMessages }
        if mayPredateRemoval {
            mailStore.takeStatus(
                status, predatingRemovalIn: folder.path, askedAt: askedAt,
                shownTotal: Int(totalMessages), fetchedThrough: client
            )
        } else {
            mailStore.takeStatus(status, folderPath: folder.path, askedAt: askedAt, fetchedThrough: client)
        }
        return serverMessages
    }

    /// True when a STATUS or fetch issued at `startedAt` may have been
    /// answered from this folder as it stood before a removal the list has
    /// already applied: one is still in flight, from this list or any other
    /// writer, or the server confirmed one after `startedAt`.
    func removalMayPostdate(_ startedAt: ContinuousClock.Instant) -> Bool {
        !pendingRemovedRefs.isEmpty
            || mailStore.shields.removalConfirmed(folderPath: folder.path, after: startedAt)
    }

    /// Row onAppear: the list is now rendering this absolute index. A row
    /// appearing means the view scrolled, so (re)arm the settle backstop --
    /// once scrolling stops we load the now-visible window. This covers a
    /// scrollbar drag (or any jump) landing on placeholders while a stale page
    /// load is still in flight, where the row `.task`'s `ensureLoaded` would
    /// bail on the single-flight gate and leave the landing rows blank.
    func noteRowVisible(_ index: Int) {
        visibleRowIndices[index, default: 0] += 1
        scheduleEnsureLoaded()
    }

    /// Row onDisappear: a row at this absolute index left the rendered set.
    /// The index stays rendered while another row there still reports in.
    func noteRowHidden(_ index: Int) {
        guard let rows = visibleRowIndices[index] else { return }
        visibleRowIndices[index] = rows > 1 ? rows - 1 : nil
    }

    /// Lowest / highest absolute index the list is currently rendering, or nil
    /// before any row has reported in (empty folder, first paint).
    var firstVisibleRow: Int? { visibleRowIndices.keys.min() }
    var lastVisibleRow: Int? { visibleRowIndices.keys.max() }

    /// Debounced "load the window the list settled on" after a scroll/key jump.
    /// Resetting the task on each call (every row appear and every PgUp/PgDown)
    /// collapses a burst of scrolling into one load once it stops. It waits for
    /// any in-flight page load to finish first -- rather than racing a cancel
    /// against a second writer (the load funcs mutate without a cancellation
    /// guard) -- then drives `ensureLoaded` at the settled visible center, which
    /// the landing rows' `.task`s may have skipped while a load was in flight.
    /// loadWindow centers a full window there, so the visible rows plus a page
    /// above and below are fetched.
    func scheduleEnsureLoaded() {
        keyScrollTask?.cancel()
        keyScrollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(175))
            guard !Task.isCancelled, let self else { return }
            await self.loadMoreTask?.value
            await self.loadPrevTask?.value
            await self.loadWindowTask?.value
            guard !Task.isCancelled,
                  let first = self.firstVisibleRow,
                  let last = self.lastVisibleRow else { return }
            self.ensureLoaded(around: (first + last) / 2)
        }
    }

    /// User-initiated "force reload." Wipes the in-memory envelope list
    /// (plus the cursor state `refresh()` uses to merge older pages) AND
    /// the on-disk envelope snapshot for this folder, then runs
    /// `refresh()` to rebuild from scratch. Both the macOS
    /// `Mailbox > Refresh` menu item and the message-list toolbar's
    /// arrow.clockwise button route through this path so the user has a
    /// way to escape stale state (e.g., a search that populated the
    /// list with foreign-folder UIDs the regular refresh's UID-range
    /// pruning can't catch). The change watcher and the 60-second wall-
    /// clock fallback intentionally keep calling `refresh()` directly —
    /// they fire often, and the merge path is the cheap "fold new mail
    /// in" loop the cache is designed around. Hard reload stays on the
    /// manual paths the user explicitly invokes.
    ///
    /// Invalidating the on-disk snapshot here matters because a refresh
    /// prunes the snapshot only of rows it can prove gone: `applyRefreshPage`
    /// while the list still fits the top page, and a window re-read
    /// (`+Reconcile`) only within what it read. Foreign-
    /// folder UIDs that leaked into the cache (historically through
    /// pagination during search) sit in the paginated tail, so without an
    /// explicit invalidate they'd survive every subsequent refresh and re-
    /// hydrate as phantoms on relaunch. The body cache is left alone:
    /// it's keyed per-UID, never blindly batch-written, and an
    /// unrelated phantom never reached the fetch path far enough to
    /// land a body in it.
    func hardReload() async {
        // Search scope has no folder cache to wipe; a force-reload just re-runs
        // the active search (or no-ops when nothing is searched).
        if isSearchScope {
            if isSearchActive { await refreshSearch() }
            return
        }
        // The spinner holds from the probe through the refresh it hands to.
        holdLoading()
        defer { releaseLoading() }
        // Ask the server before dropping anything. Offline the wipe used to
        // run anyway: the list emptied, and with the snapshot went the
        // folder's rows for every later offline launch and its Spotlight
        // entries (#1796).
        guard let probe = await probeBeforeReset() else { return }
        try? await client.envelopeCache.invalidate(folder: folder.path)
        envelopes.removeAll()
        totalMessages = 0
        savedMessageCount = nil
        hasMore = true
        resetWindow()
        await refresh(prefetched: probe, startingOver: true)
    }

    /// A STATUS already asked for, and when, for `refresh(prefetched:)`.
    /// `ask` is the refresh ask numbered just before it was asked for, so the
    /// pass it seeds answers no refresh asked for after it (`RefreshFlight`).
    struct PrefetchedStatus {
        let status: FolderStatus
        let askedAt: ContinuousClock.Instant
        let ask: Int
    }

    /// Asks the server for this folder's STATUS before a reset that drops the
    /// list (`hardReload`, `setSort`). Nil, with the error shown, when it
    /// can't be reached: the caller then keeps the list as it is (#1796).
    /// The caller holds `isLoading` up from before the probe until its reset
    /// is done, so the list shows its spinner, the Refresh button stays
    /// disabled and no page loads in between.
    func probeBeforeReset() async -> PrefetchedStatus? {
        let ask = refreshFlight.ask()
        let askedAt = ContinuousClock.now
        do {
            let status = try await client.folderStatus(path: folder.path, flagged: true)
            return PrefetchedStatus(status: status, askedAt: askedAt, ask: ask)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Apply the in-flight-write shields to a freshly fetched page so a
    /// stale refresh can't undo an optimistic update. Rows we've
    /// optimistically removed (a move/dispose still settling, or one the
    /// server has confirmed but an older fetch may still carry) are dropped,
    /// and rows with an in-flight flag write keep their optimistic flags
    /// rather than the fetched (pre-toggle) ones. Both the in-memory merge
    /// and the cache persist run through this so memory and disk stay in
    /// agreement. The optimistic flags are read back from the current
    /// in-memory `envelopes`, which is where the write paths stash them.
    /// The page is this folder's, so its rows come back placed in it
    /// (`placedInFolder(_:)`).
    func shieldFetched(_ fetched: [Envelope]) -> [Envelope] {
        let confirmedGone = mailStore.shields.confirmedRemovalRefs(folderPath: folder.path)
        return placedInFolder(fetched).compactMap { fetchedEnvelope in
            let ref = rowRef(for: fetchedEnvelope)
            // A row being removed by anyone -- this list, another list, the
            // reader -- stays gone until the removal resolves, and after that
            // a message the server confirmed gone stays gone for good: IMAP
            // never reuses a UID within a mailbox, so a fetch that still
            // carries it was answered before the move landed.
            if mailStore.shields.isRemoving(ref) || confirmedGone.contains(ref) { return nil }
            // A flag write in flight from anyone shields the row's flags.
            if mailStore.shields.isWritingFlags(ref), let local = envelope(for: ref) {
                return rebuildEnvelope(fetchedEnvelope, flags: local.flags)
            }
            return fetchedEnvelope
        }
    }

    /// Merges a fresh fetch into the in-memory envelope dictionary and
    /// re-sorts using the active `sortCriterion`. Used by both the top-
    /// page refresh and the older-page paginator — neither needs to know
    /// which sort is active, only that "the visible list should now
    /// include these too." Shielded so an in-flight local write survives a
    /// concurrent refresh (see `shieldFetched`).
    func mergeFetched(_ fetched: [Envelope]) {
        var byRef: [MessageRef: Envelope] = Dictionary(
            uniqueKeysWithValues: envelopes.map { (rowRef(for: $0), $0) }
        )
        for envelope in shieldFetched(fetched) {
            byRef[rowRef(for: envelope)] = envelope
        }
        envelopes = byRef.values.sorted(by: envelopeOrder)
    }

    /// Fetches the page immediately above the window and prepends it, then
    /// trims the now-scrolled-away bottom back to `windowCap`. Triggered by
    /// `ensureLoaded(around:)` when a row near the top of the window appears.
    /// Index-addressed rendering keeps each loaded row at its absolute slot,
    /// so prepending rows above the viewport doesn't move it. When the window
    /// reaches the top (`windowStart == 0`) `hasTrimmedFront` clears, re-
    /// enabling the top-page refresh and the snapshot persist. Internal (not
    /// `private`) so `ensureLoaded` in the main file can launch it.
    func performLoadPrevious() async {
        defer { isLoadingPrevious = false }
        let generation = alignment.generation
        do {
            let count = min(loadMorePageSize, windowStart)
            let offset = windowStart - count
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                offset: offset,
                limit: count,
                sort: sortCriterion
            )
            // Dropped if a reset or a search replaced the rows meanwhile (#1870).
            guard !fetched.isEmpty, generation == alignment.generation else { return }
            let windowEnd = windowStart + UInt32(envelopes.count)
            windowStart = offset
            mergeFetched(fetched)
            // Trim the scrolled-away bottom; the next downward loadMore
            // refetches it by absolute offset.
            if envelopes.count > windowCap {
                envelopes.removeLast(envelopes.count - windowCap)
            }
            hasTrimmedFront = windowStart > 0
            recomputeHasMore(windowEndBefore: windowEnd)
        } catch {
            // Best-effort: a failed page leaves the window as it was, and the
            // next scroll toward the top asks again.
        }
    }

    /// Envelope at an absolute folder index, or nil when that index isn't in
    /// the loaded window (the row then renders a placeholder). Backs the
    /// index-addressed virtualized list: the view's `ForEach` spans the full
    /// `0..<total` index range (stable, so scrolling never re-diffs or jumps),
    /// and each row looks up its data here.
    func envelope(at absoluteIndex: Int) -> Envelope? {
        let local = absoluteIndex - Int(windowStart)
        guard local >= 0, local < envelopes.count else { return nil }
        return envelopes[local]
    }

    /// Replaces the loaded window with a fresh one centered on `absoluteIndex`
    /// for a scrollbar drag into an unloaded region (see `ensureLoaded`).
    /// Discontinuous, so it replaces rather than merges; `hasTrimmedFront` /
    /// `hasMore` are recomputed from the new absolute bounds. Internal (not
    /// `private`) so `ensureLoaded` in the main file can launch it.
    func performLoadWindow(around absoluteIndex: Int) async {
        defer { isLoadingWindow = false }
        // Adopt a staged bottom-prefetch window instantly when it still aligns
        // with the live folder (same total) and covers the requested index --
        // the first jump to the bottom then costs no round trip. Consumed on
        // use: the live `envelopes` window now holds the bottom, and a later
        // jump re-fetches (or re-stages) as normal.
        if let staged = bottomPrefetch,
           staged.total == totalMessages,
           absoluteIndex >= Int(staged.start),
           absoluteIndex < Int(staged.start) + staged.envelopes.count {
            let windowEnd = windowStart + UInt32(envelopes.count)
            windowStart = staged.start
            envelopes = staged.envelopes
            hasTrimmedFront = staged.start > 0
            recomputeHasMore(windowEndBefore: windowEnd)
            bottomPrefetch = nil
            return
        }
        let total = Int(totalMessages)
        // Fetch ONE server-capped page centered on the target, not a whole
        // `windowCap` chunk: the Lambda clamps a page to MAX_PAGE_SIZE (250),
        // so a `windowCap` (600) request silently came back as ~250 rows while
        // the centering math still assumed the full 600 -- the target landed
        // ~`windowCap/2` rows past the loaded slice and stayed a placeholder
        // forever. `windowCap` remains the in-memory bound that loadMore /
        // loadPrevious grow this window toward as the user scrolls from here.
        let page = Int(loadMorePageSize)
        let start = max(0, min(absoluteIndex - page / 2, max(0, total - page)))
        let generation = alignment.generation
        do {
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                offset: UInt32(start),
                limit: loadMorePageSize,
                sort: sortCriterion
            )
            // Dropped if a reset or a search replaced the rows meanwhile (#1870).
            guard !fetched.isEmpty, generation == alignment.generation else { return }
            let windowEnd = windowStart + UInt32(envelopes.count)
            windowStart = UInt32(start)
            envelopes = placedInFolder(fetched).sorted(by: envelopeOrder)
            hasTrimmedFront = start > 0
            recomputeHasMore(windowEndBefore: windowEnd)
        } catch {
            // Best-effort: the rows stay placeholders until the next jump or
            // scroll asks for them again.
        }
    }

    /// A staged bottom window for the prefetch-on-open optimization. `start` is
    /// the absolute index of `envelopes[0]`; `total` stamps the `totalMessages`
    /// it was fetched against, so `performLoadWindow` only adopts it while the
    /// folder size still matches (a struct, not a tuple, to stay under
    /// SwiftLint's `large_tuple` cap).
    struct BottomPrefetch {
        let start: UInt32
        let total: UInt32
        let envelopes: [Envelope]
    }

    /// Drops any staged bottom-prefetch window and cancels an in-flight fill.
    /// Called from `resetWindow()` (sort change, hard reload, UIDVALIDITY
    /// change, search clear) and from `applyStatusCounts` when the folder size
    /// changes, so an adopted window is always aligned with the live folder.
    func invalidateBottomPrefetch() {
        bottomPrefetchTask?.cancel()
        bottomPrefetchTask = nil
        bottomPrefetch = nil
    }

    /// Kicks off a low-priority background fetch of the folder's bottom window
    /// into `bottomPrefetch`, so the first End / jump-to-bottom is instant. It
    /// stages the LAST page (offset `total - loadMorePageSize`) so it actually
    /// covers `total - 1` -- the same window `performLoadWindow` lands on for
    /// the end, one server-capped page (not `windowCap`, which a single fetch
    /// can't return). Only worth it when the bottom isn't already reachable
    /// from the top window (folders larger than one window) and the window is
    /// still top-anchored. Re-kicked after a sort change (the staged order
    /// would otherwise be stale); a no-op while a search is showing or a fill
    /// is already staged or running.
    func scheduleBottomPrefetch() {
        guard !isSearchActive, !hasTrimmedFront, bottomPrefetch == nil,
              Int(totalMessages) > windowCap else { return }
        let total = totalMessages
        let start = total - loadMorePageSize
        bottomPrefetchTask?.cancel()
        bottomPrefetchTask = Task(priority: .background) { [weak self] in
            await self?.performBottomPrefetch(start: start, total: total)
        }
    }

    /// Background body for `scheduleBottomPrefetch`. Fetches the bottom window
    /// positionally and stages it, but only if it's still relevant on
    /// completion: the sort the user is viewing hasn't changed, the folder
    /// size still matches, and no reset or search has replaced the rows
    /// since (#1870), otherwise the window would be mis-ordered or mis-
    /// aligned. Best-effort -- a failed fetch just leaves End to take the
    /// normal round trip.
    func performBottomPrefetch(start: UInt32, total: UInt32) async {
        let sortAtKickoff = sortCriterion
        let generation = alignment.generation
        do {
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                offset: start,
                limit: loadMorePageSize,
                sort: sortAtKickoff
            )
            guard !Task.isCancelled, !fetched.isEmpty, generation == alignment.generation,
                  sortAtKickoff == sortCriterion, total == totalMessages else { return }
            bottomPrefetch = BottomPrefetch(
                start: start, total: total, envelopes: placedInFolder(fetched).sorted(by: envelopeOrder)
            )
        } catch {
            // Best-effort (see above): End takes the normal round trip.
        }
    }

    /// Merges a top-page fetch into in-memory state and the envelope cache,
    /// pruning rows the server no longer returns -- but only when that
    /// pruning is actually safe.
    ///
    /// A top-page refresh is authoritative over the top page alone. The
    /// earlier design bounded the prune by a UID band
    /// (`min(fetched.uid)...uidNext`), which is only correct when the
    /// display order matches UID order. It doesn't: the default sort wires
    /// to `SORT (REVERSE ARRIVAL)` so the server pages by INTERNALDATE,
    /// while the client comparator orders by the Date header. Those orders
    /// diverge, so the top page can contain low-UID rows, the band spans
    /// most of the folder, and a deeply paginated tail gets flagged
    /// "disappeared" and wiped on every 60-second background refresh.
    ///
    /// Bounding the prune to the top page (by position) instead of by a UID
    /// band fixes it without trusting the client/server sort to agree:
    ///   * Not yet paginated (the whole list fits in the top page) ->
    ///     reconcile against the fetch; a missing row was moved/expunged
    ///     out from under us, so prune it and deletes reflect promptly.
    ///   * Paginated past the top page -> suppress pruning here; the
    ///     fetch can't see the tail and the client can't place tail rows
    ///     against it. A delete made elsewhere is caught instead by the
    ///     counts (`planWindow` in `+Reconcile`), which re-reads the window
    ///     by position rather than collapsing a scrolled list to the top.
    ///   * ...UNLESS the fetch now spans the whole folder. When STATUS
    ///     reports no more messages than we just fetched (`fetched.count >=
    ///     totalMessages`), the top page IS the entire folder, so any loaded
    ///     UID absent from it is provably gone -- independent of any
    ///     client/server sort divergence, because there is no unseen tail to
    ///     mis-place. This is the bulk-archive-elsewhere case: the folder
    ///     shrank below the loaded window, so the stale rows (which a plain
    ///     `envelopes.count > pageSize` gate would have stranded until a hard
    ///     reload) reconcile on the next pull/background refresh instead.
    /// An empty fetch (transient/blank top page) is never read as
    /// "everything vanished" -- unless STATUS says so too. A folder that
    /// legitimately emptied out (its last draft deleted server-side, say)
    /// returns nothing to fetch, so the empty-fetch guard alone stranded
    /// its rows forever: the pills read "All, 0" beside a row that 404s
    /// when opened, through refreshes and relaunches (#939). `messages: 0`
    /// straight from the server is the corroboration that makes the prune
    /// safe -- and it has to be the server's own 0, not the `?? 0` default
    /// `applyStatusCounts` falls back to, or a STATUS that dropped the
    /// field would wipe a live list. Hence `serverReportsEmpty`.
    @discardableResult
    func applyRefreshPage(
        _ fetched: [Envelope],
        uidNext: UInt32,
        uidValidity: UInt32,
        serverReportsEmpty: Bool = false
    ) async throws -> Bool {
        let windowEnd = windowStart + UInt32(envelopes.count)
        // The top page is authoritative over the loaded rows when either the
        // window still fits in one top page, or the fetch spans the whole
        // (possibly shrunken) folder -- see the doc comment above. The
        // spans-folder path is additionally gated on the folder actually
        // holding fewer messages than we have loaded, so a transiently low
        // STATUS can't turn a full fetch into a mass prune of a deep window.
        let windowFitsTopPage = UInt32(envelopes.count) <= pageSize
        let fetchSpansFolder = UInt32(fetched.count) >= totalMessages
            && UInt32(envelopes.count) > totalMessages
        let licensed = (!fetched.isEmpty || serverReportsEmpty) && (windowFitsTopPage || fetchSpansFolder)
        let disappeared: [UInt32]
        if licensed {
            let fetchedUIDs = Set(fetched.map(\.uid))
            // A row we're removing ourselves is exempt: a refresh landing in
            // the moment between a dispose's move committing and the row
            // finishing its fade-then-collapse would otherwise see it absent
            // from the fetch and yank it out instantly -- the very jump the
            // animation exists to avoid. `dispose(_:)` removes it either way.
            disappeared = envelopes.map(\.uid).filter {
                !fetchedUIDs.contains($0) && !pendingRemovedRefs.contains(MessageRef(folder: folder.path, uid: $0))
            }
        } else {
            disappeared = []
        }
        // The rows first, with no await between the caller's generation
        // check and them; the caches after, which are the folder's whatever
        // the list shows by then.
        if !disappeared.isEmpty {
            let gone = Set(disappeared)
            envelopes.removeAll { gone.contains($0.uid) }
        }
        mergeFetched(fetched)
        recomputeHasMore(windowEndBefore: windowEnd)
        for uid in disappeared {
            await client.bodyCache.remove(
                folder: folder.path,
                uidValidity: uidValidity,
                uid: uid
            )
        }
        // Mirror the in-memory prune to disk by the same explicit UID list,
        // so a confirmed-gone row can't re-hydrate on next launch.
        if !disappeared.isEmpty {
            try await client.envelopeCache.remove(uids: disappeared, folder: folder.path)
        }
        // Upsert the shielded fresh page into the snapshot (the disappeared
        // rows were pruned above): a row we've optimistically removed stays
        // out of the snapshot, and a row with an in-flight flag write keeps
        // its optimistic flags on disk. Otherwise a refresh landing mid-write
        // would re-seed the cache with pre-write state and re-hydrate it on
        // next launch.
        try await client.envelopeCache.merge(
            envelopes: shieldFetched(fetched),
            uidValidity: uidValidity,
            uidNext: uidNext,
            into: folder.path
        )
        return licensed
    }
}
