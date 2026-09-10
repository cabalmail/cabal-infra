import Foundation

/// Keeps `RssStore` current with the server and pushes the user's local
/// state changes back (docs/1.x/rss-implementation-plan.md, phase 5).
///
/// Three jobs, all idempotent and safe to overlap:
///   * `refreshCatalog()` - folders and subscriptions from the server; the
///     store deletes what departed and reports it so the app can drop the
///     matching web-view storage.
///   * `syncItems(for:)` - a feed's items. A feed with no cursor yet is
///     populated newest-first (`initialPageSize` items) and its cursor set
///     to the largest `fetchedKey` seen; after that it follows the server's
///     since-sync (ingest-time cursor) in pages until `hasMore` is false,
///     bounded per run so one huge feed cannot monopolise a refresh.
///   * `drainPending()` - the offline mutation queue, coalesced into
///     `/rss_set_item_state` batches and `/rss_mark_all_read` calls. A
///     failure leaves the queue intact for the next attempt.
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
    /// Feeds synced at once by `syncAll`.
    public var concurrency = 4

    public init(client: RssClient, store: RssStore) {
        self.client = client
        self.store = store
    }

    // MARK: - Catalog

    @discardableResult
    public func refreshCatalog() async throws -> RssStore.CatalogDiff {
        let catalog = try await client.listSubscriptions()
        return try await store.replaceCatalog(catalog)
    }

    // MARK: - Items

    /// Syncs one subscription's items; returns how many the store received.
    @discardableResult
    public func syncItems(for subscription: RssSubscription) async throws -> Int {
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
    /// pending queue. Per-feed failures are collected, not fatal.
    @discardableResult
    public func syncAll() async -> [String: Error] {
        var failures: [String: Error] = [:]
        do {
            try await refreshCatalog()
        } catch {
            failures["catalog"] = error
            return failures
        }
        let subs = (try? await store.subscriptions()) ?? []
        await withTaskGroup(of: (String, Error?).self) { group in
            var iterator = subs.makeIterator()
            var running = 0
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
            while running < concurrency, let sub = iterator.next() {
                launch(sub)
                running += 1
            }
            while let (id, error) = await group.next() {
                if let error { failures[id] = error }
                if let sub = iterator.next() { launch(sub) }
            }
        }
        do {
            try await drainPending()
        } catch {
            failures["pending"] = error
        }
        return failures
    }

    // MARK: - Pending mutations

    /// Pushes queued state changes. Returns how many queue rows were cleared.
    @discardableResult
    public func drainPending() async throws -> Int {
        let pending = try await store.pendingMutations()
        guard !pending.isEmpty else { return 0 }
        var cleared = 0
        // Item state: the queue already holds one row per (item, kind), so
        // merge read + favorite for the same item into one change.
        var changes: [String: RssItemStateChange] = [:]
        var changeIds: [String: [Int]] = [:]
        for mutation in pending where mutation.kind != .markAllRead {
            let key = "\(mutation.feedId)#\(mutation.sortKey)"
            var change = changes[key] ?? RssItemStateChange(feedId: mutation.feedId, sortKey: mutation.sortKey)
            if mutation.kind == .read { change.isRead = mutation.value } else { change.isFavorite = mutation.value }
            changes[key] = change
            changeIds[key, default: []].append(mutation.id)
        }
        let keys = changes.keys.sorted()
        for start in stride(from: 0, to: keys.count, by: 100) {
            let batch = Array(keys[start..<min(start + 100, keys.count)])
            _ = try await client.setItemState(batch.map { changes[$0]! })
            let ids = batch.flatMap { changeIds[$0] ?? [] }
            try await store.deletePending(ids: ids)
            cleared += ids.count
        }
        for mutation in pending where mutation.kind == .markAllRead {
            let result = try await client.markAllRead(scope: .subscription(mutation.subscriptionId))
            try await store.applyServerWatermark(subscriptionId: mutation.subscriptionId,
                                                 watermark: result.readWatermark)
            try await store.deletePending(ids: [mutation.id])
            cleared += 1
        }
        return cleared
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
