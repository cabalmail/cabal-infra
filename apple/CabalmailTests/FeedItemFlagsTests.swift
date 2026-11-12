import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Custom flags on feed items (cross-media plan, Phase 2): the reader's and
/// the list's flag controls write any palette flag through the sync engine,
/// the one-press controls act on the default flag, and both views follow
/// the store for flags as they do for read state, a flag the server refused
/// included. Every write is asserted through the real store, since the fake
/// client records none.
@MainActor
final class FeedItemFlagsTests: XCTestCase {
    private let later = "cabal-flag-03"
    private let waiting = "cabal-flag-05"
    private var directory: URL!
    private var store: RssStore!
    private var client: FakeRssClient!
    private var followers: [Task<Void, Never>] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-item-flags-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        client = FakeRssClient()
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: .all))
        try await store.upsertItems([item("k1"), item("k2")])
    }

    override func tearDown() async throws {
        followers.forEach { $0.cancel() }
        followers = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ sortKey: String) -> RssItem {
        RssItem(feedId: "f", subscriptionId: "s", itemId: sortKey, sortKey: sortKey, title: sortKey,
                publishedAt: "2026-01-01T00:00:00Z")
    }

    private func entry(_ slot: String, _ label: String) -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: "blue")
    }

    /// Two flags of the user's own. The built-in flag leads, so it is the
    /// default, unless `laterIsDefault` stores the palette with Later first.
    private func preferences(laterIsDefault: Bool = false, custom: Bool = true) -> Preferences {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        guard custom else { return preferences }
        let own = [entry(later, "Later"), entry(waiting, "Waiting")]
        preferences.flagPalette = laterIsDefault ? own + [FlagPalette.defaultSystemEntry] : own
        return preferences
    }

    private func engine() -> RssSyncEngine { RssSyncEngine(client: client, store: store) }

    private func reader(_ preferences: Preferences, on sortKey: String = "k1") -> FeedItemDetailViewModel {
        FeedItemDetailViewModel(item: item(sortKey), subscription: nil, engine: engine(), preferences: preferences)
    }

    private func list(_ preferences: Preferences) throws -> FeedItemListViewModel {
        FeedItemListViewModel(
            scope: .subscription("s"), subscription: RssSubscription(subscriptionId: "s", feedId: "f"),
            client: try TestFixtures.makeClient(imap: FakeImapClient()), preferences: preferences,
            store: store, engine: engine()
        )
    }

    private func stored(_ sortKey: String = "k1") async throws -> RssItem {
        let held = try await store.item(feedId: "f", sortKey: sortKey)
        return try XCTUnwrap(held)
    }

    private func follow(_ observe: @escaping @MainActor () async -> Void) {
        followers.append(Task { await observe() })
    }

    /// Leaves every pushed change in the queue, as a device with no
    /// connection does.
    private func goOffline() async {
        await client.set(pushError: CabalmailError.server(code: "offline", message: "no connection"))
    }

    // MARK: - The reader's flag menu

    func testAMenuRowSetsACustomFlagAndASecondPickClearsIt() async throws {
        let reader = reader(preferences())

        await reader.toggleFlag(slot: later)

        XCTAssertEqual(reader.item.flags, [later], "the reader shows it at once")
        var held = try await stored()
        XCTAssertEqual(held.flags, [later])
        XCTAssertFalse(held.isFavorite, "a flag of the user's own is not the built-in flag")

        await reader.toggleFlag(slot: later)

        XCTAssertEqual(reader.item.flags, [])
        held = try await stored()
        XCTAssertEqual(held.flags, [])
    }

    func testTheBuiltInFlagsRowWritesTheFavoriteBit() async throws {
        let reader = reader(preferences())

        await reader.toggleFlag(slot: FlagPalette.systemSlot)

        XCTAssertTrue(reader.item.isFavorite)
        let held = try await stored()
        XCTAssertTrue(held.isFavorite)
        XCTAssertEqual(held.flags, [], "the built-in flag is never stored as a slot")
    }

    func testACustomFlagSetOfflineIsQueuedForItsSlot() async throws {
        await goOffline()
        let reader = reader(preferences())

        await reader.toggleFlag(slot: waiting)

        let queue = try await store.pendingMutations()
        XCTAssertEqual(queue.map(\.kind), [.flag])
        XCTAssertEqual(queue.first?.slot, waiting)
        XCTAssertEqual(queue.first?.value, true)
        let held = try await stored()
        XCTAssertEqual(held.flags, [waiting], "the item carries it while it waits")
    }

    func testTheMenuOffersEveryFlagAndChecksTheOnesTheItemCarries() async throws {
        let reader = reader(preferences())
        XCTAssertEqual(reader.flagMenuRows.map(\.label), ["Flagged", "Later", "Waiting"])
        XCTAssertEqual(reader.flagMenuRows.filter(\.isOn), [])

        await reader.toggleFlag(slot: waiting)
        await reader.toggleFlag(slot: FlagPalette.systemSlot)

        XCTAssertEqual(reader.flagMenuRows.filter(\.isOn).map(\.label), ["Flagged", "Waiting"])
    }

    func testTheControlStaysAPlainButtonWhileTheBuiltInFlagIsTheOnlyOne() {
        XCTAssertEqual(reader(preferences(custom: false)).flagMenuRows, [])
    }

    /// A flag deleted from Settings stays on the item, named by its slot,
    /// and its row is what takes it off.
    func testAFlagWhoseEntryWasDeletedKeepsARowThatClearsIt() async throws {
        try await store.setFlag(feedId: "f", sortKey: "k1", slot: "cabal-flag-09", true)
        var carried = item("k1")
        carried.flags = ["cabal-flag-09"]
        let reader = FeedItemDetailViewModel(item: carried, subscription: nil, engine: engine(),
                                             preferences: preferences())
        XCTAssertEqual(reader.flagMenuRows.last, FlagMenuRow(slot: "cabal-flag-09", label: "cabal-flag-09", isOn: true))
        XCTAssertEqual(reader.flagMarks.map(\.label), ["cabal-flag-09"])

        await reader.toggleFlag(slot: "cabal-flag-09")

        let held = try await stored()
        XCTAssertEqual(held.flags, [])
        XCTAssertEqual(reader.flagMenuRows.map(\.slot), [FlagPalette.systemSlot, later, waiting])
    }

    // MARK: - The one-press controls follow the default flag

    func testTheReadersButtonTogglesTheDefaultFlagWhenItIsACustomOne() async throws {
        let reader = reader(preferences(laterIsDefault: true))
        XCTAssertEqual(reader.flagToggle.slot, later)
        XCTAssertEqual(reader.flagToggle.title(isSet: false), "Later")
        XCTAssertFalse(reader.isDefaultFlagSet)

        await reader.toggleDefaultFlag()

        XCTAssertTrue(reader.isDefaultFlagSet)
        var held = try await stored()
        XCTAssertEqual(held.flags, [later])
        XCTAssertFalse(held.isFavorite, "the built-in flag is no longer what the button sets")

        await reader.toggleDefaultFlag()

        XCTAssertFalse(reader.isDefaultFlagSet)
        held = try await stored()
        XCTAssertEqual(held.flags, [])
    }

    func testTheReadersButtonTogglesTheBuiltInFlagWhileItIsTheDefault() async throws {
        let reader = reader(preferences())
        XCTAssertEqual(reader.flagToggle.slot, FlagPalette.systemSlot)

        await reader.toggleDefaultFlag()

        XCTAssertTrue(reader.isDefaultFlagSet)
        let held = try await stored()
        XCTAssertTrue(held.isFavorite)
        XCTAssertEqual(held.flags, [])
    }

    /// The button's face reads the default flag alone: another flag on the
    /// item does not light it.
    func testTheButtonsFaceIgnoresFlagsThatAreNotTheDefault() async throws {
        let reader = reader(preferences(laterIsDefault: true))

        await reader.toggleFlag(slot: FlagPalette.systemSlot)
        await reader.toggleFlag(slot: waiting)

        XCTAssertFalse(reader.isDefaultFlagSet)
    }

    func testTheFeedsMenuItemIsTitledForTheDefaultFlag() {
        let window = WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: nil))
        XCTAssertEqual(window.feedFlag.commandTitle, "Flag/Unflag")

        window.flagPalette = [entry(later, "Later"), FlagPalette.defaultSystemEntry]

        XCTAssertEqual(window.feedFlag.slot, later)
        XCTAssertEqual(window.feedFlag.commandTitle, "Later/Remove Later")
        XCTAssertEqual(window.feedFlag, window.mailFlag, "one default flag for both media")
    }

    // MARK: - The list

    /// The swipe, the row menu's first flag item and Shift-Command-8 all
    /// go through this: the default flag, whichever flag that is.
    func testTheListsOnePressControlsToggleTheDefaultFlag() async throws {
        let list = try list(preferences(laterIsDefault: true))
        await list.reload()
        XCTAssertEqual(list.defaultFlag.slot, later)

        await list.toggleDefaultFlag(on: item("k1"))

        var held = try await stored()
        XCTAssertEqual(held.flags, [later])
        XCTAssertFalse(held.isFavorite, "the built-in flag is no longer what the swipe sets")
        XCTAssertEqual(list.filterCounts?.favorite, 0, "the Flagged pill counts the built-in flag, so it does not move")

        await list.toggleDefaultFlag(on: item("k1"))

        held = try await stored()
        XCTAssertEqual(held.flags, [])
    }

    func testTheListsOnePressControlsToggleTheBuiltInFlagWhileItIsTheDefault() async throws {
        let list = try list(preferences())
        await list.reload()

        await list.toggleDefaultFlag(on: item("k1"))

        let held = try await stored()
        XCTAssertTrue(held.isFavorite)
        XCTAssertEqual(held.flags, [])
        XCTAssertEqual(list.filterCounts?.favorite, 1)
    }

    func testAListTogglePutsTheFlagOnItsRowAndInTheStore() async throws {
        let list = try list(preferences())
        await list.reload()

        await list.toggleFlag(slot: later, on: item("k1"))

        XCTAssertEqual(list.items.first { $0.sortKey == "k1" }?.flags, [later])
        XCTAssertEqual(list.items.first { $0.sortKey == "k2" }?.flags, [])
        let held = try await stored()
        XCTAssertEqual(held.flags, [later])
    }

    /// The open item's copy is refreshed from its row. Once a reload has
    /// dropped the row, the copy is behind, and a second Shift-Command-8
    /// must still clear the flag the first one set.
    func testASecondToggleFromACopyThatIsBehindClearsTheFlag() async throws {
        let list = try list(preferences())
        let behind = item("k1")

        await list.toggleFlag(slot: later, on: behind)
        await list.toggleFlag(slot: later, on: behind)

        let held = try await stored()
        XCTAssertEqual(held.flags, [], "set, then cleared; not set twice")
    }

    func testARowFollowsAFlagSetElsewhere() async throws {
        let list = try list(preferences())
        follow { await list.observe() }
        try await waitUntilOnMainActor { list.items.count == 2 }

        try await store.setFlag(feedId: "f", sortKey: "k1", slot: waiting, true)

        try await waitUntilOnMainActor { list.items.first { $0.sortKey == "k1" }?.flags == [self.waiting] }
        XCTAssertEqual(list.items.first { $0.sortKey == "k2" }?.flags, [])
    }

    func testTheReaderFollowsAFlagSetInTheList() async throws {
        let list = try list(preferences())
        let reader = try await followingReader()

        await list.toggleFlag(slot: later, on: item("k1"))

        try await waitUntilOnMainActor { reader.item.flags == [self.later] }
        XCTAssertEqual(reader.flagMarks.map(\.label), ["Later"], "the header names it")
    }

    // MARK: - A flag the server refuses

    /// The flag was deleted on another device: the server refuses the add,
    /// the queue drops it and takes it off the item, and the row and the
    /// reader follow, so no dot stays for a flag the item does not have.
    func testARefusedFlagLeavesTheRowAndTheReader() async throws {
        let list = try list(preferences())
        follow { await list.observe() }
        try await waitUntilOnMainActor { list.items.count == 2 }
        let reader = try await followingReader()
        // The helper's read mark is sent first, so the refused flag is the
        // only change in the queue: the fake refuses every call from here.
        _ = try await engine().drainPending()
        await client.set(pushError: RssFlagRefusal(slots: [later], message: "not in the palette"))

        await list.toggleFlag(slot: later, on: item("k1"))

        try await waitUntilOnMainActor { try await self.store.pendingCount() == 0 }
        try await waitUntilOnMainActor { list.items.first { $0.sortKey == "k1" }?.flags == [] }
        try await waitUntilOnMainActor { reader.item.flags == [] }
        let held = try await stored()
        XCTAssertEqual(held.flags, [])
        XCTAssertEqual(list.pendingIds, [], "nothing is left queued for the row")
    }

    /// A reader on k1 that is following the store. The store has k1 read
    /// while the item handed to the reader says unread, so the reader's
    /// first read of the store shows once it is subscribed: what a test
    /// waits for before writing, so the write is one the reader follows.
    private func followingReader() async throws -> FeedItemDetailViewModel {
        try await store.setRead(feedId: "f", sortKey: "k1", true)
        let reader = reader(preferences())
        follow { await reader.observe() }
        try await waitUntilOnMainActor { reader.item.isRead }
        return reader
    }
}

