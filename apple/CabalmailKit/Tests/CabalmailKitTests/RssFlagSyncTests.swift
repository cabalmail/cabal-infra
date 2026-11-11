import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// Custom flags on feed items through `RssSyncEngine` and its pending queue,
/// against a `FakeRssClient` that holds the caller's state rows as the
/// server does: two devices changing different flags of one item, a drain's
/// batches, and an add the server refuses.
final class RssFlagSyncTests: XCTestCase {
    /// One device: its own store and engine on the shared server.
    private struct Device {
        let store: RssStore
        let engine: RssSyncEngine
    }

    private var tempDir: URL!
    private var client: FakeRssClient!
    private var phone: Device!
    private var mac: Device!

    private let slot3 = "cabal-flag-03"
    private let slot5 = "cabal-flag-05"
    private let slot7 = "cabal-flag-07"
    private let subscription = RssSubscription(subscriptionId: "s1", feedId: "f1", dataStoreUuid: "ds1",
                                               feed: RssFeedSummary(feedId: "f1", title: "F1"))

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-flag-sync-\(UUID().uuidString)")
        client = FakeRssClient()
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        await client.set(emptyPagesByDefault: true)
        await client.set(servesStates: true)
        phone = try await device("phone")
        mac = try await device("mac")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func device(_ name: String) async throws -> Device {
        let store = try RssStore(directory: tempDir.appendingPathComponent(name))
        try await store.upsertSubscription(subscription)
        try await store.upsertItems((1...3).map { item($0) })
        return Device(store: store, engine: RssSyncEngine(client: client, store: store))
    }

    private func item(_ number: Int, flags: Set<String> = []) -> RssItem {
        RssItem(feedId: "f1", itemId: "i\(number)", sortKey: key(number),
                publishedAt: "2026-01-02T00:00:00+00:00", flags: flags)
    }

    private func key(_ number: Int) -> String { String(format: "2026-01-02T00:00:00+00:00#i%03d", number) }

    private func flags(of number: Int, on device: Device) async throws -> Set<String>? {
        try await device.store.item(feedId: "f1", sortKey: key(number))?.flags
    }

    /// A change made with no connection: in the store and its queue, not sent.
    private func offline(_ device: Device, item number: Int, _ slot: String, _ isSet: Bool) async throws {
        try await device.store.setFlag(feedId: "f1", sortKey: key(number), slot: slot, isSet)
    }

    // MARK: - Two devices

    /// Each device sends only the slot it changed, so neither replaces what
    /// the other set, and each then learns the other's from the state sync.
    func testTwoDevicesChangingDifferentFlagsOfOneItemBothTakeEffect() async throws {
        try await offline(phone, item: 1, slot3, true)
        try await offline(mac, item: 1, slot5, true)

        try await phone.engine.drainPending()
        try await mac.engine.drainPending()

        var calls = await client.stateCalls
        XCTAssertEqual(calls.map { $0.map(\.addFlags) }, [[[slot3]], [[slot5]]], "each call adds its own slot only")
        XCTAssertEqual(calls.map { $0.map(\.removeFlags) }, [[[]], [[]]])
        var held = await client.serverStates["f1#\(key(1))"]?.flags
        XCTAssertEqual(held, [slot3, slot5])

        try await phone.engine.syncItems(for: subscription)
        try await mac.engine.syncItems(for: subscription)

        var onPhone = try await flags(of: 1, on: phone)
        var onMac = try await flags(of: 1, on: mac)
        XCTAssertEqual(onPhone, [slot3, slot5])
        XCTAssertEqual(onMac, [slot3, slot5])

        // And apart again: one removes a flag while the other adds a third.
        try await offline(phone, item: 1, slot3, false)
        try await offline(mac, item: 1, slot7, true)
        try await phone.engine.drainPending()
        try await mac.engine.drainPending()
        calls = await client.stateCalls
        XCTAssertEqual(calls.suffix(2).map { $0.map(\.removeFlags) }, [[[slot3]], [[]]])
        held = await client.serverStates["f1#\(key(1))"]?.flags
        XCTAssertEqual(held, [slot5, slot7])

        try await phone.engine.syncItems(for: subscription)
        try await mac.engine.syncItems(for: subscription)
        onPhone = try await flags(of: 1, on: phone)
        onMac = try await flags(of: 1, on: mac)
        XCTAssertEqual(onPhone, [slot5, slot7])
        XCTAssertEqual(onMac, [slot5, slot7])
    }

    /// A device that hears from the server before it has sent its own
    /// change keeps that change and gains the other device's.
    func testAStateSyncAheadOfTheDrainKeepsTheQueuedFlag() async throws {
        try await offline(phone, item: 1, slot3, true)
        try await phone.engine.drainPending()
        try await offline(mac, item: 1, slot5, true)

        try await mac.engine.syncItems(for: subscription)

        var onMac = try await flags(of: 1, on: mac)
        XCTAssertEqual(onMac, [slot3, slot5], "the server's slot 3 arrived and the queued slot 5 stayed")
        let stillQueued = try await mac.store.pendingMutations().map(\.slot)
        XCTAssertEqual(stillQueued, [slot5])

        try await mac.engine.drainPending()
        try await mac.engine.syncItems(for: subscription)
        try await phone.engine.syncItems(for: subscription)

        onMac = try await flags(of: 1, on: mac)
        let onPhone = try await flags(of: 1, on: phone)
        XCTAssertEqual(onMac, [slot3, slot5])
        XCTAssertEqual(onPhone, [slot3, slot5])
    }

