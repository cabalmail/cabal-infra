import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `FlaggedListViewModel` when the mail half cannot be had or is cut short:
/// no connection with and without rows on screen, the server's cap, the
/// pill's number, and a restored window's open item.
@MainActor
final class FlaggedListFailureTests: XCTestCase {
    private typealias Fixture = FlaggedFixture
    private var fixture: FlaggedFixture!

    override func setUp() async throws {
        fixture = try await FlaggedFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    // MARK: No connection

    func testWithNoMailEverLoadedTheFeedHalfStandsAlone() async throws {
        await fixture.source.fail(.any)
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        try await fixture.addItem("b", "2026-01-01T00:00:00+00:00")
        let model = fixture.makeModel()

        model.start()

        await fixture.expect(model, shows: ["a", "b"])
        XCTAssertEqual(model.mailFailure, .neverLoaded)
        XCTAssertNil(model.page.next, "no claim is made about mail, so nothing is held behind it")
        XCTAssertNil(model.count)
        XCTAssertFalse(model.isEmpty)
    }

    func testARefreshThatFailsKeepsTheMessagesOnScreen() async throws {
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(1, "2026-03-05T08:00:00Z")]))
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m1"])
        await fixture.source.fail(.any)

        await model.refresh()

        XCTAssertEqual(Fixture.names(model), ["m1"])
        XCTAssertEqual(model.mailFailure, .refresh)
        XCTAssertFalse(model.isRefreshing)
    }

    func testAFailedNextPageStopsAtTheHorizonUntilItIsTriedAgain() async throws {
        await fixture.scriptThreePages()
        await fixture.source.fail(.any, after: "p2")
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m9"])

        model.loadMore()
        try await waitUntilOnMainActor { model.mailFailure == .nextPage }
        XCTAssertEqual(Fixture.names(model), ["m9"])
        // The asking row stays on screen under the failure and asks nothing.
        model.footer(isVisible: true)
        var calls = await fixture.source.calls
        XCTAssertEqual(calls.map(\.cursor), [nil, "p2"])

        await fixture.source.answer(.any, after: "p2", with: Fixture.page([Fixture.mail(7, "2026-03-01T08:00:00Z")]))
        model.footer(isVisible: false)
        model.retryMail()

        await fixture.expect(model, shows: ["m9", "m8", "m7"])
        XCTAssertNil(model.mailFailure)
        calls = await fixture.source.calls
        XCTAssertEqual(calls.map(\.cursor), [nil, "p2", "p2"], "the page that failed, not the list from the top")
    }

    func testTheConnectionComingBackLoadsAMailHalfThatFailed() async throws {
        await fixture.source.fail(.any)
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["a"])
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(1, "2026-03-06T08:00:00Z")]))

        model.connectionReturned()

        await fixture.expect(model, shows: ["m1", "a"])
        XCTAssertNil(model.mailFailure)
    }

    func testTheConnectionComingBackAsksNothingOfAHalfThatLoaded() async throws {
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(1, "2026-03-06T08:00:00Z")]))
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m1"])

        model.connectionReturned()
        await model.mailTask?.value

        let calls = await fixture.source.calls
        XCTAssertEqual(calls.count, 1)
    }

    /// A refresh that lands replaces what was loaded: a message whose flag
    /// another device cleared is gone, not kept beside the fresh rows.
    func testARefreshThatLandsReplacesWhatWasLoaded() async throws {
        await fixture.source.answer(.any, with: Fixture.page([
            Fixture.mail(2, "2026-03-06T08:00:00Z"), Fixture.mail(1, "2026-03-05T08:00:00Z"),
        ]))
        let model = fixture.makeModel()
        model.start()
        await fixture.expect(model, shows: ["m2", "m1"])
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(2, "2026-03-06T08:00:00Z")]))

        await model.refresh()

        XCTAssertEqual(Fixture.names(model), ["m2"])
        XCTAssertEqual(model.count, 1)
        XCTAssertNil(model.mailFailure)
    }

    // MARK: The cap

    func testATruncatedAnswerIsSaidAndItsRowsListed() async throws {
        await fixture.source.answer(.any, with: Fixture.page(
            [Fixture.mail(2, "2026-03-05T08:00:00Z"), Fixture.mail(1, "2026-03-04T08:00:00Z")], total: 5000,
            truncated: true
        ))
        let model = fixture.makeModel()

        model.start()

        await fixture.expect(model, shows: ["m2", "m1"])
        XCTAssertTrue(model.truncated)

        // A pick whose answer is whole says nothing.
        fixture.addLaterFlag()
        model.pick(.slot(Fixture.later))
        try await waitUntilOnMainActor { !model.mailLoading }
        XCTAssertFalse(model.truncated)
    }

    // MARK: Counts and words

    func testThePillCarriesWhatThePickFindsInBothHalves() async throws {
        fixture.addLaterFlag()
        await fixture.source.answer(.any, with: Fixture.page(
            [Fixture.mail(9, "2026-03-07T10:00:00Z"), Fixture.mail(8, "2026-03-05T22:00:00Z")], total: 12, next: "p2"
        ))
        try await fixture.addItem("a", "2026-03-06T12:00:00+00:00")
        try await fixture.addItem("b", "2026-01-01T00:00:00+00:00")
        let model = fixture.makeModel()
        XCTAssertNil(model.pill?.count, "no number until the mail half has answered")

        model.start()
        await fixture.expect(model, shows: ["m9", "a"])

        // Twelve messages by the first page's count, and two feed items,
        // however few of either the horizon lets through yet.
        XCTAssertEqual(model.count, 14)
        XCTAssertEqual(model.pill?.count, 14)
        XCTAssertEqual(model.pill?.label, "Any flag")
        XCTAssertEqual(model.pill?.isOn, true)
    }

    func testAnEmptyListIsEmptyOnlyOnceBothHalvesHaveAnswered() async throws {
        let model = fixture.makeModel()
        XCTAssertFalse(model.isEmpty)

        model.start()

        try await waitUntilOnMainActor { model.isEmpty }
        XCTAssertEqual(Fixture.names(model), [])
        XCTAssertEqual(model.count, 0)
    }

    // MARK: A restored window's open item

    func testARestoredWindowsItemIsFoundOnceItsRowHasLoaded() async throws {
        await fixture.source.answer(.any, with: Fixture.page([Fixture.mail(1, "2026-03-05T08:00:00Z")]))
        try await fixture.addItem("a", "2026-03-05T12:00:00+00:00")
        await fixture.source.holdNext()
        let model = fixture.makeModel()
        let article = ItemRef.feed(feedID: "f", sortKey: "a")
        let message = ItemRef.mail(MessageRef(folder: "INBOX", uid: 1))
        let gone = ItemRef.mail(MessageRef(folder: "INBOX", uid: 77))

        model.start()
        try await waitUntilOnMainActor { await self.fixture.source.isHolding }
        try await waitUntilOnMainActor { model.feedLoaded }

        // The article's row is on the device; the message's has not landed.
        guard case .found(.feed(let item)) = model.awaited(article) else { return XCTFail("the article is loaded") }
        XCTAssertEqual(item.sortKey, "a")
        XCTAssertEqual(model.awaited(message), .waiting)
        XCTAssertEqual(model.awaited(gone), .waiting)

        await fixture.source.release()
        await fixture.expect(model, shows: ["a", "m1"])
        guard case .found(.mail(let envelope, _)) = model.awaited(message) else {
            return XCTFail("the message is loaded")
        }
        XCTAssertEqual(envelope.uid, 1)
        XCTAssertEqual(model.awaited(gone), .gone, "both halves have answered without it")
    }
}