/// The feed's "flaggable" value (`FeedItemMark`): which flags an item
/// carries, what a change does to a copy, and when a copy is behind the
/// store. Pure, so the rules are tested away from a store.
final class FeedItemMarkTests: XCTestCase {
    private func item(isRead: Bool = false, isFavorite: Bool = false, flags: Set<String> = []) -> RssItem {
        RssItem(feedId: "f", itemId: "i", sortKey: "k", isRead: isRead, isFavorite: isFavorite, flags: flags)
    }

    func testAnItemsPaletteFlagsAreItsSlotsAndTheFavoriteBit() {
        XCTAssertEqual(item().paletteFlags, [])
        XCTAssertEqual(item(isFavorite: true).paletteFlags, [.flagged])
        XCTAssertEqual(
            item(isFavorite: true, flags: ["cabal-flag-02"]).paletteFlags,
            [.flagged, .keyword("cabal-flag-02")]
        )
        XCTAssertEqual(item(flags: ["cabal-flag-02"]).paletteFlags, [.keyword("cabal-flag-02")])
    }

    func testCarriesReadsTheFavoriteBitForTheBuiltInSlot() {
        let flagged = item(isFavorite: true, flags: ["cabal-flag-02"])
        XCTAssertTrue(flagged.carries(slot: FlagPalette.systemSlot))
        XCTAssertTrue(flagged.carries(slot: "cabal-flag-02"))
        XCTAssertFalse(flagged.carries(slot: "cabal-flag-03"))
        XCTAssertFalse(item(flags: ["cabal-flag-02"]).carries(slot: FlagPalette.systemSlot))
    }

