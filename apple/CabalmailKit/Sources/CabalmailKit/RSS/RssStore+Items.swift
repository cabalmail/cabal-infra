import Foundation

// MARK: - Items: upsert, list, search

extension RssStore {
    /// How a listing is ordered and filtered; `after` pages through it.
    public struct ItemQuery: Sendable, Hashable {
        public var scope: RssItemScope
        public var filter: RssItemFilter
        public var ordering: RssOrderingMode
        public var limit: Int
        /// The last row of the previous page; nil for the first page.
        public var after: ItemCursor?

        public init(
            scope: RssItemScope, filter: RssItemFilter = .all, ordering: RssOrderingMode = .newestFirst,
            limit: Int = 50, after: ItemCursor? = nil
        ) {
            self.scope = scope
            self.filter = filter
            self.ordering = ordering
            self.limit = limit
            self.after = after
        }
    }

    /// A keyset page boundary: where a row sits in every ordering. Paging
    /// by position instead (OFFSET) skips rows when the filter set shrinks
    /// under the list - an item read in the Unread pill leaves it while
    /// staying on screen - and repeats rows when newer items are inserted
    /// above the page. A key does neither: the next page is whatever sorts
    /// after the last row shown, whatever changed in between.
    public struct ItemCursor: Sendable, Hashable {
        public var feedId: String
        public var sortKey: String
        public var publishedAt: String

        public init(after item: RssItem) {
            feedId = item.feedId
            sortKey = item.sortKey
            publishedAt = item.publishedAt
        }
    }

    /// Writes items from the server. An item with a pending local mutation
    /// keeps its local state (the server copy predates what the user did);
    /// every other item takes the server's `is_read` / `is_favorite`, and
    /// whether that read state is an explicit mark - without which an
    /// explicit unread on an item older than the watermark would read as
    /// read here.
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
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(feed_id, sort_key) DO UPDATE SET item_id = excluded.item_id,
                      guid = excluded.guid, title = excluded.title, author = excluded.author,
                      url = excluded.url, published_at = excluded.published_at,
                      updated_at = excluded.updated_at, fetched_at = excluded.fetched_at,
                      fetched_key = excluded.fetched_key, summary_html = excluded.summary_html,
                      content_html = excluded.content_html, body_text = excluded.body_text,
                      is_read = CASE WHEN ? THEN items.is_read ELSE excluded.is_read END,
                      is_favorite = CASE WHEN ? THEN items.is_favorite ELSE excluded.is_favorite END,
                      state_is_explicit = CASE WHEN ? THEN items.state_is_explicit
                                               ELSE excluded.state_is_explicit END,
                      cached_at = excluded.cached_at
                    """, [
                        .init(item.feedId), .init(item.sortKey), .init(item.itemId), .init(item.guid),
                        .init(item.title), .init(item.author), .init(item.url), .init(item.publishedAt),
                        .init(item.updatedAt), .init(item.fetchedAt), .init(item.fetchedKey),
                        .init(item.summaryHtml), .init(item.contentHtml),
                        .init(HTMLText.plainText(from: item.bodyHtml)),
                        .init(item.isRead), .init(item.isFavorite), .init(item.isReadExplicit), .init(now),
                        .init(keepLocalState), .init(keepLocalState), .init(keepLocalState),
                    ])
            }
            try database.exec("COMMIT")
        } catch {
            try? database.exec("ROLLBACK")
            throw error
        }
        emit(.feeds(Set(items.map(\.feedId))))
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
        if let after = query.after {
            let (clause, keyBinds) = Self.afterClause(query.ordering, after)
            clauses.append(clause)
            binds += keyBinds
        }
        let sql = """
            SELECT \(Schema.itemColumns) FROM items i
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(Self.orderClause(query.ordering)) LIMIT ?
            """
        binds.append(.init(query.limit))
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

    /// Cached item counts keyed by subscription id (absent = zero): the
    /// "total" a feed badge shows under the `total` / `both` folder-count
    /// modes. The cache window is what the client holds, not the feed's
    /// whole history, which is the same thing the item list can scroll.
    public func totalCounts() throws -> [String: Int] {
        let rows = try database.rows("""
            SELECT s.subscription_id, COUNT(*) FROM items i
            JOIN subscriptions s ON s.feed_id = i.feed_id
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
        orderKeys(ordering).map { "\($0.expression) \($0.ascending ? "ASC" : "DESC")" }
            .joined(separator: ", ")
    }

    private static let dayExpression = "substr(i.published_at, 1, 10)"

    /// The ordering as a total order: `feed_id` breaks a `sort_key` tie
    /// between feeds, so a keyset cursor never skips or repeats a row.
    private static func orderKeys(_ ordering: RssOrderingMode) -> [(expression: String, ascending: Bool)] {
        switch ordering {
        case .newestFirst: return [("i.sort_key", false), ("i.feed_id", false)]
        case .oldestFirst: return [("i.sort_key", true), ("i.feed_id", true)]
        case .newestDayOldestWithin: return [(dayExpression, false), ("i.sort_key", true), ("i.feed_id", true)]
        case .oldestDayNewestWithin: return [(dayExpression, true), ("i.sort_key", false), ("i.feed_id", false)]
        }
    }

    /// "Sorts after `cursor`" for the ordering, as a WHERE clause: the
    /// lexicographic comparison over `orderKeys`, expanded because the
    /// keys mix directions (a row-value comparison cannot).
    static func afterClause(_ ordering: RssOrderingMode, _ cursor: ItemCursor)
        -> (String, [SQLiteDatabase.Value]) {
        let keys = orderKeys(ordering)
        func value(of expression: String) -> SQLiteDatabase.Value {
            switch expression {
            case dayExpression: return .init(String(cursor.publishedAt.prefix(10)))
            case "i.sort_key": return .init(cursor.sortKey)
            default: return .init(cursor.feedId)
            }
        }
        var alternatives: [String] = []
        var binds: [SQLiteDatabase.Value] = []
        for index in keys.indices {
            var terms: [String] = []
            for equal in keys[..<index] {
                terms.append("\(equal.expression) = ?")
                binds.append(value(of: equal.expression))
            }
            terms.append("\(keys[index].expression) \(keys[index].ascending ? ">" : "<") ?")
            binds.append(value(of: keys[index].expression))
            alternatives.append("(" + terms.joined(separator: " AND ") + ")")
        }
        return ("(" + alternatives.joined(separator: " OR ") + ")", binds)
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
            isRead: row.bool(13), isReadExplicit: row.bool(16), isFavorite: row.bool(14)
        )
    }

    static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
