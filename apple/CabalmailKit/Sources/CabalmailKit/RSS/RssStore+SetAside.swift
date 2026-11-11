import Foundation

// MARK: - Files set aside, and the unsent changes in them

extension RssStore {
    /// How many set-aside files this build cannot read are kept: the newest,
    /// for a build that can. Older ones are deleted.
    static let unreadableSetAsideLimit = 3

    static func setAside(in directory: URL) -> SQLiteSetAside {
        SQLiteSetAside(database: directory.appendingPathComponent("rss.sqlite"))
    }

    /// One row of the `pending` queue: the six columns the schema has had
    /// since version 1, and `slot`, which version 7 added for a change to
    /// one custom flag and every other change leaves empty.
    struct QueuedChange: Equatable {
        var kind: String
        var feedId: String
        var sortKey: String
        var subscriptionId: String
        var value: Int
        var createdAt: String
        var slot: String

        /// The columns of the live queue, in the order `init(row:)` reads.
        static let columns = "kind, feed_id, sort_key, subscription_id, value, created_at, slot"

        /// `columns` for a file that may be older than this build: one from
        /// before version 7 has no `slot` column, and its rows read as
        /// having none.
        static func columns(in database: SQLiteDatabase) throws -> String {
            let hasSlot = try database.rows("PRAGMA table_info(pending)").contains { $0.string(1) == "slot" }
            return hasSlot ? columns : "kind, feed_id, sort_key, subscription_id, value, created_at, '' AS slot"
        }

        init(kind: String, feedId: String = "", sortKey: String = "", subscriptionId: String = "",
             value: Int = 0, createdAt: String, slot: String = "") {
            self.kind = kind
            self.feedId = feedId
            self.sortKey = sortKey
            self.subscriptionId = subscriptionId
            self.value = value
            self.createdAt = createdAt
            self.slot = slot
        }

        init(row: SQLiteDatabase.Row) {
            self.init(kind: row.string(0), feedId: row.string(1), sortKey: row.string(2),
                      subscriptionId: row.string(3), value: row.int(4), createdAt: row.string(5),
                      slot: row.string(6))
        }

        /// What only one queued change may exist for: an item, a kind and a
        /// slot, so changes to two flags of one item are two changes and
        /// both come back. Nil for a change that is not about one item (a
        /// mark-all-read), which never replaces another.
        var itemKey: String? {
            sortKey.isEmpty ? nil : "\(kind)|\(feedId)|\(sortKey)|\(slot)"
        }
    }

    /// Brings back the unsent changes of every set-aside file this build can
    /// read, deletes each file once its changes are in the live queue, and
    /// keeps only the newest few of the files it cannot read. Run at open,
    /// before anything else has the store.
    ///
    /// It is how an older build that set a newer file aside gives the newer
    /// build its unsent marks back, and how a file that failed to open keeps
    /// its queue. A failure here leaves the file for the next open and never
    /// fails this one.
    static func recoverSetAside(into database: SQLiteDatabase, directory: URL) {
        let aside = setAside(in: directory)
        var unreadable: [URL] = []
        // Newest first: each file's changes go in front of the queue, so the
        // oldest file's, restored last, end up first.
        for file in aside.files().reversed() {
            guard let changes = queuedChanges(inSetAside: file) else {
                unreadable.append(file)
                continue
            }
            let name = file.lastPathComponent
            do {
                try restore(changes, into: database)
                aside.remove(file)
                if !changes.isEmpty {
                    CabalmailLog.info("RssStore", "brought back \(changes.count) unsent feed changes from \(name)")
                }
            } catch {
                CabalmailLog.warn("RssStore", "could not bring back the unsent changes in \(name): \(error)")
            }
        }
        for file in unreadable.dropFirst(unreadableSetAsideLimit) {
            aside.remove(file)
        }
    }

