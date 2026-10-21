import XCTest
@testable import CabalmailKit

/// The window record a snapshot carries: where its rows sat on the server,
/// so a list hydrated from disk can prove a row gone the way the session
/// that wrote it could (#1836). The cache's part of that is the pairing
/// guarantee -- a stored record always describes the rows stored with it,
/// whatever else has written the snapshot since.
final class EnvelopeCacheWindowRecordTests: XCTestCase {
    private var tempDir: URL!
    private var cache: EnvelopeCache!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-window-record-\(UUID().uuidString)")
        cache = try EnvelopeCache(directory: tempDir)
    }

    override func tearDown() async throws {
        cache = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func envelope(_ uid: UInt32) -> Envelope {
        Envelope(uid: uid, subject: "Message \(uid)")
    }

    private func record(total: UInt32, uids: [UInt32], sort: SortCriterion = .default) -> EnvelopeCache.WindowRecord {
        EnvelopeCache.WindowRecord(total: total, uidNext: 601, sort: sort, uids: uids)
    }

    private func savedRecord(from cache: EnvelopeCache? = nil) async -> EnvelopeCache.WindowRecord? {
        await (cache ?? self.cache).snapshot(for: "INBOX")?.window
    }

    private func savedUIDs() async -> Set<UInt32>? {
        await cache.snapshot(for: "INBOX").map { Set($0.envelopes.keys) }
    }

    func testAMergeStoresARecordThatDescribesTheRowsItLeftOnDisk() async throws {
        let rows = (1...3).map { envelope(UInt32($0)) }

        try await cache.merge(
            envelopes: rows, uidValidity: 7, uidNext: 4,
            window: record(total: 600, uids: [1, 2, 3]), into: "INBOX"
        )

        let stored = await savedRecord()
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.total, 600)
        XCTAssertEqual(saved.uidNext, 601)
        XCTAssertEqual(saved.sort, .default)
        XCTAssertEqual(Set(saved.uids), [1, 2, 3])
    }

    /// The merge leaves the rows of an earlier session beside the window's,
    /// so the anchor was never proven over everything on disk: the record
    /// would overstate the window and is dropped.
    func testAMergeDropsARecordTheMergedRowsDontMatch() async throws {
        try await cache.merge(envelopes: [envelope(9)], uidValidity: 7, uidNext: 10, into: "INBOX")

        try await cache.merge(
            envelopes: [envelope(1), envelope(2)], uidValidity: 7, uidNext: 3,
            window: record(total: 600, uids: [1, 2]), into: "INBOX"
        )

        let uids = await savedUIDs()
        let saved = await savedRecord()
        XCTAssertEqual(uids, [1, 2, 9], "the older row stays in the snapshot")
        XCTAssertNil(saved, "and nothing proves where the rows on disk sit")
    }

    func testAMergeWithNoRecordClearsTheOneSavedBefore() async throws {
        try await cache.merge(
            envelopes: [envelope(1)], uidValidity: 7, uidNext: 2,
            window: record(total: 600, uids: [1]), into: "INBOX"
        )

        try await cache.merge(envelopes: [envelope(1)], uidValidity: 7, uidNext: 2, into: "INBOX")

        let saved = await savedRecord()
        XCTAssertNil(saved)
    }

    func testARemovalClearsTheRecordAndMarkingReadKeepsIt() async throws {
        try await cache.merge(
            envelopes: [envelope(1), envelope(2)], uidValidity: 7, uidNext: 3,
            window: record(total: 600, uids: [1, 2]), into: "INBOX"
        )

        try await cache.markAllSeen(folder: "INBOX")
        let afterMarking = await savedRecord()
        XCTAssertNotNil(afterMarking, "the same rows, with a flag changed")

        try await cache.remove(uids: [2], folder: "INBOX")
        let afterRemoval = await savedRecord()
        XCTAssertNil(afterRemoval, "a row left, so the record no longer holds")
    }

    func testTheRecordSurvivesAReopenAndGoesWithTheSnapshot() async throws {
        let subjectAscending = SortCriterion(field: .subject, direction: .ascending)
        try await cache.merge(
            envelopes: [envelope(1)], uidValidity: 7, uidNext: 2,
            window: record(total: 600, uids: [1], sort: subjectAscending), into: "INBOX"
        )

        let reopened = try EnvelopeCache(directory: tempDir)
        let stored = await savedRecord(from: reopened)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.sort, subjectAscending,
                       "the order the positions were read in comes back with them")

        try await reopened.clearAll()
        let afterSignOut = await reopened.snapshot(for: "INBOX")
        XCTAssertNil(afterSignOut, "sign-out takes the record with the rows")
    }

    /// A snapshot written before the record existed decodes, with none.
    func testASnapshotWrittenWithoutTheFieldStillDecodes() async throws {
        /// The snapshot as it was stored before it carried a window record.
        struct LegacySnapshot: Codable {
            let uidValidity: UInt32
            let uidNext: UInt32
            let envelopes: [UInt32: Envelope]
        }
        let legacy = LegacySnapshot(uidValidity: 7, uidNext: 4, envelopes: [1: envelope(1)])
        try JSONEncoder().encode(legacy).write(
            to: tempDir.appendingPathComponent(FolderCacheName.component(for: "INBOX") + ".envelopes.json")
        )

        let uids = await savedUIDs()
        let saved = await savedRecord()
        XCTAssertEqual(uids, [1])
        XCTAssertNil(saved)
    }
}
