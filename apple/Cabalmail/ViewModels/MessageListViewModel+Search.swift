import Foundation
import CabalmailKit

/// Structured `/search_envelopes` plumbing for `MessageListViewModel`.
/// Lives in its own file so the primary type body stays under SwiftLint's
/// length cap; same `@MainActor` extension as the rest of the view model.
@MainActor
extension MessageListViewModel {
    /// Runs a structured search against `/search_envelopes`. Builds the
    /// wire query from the free-text term + `searchFilters`; defaults to
    /// cross-folder (no `folder` param) unless the user has flipped on
    /// "This folder only" in the filters, matching the React webmail.
    /// Empty query AND empty filters drop back to the folder view via
    /// `clearSearch()`.
    ///
    /// Phase 5 of `docs/0.9.x/imap-search-plan.md` switched the wire
    /// path off the raw IMAP-SEARCH passthrough; the structured contract
    /// returns envelopes plus per-row source folders in a single round
    /// trip. Cross-folder results populate `sourceFolderIndex` so
    /// dispose / flag operations route per-row to the correct mailbox.
    func runSearch(resetFilterTab: Bool = true, preserveDepth: Bool = false) async {
        // A text search is "All" mode -- its loaded results drive the pill
        // counts. A pill-driven search (`selectFilter`) and the in-place
        // refresh of an active search pass false to keep the pill's `filterTab`.
        // Leaving a pill filter (the only thing that sets filterTab != .all) for
        // a text search drops the flag/scope the pill imposed, so the text
        // search isn't silently AND-ed with it; sheet-set filters (filterTab
        // stays .all) are untouched.
        if resetFilterTab {
            if filterTab != .all { searchFilters = MessageSearchFilters() }
            filterTab = .all
        }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty && searchFilters.isEmpty {
            await clearSearch()
            return
        }
        // Recorded at submit time, not on success: the question the
        // placeholder asks is "has this term been sent yet", which a failed
        // request answers just as much as a successful one.
        submittedQuery = trimmed
        // The depth an in-place refresh re-walks to. A fresh search starts
        // from one page and pages in from there (`loadMoreSearchResults`);
        // a refresh of an active search (pull, the 60-second background
        // pass) re-fetches as many rows as the user has already paged in,
        // so it can't silently truncate their scroll position back to one
        // page. Cost stays proportional to the depth the user opted into.
        let targetDepth = preserveDepth && isSearchActive
            ? max(envelopes.count, Self.searchPageSize)
            : Self.searchPageSize
        // Invalidate the old cursor before the await: a load-more that's
        // mid-flight checks its cursor is still current before appending,
        // so this reset makes it drop a page that belongs to the outgoing
        // result set.
        searchNextCursor = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let query = buildSearchQuery(text: trimmed, filters: searchFilters)
            // Fetch in bounded `searchPageSize` chunks by walking the cursor,
            // rather than asking for the whole set in one request (Layer 3.2
            // of the large-mailbox-hardening plan).
            let result = try await client.imapClient.searchEnvelopesChunked(
                query,
                pageSize: Self.searchPageSize,
                maxResults: targetDepth
            )
            envelopes = result.envelopes.map(\.envelope)
            sourceFolderIndex = SearchSourceFolderIndex(result.envelopes)
            searchTotalEstimate = result.totalEstimate
            searchTruncated = result.truncated
            searchFoldersSearched = result.foldersSearched
            searchNextCursor = result.nextCursor
            isSearchActive = true
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// View-facing trigger for the next search page. Hops onto a model-owned
    /// task so the row `.task` that fired it can be cancelled by scrolling
    /// without cancelling the fetch mid-flight — the folder window's
    /// `loadMoreTask` pattern, and the same reason: a propagated cancellation
    /// would surface as a spurious "cancelled" error. The guards make
    /// redundant kicks free.
    func requestMoreSearchResults() {
        guard isSearchActive, !isLoading, !isLoadingMoreSearch,
              searchNextCursor != nil else { return }
        loadMoreSearchTask = Task { [weak self] in await self?.loadMoreSearchResults() }
    }

    /// Fetches the next page of the active search and appends it — the
    /// scroll-driven leg of search pagination. Triggered (via
    /// `requestMoreSearchResults`) by the list nearing the end of the loaded
    /// matches, and by the visible rows emptying (a pill page the user has
    /// fully dealt with — every row marked read under Unread — must still be
    /// able to pull the next page). No-op unless a search is active with a
    /// cursor and nothing else is fetching.
    func loadMoreSearchResults() async {
        guard isSearchActive, !isLoading, !isLoadingMoreSearch,
              let cursor = searchNextCursor else { return }
        isLoadingMoreSearch = true
        defer { isLoadingMoreSearch = false }
        do {
            let query = buildSearchQuery(text: submittedQuery, filters: searchFilters)
            let page = try await client.imapClient.searchEnvelopes(
                query.page(limit: Self.searchPageSize, cursor: cursor)
            )
            // A clearSearch or fresh runSearch during the await owns
            // `envelopes` now; this page belongs to the outgoing result set.
            guard isSearchActive, searchNextCursor == cursor else { return }
            appendSearchPage(page)
            errorMessage = nil
        } catch {
            // Same staleness check: an error from a fetch the user has
            // already navigated away from isn't worth a banner.
            guard isSearchActive, searchNextCursor == cursor else { return }
            errorMessage = "\(error)"
        }
    }

    /// Appends one search page, dropping rows already loaded: the cursor is
    /// date-based, so a page boundary shifting under mailbox churn can
    /// re-deliver a row from the previous page, and a duplicate would draw
    /// as a repeated row.
    private func appendSearchPage(_ page: SearchResult) {
        var seen = Set(envelopes.map {
            PageRowKey(folder: sourceFolder(for: $0), uid: $0.uid, messageID: $0.messageId)
        })
        let fresh = page.envelopes.filter {
            seen.insert(
                PageRowKey(folder: $0.folder, uid: $0.envelope.uid, messageID: $0.envelope.messageId)
            ).inserted
        }
        envelopes.append(contentsOf: fresh.map(\.envelope))
        sourceFolderIndex.add(fresh)
        searchTotalEstimate = page.totalEstimate
        searchTruncated = searchTruncated || page.truncated
        searchNextCursor = page.nextCursor
    }

    /// Row identity for the append dedupe. Folder + UID pins a row to its
    /// mailbox (cross-folder results reuse UIDs); Message-ID separates the
    /// same-message-filed-twice shape the source-folder index documents.
    private struct PageRowKey: Hashable {
        let folder: String
        let uid: UInt32
        let messageID: String?
    }

    /// Drive a filter pill. Unread / Flagged run a fresh folder-scoped server
    /// search so every match in the folder is reachable -- the first page
    /// loads here and scrolling pages in the rest via
    /// `loadMoreSearchResults` -- while All returns to folder mode. A pill
    /// replaces any text search; the richer text-plus-flag combination stays
    /// available through the filter sheet. The pill stays highlighted via
    /// `filterTab`, and because `filterTab` is non-`.all` the counts stay
    /// server-sourced (see `pillCount`) rather than counting the loaded
    /// results.
    func selectFilter(_ filter: MessageFilter) async {
        guard filter != filterTab else { return }
        filterTab = filter
        guard filter != .all else {
            await clearSearch()
            return
        }
        searchQuery = ""
        searchFilters = MessageSearchFilters(
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
    /// The in-memory envelope list is wiped before refreshing. Search
    /// is cross-folder by default, so `envelopes` can hold UIDs from
    /// other folders (e.g. Archive UID 957). `applyRefreshPage`'s
    /// disappear-detection only reconciles the current folder's top
    /// page, so foreign UIDs would otherwise survive as phantom rows
    /// that 502 on tap (IMAP fetch can't find
    /// them in this folder, helper.py raises `KeyError`). Same pattern
    /// as `setSort(_:)`.
    func clearSearch() async {
        dbg("clearSearch")
        searchQuery = ""
        submittedQuery = ""
        searchFilters = MessageSearchFilters()
        // Folder mode is "All" mode: reset the pill too, so clearing a search
        // (including the banner's clear button while a pill filter is active)
        // can't strand a highlighted pill over a plain folder view.
        filterTab = .all
        isSearchActive = false
        sourceFolderIndex = SearchSourceFolderIndex()
        searchTotalEstimate = 0
        searchTruncated = false
        searchFoldersSearched = []
        searchNextCursor = nil
        envelopes.removeAll()
        totalMessages = 0
        unseen = 0
        flagged = 0
        hasMore = true
        resetWindow()
        // Folder scope drops back to the folder view; the global search
        // surface has no folder to return to, so it just lands on the empty
        // "type to search" state.
        guard !isSearchScope else { return }
        await refresh()
    }

    /// Resolves the IMAP mailbox that owns `envelope`. In folder mode
    /// and in single-folder searches this is always `folder.path`; in
    /// cross-folder search mode the per-row entry from
    /// `sourceFolderIndex` wins so dispose / flag operations target the
    /// right mailbox.
    func sourceFolder(for envelope: Envelope) -> String {
        sourceFolderIndex.folder(for: envelope) ?? folder.path
    }

    /// Per-request page size for search fetches — `runSearch`'s initial page
    /// (and an in-place refresh's chunked re-walk) and each
    /// `loadMoreSearchResults` page. No single request asks the Lambda for
    /// the whole match set (Layer 3.2 of the large-mailbox-hardening plan);
    /// depth comes from scroll-driven paging instead of an up-front cap.
    /// Mirrors the folder view's page size and the Lambda's DEFAULT_LIMIT.
    static let searchPageSize = 50

    private func buildSearchQuery(text: String, filters: MessageSearchFilters) -> SearchQuery {
        SearchQuery(
            folder: filters.thisFolderOnly ? folder.path : nil,
            text: text.isEmpty ? nil : text,
            from: filters.from.isEmpty ? nil : filters.from,
            to: filters.to.isEmpty ? nil : filters.to,
            subject: filters.subject.isEmpty ? nil : filters.subject,
            since: filters.since,
            before: filters.before,
            unread: filters.unread,
            flagged: filters.flagged,
            hasAttachment: filters.hasAttachment
            // `limit` and `cursor` are owned by the fetch paths: `runSearch`'s
            // chunked walk and `loadMoreSearchResults`' single page both fill
            // them per request via `page(limit:cursor:)`.
        )
    }
}
