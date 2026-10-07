import Foundation
import CabalmailKit

/// What a burst of `RssStore` changes adds up to: the items and feeds that
/// moved, and whether the catalog changed or everything went. A feed view
/// model applies one batch with one re-read, however many writes made it.
struct FeedChangeBatch: Equatable {
    /// `RssItem.id`s whose read or flag state, or queued mark, changed.
    var items: Set<String> = []
    /// Feed ids whose items or read state moved wholesale.
    var feeds: Set<String> = []
    var catalog = false
    var cleared = false

    var isEmpty: Bool { items.isEmpty && feeds.isEmpty && !catalog && !cleared }

    mutating func add(_ change: RssStore.Change) {
        switch change {
        case .items(let ids): items.formUnion(ids)
        case .feeds(let ids): feeds.formUnion(ids)
        case .catalog: catalog = true
        case .cleared: cleared = true
        }
    }
}

/// How the feed view models follow the store. The sidebar, the item list and
/// the reader each read their own snapshot of `RssStore`, and each re-reads
/// when the store says it moved, whoever moved it: their own actions,
/// another window, the sync engine, another device's marks arriving by state
/// sync.
@MainActor
enum FeedStoreChanges {
    /// Follows `changes` for a view model's `observe()`. Changes that arrive
    /// while `apply` is still working on the last batch are merged into the
    /// next one, so a burst (a sync's pages and cursors, a catalog and its
    /// feeds) costs one re-read rather than one per write. Returns when the
    /// stream ends (the store went) or the calling task is cancelled (the
    /// view went). Both loops are that task's children, so nothing outlives
    /// it and no view model owns a task.
    static func follow(
        _ changes: AsyncStream<RssStore.Change>,
        apply: (FeedChangeBatch) async -> Void
    ) async {
        let pending = PendingFeedChanges()
        let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await change in changes {
                    pending.batch.add(change)
                    signal.yield()
                }
                signal.finish()
            }
            for await _ in ready {
                let batch = pending.take()
                if !batch.isEmpty { await apply(batch) }
            }
            group.cancelAll()
        }
    }
}

/// The batch building up while the last one is applied.
@MainActor
private final class PendingFeedChanges {
    var batch = FeedChangeBatch()

    func take() -> FeedChangeBatch {
        defer { batch = FeedChangeBatch() }
        return batch
    }
}
