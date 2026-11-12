import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The Flagged pill's menu on a feed list (cross-media plan, Phase 2): a
/// flag of the user's own, or any flag, narrows the list for the visit
/// from the device's own store and records nothing; the built-in flag's
/// row and Clear filter are the pills they always were. Rows and counts
/// are read through the real store.
@MainActor
final class FeedListFlagFilterTests: XCTestCase {
    private final class RecordingPersister: FeedDefaultsPersisting, @unchecked Sendable {
        private(set) var filters: [RssItemFilter?] = []

        func updateSubscription(_ subscription: RssSubscription, _ update: RssSubscriptionUpdate) async throws
            -> RssSubscription {
            filters.append(update.defaultFilter)
            return subscription.applying(update)
        }

        func updateFolder(_ folder: RssFolder, _ update: RssFolderUpdate) async throws -> RssFolder {
            filters.append(update.defaultFilter)
            return folder.applying(update)
        }
    }

    private let later = "cabal-flag-03"
    private let waiting = "cabal-flag-05"
    private var directory: URL!
    private var store: RssStore!
    private var persister: RecordingPersister!
    private var preferences: Preferences!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-flag-filter-\(UUID().uuidString)")
        store = try RssStore(directory: directory)
        persister = RecordingPersister()
        preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: "cabalmail.example", username: "alice")
        preferences.flagPalette = [
            FlagPaletteEntry(slot: later, label: "Later", color: "blue"),
            FlagPaletteEntry(slot: waiting, label: "Waiting", color: "green"),
        ]
        try await store.upsertSubscription(RssSubscription(subscriptionId: "s", feedId: "f"))
        try await store.upsertSubscription(RssSubscription(subscriptionId: "t", feedId: "g"))
        try await store.upsertItems([
            item("a", flags: [later]), item("b", flags: [later, waiting]), item("c", favorite: true),
            item("d"), item("e", flags: [waiting]), item("z", feed: "g", flags: [later]),
        ])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ key: String, feed: String = "f", favorite: Bool = false, flags: Set<String> = []) -> RssItem {
        RssItem(feedId: feed, subscriptionId: feed == "f" ? "s" : "t", itemId: key, sortKey: key, title: key,
                publishedAt: "2026-01-01T00:00:00Z", isFavorite: favorite, flags: flags)
    }

    /// The list for feed "s", whose row opens it on `sticky`.
    private func list(
        scope: RssItemScope = .subscription("s"), sticky: RssItemFilter = .all,
        picks: FlagPickHold<RssItemScope>? = nil
    ) throws -> FeedItemListViewModel {
        FeedItemListViewModel(
            scope: scope,
            subscription: scope == .subscription("s")
                ? RssSubscription(subscriptionId: "s", feedId: "f", defaultFilter: sticky) : nil,
            client: try TestFixtures.makeClient(imap: FakeImapClient()), preferences: preferences,
            defaults: persister, store: store, engine: RssSyncEngine(client: FakeRssClient(), store: store),
            flagPicks: picks
        )
    }

    private func shown(_ model: FeedItemListViewModel) -> Set<String> { Set(model.items.map(\.sortKey)) }

    /// Lets the write-through task a recorded pill spawned run.
    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - What a row lists

    func testACustomFlagsRowListsTheItemsCarryingItAndCountsThem() async throws {
        let model = try list()

        model.chooseFlagFilter(.flag(slot: later))
        await model.reload()

        XCTAssertEqual(shown(model), ["a", "b"], "this feed's, and not the built-in flag's item")
        XCTAssertEqual(model.flagPick, .slot(later))
        XCTAssertEqual(model.filter, .favorite, "the Flagged pill is lit over the pick")
        let pill = try XCTUnwrap(model.flagFilterPill)
        XCTAssertEqual(pill.label, "Later")
        XCTAssertEqual(pill.count, 2)
        XCTAssertEqual(model.filterCounts?.favorite, 1, "the built-in flag's count is another number")
    }

    func testAnyFlagListsEveryItemThatDrawsADot() async throws {
        let model = try list(scope: .all)

        model.chooseFlagFilter(.any)
        await model.reload()

        XCTAssertEqual(shown(model), ["a", "b", "c", "e", "z"])
        XCTAssertEqual(model.flagFilterPill?.label, "Any flag")
        XCTAssertEqual(model.flagFilterPill?.count, 5)
        // The rule mail applies to its rows gives the same list.
        let everything = try await store.items(.init(scope: .all, limit: 100))
        let matching = everything.filter { FlagCriterion.any.matches($0.paletteFlags) }
        XCTAssertEqual(shown(model), Set(matching.map(\.sortKey)))
    }

    /// The list pages a hundred rows at a time, and the pick has to narrow
    /// every page: one read without it would lay the feed's other items
    /// under the flag's.
    func testEveryPageKeepsThePick() async throws {
        try await store.upsertItems((0..<180).map { index in
            RssItem(feedId: "f", subscriptionId: "s", itemId: "n\(index)", sortKey: String(format: "n%03d", index),
                    publishedAt: "2026-02-01T00:00:00Z", flags: index.isMultiple(of: 3) ? [] : [waiting])
        })
        let model = try list()

        model.chooseFlagFilter(.flag(slot: waiting))
        await model.reload()
        XCTAssertEqual(model.items.count, 100)
        await model.loadMore()
        await model.loadMore()

        XCTAssertEqual(model.items.count, 122, "120 new ones, and the two that carried it before")
        XCTAssertTrue(model.items.allSatisfy { $0.flags.contains(waiting) })
        XCTAssertEqual(model.flagFilterPill?.count, 122)
    }

    // MARK: - What is recorded

    func testAPickRecordsNothing() async throws {
        let model = try list(sticky: .unread)

        model.chooseFlagFilter(.flag(slot: later))
        await model.reload()
        await settle()

        XCTAssertEqual(model.flagPick, .slot(later), "the pick did take")
        XCTAssertEqual(model.subscription?.defaultFilter, .unread, "the feed still opens on its own pill")
        XCTAssertTrue(persister.filters.isEmpty)

        let everywhere = try list(scope: .all)
        let before = preferences.appPreferencesPayload()
        everywhere.chooseFlagFilter(.any)
        await everywhere.reload()
        XCTAssertEqual(everywhere.flagPick, .any)
        XCTAssertEqual(preferences.appPreferencesPayload(), before, "nor the all-feeds preference")
    }

    /// The built-in flag's row is the Flagged pill itself. Over a pick the
    /// pill is already lit, and a route that only compared pills would do
    /// nothing.
    func testTheBuiltInFlagsRowOverAPickIsTheFlaggedPillAndIsRecorded() async throws {
        let model = try list()
        model.chooseFlagFilter(.flag(slot: later))
        await model.reload()

        model.chooseFlagFilter(.flag(slot: FlagPalette.systemSlot))
        await model.reload()
        await settle()

        XCTAssertNil(model.flagPick)
        XCTAssertEqual(model.filter, .favorite)
        XCTAssertEqual(shown(model), ["c"])
        XCTAssertEqual(model.subscription?.defaultFilter, .favorite)
        XCTAssertEqual(persister.filters, [.favorite], "written once, as a tap on the plain pill is")
        XCTAssertEqual(model.flagFilterPill?.count, 1)
    }

    func testClearFilterIsAllAndIsRecorded() async throws {
        let model = try list(sticky: .unread)
        model.chooseFlagFilter(.flag(slot: later))
        await model.reload()

        model.chooseFlagFilter(.clear)
        await model.reload()
        await settle()

        XCTAssertNil(model.flagPick)
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(shown(model), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(persister.filters, [.all])
    }

    func testUnreadOverAPickTakesItsPlace() async throws {
        let model = try list()
        model.chooseFlagFilter(.flag(slot: later))
        await model.reload()
        try await store.setRead(feedId: "f", sortKey: "a", true)

        // The Unread pill's tap, as the bar sends it.
        model.selectFilter(model.filter.toggling(.unread))
        await model.reload()
        await settle()

        XCTAssertNil(model.flagPick)
        XCTAssertEqual(model.filter, .unread)
        XCTAssertEqual(shown(model), ["b", "c", "d", "e"], "every unread item, flagged or not")
        XCTAssertEqual(persister.filters, [.unread])
    }

    /// Over a pick the all-feeds pill can be chosen with the value the
    /// preference already holds. Writing it anyway would mark a default the
    /// user never set as theirs, to ride every later settings push.
    func testThePillChosenOverAPickDoesNotRewriteThePreferenceItMatches() async throws {
        let model = try list(scope: .all)
        XCTAssertEqual(model.filter, .unread, "the default, which the user has not set")
        model.chooseFlagFilter(.any)
        let before = preferences.appPreferencesPayload()
        XCTAssertNil(before["filter:feeds:all"])

        model.selectFilter(.unread)

        XCTAssertNil(model.flagPick)
        XCTAssertEqual(model.filter, .unread)
        XCTAssertEqual(preferences.appPreferencesPayload(), before)
    }

    // MARK: - Where the pick is kept

    /// The list builds a new model on every appearance (a reader popped on
    /// iPhone among them). The window holds the pick, so the feed's next
    /// list opens on it.
    func testTheScopesNextListOpensOnThePick() async throws {
        let picks = FlagPickHold<RssItemScope>()
        let first = try list(sticky: .unread, picks: picks)
        first.chooseFlagFilter(.flag(slot: later))

        let second = try list(sticky: .unread, picks: picks)
        await second.reload()

        XCTAssertEqual(second.flagPick, .slot(later))
        XCTAssertEqual(second.filter, .favorite)
        XCTAssertEqual(shown(second), ["a", "b"])
        XCTAssertEqual(second.subscription?.defaultFilter, .unread)
        XCTAssertTrue(persister.filters.isEmpty)
    }

    func testAListForAnotherScopeEndsTheVisit() async throws {
        let picks = FlagPickHold<RssItemScope>()
        try list(picks: picks).chooseFlagFilter(.flag(slot: later))

        let elsewhere = try list(scope: .all, picks: picks)
        let back = try list(sticky: .unread, picks: picks)

        XCTAssertNil(elsewhere.flagPick)
        XCTAssertNil(back.flagPick, "the window moved on; coming back finds no pick")
        XCTAssertEqual(back.filter, .unread)
    }

    func testAPickThatEndedIsNotHandedToTheNextList() async throws {
        let picks = FlagPickHold<RssItemScope>()
        let endings: [(String, @MainActor (FeedItemListViewModel) -> Void)] = [
            ("Unread", { $0.selectFilter(.unread) }),
            ("Clear filter", { $0.chooseFlagFilter(.clear) }),
            ("the built-in row", { $0.chooseFlagFilter(.flag(slot: FlagPalette.systemSlot)) }),
        ]
        for (name, end) in endings {
            let first = try list(picks: picks)
            first.chooseFlagFilter(.flag(slot: later))
            XCTAssertEqual(picks.take(for: .subscription("s")), .slot(later), name)

            end(first)

            let next = try list(picks: picks)
            XCTAssertNil(next.flagPick, name)
        }
    }

    // MARK: - The pick's number

    /// A number counted for the flag picked before is not this flag's.
    func testANewPickShowsNoNumberUntilItIsCounted() async throws {
        let model = try list()
        model.chooseFlagFilter(.flag(slot: later))
        await model.reload()
        XCTAssertEqual(model.flagFilterPill?.count, 2)

        model.chooseFlagFilter(.flag(slot: waiting))

        let waitingPill = try XCTUnwrap(model.flagFilterPill)
        XCTAssertEqual(waitingPill.label, "Waiting")
        XCTAssertNil(waitingPill.count, "not Later's 2 under Waiting's name")
        XCTAssertEqual(waitingPill.reservedCount, 1, "the room a number will take")
        await model.reload()
        XCTAssertEqual(model.flagFilterPill?.count, 2)
        XCTAssertEqual(shown(model), ["b", "e"])
    }

    func testThePicksNumberFollowsAFlagSetOnARow() async throws {
        let model = try list()
        model.chooseFlagFilter(.flag(slot: later))
        await model.reload()
        let held = try await store.item(feedId: "f", sortKey: "d")
        let plain = try XCTUnwrap(held)

        await model.toggleFlag(slot: later, on: plain)

        XCTAssertEqual(model.flagFilterPill?.count, 3)

        await model.toggleFlag(slot: later, on: try XCTUnwrap(model.items.first { $0.sortKey == "a" }))

        XCTAssertEqual(model.flagFilterPill?.count, 2)
        XCTAssertTrue(shown(model).contains("a"), "the row stays until the next reload, as a read one under Unread")
    }

    func testThePillIsThePlainToggleWithNoFlagOfTheUsersOwn() async throws {
        preferences.flagPalette = []
        let model = try list()
        await model.reload()

        XCTAssertNil(model.flagFilterPill)

        preferences.flagPalette = [FlagPaletteEntry(slot: later, label: "Later", color: "blue")]
        let pill = try XCTUnwrap(model.flagFilterPill)
        XCTAssertEqual(pill.label, "Flagged")
        XCTAssertEqual(pill.count, 1, "the built-in flag's count, as the plain pill shows")
        XCTAssertFalse(pill.isOn)
    }
}