    func testApplyingAMarkChangesOnlyWhatItNames() {
        var copy = item(flags: ["cabal-flag-02"])

        copy.apply(.flag(slot: "cabal-flag-04", isSet: true))
        XCTAssertEqual(copy.flags, ["cabal-flag-02", "cabal-flag-04"])
        XCTAssertFalse(copy.isFavorite)

        copy.apply(.flag(slot: FlagPalette.systemSlot, isSet: true))
        XCTAssertTrue(copy.isFavorite)
        XCTAssertEqual(copy.flags, ["cabal-flag-02", "cabal-flag-04"], "the built-in flag is not a slot")

        copy.apply(.flag(slot: "cabal-flag-02", isSet: false))
        XCTAssertEqual(copy.flags, ["cabal-flag-04"])

        copy.apply(.read(true))
        XCTAssertTrue(copy.isRead)
        XCTAssertTrue(copy.isFavorite)
        XCTAssertEqual(copy.flags, ["cabal-flag-04"])
    }

    func testACopyDiffersFromTheStoreInAnyOfItsThreeMarks() {
        let copy = item()
        XCTAssertFalse(copy.marksDiffer(from: item()))
        XCTAssertTrue(copy.marksDiffer(from: item(isRead: true)))
        XCTAssertTrue(copy.marksDiffer(from: item(isFavorite: true)))
        XCTAssertTrue(copy.marksDiffer(from: item(flags: ["cabal-flag-02"])), "a custom flag alone is a difference")
    }

