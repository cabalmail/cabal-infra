import Foundation

/// The RSS reader's on-device store: the whole catalog (folders,
/// subscriptions), the items the device has synced, the caller's read and
/// favorite state, per-feed sync cursors, and the queue of mutations made
/// while offline. One SQLite file per account, WAL mode, FTS5 over item
/// text for per-feed search. `RssSyncEngine` is the writer for everything
/// that comes from the server; the UI writes only optimistic state changes
/// (which also enqueue the mutation for the engine to push).
///
/// Read state follows the server's rule so the two never disagree: an item
/// the user explicitly marked (locally or server-side) keeps that mark;
/// otherwise it is read once the subscription's read watermark passes its
/// publication time. The server already folds ITS watermark into the
/// `is_read` it sends, and the local watermark only ever advances, so
/// `is_read OR published_at <= watermark` is exact.
public actor RssStore {
    let database: SQLiteDatabase
    /// Directory the database lives in (the caller may put other per-account
    /// RSS state beside it).
    public nonisolated let directory: URL

    static let schemaVersion = 1

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        database = try SQLiteDatabase(path: directory.appendingPathComponent("rss.sqlite").path)
        try database.exec("PRAGMA journal_mode = WAL")
        try database.exec("PRAGMA synchronous = NORMAL")
        try Self.migrate(database)
    }

    /// Forward-only migrations keyed on `user_version`. A downgrade is
    /// delete-and-repopulate (the store is a cache of server state).
    private static func migrate(_ database: SQLiteDatabase) throws {
        if database.userVersion < 1 {
            try database.exec(Schema.version1)
            database.userVersion = 1
        }
    }

    /// Drops every row (sign-out, or a corrupt-cache recovery).
    public func clear() throws {
        try database.exec("""
            DELETE FROM pending; DELETE FROM feed_sync; DELETE FROM items;
            DELETE FROM subscriptions; DELETE FROM folders;
            """)
    }

    // MARK: - Catalog

    /// What `replaceCatalog` removed, so the app can drop the per-subscription
    /// web-view storage of departed subscriptions.
    public struct CatalogDiff: Sendable, Equatable {
        public var removedSubscriptionIds: [String]
        public var removedDataStoreUuids: [String]
        public var removedFeedIds: [String]
    }

    /// Replaces the local catalog with the server's, deleting the items,
    /// cursors, and pending mutations of feeds no longer subscribed.
    public func replaceCatalog(_ catalog: RssCatalog) throws -> CatalogDiff {
        let existing = try subscriptions()
        let keep = Set(catalog.subscriptions.map(\.subscriptionId))
        let removed = existing.filter { !keep.contains($0.subscriptionId) }
        let keptFeeds = Set(catalog.subscriptions.map(\.feedId))
        try database.exec("BEGIN")
        do {
            for sub in removed {
                try database.run("DELETE FROM subscriptions WHERE subscription_id = ?", [.init(sub.subscriptionId)])
            }
            for feedId in Set(removed.map(\.feedId)).subtracting(keptFeeds) {
                try deleteFeedRows(feedId)
            }
            for sub in catalog.subscriptions {
                try upsertSubscription(sub)
            }
            let folderIds = catalog.folders.map(\.folderId)
            for row in try database.rows("SELECT folder_id FROM folders") where !folderIds.contains(row.string(0)) {
                try database.run("DELETE FROM folders WHERE folder_id = ?", [.init(row.string(0))])
            }
            for folder in catalog.folders {
                try database.run("""
                    INSERT INTO folders (folder_id, parent_folder_id, name, display_order)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(folder_id) DO UPDATE SET parent_folder_id = excluded.parent_folder_id,
                      name = excluded.name, display_order = excluded.display_order
                    """, [.init(folder.folderId), .init(folder.parentFolderId), .init(folder.name),
                          .init(folder.displayOrder)])
            }
            try database.exec("COMMIT")
        } catch {
            try? database.exec("ROLLBACK")
            throw error
        }
        return CatalogDiff(
            removedSubscriptionIds: removed.map(\.subscriptionId),
            removedDataStoreUuids: removed.map(\.dataStoreUuid).filter { !$0.isEmpty },
            removedFeedIds: Array(Set(removed.map(\.feedId)).subtracting(keptFeeds)).sorted()
        )
    }

    /// Writes one subscription (after a server-side update or subscribe).
    public func upsertSubscription(_ sub: RssSubscription) throws {
        let feedJson = sub.feed.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try database.run("""
            INSERT INTO subscriptions (subscription_id, feed_id, folder_id, custom_title, ordering_mode,
              default_open_mode, default_styling, notifications_enabled, credentials_scheme,
              read_watermark, data_store_uuid, created_at, feed_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(subscription_id) DO UPDATE SET feed_id = excluded.feed_id,
              folder_id = excluded.folder_id, custom_title = excluded.custom_title,
              ordering_mode = excluded.ordering_mode, default_open_mode = excluded.default_open_mode,
              default_styling = excluded.default_styling,
              notifications_enabled = excluded.notifications_enabled,
              credentials_scheme = excluded.credentials_scheme,
              read_watermark = MAX(subscriptions.read_watermark, excluded.read_watermark),
              data_store_uuid = excluded.data_store_uuid, created_at = excluded.created_at,
              feed_json = CASE WHEN excluded.feed_json = '' THEN subscriptions.feed_json
                               ELSE excluded.feed_json END
            """, [.init(sub.subscriptionId), .init(sub.feedId), .init(sub.folderId), .init(sub.customTitle),
                  .init(sub.orderingMode.rawValue), .init(sub.defaultOpenMode.rawValue),
                  .init(sub.defaultStyling.rawValue), .init(sub.notificationsEnabled),
                  .init(sub.credentialsScheme), .init(sub.readWatermark), .init(sub.dataStoreUuid),
                  .init(sub.createdAt), .init(feedJson ?? "")])
    }

    public func folders() throws -> [RssFolder] {
        try database.rows(
            "SELECT folder_id, parent_folder_id, name, display_order FROM folders ORDER BY display_order, name"
        ).map {
            RssFolder(folderId: $0.string(0), parentFolderId: $0.string(1), name: $0.string(2), displayOrder: $0.int(3))
        }
    }

    public func subscriptions() throws -> [RssSubscription] {
        try database.rows("SELECT \(Schema.subscriptionColumns) FROM subscriptions ORDER BY subscription_id")
            .map(Self.subscription(from:))
    }

    public func subscription(id: String) throws -> RssSubscription? {
        try database.rows("SELECT \(Schema.subscriptionColumns) FROM subscriptions WHERE subscription_id = ?",
            [.init(id)])
            .first.map(Self.subscription(from:))
    }

    static func subscription(from row: SQLiteDatabase.Row) -> RssSubscription {
        let feed = row.string(12).isEmpty ? nil
            : try? JSONDecoder().decode(RssFeedSummary.self, from: Data(row.string(12).utf8))
        return RssSubscription(
            subscriptionId: row.string(0), feedId: row.string(1), folderId: row.string(2),
            customTitle: row.string(3), orderingMode: RssOrderingMode(rawValue: row.string(4)) ?? .newestFirst,
            defaultOpenMode: RssOpenMode(rawValue: row.string(5)) ?? .summary,
            defaultStyling: RssStyling(rawValue: row.string(6)) ?? .reader,
            notificationsEnabled: row.bool(7), credentialsScheme: row.string(8), readWatermark: row.string(9),
            dataStoreUuid: row.string(10), createdAt: row.string(11), feed: feed
        )
    }

    /// The feed ids a scope covers, honouring folder nesting.
    func feedIds(in scope: RssItemScope) throws -> [String] {
        let subs = try subscriptions()
        switch scope {
        case .all:
            return Array(Set(subs.map(\.feedId))).sorted()
        case .subscription(let id):
            return subs.first { $0.subscriptionId == id }.map { [$0.feedId] } ?? []
        case .folder(let folderId):
            let wanted = try descendantFolderIds(of: folderId)
            return Array(Set(subs.filter { wanted.contains($0.folderId) }.map(\.feedId))).sorted()
        }
    }

    func descendantFolderIds(of folderId: String) throws -> Set<String> {
        let byParent = Dictionary(grouping: try folders(), by: \.parentFolderId)
        var wanted: Set<String> = [folderId]
        var frontier = [folderId]
        while let current = frontier.popLast() {
            for child in byParent[current] ?? [] where !wanted.contains(child.folderId) {
                wanted.insert(child.folderId)
                frontier.append(child.folderId)
            }
        }
        return wanted
    }

    func deleteFeedRows(_ feedId: String) throws {
        for table in ["items", "feed_sync", "pending"] {
            try database.run("DELETE FROM \(table) WHERE feed_id = ?", [.init(feedId)])
        }
    }
}

