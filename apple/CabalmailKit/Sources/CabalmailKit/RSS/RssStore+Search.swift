import Foundation

// The search of every feed at once: what the app's search lists beside its
// mail results (`docs/1.x/cross-media-ux-plan.md`, Phase 5). It reads the
// index `search(feedId:query:)` reads, over every subscribed feed, so it
// covers the items this device has downloaded and nothing older.
extension RssStore {
    /// What a search of every feed asks of the cached items.
    ///
    /// The text is matched as `search(feedId:query:)` matches it: every word
    /// a prefix, all of them required, in the title or the body. The rest
    /// narrows as the mail search's filters of the same names do: unread by
    /// the store's read rule, a flag by the criterion a list's pill uses,
    /// and the two dates by the day (UTC) an item was published, `since`
    /// included and `before` not.
    public struct ItemSearch: Sendable, Hashable {
        public var text: String
        public var unread: Bool
        public var flag: FlagCriterion?
        public var since: Date?
        public var before: Date?

        public init(
            text: String = "", unread: Bool = false, flag: FlagCriterion? = nil,
            since: Date? = nil, before: Date? = nil
        ) {
            self.text = text
            self.unread = unread
            self.flag = flag
            self.since = since
            self.before = before
        }

        /// Whether there is anything to match on. A search with nothing
        /// finds nothing: every cached item is a feed list's to show, not a
        /// search's.
        public var hasPredicate: Bool {
            RssStore.ftsQuery(text) != nil || unread || flag != nil || since != nil || before != nil
        }
    }

    /// One page of a search's matches, newest first across feeds, read
    /// state computed. `after` is the last row of the page before, a keyset
    /// boundary as `ItemQuery.after` is, so a mark made between two pages
    /// neither skips a row nor repeats one.
    public func search(_ search: ItemSearch, limit: Int = 50, after: ItemCursor? = nil) throws -> [RssItem] {
        guard var statement = try searchStatement(search) else { return [] }
        if let after {
            let (clause, binds) = Self.afterClause(.newestFirst, after)
            statement.clauses.append(clause)
            statement.binds += binds
        }
        statement.binds.append(.init(limit))
        return try database.rows("""
            SELECT \(Schema.itemColumns) FROM \(statement.source)
            WHERE \(statement.clauses.joined(separator: " AND "))
            ORDER BY \(Self.orderClause(.newestFirst)) LIMIT ?
            """, statement.binds).map(Self.item(from:))
    }

    /// How many cached items a search matches in all: the number beside the
    /// rows `search(_:limit:after:)` pages through.
    public func searchCount(_ search: ItemSearch) throws -> Int {
        guard let statement = try searchStatement(search) else { return 0 }
        let row = try database.rows("""
            SELECT COUNT(*) FROM \(statement.source)
            WHERE \(statement.clauses.joined(separator: " AND "))
            """, statement.binds).first
        return row?.int(0) ?? 0
    }

    /// The tables, conditions and binds a search reads with; nil when it
    /// would match nothing whatever the store holds (nothing to match on,
    /// or no subscribed feed).
    ///
    /// The index is joined only when there are words to look for, so a
    /// search by filters alone is a plain read of the items. Only subscribed
    /// feeds are read, as every list reads them, so the search can find
    /// nothing that All Feeds does not list.
    private func searchStatement(
        _ search: ItemSearch
    ) throws -> (source: String, clauses: [String], binds: [SQLiteDatabase.Value])? {
        guard search.hasPredicate else { return nil }
        let feedIds = try feedIds(in: .all)
        guard !feedIds.isEmpty else { return nil }
        var source = "items i"
        var clauses: [String] = []
        var binds: [SQLiteDatabase.Value] = []
        if let match = Self.ftsQuery(search.text) {
            source = "items i JOIN items_fts f ON f.rowid = i.id"
            clauses.append("items_fts MATCH ?")
            binds.append(.init(match))
        }
        clauses.append("i.feed_id IN (\(Self.placeholders(feedIds.count)))")
        binds += feedIds.map(SQLiteDatabase.Value.init(_:))
        if search.unread { clauses.append("NOT (\(Schema.readExpression))") }
        if let criterion = search.flag {
            let flag = Self.flagClause(criterion)
            clauses.append(flag.sql)
            binds += flag.binds
        }
        // An item with no date is on no day, so a search narrowed by a day
        // leaves it out, as it would a message.
        if search.since != nil || search.before != nil { clauses.append("i.published_at != ''") }
        if let since = search.since {
            clauses.append("\(Self.publishedDay) >= ?")
            binds.append(.init(Self.utcDay(since)))
        }
        if let before = search.before {
            clauses.append("\(Self.publishedDay) < ?")
            binds.append(.init(Self.utcDay(before)))
        }
        return (source, clauses, binds)
    }

    private static let publishedDay = "substr(i.published_at, 1, 10)"

    /// A date as the day it falls on in UTC, `yyyy-MM-dd`: the form an
    /// item's `published_at` leads with, and the day the mail search sends
    /// the server for the same filter.
    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
