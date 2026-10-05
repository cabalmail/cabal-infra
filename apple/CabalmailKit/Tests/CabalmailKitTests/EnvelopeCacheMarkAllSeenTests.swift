import XCTest
@testable import CabalmailKit

/// `EnvelopeCache.markAllSeen(folder:)`, which Mark All as Read uses to
/// keep a folder's saved list, read, instead of deleting it (#1850).
final class EnvelopeCacheMarkAllSeenTests: XCTestCase {
    private var tempDir: URL!
    private var cache: EnvelopeCache!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-envelope-seen-\(UUID().uuidString)")
        cache = try EnvelopeCache(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEveryEnvelopeIsKeptAndMarkedSeen() async throws {
        try await cache.merge(
            envelopes: [
                Envelope(uid: 1, subject: "unread, flagged", flags: [.flagged]),
                Envelope(uid: 2, subject: "unread"),
                Envelope(uid: 3, subject: "already read", flags: [.seen]),
            ],
            uidValidity: 100, uidNext: 4, into: "Archive"
        )

        try await cache.markAllSeen(folder: "Archive")

        let found = await cache.snapshot(for: "Archive")
        let snapshot = try XCTUnwrap(found)
        XCTAssertEqual(snapshot.uidValidity, 100)
        XCTAssertEqual(snapshot.uidNext, 4)
        XCTAssertEqual(snapshot.envelopes[1]?.flags, [.seen, .flagged], "other flags stay")
        XCTAssertEqual(snapshot.envelopes[2]?.flags, [.seen])
        XCTAssertEqual(snapshot.envelopes[3]?.flags, [.seen])
        XCTAssertEqual(snapshot.envelopes[1]?.subject, "unread, flagged", "the rest of the envelope stays")
    }

    /// Only the envelopes it changed are reported, so the Spotlight
    /// indexer re-indexes those and keeps the folder's other entries. The
    /// deletion this replaces reported the folder invalidated, which
    /// dropped every one of them from Spotlight.
    func testOnlyTheChangedEnvelopesAreReported() async throws {
        try await cache.merge(
            envelopes: [Envelope(uid: 1), Envelope(uid: 2, flags: [.seen])],
            uidValidity: 100, uidNext: 3, into: "Archive"
        )
        let stream = await cache.changes()

        try await cache.markAllSeen(folder: "Archive")

        let events = await buffered(stream)
        guard events.count == 1, case .upserted(let envelopes, let folder) = events[0] else {
            return XCTFail("expected one upsert, got \(events)")
        }
        XCTAssertEqual(folder, "Archive")
        XCTAssertEqual(envelopes.map(\.uid), [1])
    }

    func testAFolderWithNoSavedListStaysWithout() async throws {
        let stream = await cache.changes()

        try await cache.markAllSeen(folder: "Archive")

        let snapshot = await cache.snapshot(for: "Archive")
        XCTAssertNil(snapshot)
        let events = await buffered(stream)
        XCTAssertTrue(events.isEmpty)
    }

    func testAnAllReadFolderIsNotRewritten() async throws {
        try await cache.merge(
            envelopes: [Envelope(uid: 1, flags: [.seen])],
            uidValidity: 100, uidNext: 2, into: "Archive"
        )
        let stream = await cache.changes()

        try await cache.markAllSeen(folder: "Archive")

        let events = await buffered(stream)
        XCTAssertTrue(events.isEmpty)
    }

    /// The events already on `stream`, without waiting for more.
    private func buffered(_ stream: AsyncStream<EnvelopeCache.ChangeEvent>) async -> [EnvelopeCache.ChangeEvent] {
        let drain = Task {
            var events: [EnvelopeCache.ChangeEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        drain.cancel()
        return await drain.value
    }
}