/// `FeedListNarrowing`: the pill and the pick as one value, the query they
/// make, what each menu row leaves the list on, and an empty list's words.
final class FeedListNarrowingTests: XCTestCase {
    private let system = FlagPalette.systemSlot
    private let later = "cabal-flag-03"

    func testAPickLightsFlaggedAndTheBuiltInFlagIsNeverAPick() {
        let picked = FeedListNarrowing(filter: .unread, pick: .slot(later))
        XCTAssertEqual(picked.filter, .favorite)
        XCTAssertEqual(picked.pick, .slot(later))
        XCTAssertEqual(picked.current, .slot(later))

        let builtIn = FeedListNarrowing(filter: .unread, pick: .slot(system))
        XCTAssertEqual(builtIn, FeedListNarrowing(filter: .favorite), "one spelling of the Flagged pill")
        XCTAssertEqual(builtIn.current, .slot(system))

        XCTAssertEqual(FeedListNarrowing(filter: .unread, pick: .slot("$Forwarded")),
                       FeedListNarrowing(filter: .unread))
        XCTAssertNil(FeedListNarrowing(filter: .unread).current)
        XCTAssertNil(FeedListNarrowing(filter: .all).current)
        XCTAssertEqual(FeedListNarrowing(filter: .all, pick: .any).current, .any)
    }

