import Foundation
import CabalmailKit

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

/// Paging for a `FolderWindowLoader`: the loads that grow, shift or replace
/// the window as rows appear, the load of where the list settles after a
/// scroll, and the bottom page staged for the first jump to the end.
///
/// The list's `ForEach` spans the folder's whole stable position range, so
/// shifting or trimming the window only changes which positions hold rows;
/// it never restructures the list, so there is no jump and no trim thrash.
/// Each load runs on a task the window owns, so it outlives the row `.task`
/// that asked for it, and drops its page if a reset or a search moved the
/// window's generation while it was out (#1870).
@MainActor
struct WindowPager {
    let window: FolderWindowLoader

    /// A row (real or placeholder) at `absoluteIndex` appeared: make the
    /// window cover it. Near an edge the window extends a page toward it;
    /// a far jump replaces the window with one centred there.
    func ensureLoaded(around absoluteIndex: Int) {
        guard !window.isSearchActive, window.pendingRemovedRefs.isEmpty, !window.alignment.isReconciling,
              !window.isLoading, !window.isLoadingMore, !window.isLoadingPrevious, !window.isLoadingWindow
              else { return }
        let windowLo = Int(window.windowStart)
        let windowHi = windowLo + window.envelopes.count   // exclusive
        let prefetch = Int(window.prefetchDistance)
        if absoluteIndex >= windowLo - prefetch && absoluteIndex <= windowHi + prefetch {
            // Near or inside the window: extend toward the approached edge.
            // A fresh jump window is shorter than the runway, so an index can
            // be in reach of both; the nearer edge goes first (#1823).
            let below = absoluteIndex >= windowHi - prefetch && window.hasMore
                && windowHi < Int(window.totalMessages)
            let above = absoluteIndex <= windowLo + prefetch && windowLo > 0
            if below, !above || windowHi - 1 - absoluteIndex <= absoluteIndex - windowLo {
                window.isLoadingMore = true
                window.loadMoreTask = Task { [weak window = self.window] in await window?.pager.performLoadMore() }
            } else if above {
                window.isLoadingPrevious = true
                window.loadPrevTask = Task { [weak window = self.window] in await window?.pager.performLoadPrevious() }
            }
        } else {
            // Far jump: replace the window with one centered on the target.
            window.isLoadingWindow = true
            window.loadWindowTask = Task { [weak window = self.window] in
                await window?.pager.performLoadWindow(around: absoluteIndex)
            }
        }
    }

    /// Debounced "load the window the list settled on" after a scroll or a
    /// key jump. Each call (every row appear and every PgUp/PgDown) restarts
    /// it, so a burst of scrolling collapses into one load once it stops. It
    /// waits for any page load in flight first -- rather than racing a cancel
    /// against a second writer -- then drives `ensureLoaded` at the settled
    /// visible centre, which the landing rows' `.task`s may have skipped
    /// while a load held the gate.
    func scheduleEnsureLoaded() {
        window.keyScrollTask?.cancel()
        window.keyScrollTask = Task { [weak window = self.window] in
            try? await Task.sleep(for: .milliseconds(175))
            // Nothing to settle for a list that has gone.
            guard !Task.isCancelled, let window, window.host != nil else { return }
            await window.loadMoreTask?.value
            await window.loadPrevTask?.value
            await window.loadWindowTask?.value
            guard !Task.isCancelled,
                  let first = window.firstVisibleRow,
                  let last = window.lastVisibleRow else { return }
            window.ensureLoaded(around: (first + last) / 2)
        }
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
        guard !window.isSearchActive, !window.hasTrimmedFront, window.bottomPrefetch == nil,
              Int(window.totalMessages) > window.windowCap else { return }
        let total = window.totalMessages
        let start = total - window.loadMorePageSize
        window.bottomPrefetchTask?.cancel()
        window.bottomPrefetchTask = Task(priority: .background) { [weak window = self.window] in
            await window?.pager.performBottomPrefetch(start: start, total: total)
        }
    }

