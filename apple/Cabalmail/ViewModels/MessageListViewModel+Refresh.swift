import Foundation
import CabalmailKit

// Cache-merge helpers used by the refresh / loadMore paths. Pulled into
// a sibling extension so the main view-model file stays under SwiftLint's
// 400-line cap. Both helpers are internal so the sort-extension and the
// main file can call them; the private cache-snapshot path
// (`hydrateFromCache`, `persistCache`) stays in the main file because
// the cache scope is intentionally narrow.
extension MessageListViewModel {
    /// User-initiated "force reload." Wipes the in-memory envelope list
    /// (plus the cursor state `refresh()` uses to merge older pages) AND
    /// the on-disk envelope snapshot for this folder, then runs
    /// `refresh()` to rebuild from scratch. Both the macOS
    /// `Mailbox > Refresh` menu item and the message-list toolbar's
    /// arrow.clockwise button route through this path so the user has a
    /// way to escape stale state (e.g., a search that populated the
    /// list with foreign-folder UIDs the regular refresh's UID-range
    /// pruning can't catch). The IDLE watcher and the 60-second wall-
    /// clock fallback intentionally keep calling `refresh()` directly —
    /// they fire often, and the merge path is the cheap "fold new mail
    /// in" loop the cache is designed around. Hard reload stays on the
    /// manual paths the user explicitly invokes.
    ///
    /// Invalidating the on-disk snapshot here matters because
    /// `applyRefreshPage` only reconciles the top page, and only while
    /// the list still fits in it — once paginated it prunes nothing, and
    /// even when it does prune it touches the top page alone. Foreign-
    /// folder UIDs that leaked into the cache (historically through
    /// pagination during search) sit in the paginated tail, so without an
    /// explicit invalidate they'd survive every subsequent refresh and re-
    /// hydrate as phantoms on relaunch. The body cache is left alone:
    /// it's keyed per-UID, never blindly batch-written, and an
    /// unrelated phantom never reached the fetch path far enough to
    /// land a body in it.
    func hardReload() async {
        dbg("hardReload")
        try? await client.envelopeCache.invalidate(folder: folder.path)
        envelopes.removeAll()
        totalMessages = 0
        hasMore = true
        sourceFolderByUID = [:]
        await refresh()
    }

    /// Apply the in-flight-write shields to a freshly fetched page so a
    /// stale refresh can't undo an optimistic update. Rows we've
    /// optimistically removed (a move/dispose still settling) are dropped,
    /// and rows with an in-flight flag write keep their optimistic flags
    /// rather than the fetched (pre-toggle) ones. Both the in-memory merge
    /// and the cache persist run through this so memory and disk stay in
    /// agreement. The optimistic flags are read back from the current
    /// in-memory `envelopes`, which is where the write paths stash them.
    private func shieldFetched(_ fetched: [Envelope]) -> [Envelope] {
        let detailFlagWrites = appState.pendingFlagWriteUIDs[folder.path] ?? []
        let detailMoves = appState.pendingMoveUIDs[folder.path] ?? []
        return fetched.compactMap { fetchedEnvelope in
            // A row optimistically removed by either this view model
            // (`pendingRemovedUIDs`) or the detail view (shared, folder-keyed
            // `appState.pendingMoveUIDs`) stays gone until the move resolves.
            if pendingRemovedUIDs.contains(fetchedEnvelope.uid)
                || detailMoves.contains(fetchedEnvelope.uid) { return nil }
            // A flag write in flight from either this view model
            // (`pendingFlagUIDs`) or the detail view (shared, folder-keyed
            // `appState.pendingFlagWriteUIDs`) shields the row's flags.
            let flagWriteInFlight = pendingFlagUIDs.contains(fetchedEnvelope.uid)
                || detailFlagWrites.contains(fetchedEnvelope.uid)
            if flagWriteInFlight,
               let local = envelopes.first(where: { $0.uid == fetchedEnvelope.uid }) {
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
        let before = envelopes.count
        var byUID: [UInt32: Envelope] = Dictionary(
            uniqueKeysWithValues: envelopes.map { ($0.uid, $0) }
        )
        for envelope in shieldFetched(fetched) {
            byUID[envelope.uid] = envelope
        }
        let mergeStart = nowMs()
        envelopes = byUID.values.sorted(by: envelopeOrder)
        dbg("merge in=\(fetched.count) before=\(before) after=\(envelopes.count) sortMs=\(Int(nowMs() - mergeStart))")
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
    ///   * Paginated past the top page -> suppress pruning entirely; the
    ///     fetch can't see the tail and the client can't place tail rows
    ///     against it, so a delete surfaces on the next hard reload /
    ///     folder switch instead. Same trade the non-default sorts already
    ///     took, and far better than collapsing a scrolled list to the top.
    /// An empty fetch (transient/blank top page) is never read as
    /// "everything vanished."
    func applyRefreshPage(
        _ fetched: [Envelope],
        uidNext: UInt32,
        uidValidity: UInt32
    ) async throws {
        let paginatedBeyondTopPage = UInt32(envelopes.count) > pageSize
        let disappeared: [UInt32]
        if !paginatedBeyondTopPage, !fetched.isEmpty {
            let fetchedUIDs = Set(fetched.map(\.uid))
            disappeared = envelopes.map(\.uid).filter { !fetchedUIDs.contains($0) }
        } else {
            disappeared = []
        }
        dbg("applyRefreshPage disappeared=\(disappeared.count) fetched=\(fetched.count)")
        if !disappeared.isEmpty {
            let gone = Set(disappeared)
            envelopes.removeAll { gone.contains($0.uid) }
            for uid in disappeared {
                await client.bodyCache.remove(
                    folder: folder.path,
                    uidValidity: uidValidity,
                    uid: uid
                )
            }
            // Mirror the in-memory prune to disk by the same explicit UID
            // list, so a confirmed-gone row can't re-hydrate on next launch.
            try await client.envelopeCache.remove(uids: disappeared, folder: folder.path)
        }
        mergeFetched(fetched)
        // Positional paging: more to load iff the loaded count is below the
        // folder's STATUS message count.
        hasMore = UInt32(envelopes.count) < totalMessages
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
    }
}
