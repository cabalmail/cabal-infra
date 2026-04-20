import Foundation

/// Per-folder envelope mirror, keyed by the folder's current UIDVALIDITY.
///
/// On reconnect, the Phase 3 flow is:
/// 1. `STATUS` the folder to grab the current `UIDVALIDITY` + `UIDNEXT`.
/// 2. If `UIDVALIDITY` matches the stored value, `UID FETCH` from the
///    last-seen `UIDNEXT` forward to pull only new messages.
/// 3. If `UIDVALIDITY` differs, invalidate the whole cache — the server
///    renumbered the folder and existing UIDs are meaningless.
///
/// Persisted as per-folder JSON blobs in the application support directory
/// so eviction is as cheap as unlinking the folder's file.
public actor EnvelopeCache {
    public struct Snapshot: Sendable, Codable {
        public let uidValidity: UInt32
        public let uidNext: UInt32
        public let envelopes: [UInt32: Envelope]

        public init(uidValidity: UInt32, uidNext: UInt32, envelopes: [UInt32: Envelope]) {
            self.uidValidity = uidValidity
            self.uidNext = uidNext
            self.envelopes = envelopes
        }
    }

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func snapshot(for folder: String) -> Snapshot? {
        let url = fileURL(for: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    public func store(_ snapshot: Snapshot, for folder: String) throws {
        let url = fileURL(for: folder)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public func invalidate(folder: String) throws {
        let url = fileURL(for: folder)
        try? fileManager.removeItem(at: url)
    }

    public func merge(envelopes: [Envelope], uidValidity: UInt32, uidNext: UInt32, into folder: String) throws {
        let existing = snapshot(for: folder)
        var merged: [UInt32: Envelope]
        if let existing, existing.uidValidity == uidValidity {
            merged = existing.envelopes
        } else {
            merged = [:]
        }
        for envelope in envelopes {
            merged[envelope.uid] = envelope
        }
        try store(
            Snapshot(uidValidity: uidValidity, uidNext: uidNext, envelopes: merged),
            for: folder
        )
    }

    /// Drops the given UIDs from the folder's on-disk snapshot. Called by
    /// the view model after a successful `UID MOVE` so the cached mirror
    /// doesn't keep pointing at a message the server no longer has in this
    /// mailbox — the chief cause of "archived messages reappear after
    /// relaunch" before this hook existed.
    ///
    /// No-op when the folder has no snapshot yet or the UIDs aren't in it.
    public func remove(uids: [UInt32], folder: String) throws {
        guard !uids.isEmpty, let existing = snapshot(for: folder) else { return }
        var envelopes = existing.envelopes
        var changed = false
        for uid in uids where envelopes.removeValue(forKey: uid) != nil {
            changed = true
        }
        guard changed else { return }
        try store(
            Snapshot(
                uidValidity: existing.uidValidity,
                uidNext: existing.uidNext,
                envelopes: envelopes
            ),
            for: folder
        )
    }

    /// Writes a fresh snapshot that merges `envelopes` into the existing
    /// cache, but with a critical difference from `merge(...)`: any UID
    /// inside `keepingRange` that the server *didn't* return is dropped.
    ///
    /// Semantics:
    ///
    /// - UIDs outside `keepingRange` are retained (those represent older
    ///   pages the caller didn't refetch).
    /// - UIDs inside `keepingRange` are kept only if the server returned
    ///   them in `envelopes`.
    /// - A `nil` `keepingRange` replaces the full folder — any cached UID
    ///   missing from `envelopes` is dropped.
    ///
    /// This is the path `MessageListViewModel.refresh` uses so a move /
    /// expunge that happened on another client (webmail, another device,
    /// or this client before a crash) prunes stale rows on pull-to-refresh.
    public func replace(
        envelopes: [Envelope],
        uidValidity: UInt32,
        uidNext: UInt32,
        keepingRange: ClosedRange<UInt32>?,
        into folder: String
    ) throws {
        let existing = snapshot(for: folder)
        var merged: [UInt32: Envelope]
        if let existing, existing.uidValidity == uidValidity {
            merged = existing.envelopes
        } else {
            merged = [:]
        }
        if let keepingRange {
            // Drop cached UIDs inside the refresh window that the server
            // didn't return. Outside-window entries (older pages) stay.
            merged = merged.filter { uid, _ in
                if keepingRange.contains(uid) {
                    return envelopes.contains { $0.uid == uid }
                }
                return true
            }
        } else {
            merged = [:]
        }
        for envelope in envelopes {
            merged[envelope.uid] = envelope
        }
        try store(
            Snapshot(uidValidity: uidValidity, uidNext: uidNext, envelopes: merged),
            for: folder
        )
    }

    private func fileURL(for folder: String) -> URL {
        // Path-separator characters would nest into real subdirectories on
        // disk — collapse them into a single hash-safe filename.
        let safe = folder
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return directory.appendingPathComponent("\(safe).envelopes.json")
    }
}
