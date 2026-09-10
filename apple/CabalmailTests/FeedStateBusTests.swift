import XCTest
import CabalmailKit
@testable import Cabalmail

/// The fan-out between the feed reader, list, and sidebar models: a post
/// reaches every live subscriber, a released owner falls out, and the
/// payload travels intact.
@MainActor
final class FeedStateBusTests: XCTestCase {
    private final class Owner {}

    private func item(read: Bool, favorite: Bool) -> RssItem {
        var item = RssItem(feedId: "feed", itemId: "abc", sortKey: "2026-09-10T00:00:00Z#abc", title: "t")
        item.isRead = read
        item.isFavorite = favorite
        return item
    }

    func testPostReachesEverySubscriberWithThePayload() {
        let bus = FeedStateBus()
        let first = Owner(), second = Owner()
        var seen: [RssItem?] = []
        bus.subscribe(first) { seen.append($0) }
        bus.subscribe(second) { seen.append($0) }
        bus.post(item(read: true, favorite: false))
        bus.post()
        XCTAssertEqual(seen.count, 4)
        XCTAssertEqual(seen[0]?.isRead, true)
        XCTAssertNil(seen[2])
        XCTAssertEqual(bus.liveCount, 2)
    }

    func testAReleasedOwnerStopsReceivingAndIsDropped() {
        let bus = FeedStateBus()
        var owner: Owner? = Owner()
        var calls = 0
        bus.subscribe(owner!) { _ in calls += 1 }
        bus.post()
        owner = nil
        bus.post()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(bus.liveCount, 0)
    }
}
