import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The feed reader's own bar where it fills a window taller than wide
/// (`FeedReaderToolbarLayout.tallBar`), and its page buttons.
@MainActor
final class FeedReaderTallBarTests: XCTestCase {
    /// Flag, Read, Page Up, Page Down, View, Compose: the iPhone Duo spec's
    /// tall-window order without the mail reader's Reply and Archive.
    func testTheTallBarIsTheSpecsOrder() {
        XCTAssertEqual(FeedReaderToolbarLayout.tallBar, [
            .action(.favorite), .action(.read), .page(.upward), .page(.downward), .action(.more), .compose
        ])
    }

    /// The navigation bar draws none of its items while this bar is up, so
    /// every one of them has to be here, and no identifier twice.
    func testTheTallBarCarriesTheTouchBarAndNoIdentifierTwice() {
        let actions = FeedReaderToolbarLayout.tallBar.compactMap { slot -> FeedReaderAction? in
            if case .action(let action) = slot { return action }
            return nil
        }
        XCTAssertTrue(Set(FeedReaderToolbarLayout.menuBar).isSubset(of: Set(actions)))
        let identifiers = FeedReaderToolbarLayout.tallBar.map(\.identifier)
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(identifiers.contains("feed.reader.pageUp"))
        XCTAssertTrue(identifiers.contains("feed.reader.compose"))
    }

    /// The macOS stand-ins still draw every reader action and nothing the
    /// tall bar adds.
    func testThePageButtonsAndComposeAreNotReaderActions() {
        XCTAssertEqual(Set(FeedReaderToolbarLayout.standIns()), Set(FeedReaderAction.allCases))
    }

    func testThePageButtonsPageWhateverIsOnScreen() {
        XCTAssertTrue(FeedReaderToolbarLayout.pagingEnabled(showingArticle: true, hasFeedContent: false))
        XCTAssertTrue(FeedReaderToolbarLayout.pagingEnabled(showingArticle: false, hasFeedContent: true))
        XCTAssertFalse(FeedReaderToolbarLayout.pagingEnabled(showingArticle: false, hasFeedContent: false))
    }

    func testEveryPressIsANewRequest() {
        let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k", url: "https://example.com/post",
                           summaryHtml: "<p>hi</p>")
        let model = FeedItemDetailViewModel(item: item, subscription: nil, engine: nil,
                                            preferences: Preferences(store: InMemoryPreferenceStore()))
        XCTAssertNil(model.pageRequest)

        model.requestPage(.downward)
        model.requestPage(.upward)

        XCTAssertEqual(model.pageRequest, ReaderPageRequest(direction: .upward, tick: 2))
    }
}