    /// A set-aside file's queue in the order it was made, or nil when this
    /// build cannot read the file: a newer schema, or damage. A file from
    /// an older schema is read as it is, without the columns added since.
    static func queuedChanges(inSetAside file: URL) -> [QueuedChange]? {
        guard let database = try? SQLiteDatabase(path: file.path, existing: true) else { return nil }
        defer { database.close() }
        guard let version = try? database.userVersion(), version <= schemaVersion else { return nil }
        return try? database.rows("SELECT \(QueuedChange.columns(in: database)) FROM pending ORDER BY id")
            .map(QueuedChange.init(row:))
    }

    /// Puts a set-aside file's changes back in the live queue, in one
    /// transaction, and shows them on the items they are about.
    ///
    /// They go in front of the queue's own rows: the file was set aside
    /// before the live one existed, so each of its changes was made before
    /// any made since, and the drain must replay them in the order the user
    /// made them (a mark-all-read is a fence between item marks).
    static func restore(_ changes: [QueuedChange], into database: SQLiteDatabase) throws {
        guard !changes.isEmpty else { return }
        try database.transaction {
            let live = try database.rows("SELECT \(QueuedChange.columns) FROM pending ORDER BY id")
                .map(QueuedChange.init(row:))
            let queue = merged(restored: changes, live: live)
            try database.exec("DELETE FROM pending")
            for change in queue {
                try database.run("INSERT INTO pending (\(QueuedChange.columns)) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                 [.init(change.kind), .init(change.feedId), .init(change.sortKey),
                                  .init(change.subscriptionId), .init(change.value), .init(change.createdAt),
                                  .init(change.slot)])
            }
            // The whole queue again, in order, not only what came back: an
            // older mark-all-read must not undo a newer mark already shown.
            for change in queue {
                try showLocally(change, in: database)
            }
        }
    }

    /// The queue once a set-aside file's changes are back: those, then the
    /// live ones, with one change per item and kind (and slot, for a change
    /// to one flag). Of two for the same one the later `created_at` stays,
    /// and the live one on a tie.
    /// A change that is not about one item is dropped only when the same one
    /// is already there, which is what importing a file twice would make.
    static func merged(restored: [QueuedChange], live: [QueuedChange]) -> [QueuedChange] {
        let sequence = restored + live
        var winner: [String: Int] = [:]
        for (index, change) in sequence.enumerated() {
            guard let key = change.itemKey else { continue }
            if let held = winner[key], sequence[held].createdAt > change.createdAt { continue }
            winner[key] = index
        }
        var queue: [QueuedChange] = []
        for (index, change) in sequence.enumerated() {
            if let key = change.itemKey {
                if winner[key] == index { queue.append(change) }
            } else if !queue.contains(change) {
                queue.append(change)
            }
        }
        return queue
    }

    /// What a queued change does to the rows the lists read: the same
    /// writes `setRead`, `setFavorite`, `setFlag` and `markAllRead` make
    /// beside the queue row. A kind this build does not know changes
    /// nothing here.
    private static func showLocally(_ change: QueuedChange, in database: SQLiteDatabase) throws {
        switch PendingKind(rawValue: change.kind) {
        case .read:
            try database.run("UPDATE items SET is_read = ?, state_is_explicit = 1 WHERE feed_id = ? AND sort_key = ?",
                             [.init(change.value), .init(change.feedId), .init(change.sortKey)])
        case .favorite:
            try database.run("UPDATE items SET is_favorite = ? WHERE feed_id = ? AND sort_key = ?",
                             [.init(change.value), .init(change.feedId), .init(change.sortKey)])
        case .flag:
            try RssStoredFlags.write(change.slot, isSet: change.value != 0, feedId: change.feedId,
                                     sortKey: change.sortKey, in: database)
        case .markAllRead:
            // `created_at` carries the watermark (`markAllRead`).
            try database.run(
                "UPDATE subscriptions SET read_watermark = MAX(read_watermark, ?) WHERE subscription_id = ?",
                [.init(change.createdAt), .init(change.subscriptionId)])
            try database.run("""
                UPDATE items SET is_read = 1 WHERE feed_id = ? AND state_is_explicit = 1 AND is_read = 0
                  AND published_at <= ?
                """, [.init(change.feedId), .init(change.createdAt)])
        case nil:
            break
        }
    }
}
