import WebKit
import XCTest
@testable import CabalmailUI

/// The feed article view's navigation gestures on the Mac. iOS and visionOS
/// have had the back/forward swipe since the view shipped; macOS left it off,
/// so a two-finger trackpad swipe did nothing on the publisher's page.
@MainActor
final class ArticleWebViewGestureTests: XCTestCase {
    func testTheArticleViewSwipesBetweenPages() throws {
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let coordinator = ArticleWebCoordinator(onFailure: { _ in }, onLeftReader: {})
        XCTAssertTrue(coordinator.makeWebView(url: url, dataStoreID: nil).allowsBackForwardNavigationGestures)
    }
}
