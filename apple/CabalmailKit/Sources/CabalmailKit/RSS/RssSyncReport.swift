import Foundation

/// What one sync pass did (`RssSyncEngine.syncAll` or a scope sync), with
/// its failures kept apart by kind. `syncAll` used to fold its catalog and
/// pending-queue failures in with the feeds', so the Feeds sidebar's "every
/// feed failed" check counted them as feeds (#1904).
public struct RssSyncReport: Sendable {
    /// The catalog could not be fetched (`syncAll`, which then stops) or read
    /// from the store (a scope sync, which then syncs no feed).
    public var catalogError: Error?
    /// The subscriptions the pass synced, in store order.
    public var subscriptionIds: [String] = []
    /// The feeds that failed, by subscription id.
    public var feedErrors: [String: Error] = [:]
    /// The pending queue's drain failed; the queue stays for the next one.
    public var pendingError: Error?

    public init() {}

    /// The pass tried at least one feed and every one failed, which almost
    /// always means the device is offline.
    public var everyFeedFailed: Bool {
        !subscriptionIds.isEmpty && subscriptionIds.allSatisfy { feedErrors[$0] != nil }
    }

    /// The first failed feed's error in store order, so the one line a view
    /// shows doesn't depend on dictionary order.
    public var firstFeedError: Error? {
        subscriptionIds.lazy.compactMap { feedErrors[$0] }.first
    }
}
