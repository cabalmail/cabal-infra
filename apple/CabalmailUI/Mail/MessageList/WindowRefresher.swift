import Foundation
import CabalmailKit

/// A STATUS already asked for, and when, for `refresh(prefetched:)`.
/// `ask` is the refresh ask numbered just before it was asked for, so the
/// pass it seeds answers no refresh asked for after it (`RefreshFlight`).
struct PrefetchedStatus {
    let status: FolderStatus
    let askedAt: ContinuousClock.Instant
    let ask: Int
}

/// Refreshing a `FolderWindowLoader` from the server: the single-flight
/// refresh and its passes, the top page, and the two resets that rebuild
/// the window (a hard reload and a sort change).
@MainActor
struct WindowRefresher {
    let window: FolderWindowLoader

    /// Single-flight (#1820, `RefreshFlight`): a refresh asked for while a
    /// pass is out waits for it, then for one more pass that asks STATUS
    /// afresh and answers every refresh that waited. `isLoading` stays up
    /// until the last of them returns. `prefetched` is a STATUS already asked
    /// for, used rather than asked for again unless the refresh had to wait.
    /// `startingOver` marks a reset's refresh (`hardReload`, `setSort`,
    /// leaving a search), which runs at once: the reset has already stood
    /// down whatever the pass out was for. The pass runs in the caller's task,
    /// so a cancelled caller's refresh stops without applying anything.
    func refresh(prefetched: PrefetchedStatus?, startingOver: Bool) async {
        window.holdLoading()
        defer { window.releaseLoading() }
        let ask = prefetched?.ask ?? window.refreshFlight.ask()
        var status = prefetched
        var supersede = startingOver
        // A cancelled caller stops asking; a search that starts meanwhile
        // makes the folder's refresh moot.
        while !window.refreshFlight.hasAnswered(ask), !Task.isCancelled, !window.isSearchActive {
            if window.refreshFlight.current != nil, !supersede {
                await withCheckedContinuation { window.refreshFlight.park($0) }
                status = nil
                continue
            }
            let pass = window.refreshFlight.begin(answeringThrough: status?.ask)
            await refreshPass(prefetched: status)
            for waiter in window.refreshFlight.end(pass, finished: !Task.isCancelled) {
                waiter.resume()
            }
            supersede = false
            status = nil
        }
    }

    /// The folder half of the user's "force reload": ask the server first,
    /// then drop the rows and the on-disk snapshot and start the window over
    /// at the top, for the refresh the caller runs with the returned STATUS.
    /// Nil, with the error shown and the rows kept, when the server can't be
    /// reached: offline the wipe used to run anyway, and with the snapshot
    /// went the folder's rows for every later offline launch and its
    /// Spotlight entries (#1796).
    ///
    /// The snapshot goes because a refresh prunes it only of rows it can
    /// prove gone (`applyRefreshPage` while the window fits the top page, a
    /// re-read only within what it read), so rows that leaked into it would
    /// otherwise survive every refresh and come back as phantoms on relaunch.
    func resetForHardReload() async -> PrefetchedStatus? {
        guard let probe = await probeBeforeReset() else { return nil }
        try? await window.client.envelopeCache.invalidate(folder: window.folder.path)
        window.envelopes.removeAll()
        window.totalMessages = 0
        window.savedMessageCount = nil
        window.hasMore = true
        window.resetWindow()
        return probe
    }