    func testSettingAFlagThroughTheEngineSendsIt() async throws {
        try await phone.engine.setFlag(item(2), slot: slot3, true)

        let calls = await client.stateCalls
        XCTAssertEqual(calls.map { $0.map(\.addFlags) }, [[[slot3]]])
        let queued = try await phone.store.pendingCount()
        XCTAssertEqual(queued, 0)
        let shown = try await flags(of: 2, on: phone)
        XCTAssertEqual(shown, [slot3])
    }

    // MARK: - Batches

    /// The server takes at most 100 items a call. A flag change joins its
    /// item's entry, so the limit counts items however many rows they have.
    func testADrainSendsAtMostAHundredItemsACall() async throws {
        try await phone.store.upsertItems((1...150).map { item($0, flags: [slot5]) })
        for number in 1...150 {
            try await offline(phone, item: number, slot3, true)
            if number <= 30 {
                try await phone.store.setRead(feedId: "f1", sortKey: key(number), true)
                try await offline(phone, item: number, slot5, false)
            }
        }

        let cleared = try await phone.engine.drainPending()

        XCTAssertEqual(cleared, 210, "150 adds, 30 read marks and 30 removes left the queue")
        let calls = await client.stateCalls
        XCTAssertEqual(calls.map(\.count), [100, 50])
        let entries = calls.flatMap { $0 }
        XCTAssertEqual(Set(entries.map(\.sortKey)).count, 150, "one entry an item")
        XCTAssertTrue(entries.allSatisfy { $0.addFlags == [slot3] })
        XCTAssertEqual(entries.filter { $0.removeFlags == [slot5] && $0.isRead == true }.count, 30,
                       "an item's read mark and both its flag changes ride one entry")
        let queued = try await phone.store.pendingCount()
        XCTAssertEqual(queued, 0)
    }

    // MARK: - A refused add

    /// The flag was disabled or deleted on another device after the change
    /// was queued. The server refuses the whole call for it, every time, so
    /// keeping it would hold every other change behind it for good.
    func testAnAddTheServerRefusesIsDroppedAndTheRestOfTheBatchGoes() async throws {
        await client.set(enabledSlots: [slot3])
        try await phone.store.upsertItems([item(3, flags: [slot5])])
        try await phone.store.setRead(feedId: "f1", sortKey: key(1), true)
        try await offline(phone, item: 1, slot5, true)
        try await offline(phone, item: 2, slot3, true)
        try await offline(phone, item: 3, slot5, false)

        let cleared = try await phone.engine.drainPending()

        XCTAssertEqual(cleared, 4, "the refused add left the queue with the three that were sent")
        let refused = await client.refusedStateCalls
        XCTAssertEqual(refused.count, 1, "the first attempt carried the add and was refused whole")
        let calls = await client.stateCalls
        XCTAssertEqual(calls.count, 1)
        let sent = try XCTUnwrap(calls.first)
        XCTAssertEqual(sent.map(\.sortKey), [key(1), key(2), key(3)])
        XCTAssertEqual(sent.map(\.isRead), [true, nil, nil], "the item's read mark still went")
        XCTAssertEqual(sent.map(\.addFlags), [[], [slot3], []])
        XCTAssertEqual(sent.map(\.removeFlags), [[], [], [slot5]], "removing needs no palette entry")
        let queued = try await phone.store.pendingCount()
        XCTAssertEqual(queued, 0)
        let undone = try await flags(of: 1, on: phone)
        XCTAssertEqual(undone, [], "the flag nothing will send is off the item")
        let kept = try await flags(of: 2, on: phone)
        XCTAssertEqual(kept, [slot3])

        // The queue is not stuck: a later change goes.
        try await offline(phone, item: 2, slot3, false)
        let later = try await phone.engine.drainPending()
        XCTAssertEqual(later, 1)
    }

    /// A refusal for slots the batch does not add is not one that dropping
    /// a row can answer. The queue stays, as after any failure.
    func testARefusalThatNamesNoAddInTheBatchLeavesTheQueue() async throws {
        try await offline(phone, item: 1, slot3, true)
        await client.set(nextStateRefusal: RssFlagRefusal(slots: ["cabal-flag-09"], message: "Not enabled."))

        do {
            try await phone.engine.drainPending()
            XCTFail("the refusal should fail the drain")
        } catch {
            XCTAssertEqual(error as? CabalmailError,
                           .server(code: "flag_not_in_palette", message: "Not enabled."))
        }

        let queued = try await phone.store.pendingMutations().map(\.slot)
        XCTAssertEqual(queued, [slot3])
        let shown = try await flags(of: 1, on: phone)
        XCTAssertEqual(shown, [slot3])
        let retried = try await phone.engine.drainPending()
        XCTAssertEqual(retried, 1, "the next attempt sends it")
    }

    /// The user removes the flag again while the add is on its way to being
    /// refused. The refusal is about a row that is gone; the remove stands
    /// and goes with the next pass.
    func testAChangeMadeWhileTheRefusalWasOnItsWayStands() async throws {
        let (client, engine) = (self.client!, phone.engine)
        await client.set(enabledSlots: [])
        try await phone.store.upsertItems([item(1, flags: [slot3])])
        try await offline(phone, item: 1, slot3, true)
        await client.holdNext(.push)
        let draining = Task { try await engine.drainPending() }
        try await waitUntil { await client.isHolding(.push) }

        try await offline(phone, item: 1, slot3, false)
        await client.release(.push)
        let cleared = try await draining.value

        XCTAssertEqual(cleared, 0, "nothing this pass read is still in the queue to drop")
        let queued = try await phone.store.pendingMutations().map { "\($0.slot) \($0.value)" }
        XCTAssertEqual(queued, ["\(slot3) false"])
        let later = try await phone.engine.drainPending()
        XCTAssertEqual(later, 1)
        let sent = await client.stateCalls.last?.map(\.removeFlags)
        XCTAssertEqual(sent, [[slot3]])
    }
}
