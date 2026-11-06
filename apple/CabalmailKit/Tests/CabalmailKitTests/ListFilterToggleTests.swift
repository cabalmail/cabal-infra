import XCTest
@testable import CabalmailKit

/// The list filter pills are toggles: All has no pill of its own and is what
/// the list shows with neither Unread nor Flagged lit.
final class ListFilterToggleTests: XCTestCase {
    func testMessagePillsLeaveOutAll() {
        XCTAssertEqual(MessageFilter.pills, [.unread, .flagged])
    }

    func testMessagePillTogglesOnFromAll() {
        XCTAssertEqual(MessageFilter.all.toggling(.unread), .unread)
        XCTAssertEqual(MessageFilter.all.toggling(.flagged), .flagged)
    }

    func testMessageLitPillTogglesOffToAll() {
        XCTAssertEqual(MessageFilter.unread.toggling(.unread), .all)
        XCTAssertEqual(MessageFilter.flagged.toggling(.flagged), .all)
    }

    func testMessageUnlitPillReplacesTheLitOne() {
        XCTAssertEqual(MessageFilter.unread.toggling(.flagged), .flagged)
        XCTAssertEqual(MessageFilter.flagged.toggling(.unread), .unread)
    }

    func testFeedPillsLeaveOutAll() {
        XCTAssertEqual(RssItemFilter.pills, [.unread, .favorite])
    }

    func testFeedPillsToggle() {
        XCTAssertEqual(RssItemFilter.all.toggling(.unread), .unread)
        XCTAssertEqual(RssItemFilter.unread.toggling(.unread), .all)
        XCTAssertEqual(RssItemFilter.favorite.toggling(.favorite), .all)
        XCTAssertEqual(RssItemFilter.unread.toggling(.favorite), .favorite)
    }
}
