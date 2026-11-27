import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Which scope a search opens on and how long a pick lasts
/// (flags-and-cross-media.md, decision 17): the medium in front, All where
/// that is ambiguous, and a pick until the search is cleared.
final class SearchScopeStateTests: XCTestCase {

    func testASearchOpensOnTheMediumInFront() {
        var state = SearchScopeState()
        XCTAssertEqual(state.scope, .all, "nothing has said what is in front")

        state.noteFront(.feeds, searchInProgress: false)

        XCTAssertEqual(state.scope, .feeds)
    }

    func testASearchInProgressKeepsItsScopeWhateverComesInFront() {
        var state = SearchScopeState()
        state.noteFront(.mail, searchInProgress: false)

        state.noteFront(.feeds, searchInProgress: true)

        XCTAssertEqual(state.scope, .mail, "the search began over mail and is still that search")
    }

    func testAPickLastsUntilTheSearchIsCleared() {
        var state = SearchScopeState()
        state.noteFront(.mail, searchInProgress: false)
        state.pick(.all)
        XCTAssertEqual(state.scope, .all)

        state.noteFront(.mail, searchInProgress: true)
        XCTAssertEqual(state.scope, .all, "the pick holds while the search is in progress")

        state.searchEnded()
        XCTAssertEqual(state.scope, .mail, "and goes with the search: the next opens on the medium in front")
    }

    func testTheNextSearchOpensOnWhatCameInFrontMeanwhile() {
        var state = SearchScopeState()
        state.noteFront(.mail, searchInProgress: false)
        state.pick(.all)
        // The Search tab was left for Feeds and opened again, the old
        // search still in its field.
        state.noteFront(.feeds, searchInProgress: true)

        state.searchEnded()

        XCTAssertEqual(state.scope, .feeds)
    }

    func testAChangeOfLayoutKeepsTheScopeAndForgetsTheFront() {
        var state = SearchScopeState()
        state.noteFront(.feeds, searchInProgress: false)

        state.layoutChanged(searchInProgress: true)
        XCTAssertEqual(state.scope, .feeds, "the search the layout carries is still on Feeds")

        state.searchEnded()
        XCTAssertEqual(state.scope, .all, "what was in front of the old layout says nothing of the new one")
    }

    func testAChangeOfLayoutWithNoSearchLeavesNothingInFront() {
        var state = SearchScopeState()
        state.noteFront(.feeds, searchInProgress: false)

        state.layoutChanged(searchInProgress: false)

        XCTAssertEqual(state.scope, .all)
    }

    func testWithNoSearchTheScopeIsWhateverIsInFrontNow() {
        var state = SearchScopeState()
        state.noteFront(.mail, searchInProgress: false)
        state.pick(.all)
        state.searchEnded()

        // Nothing is said while the search is under way or as it ends:
        // what comes in front afterwards is still what the next opens on.
        state.noteFront(.feeds, searchInProgress: false)
        XCTAssertEqual(state.scope, .feeds)
        state.noteFront(.all, searchInProgress: false)
        XCTAssertEqual(state.scope, .all)
    }

    func testASearchStillOverWhatItBeganOverHoldsThatWhenSomethingElseComesInFront() {
        var state = SearchScopeState()
        state.noteFront(.feeds, searchInProgress: false)

        state.noteFront(.feeds, searchInProgress: true)
        state.noteFront(.mail, searchInProgress: true)
        state.noteFront(.all, searchInProgress: true)

        XCTAssertEqual(state.scope, .feeds)
    }

    // MARK: What is in front

    func testOnAWideLayoutTheListUnderTheFieldIsTheMedium() {
        XCTAssertEqual(SearchFront.wide(showsFlagged: false, hasFeedList: false, hasFolder: true), .mail)
        XCTAssertEqual(SearchFront.wide(showsFlagged: false, hasFeedList: true, hasFolder: false), .feeds)
        XCTAssertEqual(SearchFront.wide(showsFlagged: false, hasFeedList: false, hasFolder: false), .all,
                       "no list is no medium")
    }

    func testTheFlaggedViewIsBothMediaOnEveryLayout() {
        XCTAssertEqual(SearchFront.wide(showsFlagged: true, hasFeedList: false, hasFolder: true), .all)
        XCTAssertEqual(SearchFront.wide(showsFlagged: true, hasFeedList: true, hasFolder: false), .all)
        XCTAssertEqual(SearchFront.tab(.mail, showsFlagged: true), .all)
        XCTAssertEqual(SearchFront.tab(.feeds, showsFlagged: true), .all)
    }

    func testOnTheTabLayoutsTheTabSearchOpenedFromIsTheMedium() {
        XCTAssertEqual(SearchFront.tab(.mail, showsFlagged: false), .mail)
        XCTAssertEqual(SearchFront.tab(.folders, showsFlagged: false), .mail, "visionOS's folder list is mail's")
        XCTAssertEqual(SearchFront.tab(.feeds, showsFlagged: false), .feeds)
        XCTAssertEqual(SearchFront.tab(.addresses, showsFlagged: false), .all)
        XCTAssertEqual(SearchFront.tab(.settings, showsFlagged: false), .all)
        XCTAssertEqual(SearchFront.tab(.search, showsFlagged: false), .all)
    }

    func testEachScopeRunsTheMediaItNames() {
        XCTAssertEqual(SearchScope.allCases.map(\.title), ["All", "Mail", "Feeds"])
        XCTAssertEqual(SearchScope.allCases.map(\.includesMail), [true, true, false])
        XCTAssertEqual(SearchScope.allCases.map(\.includesFeeds), [true, false, true])
    }
}
