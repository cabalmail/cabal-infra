import XCTest
@testable import CabalmailKit

/// The window record a snapshot carries: where its rows sat on the server,
/// so a list hydrated from disk can prove a row gone the way the session
/// that wrote it could (#1836). The cache's part of that is the pairing
/// guarantee -- a stored record always vouches for rows that are still
/// stored with it, whatever else has written the snapshot since.
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

    /// The merge leaves the rows of an earlier session beside the window's.
    /// The record vouches for its own rows, not for the snapshot: it used to
    /// be dropped here, which is every write to a folder paged past its top
    /// page, so the next launch was anchored to nothing (#1836).
    func testAMergeKeepsARecordBesideRowsItDoesNotName() async throws {
        try await cache.merge(envelopes: [envelope(9)], uidValidity: 7, uidNext: 10, into: "INBOX")

        try await cache.merge(
            envelopes: [envelope(1), envelope(2)], uidValidity: 7, uidNext: 3,
            window: record(total: 600, uids: [1, 2]), into: "INBOX"
        )

        let uids = await savedUIDs()
        let saved = await savedRecord()
        XCTAssertEqual(uids, [1, 2, 9], "the older row stays in the snapshot")
        XCTAssertEqual(saved.map { Set($0.uids) }, [1, 2], "and the record still places the window's own rows")
    }

    /// The surviving half of the old equality rule: a record naming a row
    /// that is not on disk is dropped, because the write that took the row
    /// away moved the positions the rest were proven at. So is one naming no
    /// rows, which would otherwise vouch for every snapshot there is.
    func testAMergeDropsARecordNamingARowItDidNotLeaveOnDisk() async throws {
        try await cache.merge(
            envelopes: [envelope(1)], uidValidity: 7, uidNext: 3,
            window: record(total: 600, uids: [1, 2]), into: "INBOX"
        )
        let missingRow = await savedRecord()
        XCTAssertNil(missingRow)

        try await cache.merge(
            envelopes: [envelope(1)], uidValidity: 7, uidNext: 3,
            window: record(total: 600, uids: []), into: "INBOX"
        )
        let noRows = await savedRecord()
        XCTAssertNil(noRows)
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

    /// A removal narrows the record rather than discarding it: archiving one
    /// row used to throw away what placed every other row on disk (#1836).
    /// The row left the folder, so the record's count comes down with it.
    func testARemovalNarrowsTheRecordAndMarkingReadKeepsIt() async throws {
        try await cache.merge(
            envelopes: [envelope(1), envelope(2)], uidValidity: 7, uidNext: 3,
            window: record(total: 600, uids: [1, 2]), into: "INBOX"
        )

        try await cache.markAllSeen(folder: "INBOX")
        let afterMarking = await savedRecord()
        XCTAssertNotNil(afterMarking, "the same rows, with a flag changed")

        try await cache.remove(uids: [2], folder: "INBOX")
        let stored = await savedRecord()
        let afterRemoval = try XCTUnwrap(stored)
        XCTAssertEqual(Set(afterRemoval.uids), [1], "the row that left is no longer vouched for")
        XCTAssertEqual(afterRemoval.total, 599, "and the folder is one message shorter")

        try await cache.remove(uids: [1], folder: "INBOX")
        let afterLastRow = await savedRecord()
        XCTAssertNil(afterLastRow, "a record naming no rows vouches for nothing")
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
