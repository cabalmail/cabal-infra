import Foundation
import CabalmailKit

/// Keeps a `FolderWindowLoader`'s rows lined up with the server's positions
/// when the folder changes elsewhere (#1817, #1818): what a STATUS reading
/// says about the window, the plan it calls for (`WindowPlanner`), and the
/// re-read that replaces the window when the server's positions have moved
/// under the rows.
@MainActor
struct WindowReconciler {
    let window: FolderWindowLoader

    /// The reading a STATUS reply supports, or nil when it can't be trusted
    /// to say where the rows sit: it lacks a count or UIDNEXT, it may have
    /// been answered before a removal this list already applied, a re-read
    /// is already running, or the window changed while it was out.
    func windowReading(
        _ status: FolderStatus,
        askedAt: ContinuousClock.Instant,
        mayPredateRemoval: Bool,
        generation: Int
    ) -> WindowReading? {
        guard let messages = status.messages, let uidNext = status.uidNext, uidNext > 0,
              !mayPredateRemoval, !window.alignment.isReconciling, generation == window.alignment.generation
        else { return nil }
        return WindowReading(total: UInt32(max(0, messages)), uidNext: uidNext, askedAt: askedAt)
    }

    /// The plan, after letting any page already in flight land: it was
    /// addressed against the old positions, so a re-read waits for it and
    /// then plans from the window it left. A re-read that still can't run
    /// (`canRereadWindow`) leaves the refresh doing what it always did.
    func windowPlan(for reading: WindowReading?) async -> WindowPlan {
        guard case .reread = planner.planWindow(reading) else { return planner.planWindow(reading) }
        await window.loadMoreTask?.value
        await window.loadPrevTask?.value
        await window.loadWindowTask?.value
        guard canRereadWindow else { return window.hasTrimmedFront ? .countsOnly : .topPage }
        return planner.planWindow(reading)
    }

    /// After a top-page refresh: anchor the window if the page proved it
    /// (its prune licence) or if every arrival the counts report is now in
    /// the window. Otherwise the arrivals sorted below the top page, which
    /// is every arrival under any order but newest first (and mail moved in
    /// with an old date under that one), and the window is read again.
    func settleAnchor(
        after reading: WindowReading?,
        licensed: Bool,
        uidValidity: UInt32
    ) async throws {
        guard let reading else { return }
        if licensed {
            window.alignment.anchor = WindowAnchor(total: reading.total, uidNext: reading.uidNext)
            return
        }
        guard let anchor = window.alignment.anchor,
              let change = anchor.change(toTotal: reading.total, uidNext: reading.uidNext),
              change.removals == 0, !window.hasTrimmedFront
        else { return }
        let placed = window.envelopes.reduce(into: 0) { count, envelope in
            if envelope.uid >= anchor.uidNext && envelope.uid < reading.uidNext { count += 1 }
        }
        if placed == change.arrivals {
            window.alignment.anchor = WindowAnchor(total: reading.total, uidNext: reading.uidNext)
        } else if canRereadWindow {
            let range = planner.coveringWindowRange(arrivals: change.arrivals, total: reading.total)
            try await rereadReportingTopFailures(range, reading: reading, uidValidity: uidValidity)
        }
    }

    /// `rereadWindow`, with a failure reported only for a read from the top:
    /// that one stands in for the top page, whose failure the list shows. A
    /// deep read fails quietly, as paging does.
    func rereadReportingTopFailures(
        _ range: Range<Int>,
        reading: WindowReading,
        uidValidity: UInt32
    ) async throws {
        let deep = window.hasTrimmedFront || range.lowerBound > 0
        do {
            try await rereadWindow(range, reading: reading, uidValidity: uidValidity)
        } catch {
            if !deep { throw error }
        }
    }

    /// The window planner over the window as it stands now.
    private var planner: WindowPlanner {
        WindowPlanner(
            loadedCount: window.envelopes.count, windowStart: window.windowStart,
            hasTrimmedFront: window.hasTrimmedFront, anchor: window.alignment.anchor,
            firstVisibleRow: window.firstVisibleRow, lastVisibleRow: window.lastVisibleRow,
            pageSize: window.pageSize, windowCap: window.windowCap
        )
    }

    /// Whether a re-read may replace the window now. Not while a page is in
    /// flight (it was addressed against the old positions and would land on
    /// top of the new rows), not under a bulk selection the user is building,
    /// and not over search results. The refresh then behaves as it always
    /// has and the next one tries again, since the anchor hasn't moved.
    private var canRereadWindow: Bool {
        !window.isLoadingMore && !window.isLoadingPrevious && !window.isLoadingWindow
            && !window.isBuildingBulkSelection && !window.isSearchActive
    }