    /// Switches the order and reloads the window in it (sort is a reshuffle
    /// from the top, not a filter: the pages are per-order). No-op when the
    /// criterion doesn't change, so a repeat click costs nothing. The menu is
    /// off during a search (`sortApplies`); a pick whose probe a search
    /// overtook is only recorded, for the folder view the search returns to.
    func setSort(_ criterion: SortCriterion) async {
        guard window.sortCriterion != criterion else { return }
        // Set at once, so the menu shows it and a second pick builds on it.
        let previous = window.sortCriterion
        window.sortCriterion = criterion
        // The spinner holds from the probe through the refresh it hands to.
        window.holdLoading()
        defer { window.releaseLoading() }
        // The new order comes from the server, so ask it before dropping the
        // list. Offline the wipe used to run anyway and leave the list empty
        // (#1796); now the list stays, and the order goes back unless a newer
        // pick has replaced it. Cached rows can't stand in: they're a window
        // of the old order, and merged with the new order's first page they'd
        // leave gaps in it.
        guard let probe = await probeBeforeReset() else {
            if window.sortCriterion == criterion { window.sortCriterion = previous }
            return
        }
        // A newer pick arrived during the wait, and does the reset itself.
        guard window.sortCriterion == criterion else { return }
        // A search started while the probe was out (a pill, say). Its results
        // keep the server's order (see `sortApplies`), so the pick is kept for
        // the folder view the search returns to: wiping the rows to re-run
        // the search would only cut a deep result set back to one page. The
        // probe's counts are applied rather than dropped (#1822).
        if window.isSearchActive {
            _ = window.applyStatusCounts(
                probe.status, mayPredateRemoval: window.removalMayPostdate(probe.askedAt), askedAt: probe.askedAt
            )
            return
        }
        window.envelopes.removeAll()
        window.resetWindow()
        await refresh(prefetched: probe, startingOver: true)
        // Re-stage the bottom window in the new order (resetWindow dropped the
        // old one) so End stays instant after a re-sort.
        window.scheduleBottomPrefetch()
    }

    /// One refresh pass: STATUS (or the one prefetched), the counts, then the
    /// window. A reset or a search that starts while one of its awaits is
    /// out moves the window's generation, and the pass then leaves the list
    /// to it (#1870).
    private func refreshPass(prefetched: PrefetchedStatus?) async {
        let startedAt = prefetched?.askedAt ?? ContinuousClock.now
        var generation = window.alignment.generation
        do {
            // flagged: true asks for the SEARCH FLAGGED count too -- this is the
            // one status call that drives the filter-pill counts.
            let status: FolderStatus
            if let prefetched {
                status = prefetched.status
            } else {
                status = try await window.client.folderStatus(path: window.folder.path, flagged: true)
                guard generation == window.alignment.generation else { return }
            }
            // Only a concrete, *changed* UIDVALIDITY means "rebuild from
            // scratch." A missing/zero reading from a flaky STATUS must not
            // wipe a scrolled, paginated list back to the top page on a
            // routine background refresh.
            if let fresh = status.uidValidity, fresh != 0 {
                if let known = window.uidValidity, known != fresh {
                    try? await window.client.envelopeCache.invalidate(folder: window.folder.path)
                    try? await window.client.bodyCache.invalidate(folder: window.folder.path)
                    guard generation == window.alignment.generation else { return }
                    window.envelopes = []
                    window.resetWindow()
                    window.mailStore.shields.clearConfirmedRemovals(folderPath: window.folder.path)
                    generation = window.alignment.generation
                }
                window.uidValidity = fresh
            }
            let uidValidity = window.uidValidity ?? 0
            // The top page is fetched by sequence number (robust on sparse
            // folders); `totalMessages` from STATUS gates pagination and
            // drives the All pill, the store the Unread and Flagged pills.
            let mayPredate = window.removalMayPostdate(startedAt)
            _ = window.applyStatusCounts(status, mayPredateRemoval: mayPredate, askedAt: startedAt)
            let reading = window.reconciler.windowReading(status, askedAt: startedAt,
                                                          mayPredateRemoval: mayPredate, generation: generation)
            // Whether the loaded rows still sit where the server has them
            // decides what comes next: usually the top page, as always.
            try await refreshWindow(reading, status: status, generation: generation, uidValidity: uidValidity)
            window.host?.errorMessage = nil
        } catch {
            // A refresh whose task was cancelled (the 60-second poll's, the
            // watcher's, when the list leaves the screen) has nothing to
            // report; "cancelled" would stay on a list that is fine (#1816).
            guard !Task.isCancelled else { return }
            window.host?.errorMessage = error.localizedDescription
        }
    }

