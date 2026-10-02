import Foundation

/// Schema-versioned envelope for the one-file-per-record JSON stores
/// (`Outbox`, `DraftStore`).
///
/// A record is written as `{"schemaVersion": N, "payload": {...}}`. Files
/// written before the envelope existed hold the bare payload and read as
/// version 1. The version is what lets a later build migrate a record whose
/// shape changed instead of failing to decode it, and lets an older build
/// leave a newer build's record alone after a downgrade rather than
/// treating it as corrupt.
struct PersistedRecord<Payload: Codable>: Codable {
    let schemaVersion: Int
    let payload: Payload
}

/// What reading one persisted record produced.
enum PersistedRecordRead<Payload> {
    /// The record decoded at a schema version this build understands.
    case decoded(Payload)
    /// The record was written by a newer build. Leave it where it is: a
    /// re-upgrade will read it again.
    case newerSchema(Int)
    /// The bytes are not a record this build can read at any version.
    case undecodable(Error)
}

enum PersistedRecordCoding {
    /// Reads `data` as a `PersistedRecord<Payload>`, falling back to a bare
    /// legacy payload when there is no `schemaVersion` key.
    static func read<Payload: Codable>(
        _ type: Payload.Type,
        from data: Data,
        currentVersion: Int,
        decoder: JSONDecoder
    ) -> PersistedRecordRead<Payload> {
        do {
            let probe = try decoder.decode(VersionProbe.self, from: data)
            guard let version = probe.schemaVersion else {
                return .decoded(try decoder.decode(Payload.self, from: data))
            }
            if version > currentVersion {
                return .newerSchema(version)
            }
            return .decoded(try decoder.decode(PersistedRecord<Payload>.self, from: data).payload)
        } catch {
            return .undecodable(error)
        }
    }

    static func encode<Payload: Codable>(
        _ payload: Payload,
        version: Int,
        encoder: JSONEncoder
    ) throws -> Data {
        try encoder.encode(PersistedRecord(schemaVersion: version, payload: payload))
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int?
    }
}

/// Moves a record file that can't be read into a `quarantine/`
/// subdirectory next to it instead of deleting it.
///
/// Deleting an undecodable file turned every decode bug, and every future
/// model change that forgot a migration, into silent loss of queued mail or
/// draft text (audit F8). A quarantined file is out of the store's way but
/// still on disk for a later build, or a person, to recover. Sign-out wipes
/// the quarantine with the rest of the store.
enum RecordQuarantine {
    static let directoryName = "quarantine"

    @discardableResult
    static func quarantine(
        _ url: URL,
        reason: Error,
        category: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let quarantineDirectory = url.deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
        // A timestamp keeps a second bad copy of the same record from
        // colliding with the first.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let destination = quarantineDirectory.appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)-\(stamp).\(url.pathExtension)"
        )
        do {
            try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: url, to: destination)
            CabalmailLog.warn(
                category,
                "quarantined unreadable \(url.lastPathComponent) as \(destination.lastPathComponent): \(reason)"
            )
            return destination
        } catch {
            // Leave the file in place rather than delete it: a store that
            // keeps tripping over one file is better than lost mail.
            CabalmailLog.error(category, "could not quarantine \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Every file under `directory`, quarantine included. Used by the
    /// stores' `removeAll()` so sign-out leaves nothing of the previous
    /// account behind, readable or not.
    static func removeEverything(in directory: URL, fileManager: FileManager = .default) throws {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return
        }
        for url in urls {
            try fileManager.removeItem(at: url)
        }
    }
}