    /// Reads `range` of the folder's positions in the current sort and makes
    /// it the window, anchored to `reading`. Rows the read proves gone leave
    /// the body cache and the envelope snapshot too, so they can't come back
    /// on the next launch; rows it merely didn't cover stay on disk.
    ///
    /// A row is proven gone only by a read from the top that reaches every
    /// position the old rows can have moved to: the old window's extent plus
    /// one per arrival since the anchor. A read that holds a UID at or above
    /// the reading's UIDNEXT saw mail arrive after the STATUS, so it proves
    /// nothing; nor does any read when the window had no anchor, except one
    /// that holds the whole folder, which also clears snapshot rows from
    /// earlier sessions.
    private func rereadWindow(_ range: Range<Int>, reading: WindowReading, uidValidity: UInt32) async throws {
        guard !range.isEmpty else { return }
        let judged = Set(window.envelopes.map(\.uid))
        let wasTop = !window.hasTrimmedFront
        let reach = window.alignment.anchor
            .flatMap { $0.change(toTotal: reading.total, uidNext: reading.uidNext) }
            .map { window.envelopes.count + $0.arrivals }
        let generation = window.alignment.generation
        let sort = window.sortCriterion
        window.alignment.isReconciling = true
        defer { window.alignment.isReconciling = false }
        let read = try await readPositions(range, sort: sort)
        // Abandon on any change while the read was out; the anchor stays, so
        // the next refresh plans again. A blank read is never "the folder
        // emptied" while STATUS still counts messages.
        guard let read, generation == window.alignment.generation, sort == window.sortCriterion,
              !window.removalMayPostdate(reading.askedAt), !window.isSearchActive,
              !(read.rows.isEmpty && reading.total > 0)
        else { return }
        installWindow(read.rows, at: range.lowerBound)
        window.alignment.anchor = WindowAnchor(total: reading.total, uidNext: reading.uidNext)
        guard range.lowerBound == 0, wasTop,
              !read.rows.contains(where: { $0.uid >= reading.uidNext })
        else { return }
        let readUIDs = Set(read.rows.map(\.uid))
        var gone: Set<UInt32> = []
        if let reach, read.end >= min(Int(reading.total), reach) {
            gone = judged.subtracting(readUIDs)
        }
        if read.rows.count >= Int(reading.total),
           let cached = await window.client.envelopeCache.snapshot(for: window.folder.path)?.envelopes.keys {
            gone.formUnion(cached.filter { $0 < reading.uidNext && !readUIDs.contains($0) })
        }
        try await forgetEnvelopes(gone, uidValidity: uidValidity)
        try await window.client.envelopeCache.merge(
            envelopes: window.shieldFetched(read.rows),
            uidValidity: uidValidity,
            uidNext: reading.uidNext,
            into: window.folder.path
        )
    }

    /// Reads `range` in server pages, each after the first starting on the
    /// previous page's last position, so the two must share exactly one
    /// message: a folder that changed between two pages breaks that seam and
    /// the read is abandoned (nil). A short page ends the read early. Rows
    /// within a page carry no order, so only the set of rows and how far the
    /// read reached (`end`, one past the last position it covered) count.
    private func readPositions(
        _ range: Range<Int>,
        sort: SortCriterion
    ) async throws -> (rows: [Envelope], end: Int)? {
        var rows: [Envelope] = []
        var seen: Set<UInt32> = []
        var previous: Set<UInt32>?
        var offset = range.lowerBound
        while true {
            let limit = min(WindowPlanner.windowReadLimit, range.upperBound - offset)
            let page = try await window.client.imapClient.envelopes(
                folder: window.folder.path,
                offset: UInt32(offset),
                limit: UInt32(limit),
                sort: sort
            )
            let pageUIDs = Set(page.map(\.uid))
            if let previous, previous.intersection(pageUIDs).count != 1 { return nil }
            for envelope in page where seen.insert(envelope.uid).inserted {
                rows.append(envelope)
            }
            let end = offset + page.count
            if page.count < limit || end >= range.upperBound { return (rows, end) }
            previous = pageUIDs
            offset = end - 1
        }
    }

    /// Makes `rows` (server positions from `lower`) the loaded window.
    private func installWindow(_ rows: [Envelope], at lower: Int) {
        let windowEnd = window.windowStart + UInt32(window.envelopes.count)
        window.envelopes = window.shieldFetched(rows).sorted(by: window.envelopeOrder)
        window.windowStart = UInt32(lower)
        window.hasTrimmedFront = lower > 0
        window.recomputeHasMore(windowEndBefore: windowEnd)
        window.invalidateBottomPrefetch()
        window.alignment.generation += 1
        if let first = window.firstVisibleRow, let last = window.lastVisibleRow,
           first < lower || last >= lower + window.envelopes.count {
            window.alignment.needsSettleLoad = true
        }
    }

    /// Drops messages proven gone from the body cache and the envelope
    /// snapshot (which also takes them out of Spotlight).
    private func forgetEnvelopes(_ gone: Set<UInt32>, uidValidity: UInt32) async throws {
        guard !gone.isEmpty else { return }
        for uid in gone {
            await window.client.bodyCache.remove(folder: window.folder.path, uidValidity: uidValidity, uid: uid)
        }
        try await window.client.envelopeCache.remove(uids: gone.sorted(), folder: window.folder.path)
    }
}
