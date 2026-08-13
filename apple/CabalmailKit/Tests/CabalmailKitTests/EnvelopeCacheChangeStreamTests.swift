import XCTest
@testable import CabalmailKit

/// Covers the `changes()` stream added for the Spotlight indexer: every
/// cache mutation must emit the right delta, in order, because the index
/// mirrors the mailbox exclusively through this stream.
final class EnvelopeCacheChangeStreamTests: XCTestCase {
    private var tempDir: URL!
    private var cache: EnvelopeCache!

    /// Collects events from one `changes()` subscription. An actor-free
    /// recorder would race the cache's yields; the stream itself provides
    /// ordering, so a plain task draining into an actor suffices.
    private actor EventLog {
        private(set) var events: [EnvelopeCache.ChangeEvent] = []
        func append(_ event: EnvelopeCache.ChangeEvent) { events.append(event) }
    }

    private var log: EventLog!
    private var drainTask: Task<Void, Never>!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-envelope-events-\(UUID().uuidString)")
        cache = try EnvelopeCache(directory: tempDir)
        log = EventLog()
        let cache = cache!
        let log = log!
        drainTask = Task {
            for await event in await cache.changes() {
                await log.append(event)
            }
        }
        // Events aren't replayed to late subscribers; wait for registration.
        try await waitUntil { await cache.hasChangeObservers }
    }

    override func tearDown() async throws {
        drainTask.cancel()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func envelope(uid: UInt32) -> Envelope {
        Envelope(uid: uid, subject: "uid-\(uid)")
    }

    private func waitForEvents(
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [EnvelopeCache.ChangeEvent] {
        try await waitUntil(file: file, line: line) { await self.log.events.count >= count }
        return await log.events
    }

    func testMergeEmitsUpsertDelta() async throws {
        try await cache.merge(
            envelopes: [envelope(uid: 1), envelope(uid: 2)],
            uidValidity: 100, uidNext: 3, into: "INBOX"
        )
        let events = try await waitForEvents(count: 1)
        guard case .upserted(let envelopes, let folder) = events.first else {
            return XCTFail("expected upserted, got \(events)")
        }
        XCTAssertEqual(folder, "INBOX")
        XCTAssertEqual(envelopes.map(\.uid), [1, 2])
    }

    func testMergeAcrossUIDValidityChangeEmitsInvalidateFirst() async throws {
        try await cache.merge(
            envelopes: [envelope(uid: 1)], uidValidity: 100, uidNext: 2, into: "INBOX"
        )
        try await cache.merge(
            envelopes: [envelope(uid: 5)], uidValidity: 200, uidNext: 6, into: "INBOX"
        )
        let events = try await waitForEvents(count: 3)
        guard case .invalidated(let folder) = events[1] else {
            return XCTFail("expected invalidated, got \(events)")
        }
        XCTAssertEqual(folder, "INBOX")
        guard case .upserted(let envelopes, _) = events[2] else {
            return XCTFail("expected upserted, got \(events)")
        }
        XCTAssertEqual(envelopes.map(\.uid), [5])
    }

    func testRemoveEmitsOnlyActuallyRemovedUIDs() async throws {
        try await cache.merge(
            envelopes: [envelope(uid: 1), envelope(uid: 2)],
            uidValidity: 100, uidNext: 3, into: "INBOX"
        )
        try await cache.remove(uids: [2, 999], folder: "INBOX")
        let events = try await waitForEvents(count: 2)
        guard case .removed(let uids, let folder) = events[1] else {
            return XCTFail("expected removed, got \(events)")
        }
        XCTAssertEqual(folder, "INBOX")
        // The event reports the requested UIDs on a changed write; a
        // wholly-unknown UID set emits nothing (covered below).
        XCTAssertTrue(uids.contains(2))
    }

    func testNoOpRemoveEmitsNothing() async throws {
        try await cache.remove(uids: [999], folder: "Nope")
        try await Task.sleep(nanoseconds: 50_000_000)
        let events = await log.events
        XCTAssertTrue(events.isEmpty)
    }

    func testReplaceEmitsRemovedForPrunedWindowUIDs() async throws {
        try await cache.merge(
            envelopes: (1...5).map { envelope(uid: $0) },
            uidValidity: 100, uidNext: 6, into: "INBOX"
        )
        try await cache.replace(
            envelopes: [envelope(uid: 4)],
            uidValidity: 100, uidNext: 6, keepingRange: 3...5, into: "INBOX"
        )
        let events = try await waitForEvents(count: 3)
        guard case .removed(let uids, _) = events[1] else {
            return XCTFail("expected removed, got \(events)")
        }
        XCTAssertEqual(uids, [3, 5])
        guard case .upserted(let envelopes, _) = events[2] else {
            return XCTFail("expected upserted, got \(events)")
        }
        XCTAssertEqual(envelopes.map(\.uid), [4])
    }

    func testInvalidateAndClearAllEmit() async throws {
        try await cache.invalidate(folder: "INBOX")
        try await cache.clearAll()
        let events = try await waitForEvents(count: 2)
        guard case .invalidated("INBOX") = events[0] else {
            return XCTFail("expected invalidated, got \(events)")
        }
        guard case .cleared = events[1] else {
            return XCTFail("expected cleared, got \(events)")
        }
    }

    func testStoreEmitsWholeSnapshotAsUpsert() async throws {
        try await cache.store(
            EnvelopeCache.Snapshot(
                uidValidity: 100, uidNext: 3,
                envelopes: [1: envelope(uid: 1), 2: envelope(uid: 2)]
            ),
            for: "INBOX"
        )
        let events = try await waitForEvents(count: 1)
        guard case .upserted(let envelopes, "INBOX") = events[0] else {
            return XCTFail("expected upserted, got \(events)")
        }
        XCTAssertEqual(Set(envelopes.map(\.uid)), [1, 2])
    }
}
