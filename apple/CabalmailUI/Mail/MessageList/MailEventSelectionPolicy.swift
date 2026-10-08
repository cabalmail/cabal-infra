import Foundation
import Observation
import CabalmailKit

/// What one list's selection may have to do about a mail event that named
/// rows it holds, worked out by its view model when the event arrived, while
/// the rows were still there to walk from (`MessageListViewModel.receive`).
/// Each view showing the list decides with `MailEventSelectionPolicy`, since
/// it owns the selection on compact layouts.
struct ListSelectionReaction: Equatable {
    enum Kind: Equatable {
        /// The rows left the list (`.removed`): a selection on them moves to
        /// `target`, the row the after-dispose preference picked, or clears
        /// when there is none.
        case removal
        /// The reader marked the row read and asked to move on
        /// (`.readAdvance`): the selection moves to `target`, and stays put
        /// when there is none.
        case readAdvance
        /// A compose session retired the Drafts copies in `rows`
        /// (`.draftReplaced`); `loadedUIDs` are the folder's rows loaded once
        /// the list refreshed for the survivor. `DraftReplacementPolicy`
        /// decides.
        case draftReplacement(DraftReplacement, loadedUIDs: [UInt32])
    }

    let kind: Kind
    /// The event's rows in this list. A selection off them never moves.
    let rows: Set<MessageRef>
    let target: MessageRef?
    /// The window that started the event (`MailEvent.origin`).
    let origin: UUID?
}

/// Whose selection moves when the reader or the composer changes mail, and
/// where to (#1845).
///
/// A list's selection moves only when it is on the event's row. The window
/// the user acted in advances, per their preference; a list in any other
/// window lets go of the row without advancing, so acting in one window
/// never moves another window's reader. A change no main window started (a
/// compose window's send or save) advances every window whose selection is
/// on the row, as before. Mark-read-and-advance belongs to its window alone:
/// another window's list leaves its selection where it is.
enum MailEventSelectionPolicy {
    /// What a list view does with the reactions it hasn't applied yet,
    /// oldest first: the rows it selects (wide layouts) and the message its
    /// reader shows (`shown`, nil for none). Nil when nothing moves.
    ///
    /// The view's selection is its selected rows, or, on a wide layout whose
    /// selected rows are empty, the reader's own message, as the shortcuts
    /// read it: a list rebuilt under an open reader (a search ended) or a
    /// compact selection carried into a wide window has no selected rows,
    /// yet its reader is on the row. The reactions are worked through in
    /// refs and only the end result is shown, since a later reaction may
    /// have pruned an earlier one's target before the view applies either.
    static func update(
        after reactions: [ListSelectionReaction],
        selectedRefs: Set<MessageRef>,
        shown: MessageRef?,
        isWideLayout: Bool,
        in window: UUID?
    ) -> ListSelectionUpdate? {
        var selection = isWideLayout && !selectedRefs.isEmpty ? selectedRefs : Set(shown.map { [$0] } ?? [])
        var moved = false
        for reaction in reactions {
            guard let next = self.selection(after: reaction, current: selection, in: window) else { continue }
            selection = next
            moved = true
        }
        guard moved else { return nil }
        return ListSelectionUpdate(
            selectedRefs: isWideLayout ? selection : selectedRefs,
            shown: selection.count == 1 ? selection.first : nil
        )
    }

    /// The selection a list in `window` should have after `reaction`, given
    /// its `current` one; nil leaves the selection as it is.
    static func selection(
        after reaction: ListSelectionReaction,
        current: Set<MessageRef>,
        in window: UUID?
    ) -> Set<MessageRef>? {
        let named = current.intersection(reaction.rows)
        guard !named.isEmpty else { return nil }
        let advances = reaction.origin == nil || reaction.origin == window
        // Only a selection wholly on the event's rows (the reader's message)
        // moves on; a larger selection just loses the rows that went.
        let isOnTheRow = named == current
        switch reaction.kind {
        case .removal:
            guard advances, isOnTheRow else { return current.subtracting(named) }
            return reaction.target.map { [$0] } ?? []
        case .readAdvance:
            guard advances, isOnTheRow, let target = reaction.target else { return nil }
            return [target]
        case .draftReplacement(let replacement, let loadedUIDs):
            guard advances, isOnTheRow, named.count == 1, let displayed = named.first else {
                return current.subtracting(named)
            }
            switch DraftReplacementPolicy.resolve(
                displayedUID: displayed.uid,
                replacement: replacement,
                loadedUIDs: loadedUIDs
            ) {
            case .ignore:
                return nil
            case .dismiss:
                return []
            case .repoint(let uid):
                return [MessageRef(folder: displayed.folder, uid: uid)]
            }
        }
    }
}

/// A list view's selection after `MailEventSelectionPolicy.update`.
struct ListSelectionUpdate: Equatable {
    /// The rows selected: what a wide layout's reader follows.
    let selectedRefs: Set<MessageRef>
    /// The message the reader shows, nil for none.
    let shown: MessageRef?
}

/// The selection reactions a list's view model has worked out from mail
/// events, for the views showing it to apply. Kept in order and never
/// coalesced, so two events in one update both reach the selection, and
/// never handed out once only: each view keeps its own place (`since`), so a
/// model two windows show at once (the search surface's, which every window
/// shares) reaches both, each deciding for its own window.
@Observable
@MainActor
final class ListSelectionReactions {
    /// The latest reaction's number, moving on every `append`; the views
    /// observe it, and keep the one they have applied up to.
    private(set) var tick = 0
    @ObservationIgnored private var kept: [(tick: Int, reaction: ListSelectionReaction)] = []

    /// How many are kept: a view that has fallen this far behind (one that
    /// wasn't on screen) can only be helped by the latest, which are the
    /// ones that can still name what it has selected.
    static let limit = 16

    func append(_ reaction: ListSelectionReaction) {
        tick += 1
        kept.append((tick, reaction))
        if kept.count > Self.limit {
            kept.removeFirst(kept.count - Self.limit)
        }
    }

    /// The reactions after `applied` (a view's place), oldest first.
    func since(_ applied: Int) -> [ListSelectionReaction] {
        kept.filter { $0.tick > applied }.map(\.reaction)
    }
}
