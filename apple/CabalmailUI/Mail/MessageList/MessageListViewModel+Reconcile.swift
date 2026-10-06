import Foundation
import CabalmailKit

/// The folder STATUS the loaded window is known to line up with: when the
/// counts last agreed with the rows, the server's message total (moved since
/// by this client's own removals, `adjustTotalMessages`) and its UIDNEXT.
///
/// Every message that enters a folder takes a UID at or above UIDNEXT, so
/// between two STATUS replies `uidNext - anchor.uidNext` bounds the arrivals
/// and `arrivals - (total - anchor.total)` the removals made somewhere other
/// than this list. That is what lets a refresh tell an ordinary arrival at
/// the top of the list from a change that has moved the server's positions
/// under the loaded rows (#1817, #1818).
///
/// One change it can't see: another IMAP client flagging a message
/// `\Deleted` (or clearing the flag) without an expunge. The list's pages
/// leave such messages out while STATUS still counts them, so the window can
/// sit one row off until the expunge lowers the count.
struct WindowAnchor: Equatable {
    var total: UInt32
    var uidNext: UInt32

    /// Arrivals and removals elsewhere since the anchor, or nil when the
    /// reply can't follow from it (UIDNEXT went backwards, or more messages
    /// than UIDs arrived), in which case nothing proves where the rows sit.
    func change(toTotal newTotal: UInt32, uidNext newUidNext: UInt32) -> (arrivals: Int, removals: Int)? {
        guard newUidNext >= uidNext else { return nil }
        let arrivals = Int(newUidNext - uidNext)
        let removals = arrivals - (Int(newTotal) - Int(total))
        return removals >= 0 ? (arrivals, removals) : nil
    }
}

/// Window-alignment bookkeeping for `MessageListViewModel`, kept in one
/// stored value so the view model's type body stays small.
struct WindowAlignment {
    /// Nil while nothing proves where the loaded rows sit on the server: a
    /// window hydrated from the snapshot, or one just reset.
    var anchor: WindowAnchor?
    /// A window re-read is in flight; `ensureLoaded` starts no page meanwhile.
    var isReconciling = false
    /// Bumped whenever the window is replaced or reset, so a re-read or a
    /// top page that finds it changed under it drops its result.
    var generation = 0
    /// A re-read replaced the rows without covering everything the list is
    /// showing; the refresh that ran it loads what the viewport now lacks.
    var needsSettleLoad = false
}

// MARK: - Reconciling the loaded window with the server (#1817, #1818)

extension MessageListViewModel {
    /// Rows one server page holds at most (helper.py clamps a page to 250).
    static let windowReadLimit = 250

    /// A STATUS reply as the reconciliation reads it.
    struct WindowReading {
        let total: UInt32
        let uidNext: UInt32
        let askedAt: ContinuousClock.Instant
    }

    /// What a refresh does with the loaded window.
    enum WindowPlan: Equatable {
        /// Fold in the top page, as refreshes always have.
        case topPage
        /// The window is trimmed and nothing moved: take the counts only.
        case countsOnly
        /// Re-read these server positions and make them the window.
        case reread(Range<Int>)
    }

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

    /// Decides how a refresh treats the loaded window.
    ///
    /// The common cases cost what they always have: a quiet folder, and new
    /// mail arriving above an untrimmed window, both take the top page (the
    /// arrivals are then checked against it in `settleAnchor`). Anything the
    /// counts can't explain -- a removal made elsewhere, or any change at all
    /// under a trimmed window -- means the server's positions have moved
    /// under the rows, so the rows are read again (`rereadWindow`).
    func planWindow(_ reading: WindowReading?) -> WindowPlan {
        // An untrustworthy reply changes nothing about the window.
        guard let reading else { return hasTrimmedFront ? .countsOnly : .topPage }
        // An emptied folder is the top page's to settle (#939).
        if reading.total == 0 { return .topPage }
        let count = envelopes.count
        guard let anchor = alignment.anchor,
              let change = anchor.change(toTotal: reading.total, uidNext: reading.uidNext)
        else {
            // Nothing proves where the rows sit. A small window, or a folder
            // the top page covers, is settled by the top page itself (its
            // prune licence anchors the window); anything larger is read
            // again in one page, the same round trips as the top page.
            if hasTrimmedFront { return .reread(centredWindowRange(total: reading.total)) }
            if count <= Int(pageSize) || reading.total <= pageSize { return .topPage }
            return .reread(0..<min(Int(reading.total), count, Self.windowReadLimit))
        }
        if change.arrivals == 0 && change.removals == 0 {
            return hasTrimmedFront ? .countsOnly : .topPage
        }
        if hasTrimmedFront { return .reread(centredWindowRange(total: reading.total)) }
        // Pure arrivals usually land in the top page; so does every row of a
        // window that can't have been pushed past it, which the top page's
        // own prune then settles.
        if change.removals == 0 || count + change.arrivals <= Int(pageSize) { return .topPage }
        return .reread(coveringWindowRange(arrivals: change.arrivals, total: reading.total))
    }

