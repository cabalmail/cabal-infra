import Foundation

/// Keeps `RssStore` current with the server and pushes the user's local
/// state changes back (docs/1.x/rss-implementation-plan.md, phase 5).
///
/// Three jobs, all idempotent:
///   * `refreshCatalog()` - folders and subscriptions from the server; the
///     store deletes what departed and reports it so the app can drop the
///     matching web-view storage.
///   * `syncItems(for:)` - a feed's items. A feed with no cursor yet is
///     populated newest-first (`initialPageSize` items) and its cursor set
///     to the largest `fetchedKey` seen; after that it follows the server's
///     since-sync (ingest-time cursor) in pages until `hasMore` is false,
///     bounded per run so one huge feed cannot monopolise a refresh. Then
///     the feed's state sync: the read/favorite marks changed on the
///     server (by another device, or by a mark-all-read's flip) since the
///     feed's state cursor, applied to the cached items. Without it a mark
///     made elsewhere never arrives, because ingest time does not move
///     when state does.
///   * `drainPending()` - the offline mutation queue, replayed in the
///     order the user made the changes: item marks coalesced into
///     `/rss_set_item_state` batches, each `/rss_mark_all_read` a fence
///     between batches. A failure leaves the queue intact for the next
///     attempt.
///
/// Single flight: the app asks from several places at once (the session's
/// poller, the Feeds sidebar, the item list, the reader's marks), so the
/// work is shared rather than repeated. There is one `syncAll` pass, one sync
/// per feed (which `syncAll` and the scope syncs join), and one drain, with a
/// drain asked for mid-pass getting one more pass so a change queued after
/// the pass read the queue still goes. A caller whose task is cancelled stops
/// waiting and gets nothing back; the work stops once nobody waits for it
/// (`SharedRun`).
///
/// The engine never decides *when* to run; the app calls it from its
/// triggers (selection, foreground, background refresh, reconnect).
public actor RssSyncEngine {
    public let client: RssClient
    public let store: RssStore
    /// Items fetched for a subscription with no sync history.
    public var initialPageSize = 100
    /// Page size for since-sync and "load older".
    public var pageSize = 100
    /// Since-sync pages per feed per run.
    public var maxPagesPerRun = 5
    /// Feeds synced at once by `syncAll` and the scope syncs.
    public var concurrency = 4

    /// The `syncAll` pass in flight.
    private var allFlight: Flight<RssSyncReport>?
    /// Each feed's sync in flight, by feed id.
    private var feedFlights: [String: Flight<Result<Int, Error>>] = [:]
    /// The pending queue's pusher.
    private let pending: RssPendingDrain

    /// Callers waiting on the `syncAll` pass in flight, on a feed's sync, and
    /// on the drain queued behind the one pushing: the tests' view of a join.
    var syncAllWaiterCount: Int { allFlight?.run.waiterCount ?? 0 }
    func feedSyncWaiterCount(_ feedId: String) -> Int { feedFlights[feedId]?.run.waiterCount ?? 0 }
    var queuedDrainWaiterCount: Int { get async { await pending.queuedWaiterCount } }

    public init(client: RssClient, store: RssStore) {
        self.client = client
        self.store = store
        pending = RssPendingDrain(client: client, store: store)
    }

    // MARK: - Catalog

    @discardableResult
    public func refreshCatalog() async throws -> RssStore.CatalogDiff {
        let catalog = try await client.listSubscriptions()
        return try await store.replaceCatalog(catalog)
    }

    // MARK: - Items

    /// Syncs one subscription's items; returns how many the store received.
    /// A sync of the same feed already in flight is joined, not repeated.
    /// Throws `CancellationError` when the caller is cancelled first.
    @discardableResult
    public func syncItems(for subscription: RssSubscription) async throws -> Int {
        guard !Task.isCancelled else { throw CancellationError() }
        let feedId = subscription.feedId
        let (flight, ticket) = Flight.join(feedFlights[feedId]) { [self] id in
            let result: Result<Int, Error>
            do {
                result = .success(try await syncFeedPass(subscription))
            } catch {
                result = .failure(error)
            }
            await endFeedFlight(feedId, id)
            return result
        }
        feedFlights[feedId] = flight
        guard let result = await flight.run.value(for: ticket) else { throw CancellationError() }
        return try result.get()
    }

    private func endFeedFlight(_ feedId: String, _ id: UUID) {
        if feedFlights[feedId]?.id == id { feedFlights[feedId] = nil }
    }

    /// Syncs the feeds a scope covers, `concurrency` at a time, then drains
    /// the queue: the item list's refresh. Every feed is tried whatever
    /// another one does, and a feed `syncAll` is already syncing is joined.
    /// Nil when the caller is cancelled before the pass ends.
    public func syncItems(in scope: RssItemScope) async -> RssSyncReport? {
        guard !Task.isCancelled else { return nil }
        var report = RssSyncReport()
        do {
            let feedIds = Set(try await store.feedIds(in: scope))
            let subscriptions = try await store.subscriptions().filter { feedIds.contains($0.feedId) }
            report.subscriptionIds = subscriptions.map(\.subscriptionId)
            report.feedErrors = await syncFeeds(subscriptions)
        } catch {
            report.catalogError = error
        }
        guard !Task.isCancelled else { return nil }
        do {
            try await drainPending()
        } catch {
            report.pendingError = error
        }
        return Task.isCancelled ? nil : report
    }

    private func syncFeedPass(_ subscription: RssSubscription) async throws -> Int {
        var state = try await store.syncState(feedId: subscription.feedId)
        var received = 0
        if state.sinceCursor.isEmpty {
            let page = try await client.listItems(
                scope: .subscription(subscription.subscriptionId), filter: .all, order: .newest,
                limit: initialPageSize, cursor: nil)
            try await store.upsertItems(page.items)
            received += page.items.count
            state.sinceCursor = page.items.map(\.fetchedKey).max() ?? Self.sentinelCursor
            state.olderCursor = page.nextCursor ?? ""
            state.olderExhausted = page.nextCursor == nil
        }
        var pages = 0
        var since = state.sinceCursor == Self.sentinelCursor ? "" : state.sinceCursor
        while pages < maxPagesPerRun {
            let page = try await client.syncItems(
                subscriptionId: subscription.subscriptionId, since: since, limit: pageSize)
            try await store.upsertItems(page.items)
            received += page.items.count
            pages += 1
            if !page.nextSince.isEmpty { since = page.nextSince }
            if !page.hasMore { break }
        }
        state.sinceCursor = since.isEmpty ? Self.sentinelCursor : since
        pages = 0
        while pages < maxPagesPerRun {
            let page = try await client.syncItemStates(
                subscriptionId: subscription.subscriptionId, since: state.stateCursor, limit: pageSize)
            try await store.applyServerStates(page.states)
            pages += 1
            if !page.nextSince.isEmpty { state.stateCursor = page.nextSince }
            if !page.hasMore { break }
        }
        state.lastSyncedAt = RssStore.isoNow()
        try await store.setSyncState(feedId: subscription.feedId, state)
        return received
    }

    /// Pulls the next page of older items for "Load older" / "Search older";
    /// returns how many arrived (0 when the server has no more).
    @discardableResult
    public func loadOlder(for subscription: RssSubscription) async throws -> Int {
        var state = try await store.syncState(feedId: subscription.feedId)
        guard !state.olderExhausted else { return 0 }
        let page = try await client.listItems(
            scope: .subscription(subscription.subscriptionId), filter: .all, order: .newest,
            limit: pageSize, cursor: state.olderCursor.isEmpty ? nil : state.olderCursor)
        try await store.upsertItems(page.items)
        state.olderCursor = page.nextCursor ?? ""
        state.olderExhausted = page.nextCursor == nil
        try await store.setSyncState(feedId: subscription.feedId, state)
        return page.items.count
    }

    /// Catalog, then every subscription, `concurrency` at a time; then the
    /// pending queue. A pass already in flight is joined. Per-feed failures
    /// are collected, not fatal, and reported apart from the catalog's and
    /// the queue's (#1904). Nil when the caller is cancelled before the pass
    /// ends.
    @discardableResult
    public func syncAll() async -> RssSyncReport? {
        guard !Task.isCancelled else { return nil }
        let (flight, ticket) = Flight.join(allFlight) { [self] id in
            let report = await syncAllPass()
            await endAllFlight(id)
            return report
        }
        allFlight = flight
        return await flight.run.value(for: ticket)
    }

    private func endAllFlight(_ id: UUID) {
        if allFlight?.id == id { allFlight = nil }
    }

    private func syncAllPass() async -> RssSyncReport {
        var report = RssSyncReport()
        do {
            try await refreshCatalog()
        } catch {
            report.catalogError = error
            return report
        }
        let subscriptions = (try? await store.subscriptions()) ?? []
        report.subscriptionIds = subscriptions.map(\.subscriptionId)
        report.feedErrors = await syncFeeds(subscriptions)
        guard !Task.isCancelled else { return report }
        do {
            try await drainPending()
        } catch {
            report.pendingError = error
        }
        return report
    }

    /// Syncs `subscriptions` through their feed runs, `concurrency` at a
    /// time; the failures by subscription id.
    private func syncFeeds(_ subscriptions: [RssSubscription]) async -> [String: Error] {
        var failures: [String: Error] = [:]
        await withTaskGroup(of: (String, Error?).self) { group in
            var iterator = subscriptions.makeIterator()
            func launch(_ sub: RssSubscription) {
                group.addTask { [self] in
                    do {
                        try await self.syncItems(for: sub)
                        return (sub.subscriptionId, nil)
                    } catch {
                        return (sub.subscriptionId, error)
                    }
                }
            }
            var running = 0
            while running < concurrency, let sub = iterator.next() {
                launch(sub)
                running += 1
            }
            while let (id, error) = await group.next() {
                if let error { failures[id] = error }
                if let sub = iterator.next() { launch(sub) }
            }
        }
        return failures
    }

    // MARK: - Pending mutations

    /// Pushes queued state changes (`RssPendingDrain`). Returns how many queue
    /// rows were cleared. Joins a drain that has not yet read the queue; asked
    /// for while one is pushing, it waits for one more pass behind it, so a
    /// change made after the queue was read still goes. Throws
    /// `CancellationError` when the caller is cancelled first.
    @discardableResult
    public func drainPending() async throws -> Int {
        try await pending.drain()
    }

    // MARK: - Local mutations (store first, then a best-effort push)

    public func setRead(_ item: RssItem, _ isRead: Bool) async throws {
        try await store.setRead(feedId: item.feedId, sortKey: item.sortKey, isRead)
        await pushSoon()
    }

    public func setFavorite(_ item: RssItem, _ isFavorite: Bool) async throws {
        try await store.setFavorite(feedId: item.feedId, sortKey: item.sortKey, isFavorite)
        await pushSoon()
    }

    public func markAllRead(subscriptionId: String) async throws {
        try await store.markAllRead(subscriptionId: subscriptionId)
        await pushSoon()
    }

    /// Changes a subscription's per-feed settings. The store takes the
    /// change first, so the next item opened in the feed honours it even
    /// while the round trip is in flight or offline; the server's copy
    /// replaces it on success. A failure leaves the optimistic row for the
    /// session — the next catalog refresh reconciles it — and rethrows so a
    /// caller that cares can say so.
    @discardableResult
    public func updateSubscription(_ subscription: RssSubscription, _ update: RssSubscriptionUpdate) async throws
        -> RssSubscription {
        guard !update.isEmpty else { return subscription }
        try await store.upsertSubscription(subscription.applying(update))
        let updated = try await client.updateSubscription(subscription.subscriptionId, update)
        try await store.upsertSubscription(updated)
        return updated
    }

    /// Changes a folder's settings (today only its sticky filter pill), with
    /// the same optimistic store-first shape as `updateSubscription`.
    @discardableResult
    public func updateFolder(_ folder: RssFolder, _ update: RssFolderUpdate) async throws -> RssFolder {
        guard !update.isEmpty else { return folder }
        try await store.upsertFolder(folder.applying(update))
        let updated = try await client.updateFolder(folder.folderId, update)
        try await store.upsertFolder(updated)
        return updated
    }

    /// One drain attempt; a failure (offline, say) is expected and leaves
    /// the queue for the next trigger.
    private func pushSoon() async {
        _ = try? await drainPending()
    }

    /// Stored in place of an empty since-cursor once a feed has been
    /// populated, so "never synced" and "synced, nothing ingested yet" stay
    /// distinguishable in `feed_sync`. Real cursors are ISO timestamps, so a
    /// string that cannot be one is safe (and unlike a NUL byte, survives
    /// SQLite's C-string binding).
    static let sentinelCursor = "~none"
}
