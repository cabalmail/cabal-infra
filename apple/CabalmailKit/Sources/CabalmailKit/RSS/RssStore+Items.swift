import Foundation

// MARK: - Items: upsert, list, search

extension RssStore {
    /// How a listing is ordered and filtered; `offset` pages through it.
    public struct ItemQuery: Sendable, Hashable {
        public var scope: RssItemScope
        public var filter: RssItemFilter
        public var ordering: RssOrderingMode
        public var limit: Int
        public var offset: Int

        public init(
            scope: RssItemScope, filter: RssItemFilter = .all, ordering: RssOrderingMode = .newestFirst,
            limit: Int = 50, offset: Int = 0
        ) {
            self.scope = scope
            self.filter = filter
            self.ordering = ordering
            self.limit = limit
            self.offset = offset
        }
    }

    /// Writes items from the server. An item with a pending local mutation
    /// keeps its local state (the server copy predates what the user did);
    /// every other item takes the server's `is_read` / `is_favorite`.
    public func upsertItems(_ items: [RssItem]) throws {
        guard !items.isEmpty else { return }
        let now = Self.isoNow()
        let pendingKeys = Set(
            try database.rows("SELECT feed_id, sort_key FROM pending WHERE kind IN ('read', 'favorite')")
                .map { "\($0.string(0))#\($0.string(1))" }
        )
        try database.exec("BEGIN")
        do {
            for item in items {
                let keepLocalState = pendingKeys.contains(item.id)
                try database.run("""
                    INSERT INTO items (feed_id, sort_key, item_id, guid, title, author, url, published_at,
                      updated_at, fetched_at, fetched_key, summary_html, content_html, body_text,
                      is_read, is_favorite, state_is_explicit, cached_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                    ON CONFLICT(feed_id, sort_key) DO UPDATE SET item_id = excluded.item_id,
                      guid = excluded.guid, title = excluded.title, author = excluded.author,
                      url = excluded.url, published_at = excluded.published_at,
                      updated_at = excluded.updated_at, fetched_at = excluded.fetched_at,
                      fetched_key = excluded.fetched_key, summary_html = excluded.summary_html,
                      content_html = excluded.content_html, body_text = excluded.body_text,
                      is_read = CASE WHEN ? THEN items.is_read ELSE excluded.is_read END,
                      is_favorite = CASE WHEN ? THEN items.is_favorite ELSE excluded.is_favorite END,
                      state_is_explicit = CASE WHEN ? THEN items.state_is_explicit ELSE 0 END,
                      cached_at = excluded.cached_at
                    """, [
                        .init(item.feedId), .init(item.sortKey), .init(item.itemId), .init(item.guid),
                        .init(item.title), .init(item.author), .init(item.url), .init(item.publishedAt),
                        .init(item.updatedAt), .init(item.fetchedAt), .init(item.fetchedKey),
                        .init(item.summaryHtml), .init(item.contentHtml),
                        .init(HTMLText.plainText(from: item.bodyHtml)),
                        .init(item.isRead), .init(item.isFavorite), .init(now),
                        .init(keepLocalState), .init(keepLocalState), .init(keepLocalState),
                    ])
            }
            try database.exec("COMMIT")
        } catch {
            try? database.exec("ROLLBACK")
            throw error
        }
    }

    /// One page of items for the query, read state computed.
    public func items(_ query: ItemQuery) throws -> [RssItem] {
        let feedIds = try feedIds(in: query.scope)
        guard !feedIds.isEmpty else { return [] }
        var clauses = ["i.feed_id IN (\(Self.placeholders(feedIds.count)))"]
        var binds = feedIds.map(SQLiteDatabase.Value.init(_:))
        switch query.filter {
        case .all: break
        case .unread: clauses.append("NOT (\(Schema.readExpression))")
        case .favorite: clauses.append("i.is_favorite = 1")
        }
        let sql = """
            SELECT \(Schema.itemColumns) FROM items i
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(Self.orderClause(query.ordering)) LIMIT ? OFFSET ?
            """
        binds += [.init(query.limit), .init(query.offset)]
        return try database.rows(sql, binds).map(Self.item(from:))
    }

    public func item(feedId: String, sortKey: String) throws -> RssItem? {
        try database.rows("SELECT \(Schema.itemColumns) FROM items i WHERE i.feed_id = ? AND i.sort_key = ?",
                    [.init(feedId), .init(sortKey)]).first.map(Self.item(from:))
    }

    /// Unread counts keyed by subscription id (absent = zero).
    public func unreadCounts() throws -> [String: Int] {
        let rows = try database.rows("""
            SELECT s.subscription_id, COUNT(*) FROM items i
            JOIN subscriptions s ON s.feed_id = i.feed_id
            WHERE NOT (\(Schema.readExpression))
            GROUP BY s.subscription_id
            """)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.string(0), $0.int(1)) })
    }

    /// Per-feed full-text search over cached items, best match first.
    public func search(feedId: String, query: String, limit: Int = 100) throws -> [RssItem] {
        guard let match = Self.ftsQuery(query) else { return [] }
        return try database.rows("""
            SELECT \(Schema.itemColumns) FROM items i
            JOIN items_fts f ON f.rowid = i.id
            WHERE items_fts MATCH ? AND i.feed_id = ?
            ORDER BY f.rank LIMIT ?
            """, [.init(match), .init(feedId), .init(limit)]).map(Self.item(from:))
    }

    /// Turns free text into an FTS5 query: each token a quoted prefix
    /// (implicit AND), so operator characters in the user's text never reach
    /// the FTS parser. Nil when there is nothing searchable. The index uses
    /// the plain unicode61 tokenizer, not porter: stemming rewrites stored
    /// tokens ("isolation" -> "isol") in ways a typed prefix ("isolat")
    /// no longer matches, and prefix search is what a search-as-you-type
    /// field needs.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    static func orderClause(_ ordering: RssOrderingMode) -> String {
        switch ordering {
        case .newestFirst: return "i.sort_key DESC"
        case .oldestFirst: return "i.sort_key ASC"
        case .newestDayOldestWithin: return "substr(i.published_at, 1, 10) DESC, i.sort_key ASC"
        case .oldestDayNewestWithin: return "substr(i.published_at, 1, 10) ASC, i.sort_key DESC"
        }
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    static func item(from row: SQLiteDatabase.Row) -> RssItem {
        RssItem(
            feedId: row.string(0), subscriptionId: row.string(15), itemId: row.string(2), sortKey: row.string(1),
            guid: row.string(3), title: row.string(4), author: row.string(5), url: row.string(6),
            publishedAt: row.string(7), updatedAt: row.string(8), fetchedAt: row.string(9),
            fetchedKey: row.string(10), summaryHtml: row.string(11), contentHtml: row.string(12),
            isRead: row.bool(13), isFavorite: row.bool(14)
        )
    }

    static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
