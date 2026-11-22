import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `FlaggedListViewModel`: what each pick asks of each half, and the horizon
/// as pages land. `FlaggedListFailureTests` has the mail half failing, and
/// `FlaggedRowWritesTests` what a row's controls write.
@MainActor
final class FlaggedListViewModelTests: XCTestCase {
    private typealias Fixture = FlaggedFixture
    private var fixture: FlaggedFixture!

    override func setUp() async throws {
        fixture = try await FlaggedFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    // MARK: What it asks for

    func testItOpensOnAnyFlagAndListsBothMediaByDate() async throws {
        await fixture.source.answer(.any, with: Fixture.page([
            Fixture.mail(3, "2026-03-05T08:00:00Z"), Fixture.mail(9, "2026-03-05T21:00:00Z", folder: "Archive"),
        ]))
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        try await fixture.addItem("b", "2026-03-01T00:00:00+00:00", favorite: false, flags: [Fixture.later])
        try await fixture.addItem("unflagged", "2026-03-06T00:00:00+00:00", favorite: false)
        let model = fixture.makeModel()

        model.start()

        await fixture.expect(model, shows: ["m9", "a", "m3", "b"])
        XCTAssertEqual(model.criterion, .any)
        let calls = await fixture.source.calls
        XCTAssertEqual(calls, [.init(criterion: .any, cursor: nil)])
        XCTAssertNil(model.page.next)
    }

    func testAPickAsksEachHalfForThatFlagAlone() async throws {
        fixture.addLaterFlag()
        let later = FlagCriterion.slot(Fixture.later)
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(1, "2026-03-05T08:00:00Z")]))
        await fixture.source.answer(later, with: Fixture.page([
            Fixture.mail(2, "2026-03-04T08:00:00Z", flags: [.keyword(Fixture.later)]),
        ]))
        try await fixture.addItem("flagged", "2026-03-05T12:00:00+00:00")
        try await fixture.addItem("later", "2026-03-03T00:00:00+00:00", favorite: false, flags: [Fixture.later])
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["flagged", "m1", "later"])
        let epoch = model.listEpoch

        model.choose(.flag(slot: Fixture.later))

        await fixture.expect(model, shows: ["m2", "later"])
        XCTAssertEqual(model.criterion, later)
        XCTAssertEqual(model.listEpoch, epoch + 1, "a pick is a list of its own, from the top")
        let calls = await fixture.source.calls
        XCTAssertEqual(calls.last, .init(criterion: later, cursor: nil))

        // Any flag is the way back.
        model.choose(.any)
        await fixture.expect(model, shows: ["flagged", "m1", "later"])
    }

    func testTheBuiltInFlagsPickLeavesOutItemsThatCarryOnlyAFlagOfTheUsersOwn() async throws {
        fixture.addLaterFlag()
        let builtIn = FlagCriterion.slot(FlagPalette.systemSlot)
        await fixture.source.answer(builtIn, with: Fixture.page([Fixture.mail(1, "2026-03-05T08:00:00Z")]))
        try await fixture.addItem("flagged", "2026-03-05T12:00:00+00:00")
        try await fixture.addItem("later", "2026-03-03T00:00:00+00:00", favorite: false, flags: [Fixture.later])
        let model = fixture.makeModel()
        model.start()

        model.pick(builtIn)

        await fixture.expect(model, shows: ["flagged", "m1"])
    }

    func testStartingAgainLoadsNothingAgain() async throws {
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(1, "2026-03-05T08:00:00Z")]))
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m1"])

        // A reader pushed and popped on iPhone brings the list's view back.
        model.start()
        model.start()

        await fixture.expect(model, shows: ["m1"])
        let calls = await fixture.source.calls
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: Paging and the horizon

    func testWhileMailHasMorePagesNothingOlderThanItsHorizonShowsFromEitherHalf() async throws {
        await fixture.scriptThreePages()
        try await fixture.addItem("new", "2026-03-06T12:00:00+00:00")
        try await fixture.addItem("sameDay", "2026-03-05T23:00:00+00:00")
        try await fixture.addItem("old", "2026-02-25T00:00:00+00:00")
        let model = fixture.makeModel()

        model.start()

        // Page one ends on 5 March, so the list is whole down to 6 March.
        await fixture.expect(model, shows: ["m9", "new"])
        XCTAssertEqual(model.page.next, .mail)
        XCTAssertEqual(model.page.heldBack, 3)

        model.loadMore()
        // Page two ends on 2 March: whole down to 3 March.
        await fixture.expect(model, shows: ["m9", "new", "sameDay", "m8", "m7"])
        XCTAssertEqual(model.page.next, .mail)

        model.loadMore()
        await fixture.expect(model, shows: ["m9", "new", "sameDay", "m8", "m7", "m6", "old", "m5"])
        XCTAssertNil(model.page.next)
        let calls = await fixture.source.calls
        XCTAssertEqual(calls.map(\.cursor), [nil, "p2", "p3"])
    }

    func testBeforeTheFirstPageLandsNothingIsListed() async throws {
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(1, "2026-03-01T08:00:00Z")]))
        await fixture.source.holdNext()
        let model = fixture.makeModel()

        model.start()
        try await waitUntilOnMainActor { model.feedLoaded }
        try await waitUntilOnMainActor { await self.fixture.source.isHolding }

        // The feed half is read, and held: mail must not arrive above it.
        XCTAssertEqual(Fixture.names(model), [])
        XCTAssertEqual(model.page.heldBack, 1)
        XCTAssertFalse(model.isEmpty, "a list still loading is not an empty one")

        await fixture.source.release()
        await fixture.expect(model, shows: ["a", "m1"])
    }

    func testAPageThatShowsNoNewMessageAsksForTheNextOne() async throws {
        // All of page one is one day, so none of it can be shown, and no
        // row has come on screen to ask for page two.
        await fixture.source.answer(.any, with: Fixture.page(
            [Fixture.mail(3, "2026-03-05T20:00:00Z"), Fixture.mail(2, "2026-03-05T08:00:00Z")], total: 3, next: "p2"
        ))
        await fixture.source.answer(.any, after: "p2", with: Fixture.page([Fixture.mail(1, "2026-03-01T08:00:00Z")]))
        let model = fixture.makeModel()

        model.start()

        await fixture.expect(model, shows: ["m3", "m2", "m1"])
    }

    func testTheRowThatAsksForMoreAsksAgainWhileItStaysOnScreen() async throws {
        await fixture.scriptThreePages()
        let model = fixture.makeModel()

        // The asking row is on screen from the start and never leaves: the
        // list is short of the screen.
        model.footer(isVisible: true)
        model.start()

        await fixture.expect(model, shows: ["m9", "m8", "m7", "m6", "m5"])
    }

    func testOffScreenTheRowThatAsksForMoreAsksNothing() async throws {
        await fixture.scriptThreePages()
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m9"])

        model.footer(isVisible: false)
        let moved = await holdsOnMainActor(within: 0.3) { Fixture.names(model) != ["m9"] }

        XCTAssertFalse(moved)
        let calls = await fixture.source.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testAMessageTwoPagesDeliverIsListedOnce() async throws {
        await fixture.source.answer(.any, with: Fixture.page(
            [Fixture.mail(9, "2026-03-07T10:00:00Z"), Fixture.mail(8, "2026-03-05T22:00:00Z")], total: 3, next: "p2"
        ))
        // The boundary shifted under mailbox churn: UID 8 comes again.
        await fixture.source.answer(.any, after: "p2", with: Fixture.page(
            [Fixture.mail(8, "2026-03-05T22:00:00Z"), Fixture.mail(7, "2026-03-01T08:00:00Z")]
        ))
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m9"])

        model.loadMore()

        await fixture.expect(model, shows: ["m9", "m8", "m7"])
    }

    /// The feed half is read from the store a page at a time too, so it has
    /// a horizon of its own once an account holds more flagged feed items
    /// than a page: the last row read waits, since an item of the same
    /// instant may be on the next read.
    func testTheFeedHalfPagesBehindItsOwnHorizon() async throws {
        let size = FlaggedList.feedPageSize
        let start = Fixture.date("2026-03-01T00:00:00Z")
        let items = (0..<(size + 5)).map { index in
            // Newest first by sort key and by date alike.
            RssItem(
                feedId: "f", subscriptionId: "s", itemId: "i\(index)", sortKey: String(format: "k%04d", 9999 - index),
                publishedAt: start.addingTimeInterval(TimeInterval(-60 * index)).formatted(.iso8601),
                isFavorite: true
            )
        }
        try await fixture.store.upsertItems(items)
        let model = fixture.makeModel()

        model.start()

        try await waitUntilOnMainActor { model.page.next == .feed && !model.mailLoading }
        XCTAssertEqual(model.page.rows.count, size - 1)
        XCTAssertEqual(model.page.heldBack, 1)

        model.loadMore()

        try await waitUntilOnMainActor { model.page.next == nil }
        XCTAssertEqual(model.page.rows.count, size + 5)
        XCTAssertEqual(model.count, size + 5)
    }

    /// The store is asked for the pick itself, not for everything flagged
    /// to be narrowed afterwards: a page of other flags' items would hide
    /// the pick's own behind a horizon.
    func testTheFeedHalfAsksTheStoreForThePickAlone() async throws {
        fixture.addLaterFlag()
        let start = Fixture.date("2026-03-01T00:00:00Z")
        var items = (0..<FlaggedList.feedPageSize).map { index in
            RssItem(
                feedId: "f", subscriptionId: "s", itemId: "i\(index)", sortKey: String(format: "k%04d", 9999 - index),
                publishedAt: start.addingTimeInterval(TimeInterval(-60 * index)).formatted(.iso8601),
                isFavorite: true
            )
        }
        items.append(RssItem(
            feedId: "f", subscriptionId: "s", itemId: "old", sortKey: "k0000",
            publishedAt: "2026-01-01T00:00:00Z", flags: [Fixture.later]
        ))
        try await fixture.store.upsertItems(items)
        let model = fixture.makeModel()
        model.start()

        model.pick(.slot(Fixture.later))

        try await waitUntilOnMainActor { model.feedLoaded && !model.mailLoading }
        XCTAssertEqual(Fixture.names(model), ["k0000"])
        XCTAssertNil(model.page.next, "one item, read whole: nothing is left to load")
    }

    func testAnAnswerToAListAPickReplacedIsDropped() async throws {
        fixture.addLaterFlag()
        let later = FlagCriterion.slot(Fixture.later)
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(1, "2026-03-05T08:00:00Z")]))
        await fixture.source.answer(later, with: Fixture.page([
            Fixture.mail(2, "2026-03-04T08:00:00Z", flags: [.keyword(Fixture.later)]),
        ]))
        await fixture.source.holdNext()
        let model = fixture.makeModel()
        model.start()
        try await waitUntilOnMainActor { await self.fixture.source.isHolding }

        model.pick(later)
        await fixture.expect(model, shows: ["m2"])
        await fixture.source.release()

        let moved = await holdsOnMainActor(within: 0.3) { Fixture.names(model) != ["m2"] }
        XCTAssertFalse(moved, "the first list's answer landed after the pick, and is not this list's")
    }
}
