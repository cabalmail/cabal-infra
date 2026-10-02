import Foundation

/// Durable, Codable-backed draft store.
///
/// Each draft lives in its own JSON file under `directory/{id}.json` so a
/// corrupt or partially-written file only takes out the draft it belongs to.
/// Writes are atomic (`Data.write(to:options:.atomic)`). A single autosave
/// loop in `ComposeViewModel` updates the same draft in place — no fsync
/// fight between multiple compose windows because each owns a distinct `id`.
///
/// Cross-device sync layers on top of this store, not inside it: compose
/// pushes the buffer to the IMAP `Drafts` folder via `/save_draft`
/// (close-without-send plus a long debounce) and records the server
/// coordinates on the persisted `Draft`. This on-disk copy remains the live
/// editing buffer and the crash-recovery story.
///
/// Each file is a schema-versioned `PersistedRecord`. A file this build
/// can't read is moved to `quarantine/` instead of deleted, and one written
/// by a newer build is skipped and left alone.
public actor DraftStore {
    /// Bump when `Draft`'s persisted shape changes, and teach `read(_:)` to
    /// migrate the older version.
    static let schemaVersion = 1

    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Saves or replaces a draft. Empty drafts are removed rather than
    /// written, so a user who opens Compose and cancels immediately doesn't
    /// leave a `New Draft` breadcrumb behind.
    public func save(_ draft: Draft) throws {
        if draft.isEmpty {
            try remove(id: draft.id)
            return
        }
        var updated = draft
        updated.updatedAt = Date()
        let data = try PersistedRecordCoding.encode(updated, version: Self.schemaVersion, encoder: encoder)
        try data.write(to: fileURL(for: updated.id), options: .atomic)
    }

    /// Returns the draft with the given id, or nil if it's missing or
    /// unreadable. An unreadable file is quarantined so it stops tripping
    /// subsequent reads without the draft text being destroyed.
    public func load(id: UUID) throws -> Draft? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return read(data, at: url)
    }

    /// Lists every draft the store currently holds, most-recently-updated
    /// first. Unreadable files are quarantined and skipped (same recovery
    /// behavior as `load`).
    public func list() throws -> [Draft] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        var drafts: [Draft] = []
        for url in urls where url.pathExtension == "json" {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                RecordQuarantine.quarantine(url, reason: error, category: "DraftStore")
                continue
            }
            if let draft = read(data, at: url) {
                drafts.append(draft)
            }
        }
        return drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func remove(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Removes every draft, including unreadable and quarantined files, so
    /// sign-out leaves none of the previous account's text on disk.
    public func removeAll() throws {
        try RecordQuarantine.removeEverything(in: directory)
    }

    // MARK: - Internals

    private func read(_ data: Data, at url: URL) -> Draft? {
        switch PersistedRecordCoding.read(
            Draft.self, from: data, currentVersion: Self.schemaVersion, decoder: decoder
        ) {
        case .decoded(let draft):
            return draft
        case .newerSchema(let version):
            CabalmailLog.warn(
                "DraftStore",
                "skipping \(url.lastPathComponent): schema \(version) is newer than this build"
            )
            return nil
        case .undecodable(let error):
            RecordQuarantine.quarantine(url, reason: error, category: "DraftStore")
            return nil
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Millisecond-precision so two autosaves a few frames apart still
        // round-trip to distinct `updatedAt` values (the `list()` ordering
        // depends on this).
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
