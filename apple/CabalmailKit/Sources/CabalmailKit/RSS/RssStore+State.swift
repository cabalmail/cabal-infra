import Foundation

// MARK: - Local state changes, the pending queue, and sync cursors

extension RssStore {
    /// One queued mutation awaiting a push to the server.
    /// What a queued mutation does.
    public enum PendingKind: String, Sendable { case read, favorite, markAllRead = "mark_all_read" }

    public struct PendingMutation: Sendable, Hashable, Identifiable {
        public var id: Int
        public var kind: PendingKind
        public var feedId: String
        public var sortKey: String
        public var subscriptionId: String
        public var value: Bool
    }

    /// Sync bookkeeping for one feed.
    public struct FeedSyncState: Sendable, Hashable {
        /// The `fetched_key` to continue since-sync from; "" before the first sync.
        public var sinceCursor: String
        /// The merged-listing cursor for "load older"; "" before the first page.
        public var olderCursor: String
        public var olderExhausted: Bool
        public var lastSyncedAt: String
        /// The state-sync cursor (opaque); "" before the first pull.
        public var stateCursor: String

        public init(sinceCursor: String = "", olderCursor: String = "", olderExhausted: Bool = false,
                    lastSyncedAt: String = "", stateCursor: String = "") {
            self.sinceCursor = sinceCursor
            self.olderCursor = olderCursor
            self.olderExhausted = olderExhausted
            self.lastSyncedAt = lastSyncedAt
            self.stateCursor = stateCursor
        }
    }

    /// Marks an item read or unread locally and queues the change.
    public func setRead(feedId: String, sortKey: String, _ isRead: Bool) throws {
        try database.run("UPDATE items SET is_read = ?, state_is_explicit = 1 WHERE feed_id = ? AND sort_key = ?",
                   [.init(isRead), .init(feedId), .init(sortKey)])
        try enqueue(kind: .read, feedId: feedId, sortKey: sortKey, value: isRead)
    }

    /// Favorites or unfavorites an item locally and queues the change.
    public func setFavorite(feedId: String, sortKey: String, _ isFavorite: Bool) throws {
        try database.run("UPDATE items SET is_favorite = ? WHERE feed_id = ? AND sort_key = ?",
                   [.init(isFavorite), .init(feedId), .init(sortKey)])
        try enqueue(kind: .favorite, feedId: feedId, sortKey: sortKey, value: isFavorite)
    }

    /// Mark-all-read for one subscription, the way the server does it:
    /// advance the watermark and flip items explicitly marked unread.
    public func markAllRead(subscriptionId: String, watermark: String? = nil) throws {
        let watermark = watermark ?? Self.isoNow()
        guard let sub = try subscription(id: subscriptionId) else { return }
        try database.run(
            "UPDATE subscriptions SET read_watermark = MAX(read_watermark, ?) WHERE subscription_id = ?",
            [.init(watermark), .init(subscriptionId)])
        try database.run("""
            UPDATE items SET is_read = 1 WHERE feed_id = ? AND state_is_explicit = 1 AND is_read = 0
              AND published_at <= ?
            """, [.init(sub.feedId), .init(watermark)])
        try database.run(
            "INSERT INTO pending (kind, subscription_id, feed_id, created_at) VALUES ('mark_all_read', ?, ?, ?)",
            [.init(subscriptionId), .init(sub.feedId), .init(Self.isoNow())])
    }

    /// Applies state rows the server reported (the state sync) to the
    /// items this device has, without queueing anything. A flag with a
    /// queued local change is left alone - the local intent is newer than
    /// whatever the server had when it answered - and an item not cached
    /// here is skipped; it arrives with its state when it is listed.
    public func applyServerStates(_ states: [RssItemState]) throws {
        guard !states.isEmpty else { return }
        try database.exec("BEGIN")
        do {
            for state in states {
                try database.run("""
                    UPDATE items SET is_read = ?, state_is_explicit = ?
                    WHERE feed_id = ? AND sort_key = ? AND NOT EXISTS (
                      SELECT 1 FROM pending WHERE kind = 'read' AND feed_id = items.feed_id
                        AND sort_key = items.sort_key)
                    """, [.init(state.isRead), .init(state.isReadExplicit), .init(state.feedId), .init(state.sortKey)])
                try database.run("""
                    UPDATE items SET is_favorite = ?
                    WHERE feed_id = ? AND sort_key = ? AND NOT EXISTS (
                      SELECT 1 FROM pending WHERE kind = 'favorite' AND feed_id = items.feed_id
                        AND sort_key = items.sort_key)
                    """, [.init(state.isFavorite), .init(state.feedId), .init(state.sortKey)])
            }
            try database.exec("COMMIT")
        } catch {
            try? database.exec("ROLLBACK")
            throw error
        }
    }