    func testTakingTheStoresMarksLeavesTheRestOfTheCopy() {
        var copy = RssItem(feedId: "f", itemId: "i", sortKey: "k", title: "Mine")
        var held = item(isRead: true, isFavorite: true, flags: ["cabal-flag-02"])
        held.title = "Theirs"

        copy.takeMarks(from: held)

        XCTAssertTrue(copy.isRead)
        XCTAssertTrue(copy.isFavorite)
        XCTAssertEqual(copy.flags, ["cabal-flag-02"])
        XCTAssertEqual(copy.title, "Mine")
    }
}

/// What the feed list says under the Flagged pill with nothing to show.
final class FeedFlaggedEmptyStateTests: XCTestCase {
    func testTheSwipeIsOfferedOnlyWhileItSetsTheFlagThePillShows() {
        XCTAssertEqual(
            FeedItemListView.flaggedEmptyDescription(defaultFlagIsBuiltIn: true, flagName: "Flagged"),
            "Swipe an item or use its menu to flag it."
        )
        // Another flag is the default: the swipe sets that one, so the
        // Flags menu is the way to the built-in flag, under its own name.
        XCTAssertEqual(
            FeedItemListView.flaggedEmptyDescription(defaultFlagIsBuiltIn: false, flagName: "Urgent"),
            "Use an item's Flags menu to mark it Urgent."
        )
    }
}
