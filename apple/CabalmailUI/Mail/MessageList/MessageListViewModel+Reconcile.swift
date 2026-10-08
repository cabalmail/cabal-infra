import Foundation
import CabalmailKit

/// Window-alignment bookkeeping for `MessageListViewModel`, kept in one
/// stored value so the view model's type body stays small.
struct WindowAlignment {
    /// Nil while nothing proves where the loaded rows sit on the server: a
    /// window hydrated from the snapshot, or one just reset.
    var anchor: WindowAnchor?
    /// A window re-read is in flight; `ensureLoaded` starts no page meanwhile.
    var isReconciling = false
    /// Moved whenever the rows on screen are replaced or reset, or a search
    /// starts or installs its results. Every page load, the bottom prefetch
    /// and each await of a refresh pass compare it after the await, and drop
    /// what they brought when it moved.
    var generation = 0
    /// The viewport may show positions with no rows: a re-read replaced the
    /// rows without covering everything the list is showing, or a search
    /// stood the window's loads down and then didn't take the list over.
    /// What it lacks loads once `isLoading` falls.
    var needsSettleLoad = false
}

// MARK: - Reconciling the loaded window with the server (#1817, #1818)

extension MessageListViewModel {
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
              !mayPredateRemoval, !alignment.isReconciling, generation == alignment.generation
        else { return nil }
        return WindowReading(total: UInt32(max(0, messages)), uidNext: uidNext, askedAt: askedAt)
    }

    /// The window planner over the window as it stands now.
    private var planner: WindowPlanner {
        WindowPlanner(
            loadedCount: envelopes.count, windowStart: windowStart, hasTrimmedFront: hasTrimmedFront,
            anchor: alignment.anchor, firstVisibleRow: firstVisibleRow, lastVisibleRow: lastVisibleRow,
            pageSize: pageSize, windowCap: windowCap
        )
    }

    /// The window half of `refresh()`, once `status` has answered and its
    /// counts are applied. A trimmed window that nothing moved under takes
    /// the counts only: folding in the top page would splice a gap above it.
    /// A window the server's positions moved under is read again. Otherwise
    /// the top page is folded in, and the arrivals checked against it.
    /// `generation` is the pass's: a reset or a search that moves it while
    /// the plan waits on a page in flight leaves the list to them (#1870).
    func refreshWindow(
        _ reading: WindowReading?,
        status: FolderStatus,
        generation passGeneration: Int,
        uidValidity: UInt32
    ) async throws {
        // The top page is addressed in the server's own numbering.
        let messages = UInt32(max(0, status.messages ?? 0))
        let plan = await windowPlan(for: reading)
        guard passGeneration == alignment.generation else { return }
        switch plan {
        case .countsOnly:
            return
        case .reread(let range):
            guard let reading else { return }
            try await rereadReportingTopFailures(range, reading: reading, uidValidity: uidValidity)
            return
        case .topPage:
            break
        }
        // A deep window can only reach here with the folder emptied; start
        // it over at the top for the top page to prune.
        if hasTrimmedFront && messages == 0 { resetWindow() }
        let generation = alignment.generation
        let fetched = try await client.imapClient.topEnvelopes(
            folder: folder.path,
            limit: pageSize,
            totalMessages: messages,
            sort: sortCriterion
        )
        // A reset or a search may have replaced the window while this page
        // was out, or a jump moved it off the top; folding the top into it
        // would misplace it.
        guard generation == alignment.generation, !hasTrimmedFront else { return }
        // `serverReportsEmpty` is the server's own zero, not the `?? 0`
        // fallback `applyStatusCounts` applies: only an explicit zero licenses
        // pruning the list against an empty fetch (#939).
        let licensed = try await applyRefreshPage(fetched, uidNext: status.uidNext ?? 1,
                                                  uidValidity: uidValidity,
                                                  serverReportsEmpty: status.messages == 0)
        // The page's caches were written after its rows; whatever replaced
        // the rows meanwhile anchors its own window.
        guard generation == alignment.generation else { return }
        try await settleAnchor(after: reading, licensed: licensed, uidValidity: uidValidity)
    }

    /// `planWindow`, after letting any page already in flight land: it was
    /// addressed against the old positions, so a re-read waits for it and
    /// then plans from the window it left. A re-read that still can't run
    /// (`canRereadWindow`) leaves the refresh doing what it always did.
    func windowPlan(for reading: WindowReading?) async -> WindowPlan {
        guard case .reread = planner.planWindow(reading) else { return planner.planWindow(reading) }
        await loadMoreTask?.value
        await loadPrevTask?.value
        await loadWindowTask?.value
        guard canRereadWindow else { return hasTrimmedFront ? .countsOnly : .topPage }
        return planner.planWindow(reading)
    }

    /// Whether a re-read may replace the window now. Not while a page is in
    /// flight (it was addressed against the old positions and would land on
    /// top of the new rows), not under a bulk selection the user is building,
    /// and not over search results. The refresh then behaves as it always
    /// has and the next one tries again, since the anchor hasn't moved.
    var canRereadWindow: Bool {
        !isLoadingMore && !isLoadingPrevious && !isLoadingWindow
            && !(bulkMode && !selectedRefs.isEmpty) && !isSearchActive
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
            alignment.anchor = WindowAnchor(total: reading.total, uidNext: reading.uidNext)
            return
        }
        guard let anchor = alignment.anchor,
              let change = anchor.change(toTotal: reading.total, uidNext: reading.uidNext),
              change.removals == 0, !hasTrimmedFront
        else { return }
        let placed = envelopes.reduce(into: 0) { count, envelope in
            if envelope.uid >= anchor.uidNext && envelope.uid < reading.uidNext { count += 1 }
        }
        if placed == change.arrivals {
            alignment.anchor = WindowAnchor(total: reading.total, uidNext: reading.uidNext)
        } else if canRereadWindow {
            let range = planner.coveringWindowRange(arrivals: change.arrivals, total: reading.total)
            try await rereadReportingTopFailures(range, reading: reading, uidValidity: uidValidity)
        }
    }

    /// `rereadWindow`, with a failure reported only for a read from the top:
    /// that one stands in for the top page, whose failure the list shows. A
    /// deep read fails quietly, as paging does.
    private func rereadReportingTopFailures(
        _ range: Range<Int>,
        reading: WindowReading,
        uidValidity: UInt32
    ) async throws {
        let deep = hasTrimmedFront || range.lowerBound > 0
        do {
            try await rereadWindow(range, reading: reading, uidValidity: uidValidity)
        } catch {
            if !deep { throw error }
        }
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
    func rereadWindow(_ range: Range<Int>, reading: WindowReading, uidValidity: UInt32) async throws {
        guard !range.isEmpty else { return }
        let judged = Set(envelopes.map(\.uid))
        let wasTop = !hasTrimmedFront
        let reach = alignment.anchor
            .flatMap { $0.change(toTotal: reading.total, uidNext: reading.uidNext) }
            .map { envelopes.count + $0.arrivals }
        let generation = alignment.generation
        let sort = sortCriterion
        alignment.isReconciling = true
        defer { alignment.isReconciling = false }
        let read = try await readPositions(range, sort: sort)
        // Abandon on any change while the read was out; the anchor stays, so
        // the next refresh plans again. A blank read is never "the folder
        // emptied" while STATUS still counts messages.
        guard let read, generation == alignment.generation, sort == sortCriterion,
              !removalMayPostdate(reading.askedAt), !isSearchActive,
              !(read.rows.isEmpty && reading.total > 0)
        else { return }
        installWindow(read.rows, at: range.lowerBound)
        alignment.anchor = WindowAnchor(total: reading.total, uidNext: reading.uidNext)
        guard range.lowerBound == 0, wasTop,
              !read.rows.contains(where: { $0.uid >= reading.uidNext })
        else { return }
        let readUIDs = Set(read.rows.map(\.uid))
        var gone: Set<UInt32> = []
        if let reach, read.end >= min(Int(reading.total), reach) {
            gone = judged.subtracting(readUIDs)
        }
        if read.rows.count >= Int(reading.total),
           let cached = await client.envelopeCache.snapshot(for: folder.path)?.envelopes.keys {
            gone.formUnion(cached.filter { $0 < reading.uidNext && !readUIDs.contains($0) })
        }
        try await forgetEnvelopes(gone, uidValidity: uidValidity)
        try await client.envelopeCache.merge(
            envelopes: shieldFetched(read.rows),
            uidValidity: uidValidity,
            uidNext: reading.uidNext,
            into: folder.path
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
            let page = try await client.imapClient.envelopes(
                folder: folder.path,
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
        let windowEnd = windowStart + UInt32(envelopes.count)
        envelopes = shieldFetched(rows).sorted(by: envelopeOrder)
        windowStart = UInt32(lower)
        hasTrimmedFront = lower > 0
        recomputeHasMore(windowEndBefore: windowEnd)
        invalidateBottomPrefetch()
        alignment.generation += 1
        if let first = firstVisibleRow, let last = lastVisibleRow,
           first < lower || last >= lower + envelopes.count {
            alignment.needsSettleLoad = true
        }
    }

    /// Drops messages proven gone from the body cache and the envelope
    /// snapshot (which also takes them out of Spotlight).
    private func forgetEnvelopes(_ gone: Set<UInt32>, uidValidity: UInt32) async throws {
        guard !gone.isEmpty else { return }
        for uid in gone {
            await client.bodyCache.remove(folder: folder.path, uidValidity: uidValidity, uid: uid)
        }
        try await client.envelopeCache.remove(uids: gone.sorted(), folder: folder.path)
    }

    /// The window no longer lines up with anything known: hydrated from the
    /// snapshot, or reset. The next trustworthy refresh decides afresh.
    func forgetWindowAnchor() {
        alignment.anchor = nil
        alignment.generation += 1
    }
}