    /// A picked flag is the one criterion: it stands in place of the pill's
    /// own filter, on the first page and on the pages after.
    func testAPickStandsInPlaceOfThePillsFilterOnEveryPage() {
        let last = RssItem(feedId: "f", itemId: "i", sortKey: "k", publishedAt: "2026-01-01T00:00:00Z")
        let picked = FeedListNarrowing(filter: .unread, pick: .slot(later))

        let first = picked.query(scope: .all, ordering: .oldestFirst, limit: 100)
        let next = picked.query(scope: .all, ordering: .oldestFirst, limit: 100, after: last)

        XCTAssertEqual(first, RssStore.ItemQuery(scope: .all, filter: .all, flag: .slot(later), ordering: .oldestFirst,
                                                 limit: 100))
        XCTAssertEqual(next.flag, .slot(later))
        XCTAssertEqual(next.filter, .all)
        XCTAssertEqual(next.after, RssStore.ItemCursor(after: last))
        XCTAssertEqual(FeedListNarrowing(filter: .unread).query(scope: .all, ordering: .newestFirst, limit: 100),
                       RssStore.ItemQuery(scope: .all, filter: .unread, ordering: .newestFirst, limit: 100))
    }

    func testEachMenuRowsOutcome() {
        let onUnread = FeedListNarrowing(filter: .unread)

        let custom = onUnread.choosing(.flag(slot: later))
        XCTAssertEqual(custom.narrowing, FeedListNarrowing(filter: .unread, pick: .slot(later)))
        XCTAssertNil(custom.recorded, "a pick is never recorded")
        XCTAssertNil(onUnread.choosing(.any).recorded)
        XCTAssertEqual(onUnread.choosing(.any).narrowing.pick, .any)

        let builtIn = custom.narrowing.choosing(.flag(slot: system))
        XCTAssertEqual(builtIn.narrowing, FeedListNarrowing(filter: .favorite))
        XCTAssertEqual(builtIn.recorded, .favorite)

        let cleared = custom.narrowing.choosing(.clear)
        XCTAssertEqual(cleared.narrowing, FeedListNarrowing(filter: .all))
        XCTAssertEqual(cleared.recorded, .all)

        let unknown = onUnread.choosing(.flag(slot: "$Forwarded"))
        XCTAssertEqual(unknown.narrowing, onUnread)
        XCTAssertNil(unknown.recorded)
    }

