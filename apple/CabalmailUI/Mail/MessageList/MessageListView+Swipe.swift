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

    /// Swipe spec: flip the default flag (`MessageListViewModel.defaultFlag`),
    /// in its name and color. Same single toggle gesture as the read one,
    /// with the context menu's words and symbols.
    func toggleFlagSwipe(for envelope: Envelope, model: MessageListViewModel) -> SwipeActionSpec {
        let toggle = model.defaultFlag
        let isSet = envelope.flags.contains(toggle.flag)
        return SwipeActionSpec(
            systemImage: toggle.systemImage(isSet: isSet),
            title: toggle.title(isSet: isSet),
            tint: toggle.tint,
            identifier: "message.swipe.toggleFlag"
        ) {
            Task { await model.toggleDefaultFlag(envelope) }
        }
    }
}
