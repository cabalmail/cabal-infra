import SwiftUI

/// Plays a message row out of the list in two legs — fade at full height,
/// then collapse to zero height — while the view model holds the envelope in
/// place. `MessageListViewModel.dispose(_:)` drops the envelope only once both
/// legs have run (see `beginRowDisposal`).
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
    let uid: UInt32
    let rowHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let phase = model.rowDisposalPhases[uid]
        content()
            .opacity(phase == nil ? 1 : 0)
            // No `.clipped()`: the row keeps its intrinsic `rowHeight` and
            // overflows this frame as it collapses, but it's fully transparent
            // by then, so there's nothing to clip — and settled rows (all of
            // them, nearly all the time) skip the clip cost.
            .frame(height: phase == .collapsing ? 0 : rowHeight, alignment: .top)
            // Hit testing goes off with the fade, so the second swipe this
            // animation exists to prevent can't land on the outgoing row.
            .allowsHitTesting(phase == nil)
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
