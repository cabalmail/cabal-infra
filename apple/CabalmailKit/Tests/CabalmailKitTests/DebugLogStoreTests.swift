import XCTest
@testable import CabalmailKit

final class DebugLogStoreTests: XCTestCase {
    func testAppendRespectsCapacity() async {
        let store = DebugLogStore(capacity: 3)
        for index in 0..<5 {
            await store.append(DebugLogStore.Entry(
                level: .info, category: "test", message: "line \(index)"
            ))
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot.map(\.message), ["line 2", "line 3", "line 4"])
    }

    func testNewEntriesStreamsAppends() async throws {
        let store = DebugLogStore(capacity: 10)
        let stream = await store.newEntries()
        let received = Task { () -> [String] in
            var collected: [String] = []
            for await entry in stream {
                collected.append(entry.message)
                if collected.count == 2 { break }
            }
            return collected
        }
        // Small async yield so the subscription is in place before we
        // fire writes. Without this the continuation setup can race the
        // first `append` and drop it.
        try await Task.sleep(nanoseconds: 10_000_000)
        await store.log(.info, "cat", "one")
        await store.log(.warn, "cat", "two")
        let collected = await received.value
        XCTAssertEqual(collected, ["one", "two"])
    }

    func testClearEmptiesBuffer() async {
        let store = DebugLogStore(capacity: 10)
        await store.log(.info, "cat", "one")
        await store.clear()
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }
}
