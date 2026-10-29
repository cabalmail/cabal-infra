import SwiftUI

/// What a compose window's scene phase means once its composer has closed.
///
/// A closed compose window is only off screen. On iPhone Duo the system
/// keeps listing it in the window switcher and the "Views Open" pill, and
/// iOS refuses an app's request to destroy its scene session there ("not
/// supported for this device idiom"). Picked again, it came back as a live
/// composer holding the draft it had sent or discarded, Send included
/// (#2257). iPad keeps the scene connected too (#1084).
///
/// So a closed window that has left the screen composes nothing
/// (`ComposeSlotRegistry.mayCompose`), and one that comes back to the front
/// leaves again. A close can finish with the window already in the
/// background: Send, Save Draft and Discard wait on the server, and the user
/// may have moved on by then. That window has left the screen too.
extension ComposeSlotRegistry.ClosedCompose {
    /// Records the phase the window was in when its composer closed.
    mutating func closed(in phase: ScenePhase) {
        if phase == .background { hasLeftScreen = true }
    }

    /// Applies a change of the window's phase after its composer closed, and
    /// answers whether the window should leave the screen again: it has come
    /// back to the front from the switcher, before or after it reached the
    /// background.
    mutating func sceneMoved(from old: ScenePhase, to new: ScenePhase) -> Bool {
        if new == .background { hasLeftScreen = true }
        guard new == .active, old != .active else { return false }
        hasLeftScreen = true
        return true
    }
}
