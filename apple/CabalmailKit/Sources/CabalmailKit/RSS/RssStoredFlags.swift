import Foundation

/// A feed item's custom flags as `RssStore` keeps them: the `items.flags`
/// column, a sorted JSON list of palette slots, and the queued changes to
/// them, one `pending` row of kind `flag` per item and slot whose `value`
/// says add (1) or remove (0).
///
/// The column always shows what the queue will send. A local change writes
/// the column and its queue row in one transaction, and anything the server
/// reports is laid under the changes still queued (`overlaying`), slot by
/// slot: a change waiting here is newer than what the server had when it
/// answered, and only for its own slot.
enum RssStoredFlags {
    static func encode(_ slots: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(slots.sorted()) else { return "[]" }
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }

    /// Empty for anything that is not a JSON list of strings.
    static func decode(_ json: String) -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? [])
    }

    /// The server's flags for an item with that item's queued changes on
    /// top: a slot with a queued add is set and one with a queued remove is
    /// not, whatever the server said, and every other slot is the server's.
    static func overlaying(_ queued: [String: Bool], on server: Set<String>) -> Set<String> {
        var flags = server
        for (slot, isSet) in queued {
            if isSet { flags.insert(slot) } else { flags.remove(slot) }
        }
        return flags
    }

    /// Every queued flag change, by item (`RssItem.id`) and then slot: true
    /// for an add. The queue holds one per item and slot; were there two,
    /// the later one is the intent.
    static func queued(in database: SQLiteDatabase) throws -> [String: [String: Bool]] {
        var changes: [String: [String: Bool]] = [:]
        let rows = try database.rows(
            "SELECT feed_id, sort_key, slot, value FROM pending WHERE kind = ? ORDER BY id",
            [.init(RssStore.PendingKind.flag.rawValue)])
        for row in rows {
            changes["\(row.string(0))#\(row.string(1))", default: [:]][row.string(2)] = row.bool(3)
        }
        return changes
    }

    /// Sets or clears one slot on an item this device has; an item it does
    /// not have is left alone. Opens no transaction: the caller's holds it.
    static func write(
        _ slot: String, isSet: Bool, feedId: String, sortKey: String, in database: SQLiteDatabase
    ) throws {
        let key: [SQLiteDatabase.Value] = [.init(feedId), .init(sortKey)]
        guard let row = try database.rows("SELECT flags FROM items WHERE feed_id = ? AND sort_key = ?", key).first
        else { return }
        var flags = decode(row.string(0))
        if isSet { flags.insert(slot) } else { flags.remove(slot) }
        try database.run("UPDATE items SET flags = ? WHERE feed_id = ? AND sort_key = ?", [.init(encode(flags))] + key)
    }
}
