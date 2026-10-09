import Foundation
import CabalmailKit

// The list's search entries: they start a search over whatever the list
// shows -- standing the folder window down for it, and giving it back when
// the search doesn't take the list over -- refresh it, end it, and drive the
// filter pills that run one. The search itself (its query, results and
// paging) is `search`, a `MailSearchSession`.
@MainActor
extension MessageListViewModel {
    /// Runs a structured search against `/search_envelopes`. Builds the
    /// wire query from the free-text term + `search.filters`; defaults to
    /// cross-folder (no `folder` param) unless the user has flipped on
    /// "This folder only" in the filters, matching the React webmail.
    /// Empty query AND empty filters drop back to the folder view via
    /// `clearSearch()`.
    ///
    /// Phase 5 of `docs/0.9.x/imap-search-plan.md` switched the wire
    /// path off the raw IMAP-SEARCH passthrough; the structured contract
    /// returns envelopes plus per-row source folders in a single round
    /// trip. Each row keeps its folder (`SearchedEnvelope` places the
    /// envelope in it), so dispose / flag operations route per-row to the
    /// correct mailbox.
    func runSearch(resetFilterTab: Bool = true, preserveDepth: Bool = false, rerun: Bool = false) async {
        // A text search is "All" mode -- its loaded results drive the pill
        // counts. A pill-driven search (`selectFilter`) and the in-place
        // refresh of an active search pass false to keep the pill's `filterTab`.
        // Leaving a pill filter (the only thing that sets filterTab != .all) for
        // a text search drops the flag/scope the pill imposed, so the text
        // search isn't silently AND-ed with it; sheet-set filters (filterTab
        // stays .all) are untouched.
        if resetFilterTab {
            if filterTab != .all { search.filters = MessageSearchFilters() }
            filterTab = .all
        }
        // A refresh re-runs the search that was submitted, not whatever has
        // been typed into the field since (#1821).
        let trimmed = rerun ? search.submittedQuery : searchQuery.trimmingCharacters(in: .whitespaces)
        // Nothing to match on drops back to the folder view. "This folder
        // only" alone is not something to match on (see `hasNoPredicate`):
        // a sidebar pick empties the query and then moves the anchor, so
        // counting the scope re-ran the search with no term and drew the
        // whole folder as matches (#1536).
        if trimmed.isEmpty && search.filters.hasNoPredicate {
            await clearSearch()
            return
        }
        // The depth an in-place refresh re-walks to. A fresh search starts
        // from one page and pages in from there (`MailSearchSession.loadMore`);
        // a refresh of an active search (pull, a poll of the folder)
        // re-fetches as many rows as the user has already paged in,
        // so it can't silently truncate their scroll position back to one
        // page. Cost stays proportional to the depth the user opted into.
        let targetDepth = preserveDepth && isSearchActive
            ? max(envelopes.count, MailSearchSession.pageSize)
            : MailSearchSession.pageSize
        // A search over a folder holds its window as a refresh does (#1820):
        // no folder page starts while it is out, and what the viewport lacks
        // loads once the last hold falls.
        window?.holdLoading()
        defer { window?.releaseLoading() }
        // A folder page or refresh still out was addressed to the rows this
        // search replaces; landing later, it would mix folder rows into the
        // results (#1870). They stand down now, and again as the results
        // land (`searchWillShowResults`), for any that started meanwhile. A
        // search that ends without taking the list over leaves the folder
        // rows they were filling.
        window?.standDownWindowLoads()
        defer { if !isSearchActive { window?.resumeWindowLoads() } }
        await search.run(trimmed, depth: targetDepth, rerun: rerun)
    }

    /// A refresh of the active search: the folder's counts from STATUS
    /// first (a pill is a search, and its counts and the sidebar badge would
    /// otherwise stop moving until it is left, #1819), then the submitted
    /// search again at the depth already paged in. `prefetched` is a STATUS the caller already asked
    /// for (`hardReload`, the folder's poller), used rather than asked for again. The search
    /// surface has no folder to count.
    func refreshSearch(prefetched: PrefetchedStatus? = nil) async {
        await window?.refreshCounts(prefetched: prefetched)
        guard !Task.isCancelled else { return }
        await runSearch(resetFilterTab: false, preserveDepth: true, rerun: true)
    }

