import XCTest
@testable import CabalmailKit

/// Custom flags on feed items in `RssStore`: what an item carries, the queue
/// of changes to them (one per item and slot, the latest), and what the
/// server reports laid under the changes still queued.
final class RssStoreFlagsTests: XCTestCase {
    private var tempDir: URL!
    private var store: RssStore!

    private let slot3 = "cabal-flag-03"
    private let slot5 = "cabal-flag-05"
    private let slot7 = "cabal-flag-07"

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-flags-\(UUID().uuidString)")
        store = try RssStore(directory: tempDir)
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s1", feedId: "f1"))
        try await store.upsertItems([item("a"), item("b")])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ key: String, flags: Set<String> = []) -> RssItem {
        RssItem(feedId: "f1", itemId: key, sortKey: key, publishedAt: "2026-01-02T00:00:00Z", flags: flags)
    }

    private func flags(of key: String) async throws -> Set<String>? {
        try await store.item(feedId: "f1", sortKey: key)?.flags
    }

    /// The queued flag changes, as "item slot +" for an add and "-" for a
    /// remove, in queue order.
    private func queuedFlagChanges() async throws -> [String] {
        try await store.pendingMutations().filter { $0.kind == .flag }
            .map { "\($0.sortKey) \($0.slot) \($0.value ? "+" : "-")" }
    }

    // MARK: - What an item carries

    func testAnItemsFlagsComeBackFromTheStore() async throws {
        try await store.upsertItems([item("a", flags: [slot5, slot3])])

        let one = try await flags(of: "a")
        XCTAssertEqual(one, [slot3, slot5])
        let listed = try await store.items(.init(scope: .all, ordering: .oldestFirst)).map(\.flags)
        XCTAssertEqual(listed, [[slot3, slot5], []])
    }

    func testSettingAFlagShowsItAndQueuesItsSlot() async throws {
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)

        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [slot3])
        let queued = try await store.pendingMutations()
        XCTAssertEqual(queued.map(\.kind), [.flag])
        XCTAssertEqual(queued.map(\.slot), [slot3])
        XCTAssertEqual(queued.map(\.value), [true])
        let marked = try await store.hasPending(feedId: "f1", sortKey: "a")
        XCTAssertTrue(marked, "the row shows its queued mark")
    }

    func testOnlyAPaletteSlotCanBeQueued() async throws {
        for notASlot in [FlagPalette.systemSlot, "cabal-flag-00", "cabal-flag-21", "cabal-flag-3", "later"] {
            do {
                try await store.setFlag(feedId: "f1", sortKey: "a", slot: notASlot, true)
                XCTFail("\(notASlot) is not a slot the server takes")
            } catch {}
        }

        let queued = try await store.pendingCount()
        XCTAssertEqual(queued, 0, "the server refuses such a change every time, so it must never be queued")
        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [])
    }

    // MARK: - Coalescing

    /// The latest intent for an item and slot is the one queued. An add and
    /// then a remove leaves the remove, not nothing: only the server knows
    /// whether it holds the flag.
    func testTheLatestChangeToOneItemAndSlotIsTheOneQueued() async throws {
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, false)

        var queued = try await queuedFlagChanges()
        XCTAssertEqual(queued, ["a \(slot3) -"])
        var shown = try await flags(of: "a")
        XCTAssertEqual(shown, [])

        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)

        queued = try await queuedFlagChanges()
        XCTAssertEqual(queued, ["a \(slot3) +"])
        shown = try await flags(of: "a")
        XCTAssertEqual(shown, [slot3])
    }

    /// A change to one flag leaves the queued changes to the item's other
    /// flags, to its read and favorite marks, and to other items alone.
    func testAChangeReplacesOnlyTheSameItemAndSlot() async throws {
        try await store.setRead(feedId: "f1", sortKey: "a", true)
        try await store.setFavorite(feedId: "f1", sortKey: "a", true)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot5, true)
        try await store.setFlag(feedId: "f1", sortKey: "b", slot: slot3, true)

        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, false)

        let queued = try await store.pendingMutations()
        XCTAssertEqual(queued.map { "\($0.kind.rawValue) \($0.sortKey) \($0.slot) \($0.value)" }, [
            "read a  true", "favorite a  true",
            "flag a \(slot5) true", "flag b \(slot3) true", "flag a \(slot3) false",
        ])
        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [slot5])
        let other = try await flags(of: "b")
        XCTAssertEqual(other, [slot3])
    }

    // MARK: - One transaction with the queue row

    func testAFlagWithNoQueueRowIsNotShown() async throws {
        try await store.execForTests("""
            CREATE TRIGGER refuse_push BEFORE INSERT ON pending
            BEGIN SELECT RAISE(ABORT, 'database is full'); END
            """)

        do {
            try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
            XCTFail("the refused push should fail the change")
        } catch {}

        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [], "no local flag without its push")
        let queued = try await store.pendingCount()
        XCTAssertEqual(queued, 0)
    }

    // MARK: - What the server reports

    /// A slot with a queued change stays as that change left it; every
    /// other slot is the server's, set or cleared.
    func testServerStatesNeverOverwriteAQueuedSlot() async throws {
        try await store.upsertItems([item("a", flags: [slot5, slot7])])
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot5, false)

        // The server has not seen either change: no slot 3, slot 5 still set.
        // Another device cleared slot 7 and set slot 9.
        try await store.applyServerStates([
            RssItemState(feedId: "f1", sortKey: "a", flags: [slot5, "cabal-flag-09"]),
        ])

        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [slot3, "cabal-flag-09"],
                       "the queued add stays, the queued remove stays removed, and the rest is the server's")
    }

    func testOnceAChangeIsSentTheServersWordStandsForItsSlot() async throws {
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        let ids = try await store.pendingMutations().map(\.id)
        try await store.deletePending(ids: ids)

        try await store.applyServerStates([RssItemState(feedId: "f1", sortKey: "a", flags: [])])

        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [], "nothing is queued, so the server's state is the item's")
    }

    /// The same rule when the item itself is listed again.
    func testAListedItemKeepsOnlyItsQueuedSlots() async throws {
        try await store.upsertItems([item("a", flags: [slot5, slot7]), item("b", flags: [slot7])])
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot5, false)

        try await store.upsertItems([item("a", flags: [slot5]), item("b", flags: [])])

        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [slot3], "slot 7 went with the server; the two queued slots are the device's")
        let other = try await flags(of: "b")
        XCTAssertEqual(other, [], "an item with nothing queued takes the server's flags whole")
    }

    // MARK: - A refused add

    func testDroppingARefusedAddTakesTheFlagOffAndLeavesTheRest() async throws {
        try await store.setRead(feedId: "f1", sortKey: "a", true)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot5, true)
        try await store.setFlag(feedId: "f1", sortKey: "b", slot: slot5, false)
        let rows = try await store.pendingMutations()

        // Every row is offered; only an add is one the server can refuse.
        let dropped = try await store.dropRefusedFlagAdds(ids: rows.filter { $0.slot == slot5 }.map(\.id))

        XCTAssertEqual(dropped, 1)
        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [slot3], "the refused flag is off the item; nothing would ever send it")
        let left = try await store.pendingMutations().map { "\($0.kind.rawValue) \($0.sortKey) \($0.slot)" }
        XCTAssertEqual(left, ["read a ", "flag a \(slot3)", "flag b \(slot5)"],
                       "the read mark, the other add and the remove are still queued")
    }

    /// The drain read the queue, and the user changed their mind before the
    /// server answered: that newer change replaced the row, and it stands.
    func testARowReplacedSinceTheDrainReadItIsNotDropped() async throws {
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)
        let read = try await store.pendingMutations().map(\.id)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, false)
        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)

        let dropped = try await store.dropRefusedFlagAdds(ids: read)

        XCTAssertEqual(dropped, 0)
        let shown = try await flags(of: "a")
        XCTAssertEqual(shown, [slot3])
        let queued = try await queuedFlagChanges()
        XCTAssertEqual(queued, ["a \(slot3) +"])
    }

    // MARK: - Announced

    func testAFlagChangeIsAnnouncedForItsItem() async throws {
        var changes = await store.changes().makeAsyncIterator()

        try await store.setFlag(feedId: "f1", sortKey: "a", slot: slot3, true)

        let announced = await changes.next()
        XCTAssertEqual(announced, .items(["f1#a"]))
    }
}

private extension RssStore {
    /// Raw SQL against the store's file, for setting up a failure.
    func execForTests(_ sql: String) throws {
        try database.exec(sql)
    }
}
