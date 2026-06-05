import Foundation
import CabalmailKit

/// Drag-and-drop coordination helpers split out of `AppState.swift` so that
/// file stays under the SwiftLint length cap. Storage stays on `AppState`
/// (`messageDragInProgress`, `pendingMoveRequest`, `moveRequestTick`) - only
/// the mutators live here, mirroring the `AppStateCounts` / `AppStateCompose`
/// split.
///
/// The drag flag and the move request are the two halves of moving a message
/// onto a sidebar folder: the flag lets the sidebar reveal folders mid-drag
/// (see `MailRootView`), and the move request hands the dropped payload to the
/// active message list (see `MessageListView`). See
/// `Cabalmail/Views/MessageDrag.swift` for the drag/drop plumbing itself.
@MainActor
extension AppState {
    /// Drag lifecycle, driven from SwiftUI drag/drop closures. `begin` fires
    /// when a row is lifted; `end` fires on drop or release. Both are
    /// idempotent so the burst of drag callbacks the system can emit doesn't
    /// matter.
    func beginMessageDrag() { messageDragInProgress = true }
    func endMessageDrag() { messageDragInProgress = false }

    /// Post a drag-and-drop move for the active message list to perform.
    /// `tick` is monotonic so dragging onto the same folder twice still fires
    /// the list's `.onChange` observer.
    func requestMove(items: [MessageDragItem], to destination: String) {
        moveRequestTick += 1
        pendingMoveRequest = MessageMoveRequest(
            destination: destination,
            items: items,
            tick: moveRequestTick
        )
    }
}
