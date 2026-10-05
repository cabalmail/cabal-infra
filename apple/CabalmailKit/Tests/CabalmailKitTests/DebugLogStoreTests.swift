import XCTest
@testable import CabalmailKit

final class DebugLogStoreTests: XCTestCase {
    func testAppendRespectsCapacity() {
        let store = DebugLogStore(capacity: 3)
        for index in 0..<5 {
            store.append(DebugLogStore.Entry(
                level: .info, category: "test", message: "line \(index)"
            ))
        }
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot.map(\.message), ["line 2", "line 3", "line 4"])
    }

    /// The ring overwrites in place once full; the snapshot still reads
    /// oldest first across the wrap, and again after a clear.
    func testSnapshotStaysOldestFirstAcrossTheWrap() {
        let store = DebugLogStore(capacity: 4)
        for index in 0..<11 {
            store.log(.info, "ring", "line \(index)")
        }
        XCTAssertEqual(store.snapshot().map(\.message), ["line 7", "line 8", "line 9", "line 10"])

        store.clear()
        store.log(.info, "ring", "after")
        XCTAssertEqual(store.snapshot().map(\.message), ["after"])
    }

    func testZeroCapacityKeepsNothing() {
        let store = DebugLogStore(capacity: 0)
        store.log(.info, "ring", "dropped")
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testNewEntriesStreamsAppends() async {
        let store = DebugLogStore(capacity: 10)
        let stream = store.newEntries()
        let received = Task { () -> [String] in
            var collected: [String] = []
            for await entry in stream {
                collected.append(entry.message)
                if collected.count == 2 { break }
            }
            return collected
        }
        // `newEntries` registers before it returns, so nothing logged from
        // here on can miss the subscriber.
        store.log(.info, "cat", "one")
        store.log(.warn, "cat", "two")
        let collected = await received.value
        XCTAssertEqual(collected, ["one", "two"])
    }

    /// Writers on many threads at once: every line lands, each writer's lines
    /// keep their own order, and a subscriber sees exactly the buffer's order.
    func testConcurrentWritersKeepTheirOrderAndSubscribersMatchTheBuffer() async {
        let writers = 8
        let linesEach = 50
        let store = DebugLogStore(capacity: writers * linesEach)
        let stream = store.newEntries()
        let streamed = Task { () -> [String] in
            var collected: [String] = []
            for await entry in stream {
                collected.append(entry.message)
                if collected.count == writers * linesEach { break }
            }
            return collected
        }

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    for line in 0..<linesEach {
                        store.log(.info, "w\(writer)", "\(writer):\(line)")
                    }
                }
            }
        }

        let buffered = store.snapshot().map(\.message)
        XCTAssertEqual(buffered.count, writers * linesEach)
        for writer in 0..<writers {
            let own = buffered.filter { $0.hasPrefix("\(writer):") }
            XCTAssertEqual(own, (0..<linesEach).map { "\(writer):\($0)" }, "writer \(writer)'s lines reordered")
        }
        let delivered = await streamed.value
        XCTAssertEqual(delivered, buffered, "the subscriber saw a different order from the buffer")
    }

    /// #1761, the same shape as `MailboxWatcherTests`' leak case: the store
    /// keeps every subscriber's continuation, each continuation stores the
    /// termination handler, and that handler used to hold the store strongly
    /// — the `[weak self]` sat on the `Task` nested inside it, which needs a
    /// strong `self` in the handler to be formed at all.
    func testStoreDeallocatesWhileASubscriberStillHoldsTheStream() async throws {
        var store: DebugLogStore? = DebugLogStore(capacity: 4)
        weak let leaked: DebugLogStore? = store
        let stream = store!.newEntries()
        store = nil

        var released = false
        for _ in 0..<200 {
            if leaked == nil {
                released = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(
            released,
            "the store outlived its last owner: a subscriber's termination handler is holding it (#1761)"
        )
        withExtendedLifetime(stream) {}
    }

    /// Releasing the store finishes its live streams, so a Debug Log view
    /// tailing a store that went away stops instead of waiting forever.
    func testReleasingTheStoreFinishesItsStreams() async {
        var store: DebugLogStore? = DebugLogStore(capacity: 4)
        let stream = store!.newEntries()
        store = nil
        let finished = await finishesWithoutCancelling(stream)
        XCTAssertTrue(finished, "the stream outlived its store")
    }

    func testClearEmptiesBuffer() {
        let store = DebugLogStore(capacity: 10)
        store.log(.info, "cat", "one")
        store.clear()
        XCTAssertTrue(store.snapshot().isEmpty)
    }
}