enum Schema {
    static let subscriptionColumns = """
        subscription_id, feed_id, folder_id, custom_title, ordering_mode, default_open_mode,
        default_styling, notifications_enabled, credentials_scheme, read_watermark,
        data_store_uuid, created_at, feed_json
        """
    static let itemColumns = """
        i.feed_id, i.sort_key, i.item_id, i.guid, i.title, i.author, i.url, i.published_at,
        i.updated_at, i.fetched_at, i.fetched_key, i.summary_html, i.content_html,
        (\(readExpression)) AS effective_read, i.is_favorite,
        COALESCE((SELECT s.subscription_id FROM subscriptions s WHERE s.feed_id = i.feed_id LIMIT 1), '')
        """
    /// The read-state rule in SQL; `i` is the items alias and the
    /// subscription's watermark is looked up per row.
    static let readExpression = """
        CASE WHEN i.state_is_explicit = 1 THEN i.is_read
             ELSE (i.is_read = 1 OR i.published_at <= COALESCE(
                 (SELECT s.read_watermark FROM subscriptions s WHERE s.feed_id = i.feed_id LIMIT 1), '')) END
        """

    static let version1 = """
        CREATE TABLE IF NOT EXISTS folders (
          folder_id TEXT PRIMARY KEY, parent_folder_id TEXT NOT NULL DEFAULT '',
          name TEXT NOT NULL, display_order INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS subscriptions (
          subscription_id TEXT PRIMARY KEY, feed_id TEXT NOT NULL, folder_id TEXT NOT NULL DEFAULT '',
          custom_title TEXT NOT NULL DEFAULT '', ordering_mode TEXT NOT NULL DEFAULT 'newest_first',
          default_open_mode TEXT NOT NULL DEFAULT 'summary', default_styling TEXT NOT NULL DEFAULT 'reader',
          notifications_enabled INTEGER NOT NULL DEFAULT 0, credentials_scheme TEXT NOT NULL DEFAULT '',
          read_watermark TEXT NOT NULL DEFAULT '', data_store_uuid TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL DEFAULT '', feed_json TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS subscriptions_feed ON subscriptions (feed_id);
        CREATE TABLE IF NOT EXISTS items (
          id INTEGER PRIMARY KEY AUTOINCREMENT, feed_id TEXT NOT NULL, sort_key TEXT NOT NULL,
          item_id TEXT NOT NULL DEFAULT '', guid TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '',
          author TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT '', fetched_at TEXT NOT NULL DEFAULT '',
          fetched_key TEXT NOT NULL DEFAULT '', summary_html TEXT NOT NULL DEFAULT '',
          content_html TEXT NOT NULL DEFAULT '', body_text TEXT NOT NULL DEFAULT '',
          is_read INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0,
          state_is_explicit INTEGER NOT NULL DEFAULT 0, cached_at TEXT NOT NULL DEFAULT '',
          UNIQUE (feed_id, sort_key));
        CREATE INDEX IF NOT EXISTS items_feed_fetched ON items (feed_id, fetched_key);
        CREATE INDEX IF NOT EXISTS items_feed_published ON items (feed_id, published_at);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
          title, body_text, content='items', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(rowid, title, body_text) VALUES (new.id, new.title, new.body_text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, title, body_text)
            VALUES ('delete', old.id, old.title, old.body_text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE OF title, body_text ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, title, body_text)
            VALUES ('delete', old.id, old.title, old.body_text);
          INSERT INTO items_fts(rowid, title, body_text) VALUES (new.id, new.title, new.body_text);
        END;
        CREATE TABLE IF NOT EXISTS feed_sync (
          feed_id TEXT PRIMARY KEY, since_cursor TEXT NOT NULL DEFAULT '',
          older_cursor TEXT NOT NULL DEFAULT '', older_exhausted INTEGER NOT NULL DEFAULT 0,
          last_synced_at TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS pending (
          id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, feed_id TEXT NOT NULL DEFAULT '',
          sort_key TEXT NOT NULL DEFAULT '', subscription_id TEXT NOT NULL DEFAULT '',
          value INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
        """
}