    func testAnEmptyListNamesThePickedFlag() {
        XCTAssertEqual(FeedListNarrowing.emptyTitle(pick: nil, name: "Flagged"), "No flagged items")
        XCTAssertEqual(FeedListNarrowing.emptyTitle(pick: .any, name: "Any flag"), "No flagged items")
        XCTAssertEqual(FeedListNarrowing.emptyTitle(pick: .slot(later), name: "Later"), "No items marked Later")
    }

    /// The swipe is offered only where it sets the flag the list shows.
    func testAnEmptyListOffersTheSwipeOnlyWhereItSetsTheFlagShown() {
        func words(_ pick: FlagCriterion, swipe: Bool = false, inPalette: Bool = true) -> String {
            FeedListNarrowing.emptyDescription(pick: pick, name: "Later", swipeSetsIt: swipe, isInPalette: inPalette)
        }

        XCTAssertEqual(words(.slot(later)), "Use an item's Flags menu to mark it Later.")
        XCTAssertEqual(words(.slot(later), swipe: true), "Swipe an item or use its menu to flag it.")
        XCTAssertEqual(words(.any), "Swipe an item or use its menu to flag it.", "whatever the swipe sets shows")
        XCTAssertEqual(words(.slot(later), inPalette: false), "This flag was deleted.")
    }
}
