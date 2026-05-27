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
    /// `applyRefreshPage`'s `replace(... keepingRange:)` only prunes
    /// UIDs *inside* the refresh window — UIDs outside it are treated
    /// as "older pages" and retained. Foreign-folder UIDs that leaked
    /// into the cache (historically through pagination during search)
    /// sit below the inbox's current UID band, so without an explicit
    /// invalidate they'd survive every subsequent refresh and re-
    /// hydrate as phantoms on relaunch. The body cache is left alone:
    /// it's keyed per-UID, never blindly batch-written, and an
    /// unrelated phantom never reached the fetch path far enough to
    /// land a body in it.
    func hardReload() async {
        try? await client.envelopeCache.invalidate(folder: folder.path)
        envelopes.removeAll()
        lowestUID = nil
        hasMore = true
        sourceFolderByUID = [:]
        await refresh()
    }

    /// Merges a fresh fetch into the in-memory envelope dictionary and
    /// re-sorts using the active `sortCriterion`. Used by both the top-
    /// page refresh and the older-page paginator — neither needs to know
    /// which sort is active, only that "the visible list should now
    /// include these too."
    func mergeFetched(_ fetched: [Envelope]) {
        var byUID: [UInt32: Envelope] = Dictionary(
            uniqueKeysWithValues: envelopes.map { ($0.uid, $0) }
        )
        for envelope in fetched {
            byUID[envelope.uid] = envelope
        }
        envelopes = byUID.values.sorted(by: envelopeOrder)
    }

    /// Merges a top-page fetch into in-memory state and the envelope cache.
    /// For the default REVERSE ARRIVAL sort, `keepingRange` covers
    /// `min(fetched.uid)...uidNext` and any in-memory envelope in that band
    /// missing from the fetch was moved or expunged elsewhere. Non-default
    /// sorts span the whole folder with their top page, so we suppress the
    /// disappear-detection there — accepting that server-side deletes show
    /// up later (on the next folder switch) is the right trade vs. mass-
    /// pruning cached envelopes on every IDLE refresh.
    func applyRefreshPage(
        _ fetched: [Envelope],
        uidNext: UInt32,
        uidValidity: UInt32
    ) async throws {
        let fetchedUIDs = Set(fetched.map(\.uid))
        let isDefaultSort = sortCriterion == .default
        let keepingRange: ClosedRange<UInt32>? = isDefaultSort
            ? fetched.map(\.uid).min().map { lower in lower...max(uidNext, lower) }
            : nil
        let disappeared: [UInt32] = keepingRange.map { range in
            envelopes.map(\.uid).filter { range.contains($0) && !fetchedUIDs.contains($0) }
        } ?? (isDefaultSort ? envelopes.map(\.uid) : [])
        if !disappeared.isEmpty {
            envelopes.removeAll { disappeared.contains($0.uid) }
            for uid in disappeared {
                await client.bodyCache.remove(
                    folder: folder.path,
                    uidValidity: uidValidity,
                    uid: uid
                )
            }
        }
        mergeFetched(fetched)
        lowestUID = envelopes.map(\.uid).min() ?? lowestUID
        hasMore = (lowestUID ?? 0) > 1
        try await client.envelopeCache.replace(
            envelopes: fetched,
            uidValidity: uidValidity,
            uidNext: uidNext,
            keepingRange: keepingRange,
            into: folder.path
        )
    }
}
