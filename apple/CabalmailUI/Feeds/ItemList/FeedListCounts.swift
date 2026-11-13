import Foundation
import Observation
import CabalmailKit

/// The numbers on a feed list's pills: what All, Unread and Flagged count
/// for the scope and, while the list is narrowed to a flag picked from the
/// Flagged pill's menu, how many items carry that flag. All of them count
/// the items the device holds.
///
/// The list's model (`FeedItemListViewModel`) says when to count again: a
/// reload, a mark made on a row, a change in the store. This type reads the
/// store and keeps each number honest about what it is a count of.
@Observable
@MainActor
final class FeedListCounts {
    /// What the pills count; nil until the first read.
    private(set) var filter: RssStore.FilterCounts?
    /// The picked flag's count, with the pick it was counted for.
    private var picked: (pick: FlagCriterion, count: Int)?

    private let store: RssStore?
    private let scope: RssItemScope

    init(store: RssStore?, scope: RssItemScope) {
        self.store = store
        self.scope = scope
    }

    /// The number for a pill lit on `pick`; nil with no pick, and until
    /// the store has counted for this very one. A count read for the flag
    /// picked before is not this flag's, however briefly it would show.
    func count(for pick: FlagCriterion?) -> Int? {
        guard let pick, picked?.pick == pick else { return nil }
        return picked?.count
    }

    /// Counts again. A read that fails leaves the numbers as they were.
    func read(pick: FlagCriterion?) async {
        guard let store else { return }
        filter = (try? await store.filterCounts(in: scope)) ?? filter
        guard let pick, let count = try? await store.flagCount(in: scope, matching: pick) else { return }
        picked = (pick, count)
    }
}