    /// Fetches and merges the next positional page, then trims the
    /// scrolled-past front back to `windowCap`. Resets `isLoadingMore` on
    /// every exit, cancellation included.
    private func performLoadMore() async {
        defer { window.isLoadingMore = false }
        let generation = window.alignment.generation
        do {
            // Positional page in the current sort order. `mergeFetched`
            // dedups, so a shifted offset (a concurrent removal) can't
            // double-insert. The offset is absolute: the window's front may
            // have been trimmed, so the next page starts past everything ever
            // loaded (`windowStart` + the rows still in memory), not at
            // `envelopes.count`.
            let offset = window.windowStart + UInt32(window.envelopes.count)
            let fetched = try await window.client.imapClient.envelopes(
                folder: window.folder.path,
                offset: offset,
                limit: window.loadMorePageSize,
                sort: window.sortCriterion
            )
            // A reset or a search that started while the page was out has
            // replaced the rows it was addressed to (#1870).
            guard generation == window.alignment.generation else { return }
            window.mergeFetched(fetched)
            // Trim the scrolled-past front so the loaded window stays bounded
            // (see `windowCap`). loadMore only fires near the bottom (within
            // `prefetchDistance`), so the last `windowCap` rows always cover
            // the viewport, the runway below it, and a scroll-back buffer
            // above; `removeFirst` drops the newest rows the user scrolled up
            // and away from under the default newest-first sort. Each loaded
            // row keeps its absolute position, so the viewport doesn't move
            // across the removal.
            if window.envelopes.count > window.windowCap {
                let overflow = window.envelopes.count - window.windowCap
                window.envelopes.removeFirst(overflow)
                window.windowStart += UInt32(overflow)
                window.hasTrimmedFront = true
            }
            // Done when the page comes back empty or the absolute bottom of
            // the window reaches the folder's STATUS total.
            window.hasMore = !fetched.isEmpty
                && (window.windowStart + UInt32(window.envelopes.count)) < window.totalMessages
            // Persist is debounced: rewriting the whole on-disk snapshot is
            // O(loaded count), and awaited on every page it put a growing
            // write on the pagination critical path while `isLoadingMore` was
            // held. The snapshot is a warm-reopen cache, not source of truth,
            // so writing once the scroll settles is safe.
            window.snapshot.schedulePersist()
        } catch {
            // Best-effort pagination: a failed page shows nothing, and the
            // next row to appear asks again.
        }
    }

    /// Fetches the page immediately above the window and prepends it, then
    /// trims the now-scrolled-away bottom back to `windowCap`. Each loaded row
    /// keeps its absolute slot, so prepending above the viewport doesn't move
    /// it. Once the window reaches the top `hasTrimmedFront` clears, which
    /// lets the top-page refresh and the snapshot write run again.
    private func performLoadPrevious() async {
        defer { window.isLoadingPrevious = false }
        let generation = window.alignment.generation
        do {
            let count = min(window.loadMorePageSize, window.windowStart)
            let offset = window.windowStart - count
            let fetched = try await window.client.imapClient.envelopes(
                folder: window.folder.path,
                offset: offset,
                limit: count,
                sort: window.sortCriterion
            )
            // Dropped if a reset or a search replaced the rows meanwhile (#1870).
            guard !fetched.isEmpty, generation == window.alignment.generation else { return }
            let windowEnd = window.windowStart + UInt32(window.envelopes.count)
            window.windowStart = offset
            window.mergeFetched(fetched)
            // Trim the scrolled-away bottom; the next downward loadMore
            // refetches it by absolute offset.
            if window.envelopes.count > window.windowCap {
                window.envelopes.removeLast(window.envelopes.count - window.windowCap)
            }
            window.hasTrimmedFront = window.windowStart > 0
            window.recomputeHasMore(windowEndBefore: windowEnd)
        } catch {
            // Best-effort: a failed page leaves the window as it was, and the
            // next scroll toward the top asks again.
        }
    }

