import Foundation
import CabalmailKit

/// What a feed list is narrowed to: the pill that is lit and, under
/// Flagged, the flag picked from that pill's menu.
///
/// The pill is the scope's sticky choice (`RssItemFilter`, a wire value the
/// feed's row and the all-feeds preference store). A pick is not: a flag of
/// the user's own, or any flag, lasts for the visit and is written nowhere,
/// so it cannot be a filter case and sits beside the filter here. While one
/// is in force the Flagged pill is lit over it, and the built-in flag, which
/// is what that pill means on its own, is never a pick.
struct FeedListNarrowing: Equatable {
    private(set) var filter: RssItemFilter
    private(set) var pick: FlagCriterion?

    /// - Parameter pick: the flag picked from the Flagged pill's menu. Any
    ///   flag or one of the palette's own slots lights Flagged over it,
    ///   whatever `filter` says; the built-in flag's slot is the Flagged
    ///   pill itself; anything else is no pick.
    init(filter: RssItemFilter, pick: FlagCriterion? = nil) {
        if let pick, pick == .any || pick.keywordSlot != nil {
            self.filter = .favorite
            self.pick = pick
        } else {
            self.filter = pick?.isSystemFlag == true ? .favorite : filter
        }
    }

    /// What the Flagged pill is lit on, for its menu's checkmark: nothing,
    /// the built-in flag, or the pick.
    var current: FlagCriterion? {
        pick ?? (filter == .favorite ? .slot(FlagPalette.systemSlot) : nil)
    }

    /// One page of the list. A pick is the one criterion: it stands in
    /// place of the pill's own, not beside it. Built here for the first
    /// page and every later one, so a page cannot be read under another
    /// filter than the rows above it.
    func query(
        scope: RssItemScope, ordering: RssOrderingMode, limit: Int, after last: RssItem? = nil
    ) -> RssStore.ItemQuery {
        RssStore.ItemQuery(
            scope: scope, filter: pick == nil ? filter : .all, flag: pick, ordering: ordering, limit: limit,
            after: last.map(RssStore.ItemCursor.init(after:))
        )
    }

    /// What a row of the Flagged pill's menu leaves the list on, and the
    /// pill to record for the scope with it. The built-in flag's row is the
    /// Flagged pill as it always was, and Clear filter is All; both are
    /// recorded, as a tap on a pill is. A flag of the user's own and Any
    /// flag are picks, and record nothing (nil): the scope reopens on the
    /// pill it had.
    func choosing(_ choice: FlagFilterChoice) -> (narrowing: FeedListNarrowing, recorded: RssItemFilter?) {
        guard let criterion = FlagFilterMenuPolicy.criterion(for: choice) else {
            return (FeedListNarrowing(filter: .all), .all)
        }
        let next = FeedListNarrowing(filter: filter, pick: criterion)
        // A string that is no slot of the palette changes nothing.
        guard next.pick != nil || criterion.isSystemFlag else { return (self, nil) }
        return (next, next.pick == nil ? .favorite : nil)
    }

    // MARK: - An empty list's words

    /// Under the Flagged pill with nothing to show: the title. Any flag,
    /// and the pill's own built-in filter, keep the plain words; a picked
    /// flag is named.
    static func emptyTitle(pick: FlagCriterion?, name: String) -> String {
        guard let pick, pick != .any else { return "No flagged items" }
        return "No items marked \(name)"
    }

    /// The line under that title, for a pick. The swipe is offered when it
    /// sets the flag shown, and always under Any flag, where whatever it
    /// sets shows; a flag gone from Settings > Flags can no longer be set
    /// at all.
    static func emptyDescription(pick: FlagCriterion, name: String, swipeSetsIt: Bool, isInPalette: Bool) -> String {
        if pick == .any || swipeSetsIt { return "Swipe an item or use its menu to flag it." }
        guard isInPalette else { return "This flag was deleted." }
        return "Use an item's Flags menu to mark it \(name)."
    }
}
