import SwiftUI
import CabalmailKit

// The configurable swipe edges of a message row: which `SwipeActionSpec`
// each edge reveals follows the synced `swipeLeading` / `swipeTrailing`
// preference (Settings › Actions). `disposeSwipe` / `toggleReadSwipe`
// stay in `MessageListView+Rows.swift`; this file adds the flag toggle and
// the binding that picks between the three.
extension MessageListView {
    /// The spec a swipe edge bound to `action` reveals for `envelope`, or
    /// nil for a disabled edge (the row then has no swipe on that side).
    /// Read on every row build, so a change mid-session takes effect at
    /// once, like the dispose label following `disposeAction`.
    func swipeSpec(
        for action: MailSwipeAction,
        envelope: Envelope,
        model: MessageListViewModel
    ) -> SwipeActionSpec? {
        switch action {
        case .toggleRead: return toggleReadSwipe(for: envelope, model: model)
        case .toggleFlag: return toggleFlagSwipe(for: envelope, model: model)
        case .dispose: return disposeSwipe(for: envelope, model: model)
        case .disabled: return nil
        }
    }

    /// Swipe spec: flip `\Flagged`. Same single toggle gesture as the
    /// read one, with the context menu's flag labels and symbols.
    func toggleFlagSwipe(for envelope: Envelope, model: MessageListViewModel) -> SwipeActionSpec {
        let isFlagged = envelope.flags.contains(.flagged)
        return SwipeActionSpec(
            systemImage: isFlagged ? "flag.slash" : "flag",
            title: isFlagged ? "Unflag" : "Flag",
            tint: ColorTokens.flaggedFill,
            identifier: "message.swipe.toggleFlag"
        ) {
            Task { await model.toggleFlag(envelope) }
        }
    }
}
