import Foundation
import CabalmailKit

/// One main window's memory of the flag a list is narrowed to for the
/// visit: the pick made from the Flagged pill's menu (a flag of the user's
/// own, or any flag), which is never stored and never synced.
///
/// A list's view model does not outlive its view, and the same folder or
/// feed gets a new view more often than the user leaves it: a reader pushed
/// and popped on iPhone rebuilds the feed list's model; a layout swap, a
/// list moving below a laptop fold and the search field taking the column
/// rebuild the folder list's. So the pick is held here, above the lists,
/// and the next list for the same place opens on it. A list mounting for
/// another place is the visit's end: the window has moved on, and coming
/// back finds no pick. Quitting ends it too, since nothing here is saved.
///
/// A window has one for its folder list, keyed by folder path, and one for
/// its feed list, keyed by scope (`ListFlagPicks`). Not `@Observable`: no
/// view body reads it; a list reads it once, as its model is built.
@MainActor
final class FlagPickHold<Place: Hashable> {
    private var held: (place: Place, criterion: FlagCriterion)?

    /// The pick a list mounting for `place` opens on, if the window's last
    /// list there was on one. A list for anywhere else drops what was held.
    func take(for place: Place) -> FlagCriterion? {
        if held?.place != place { held = nil }
        return held?.criterion
    }

    /// The pick `place`'s list is now on; nil once it is on none.
    func set(_ criterion: FlagCriterion?, for place: Place) {
        held = criterion.map { (place, $0) }
    }
}

/// One main window's two holds: its folder list's and its feed list's. They
/// are apart because the lists are: looking at a feed does not end the visit
/// to the folder the window was on, nor the other way round. `SceneNavigator`
/// owns it.
@MainActor
final class ListFlagPicks {
    let mail = FlagPickHold<String>()
    let feed = FlagPickHold<RssItemScope>()
}