    /// The window half of a pass, once `status` has answered and its counts
    /// are applied. A trimmed window that nothing moved under takes the
    /// counts only: folding in the top page would splice a gap above it. A
    /// window the server's positions moved under is read again. Otherwise the
    /// top page is folded in, and the arrivals checked against it.
    /// `generation` is the pass's: a reset or a search that moves it while
    /// the plan waits on a page in flight leaves the list to them (#1870).
    private func refreshWindow(
        _ reading: WindowReading?,
        status: FolderStatus,
        generation passGeneration: Int,
        uidValidity: UInt32
    ) async throws {
        // The top page is addressed in the server's own numbering.
        let messages = UInt32(max(0, status.messages ?? 0))
        let plan = await window.reconciler.windowPlan(for: reading)
        guard passGeneration == window.alignment.generation else { return }
        switch plan {
        case .countsOnly:
            return
        case .reread(let range):
            guard let reading else { return }
            try await window.reconciler.rereadReportingTopFailures(range, reading: reading, uidValidity: uidValidity)
            return
        case .topPage:
            break
        }
        // A deep window can only reach here with the folder emptied; start
        // it over at the top for the top page to prune.
        if window.hasTrimmedFront && messages == 0 { window.resetWindow() }
        let generation = window.alignment.generation
        let fetched = try await window.client.imapClient.topEnvelopes(
            folder: window.folder.path,
            limit: window.pageSize,
            totalMessages: messages,
            sort: window.sortCriterion
        )
        // A reset or a search may have replaced the window while this page
        // was out, or a jump moved it off the top; folding the top into it
        // would misplace it.
        guard generation == window.alignment.generation, !window.hasTrimmedFront else { return }
        // `serverReportsEmpty` is the server's own zero, not the `?? 0`
        // fallback `applyStatusCounts` applies: only an explicit zero licenses
        // pruning the list against an empty fetch (#939).
        let licensed = try await applyRefreshPage(fetched, uidNext: status.uidNext ?? 1,
                                                  uidValidity: uidValidity,
                                                  serverReportsEmpty: status.messages == 0)
        // The page's caches were written after its rows; whatever replaced
        // the rows meanwhile anchors its own window.
        guard generation == window.alignment.generation else { return }
        try await window.reconciler.settleAnchor(after: reading, licensed: licensed, uidValidity: uidValidity)
    }

