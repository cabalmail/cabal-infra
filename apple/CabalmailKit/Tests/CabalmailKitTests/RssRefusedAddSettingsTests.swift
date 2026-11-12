import XCTest
import CabalmailKitTestSupport
@testable import CabalmailKit

/// A flag add the server refuses while the app holds a settings change it
/// has not managed to send (#2421): `RssPendingDrain` asks for that push
/// (`RssSyncEngine.setUnsentSettingsPush`) before it drops anything, and
/// what the app answers decides whether the add goes again, waits, or is
/// dropped as for a deleted flag (`RssFlagSyncTests` has the drop with no
/// one to ask). Against `FakeRssClient`, whose palette check is the server's.
final class RssRefusedAddSettingsTests: XCTestCase {
    private struct Device {
        let store: RssStore
        let engine: RssSyncEngine
    }

    private var tempDir: URL!
    private var client: FakeRssClient!
    private var phone: Device!

    private let slot5 = "cabal-flag-05"
    private let subscription = RssSubscription(subscriptionId: "s1", feedId: "f1", dataStoreUuid: "ds1",
                                               feed: RssFeedSummary(feedId: "f1", title: "F1"))

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cabalmail-rss-refused-add-\(UUID().uuidString)")
        client = FakeRssClient()
        await client.set(catalog: RssCatalog(folders: [], subscriptions: [subscription]))
        await client.set(emptyPagesByDefault: true)
        await client.set(servesStates: true)
        let store = try RssStore(directory: tempDir.appendingPathComponent("phone"))
        try await store.upsertSubscription(subscription)
        try await store.upsertItems((1...2).map { item($0) })
        phone = Device(store: store, engine: RssSyncEngine(client: client, store: store))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func item(_ number: Int) -> RssItem {
        RssItem(feedId: "f1", itemId: "i\(number)", sortKey: key(number), publishedAt: "2026-01-02T00:00:00+00:00")
    }

    private func key(_ number: Int) -> String { String(format: "2026-01-02T00:00:00+00:00#i%03d", number) }

    private func flags(of number: Int, on device: Device) async throws -> Set<String>? {
        try await device.store.item(feedId: "f1", sortKey: key(number))?.flags
    }

    /// A change made with no connection: in the store and its queue, not sent.
    private func offline(_ device: Device, item number: Int, _ slot: String, _ isSet: Bool) async throws {
        try await device.store.setFlag(feedId: "f1", sortKey: key(number), slot: slot, isSet)
    }

    /// The flag was created on this device while its settings push was
    /// failing, then put on an item. The server has not been told of the
    /// flag, so it refuses the add; the drain asks for the settings, they
    /// go, and the add goes again and is taken.
    func testARefusedAddGoesAgainOnceTheSettingsThatCarryItsFlagAreSent() async throws {
        let (client, asks, slot5) = (self.client!, AskLog(), self.slot5)
        await client.set(paletteSlots: [])
        phone.engine.setUnsentSettingsPush {
            await asks.bump()
            // The settings push carries the new flag: the server's palette
            // now lists it.
            await client.set(paletteSlots: [slot5])
            return .sent
        }
        try await offline(phone, item: 1, slot5, true)
        try await phone.store.setRead(feedId: "f1", sortKey: key(2), true)

        let cleared = try await phone.engine.drainPending()

        XCTAssertEqual(cleared, 2, "the add and the read mark both left the queue, sent")
        let asked = await asks.count
        XCTAssertEqual(asked, 1)
        let refused = await client.refusedStateCalls.count
        XCTAssertEqual(refused, 1, "the first call, before the settings went, was refused")
        let sent = await client.stateCalls
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.map(\.addFlags), [[slot5], []], "the add went with the batch it was in")
        let kept = try await flags(of: 1, on: phone)
        XCTAssertEqual(kept, [slot5], "the item keeps its flag")
        let queued = try await phone.store.pendingCount()
        XCTAssertEqual(queued, 0)
    }

    /// The settings still cannot be sent, so the server may not know the
    /// flag yet. The add waits in the queue, on its item, and the rest of
    /// the batch goes; once the settings go, so does the add.
    func testARefusedAddWaitsWhileTheSettingsCannotBeSent() async throws {
        let (client, asks, slot5) = (self.client!, AskLog(), self.slot5)
        await client.set(paletteSlots: [])
        phone.engine.setUnsentSettingsPush {
            await asks.bump()
            return .stillUnsent
        }
        try await offline(phone, item: 1, slot5, true)
        try await phone.store.setRead(feedId: "f1", sortKey: key(2), true)

        let cleared = try await phone.engine.drainPending()

        XCTAssertEqual(cleared, 1, "only the read mark left the queue")
        let sent = await client.stateCalls
        XCTAssertEqual(sent.map { $0.map(\.sortKey) }, [[key(2)]], "the rest of the batch went without the add")
        let waiting = try await phone.store.pendingMutations().map { "\($0.sortKey) \($0.slot) \($0.value)" }
        XCTAssertEqual(waiting, ["\(key(1)) \(slot5) true"])
        let shown = try await flags(of: 1, on: phone)
        XCTAssertEqual(shown, [slot5], "the item still shows the flag")

        phone.engine.setUnsentSettingsPush {
            await asks.bump()
            await client.set(paletteSlots: [slot5])
            return .sent
        }
        let later = try await phone.engine.drainPending()

        XCTAssertEqual(later, 1, "the add went once the settings had")
        let added = await client.stateCalls.last?.map(\.addFlags)
        XCTAssertEqual(added, [[slot5]])
        let kept = try await flags(of: 1, on: phone)
        XCTAssertEqual(kept, [slot5])
        let asked = await asks.count
        XCTAssertEqual(asked, 2, "asked once a drain")
    }

    /// Nothing unsent: the server's palette is this device's, so the flag
    /// was deleted, and the add is dropped as before (2026-11-11).
    func testWithNothingUnsentARefusedAddIsStillDropped() async throws {
        let (client, asks) = (self.client!, AskLog())
        await client.set(paletteSlots: [])
        phone.engine.setUnsentSettingsPush {
            await asks.bump()
            return .nothingUnsent
        }
        try await offline(phone, item: 1, slot5, true)

        let cleared = try await phone.engine.drainPending()

        XCTAssertEqual(cleared, 1, "the refused add was dropped")
        let asked = await asks.count
        XCTAssertEqual(asked, 1)
        let undone = try await flags(of: 1, on: phone)
        XCTAssertEqual(undone, [])
        let queued = try await phone.store.pendingCount()
        XCTAssertEqual(queued, 0)
    }

    /// The settings went, but without the flag: it was deleted after all.
    /// The second refusal is final, and the drain does not ask again,
    /// which would loop for as long as each answer said sent.
    func testARefusalAfterTheSettingsWentIsFinal() async throws {
        let (client, asks) = (self.client!, AskLog())
        await client.set(paletteSlots: [])
        phone.engine.setUnsentSettingsPush {
            await asks.bump()
            return .sent
        }
        try await offline(phone, item: 1, slot5, true)

        let cleared = try await phone.engine.drainPending()

        XCTAssertEqual(cleared, 1, "the add was dropped after the second refusal")
        let refused = await client.refusedStateCalls.count
        XCTAssertEqual(refused, 2)
        let asked = await asks.count
        XCTAssertEqual(asked, 1)
        let undone = try await flags(of: 1, on: phone)
        XCTAssertEqual(undone, [])
    }
}

/// How often the drain asked for the app's unsent settings.
private actor AskLog {
    private(set) var count = 0
    func bump() { count += 1 }
}
