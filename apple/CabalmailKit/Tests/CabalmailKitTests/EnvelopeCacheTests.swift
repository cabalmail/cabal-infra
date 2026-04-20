import XCTest
@testable import CabalmailKit

final class EnvelopeCacheTests: XCTestCase {
    private var tempDir: URL!
    private var cache: EnvelopeCache!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-envelope-cache-\(UUID().uuidString)")
        cache = try EnvelopeCache(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func envelope(uid: UInt32) -> Envelope {
        Envelope(uid: uid, subject: "uid-\(uid)")
    }

    // MARK: - remove(uids:folder:)

    func testRemoveDropsUIDsFromSnapshot() async throws {
        try await cache.merge(
            envelopes: [envelope(uid: 1), envelope(uid: 2), envelope(uid: 3)],
            uidValidity: 100,
            uidNext: 4,
            into: "INBOX"
        )
        try await cache.remove(uids: [2], folder: "INBOX")
        let snapshot = await cache.snapshot(for: "INBOX")
        XCTAssertEqual(Set(snapshot?.envelopes.keys ?? [:].keys), Set([1, 3]))
        XCTAssertEqual(snapshot?.uidValidity, 100)
        XCTAssertEqual(snapshot?.uidNext, 4)
    }

    func testRemoveIsNoOpForUnknownUID() async throws {
        try await cache.merge(
            envelopes: [envelope(uid: 1)],
            uidValidity: 100,
            uidNext: 2,
            into: "INBOX"
        )
        try await cache.remove(uids: [999], folder: "INBOX")
        let snapshot = await cache.snapshot(for: "INBOX")
        XCTAssertEqual(Array(snapshot?.envelopes.keys ?? [:].keys), [1])
    }

    func testRemoveWithoutSnapshotIsNoOp() async throws {
        try await cache.remove(uids: [1], folder: "Nope")
        let snapshot = await cache.snapshot(for: "Nope")
        XCTAssertNil(snapshot)
    }

    // MARK: - replace(..., keepingRange:)

    /// The core "pull-to-refresh prunes archived messages" behavior. The
    /// refresh window is 50..100; server returns only 50, 52, 53; we should
    /// drop 51, 54..100 from the snapshot but keep any older pages (below
    /// 50) intact.
    func testReplacePrunesMissingUIDsInsideRange() async throws {
        try await cache.merge(
            envelopes: (10...60).map { envelope(uid: $0) },
            uidValidity: 100,
            uidNext: 61,
            into: "INBOX"
        )
        try await cache.replace(
            envelopes: [envelope(uid: 50), envelope(uid: 52), envelope(uid: 53)],
            uidValidity: 100,
            uidNext: 61,
            keepingRange: 50...60,
            into: "INBOX"
        )
        let snapshot = await cache.snapshot(for: "INBOX")
        let remaining = Set(snapshot?.envelopes.keys ?? [:].keys)
        // Below the range: kept. Inside the range: only the returned three.
        XCTAssertEqual(remaining, Set((10...49)).union([50, 52, 53]))
    }

    func testReplaceWithNilRangeReplacesEverything() async throws {
        try await cache.merge(
            envelopes: (1...5).map { envelope(uid: $0) },
            uidValidity: 100,
            uidNext: 6,
            into: "INBOX"
        )
        try await cache.replace(
            envelopes: [envelope(uid: 10)],
            uidValidity: 100,
            uidNext: 11,
            keepingRange: nil,
            into: "INBOX"
        )
        let snapshot = await cache.snapshot(for: "INBOX")
        XCTAssertEqual(Array(snapshot?.envelopes.keys ?? [:].keys), [10])
    }

    /// UIDVALIDITY change tears down the existing snapshot entirely, which
    /// matches the reconnect-flow assumption that old UIDs are meaningless
    /// after a renumber.
    func testReplaceClearsOldOnUIDValidityMismatch() async throws {
        try await cache.merge(
            envelopes: [envelope(uid: 1)],
            uidValidity: 100,
            uidNext: 2,
            into: "INBOX"
        )
        try await cache.replace(
            envelopes: [envelope(uid: 5)],
            uidValidity: 200,
            uidNext: 6,
            keepingRange: 1...10,
            into: "INBOX"
        )
        let snapshot = await cache.snapshot(for: "INBOX")
        XCTAssertEqual(snapshot?.uidValidity, 200)
        XCTAssertEqual(Array(snapshot?.envelopes.keys ?? [:].keys), [5])
    }
}
