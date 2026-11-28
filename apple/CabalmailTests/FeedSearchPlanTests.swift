import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the feed half of a search does with the mail search's term and
/// filters (flags-and-cross-media.md, decision 17): four filters narrow an
/// article as they narrow a message, and any other stops the feed half.
final class FeedSearchPlanTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    func testATermAloneSearchesWithIt() {
        let plan = FeedSearchPlan(text: "  ferry  ", filters: MessageSearchFilters())

        XCTAssertEqual(plan, .search(RssStore.ItemSearch(text: "ferry")))
    }

    func testTheFourSharedFiltersReachTheFeedSearch() {
        var filters = MessageSearchFilters()
        filters.unread = true
        filters.flagged = true
        filters.since = day
        filters.before = day.addingTimeInterval(86_400)

        let plan = FeedSearchPlan(text: "ferry", filters: filters)

        XCTAssertEqual(plan, .search(RssStore.ItemSearch(
            text: "ferry", unread: true, flag: .slot(FlagPalette.systemSlot), since: day,
            before: day.addingTimeInterval(86_400)
        )))
    }

    func testTheSharedFiltersSearchWithNoTermAtAll() {
        var filters = MessageSearchFilters()
        filters.unread = true

        XCTAssertEqual(FeedSearchPlan(text: "", filters: filters), .search(RssStore.ItemSearch(unread: true)))
    }

    func testAFlagPickIsTheCriterionAsItStands() {
        var filters = MessageSearchFilters()
        filters.flag = .any

        XCTAssertEqual(FeedSearchPlan(text: "", filters: filters).search?.flag, .any)
    }

    func testNothingToMatchOnIsNoSearch() {
        XCTAssertEqual(FeedSearchPlan(text: "   ", filters: MessageSearchFilters()), .nothing)
        XCTAssertEqual(FeedSearchPlan(text: "\"", filters: MessageSearchFilters()), .nothing,
                       "text the index reads no word in")
    }

    func testEachMailOnlyFilterStopsTheFeedHalf() {
        let setters: [(FeedSearchPlan.MailOnlyFilter, (inout MessageSearchFilters) -> Void)] = [
            (.from, { $0.from = "a@example.com" }),
            (.to, { $0.to = "b@example.com" }),
            (.subject, { $0.subject = "invoice" }),
            (.hasAttachment, { $0.hasAttachment = true }),
            (.thisFolderOnly, { $0.thisFolderOnly = true }),
        ]
        for (filter, set) in setters {
            var filters = MessageSearchFilters()
            set(&filters)
            XCTAssertEqual(FeedSearchPlan(text: "ferry", filters: filters), .blocked([filter]), "\(filter)")
        }
        XCTAssertEqual(setters.map(\.0), FeedSearchPlan.MailOnlyFilter.allCases, "every mail-only filter is tried")
    }

    func testSeveralAreNamedInTheSheetsOrder() {
        var filters = MessageSearchFilters()
        filters.hasAttachment = true
        filters.from = "a@example.com"
        filters.unread = true

        XCTAssertEqual(FeedSearchPlan(text: "ferry", filters: filters), .blocked([.from, .hasAttachment]))
    }

    func testClearingTheMailOnlyFiltersKeepsTheSharedOnes() {
        var filters = MessageSearchFilters()
        filters.from = "a@example.com"
        filters.to = "b@example.com"
        filters.subject = "invoice"
        filters.hasAttachment = true
        filters.thisFolderOnly = true
        filters.unread = true
        filters.since = day

        let cleared = FeedSearchPlan.clearingMailOnly(filters)

        var expected = MessageSearchFilters()
        expected.unread = true
        expected.since = day
        XCTAssertEqual(cleared, expected)
        XCTAssertEqual(FeedSearchPlan.mailOnly(in: cleared), [])
    }
}
