import XCTest
@testable import Cabalmail

// The feed sidebar's one pill: Unread toggles, and off is every feed. No
// All pill — it only restated "Unread off".
final class FeedListFilterTests: XCTestCase {
    func testFreshInstallOpensOnUnread() {
        XCTAssertEqual(FeedListFilter.defaultForFeeds, .unread)
        XCTAssertTrue(FeedListFilter.defaultForFeeds.unreadOnly)
    }

    func testThePillTogglesBetweenTheTwoStoredStates() {
        XCTAssertEqual(FeedListFilter.unread.toggled, .all)
        XCTAssertEqual(FeedListFilter.all.toggled, .unread)
        XCTAssertFalse(FeedListFilter.all.unreadOnly)
    }

    func testTheStoredFormSurvivesARelaunch() {
        XCTAssertEqual(FeedListFilter(rawValue: FeedListFilter.all.rawValue), .all)
        XCTAssertNil(FeedListFilter(rawValue: "favorite"), "an unknown stored value falls back to the default")
    }
}