    /// Applies a watermark the SERVER reported (after a push or a catalog
    /// refresh) without queueing anything.
    public func applyServerWatermark(subscriptionId: String, watermark: String) throws {
        try database.run(
            "UPDATE subscriptions SET read_watermark = MAX(read_watermark, ?) WHERE subscription_id = ?",
            [.init(watermark), .init(subscriptionId)])
    }

    public func pendingMutations() throws -> [PendingMutation] {
        try database.rows("SELECT id, kind, feed_id, sort_key, subscription_id, value FROM pending ORDER BY id")
            .compactMap {
            guard let kind = PendingKind(rawValue: $0.string(1)) else { return nil }
            return PendingMutation(id: $0.int(0), kind: kind, feedId: $0.string(2), sortKey: $0.string(3),
                                   subscriptionId: $0.string(4), value: $0.bool(5))
        }
    }

    public func pendingCount() throws -> Int {
        try database.rows("SELECT COUNT(*) FROM pending").first?.int(0) ?? 0
    }

    /// Whether an item has a queued change (the UI's "queued" mark).
    public func hasPending(feedId: String, sortKey: String) throws -> Bool {
        (try database.rows("SELECT 1 FROM pending WHERE feed_id = ? AND sort_key = ? LIMIT 1",
                     [.init(feedId), .init(sortKey)]).first) != nil
    }

    public func deletePending(ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        try database.run("DELETE FROM pending WHERE id IN (\(Self.placeholders(ids.count)))",
                         ids.map(SQLiteDatabase.Value.init(_:)))
    }

    private func enqueue(kind: PendingKind, feedId: String, sortKey: String, value: Bool) throws {
        // The latest intent for an item wins; drop earlier queued flips of
        // the same kind so a drain never replays a superseded state.
        try database.run("DELETE FROM pending WHERE kind = ? AND feed_id = ? AND sort_key = ?",
                   [.init(kind.rawValue), .init(feedId), .init(sortKey)])
        try database.run("INSERT INTO pending (kind, feed_id, sort_key, value, created_at) VALUES (?, ?, ?, ?, ?)",
                   [.init(kind.rawValue), .init(feedId), .init(sortKey), .init(value), .init(Self.isoNow())])
    }

    // MARK: Sync cursors

    public func syncState(feedId: String) throws -> FeedSyncState {
        guard let row = try database.rows("""
            SELECT since_cursor, older_cursor, older_exhausted, last_synced_at, state_cursor
            FROM feed_sync WHERE feed_id = ?
            """, [.init(feedId)]).first else { return FeedSyncState() }
        return FeedSyncState(sinceCursor: row.string(0), olderCursor: row.string(1),
                             olderExhausted: row.bool(2), lastSyncedAt: row.string(3), stateCursor: row.string(4))
    }

    public func setSyncState(feedId: String, _ state: FeedSyncState) throws {
        try database.run("""
            INSERT INTO feed_sync (feed_id, since_cursor, older_cursor, older_exhausted, last_synced_at, state_cursor)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(feed_id) DO UPDATE SET since_cursor = excluded.since_cursor,
              older_cursor = excluded.older_cursor, older_exhausted = excluded.older_exhausted,
              last_synced_at = excluded.last_synced_at, state_cursor = excluded.state_cursor
            """, [.init(feedId), .init(state.sinceCursor), .init(state.olderCursor),
                  .init(state.olderExhausted), .init(state.lastSyncedAt), .init(state.stateCursor)])
    }

    public func itemCount(feedId: String) throws -> Int {
        try database.rows("SELECT COUNT(*) FROM items WHERE feed_id = ?", [.init(feedId)]).first?.int(0) ?? 0
    }
}
