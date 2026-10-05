import XCTest
@testable import CabalmailKit

#if canImport(Network)
/// `Reachability`'s stream contract, and #1809: a signed-out session's
/// monitor must not keep running because something still holds one of its
/// streams. The client that owns it is released on sign-out; the send queue
/// and the offline banners are the stream holders that outlive it.
final class ReachabilityTests: XCTestCase {
    /// A new subscriber hears the current status at once, before any
    /// transition.
    func testASubscriberHearsTheCurrentStatusFirst() async {
        let reachability = Reachability()
        var iterator = reachability.changes().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertNotNil(first)
    }

    func testEndedSubscriptionsUnregister() async {
        let reachability = Reachability()
        let stream = reachability.changes()
        XCTAssertEqual(reachability.subscriberCount, 1)

        let consumer = Task { for await _ in stream {} }
        consumer.cancel()
        await consumer.value
        XCTAssertEqual(reachability.subscriberCount, 0, "a cancelled consumer unregisters")

        _ = reachability.changes()
        XCTAssertEqual(reachability.subscriberCount, 0, "a stream nobody keeps unregisters at once")
    }

    /// #1809. The stream's termination handler used to hold the monitor
    /// strongly, so a live subscriber kept a released session's monitor (and
    /// its `NWPathMonitor`) running until the subscriber next woke and gave
    /// up. Now releasing the owner frees it and finishes the stream.
    func testLiveSubscriptionDoesNotKeepReachabilityAlive() async throws {
        weak var subscribed: Reachability?
        let stream: AsyncStream<Bool>
        do {
            let reachability = Reachability()
            subscribed = reachability
            stream = reachability.changes()
        }
        // A path update in flight on the monitor's queue holds the monitor
        // for the length of the callback, so allow it to drain.
        try await waitUntil { subscribed == nil }
        let finishedByTheMonitor = await finishesWithoutCancelling(stream)
        XCTAssertTrue(finishedByTheMonitor, "releasing the monitor did not finish its live stream")
    }
}
#endif
