import Foundation

/// What a range selection — a shift-click, or a Shift+Up/Down — leaves
/// selected.
///
/// A pure rule rather than an inline `Set(ordered[lower...upper])` in
/// `MessageListView+Selection`, for the same reason `CompactColumnPolicy` is
/// one: both call sites sit inside a click gesture and a key handler whose
/// state a unit test cannot reach, and this can.
///
/// The rule is the platform's, not ours. An `NSTableView` — Finder, Mail —
/// treats the shift-extended run as one *replaceable* span laid over
/// whatever else is selected: rows picked with command outside the span keep
/// their selection, and a following shift-click re-pivots from the same
/// anchor and replaces the span rather than accumulating. Assigning the span
/// wholesale got the span itself right and silently discarded everything
/// else (#1768: `{367, 369, 313}` plus a shift-click one row down became
/// `{313, 312}`), so the span is unioned onto the selection that was in
/// force when the anchor was pinned.
///
/// Generic over the row identity: the message list passes `MessageRef`s, so
/// two rows that share a UID (a cross-folder search) are two rows here too.
enum RangeSelectionPolicy {
    /// The selection after a range operation, and the anchor to adopt.
    struct Outcome<ID: Hashable>: Equatable {
        let selected: Set<ID>
        /// Non-nil only when the anchor could not be resolved, in which case
        /// `target` becomes the new pivot. The anchor otherwise stays put,
        /// which is what lets a second shift-click replace the first's span.
        let newAnchor: ID?
    }

    /// Extend from `anchor` to `target` over `ordered` (the visible rows in
    /// display order).
    ///
    /// `base` is the selection in force when `anchor` was pinned
    /// (`MessageListViewModel.selectionRangeBase`), deliberately not the
    /// current selection: an earlier shift-click's span has to be replaced by
    /// this one, and unioning onto the live selection would grow it instead.
    static func outcome<ID: Hashable>(
        base: Set<ID>,
        anchor: ID?,
        target: ID,
        ordered: [ID]
    ) -> Outcome<ID> {
        guard let anchor,
              let anchorIndex = ordered.firstIndex(of: anchor),
              let targetIndex = ordered.firstIndex(of: target)
        else {
            // No pivot to extend from — a row off the visible run, or no
            // anchor at all. A lone selection is the honest answer and is
            // what both call sites already did.
            return Outcome(selected: [target], newAnchor: target)
        }
        let span = ordered[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)]
        return Outcome(selected: base.union(span), newAnchor: nil)
    }
}
