import Foundation

/// Durable, Codable-backed draft store.
///
/// Each draft lives in its own JSON file under `directory/{id}.json` so a
/// corrupt or partially-written file only takes out the draft it belongs to.
/// Writes are atomic (`Data.write(to:options:.atomic)`). A single autosave
/// loop in `ComposeViewModel` updates the same draft in place — no fsync
/// fight between multiple compose windows because each owns a distinct `id`.
///
/// Plan (Phase 5): local storage only. Phase 5.1 layers IMAP `APPEND` to the
/// `Drafts` folder on top of this for cross-device sync; the on-disk format
/// below is the canonical source of truth either way.
public actor DraftStore {
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
        let data = try encoder.encode(updated)
        try data.write(to: fileURL(for: updated.id), options: .atomic)
    }

    /// Returns the draft with the given id, or nil if it's missing or the
    /// on-disk JSON is unreadable. Corrupt files are deleted so they don't
    /// keep tripping subsequent reads.
    public func load(id: UUID) throws -> Draft? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(Draft.self, from: data)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Lists every draft the store currently holds, most-recently-updated
    /// first. Unreadable files are silently skipped (same recovery behavior
    /// as `load`).
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
            if let data = try? Data(contentsOf: url),
               let draft = try? decoder.decode(Draft.self, from: data) {
                drafts.append(draft)
            } else {
                try? FileManager.default.removeItem(at: url)
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

    public func removeAll() throws {
        for draft in try list() {
            try remove(id: draft.id)
        }
    }

    // MARK: - Internals

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
