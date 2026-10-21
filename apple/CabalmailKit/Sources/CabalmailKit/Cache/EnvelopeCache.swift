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
        /// Where these rows sat on the server when they were written, when
        /// that was known; nil for a snapshot nothing proved (see
        /// `WindowRecord`). Absent from snapshots written before it existed.
        public let window: WindowRecord?

        public init(
            uidValidity: UInt32,
            uidNext: UInt32,
            envelopes: [UInt32: Envelope],
            window: WindowRecord? = nil
        ) {
            self.uidValidity = uidValidity
            self.uidNext = uidNext
            self.envelopes = envelopes
            self.window = window
        }
    }

    /// The folder STATUS a snapshot's rows were proven to line up with, so a
    /// list hydrated from disk knows where they sat and the first refresh can
    /// prove a row gone without reading the whole folder (#1836). Without one
    /// a hydrated window is anchored to nothing: rows removed while the
    /// folder was closed stay on disk in any folder one page can't hold, an
    /// offline launch shows them and a Spotlight hit opens them.
    ///
    /// `uids` is what pairs the record with the snapshot it sits in: it names
    /// the rows the anchor was proven over, and it vouches for those rows
    /// only. The snapshot is wider than any one window -- it accumulates
    /// every row ever cached for the folder, while the loaded window moves
    /// independently -- so the record has to survive sitting beside rows it
    /// says nothing about, and a reader may prove gone only the rows it
    /// names (`WindowAlignment.vouchedUIDs`). `sort` is the order those
    /// positions were read in, since they mean nothing under another one.
    public struct WindowRecord: Sendable, Codable, Equatable {
        /// The folder's not-deleted count and UIDNEXT when the rows were
        /// proven to match it (`WindowAnchor`).
        public let total: UInt32
        public let uidNext: UInt32
        public let sort: SortCriterion
        /// The UIDs the anchor was proven over, top-anchored at position 0.
        public let uids: [UInt32]

        public init(total: UInt32, uidNext: UInt32, sort: SortCriterion, uids: [UInt32]) {
            self.total = total
            self.uidNext = uidNext
            self.sort = sort
            self.uids = uids
        }

        /// Whether every row this record names is still among `uids` -- the
        /// rows a snapshot holds now. A record naming a row that has left
        /// the snapshot says nothing about the rest: the write that dropped
        /// it moved the positions the others were proven at. Rows on disk
        /// the record doesn't name are no business of its own (#1836): the
        /// snapshot is routinely wider than the window that proved part of
        /// it, and demanding equality deleted the record on every such
        /// write, which left the next launch anchored to nothing.
        ///
        /// A record naming no rows vouches for nothing, and would otherwise
        /// be a subset of every snapshot there is.
        public func vouches(for others: some Sequence<UInt32>) -> Bool {
            !uids.isEmpty && Set(uids).isSubset(of: Set(others))
        }

        /// This record with `removed` taken out: the rows it still names,
        /// and a total lowered by each row that has left the folder, so what
        /// it says about the survivors stays true. Nil once it names no rows.
        ///
        /// Dropping a row from a covered prefix leaves the rest a prefix
        /// under any sort, and a row removed from below one doesn't move it,
        /// so the record survives a removal it didn't ask for -- archiving
        /// one row used to discard the record covering every other row on
        /// disk (#1836).
        func removing(_ removed: Set<UInt32>) -> WindowRecord? {
            let kept = uids.filter { !removed.contains($0) }
            guard !kept.isEmpty else { return nil }
            return WindowRecord(
                total: UInt32(max(0, Int(total) - removed.count)),
                uidNext: uidNext,
                sort: sort,
                uids: kept
            )
        }
    }

    /// One mutation of the on-disk mirror, as observed through `changes()`.
    /// Every write path funnels through this cache, which makes the stream a
    /// single chokepoint for anything that must mirror the mailbox — the
    /// Spotlight indexer is the first consumer. Events carry deltas (what
    /// changed), not whole snapshots, so a routine page merge doesn't force
    /// consumers to reprocess thousands of untouched envelopes.
    public enum ChangeEvent: Sendable {
        case upserted(envelopes: [Envelope], folder: String)
        case removed(uids: [UInt32], folder: String)
        /// The folder's snapshot was dropped wholesale — an explicit
        /// `invalidate` or a UIDVALIDITY change (old UIDs are meaningless).
        case invalidated(folder: String)
        case cleared
    }

    private let directory: URL
    private let fileManager: FileManager
    private var changeContinuations: [UUID: AsyncStream<ChangeEvent>.Continuation] = [:]

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.removeLegacySnapshots(in: directory, using: fileManager)
    }

    deinit {
        // Finish outstanding streams so a consumer's `for await` loop ends
        // with the cache (sign-out releases the per-session client) instead
        // of suspending forever and retaining its task's captures.
        for continuation in changeContinuations.values {
            continuation.finish()
        }
    }

    /// Async stream of every subsequent cache mutation. Multiple observers
    /// are supported; each stream ends when the cache is deallocated.
    public func changes() -> AsyncStream<ChangeEvent> {
        AsyncStream { continuation in
            let id = UUID()
            changeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }

    /// Test hook: whether any change-stream observer is registered. Events
    /// are not replayed to late subscribers, so tests that bind a consumer
    /// in a background task wait on this before mutating.
    var hasChangeObservers: Bool { !changeContinuations.isEmpty }

    private func emit(_ event: ChangeEvent) {
        for continuation in changeContinuations.values {
            continuation.yield(event)
        }
    }

    public func snapshot(for folder: String) -> Snapshot? {
        let url = fileURL(for: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    public func store(_ snapshot: Snapshot, for folder: String) throws {
        try write(snapshot, for: folder)
        // A whole-snapshot write has no delta to report; treat every entry
        // as upserted. `merge` / `replace` / `remove` use `write` directly
        // and emit the precise delta instead.
        emit(.upserted(envelopes: Array(snapshot.envelopes.values), folder: folder))
    }

    private func write(_ snapshot: Snapshot, for folder: String) throws {
        let url = fileURL(for: folder)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public func invalidate(folder: String) throws {
        let url = fileURL(for: folder)
        try? fileManager.removeItem(at: url)
        emit(.invalidated(folder: folder))
    }

    /// Drops every folder snapshot. Called on sign-out so the next account
    /// to sign in on this device can't read the previous user's envelopes
    /// from disk. The directory is recreated empty so the actor stays usable
    /// (the cache lives in a shared, non-user-scoped path).
    public func clearAll() throws {
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        emit(.cleared)
    }

    /// Folds `envelopes` into the folder's snapshot. `window` records where
    /// its rows sat on the server, and is kept only when every row it names
    /// is still on disk afterwards -- a record naming a row the merge didn't
    /// leave there says nothing about the others. A merge that passes none
    /// clears the one saved before, so a stored record is always one some
    /// caller vouched for over the snapshot holding it.
    public func merge(
        envelopes: [Envelope],
        uidValidity: UInt32,
        uidNext: UInt32,
        window: WindowRecord? = nil,
        into folder: String
    ) throws {
        let existing = snapshot(for: folder)
        var merged: [UInt32: Envelope]
        let uidValidityChanged: Bool
        if let existing, existing.uidValidity == uidValidity {
            merged = existing.envelopes
            uidValidityChanged = false
        } else {
            merged = [:]
            uidValidityChanged = existing != nil
        }
        for envelope in envelopes {
            merged[envelope.uid] = envelope
        }
        try write(
            Snapshot(
                uidValidity: uidValidity,
                uidNext: uidNext,
                envelopes: merged,
                window: window.flatMap { $0.vouches(for: merged.keys) ? $0 : nil }
            ),
            for: folder
        )
        if uidValidityChanged { emit(.invalidated(folder: folder)) }
        if !envelopes.isEmpty { emit(.upserted(envelopes: envelopes, folder: folder)) }
    }

    /// Marks every envelope in the folder's snapshot seen, as Mark All as
    /// Read just did on the server, so the folder keeps its saved list
    /// rather than losing it until it is next opened online (#1850). Reports
    /// only the envelopes it changed. No-op when the folder has no snapshot.
    public func markAllSeen(folder: String) throws {
        guard let existing = snapshot(for: folder) else { return }
        var envelopes = existing.envelopes
        var changed: [Envelope] = []
        for (uid, envelope) in envelopes where !envelope.flags.contains(.seen) {
            let seen = envelope.withFlags(envelope.flags.union([.seen]))
            envelopes[uid] = seen
            changed.append(seen)
        }
        guard !changed.isEmpty else { return }
        try write(
            Snapshot(
                uidValidity: existing.uidValidity,
                uidNext: existing.uidNext,
                envelopes: envelopes,
                // The rows are the same rows, with a flag changed, so the
                // window record still vouches for them.
                window: existing.window
            ),
            for: folder
        )
        emit(.upserted(envelopes: changed, folder: folder))
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
        var removed: Set<UInt32> = []
        for uid in uids where envelopes.removeValue(forKey: uid) != nil {
            removed.insert(uid)
        }
        guard !removed.isEmpty else { return }
        try write(
            Snapshot(
                uidValidity: existing.uidValidity,
                uidNext: existing.uidNext,
                envelopes: envelopes,
                // The rows left the folder, so the record's own count moves
                // with them and it goes on vouching for the rest.
                window: existing.window?.removing(removed)
            ),
            for: folder
        )
        emit(.removed(uids: uids, folder: folder))
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
        let uidValidityChanged: Bool
        if let existing, existing.uidValidity == uidValidity {
            merged = existing.envelopes
            uidValidityChanged = false
        } else {
            merged = [:]
            uidValidityChanged = existing != nil
        }
        let before = Set(merged.keys)
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
        let dropped = before.subtracting(merged.keys).sorted()
        try write(
            Snapshot(uidValidity: uidValidity, uidNext: uidNext, envelopes: merged),
            for: folder
        )
        if uidValidityChanged { emit(.invalidated(folder: folder)) }
        if !dropped.isEmpty { emit(.removed(uids: dropped, folder: folder)) }
        if !envelopes.isEmpty { emit(.upserted(envelopes: envelopes, folder: folder)) }
    }

    private static let fileSuffix = ".envelopes.json"

    private func fileURL(for folder: String) -> URL {
        // One path component per folder, and a different one for every
        // distinct folder: the old collapse of `/` and `.` into `_` gave
        // `a/b` and `a_b` the same file (#1871, `FolderCacheName`).
        directory.appendingPathComponent(
            FolderCacheName.component(for: folder) + Self.fileSuffix
        )
    }

    /// Drops snapshots written under the pre-#1871 names, once, at open.
    ///
    /// They cannot be renamed: the old name does not say which folder wrote
    /// it, which is the defect. A snapshot is rebuilt from the server on the
    /// next online visit, so dropping is the whole migration.
    private static func removeLegacySnapshots(in directory: URL, using fileManager: FileManager) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(fileSuffix) {
            let base = String(name.dropLast(fileSuffix.count))
            guard !FolderCacheName.isCurrent(base: base) else { continue }
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
