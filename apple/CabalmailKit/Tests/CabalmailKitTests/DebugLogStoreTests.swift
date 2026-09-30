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

    /// #1761, the same shape as `MailboxWatcherTests`' leak case: the store
    /// keeps every subscriber's continuation, each continuation stores the
    /// termination handler, and that handler used to hold the store strongly
    /// — the `[weak self]` sat on the `Task` nested inside it, which needs a
    /// strong `self` in the handler to be formed at all.
    func testStoreDeallocatesWhileASubscriberStillHoldsTheStream() async throws {
        var store: DebugLogStore? = DebugLogStore(capacity: 4)
        weak var leaked: DebugLogStore? = store
        let stream = await store!.newEntries()
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

    func testClearEmptiesBuffer() async {
        let store = DebugLogStore(capacity: 10)
        await store.log(.info, "cat", "one")
        await store.clear()
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }
}