    /// Merges a top-page fetch into the rows and the envelope cache, pruning
    /// rows the server no longer returns -- but only when that is safe.
    ///
    /// The top page is authoritative over the top page alone, so the prune is
    /// bounded by position, not by a UID band (the client and server orders
    /// can disagree, so a band could span the whole folder):
    ///   * The whole window fits in the top page: a row missing from the
    ///     fetch was moved or expunged under us, so it goes.
    ///   * The window runs past the top page: no prune here; the fetch can't
    ///     see the tail. A removal made elsewhere is caught by the counts
    ///     instead (`WindowPlanner`), which re-read the window by position.
    ///   * ...unless the fetch now spans the whole folder (STATUS counts no
    ///     more messages than were fetched, and fewer than are loaded): then
    ///     any loaded row missing from it is provably gone, which is how a
    ///     bulk archive made elsewhere clears from a deep window.
    /// An empty fetch is never "everything vanished" unless STATUS says so
    /// too, with the server's own 0 (`serverReportsEmpty`): a folder that
    /// really emptied would otherwise keep its rows forever (#939), and a
    /// STATUS that dropped the field must not wipe a live list.
    @discardableResult
    private func applyRefreshPage(
        _ fetched: [Envelope],
        uidNext: UInt32,
        uidValidity: UInt32,
        serverReportsEmpty: Bool = false
    ) async throws -> Bool {
        let windowEnd = window.windowStart + UInt32(window.envelopes.count)
        let windowFitsTopPage = UInt32(window.envelopes.count) <= window.pageSize
        let fetchSpansFolder = UInt32(fetched.count) >= window.totalMessages
            && UInt32(window.envelopes.count) > window.totalMessages
        let licensed = (!fetched.isEmpty || serverReportsEmpty) && (windowFitsTopPage || fetchSpansFolder)
        let disappeared: [UInt32]
        if licensed {
            let fetchedUIDs = Set(fetched.map(\.uid))
            // A row we're removing ourselves is exempt: a refresh landing in
            // the moment between a dispose's move committing and the row
            // finishing its fade-then-collapse would otherwise see it absent
            // from the fetch and yank it out instantly -- the very jump the
            // animation exists to avoid. `dispose(_:)` removes it either way.
            disappeared = window.envelopes.map(\.uid).filter {
                !fetchedUIDs.contains($0)
                    && !window.pendingRemovedRefs.contains(MessageRef(folder: window.folder.path, uid: $0))
            }
        } else {
            disappeared = []
        }
        // The rows first, with no await between the caller's generation
        // check and them; the caches after, which are the folder's whatever
        // the list shows by then.
        if !disappeared.isEmpty {
            let gone = Set(disappeared)
            window.envelopes.removeAll { gone.contains($0.uid) }
        }
        window.mergeFetched(fetched)
        window.recomputeHasMore(windowEndBefore: windowEnd)
        for uid in disappeared {
            await window.client.bodyCache.remove(folder: window.folder.path, uidValidity: uidValidity, uid: uid)
        }
        // Mirror the in-memory prune to disk by the same explicit UID list,
        // so a confirmed-gone row can't re-hydrate on next launch.
        if !disappeared.isEmpty {
            try await window.client.envelopeCache.remove(uids: disappeared, folder: window.folder.path)
        }
        // Upsert the shielded fresh page into the snapshot: a row being
        // removed stays out of it, and a row with a flag write in flight keeps
        // the flags it shows, or a refresh landing mid-write would re-seed the
        // cache with pre-write state for the next launch.
        try await window.client.envelopeCache.merge(
            envelopes: window.shieldFetched(fetched),
            uidValidity: uidValidity,
            uidNext: uidNext,
            into: window.folder.path
        )
        return licensed
    }

    /// The folder's counts from one STATUS (or the one prefetched), with no
    /// page: a search showing in the window's place still moves the pills
    /// and the sidebar badge (#1819). A STATUS that fails changes nothing.
    func refreshCounts(prefetched: PrefetchedStatus?) async {
        let startedAt = prefetched?.askedAt ?? ContinuousClock.now
        let status: FolderStatus?
        if let prefetched {
            status = prefetched.status
        } else {
            status = try? await window.client.folderStatus(path: window.folder.path, flagged: true)
        }
        if let status {
            _ = window.applyStatusCounts(
                status, mayPredateRemoval: window.removalMayPostdate(startedAt), askedAt: startedAt
            )
        }
    }

    /// Asks the server for this folder's STATUS before a reset that drops the
    /// list (`hardReload`, `setSort`). Nil, with the error shown, when it
    /// can't be reached: the caller then keeps the list as it is (#1796).
    /// The caller holds `isLoading` up from before the probe until its reset
    /// is done, so the list shows its spinner, the Refresh button stays
    /// disabled and no page loads in between.
    private func probeBeforeReset() async -> PrefetchedStatus? {
        let ask = window.refreshFlight.ask()
        let askedAt = ContinuousClock.now
        do {
            let status = try await window.client.folderStatus(path: window.folder.path, flagged: true)
            return PrefetchedStatus(status: status, askedAt: askedAt, ask: ask)
        } catch {
            window.host?.errorMessage = error.localizedDescription
            return nil
        }
    }
}
