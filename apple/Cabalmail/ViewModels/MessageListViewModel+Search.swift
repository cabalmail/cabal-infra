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
    /// trip. Cross-folder results populate `sourceFolderByUID` so
    /// dispose / flag operations route per-row to the correct mailbox.
    func runSearch(resetFilterTab: Bool = true) async {
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
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let query = buildSearchQuery(text: trimmed, filters: searchFilters)
            // Fetch the match set in bounded `searchPageSize` chunks by
            // walking the cursor, rather than asking for the whole set in one
            // request (Layer 3.2 of the large-mailbox-hardening plan).
            let result = try await client.imapClient.searchEnvelopesChunked(
                query,
                pageSize: Self.searchPageSize,
                maxResults: searchResultCap
            )
            envelopes = result.envelopes.map(\.envelope)
            sourceFolderByUID = Dictionary(uniqueKeysWithValues: result.envelopes.map {
                ($0.envelope.uid, $0.folder)
            })
            searchTotalEstimate = result.totalEstimate
            searchTruncated = result.truncated
            searchFoldersSearched = result.foldersSearched
            isSearchActive = true
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Drive a filter pill. Unread / Flagged run a fresh folder-scoped server
    /// search so every match in the folder shows -- not just the loaded rows --
    /// while All returns to folder mode. A pill replaces any text search; the
    /// richer text-plus-flag combination stays available through the filter
    /// sheet. The pill stays highlighted via `filterTab`, and because
    /// `filterTab` is non-`.all` the counts stay server-sourced (see
    /// `pillCount`) rather than counting the loaded results.
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
        searchFilters = MessageSearchFilters()
        // Folder mode is "All" mode: reset the pill too, so clearing a search
        // (including the banner's clear button while a pill filter is active)
        // can't strand a highlighted pill over a plain folder view.
        filterTab = .all
        isSearchActive = false
        sourceFolderByUID = [:]
        searchTotalEstimate = 0
        searchTruncated = false
        searchFoldersSearched = []
        envelopes.removeAll()
        totalMessages = 0
        unseen = 0
        flagged = 0
        hasMore = true
        resetWindow()
        await refresh()
    }

    /// Resolves the IMAP mailbox that owns `envelope`. In folder mode
    /// and in single-folder searches this is always `folder.path`; in
    /// cross-folder search mode the per-row entry from
    /// `sourceFolderByUID` wins so dispose / flag operations target the
    /// right mailbox.
    func sourceFolder(for envelope: Envelope) -> String {
        sourceFolderByUID[envelope.uid] ?? folder.path
    }

    /// Per-request chunk size for `runSearch`'s envelope fetch. The match set
    /// is gathered by walking the `/search_envelopes` cursor in batches of
    /// this size (Layer 3.2 of the large-mailbox-hardening plan), so no single
    /// request asks the Lambda for the whole set. Mirrors the folder view's
    /// page size and the Lambda's DEFAULT_LIMIT.
    static let searchPageSize = 50

    /// Upper bound on the envelopes `runSearch` collects across all chunks. A
    /// pill filter promises "all matches in the folder," so it pulls up to the
    /// Lambda's MAX_LIMIT (200); a free-text search shows the first page and
    /// leans on the count/disclosure banner for the rest. Derived from
    /// `filterTab` so a background refresh keeps the wide cap.
    private var searchResultCap: Int {
        filterTab == .all ? Self.searchPageSize : 200
    }

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
            // `limit` and `cursor` are owned by `searchEnvelopesChunked`, which
            // pages the fetch into `searchPageSize` chunks up to `searchResultCap`.
        )
    }
}