    /// Drive a filter pill. Unread / Flagged run a fresh folder-scoped server
    /// search so every match in the folder is reachable -- the first page
    /// loads here and scrolling pages in the rest via
    /// `MailSearchSession.loadMore` -- while All returns to folder mode. A pill
    /// replaces any text search; the richer text-plus-flag combination stays
    /// available through the filter sheet. The pill stays highlighted via
    /// `filterTab`, and because `filterTab` is non-`.all` the counts stay
    /// server-sourced (see `pillCount`) rather than counting the loaded
    /// results.
    ///
    /// The tap also makes the pill the one this folder's list opens on
    /// (sticky per folder, synced through the preferences row); `loadInitial`
    /// replays it through `applyFilter`, which is the tap without the
    /// persistence.
    func selectFilter(_ filter: MessageFilter) async {
        guard filter != filterTab else { return }
        if let folder { preferences.setMailFolderFilter(filter, for: folder.path) }
        await applyFilter(filter)
    }

    /// `selectFilter`'s effect on the list, without recording the pill it
    /// picks. Leaving Unread or Flagged for All is still recorded, by
    /// `filterTab`'s `didSet`, as it is by every route there.
    func applyFilter(_ filter: MessageFilter) async {
        filterTab = filter
        guard filter != .all else {
            await clearSearch()
            return
        }
        searchQuery = ""
        search.filters = MessageSearchFilters(
            unread: filter == .unread,
            flagged: filter == .flagged,
            thisFolderOnly: true
        )
        await runSearch(resetFilterTab: false)
    }

    /// Drops the active search, restores folder-mode metadata, and
    /// re-runs `refresh()` so the user lands back on the folder view.
    /// Called by the search banner's clear button and by `runSearch()`
    /// when the user submits an empty query with no filters set.
    ///
    /// The folder window's rows are wiped before refreshing: a search's
    /// rows stay in the search, but the window's are the folder's as they
    /// stood when the search took the list over, and `applyRefreshPage`'s
    /// disappear-detection only reconciles the current folder's top page.
    /// Same pattern as `setSort(_:)`.
    func clearSearch() async {
        // Folder mode is "All" mode: reset the pill too, so clearing a search
        // (including the banner's clear button while a pill filter is active)
        // can't strand a highlighted pill over a plain folder view.
        filterTab = .all
        search.clear()
        // Folder scope drops back to the folder view; the global search
        // surface has no folder to return to, so it just lands on the empty
        // "type to search" state.
        guard let window else { return }
        window.envelopes.removeAll()
        window.totalMessages = 0
        window.savedMessageCount = nil
        window.hasMore = true
        window.resetWindow()
        await refresh(startingOver: true)
        // Offline the refresh can't answer, and the list used to stay empty
        // (#1796): the saved counts come back, and under the default order
        // the folder's cached rows too, as `loadInitial` starts from. The
        // snapshot is a window of that order; under another it would leave
        // gaps once the server answers.
        if envelopes.isEmpty, errorMessage != nil {
            if window.sortCriterion == .default { await window.hydrateFromCache() }
            await window.seedSavedCounts()
        }
    }

    /// Moves the search surface's anchor. An active single-folder search
    /// re-runs against the new folder, so the banner never names a folder the
    /// rows did not come from; losing the anchor drops the scope, since there
    /// is nothing left to narrow to.
    ///
    /// The re-run lands in `runSearch`, which ends the search instead when
    /// there is no longer anything to match on — a sidebar pick empties the
    /// query before it writes the new folder, and that is a teardown, not a
    /// search of the folder just picked (#1536).
    func setSearchAnchor(_ anchor: Folder?) async {
        guard anchor?.path != searchAnchor?.path else { return }
        searchAnchor = anchor
        guard search.filters.thisFolderOnly else { return }
        if anchor == nil { search.filters.thisFolderOnly = false }
        guard isSearchActive else { return }
        await runSearch(resetFilterTab: false)
    }
}

// MARK: - The search's host

extension MessageListViewModel: MailSearchHost {
    /// A search's results are landing in place of the rows on screen: the
    /// folder window's loads stand down again, for any that started while
    /// the search was out (#1870).
    func searchWillShowResults() {
        window?.standDownWindowLoads()
    }
}
