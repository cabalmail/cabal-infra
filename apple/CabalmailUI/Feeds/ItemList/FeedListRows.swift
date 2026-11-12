import Foundation
import Observation
import CabalmailKit

/// The rows a feed list shows and the marks on them: a control's change
/// drawn at once and written through the sync engine, the re-read of a row
/// the store says changed, and the "queued" mark while a change waits for
/// the network.
///
/// The list's model (`FeedItemListViewModel`) decides which rows these are:
/// the scope, the pill, the order and the pages. This type keeps each one
/// truthful once it is on screen. It belongs to the model, so a list that
/// takes a moved list's model over (`FeedListHold`) keeps its rows.
@Observable
@MainActor
final class FeedListRows {
    var items: [RssItem] = []
    /// Items with a queued (not yet pushed) state change, for the row mark.
    private(set) var pendingIds: Set<String> = []

    private let store: RssStore?
    private let engine: RssSyncEngine?

    init(store: RssStore?, engine: RssSyncEngine?) {
        self.store = store
        self.engine = engine
    }

    /// A control's mark on a row. Optimistic: the row changes at once, the
    /// engine writes the store and pushes, and the row then takes what the
    /// store holds, with its queued mark.
    func mark(_ item: RssItem, _ mark: FeedItemMark) async {
        guard let engine else { return }
        replace(item) { $0.apply(mark) }
        try? await engine.write(mark, to: item)
        await patch([item.id])
    }

    /// Sets the flag in palette slot `slot` on an item that lacks it and
    /// clears it on one that carries it. Judged by what the store holds
    /// rather than by the caller's copy: the open item's copy is refreshed
    /// from its row, and once a reload has dropped that row (a read item
    /// under Unread) a second press would otherwise set the flag again.
    func toggleFlag(slot: String, on item: RssItem) async {
        let stored = (try? await store?.item(feedId: item.feedId, sortKey: item.sortKey)) ?? nil
        await mark(item, .flag(slot: slot, isSet: !(stored ?? item).carries(slot: slot)))
    }

    /// Re-reads the rows the store says changed: their read state, their
    /// flags and the queued mark. A flag the server refused, which the
    /// drain takes off the item again, leaves its row this way.
    func patch(_ ids: Set<String>) async {
        guard let store else { return }
        for row in items where ids.contains(row.id) {
            let fresh = (try? await store.item(feedId: row.feedId, sortKey: row.sortKey)) ?? nil
            let queued = (try? await store.hasPending(feedId: row.feedId, sortKey: row.sortKey)) == true
            if let fresh, row.marksDiffer(from: fresh) {
                replace(row) { $0.takeMarks(from: fresh) }
            }
            if queued { pendingIds.insert(row.id) } else { pendingIds.remove(row.id) }
        }
    }

    /// The queued mark of every row, after the list has read a page.
    func refreshPendingMarks() async {
        guard let store else { return }
        var pending: Set<String> = []
        for item in items where (try? await store.hasPending(feedId: item.feedId, sortKey: item.sortKey)) == true {
            pending.insert(item.id)
        }
        pendingIds = pending
    }

    private func replace(_ item: RssItem, _ change: (inout RssItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        change(&items[index])
    }
}
