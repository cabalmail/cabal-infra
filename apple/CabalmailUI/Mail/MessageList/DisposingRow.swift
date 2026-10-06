import SwiftUI
import CabalmailKit

/// Plays a message row out of the list in two legs — fade at full height,
/// then collapse to zero height — while the view model holds the envelope in
/// place. `MessageListViewModel.dispose(_:)` drops the envelope only once both
/// legs have run (see `beginRowDisposal`), and in the same step hands the slot
/// a new row, so the next message doesn't inherit a full swipe's held-open
/// reveal (see `replaceRows(showing:)`).
///
/// Why an animation at all: the removal itself is instantaneous, and under the
/// index-addressed virtualized list it isn't even a row removal — every slot
/// below simply re-points at the next envelope — so the rows snap up with no
/// transition whatsoever. That reads as "nothing happened," which invites a
/// second swipe on whatever slid into the vacated spot. Fading first, at full
/// height, gives the eye something to catch before anything moves.
///
/// Why a separate view rather than modifiers on the row: this is where
/// `rowDisposalPhases` is read, so a phase flip invalidates only the realized
/// rows' wrappers. Read from `MessageListView`'s body instead, each flip would
/// re-run the entire list body — `filteredEnvelopes` (O(loaded rows)) and
/// every visible row with it.
struct DisposingRow<Content: View>: View {
    let model: MessageListViewModel
    /// The row's message. Keyed by ref, not UID, so disposing one of two
    /// search rows that share a UID plays only that row out.
    let ref: MessageRef
    let rowHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let phase = model.rowDisposalPhases[ref]
        content()
            .opacity(phase == nil ? 1 : 0)
            // No `.clipped()`: the row keeps its intrinsic `rowHeight` and
            // overflows this frame as it collapses, but it's fully transparent
            // by then, so there's nothing to clip — and settled rows (all of
            // them, nearly all the time) skip the clip cost.
            .frame(height: phase == .collapsing ? 0 : rowHeight, alignment: .top)
            // Hit testing goes off with the fade -- on EVERY row while any row
            // is leaving, not just the outgoing one. The outgoing row can't take
            // the second tap this animation exists to prevent, and the rows
            // below it can't take a touch either: when the envelope leaves they
            // all re-point to the next one, so a swipe begun on the row that
            // just slid under the thumb would reveal on the row beneath it. The
            // ~300ms this lasts is how long the next row takes to arrive anyway.
            // (A macOS trackpad swipe ignores hit testing and reaches the
            // leaving row's own slot, which re-points to the incoming message as
            // the collapse ends -- see `MessageListViewModel.dispose`.)
            .allowsHitTesting(!model.isDisposingRow)
            .animation(animation(for: phase), value: phase)
    }

    /// Animation for the leg the row is entering. `nil` for the return to the
    /// settled state, which covers the failed-write revert and — more
    /// importantly — the moment the envelope leaves `envelopes` and this slot
    /// re-points at the next one: that has to land at full height instantly,
    /// not animate the incoming row back open.
    private func animation(for phase: MessageListViewModel.RowDisposalPhase?) -> Animation? {
        switch phase {
        case .fading:
            .easeOut(duration: MessageListViewModel.rowFadeDuration)
        case .collapsing:
            .easeOut(duration: MessageListViewModel.rowCollapseDuration)
        case nil:
            nil
        }
    }
}
