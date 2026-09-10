import Foundation
import CabalmailKit

/// Fan-out for feed state changes between sibling view models.
///
/// The reader, the item list, and the sidebar each hold their own snapshot
/// of `RssStore`. When one of them changes an item's read or favorite state,
/// or refetches a scope, the others learn of it here instead of re-reading
/// the store on a timer: the list patches the row in place, the sidebar
/// re-reads its unread counts, and the reader updates its toolbar if the
/// change was to the item it is showing.
///
/// Subscribers are held weakly and dropped on the next post once their owner
/// is gone, so a model never has to unsubscribe (a `deinit` on a main-actor
/// class cannot call back into the actor under strict concurrency).
@MainActor
final class FeedStateBus {
    static let shared = FeedStateBus()

    /// A changed item, or nil when the change is broader (a sync, a
    /// mark-all-read), in which case counts should be re-read from the store.
    typealias Handler = @MainActor (RssItem?) -> Void

    private struct Subscriber {
        weak var owner: AnyObject?
        let handler: Handler
    }

    /// The catalog itself changed (a subscription or folder was added,
    /// edited, or removed): the sidebar re-reads folders and subscriptions.
    typealias CatalogHandler = @MainActor () -> Void

    private struct CatalogSubscriber {
        weak var owner: AnyObject?
        let handler: CatalogHandler
    }

    private var subscribers: [Subscriber] = []
    private var catalogSubscribers: [CatalogSubscriber] = []

    init() {}

    func subscribe(_ owner: AnyObject, _ handler: @escaping Handler) {
        subscribers.append(Subscriber(owner: owner, handler: handler))
    }

    func subscribeCatalog(_ owner: AnyObject, _ handler: @escaping CatalogHandler) {
        catalogSubscribers.append(CatalogSubscriber(owner: owner, handler: handler))
    }

    func post(_ item: RssItem? = nil) {
        subscribers.removeAll { $0.owner == nil }
        for subscriber in subscribers { subscriber.handler(item) }
    }

    func postCatalogChanged() {
        catalogSubscribers.removeAll { $0.owner == nil }
        for subscriber in catalogSubscribers { subscriber.handler() }
    }

    /// Subscribers whose owner is still alive, for tests.
    var liveCount: Int { subscribers.filter { $0.owner != nil }.count }
}