    /// Replaces the loaded window with a fresh one centered on `absoluteIndex`
    /// for a scrollbar drag into an unloaded region (see `ensureLoaded`).
    /// Discontinuous, so it replaces rather than merges.
    private func performLoadWindow(around absoluteIndex: Int) async {
        defer { window.isLoadingWindow = false }
        // Adopt a staged bottom-prefetch window instantly when it still aligns
        // with the live folder (same total) and covers the requested index --
        // the first jump to the bottom then costs no round trip. Consumed on
        // use: the live `envelopes` window now holds the bottom, and a later
        // jump re-fetches (or re-stages) as normal.
        if let staged = window.bottomPrefetch,
           staged.total == window.totalMessages,
           absoluteIndex >= Int(staged.start),
           absoluteIndex < Int(staged.start) + staged.envelopes.count {
            let windowEnd = window.windowStart + UInt32(window.envelopes.count)
            window.windowStart = staged.start
            window.envelopes = staged.envelopes
            window.hasTrimmedFront = staged.start > 0
            window.recomputeHasMore(windowEndBefore: windowEnd)
            window.bottomPrefetch = nil
            return
        }
        let total = Int(window.totalMessages)
        // Fetch ONE server-capped page centered on the target, not a whole
        // `windowCap` chunk: the Lambda clamps a page to MAX_PAGE_SIZE (250),
        // so a `windowCap` (600) request silently came back as ~250 rows while
        // the centering math still assumed the full 600 -- the target landed
        // ~`windowCap/2` rows past the loaded slice and stayed a placeholder
        // forever. `windowCap` remains the in-memory bound that loadMore /
        // loadPrevious grow this window toward as the user scrolls from here.
        let page = Int(window.loadMorePageSize)
        let start = max(0, min(absoluteIndex - page / 2, max(0, total - page)))
        let generation = window.alignment.generation
        do {
            let fetched = try await window.client.imapClient.envelopes(
                folder: window.folder.path,
                offset: UInt32(start),
                limit: window.loadMorePageSize,
                sort: window.sortCriterion
            )
            // Dropped if a reset or a search replaced the rows meanwhile (#1870).
            guard !fetched.isEmpty, generation == window.alignment.generation else { return }
            let windowEnd = window.windowStart + UInt32(window.envelopes.count)
            window.windowStart = UInt32(start)
            window.envelopes = window.placedInFolder(fetched).sorted(by: window.envelopeOrder)
            window.hasTrimmedFront = start > 0
            window.recomputeHasMore(windowEndBefore: windowEnd)
        } catch {
            // Best-effort: the rows stay placeholders until the next jump or
            // scroll asks for them again.
        }
    }

    /// Background body for `scheduleBottomPrefetch`. Fetches the bottom window
    /// positionally and stages it, but only if it's still relevant on
    /// completion: the sort the user is viewing hasn't changed, the folder
    /// size still matches, and no reset or search has replaced the rows
    /// since (#1870), otherwise the window would be mis-ordered or mis-
    /// aligned. Best-effort -- a failed fetch just leaves End to take the
    /// normal round trip.
    private func performBottomPrefetch(start: UInt32, total: UInt32) async {
        let sortAtKickoff = window.sortCriterion
        let generation = window.alignment.generation
        do {
            let fetched = try await window.client.imapClient.envelopes(
                folder: window.folder.path,
                offset: start,
                limit: window.loadMorePageSize,
                sort: sortAtKickoff
            )
            guard !Task.isCancelled, !fetched.isEmpty, generation == window.alignment.generation,
                  sortAtKickoff == window.sortCriterion, total == window.totalMessages else { return }
            window.bottomPrefetch = BottomPrefetch(
                start: start, total: total,
                envelopes: window.placedInFolder(fetched).sorted(by: window.envelopeOrder)
            )
        } catch {
            // Best-effort (see above): End takes the normal round trip.
        }
    }
}