    /// From the top through every position an untrimmed window's rows can
    /// have reached (each arrival pushes them down one), when that fits the
    /// window's cap; a read centred on the viewport otherwise.
    func coveringWindowRange(arrivals: Int, total: UInt32) -> Range<Int> {
        let reach = min(Int(total), envelopes.count + arrivals)
        guard reach > windowCap else { return 0..<reach }
        return centredWindowRange(total: total)
    }

    /// One page of positions centred on what the list is showing (the middle
    /// of the window when no row has reported in yet).
    func centredWindowRange(total: UInt32) -> Range<Int> {
        let total = Int(total)
        let centre: Int
        if let first = firstVisibleRow, let last = lastVisibleRow {
            centre = (first + last) / 2
        } else {
            centre = Int(windowStart) + envelopes.count / 2
        }
        let half = Self.windowReadLimit / 2
        let lower = max(0, min(centre - half, total - Self.windowReadLimit))
        return lower..<max(lower, min(total, lower + Self.windowReadLimit))
    }

    /// The window half of `refresh()`, once STATUS has answered and its
    /// counts are applied. A trimmed window that nothing moved under takes
    /// the counts only: folding in the top page would splice a gap above it.
    /// A window the server's positions moved under is read again. Otherwise
    /// the top page is folded in, and the arrivals checked against it.
    func refreshWindow(
        _ reading: WindowReading?,
        messages: UInt32,
        uidNext: UInt32,
        uidValidity: UInt32,
        serverReportsEmpty: Bool
    ) async throws {
        switch await windowPlan(for: reading) {
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
        // A re-read from an overlapping refresh may have replaced the window
        // while this page was out; folding the top into it would misplace it.
        guard generation == alignment.generation, !hasTrimmedFront else { return }
        // `serverReportsEmpty` is the server's own zero, not the `?? 0`
        // fallback `applyStatusCounts` applies: only an explicit zero licenses
        // pruning the list against an empty fetch (#939).
        let licensed = try await applyRefreshPage(fetched, uidNext: uidNext,
                                                  uidValidity: uidValidity,
                                                  serverReportsEmpty: serverReportsEmpty)
        try await settleAnchor(after: reading, licensed: licensed, uidValidity: uidValidity)
    }

    /// `refresh()`'s exit: lower `isLoading`, and if a re-read left the
    /// viewport showing positions it didn't read, load them.
    func finishRefresh() {
        isLoading = false
        if alignment.needsSettleLoad {
            alignment.needsSettleLoad = false
            scheduleEnsureLoaded()
        }
    }

    /// `planWindow`, after letting any page already in flight land: it was
    /// addressed against the old positions, so a re-read waits for it and
    /// then plans from the window it left. A re-read that still can't run
    /// (`canRereadWindow`) leaves the refresh doing what it always did.
    func windowPlan(for reading: WindowReading?) async -> WindowPlan {
        guard case .reread = planWindow(reading) else { return planWindow(reading) }
        await loadMoreTask?.value
        await loadPrevTask?.value
        await loadWindowTask?.value
        guard canRereadWindow else { return hasTrimmedFront ? .countsOnly : .topPage }
        return planWindow(reading)
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
            let range = coveringWindowRange(arrivals: change.arrivals, total: reading.total)
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
            let limit = min(Self.windowReadLimit, range.upperBound - offset)
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
        envelopes = shieldFetched(rows).sorted(by: envelopeOrder)
        windowStart = UInt32(lower)
        hasTrimmedFront = lower > 0
        hasMore = windowStart + UInt32(envelopes.count) < totalMessages
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
