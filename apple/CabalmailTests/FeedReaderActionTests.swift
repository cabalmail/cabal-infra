import XCTest
@testable import Cabalmail

/// The feed reader's toolbar order is shared between the live toolbar and
/// the macOS empty pane's stand-ins; pin it so a reorder in one place is a
/// deliberate change in both.
final class FeedReaderActionTests: XCTestCase {
    func testOrderMatchesTheReaderToolbar() {
        XCTAssertEqual(FeedReaderAction.allCases,
                       [.read, .favorite, .readerMode, .remoteContent, .article, .more])
    }

    func testEveryActionHasAnIdentifierSymbolAndTitle() {
        for action in FeedReaderAction.allCases {
            XCTAssertEqual(action.identifier, "feed.reader.\(action.rawValue)")
            XCTAssertFalse(action.quiescentSymbol.isEmpty)
            XCTAssertFalse(action.quiescentTitle.isEmpty)
        }
    }
}
