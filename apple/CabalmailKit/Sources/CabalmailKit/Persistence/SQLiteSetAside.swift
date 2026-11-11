import Foundation

/// Where a store's SQLite file goes when it cannot be opened - damaged, or
/// written by a newer build - instead of being deleted: a `set-aside/`
/// directory beside it.
///
/// A cache can be rebuilt, but a store's file may also hold what cannot be:
/// the feed store's queue of changes not yet sent. Deleting the file loses
/// them; a file set aside is out of the store's way and still on disk for a
/// build that can read it, as `RecordQuarantine` does for the record stores.
/// What reads a set-aside file back is the store's own business.
struct SQLiteSetAside {
    static let directoryName = "set-aside"

    /// The store's live database file.
    let database: URL
    private let fileManager = FileManager.default

    var directory: URL {
        database.deletingLastPathComponent().appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// Moves the live file, with its WAL and shared-memory files, into the
    /// directory under a new name. False when it is still in the way, which
    /// leaves it where it is rather than deleting it.
    @discardableResult
    func setAside(reason: String) -> Bool {
        guard fileManager.fileExists(atPath: database.path) else { return true }
        foldInWriteAheadLog()
        let destination = directory.appendingPathComponent(Self.name(for: database, at: Date()))
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: database, to: destination)
        } catch {
            CabalmailLog.error("SQLiteSetAside", "could not set \(database.lastPathComponent) aside: \(error)")
            return false
        }
        // The side files go too, under the matching names, so SQLite finds
        // them when the copy is opened. One left behind would be read as
        // belonging to the new file that takes this one's place.
        for suffix in Self.sideSuffixes {
            let side = URL(fileURLWithPath: database.path + suffix)
            guard fileManager.fileExists(atPath: side.path) else { continue }
            do {
                try fileManager.moveItem(at: side, to: URL(fileURLWithPath: destination.path + suffix))
            } catch {
                CabalmailLog.error("SQLiteSetAside", "could not move \(side.lastPathComponent) aside: \(error)")
                try? fileManager.removeItem(at: side)
            }
        }
        CabalmailLog.warn(
            "SQLiteSetAside",
            "set \(database.lastPathComponent) aside as \(destination.lastPathComponent): \(reason)"
        )
        return true
    }

    /// The database files set aside so far, oldest first.
    func files() -> [URL] {
        let found = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return found
            .filter { $0.pathExtension == database.pathExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Deletes one set-aside file and its side files, and the directory
    /// with the last of them.
    func remove(_ file: URL) {
        for suffix in [""] + Self.sideSuffixes {
            try? fileManager.removeItem(at: URL(fileURLWithPath: file.path + suffix))
        }
        if let left = try? fileManager.contentsOfDirectory(atPath: directory.path), left.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
    }

    /// Deletes every set-aside file (sign-out: they hold the account's data).
    func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    // MARK: - Names

    private static let sideSuffixes = ["-wal", "-shm"]

    /// `rss-1762867200123-1a2b3c4d.sqlite`: the time in milliseconds, so
    /// names sort oldest first, and a random tail, so two files set aside
    /// in one millisecond do not collide.
    static func name(for database: URL, at date: Date) -> String {
        let stamp = String(format: "%013lld", Int64(date.timeIntervalSince1970 * 1000))
        let tail = UUID().uuidString.prefix(8).lowercased()
        return "\(database.deletingPathExtension().lastPathComponent)-\(stamp)-\(tail).\(database.pathExtension)"
    }

    /// Writes the WAL's committed pages into the main file, when SQLite can
    /// still open it, so the one rename that follows carries every committed
    /// write even if a side file's move then fails. Best effort: a damaged
    /// file refuses, and its side files are moved as they are.
    private func foldInWriteAheadLog() {
        guard let connection = try? SQLiteDatabase(path: database.path, existing: true) else { return }
        try? connection.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        connection.close()
    }
}
