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
/// Only the newest list writes. A list takes a `Visit` as its model is
/// built and records through it; a list the window has since replaced can
/// still be finishing its first load, and what that load settles on must
/// not put back a pick the window dropped, nor clear its successor's. The
/// same rule as `FolderListHold`'s claims.
///
/// A window has one hold for its folder list, keyed by folder path, and one
/// for its feed list, keyed by scope (`ListFlagPicks`). Not `@Observable`:
/// no view body reads it; a list reads it once, as its model is built.
@MainActor
final class FlagPickHold<Place: Hashable> {
    /// A list's turn at the hold: the pick it opens on, and its right to
    /// say what the pick becomes, for as long as it is the newest list.
    struct Visit {
        /// The pick the window's last list for this place was on, if any.
        let pick: FlagCriterion?
        fileprivate let hold: FlagPickHold
        fileprivate let place: Place
        fileprivate let turn: Int

        /// The pick this list is now on; nil once it is on none. Ignored
        /// from a list that is no longer the window's newest.
        @MainActor
        func record(_ criterion: FlagCriterion?) {
            guard hold.turn == turn else { return }
            hold.held = criterion.map { (place, $0) }
        }
    }

    private var held: (place: Place, criterion: FlagCriterion)?
    /// Counts the lists that have mounted; the newest one's is current.
    private var turn = 0

    /// A list is mounting for `place`. It opens on the pick the window's
    /// last list there was on, if there was one; a list for anywhere else
    /// drops what was held. Either way it is now the list that records.
    func take(for place: Place) -> Visit {
        if held?.place != place { held = nil }
        turn += 1
        return Visit(pick: held?.criterion, hold: self, place: place, turn: turn)
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
