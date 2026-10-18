import XCTest
@testable import CabalmailKit

/// The two offline caches, driven with the pair of folders that used to share
/// one file on disk: a nested `zzc/qq` and its flat sibling `zzc_qq` (#1871,
/// reproduced on stage with one distinct message in each, both UID 1).
final class FolderCacheCollisionTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-folder-cache-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEachFolderKeepsItsOwnEnvelopeSnapshot() async throws {
        let cache = try EnvelopeCache(directory: tempDir)
        try await cache.merge(
            envelopes: [Envelope(uid: 1, subject: "Outbox test")],
            uidValidity: 1_784_161_201, uidNext: 2, into: "zzc/qq"
        )
        try await cache.merge(
            envelopes: [Envelope(uid: 1, subject: "Notification test")],
            uidValidity: 1_784_161_202, uidNext: 2, into: "zzc_qq"
        )

        // Before the fix the second merge replaced the first wholesale, so
        // the nested folder read back the flat one's message.
        let nested = await cache.snapshot(for: "zzc/qq")
        let flat = await cache.snapshot(for: "zzc_qq")
        XCTAssertEqual(nested?.envelopes[1]?.subject, "Outbox test")
        XCTAssertEqual(flat?.envelopes[1]?.subject, "Notification test")
        XCTAssertEqual(nested?.uidValidity, 1_784_161_201)
        XCTAssertEqual(flat?.uidValidity, 1_784_161_202)
        XCTAssertEqual(try snapshotFileCount(), 2, "one file per folder, not one shared file")
    }

    func testEachFolderKeepsItsOwnBodies() async throws {
        let cache = try MessageBodyCache(directory: tempDir)
        try await cache.store(folder: "zzc/qq", uidValidity: 7, uid: 1, bytes: Data("nested".utf8))
        try await cache.store(folder: "zzc_qq", uidValidity: 7, uid: 1, bytes: Data("flat".utf8))

        // Same UIDVALIDITY and UID: the case the report says collides in the
        // body cache by construction.
        let nested = await cache.fetch(folder: "zzc/qq", uidValidity: 7, uid: 1)
        let flat = await cache.fetch(folder: "zzc_qq", uidValidity: 7, uid: 1)
        XCTAssertEqual(nested, Data("nested".utf8))
        XCTAssertEqual(flat, Data("flat".utf8))
    }

    func testOpeningDropsSnapshotsWrittenUnderTheOldNames() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let legacy = tempDir.appendingPathComponent("zzc_qq.envelopes.json")
        try Data("{}".utf8).write(to: legacy)

        let cache = try EnvelopeCache(directory: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "an ambiguous snapshot cannot be renamed, so it is dropped")

        // And the sweep is not indiscriminate: a snapshot this build wrote
        // survives the next open.
        try await cache.merge(
            envelopes: [Envelope(uid: 1, subject: "kept")],
            uidValidity: 1, uidNext: 2, into: "zzc/qq"
        )
        _ = try EnvelopeCache(directory: tempDir)
        let reopened = try EnvelopeCache(directory: tempDir)
        let snapshot = await reopened.snapshot(for: "zzc/qq")
        XCTAssertEqual(snapshot?.envelopes[1]?.subject, "kept")
    }

    func testOpeningDropsBodyFoldersWrittenUnderTheOldNames() async throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("zzc_qq/7"), withIntermediateDirectories: true
        )
        let legacy = tempDir.appendingPathComponent("zzc_qq/7/1.eml")
        try Data("stale".utf8).write(to: legacy)

        let cache = try MessageBodyCache(directory: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        try await cache.store(folder: "zzc_qq", uidValidity: 7, uid: 1, bytes: Data("fresh".utf8))
        _ = try MessageBodyCache(directory: tempDir)
        let kept = await cache.fetch(folder: "zzc_qq", uidValidity: 7, uid: 1)
        XCTAssertEqual(kept, Data("fresh".utf8))
    }

    private func snapshotFileCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasSuffix(".envelopes.json") }.count
    }
}
