import Foundation

/// Disk-backed LRU for full message bodies fetched via `UID FETCH BODY.PEEK[]`.
///
/// Entries live as raw files keyed by `<uidValidity>/<uid>.eml` inside a
/// per-folder subdirectory. Access recency is tracked via the file system's
/// mtime, which is cheap to read in bulk and robust across crashes. When
/// the total on-disk size exceeds `capacityBytes`, the least-recently-
/// touched files are removed until the total is back under the cap.
public actor MessageBodyCache {
    public let directory: URL
    public let capacityBytes: UInt64
    private let fileManager: FileManager

    public init(directory: URL, capacityBytes: UInt64 = 200 * 1024 * 1024, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.capacityBytes = capacityBytes
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fetch(folder: String, uidValidity: UInt32, uid: UInt32) -> Data? {
        let url = url(folder: folder, uidValidity: uidValidity, uid: uid)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Touch mtime so LRU ordering reflects read-access.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func store(folder: String, uidValidity: UInt32, uid: UInt32, bytes: Data) throws {
        let url = url(folder: folder, uidValidity: uidValidity, uid: uid)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        try evictIfNeeded()
    }

    /// Drops every cached body for a folder — called when `UIDVALIDITY`
    /// changes, since the server's UIDs are no longer the ones we indexed
    /// under.
    public func invalidate(folder: String) throws {
        let url = folderURL(folder: folder)
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Internals

    private func url(folder: String, uidValidity: UInt32, uid: UInt32) -> URL {
        folderURL(folder: folder)
            .appendingPathComponent(String(uidValidity))
            .appendingPathComponent("\(uid).eml")
    }

    private func folderURL(folder: String) -> URL {
        let safe = folder
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return directory.appendingPathComponent(safe)
    }

    private struct CacheEntry {
        let url: URL
        let size: UInt64
        let mtime: Date
    }

    private func evictIfNeeded() throws {
        var totalSize: UInt64 = 0
        var entries: [CacheEntry] = []

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey
        ]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true,
                  let size = values?.fileSize,
                  let mtime = values?.contentModificationDate else { continue }
            let entrySize = UInt64(size)
            totalSize += entrySize
            entries.append(CacheEntry(url: url, size: entrySize, mtime: mtime))
        }

        if totalSize <= capacityBytes { return }
        // Evict oldest first.
        entries.sort { $0.mtime < $1.mtime }
        var running = totalSize
        for entry in entries {
            if running <= capacityBytes { break }
            try? fileManager.removeItem(at: entry.url)
            running -= entry.size
        }
    }
}
