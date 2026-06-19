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
    func runSearch() async {
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
            let result = try await client.imapClient.searchEnvelopes(query)
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
        )
    }
}
