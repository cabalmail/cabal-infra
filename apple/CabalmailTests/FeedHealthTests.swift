import XCTest
import CabalmailKit
@testable import Cabalmail

/// The sidebar's health badge: quiet below three failures, a warning from
/// three, stopped at twenty or when the fetcher dead-lettered the feed.
final class FeedHealthTests: XCTestCase {
    private func feed(failures: Int, dead: Bool = false, error: String = "") -> RssFeedSummary {
        var feed = RssFeedSummary(feedId: "f", canonicalUrl: "https://example.com/feed", title: "Example")
        feed.consecutiveFailureCount = failures
        feed.deadLettered = dead
        feed.lastError = error
        return feed
    }

    func testThresholds() {
        XCTAssertEqual(FeedHealth.level(for: nil), .healthy)
        XCTAssertEqual(FeedHealth.level(for: feed(failures: 0)), .healthy)
        XCTAssertEqual(FeedHealth.level(for: feed(failures: 2)), .healthy)
        XCTAssertEqual(FeedHealth.level(for: feed(failures: 3)), .failing(3))
        XCTAssertEqual(FeedHealth.level(for: feed(failures: 19)), .failing(19))
        XCTAssertEqual(FeedHealth.level(for: feed(failures: 20)), .stopped)
        XCTAssertEqual(FeedHealth.level(for: feed(failures: 1, dead: true)), .stopped)
    }

    func testBadgeWordingAndSymbols() {
        XCTAssertNil(FeedHealthLevel.healthy.symbol)
        XCTAssertNil(FeedHealthLevel.healthy.summary)
        XCTAssertEqual(FeedHealthLevel.failing(4).summary, "Failing: 4 fetches in a row")
        XCTAssertEqual(FeedHealthLevel.failing(4).symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(FeedHealthLevel.stopped.symbol, "xmark.octagon.fill")
    }

    func testHeadlineAppendsTheFetchersWords() {
        XCTAssertNil(FeedHealth.headline(for: feed(failures: 1, error: "HTTP 404")))
        XCTAssertEqual(FeedHealth.headline(for: feed(failures: 3, error: " http_404: HTTP 404 from https://a.example/feed ")),
                       "Failing: 3 fetches in a row. http_404: HTTP 404 from https://a.example/feed")
        XCTAssertEqual(FeedHealth.headline(for: feed(failures: 25)), "Stopped: the fetcher gave up on this feed")
    }
}
